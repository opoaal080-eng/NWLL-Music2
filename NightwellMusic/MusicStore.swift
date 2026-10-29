import Foundation
import SwiftUI
import AVFoundation
import Combine
import Network

@MainActor final class TrackStatus: ObservableObject {
    @Published var id = ""
    @Published var playing = false
}
@MainActor final class PlaybackClock: ObservableObject {
    let status = TrackStatus()
    private var queueRevision = -1
    var onTick: (([String: Any]) -> Void)?
    @Published var position = 0.0
    @Published var duration = 1.0
    @Published var playing = false
    @Published var id = ""
    @Published var queue: [Track] = []
    @Published var failure = ""
    init() {
        NativePlayer.shared.onChange = { [weak self] in self?.sync() }
        sync()
    }
    #if DEBUG
    var preview = false
    #endif
    func sync() {
        #if DEBUG
        if preview { return }
        #endif
        let value = NativePlayer.shared.snapshot(includeQueue: false)
        position = value["position"] as? Double ?? 0
        duration = max(1, value["duration"] as? Double ?? 1)
        let next = value["playing"] as? Bool ?? false
        if playing != next { playing = next; status.playing = next }
        let nextID = value["id"] as? String ?? ""
        if id != nextID { id = nextID; status.id = nextID }
        failure = value["error"] as? String ?? ""
        let revision = value["queueRevision"] as? Int ?? 0
        if revision != queueRevision {
            queueRevision = revision
            if let raw = NativePlayer.shared.snapshot()["queueTracks"], let data = try? JSONSerialization.data(withJSONObject: raw), let next = try? JSONDecoder().decode([Track].self, from: data), next != queue { queue = next }
        }
        onTick?(value)
    }
    var current: Track? { queue.first { $0.id == id } }
    func toggle() { playing ? NativePlayer.shared.pause() : NativePlayer.shared.play() }
}

