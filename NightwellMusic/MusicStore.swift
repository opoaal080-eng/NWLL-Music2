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
    // Visual metadata may lead the actual playhead while the next asset loads.
    @Published var displayID = ""
    @Published var displayPosition = 0.0
    @Published var displayDuration = 1.0
    @Published var playing = false
    @Published var preparing = false
    @Published var bufferFraction = 0.0
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
        // Streaming manifests occasionally expose NaN or infinite lengths.
        // Never pass those into a SwiftUI ClosedRange or an audio frame seek.
        let nextID = value["id"] as? String ?? ""
        let rawDuration = value["duration"] as? Double ?? 0
        if rawDuration.isFinite && rawDuration > 0.5 {
            duration = max(1, min(rawDuration, 604800))
        } else if nextID != id {
            // Keep a known duration for the SAME track when AVPlayer briefly
            // reports an indefinite time during pause or buffering.
            duration = 1
        }
        let rawPosition = value["position"] as? Double ?? 0
        position = rawPosition.isFinite
            ? min(duration, max(0, rawPosition))
            : (nextID == id ? position : 0)
        let next = value["playing"] as? Bool ?? false
        if playing != next { playing = next; status.playing = next }
        if id != nextID { id = nextID; status.id = nextID }
        let nextDisplayID = value["displayID"] as? String ?? nextID
        if displayID != nextDisplayID { displayID = nextDisplayID }
        let rawDisplayDuration = value["displayDuration"] as? Double ?? duration
        let nextDisplayDuration = rawDisplayDuration.isFinite && rawDisplayDuration > 0.5
            ? max(1, min(rawDisplayDuration, 604800)) : duration
        if displayDuration != nextDisplayDuration { displayDuration = nextDisplayDuration }
        let rawDisplayPosition = value["displayPosition"] as? Double ?? position
        let nextDisplayPosition = rawDisplayPosition.isFinite
            ? min(displayDuration, max(0, rawDisplayPosition)) : 0
        if displayPosition != nextDisplayPosition { displayPosition = nextDisplayPosition }
        let nextPreparing = value["preparing"] as? Bool ?? false
        let rawBuffered = value["bufferFraction"] as? Double ?? 0
        let nextBuffered = rawBuffered.isFinite ? min(1, max(0, rawBuffered)) : 0
        if preparing != nextPreparing { preparing = nextPreparing }
        if abs(bufferFraction - nextBuffered) > 0.002 { bufferFraction = nextBuffered }
        failure = value["error"] as? String ?? ""
        let revision = value["queueRevision"] as? Int ?? 0
        if revision != queueRevision {
            queueRevision = revision
            if let raw = NativePlayer.shared.snapshot()["queueTracks"], let data = try? JSONSerialization.data(withJSONObject: raw), let next = try? JSONDecoder().decode([Track].self, from: data), next != queue { queue = next }
        }
        onTick?(value)
    }
    var current: Track? { queue.first { $0.id == id } }
    var displayCurrent: Track? {
        queue.first { $0.id == (displayID.isEmpty ? id : displayID) } ?? current
    }
    func toggle() { playing ? NativePlayer.shared.pause() : NativePlayer.shared.play() }
}

private struct LivePlaybackState: Decodable {
    let revision: Int
    let device_id: String
    let track_id: String
    let queue: [String]
    let position: Double
    let playing: Bool
    let repeatMode: Int
    let shuffle: Bool
    let wave: Bool
    enum CodingKeys: String, CodingKey {
        case revision, device_id, track_id, queue, position, playing, shuffle, wave
        case repeatMode = "repeat"
    }
}
private struct LivePlaybackQueue: Decodable { let tracks: [Track] }
private struct AudioQualityCapabilities: Decodable {
    struct Option: Decodable { let id: String }
    let options: [Option]
}
private struct AudioQualityDecision: Decodable {
    let requested_quality: String
    let selected_quality: String
    let actual_kbps: Int?
    let fallback: Bool
    let message: String?
    let source: String?
}