@MainActor final class MusicStore: ObservableObject {
    enum Screen: String, CaseIterable { case home = "Главная", search = "Поиск", likes = "Избранное", playlists = "Плейлисты", offline = "Офлайн" }
    @Published var screen: Screen = .home
    @Published var catalog: [Track] = []
    @Published var results: [Track] = []
    @Published var offline: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var likes: Set<String> = []
    @Published var account: Account?
    @Published var query = ""
    @Published var searchMessage = ""
    @Published var error: String?
    @Published var loading = false
    @Published private(set) var connectionStatus = "Загрузка…"
    @Published var downloadMessage = ""
    @Published var downloading = false
    @Published var downloadFractions: [String: Double] = [:]
    @Published var authPresented = false
    @Published var emailChallenge: EmailChallenge?
    @Published var likeFlash = 0
    private(set) var api: MusicAPI
    private(set) var origin: URL
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var searchCache: [String: [Track]] = [:]
    private var starting = false
    private let libraryRefresh = LibraryRefreshCoordinator()
    private var sessionGeneration = UUID()
    private var preloadTask: Task<Void, Never>?
    private var lastPreloadIDs: [String] = []
    private var lastPreloadAt = Date.distantPast
    let clock = PlaybackClock()
    let lyrics = NativeLyrics()
    private var lastSaved = Date.distantPast
    private var listeningID = "", listeningSession = "", listeningSeconds = 0.0
    private var lastTick = ProcessInfo.processInfo.systemUptime, lastReport = Date.distantPast
    private var previousWave = false
    private var previousPlaying = false
    private var listeningDuration = 0.0, listeningPosition = 0.0
    private var mixRecentIDs: [String] = []
    private var mixRecentKey: String {
        "nw-recent-recommendations|" + origin.absoluteString + "|" + (account?.id ?? "device")
    }
    private func restoreRecent() {
        mixRecentIDs = Array((UserDefaults.standard.stringArray(forKey: mixRecentKey) ?? []).suffix(120))
    }
    private var hiddenRecommendationsKey: String {
        "nw-hidden-recommendations|" + origin.absoluteString + "|" + (account?.id ?? "device")
    }
    private var hiddenRecommendationIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenRecommendationsKey) ?? [])
    }
    private var blockedArtistKey: String {
        "nw-hidden-artists|" + origin.absoluteString + "|" + (account?.id ?? "device")
    }
    private var blockedArtists: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: blockedArtistKey) ?? [])
    }
    func isArtistHidden(_ track: Track) -> Bool {
        blockedArtists.contains(RecommendationOrder.key(track.artist))
    }
    func toggleArtistHidden(_ track: Track) {
        let normalized = RecommendationOrder.key(track.artist)
        guard !normalized.isEmpty else { return }
        var artists = UserDefaults.standard.stringArray(forKey: blockedArtistKey) ?? []
        if artists.contains(normalized) { artists.removeAll { $0 == normalized } }
        else { artists.append(normalized) }
        UserDefaults.standard.set(Array(artists.suffix(150)), forKey: blockedArtistKey)
        objectWillChange.send()
    }
    func isRecommendationHidden(_ track: Track) -> Bool { hiddenRecommendationIDs.contains(track.id) }
    func toggleRecommendationHidden(_ track: Track) {
        let key = hiddenRecommendationsKey
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        if ids.contains(track.id) { ids.removeAll { $0 == track.id } }
        else { ids.append(track.id) }
        objectWillChange.send()
        UserDefaults.standard.set(Array(ids.suffix(300)), forKey: key)
    }
    private struct SessionSnapshot: Codable {
        let savedAt: Date
        let tracks: [Track]
        let likes: [String]
        let playlists: [Playlist]
        let wave: [Track]
    }
    private var lastWave: [Track] = []
    private var sessionCacheKey: String? {
        guard let id = account?.id else { return nil }
        return "nw-session-v1-" + (origin.host ?? "server") + "-" + id
    }
    private func restoreSessionSnapshot() {
        restoreRecent()
        guard let key = sessionCacheKey,
              let data = UserDefaults.standard.data(forKey: key) else { return }
        guard let cache = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              cache.savedAt.timeIntervalSinceNow > -365 * 24 * 60 * 60,
              cache.savedAt.timeIntervalSinceNow < 5 * 60 else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        catalog = cache.tracks
        likes = Set(cache.likes)
        playlists = cache.playlists
        lastWave = cache.wave
    }
    private var snapshotSaveTask: Task<Void, Never>?
    private func saveSessionSnapshot() {
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, let key = self.sessionCacheKey else { return }
            let snapshot = SessionSnapshot(savedAt: Date(), tracks: Array(self.catalog.prefix(1500)),
                                           likes: Array(self.likes), playlists: self.playlists,
                                           wave: Array(self.lastWave.prefix(90)))
            let data = await Task.detached(priority: .utility) { try? JSONEncoder().encode(snapshot) }.value
            guard !Task.isCancelled, self.sessionCacheKey == key,
                  let data, data.count < 2_000_000 else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    private let connectionMonitor = NWPathMonitor()
    private let connectionQueue = DispatchQueue(label: "fun.nightwell.connection")
    private var connectionWatcher: Task<Void, Never>?
    private var connectionCheck: Task<Void, Never>?
    private var connectionCheckGeneration = UUID()
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var hasNetworkPath = true
    private var networkGeneration = UUID()
    private var lastConnectionRefresh = Date.distantPast

    private func checkConnection() {
        guard applicationIsActive, sessionReady, !starting, connectionCheck == nil else { return }
        guard hasNetworkPath else { connectionStatus = "Оффлайн"; return }
        let server = origin
        let client = api
        let session = sessionGeneration
        let checkID = UUID()
        connectionCheckGeneration = checkID
        connectionCheck = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionCheckGeneration == checkID { self.connectionCheck = nil }
            }
            do {
                // Reuse the authenticated connection instead of negotiating a new TLS session.
                let identity: Identity = try await client.request("/api/me", timeout: 8)
                guard !Task.isCancelled, self.hasNetworkPath, self.origin == server,
                      self.sessionGeneration == session, self.connectionCheckGeneration == checkID else { return }
                let wasOffline = self.connectionStatus == "Оффлайн"
                let changedAccount = self.account?.id != identity.user?.id
                if changedAccount {
                    self.libraryRefresh.cancel()
                    self.catalog = []; self.likes = []; self.playlists = []; self.lastWave = []; self.results = []
                    self.searchTask?.cancel(); self.searchGeneration = UUID(); self.searchCache.removeAll()
                    NativePlayer.shared.stop()
                }
                self.account = identity.user
                self.cacheAccount()
                await client.setCSRF(identity.csrf)
                guard !Task.isCancelled, self.origin == server,
                      self.sessionGeneration == session, self.connectionCheckGeneration == checkID else { return }
                if changedAccount { self.restoreSessionSnapshot() }
                self.connectionStatus = "Онлайн"
                if (wasOffline || changedAccount) && self.account != nil &&
                    Date().timeIntervalSince(self.lastConnectionRefresh) > 30 {
                    self.lastConnectionRefresh = Date()
                    // Keep the connectivity checker free while the library reloads.
                    Task { [weak self] in
                        guard let self, self.sessionGeneration == session, self.origin == server,
                              self.hasNetworkPath else { return }
                        await self.refresh()
                    }
                }
            } catch {
                if !Task.isCancelled, self.origin == server, self.sessionGeneration == session, self.connectionCheckGeneration == checkID, self.hasNetworkPath { self.connectionStatus = "Оффлайн" }
            }
        }
    }

    private func startConnectionWatcher() {
        connectionMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let available = path.status == .satisfied
                if available != self.hasNetworkPath {
                    self.networkGeneration = UUID()
                    if !available { self.libraryRefresh.cancel() }
                }
                self.hasNetworkPath = available
                if self.hasNetworkPath {
                    self.checkConnection()
                } else {
                    self.connectionCheck?.cancel()
                    self.connectionCheck = nil
                    self.connectionCheckGeneration = UUID()
                    self.connectionStatus = "Оффлайн"
                }
            }
        }
        connectionMonitor.start(queue: connectionQueue)
        connectionWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.checkConnection()
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    init() {
        let saved = UserDefaults.standard.string(forKey: "nightwell.server") ?? "https://music.nightwell.fun/"
        origin = ServerAddress.validated(saved) ?? URL(string: "https://music.nightwell.fun/")!
        api = MusicAPI(origin: origin)
        if let bytes = UserDefaults.standard.data(forKey: "native.account") { account = try? JSONDecoder().decode(Account.self, from: bytes) }
        restoreSessionSnapshot()
        startConnectionWatcher()
        clock.onTick = { [weak self] value in self?.playbackTick(value) }
        observers.append(NotificationCenter.default.addObserver(forName: BackgroundDownloads.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let progress = BackgroundDownloads.shared.progress
            let statusChanged = self.downloadMessage != progress.message
            self.downloading = progress.active; self.downloadMessage = progress.message; self.downloadFractions = progress.fractions
            // Updating a progress bar must not rescan offline storage each percent.
            if statusChanged || !progress.active { Task { await self.refreshOffline() } }
        })
        BackgroundDownloads.shared.reconnect()
        let progress = BackgroundDownloads.shared.progress
        downloading = progress.active; downloadMessage = progress.message; downloadFractions = progress.fractions

        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.applicationIsActive = false
            self.connectionCheck?.cancel(); self.connectionCheck = nil
            self.connectionCheckGeneration = UUID()
            self.savePlayback(force: true)
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applicationIsActive = true
            self?.checkConnection()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.savePlayback(force: true) })
    }
    private var sessionReady = false
    func start() async {
        guard !starting else { return }
        starting = true
        let generation = sessionGeneration
        defer { if generation == sessionGeneration { starting = false } }
        let client = api
        connectionStatus = "Загрузка…"
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-smoke-lyrics") {
            clock.preview = true
            let example = Track(id: "native_preview", title: "Твой тёмный ритм", artist: "Nightwell Music")
            clock.queue = [example]; clock.id = example.id; clock.playing = true; clock.position = 12; clock.duration = 180
            clock.status.id = example.id; clock.status.playing = true
            UserDefaults.standard.set(true, forKey: "nw-ambient-lyrics")
            lyrics.trackID = example.id; lyrics.value = Lyrics(status: "found", lines: [.init(time: 0, text: "Музыка этой ночи"), .init(time: 10, text: "Твой ритм растворяется в тумане")], synced: true, source: "Preview")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--native-smoke") {
            clock.preview = true
            let track = Track(id: "native_preview", title: "Грустная песня (…", artist: "Егор Крид, THRILL PILL")
            clock.queue = [track]; clock.id = track.id; clock.playing = true
            clock.status.id = track.id; clock.status.playing = true
            account = Account(id: "preview", email: "preview@example.invalid", is_admin: true)
            return
        }
        #endif
        // Disk scanning and the session request are independent.
        async let localFiles: Void = refreshOffline()
        restorePlayback()
        do {
            let identity: Identity = try await client.request("/api/me", timeout: 10)
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            if account?.id != identity.user?.id {
                libraryRefresh.cancel()
                catalog = []; likes = []; playlists = []; lastWave = []; results = []
                searchTask?.cancel(); searchGeneration = UUID(); searchCache.removeAll()
                NativePlayer.shared.stop()
            }
            account = identity.user
            restoreAutoFavoritesSetting()
            cacheAccount()
            await client.setCSRF(identity.csrf)
            restoreSessionSnapshot()
            connectionStatus = "Онлайн"
            sessionReady = true
            if let id = pendingSharedTrackID { pendingSharedTrackID = nil; await openSharedTrack(id) }
            restorePlayback()
            // Cached library is already visible. Refresh from the server without holding up startup.
            if account != nil {
                Task { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    await self.refresh()
                }
            }
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            connectionStatus = "Оффлайн"
            sessionReady = true
        }
        await localFiles
        guard generation == sessionGeneration else { return }
        if connectionStatus == "Оффлайн", catalog.isEmpty {
            restorePlayback(offlineOnly: true)
            if !offline.isEmpty { screen = .offline }
        }
    }

    private func cacheAccount() {
        if let account, let bytes = try? JSONEncoder().encode(account) { UserDefaults.standard.set(bytes, forKey: "native.account") }
        else { UserDefaults.standard.removeObject(forKey: "native.account") }
    }
    func savePlayback(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) >= 5, let current = clock.current else { return }
        lastSaved = Date()
        let state = NativePlayer.shared.snapshot(includeQueue: false)
        let memory = PlaybackMemory(id: current.id, tracks: Array(clock.queue.prefix(1000)), position: clock.position, repeatMode: state["repeat"] as? Int ?? 0, shuffle: state["shuffle"] as? Bool ?? false, wave: state["wave"] as? Bool ?? false)
        let origin = origin, account = account?.id ?? "device"
        if force { memory.save(origin, account) } else { Task.detached(priority: .utility) { memory.save(origin, account) } }
    }
    private func restorePlayback(offlineOnly: Bool = false) {
        guard clock.current == nil, let memory = PlaybackMemory.read(origin, account?.id ?? "device") else { return }
        let local = Dictionary(offline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = memory.tracks.compactMap { track -> Track? in
            if offlineOnly { return local[track.id] }; return track
        }
        guard items.contains(where: { $0.id == memory.id }) else { return }
        NativePlayer.shared.prepare(["id": memory.id, "queue": items.map(\.dictionary), "account": account?.id ?? "device", "position": memory.position * 1000, "wave": memory.wave, "wave_preferences": WaveSettings.read(origin, account?.id ?? "device").dictionary], origin: origin, cookies: HTTPCookieStorage.shared.cookies(for: origin) ?? [])
        NativePlayer.shared.modes(repeatMode: memory.repeatMode, shuffle: memory.shuffle)
    }
    private func reportListening(skipped: Bool = false) {
        guard !listeningID.isEmpty, listeningSeconds > 0, account != nil else { return }
        if skipped && previousWave && listeningSeconds >= 3 && listeningSeconds < 30,
           let id = account?.id {
            SkipFeedback.record(listeningID, origin: origin, account: id)
        }
        let body: [String: Any] = ["session_id": listeningSession, "track_id": listeningID, "seconds": listeningSeconds, "skipped": skipped]
        let api = api; Task { let _: OK? = try? await api.request("/api/listening", method: "POST", body: body) }
        lastReport = Date()
    }
    private func playbackTick(_ state: [String: Any]) {
        PremiumFeatureState.shared.tick(self)
        let now = ProcessInfo.processInfo.systemUptime, elapsed = min(1, max(0, now - lastTick)); lastTick = now
        if clock.id != listeningID {
            reportListening(skipped: previousPlaying && listeningSeconds < 30 && listeningPosition + 2 < listeningDuration); listeningID = clock.id; listeningSession = UUID().uuidString; listeningSeconds = 0
            if !clock.id.isEmpty {
                mixRecentIDs.removeAll { $0 == clock.id }
                mixRecentIDs.append(clock.id)
                mixRecentIDs = Array(mixRecentIDs.suffix(120))
                UserDefaults.standard.set(mixRecentIDs, forKey: mixRecentKey)
            }
            lastSaved = .distantPast
            lyrics.select(clock.current, api: api, origin: origin, online: account != nil)
            preloadTask?.cancel()
            preloadTask = nil
            if let at = clock.queue.firstIndex(where: { $0.id == clock.id }), account != nil, hasNetworkPath {
                // Warm only the nearest tracks; a large queue must not trigger 60 server fetches.
                let upcoming = Array(clock.queue.dropFirst(at + 1).prefix(8))
                let api = api, origin = origin
                let ids = upcoming.map(\.id)
                let shouldPreload = ids != lastPreloadIDs || Date().timeIntervalSince(lastPreloadAt) > 45
                if !upcoming.isEmpty && shouldPreload {
                    preloadTask = Task(priority: .utility) {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        lastPreloadIDs = ids
                        lastPreloadAt = Date()
                        let _: OK? = try? await api.request("/api/preload", method: "POST", body: ["ids": ids])
                        guard !Task.isCancelled else { return }
                        await lyrics.preload(Array(upcoming.prefix(3)), api: api, origin: origin)
                        let covers = upcoming.prefix(3).compactMap { track -> URL? in
                            guard let path = track.cover_url else { return nil }
                            return URL(string: path, relativeTo: origin)?.absoluteURL
                        }
                        await ArtworkCache.shared.prefetch(covers)
                    }
                }
            }
        }
        if state["audible"] as? Bool == true, clock.current?._offline != true { listeningSeconds += elapsed }
        if Date().timeIntervalSince(lastReport) >= 15 || previousPlaying && !clock.playing { reportListening() }
        if previousPlaying && !clock.playing { savePlayback(force: true) } else { savePlayback() }
        previousWave = state["wave"] as? Bool ?? false
        previousPlaying = clock.playing; listeningDuration = clock.duration; listeningPosition = clock.position
    }
    func refresh() async {
        guard let owner = account?.id else { return }
        let client = api, server = origin, generation = sessionGeneration
        let network = networkGeneration
        await libraryRefresh.run { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool {
                !Task.isCancelled && self.hasNetworkPath &&
                    self.networkGeneration == network && self.sessionGeneration == generation &&
                    self.account?.id == owner && self.origin == server
            }
            guard current() else { return }
            var successes = 0
            var failures: [String] = []
            // Each response updates its own section immediately; a slow catalogue
            // must not hold back favourites or playlists.
            await LibraryRefreshCoordinator.load(tracks: {
                do {
                    let value: TrackResult = try await client.request("/api/tracks", timeout: 15)
                    guard current() else { return }
                    self.catalog = value.tracks
                    self.syncFavoriteDownloadsIfEnabled()
                    successes += 1
                    self.connectionStatus = "Онлайн"
                    self.saveSessionSnapshot()
                } catch { if current() { failures.append(error.localizedDescription) } }
            }, likes: {
                do {
                    let value: LikeResult = try await client.request("/api/likes", timeout: 10)
                    guard current() else { return }
                    self.likes = Set(value.ids)
                    self.syncFavoriteDownloadsIfEnabled()
                    successes += 1
                    self.connectionStatus = "Онлайн"
                    self.saveSessionSnapshot()
                } catch { if current() { failures.append(error.localizedDescription) } }
            }, playlists: {
                do {
                    let value: PlaylistResult = try await client.request("/api/playlists", timeout: 10)
                    guard current() else { return }
                    self.playlists = value.playlists
                    successes += 1
                    self.connectionStatus = "Онлайн"
                    self.saveSessionSnapshot()
                } catch { if current() { failures.append(error.localizedDescription) } }
            })
            guard current() else { return }
            if successes == 0 {
                self.connectionStatus = "Оффлайн"
                if self.catalog.isEmpty { self.error = failures.first }
            }
        }
    }
    private func finishAuthentication(_ response: EmailAuthResponse) async throws -> Bool {
        if let challenge = response.challenge {
            emailChallenge = challenge
            return false
        }
        guard let user = response.user else { throw APIError(message: "Сервер не подтвердил вход") }
        sessionGeneration = UUID()
        starting = false
        snapshotSaveTask?.cancel()
        libraryRefresh.cancel()
        connectionCheck?.cancel()
        connectionCheck = nil
        connectionCheckGeneration = UUID()
        if account?.id != user.id {
            NativePlayer.shared.stop()
            catalog = []; likes = []; playlists = []; lastWave = []; results = []
            searchTask?.cancel(); searchGeneration = UUID(); searchCache = [:]
        }
        account = user
        restoreAutoFavoritesSetting()
        emailChallenge = nil
        cacheAccount()
        await api.setCSRF(response.csrf)
        restoreSessionSnapshot()
        authPresented = false
        restorePlayback()
        // Present the authenticated session immediately while the library refreshes.
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            await self.refresh()
        }
        if let id = pendingSharedTrackID {
            pendingSharedTrackID = nil
            await openSharedTrack(id)
        }
        return true
    }

    func authenticate(email: String, password: String, register: Bool) async -> Bool {
        error = nil
        emailChallenge = nil
        do {
            let response: EmailAuthResponse = try await api.request(register ? "/api/register" : "/api/login",
                method: "POST", body: ["email": email, "password": password, "supports_email_codes": true])
            return try await finishAuthentication(response)
        } catch { self.error = error.localizedDescription; return false }
    }

    func confirmEmailCode(_ code: String) async -> Bool {
        error = nil
        guard let challenge = emailChallenge else { return false }
        do {
            let path = challenge.action == "register" ? "/api/register" : "/api/login"
            let response: EmailAuthResponse = try await api.request(path, method: "POST",
                body: ["challenge_id": challenge.id, "code": code])
            return try await finishAuthentication(response)
        } catch { self.error = error.localizedDescription; return false }
    }

    func resendEmailCode() async {
        error = nil
        guard let challenge = emailChallenge else { return }
        do {
            let path = challenge.action == "register" ? "/api/register" : "/api/login"
            let response: EmailAuthResponse = try await api.request(path, method: "POST",
                body: ["challenge_id": challenge.id, "resend": true])
            guard let next = response.challenge else { throw APIError(message: "Не удалось запросить код") }
            emailChallenge = next
        } catch { self.error = error.localizedDescription }
    }

    func logout() async {
        do {
            let _: OK = try await api.request("/api/logout", method: "POST")
            NativePlayer.shared.stop(); preloadTask?.cancel(); preloadTask = nil; lastPreloadIDs = []; lastPreloadAt = .distantPast; searchTask?.cancel(); searchGeneration = UUID(); searchCache = [:]
            sessionGeneration = UUID(); starting = false; snapshotSaveTask?.cancel(); libraryRefresh.cancel()
            connectionCheck?.cancel(); connectionCheck = nil; connectionCheckGeneration = UUID(); sessionReady = false
            account = nil; restoreAutoFavoritesSetting(); mixRecentIDs = []; cacheAccount(); catalog = []; results = []; likes = []; playlists = []; lastWave = []; query = ""; await api.setCSRF(nil)
        } catch { self.error = error.localizedDescription }
    }
    func search() {
        searchTask?.cancel(); searchGeneration = UUID()
        let generation = searchGeneration, text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; searchMessage = "Введи название трека или исполнителя"; return }
        let cacheKey = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        results = searchCache[cacheKey] ?? []
        searchMessage = results.isEmpty ? "Ищем треки…" : ""
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                let local = catalog, key = cacheKey
                let terms = text.split(whereSeparator: { $0.isWhitespace }).map { RecommendationOrder.key(String($0)) }.filter { !$0.isEmpty }
                let found = await Task.detached(priority: .userInitiated) {
                    local.filter { track in
                        let combined = (track.title + " " + track.artist).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        let compact = RecommendationOrder.key(track.title + " " + track.artist)
                        return combined.contains(key) || (!terms.isEmpty && terms.allSatisfy { compact.contains($0) })
                    }
                }.value
                guard generation == searchGeneration, !Task.isCancelled else { return }
                results = searchCache[cacheKey] ?? RecommendationOrder.rankSearch(found, query: text, title: { $0.title }, artist: { $0.artist })
                searchMessage = "Ищем полные версии…"
                let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
                for _ in 0..<30 {
                    let response: TrackResult = try await api.request("/api/tracks?q=" + encoded)
                    guard generation == searchGeneration, !Task.isCancelled else { return }
                    let ranked = RecommendationOrder.rankSearch(response.tracks, query: text, title: { $0.title }, artist: { $0.artist })
                    let visible = RecommendationOrder.presentedSearchResults(
                        current: results, incoming: ranked, pending: response.search_pending == true)
                    if results != visible { results = visible }
                    searchMessage = response.search_message ?? ""
                    if response.search_pending != true {
                        if searchCache.count >= 20 { searchCache.removeAll(keepingCapacity: true) }
                        searchCache[cacheKey] = ranked; return
                    }
                    try await Task.sleep(nanoseconds: UInt64(max(1.5, min(10, response.search_retry_after ?? 2)) * 1_000_000_000))
                }
                searchMessage = "Поиск занимает больше времени. Повтори запрос."
            } catch is CancellationError { } catch let failure as URLError where failure.code == .cancelled { }
            catch { if generation == searchGeneration { searchMessage = error.localizedDescription } }
        }
    }
    func leaveSearch() { searchTask?.cancel(); searchGeneration = UUID() }
    // Resolve a shared track URL to the catalogue and start native playback.
    func openSharedTrack(_ id: String) async {
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit }) else { return }
        if !sessionReady { pendingSharedTrackID = id; return }
        if account == nil {
            authPresented = true
            pendingSharedTrackID = id
            return
        }
        let track: Track?
        if let existing = catalog.first(where: { $0.id.lowercased() == id.lowercased() }) {
            track = existing
        } else {
            do {
                let result: TrackResult = try await api.request("/api/shared-track/" + id)
                track = result.tracks.first(where: { $0.id.lowercased() == id.lowercased() })
            } catch {
                self.error = "Не удалось загрузить трек по ссылке: " + error.localizedDescription
                return
            }
        }
        guard let track else {
            error = "Трек из ссылки не найден в каталоге"
            return
        }
        play(track, in: [track])
    }
    private var pendingSharedTrackID: String?
    func play(_ track: Track, in queue: [Track], wave: Bool = false) {
        // Reuse the downloaded audio for tracks listed in favorites or playlists.
        let downloaded = Dictionary(offline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localQueue = queue.map { downloaded[$0.id] ?? $0 }
        let selected = downloaded[track.id] ?? track
        if account == nil && selected._offline != true { authPresented = true; return }
        NativePlayer.shared.prepare(["id": selected.id, "queue": localQueue.map(\.dictionary), "account": account?.id ?? "device", "wave": wave, "wave_preferences": WaveSettings.read(origin, account?.id ?? "device").dictionary], origin: origin, cookies: HTTPCookieStorage.shared.cookies(for: origin) ?? [])
        NativePlayer.shared.play()
    }
    func applyWaveSettings(_ value: WaveSettings) async throws {
        guard let id = account?.id else { authPresented = true; throw APIError(message: "Войди в аккаунт") }
        guard !loading else { throw APIError(message: "Дождись завершения текущей подборки") }
        do {
            let capabilities: WaveOptionsResponse = try await api.request("/api/wave-options")
            guard capabilities.version >= 1 else { throw URLError(.unsupportedURL) }
        } catch { throw APIError(message: "Для настроек подборки нужно обновить сервер Nightwell Music.") }
        guard account?.id == id else { throw CancellationError() }
        guard !loading else { throw APIError(message: "Дождись завершения текущей подборки") }
        value.save(origin, id)
        await wave()
    }
    func wave() async {
        guard !loading else { return }
        guard account != nil else { authPresented = true; return }
        let mixAccount = account?.id
        let settings = WaveSettings.read(origin, mixAccount ?? "device")
        loading = true; defer { loading = false }
        do {
            let hidden = hiddenRecommendationIDs.union(SkipFeedback.recentIDs(origin: origin, account: mixAccount ?? "device"))
            var ids = Array(Set(mixRecentIDs + Array(clock.queue.prefix(8)).map(\.id)))
            ids.append(contentsOf: hidden.sorted().prefix(80))
            if !clock.id.isEmpty { ids.removeAll { $0 == clock.id }; ids.append(clock.id) }
            let excluded = Array(ids.suffix(200)), nonce = UUID().uuidString
            let query = excluded.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            var result: TrackResult = try await api.request("/api/wave?mix=" + nonce + settings.query + "&exclude=" + query)
            if result.tracks.isEmpty, !clock.id.isEmpty {
                let recent = Array(Set(Array(mixRecentIDs.suffix(4)) + [clock.id]))
                result = try await api.request("/api/wave?mix=" + nonce + settings.query + "&exclude=" + recent.joined(separator: ","))
            }
            guard account?.id == mixAccount else { return }
            let fresh = RecommendationOrder.arrange(result.tracks, recent: Set(mixRecentIDs.suffix(20)), hidden: hidden, hiddenArtists: blockedArtists, current: clock.id, identity: { $0.id }, title: { $0.title }, artist: { $0.artist })
            if let first = fresh.first { lastWave = fresh; saveSessionSnapshot(); play(first, in: fresh, wave: true) }
            else { error = result.message ?? "Нет подходящих треков. Измени настройки или попробуй позже." }
        } catch {
            let cooled = SkipFeedback.recentIDs(origin: origin, account: mixAccount ?? "device")
            let cached = lastWave.filter { $0.id != clock.id && !hiddenRecommendationIDs.contains($0.id) && !cooled.contains($0.id) && !blockedArtists.contains(RecommendationOrder.key($0.artist)) }
            if let first = cached.first {
                play(first, in: cached, wave: true)
            } else { self.error = error.localizedDescription }
        }
    }
    @Published private(set) var automaticFavoritesDownload = false
    private var lastAutoFavoritesCheck = Date.distantPast
    private var autoFavoritesKey: String? {
        guard let user = account?.id else { return nil }
        return "nw-auto-favorites|" + origin.absoluteString + "|" + user
    }
    func restoreAutoFavoritesSetting() {
        automaticFavoritesDownload = autoFavoritesKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Bool } ?? false
        lastAutoFavoritesCheck = .distantPast
    }
    func setAutomaticFavoritesDownload(_ enabled: Bool) {
        guard let key = autoFavoritesKey else { authPresented = true; return }
        UserDefaults.standard.set(enabled, forKey: key)
        automaticFavoritesDownload = enabled
        lastAutoFavoritesCheck = .distantPast
        if enabled { syncFavoriteDownloadsIfEnabled(force: true) }
    }
    private func syncFavoriteDownloadsIfEnabled(force: Bool = false, newest: Track? = nil) {
        guard automaticFavoritesDownload, account != nil else { return }
        if let newest {
            Task { await download([newest]) }
            return
        }
        guard force || Date().timeIntervalSince(lastAutoFavoritesCheck) > 120 else { return }
        let missing = catalog.filter { likes.contains($0.id) && !isDownloaded($0) }
        guard !missing.isEmpty else { return }
        lastAutoFavoritesCheck = Date()
        Task { await download(Array(missing.prefix(500))) }
    }
    private var likesInFlight: Set<String> = []
    func like(_ track: Track) async {
        guard account != nil else { authPresented = true; return }
        guard likesInFlight.insert(track.id).inserted else { return }
        defer { likesInFlight.remove(track.id) }
        let owner = account?.id
        let desired = !likes.contains(track.id)
        if desired { likes.insert(track.id); likeFlash += 1 }
        else { likes.remove(track.id) }
        var failure: Error?
        do {
            // The HTTP operation may succeed even if its body is empty or uses an
            // unexpected JSON shape. Confirm the actual server-side state below.
            let _: OK = try await api.request("/api/likes/" + track.id, method: desired ? "POST" : "DELETE")
        } catch {
            failure = error
        }
        guard account?.id == owner else { return }
        // Read back the canonical set; never undo a successful save merely
        // because decoding the POST/DELETE response failed.
        do {
            let response: LikeResult = try await api.request("/api/likes")
            guard account?.id == owner else { return }
            likes = Set(response.ids)
            saveSessionSnapshot()
            if likes.contains(track.id) == desired {
                if desired { syncFavoriteDownloadsIfEnabled(newest: track) }
                return
            }
            self.error = failure?.localizedDescription ?? "Не удалось обновить избранное. Попробуйте ещё раз."
        } catch {
            guard account?.id == owner else { return }
            // Without confirmation we must not claim the request succeeded.
            if desired { likes.remove(track.id) } else { likes.insert(track.id) }
            self.error = "Не удалось проверить избранное. Проверьте подключение и повторите."
        }
    }
    private func playlistCacheKey(_ id: String) -> String? {
        guard let scope = sessionCacheKey, !id.isEmpty else { return nil }
        return scope + "-playlist-" + id
    }
    func playlistTracks(_ id: String) async throws -> [Track] {
        let key = playlistCacheKey(id)
        do {
            let value: TrackResult = try await api.request("/api/playlists/" + id + "/tracks", timeout: 10)
            if let key, let data = try? JSONEncoder().encode(value.tracks), data.count < 1_500_000 {
                UserDefaults.standard.set(data, forKey: key)
            }
            return value.tracks
        } catch {
            if let key, let data = UserDefaults.standard.data(forKey: key),
               let saved = try? JSONDecoder().decode([Track].self, from: data) {
                return saved
            }
            throw error
        }
    }
    func createPlaylist(_ name: String) async {
        do { let _: Playlist = try await api.request("/api/playlists", method: "POST", body: ["name": name]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func deletePlaylist(_ id: String) async {
        do { let _: OK = try await api.request("/api/playlists/" + id, method: "DELETE"); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func add(_ track: Track, playlist: Playlist, remove: Bool = false) async {
        do { let _: OK = try await api.request("/api/playlists/" + playlist.id + "/tracks/" + track.id, method: remove ? "DELETE" : "POST") }
        catch { self.error = error.localizedDescription }
    }
    func share(kind: String, playlist: String = "") async -> URL? {
        do { let result: ShareResult = try await api.request("/api/shares", method: "POST", body: ["kind": kind, "playlist_id": playlist]); return URL(string: result.path, relativeTo: origin)?.absoluteURL }
        catch { self.error = error.localizedDescription; return nil }
    }
    func refreshOffline() async {
        let server = origin
        let value = await Task.detached { try? OfflineStore.operation(["op": "listAll"], origin: server) }.value
        guard origin == server else { return }
        if let value, let data = try? JSONSerialization.data(withJSONObject: value["tracks"] ?? []), let tracks = try? JSONDecoder().decode([Track].self, from: data) { offline = tracks }
    }
    func download(_ list: [Track]) async {
        guard let account else { authPresented = true; return }
        struct DownloadAccess: Decodable { let premium: Bool }
        let owner = account.id
        do {
            let state: DownloadAccess = try await api.request("api/premium/me")
            guard self.account?.id == owner else { return }
            guard state.premium else { error = "Скачивание доступно с Premium — 150 ₽ за 30 дней."; return }
        } catch { self.error = error.localizedDescription; return }
        BackgroundDownloads.shared.enqueue(list, origin: origin, account: account.id)
    }
    func downloadProgress(_ id: String) -> Double? {
        guard let account else { return nil }
        return downloadFractions[origin.absoluteString + "|" + account.id + "|" + id]
    }
    func isDownloaded(_ track: Track) -> Bool {
        offline.contains { $0.id == track.id } || track._offline == true
    }
    func removeDownload(_ track: Track) async {
        guard let account else { return }
        let server = origin
        do {
            _ = try await Task.detached {
                try OfflineStore.operation(["op": "remove", "account": account.id, "id": track.id], origin: server)
            }.value
            await refreshOffline()
        } catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: url)
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw APIError(message: "Не удалось прочитать аудиофайл") }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                defer { try? FileManager.default.removeItem(at: temp) }
                exporter.outputURL = temp; exporter.outputFileType = .m4a
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in exporter.exportAsynchronously { continuation.resume() } }
                guard exporter.status == .completed else { throw exporter.error ?? APIError(message: "Неподдерживаемый формат") }
                let duration = try await asset.load(.duration).seconds
                let bytes = try Data(contentsOf: temp)
                let id = "local_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let meta: [String: Any] = ["id": id, "title": url.deletingPathExtension().lastPathComponent, "artist": "На этом устройстве", "duration": duration.isFinite ? duration : 0]
                _ = try OfflineStore.operation(["op": "save", "account": "device", "id": id, "audio": bytes.base64EncodedString(), "track": meta], origin: origin)
            } catch { self.error = error.localizedDescription }
        }
        await refreshOffline(); screen = .offline
    }
    func changeServer(_ value: String) async {
        guard let url = ServerAddress.validated(value) else { error = "Нужен HTTPS-адрес без пути и параметров"; return }
        NativePlayer.shared.stop(); preloadTask?.cancel(); preloadTask = nil; lastPreloadIDs = []; lastPreloadAt = .distantPast; leaveSearch(); catalog = []; results = []; playlists = []; likes = []; account = nil; searchCache = [:]
        sessionGeneration = UUID(); starting = false; snapshotSaveTask?.cancel(); libraryRefresh.cancel(); connectionCheck?.cancel(); connectionCheck = nil; connectionCheckGeneration = UUID(); sessionReady = false
        origin = url; api = MusicAPI(origin: url); lastWave = []; restoreAutoFavoritesSetting(); cacheAccount(); await api.setCSRF(nil); UserDefaults.standard.set(url.absoluteString, forKey: "nightwell.server"); await start()
    }
}