@MainActor final class MusicStore: ObservableObject {
    enum Screen: String, CaseIterable { case home = "Главная", search = "Поиск", likes = "Избранное", playlists = "Плейлисты", offline = "Офлайн" }
    @Published var screen: Screen = .home
    @Published var catalog: [Track] = []
    @Published var results: [Track] = []
    @Published var artistResults: [ArtistDirectoryItem] = []
    @Published var searchArtistSuggestions: [ArtistDirectoryItem] = []
    @Published var offline: [Track] = []
    @Published private(set) var damagedOffline: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var likes: Set<String> = []
    @Published private(set) var favoriteOrder: [String] = []
    @Published private(set) var favoriteTrackDetails: [Track] = []
    @Published var account: Account?
    @Published var profileNickname = ""
    @Published var profileAvatar: UIImage?
    @Published var profileLoadError: String?
    @Published var profileLoading = false
    // Profile loads originate at startup, connectivity restoration and sheet
    // presentation. Coalesce them to avoid hitting the same API repeatedly.
    var profileLastRequestAt = Date.distantPast
    var profileLastRequestScope = ""
    var profileRequestToken: UUID?
    @Published var query = ""
    @Published var searchMessage = ""
    @Published var audioQualityNotice = ""
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
    private var searchDebounceTask: Task<Void, Never>?
    private var artistSearchTask: Task<Void, Never>?
    private var searchArtistSuggestionTask: Task<Void, Never>?
    private var qualityNoticeTask: Task<Void, Never>?
    private var artistSearchCache: [String: [ArtistDirectoryItem]] = [:]
    private var searchGeneration = UUID()
    private var searchCache: [String: [Track]] = [:]
    private var indexedPlaylistTracks: [Track] = []
    private var indexedPlaylistIDs: Set<String> = []
    private var librarySearchIndexScope = ""
    private var librarySearchIndexTask: Task<Void, Never>?
    @Published private(set) var hasRemotePlayback = false
    private var remotePlaybackState: LivePlaybackState?
    private lazy var liveDeviceID: String = {
        if let current = UserDefaults.standard.string(forKey: "nw-live-sync-device"),
           current.range(of: "^[A-Za-z0-9_-]{8,100}$", options: .regularExpression) != nil {
            return current
        }
        let device = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(device, forKey: "nw-live-sync-device")
        return device
    }()
    private var liveRevision = 0
    private var liveIsOwner = false
    private var liveBusy = false
    private var liveLastWrite = Date.distantPast
    private var liveLoop: Task<Void, Never>?
    private func stopLiveSync() {
        liveLoop?.cancel(); liveLoop = nil
        liveBusy = false; liveIsOwner = false; liveRevision = 0
        remotePlaybackState = nil; hasRemotePlayback = false
    }
    private func startLiveSync() {
        stopLiveSync()
        guard account != nil else { return }
        let expected = account?.id
        liveLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.account?.id == expected {
                if self.hasNetworkPath {
                    await self.pollLiveSync()
                    if self.liveIsOwner && self.applicationIsActive &&
                       Date().timeIntervalSince(self.liveLastWrite) > 5 {
                        await self.publishLiveSync(takeover: false)
                    }
                }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
    }
    private func pollLiveSync() async {
        guard !liveBusy, let owner = account?.id, hasNetworkPath else { return }
        liveBusy = true; defer { liveBusy = false }
        do {
            let remote: LivePlaybackState = try await api.request("/api/playback/state", timeout: 8)
            guard account?.id == owner else { return }
            liveRevision = remote.revision
            let mine = remote.device_id == liveDeviceID
            if liveIsOwner && !mine && clock.playing { NativePlayer.shared.pause() }
            liveIsOwner = mine
            if mine || remote.track_id.isEmpty {
                remotePlaybackState = nil
                if hasRemotePlayback { hasRemotePlayback = false }
            } else {
                remotePlaybackState = remote
                if !hasRemotePlayback { hasRemotePlayback = true }
            }
        } catch { /* Offline mode must keep local playback unchanged. */ }
    }
    private func publishLiveSync(takeover: Bool) async {
        guard !liveBusy, let owner = account?.id, hasNetworkPath,
              takeover || liveIsOwner else { return }
        let state = NativePlayer.shared.snapshot(includeQueue: true)
        guard let trackID = state["id"] as? String, !trackID.isEmpty,
              let all = state["queueTracks"] as? [[String: Any]] else { return }
        let ids = Array(all.compactMap { raw -> String? in
            guard raw["_offline"] as? Bool != true else { return nil }
            return raw["id"] as? String
        }.prefix(950))
        guard ids.contains(trackID) else { return }
        liveBusy = true; defer { liveBusy = false }
        do {
            if takeover {
                let current: LivePlaybackState = try await api.request("/api/playback/state", timeout: 8)
                guard account?.id == owner else { return }
                liveRevision = current.revision
            }
            let rawPosition = state["position"] as? Double ?? 0
            let body: [String: Any] = [
                "device_id": liveDeviceID, "revision": liveRevision, "takeover": takeover,
                "track_id": trackID, "queue": ids,
                "position": rawPosition.isFinite ? max(0, min(86400, rawPosition)) : 0,
                "playing": state["playing"] as? Bool ?? false,
                "repeat": state["repeat"] as? Int ?? 0,
                "shuffle": state["shuffle"] as? Bool ?? false,
                "wave": state["wave"] as? Bool ?? false
            ]
            struct Result: Decodable { let revision: Int }
            let answer: Result = try await api.request("/api/playback/state", method: "PUT", body: body, timeout: 9)
            guard account?.id == owner else { return }
            liveRevision = answer.revision; liveIsOwner = true; remotePlaybackState = nil
            hasRemotePlayback = false; liveLastWrite = Date()
        } catch {
            liveIsOwner = false
        }
    }
    func continuePlaybackHere() async {
        guard !liveBusy, let owner = account?.id, hasNetworkPath else { return }
        liveBusy = true
        do {
            let remote: LivePlaybackState = try await api.request("/api/playback/state", timeout: 8)
            guard account?.id == owner, !remote.track_id.isEmpty,
                  remote.device_id != liveDeviceID else { liveBusy = false; return }
            let list: LivePlaybackQueue = try await api.request("/api/playback/queue", timeout: 10)
            guard account?.id == owner,
                  list.tracks.contains(where: { $0.id == remote.track_id }) else {
                liveBusy = false; error = "Трек больше недоступен на сервере."; return
            }
            let body: [String: Any] = [
                "device_id": liveDeviceID, "revision": remote.revision, "takeover": true,
                "track_id": remote.track_id, "queue": remote.queue,
                "position": remote.position, "playing": remote.playing,
                "repeat": remote.repeatMode, "shuffle": remote.shuffle, "wave": remote.wave
            ]
            struct Result: Decodable { let revision: Int }
            let accepted: Result = try await api.request("/api/playback/state", method: "PUT", body: body, timeout: 9)
            guard account?.id == owner else { liveBusy = false; return }
            liveRevision = accepted.revision; liveIsOwner = true
            remotePlaybackState = nil; hasRemotePlayback = false; liveLastWrite = Date()
            NativePlayer.shared.prepare([
                "id": remote.track_id, "queue": list.tracks.map(\.dictionary),
                "account": owner, "position": remote.position * 1000,
                "wave": remote.wave, "wave_preferences": WaveSettings.read(origin, owner).dictionary
            ], origin: origin, cookies: HTTPCookieStorage.shared.cookies(for: origin) ?? [])
            NativePlayer.shared.modes(repeatMode: remote.repeatMode, shuffle: remote.shuffle)
            if remote.playing { NativePlayer.shared.play() }
            liveBusy = false
        } catch {
            liveBusy = false
            self.error = "Не удалось перенести воспроизведение: " + error.localizedDescription
        }
    }
    private var starting = false
    private let libraryRefresh = LibraryRefreshCoordinator()
    private var sessionGeneration = UUID()
    private var preloadTask: Task<Void, Never>?
    private var lastPreloadIDs: [String] = []
    private var lastPreloadAt = Date.distantPast
    let clock = PlaybackClock()
    let lyrics = NativeLyrics()
    private var lastSaved = Date.distantPast
    private var listeningID = ""
    private var listeningArtist = "", listeningSession = "", listeningSeconds = 0.0
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
    // A liked track may originate in search, recommendations or a shared link,
    // and therefore not yet exist in the main catalogue.
    var favoriteDisplayTracks: [Track] {
        var byID: [String: Track] = [:]
        for item in favoriteTrackDetails + catalog + results + clock.queue + offline {
            if byID[item.id] == nil { byID[item.id] = item }
        }
        var seen = Set<String>()
        let ordered = favoriteOrder.compactMap { id -> Track? in
            guard likes.contains(id), seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        let remaining = likes.sorted().compactMap { id -> Track? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        return ordered + remaining
    }

    private var favoriteDetailCacheKey: String? {
        guard let id = account?.id else { return nil }
        return "nw-favorite-tracks-v2|" + origin.absoluteString + "|" + id
    }

    private func restoreFavoriteTrackDetails(forAccountID savedAccountID: String? = nil) {
        let key = savedAccountID.map { "nw-favorite-tracks-v2|" + origin.absoluteString + "|" + $0 }
            ?? favoriteDetailCacheKey
        guard let key,
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Track].self, from: data) else {
            favoriteTrackDetails = []
            return
        }
        favoriteTrackDetails = Array(decoded.prefix(1200))
    }

    private func persistFavoriteTrackDetails() {
        guard let key = favoriteDetailCacheKey else { return }
        let items = Array(favoriteTrackDetails.prefix(1200))
        guard let data = try? JSONEncoder().encode(items), data.count < 1_900_000 else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func rememberFavoriteTrack(_ track: Track) {
        favoriteTrackDetails.removeAll { $0.id == track.id }
        favoriteTrackDetails.insert(track, at: 0)
        persistFavoriteTrackDetails()
    }

    private var favoriteOrderKey: String? {
        guard let id = account?.id else { return nil }
        return "nw-favorites-order-v1|" + origin.absoluteString + "|" + id
    }

    private func saveFavoriteOrder() {
        guard let key = favoriteOrderKey else { return }
        UserDefaults.standard.set(favoriteOrder, forKey: key)
    }

    // Keep the user's explicit add chronology across app restarts.
    // Older servers return only IDs rather than liked_at timestamps, so
    // unobserved favorites fall back to the API's original ID sequence.
    private func reconcileFavoriteOrder(_ serverIDs: [String], newestID: String? = nil) {
        let valid = Set(serverIDs)
        let saved = favoriteOrderKey.flatMap {
            UserDefaults.standard.stringArray(forKey: $0)
        } ?? []
        var seen = Set<String>()
        let previous = (saved + favoriteOrder).filter {
            valid.contains($0) && seen.insert($0).inserted
        }
        let unseen = serverIDs.reversed().filter {
            valid.contains($0) && seen.insert($0).inserted
        }
        var result = previous + unseen
        if let newestID, valid.contains(newestID) {
            result.removeAll { $0 == newestID }
            result.insert(newestID, at: 0)
        }
        favoriteOrder = result
        saveFavoriteOrder()
        favoriteTrackDetails.removeAll { !valid.contains($0.id) }
        persistFavoriteTrackDetails()
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
    private func restoreSessionSnapshot(forAccountID savedAccountID: String? = nil) {
        restoreRecent()
        let owner = savedAccountID ?? account?.id
        let key = owner.map { "nw-session-v1-" + (origin.host ?? "server") + "-" + $0 }
        guard let key,
              let data = UserDefaults.standard.data(forKey: key) else { return }
        guard let cache = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              cache.savedAt.timeIntervalSinceNow > -365 * 24 * 60 * 60,
              cache.savedAt.timeIntervalSinceNow < 5 * 60 else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        catalog = cache.tracks
        likes = Set(cache.likes)
        if account?.id == owner {
            reconcileFavoriteOrder(cache.likes)
        } else if let owner {
            // Display the last authorized user's local library without treating
            // the cached identity as an authenticated network session.
            let key = "nw-favorites-order-v1|" + origin.absoluteString + "|" + owner
            let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
            var seen = Set<String>()
            favoriteOrder = (saved + cache.likes.reversed()).filter {
                likes.contains($0) && seen.insert($0).inserted
            }
        }
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
                                           likes: self.favoriteOrder.isEmpty ? Array(self.likes) : self.favoriteOrder,
                                           playlists: self.playlists,
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
    private var lastConfirmedServerResponse = Date.distantPast
    private var consecutiveConnectionFailures = 0

    private func markServerReachable() {
        consecutiveConnectionFailures = 0
        lastConfirmedServerResponse = Date()
        connectionStatus = "Онлайн"
    }

    // HTTP 4xx or a JSON decoding error means the API responded: it is not
    // evidence that the server is offline. Authentication is a separate state.
    private func isServerResponse(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let response = error as? RequestRetry.HTTPFailure {
            return (400..<500).contains(response.status)
        }
        return false
    }

    private func probeAPIReachability(at server: URL) async -> Bool {
        guard let url = URL(string: "/api/me", relativeTo: server)?.absoluteURL else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 6)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.url?.host == server.host else { return false }
            // 401/403/404/405 still prove an origin/server response; 5xx does not.
            return (200..<500).contains(http.statusCode)
        } catch { return false }
    }

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
                let wasOffline = self.connectionStatus == "Оффлайн" || self.connectionStatus == "Ограничен"
                let changedAccount = self.account?.id != identity.user?.id
                if changedAccount {
                    self.libraryRefresh.cancel()
                    self.catalog = []; self.likes = []; self.playlists = []; self.lastWave = []; self.results = []
                    self.searchTask?.cancel(); self.artistSearchTask?.cancel(); self.searchGeneration = UUID(); self.searchCache.removeAll(); self.artistResults = []; self.artistSearchCache.removeAll()
                    NativePlayer.shared.stop()
                }
                self.account = identity.user
                if changedAccount { self.restoreFavoriteTrackDetails() }
                self.cacheAccount()
                if changedAccount { self.restoreAutoFavoritesSetting(); self.startLiveSync() }
                await client.setCSRF(identity.csrf)
                guard !Task.isCancelled, self.origin == server,
                      self.sessionGeneration == session, self.connectionCheckGeneration == checkID else { return }
                if changedAccount { self.restoreCachedProfile(); self.restoreSessionSnapshot() }
                if changedAccount || wasOffline {
                    Task { [weak self] in
                        guard let self, self.sessionGeneration == session,
                              self.origin == server else { return }
                        await self.refreshProfile()
                    }
                }
                self.markServerReachable()
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
                let responded: Bool
                if self.isServerResponse(error) { responded = true }
                else { responded = await self.probeAPIReachability(at: server) }
                guard !Task.isCancelled, self.origin == server,
                      self.sessionGeneration == session,
                      self.connectionCheckGeneration == checkID,
                      self.hasNetworkPath else { return }
                if responded {
                    self.markServerReachable()
                } else {
                    self.consecutiveConnectionFailures += 1
                    // One timeout must not override a recently healthy API.
                    if self.consecutiveConnectionFailures >= 3 &&
                       Date().timeIntervalSince(self.lastConfirmedServerResponse) > 30 {
                        self.connectionStatus = "Ограничен"
                    } else if self.connectionStatus != "Онлайн" {
                        self.connectionStatus = "Загрузка…"
                    }
                }
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
        restoreCachedProfile()
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
        // Show previously saved track lists immediately, even if /api/me is
        // slow or the device temporarily has no network connection.
        let savedAccount = UserDefaults.standard.data(forKey: "native.account")
            .flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        if account == nil, let savedAccount {
            restoreSessionSnapshot(forAccountID: savedAccount.id)
            restoreFavoriteTrackDetails(forAccountID: savedAccount.id)
        }
        do {
            let identity: Identity = try await client.request("/api/me", timeout: 10)
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            if account?.id != identity.user?.id || (identity.user == nil && savedAccount != nil) {
                libraryRefresh.cancel()
                catalog = []; likes = []; favoriteOrder = []; favoriteTrackDetails = []; playlists = []; lastWave = []; results = []
                searchTask?.cancel(); artistSearchTask?.cancel(); searchGeneration = UUID(); searchCache.removeAll(); artistResults = []; artistSearchCache.removeAll()
                NativePlayer.shared.stop()
            }
            account = identity.user
            restoreFavoriteTrackDetails()
            restoreCachedProfile()
            restoreAutoFavoritesSetting()
            cacheAccount()
            await client.setCSRF(identity.csrf)
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            // This is required even if /api/me returns the same cached account ID.
            // SwiftUI's onChange(account.id) won't fire on that common startup path.
            if account != nil {
                Task { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    await self.refreshProfile()
                }
            }
            restoreSessionSnapshot()
            markServerReachable()
            sessionReady = true
            if let id = pendingSharedTrackID { pendingSharedTrackID = nil; await openSharedTrack(id) }
            restorePlayback()
            startLiveSync()
            // Cached library is already visible. Refresh from the server without holding up startup.
            if account != nil {
                Task { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    await self.refresh()
                }
            }
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            connectionStatus = hasNetworkPath ? "Загрузка…" : "Оффлайн"
            sessionReady = true
            // A failed identity request is not proof that the server is down.
            // The periodic watcher verifies actual API reachability.
        }
        await localFiles
        guard generation == sessionGeneration else { return }
        if connectionStatus != "Онлайн", catalog.isEmpty {
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
        RecommendationOrder.learn(session: listeningSession, artist: listeningArtist, seconds: listeningSeconds, skipped: skipped)
        let body: [String: Any] = ["session_id": listeningSession, "track_id": listeningID, "seconds": listeningSeconds, "skipped": skipped]
        let api = api; Task { let _: OK? = try? await api.request("/api/listening", method: "POST", body: body) }
        lastReport = Date()
    }
    func checkAudioQualitySupport() async {
        guard account != nil else { return }
        do {
            let response: AudioQualityCapabilities = try await api.request(
                "/api/audio-quality/options", timeout: 7)
            guard response.options.contains(where: { $0.id == "high" }) else {
                throw APIError(message: "Смена качества недоступна")
            }
            UserDefaults.standard.set(true, forKey: "nw-quality-ready")
            UserDefaults.standard.set(origin.absoluteString, forKey: "nw-quality-ready-origin")
        } catch {
            UserDefaults.standard.set(false, forKey: "nw-quality-ready")
            audioQualityNotice = "Сервер не поддерживает смену качества"
        }
    }
    private func updateAudioQualityNotice(_ trackID: String) {
        qualityNoticeTask?.cancel()
        audioQualityNotice = ""
        let chosenQuality = UserDefaults.standard.string(forKey: "nw-audio-quality") ?? "auto"
        let quality = (chosenQuality == "low" || chosenQuality == "economy") ? "economy" :
            (chosenQuality == "medium" || chosenQuality == "high") ? "high" : "auto"
        guard quality != "auto", account != nil else { return }
        guard clock.current?._offline != true else { return }
        let wasReady = UserDefaults.standard.bool(forKey: "nw-quality-ready") &&
            UserDefaults.standard.string(forKey: "nw-quality-ready-origin") == origin.absoluteString
        qualityNoticeTask = Task { [weak self] in
            guard let self else { return }
            if !wasReady {
                await checkAudioQualitySupport()
                if !Task.isCancelled && clock.id == trackID {
                    audioQualityNotice = "Выбранное качество применится со следующего трека"
                }
                return
            }
            do {
                let result: AudioQualityDecision = try await api.request(
                    "/api/audio-quality/options?track_id=" + trackID +
                    "&quality=" + quality, timeout: 12)
                guard !Task.isCancelled && clock.id == trackID else { return }
                let actual = result.selected_quality == "economy" ? "Низкое" :
                    result.selected_quality == "high" ? "Высокое" : "Исходное"
                audioQualityNotice = result.fallback ?
                    "Выбранное качество недоступно. Используется: \(actual)." : ""
            } catch {
                if !Task.isCancelled && clock.id == trackID {
                    audioQualityNotice = "Не удалось проверить качество, играет доступный поток"
                }
            }
        }
    }
    private func playbackTick(_ state: [String: Any]) {
        PremiumFeatureState.shared.tick(self)
        let now = ProcessInfo.processInfo.systemUptime, elapsed = min(1, max(0, now - lastTick)); lastTick = now
        if clock.id != listeningID {
            if !clock.id.isEmpty { updateAudioQualityNotice(clock.id) }
            reportListening(skipped: previousPlaying && listeningSeconds < 30 && listeningPosition + 2 < listeningDuration); listeningID = clock.id; listeningArtist = clock.queue.first(where: { $0.id == clock.id })?.artist ?? ""; listeningSession = UUID().uuidString; listeningSeconds = 0
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
                // Send the next 12 tracks; the server gives only the nearest two full audio prefetch.
                let upcoming = Array(clock.queue.dropFirst(at + 1).prefix(12))
                let api = api, origin = origin, playingID = clock.id
                let ids = upcoming.map(\.id)
                let shouldPreload = ids != lastPreloadIDs || Date().timeIntervalSince(lastPreloadAt) > 45
                if !upcoming.isEmpty && shouldPreload {
                    preloadTask = Task(priority: .utility) {
                        // Don't start server-side preloads alongside the first stream request.
                        // Speculative downloads previously competed with audio for bandwidth.
                        do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
                        guard !Task.isCancelled, clock.id == playingID else { return }
                        lastPreloadIDs = ids
                        lastPreloadAt = Date()
                        let covers = upcoming.prefix(3).compactMap {
                            CoverImagePipeline.coverURL(for: $0, origin: origin)
                        }
                        // Cover requests do not hold up the next-track audio preload.
                        // Cancel speculative art if a different song takes over.
                        let coverTask = Task(priority: .utility) {
                            await CoverImagePipeline.shared.prefetch(covers)
                        }
                        // Lyrics and small artwork are independent of the server's
                        // audio warmup. Fetch them early, while the current stream
                        // is starting, instead of waiting for a potentially slow
                        // preload endpoint.
                        let lyricTask = Task(priority: .utility) {
                            await lyrics.preload(Array(upcoming.prefix(2)), api: api, origin: origin)
                        }
                        defer { coverTask.cancel(); lyricTask.cancel() }
                        guard !Task.isCancelled, clock.id == playingID else { return }
                        // Only warm new audio after the current track is actually audible.
                        // Give slower mobile networks a short grace period.
                        for _ in 0..<24 {
                            guard !Task.isCancelled, clock.id == playingID else { return }
                            if NativePlayer.shared.snapshot(includeQueue: false)["audible"] as? Bool == true { break }
                            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                        }
                        guard !Task.isCancelled, clock.id == playingID,
                              NativePlayer.shared.snapshot(includeQueue: false)["audible"] as? Bool == true else { return }
                        let _: OK? = try? await api.request("/api/preload", method: "POST", body: ["ids": ids, "current_id": playingID], timeout: 10)
                        guard !Task.isCancelled, clock.id == playingID else { return }
                        await coverTask.value
                        await lyricTask.value
                    }
                }
            }
        }
        if state["audible"] as? Bool == true, clock.current?._offline != true { listeningSeconds += elapsed }
        if Date().timeIntervalSince(lastReport) >= 15 || previousPlaying && !clock.playing { reportListening() }
        if previousPlaying && !clock.playing { savePlayback(force: true) } else { savePlayback() }
        if liveIsOwner && !liveBusy && hasNetworkPath &&
           Date().timeIntervalSince(liveLastWrite) > 6 {
            Task { await publishLiveSync(takeover: false) }
        }
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
                    self.markServerReachable()
                    self.saveSessionSnapshot()
                } catch { if current() { failures.append(error.localizedDescription) } }
            }, likes: {
                do {
                    let value: LikeResult = try await client.request("/api/likes", timeout: 10)
                    guard current() else { return }
                    self.likes = Set(value.ids)
                    self.reconcileFavoriteOrder(value.ids)
                    self.syncFavoriteDownloadsIfEnabled()
                    successes += 1
                    self.markServerReachable()
                    self.saveSessionSnapshot()
                } catch { if current() { failures.append(error.localizedDescription) } }
            }, playlists: {
                do {
                    let value: PlaylistResult = try await client.request("/api/playlists", timeout: 10)
                    guard current() else { return }
                    self.playlists = value.playlists
                    self.ensureLibrarySearchIndex()
                    successes += 1
                    self.markServerReachable()
                    self.saveSessionSnapshot()
                } catch { if current() { failures.append(error.localizedDescription) } }
            })
            guard current() else { return }
            if successes == 0 {
                // One failed library refresh does not override a healthy API
                // ping. The connection watcher is the only outage authority.
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
            catalog = []; likes = []; favoriteOrder = []; playlists = []; lastWave = []; results = []
            searchTask?.cancel(); artistSearchTask?.cancel(); searchGeneration = UUID(); searchCache = [:]; artistResults = []; artistSearchCache = [:]
        }
        account = user
        restoreCachedProfile()
        restoreAutoFavoritesSetting()
        emailChallenge = nil
        cacheAccount()
        await api.setCSRF(response.csrf)
        let signedInGeneration = sessionGeneration
        Task { [weak self] in
            guard let self, self.sessionGeneration == signedInGeneration else { return }
            await self.refreshProfile()
        }
        restoreSessionSnapshot()
        authPresented = false
        restorePlayback()
        startLiveSync()
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
            NativePlayer.shared.stop(); preloadTask?.cancel(); preloadTask = nil; lastPreloadIDs = []; lastPreloadAt = .distantPast; searchTask?.cancel(); artistSearchTask?.cancel(); searchGeneration = UUID(); searchCache = [:]; artistResults = []; artistSearchCache = [:]
            sessionGeneration = UUID(); starting = false; snapshotSaveTask?.cancel(); libraryRefresh.cancel()
            connectionCheck?.cancel(); connectionCheck = nil; connectionCheckGeneration = UUID(); sessionReady = false
            stopLiveSync()
            account = nil; profileNickname = ""; profileAvatar = nil; restoreAutoFavoritesSetting(); mixRecentIDs = []; cacheAccount(); catalog = []; results = []; likes = []; favoriteOrder = []; playlists = []; lastWave = []; query = ""; await api.setCSRF(nil)
        } catch { self.error = error.localizedDescription }
    }
    private func refreshSearchArtists(for text: String, generation: UUID) {
        searchArtistSuggestionTask?.cancel()
        // Derive short chip lists in the background. The old SwiftUI View ran
        // regular expressions across the entire catalogue on every redraw.
        let visibleTracks = Array(results.prefix(180))
        let directory = Array(artistResults.prefix(16))
        searchArtistSuggestionTask = Task(priority: .utility) {
            let suggestions = await Task.detached(priority: .utility) {
                let names = ArtistNames.matches(query: text, tracks: visibleTracks)
                let byKey = Dictionary(directory.map { (ArtistNames.normalized($0.name), $0) },
                                       uniquingKeysWith: { first, _ in first })
                return names.map { name in
                    let key = ArtistNames.normalized(name)
                    return byKey[key] ?? ArtistDirectoryItem(
                        id: key, name: name, image_url: nil,
                        track_count: nil, source: nil)
                }
            }.value
            guard !Task.isCancelled, generation == searchGeneration else { return }
            if searchArtistSuggestions != suggestions {
                searchArtistSuggestions = suggestions
            }
        }
    }
    private func ensureLibrarySearchIndex() {
        let keys = playlists.prefix(45).compactMap { playlistCacheKey($0.id) }
        let scope = (account?.id ?? "guest") + "|" + origin.absoluteString + "|" + keys.joined(separator: "|")
        guard librarySearchIndexScope != scope else { return }
        librarySearchIndexScope = scope
        librarySearchIndexTask?.cancel()
        indexedPlaylistTracks = []
        indexedPlaylistIDs = []
        librarySearchIndexTask = Task(priority: .utility) {
            let loaded = await Task.detached(priority: .utility) { () -> [Track] in
                var seen = Set<String>(), result: [Track] = []
                for key in keys {
                    if Task.isCancelled { break }
                    guard let data = UserDefaults.standard.data(forKey: key),
                          let tracks = try? JSONDecoder().decode([Track].self, from: data)
                    else { continue }
                    for track in tracks.prefix(2000) {
                        if seen.insert(track.id).inserted { result.append(track) }
                    }
                }
                return result
            }.value
            guard !Task.isCancelled, librarySearchIndexScope == scope else { return }
            indexedPlaylistIDs = Set(loaded.map(\.id))
            indexedPlaylistTracks = loaded
            if screen == .search && query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                search()
            }
        }
    }

    func scheduleSearch() {
        // A separate debounce means typing never scans the catalogue or forces
        // 100+ image rows to refresh for each individual keyboard event.
        searchDebounceTask?.cancel()
        searchTask?.cancel()
        artistSearchTask?.cancel()
        searchArtistSuggestionTask?.cancel()
        searchGeneration = UUID()
        let expected = query
        if expected.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            search()
            return
        }
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled, let self, self.query == expected,
                  self.screen == .search else { return }
            self.search()
        }
    }
    func search() {
        ensureLibrarySearchIndex()
        searchTask?.cancel(); artistSearchTask?.cancel(); searchArtistSuggestionTask?.cancel()
        searchGeneration = UUID()
        let generation = searchGeneration, text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []; artistResults = []; searchArtistSuggestions = []
            searchMessage = "Введи название трека или исполнителя"
            return
        }
        guard text.count >= 2 else {
            results = []; artistResults = []; searchArtistSuggestions = []
            searchMessage = "Введи ещё один символ"
            return
        }
        let cacheKey = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let priorityIDs = likes.union(indexedPlaylistIDs)
        results = NightwellLibrarySearchOrder.ordered(
            searchCache[cacheKey] ?? [], query: text, priorityIDs: priorityIDs)
        artistResults = artistSearchCache[cacheKey] ?? []
        refreshSearchArtists(for: text, generation: generation)
        searchMessage = results.isEmpty ? "Ищем треки…" : ""
        if account != nil && text.count >= 2 {
            let encodedArtist = text.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
            artistSearchTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 40_000_000)
                    let found: ArtistDirectoryResults = try await api.request(
                        "/api/artists?q=" + encodedArtist + "&limit=16", timeout: 9)
                    guard !Task.isCancelled, generation == searchGeneration else { return }
                    artistResults = found.artists
                    refreshSearchArtists(for: text, generation: generation)
                    if artistSearchCache.count >= 20 { artistSearchCache.removeAll(keepingCapacity: true) }
                    artistSearchCache[cacheKey] = found.artists
                } catch {
                    // Older servers continue to use local artist matches.
                }
            }
        }
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 30_000_000)
                try Task.checkCancellation()
                let local = catalog + indexedPlaylistTracks
                    + favoriteTrackDetails.filter { likes.contains($0.id) }
                let owned = priorityIDs, key = cacheKey
                let terms = text.split(whereSeparator: { $0.isWhitespace }).map { RecommendationOrder.key(String($0)) }.filter { !$0.isEmpty }
                let found = await Task.detached(priority: .userInitiated) {
                    var matches: [Track] = []
                    matches.reserveCapacity(160)
                    for track in local {
                        if Task.isCancelled { break }
                        let combined = (track.title + " " + track.artist).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        let compact = RecommendationOrder.key(track.title + " " + track.artist)
                        if combined.contains(key) || (!terms.isEmpty && terms.allSatisfy({ compact.contains($0) })) {
                            matches.append(track)
                            if matches.count >= 180 { break }
                        }
                    }
                    return NightwellLibrarySearchOrder.ordered(
                        matches, query: text, priorityIDs: owned)
                }.value
                guard generation == searchGeneration, !Task.isCancelled else { return }
                results = NightwellLibrarySearchOrder.ordered(
                    found + (searchCache[cacheKey] ?? []),
                    query: text, priorityIDs: owned)
                refreshSearchArtists(for: text, generation: generation)
                searchMessage = "Ищем полные версии…"
                let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
                for _ in 0..<30 {
                    let response: TrackResult = try await api.request("/api/tracks?q=" + encoded)
                    guard generation == searchGeneration, !Task.isCancelled else { return }
                    let incoming = Array(response.tracks.prefix(250))
                    let ranked = await Task.detached(priority: .userInitiated) {
                        Array(RecommendationOrder.rankSearch(incoming, query: text,
                              title: { $0.title }, artist: { $0.artist }).prefix(140))
                    }.value
                    guard generation == searchGeneration, !Task.isCancelled else { return }
                    let serverVisible = RecommendationOrder.presentedSearchResults(
                        current: results, incoming: ranked, pending: response.search_pending == true)
                    let visible = NightwellLibrarySearchOrder.ordered(
                        found + serverVisible, query: text, priorityIDs: owned)
                    if results != visible {
                        results = visible
                        refreshSearchArtists(for: text, generation: generation)
                    }
                    searchMessage = response.search_message ?? ""
                    if response.search_pending != true {
                        if searchCache.count >= 20 { searchCache.removeAll(keepingCapacity: true) }
                        searchCache[cacheKey] = visible; return
                    }
                    try await Task.sleep(nanoseconds: UInt64(max(1.5, min(10, response.search_retry_after ?? 2)) * 1_000_000_000))
                }
                searchMessage = "Поиск занимает больше времени. Повтори запрос."
            } catch is CancellationError { } catch let failure as URLError where failure.code == .cancelled { }
            catch { if generation == searchGeneration { searchMessage = error.localizedDescription } }
        }
    }
    func leaveSearch() {
        searchDebounceTask?.cancel()
        searchTask?.cancel(); artistSearchTask?.cancel()
        searchArtistSuggestionTask?.cancel()
        searchGeneration = UUID()
        searchArtistSuggestions = []
    }
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
    func play(_ track: Track, in queue: [Track], wave: Bool = false,
              seedArtists: [String] = []) {
        // Reuse the downloaded audio for tracks listed in favorites or playlists.
        let downloaded = Dictionary(offline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = downloaded[track.id] ?? track
        let scope = selected._offline_account ?? account?.id ?? "device"
        let damagedSelected = selected._offline == true &&
            OfflineStore.audio(origin: origin, account: scope, id: selected.id) == nil
        if damagedSelected && (selected.id.hasPrefix("local_") || account == nil || !hasNetworkPath) {
            error = "Скачанный файл повреждён или удалён. Подключись к интернету и скачай его снова."
            return
        }
        if account == nil && selected._offline != true { authPresented = true; return }
        // Old restored queues may contain an _offline marker for a file that no
        // longer exists. Fall back to the online source instead of silence.
        func verified(_ candidate: Track) -> Track {
            guard candidate._offline == true else { return candidate }
            let owner = candidate._offline_account ?? account?.id ?? "device"
            guard OfflineStore.audio(origin: origin, account: owner, id: candidate.id) == nil else { return candidate }
            var remote = candidate
            remote._offline = false
            remote._offline_account = nil
            return remote
        }
        let localQueue = queue.map { verified(downloaded[$0.id] ?? $0) }
        if damagedSelected {
            error = "Офлайн-копия недоступна. Воспроизводим через интернет. Загрузи трек повторно."
        }
        NativePlayer.shared.prepare(["id": selected.id, "queue": localQueue.map(\.dictionary), "account": account?.id ?? "device", "wave": wave, "wave_seed_artists": seedArtists, "wave_preferences": WaveSettings.read(origin, account?.id ?? "device").dictionary], origin: origin, cookies: HTTPCookieStorage.shared.cookies(for: origin) ?? [])
        NativePlayer.shared.play()
        Task { await publishLiveSync(takeover: true) }
    }
    func rhythm(around track: Track) async {
        await playSeededRhythm(seeds: [track], startWithSeed: track)
    }

    func rhythm(around playlist: Playlist) async {
        guard account != nil else { authPresented = true; return }
        do {
            let songs = try await playlistTracks(playlist.id)
            guard !songs.isEmpty else {
                error = "В плейлисте нет треков для подбора похожей музыки."
                return
            }
            await playSeededRhythm(seeds: songs, startWithSeed: nil)
        } catch {
            self.error = "Не получилось прочитать плейлист: " + error.localizedDescription
        }
    }

    private func playSeededRhythm(seeds: [Track], startWithSeed: Track?) async {
        guard account != nil else { authPresented = true; return }
        guard !loading else { return }
        guard !seeds.isEmpty else { return }
        loading = true
        defer { loading = false }
        let owner = account?.id
        let blocked = blockedArtists
        let hidden = hiddenRecommendationIDs
        var songs = catalog
        songs.append(contentsOf: results)
        songs.append(contentsOf: offline)
        songs.append(contentsOf: favoriteTrackDetails)
        songs.append(contentsOf: indexedPlaylistTracks)
        songs.append(contentsOf: lastWave)
        songs.append(contentsOf: clock.queue)
        let preferenceArtists = NightwellSeededRhythm.artists(seeds)
        let seedCopy = Array(seeds.prefix(400))
        func rank(_ pool: [Track]) async -> [Track] {
            await Task.detached(priority: .userInitiated) {
                NightwellSeededRhythm.ranked(
                    candidates: pool, seeds: seedCopy,
                    hidden: hidden, blockedArtists: blocked)
            }.value
        }
        var picked = await rank(songs)
        if picked.count < 25 {
            // One existing recommendation request only: avoid searching the
            // provider independently for every song in a large playlist.
            var query = URLComponents()
            query.path = "/api/wave"
            let settings = WaveSettings.read(origin, owner ?? "device")
            let seedIDs: [String] = seedCopy.prefix(100).map { $0.id }
            let candidateIDs: [String] = picked.prefix(70).map { $0.id }
            let skip = Array(Set(seedIDs + candidateIDs))
            query.queryItems = [
                URLQueryItem(name: "exclude", value: skip.joined(separator: ",")),
                URLQueryItem(name: "artists", value: preferenceArtists.joined(separator: ","))
            ] + WaveSettings.keys.map { URLQueryItem(name: $0, value: settings.dictionary[$0]) }
            if let path = query.string {
                do {
                    let response: TrackResult = try await api.request(path, timeout: 15)
                    picked = await rank(songs + response.tracks)
                } catch {
                    // Usable on-device results still work without a connection.
                }
            }
        }
        guard !Task.isCancelled, account?.id == owner else { return }
        if let seed = startWithSeed {
            let others = picked.filter { $0.id != seed.id }
            guard !others.isEmpty else {
                error = "Не удалось подобрать похожие треки. Попробуй другую песню."
                return
            }
            play(seed, in: [seed] + others, wave: true, seedArtists: preferenceArtists)
        } else if let first = picked.first {
            play(first, in: picked, wave: true, seedArtists: preferenceArtists)
        } else {
            error = "Для этого плейлиста не нашлось похожих треков в доступном каталоге."
        }
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
            let recent = Set(mixRecentIDs.suffix(20))
            let hiddenArtists = blockedArtists, currentID = clock.id
            let candidates = result.tracks
            // Ranking a large provider result must not block gestures or audio UI.
            let fresh = await Task.detached(priority: .userInitiated) {
                RecommendationOrder.arrange(candidates, recent: recent, hidden: hidden,
                    hiddenArtists: hiddenArtists, current: currentID, identity: { $0.id },
                    title: { $0.title }, artist: { $0.artist })
            }.value
            guard account?.id == mixAccount, !Task.isCancelled else { return }
            if let first = fresh.first {
                lastWave = fresh
                saveSessionSnapshot()
                play(first, in: fresh, wave: true)
                let server = origin
                Task(priority: .utility) {
                    let covers = fresh.prefix(4).compactMap { CoverImagePipeline.coverURL(for: $0, origin: server) }
                    await CoverImagePipeline.shared.prefetch(covers)
                }
            }
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
        let beforeOrder = favoriteOrder
        let beforeDetails = favoriteTrackDetails
        if desired {
            rememberFavoriteTrack(track)
            likes.insert(track.id)
            favoriteOrder.removeAll { $0 == track.id }
            favoriteOrder.insert(track.id, at: 0)
            likeFlash += 1
        } else {
            likes.remove(track.id)
            favoriteOrder.removeAll { $0 == track.id }
            favoriteTrackDetails.removeAll { $0.id == track.id }
            persistFavoriteTrackDetails()
        }
        saveFavoriteOrder()
        saveSessionSnapshot()
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
            reconcileFavoriteOrder(response.ids,
                                   newestID: desired && likes.contains(track.id) ? track.id : nil)
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
            favoriteOrder = beforeOrder
            favoriteTrackDetails = beforeDetails
            persistFavoriteTrackDetails()
            saveFavoriteOrder()
            saveSessionSnapshot()
            self.error = "Не удалось проверить избранное. Проверьте подключение и повторите."
        }
    }
    private func playlistCacheKey(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        // The server may be unavailable at startup, so reading on-device
        // playlists must not depend on an authenticated session response.
        let owner = account?.id ?? UserDefaults.standard.data(forKey: "native.account")
            .flatMap { try? JSONDecoder().decode(Account.self, from: $0).id }
        guard let owner else { return nil }
        return "nw-session-v1-" + (origin.host ?? "server") + "-" + owner + "-playlist-" + id
    }

    func cachedPlaylistTracks(_ id: String) -> [Track]? {
        guard let key = playlistCacheKey(id),
              let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([Track].self, from: data)
    }

    private func persistPlaylistTracks(_ tracks: [Track], playlist id: String) {
        guard let key = playlistCacheKey(id),
              let data = try? JSONEncoder().encode(tracks),
              data.count < 3_500_000 else { return }
        UserDefaults.standard.set(data, forKey: key)
        librarySearchIndexScope = ""
        if screen == .search { ensureLibrarySearchIndex() }
    }

    func playlistTracks(_ id: String) async throws -> [Track] {
        let key = playlistCacheKey(id)
        do {
            let value: TrackResult = try await api.request("/api/playlists/" + id + "/tracks", timeout: 10)
            if key != nil { persistPlaylistTracks(value.tracks, playlist: id) }
            return value.tracks
        } catch {
            if key != nil, let saved = cachedPlaylistTracks(id) {
                return saved
            }
            throw error
        }
    }
    func createPlaylist(_ name: String) async {
        do {
            let created: Playlist = try await api.request("/api/playlists", method: "POST", body: ["name": name])
            playlists.append(created)
            librarySearchIndexScope = ""
            saveSessionSnapshot()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func deletePlaylist(_ id: String) async {
        do {
            let _: OK = try await api.request("/api/playlists/" + id, method: "DELETE")
            playlists.removeAll { $0.id == id }
            librarySearchIndexScope = ""
            if let key = playlistCacheKey(id) { UserDefaults.standard.removeObject(forKey: key) }
            saveSessionSnapshot()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func add(_ track: Track, playlist: Playlist, remove: Bool = false) async {
        do {
            let _: OK = try await api.request("/api/playlists/" + playlist.id + "/tracks/" + track.id,
                                              method: remove ? "DELETE" : "POST")
            if var cached = cachedPlaylistTracks(playlist.id) {
                cached.removeAll { $0.id == track.id }
                if !remove { cached.append(track) }
                persistPlaylistTracks(cached, playlist: playlist.id)
            }
        } catch { self.error = error.localizedDescription }
    }
    func share(kind: String, playlist: String = "", title: String = "", tracks: [Track] = []) async -> String? {
        // Prefer an actual hosted collection link if the current server supports it.
        // Older Nightwell servers do not expose /api/shares at all: fall back to
        // a real shareable text list, not an invented or broken URL.
        if account != nil {
            do {
                let response: ShareResult = try await api.request(
                    "/api/shares", method: "POST",
                    body: ["kind": kind, "playlist_id": playlist])
                let path = response.path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, !path.contains("\n"),
                   let link = URL(string: path, relativeTo: origin)?.absoluteURL,
                   link.scheme == "https", link.host == origin.host {
                    return link.absoluteString
                }
            } catch {
                // Continue with a usable collection export if sharing is not deployed.
            }
        }
        var entries = tracks
        if kind == "playlist" && !playlist.isEmpty && entries.isEmpty {
            entries = (try? await playlistTracks(playlist)) ?? []
        } else if kind == "likes" && entries.isEmpty {
            entries = catalog.filter { likes.contains($0.id) }
        }
        let header = title.isEmpty ? (kind == "likes" ? "Избранное Nightwell Music" : "Плейлист Nightwell Music") : title
        guard !entries.isEmpty else {
            self.error = "Не получилось получить треки для отправки. Проверь подключение и повтори."
            return nil
        }
        var lines = ["🎵 " + header, "Nightwell Music", ""]
        for (index, track) in entries.prefix(300).enumerated() {
            lines.append("\(index + 1). \(track.artist) — \(track.title)")
        }
        if entries.count > 300 { lines.append("И ещё \(entries.count - 300) треков") }
        return lines.joined(separator: "\n")
    }
    func refreshOffline() async {
        let server = origin
        let value = await Task.detached { try? OfflineStore.operation(["op": "listAll"], origin: server) }.value
        guard origin == server else { return }
        if let value {
            if let data = try? JSONSerialization.data(withJSONObject: value["tracks"] ?? []),
               let tracks = try? JSONDecoder().decode([Track].self, from: data) {
                offline = tracks
            }
            if let data = try? JSONSerialization.data(withJSONObject: value["damaged"] ?? []),
               let broken = try? JSONDecoder().decode([Track].self, from: data) {
                damagedOffline = broken
            }
        }
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
    func repairDamagedDownloads() async {
        guard account != nil else { authPresented = true; return }
        let broken = damagedOffline.filter { !$0.id.hasPrefix("local_") }
        guard !broken.isEmpty else {
            error = "Повреждённые локальные файлы нужно импортировать заново из «Файлов»."
            return
        }
        await download(broken)
    }
    func downloadProgress(_ id: String) -> Double? {
        guard let account else { return nil }
        return downloadFractions[origin.absoluteString + "|" + account.id + "|" + id]
    }
    func isDownloaded(_ track: Track) -> Bool {
        if offline.contains(where: { $0.id == track.id }) { return true }
        guard track._offline == true else { return false }
        let owner = track._offline_account ?? account?.id ?? "device"
        return OfflineStore.audio(origin: origin, account: owner, id: track.id) != nil
    }
    func removeDownload(_ track: Track) async {
        let owner = track._offline_account ?? account?.id ?? "device"
        let server = origin
        do {
            _ = try await Task.detached {
                try OfflineStore.operation(["op": "remove", "account": owner, "id": track.id], origin: server)
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
        NativePlayer.shared.stop(); preloadTask?.cancel(); preloadTask = nil; lastPreloadIDs = []; lastPreloadAt = .distantPast; leaveSearch(); catalog = []; results = []; artistResults = []; playlists = []; likes = []; account = nil; profileNickname = ""; profileAvatar = nil; searchCache = [:]; artistSearchCache = [:]
        sessionGeneration = UUID(); starting = false; snapshotSaveTask?.cancel(); libraryRefresh.cancel(); connectionCheck?.cancel(); connectionCheck = nil; connectionCheckGeneration = UUID(); sessionReady = false
        stopLiveSync()
        origin = url; api = MusicAPI(origin: url); lastWave = []; restoreAutoFavoritesSetting(); cacheAccount(); await api.setCSRF(nil); UserDefaults.standard.set(url.absoluteString, forKey: "nightwell.server"); await start()
    }
}




