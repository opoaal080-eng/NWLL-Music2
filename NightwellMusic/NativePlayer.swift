import AVFoundation
import MediaPlayer
import UIKit

struct NativeTrack {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let cover: String?
    let source: String?
    let sourceURL: String?
    let remote: Bool
    var offline: Bool = false
    var offlineAccount: String = ""
    var offlineLyrics: [String: Any]? = nil
}

// Retry activation when iOS makes this playback session eligible for Now Playing.
private final class NowPlayingEligibilityDelegate: NSObject, MPNowPlayingSessionDelegate {
    var eligibilityChanged: (() -> Void)?
    func nowPlayingSessionDidChangeCanBecomeActive(_ nowPlayingSession: MPNowPlayingSession) {
        DispatchQueue.main.async { [weak self] in self?.eligibilityChanged?() }
    }
}

// All state changes and AVPlayer commands run on the main thread.
final class NativePlayer {
    static let shared = NativePlayer()
    let player = AVPlayer()
    private var nextAsset: AVURLAsset?
    private var nextAssetID: String?
    private lazy var nowPlayingSession = MPNowPlayingSession(players: [player])
    private let nowPlayingEligibility = NowPlayingEligibilityDelegate()
    private var activatingNowPlaying = false
    private var audioMeter = LocalAudioMeter()
    private let enginePlayback = NativeEQPlayback()
    private var eqDownload: EnvelopeDownload?
    private var eqRequested = false
    private var eqGeneration = UUID()
    private var eqAttempted = false
    private var eqBands = [Double](repeating: 0, count: 5)
    private var eqExpiry = 0.0
    private var engineTimer: Timer?
    private(set) var premiumSoundStatus = "Запустите трек и выберите пресет."
    private var playbackPosition: Double { enginePlayback.ready ? enginePlayback.position : player.currentTime().seconds }
    private var audible: Bool { enginePlayback.ready ? enginePlayback.playing : player.timeControlStatus == .playing }
    private let independentMeter = IndependentAudioMeter()
    private var usesLiveMeter = true
    var onChange: (() -> Void)?
    private(set) var origin: URL?
    private var tracks: [NativeTrack] = []
    private(set) var queueRevision = 0
    private var appIsActive = UIApplication.shared.applicationState == .active
    private var offlineAccount = ""
    private var index = 0
    private var cookies: [HTTPCookie] = []
    private var requestedPosition = 0.0
    private var waitingForReady = false
    private var wantsPlay = false
    private var ended = false
    private var repeatMode = 0
    private var shuffle = false
    private var error = ""
    private var waveSettings = WaveSettings()
    private var waveActive = false
    private var waveSeen: [String] = []
    private var waveTask: URLSessionDataTask?
    private var waveGeneration = UUID()
    private var waveRetryAt = Date.distantPast
    private var waveWaiting = false
    private var waveTimer: Timer?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var stallCheck: DispatchWorkItem?
    private let recovery = PlaybackRecovery()
    private var lastPosition = 0.0
    private var fadeObserver: Any?
    private var baseVolume: Float = 1
    private var transitionSeconds = UserDefaults.standard.object(forKey: "nw-transition-seconds") == nil ? 0.8 : UserDefaults.standard.double(forKey: "nw-transition-seconds")
    private var fadeInActive = false
    private var fadeNextAutomatically = false
    private var timeObserver: Any?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: URLSessionDataTask?
    private var itemGeneration = UUID()
    private var seekGeneration = UUID()
    private var resumeAfterInterruption = false
    private var observers: [NSObjectProtocol] = []
    private var current: NativeTrack? { tracks.indices.contains(index) ? tracks[index] : nil }

    private init() {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio) }
        catch { self.error = "Не удалось настроить звук." }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            if let self, !self.waitingForReady, self.player.currentItem?.status == .readyToPlay {
                let position = self.playbackPosition
                if position.isFinite { self.lastPosition = max(0, position) }
            }
            self?.refreshIndependentMeter(); self?.refillWave(); self?.publish()
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.appIsActive = true; self?.refreshIndependentMeter(); self?.publish()
            })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.appIsActive = false; self?.independentMeter.cancel(keepingEnvelope: true); self?.publish()
            })
        fadeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.04, preferredTimescale: 600), queue: .main) { [weak self] _ in self?.updateFade() }
        nowPlayingSession.automaticallyPublishesNowPlayingInfo = false
        nowPlayingEligibility.eligibilityChanged = { [weak self] in self?.activateNowPlayingSession() }
        nowPlayingSession.delegate = nowPlayingEligibility
        let center = nowPlayingSession.remoteCommandCenter
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.playCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.wantsPlay ? self.pause() : self.play() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.step(1) }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in DispatchQueue.main.async { self?.step(-1) }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async { self?.seek(event.positionTime) }; return .success
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in self?.interruption(note) })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
                self?.routeChanged(note)
            })
        waveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refillWave() }
        enginePlayback.onEnd = { [weak self] in self?.finishTrack() }
        engineTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.enginePlayback.apply()
            if self.enginePlayback.ready {
                self.lastPosition = self.enginePlayback.position
                self.updateFade(); self.refillWave(); self.refreshIndependentMeter(); self.publish()
            }
        }
        publish()
    }

    func prepare(_ data: [String: Any], origin: URL, cookies: [HTTPCookie]) {
        guard let raw = data["queue"] as? [[String: Any]], let selected = data["id"] as? String else { return }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let queue = raw.prefix(1000).compactMap { item -> NativeTrack? in
            guard let id = item["id"] as? String, !id.isEmpty,
                  id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            return NativeTrack(id: id, title: item["title"] as? String ?? "",
                artist: item["artist"] as? String ?? "", album: item["album"] as? String ?? "",
                duration: (item["duration"] as? NSNumber)?.doubleValue ?? 0, cover: item["cover_url"] as? String, source: item["source"] as? String,
                sourceURL: item["source_url"] as? String, remote: item["is_remote"] as? Bool ?? false, offline: item["_offline"] as? Bool ?? false, offlineAccount: item["_offline_account"] as? String ?? "", offlineLyrics: item["_offline_lyrics"] as? [String: Any])
        }
        fadeInActive = false; fadeNextAutomatically = false
        guard let selectedIndex = queue.firstIndex(where: { $0.id == selected }) else { return }
        self.offlineAccount = data["account"] as? String ?? ""
        let previousOrigin = self.origin
        self.origin = origin
        self.cookies = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let host = origin.host?.lowercased() ?? ""
            return (host == domain || host.hasSuffix("." + domain)) && (cookie.expiresDate ?? .distantFuture) > Date()
        }
        let nextWave = data["wave"] as? Bool ?? false
        if !waveActive || !nextWave || previousOrigin != origin { waveSeen = [] }
        waveTask?.cancel(); waveTask = nil; waveGeneration = UUID()
        waveSettings = WaveSettings(data["wave_preferences"] as? [String: Any] ?? [:])
        waveActive = nextWave; waveWaiting = false; waveRetryAt = .distantPast
        tracks = queue; queueRevision += 1; index = selectedIndex; wantsPlay = false
        load(position: max(0, ((data["position"] as? NSNumber)?.doubleValue ?? 0) / 1000))
    }

    private func prewarmNextAsset() {
        guard !shuffle, !waveWaiting, index + 1 < tracks.count, let origin else {
            nextAsset = nil; nextAssetID = nil; return
        }
        let next = tracks[index + 1]
        guard nextAssetID != next.id else { return }
        let saved = OfflineStore.audio(origin: origin,
            account: next.offlineAccount.isEmpty ? offlineAccount : next.offlineAccount, id: next.id)
        guard !next.offline || saved != nil,
              let url = saved ?? URL(string: "api/stream/" + next.id + "?cache=1&format=" +
                  (next.remote || next.source == "soundcloud" ? "hls" : "file"),
                  relativeTo: origin)?.absoluteURL else { return }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
        nextAsset = asset; nextAssetID = next.id
        // Only warm metadata for one imminent track, never download the whole queue.
        Task(priority: .utility) { let _ = try? await asset.load(.isPlayable) }
    }

    private func load(position: Double = 0, recovering: Bool = false) {
        if !recovering { recovery.cancel(resetBudget: true); independentMeter.cancel(); resumeAfterInterruption = false }
        eqGeneration = UUID(); eqDownload?.cancel(); eqDownload = nil; eqAttempted = false; enginePlayback.stop()
        stallCheck?.cancel(); stallCheck = nil
        itemGeneration = UUID(); let generation = itemGeneration
        guard let current, let origin else { return }
        let saved = OfflineStore.audio(origin: origin, account: current.offlineAccount.isEmpty ? offlineAccount : current.offlineAccount, id: current.id)
        if current.offline && saved == nil {
            itemObservation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
            if let failureObserver { NotificationCenter.default.removeObserver(failureObserver); self.failureObserver = nil }
            artworkTask?.cancel(); audioMeter = LocalAudioMeter()
            player.pause(); player.replaceCurrentItem(with: nil)
            wantsPlay = false; waitingForReady = false; requestedPosition = max(0, position); lastPosition = requestedPosition
            error = "Офлайн-файл не найден. Скачай трек заново."; publish(); return
        }
        guard let url = saved ?? URL(string: "api/stream/" + current.id + "?cache=1&format=" + (current.remote || current.source == "soundcloud" ? "hls" : "file"), relativeTo: origin)?.absoluteURL else { return }
        if waveActive && !recovering { waveSeen.append(current.id); waveSeen = Array(waveSeen.suffix(120)) }
        fadeInActive = fadeNextAutomatically && transitionSeconds > 0; fadeNextAutomatically = false
        player.volume = fadeInActive ? 0 : baseVolume
        requestedPosition = position; lastPosition = position; waitingForReady = true
        ended = false; error = ""; artworkTask?.cancel(); artwork = makeArtwork(placeholder())
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver); self.stallObserver = nil }
        itemObservation = nil
        let asset = nextAssetID == current.id && nextAsset?.url == url
            ? nextAsset! : AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
        nextAsset = nil; nextAssetID = nil
        let item = AVPlayerItem(asset: asset)
        // Keep a useful forward buffer, but do not wait to fill it before starting.
        item.preferredForwardBufferDuration = 12
        audioMeter = LocalAudioMeter()
        configureAudioMeter(for: item)
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.itemGeneration == generation else { return }
                if item.status == .readyToPlay {
                    // Start fallback envelope preparation as soon as the stream is ready.
                    // It runs independently from playback and must never block the first samples.
                    if self.wantsPlay && !self.usesLiveMeter { self.refreshIndependentMeter() }
                    self.prewarmNextAsset()
                    let length = item.duration.seconds
                    let target = length.isFinite && self.requestedPosition >= length ? 0 : self.requestedPosition
                    self.requestedPosition = target; self.lastPosition = target
                    if target <= 0 {
                        self.waitingForReady = false
                        if self.wantsPlay { self.player.playImmediately(atRate: 1) }
                        self.publish(); return
                    }
                    self.seekCurrentItem(to: target)
                } else if item.status == .failed {
                    self.playbackFailed(item.error, generation: generation)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                guard let self, self.itemGeneration == generation else { return }
                if !self.enginePlayback.ready { self.finishTrack() }
            }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main) { [weak self] note in
                self?.playbackFailed(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? item.error, generation: generation)
            }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled,
            object: item, queue: .main) { [weak self] _ in
                guard let self, self.wantsPlay, self.itemGeneration == generation else { return }
                self.stallCheck?.cancel()
                let stalledAt = self.player.currentTime().seconds
                let check = DispatchWorkItem { [weak self] in
                    guard let self, self.wantsPlay, self.itemGeneration == generation,
                          self.player.currentItem === item else { return }
                    let now = self.player.currentTime().seconds
                    if self.player.timeControlStatus != .playing &&
                       (!now.isFinite || !stalledAt.isFinite || now - stalledAt < 0.5) {
                        self.playbackFailed(URLError(.networkConnectionLost), generation: generation)
                    }
                }
                self.stallCheck = check
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: check)
            }
        prepareEqualizerPlayback(); fetchArtwork(current, generation: generation); publish()
    }

    private func playbackFailed(_ failure: Error?, generation: UUID) {
        guard generation == itemGeneration, !enginePlayback.ready else { return }
        if !waitingForReady {
            let position = playbackPosition
            if position.isFinite { lastPosition = max(0, position) }
        }
        requestedPosition = lastPosition; waitingForReady = false
        player.pause()
        if wantsPlay, current?.offline != true, PlaybackRecovery.isTransient(failure),
           recovery.schedule({ [weak self] in
               guard let self, self.wantsPlay, self.itemGeneration == generation else { return }
               self.load(position: self.requestedPosition, recovering: true)
           }) {
            error = "Восстанавливаем подключение…"
        } else {
            recovery.cancel(); wantsPlay = false
            error = "Трек недоступен. Проверь подключение и нажми Play."
        }
        publish()
    }

    func play() {
        guard current != nil else { return }
        if enginePlayback.ready {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try enginePlayback.play()
                resumeAfterInterruption = false
                wantsPlay = true; ended = false; error = ""
                player.isMuted = true; player.playImmediately(atRate: 1)
                updateFade(); publish(); return
            } catch { fallbackFromEngine() }
        }
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || session.mode != .default || session.routeSharingPolicy != .longFormAudio {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            }
            try session.setActive(true)
            if let item = player.currentItem { configureAudioMeter(for: item) }
        }
        catch { wantsPlay = false; self.error = "Не удалось включить аудиосессию."; publish(); return }
        let rebuild = player.currentItem == nil || player.currentItem?.status == .failed || recovery.pending || !error.isEmpty
        recovery.cancel(resetBudget: true)
        resumeAfterInterruption = false
        wantsPlay = true; ended = false; error = ""
        if rebuild { load(position: lastPosition) }
        guard wantsPlay else { return }
        updateFade()
        if !waitingForReady { player.playImmediately(atRate: 1) }
        refillWave(); publish()
    }
    func pause() { resumeAfterInterruption = false; recovery.cancel(); independentMeter.cancel(keepingEnvelope: true); wantsPlay = false; waveWaiting = false; enginePlayback.pause(); player.pause(); publish() }
    func stop() {
        waveActive = false; waveTask?.cancel(); waveTask = nil; waveGeneration = UUID(); waveSeen = []
        pause(); stallCheck?.cancel(); stallCheck = nil; itemGeneration = UUID(); itemObservation = nil; artworkTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver); self.failureObserver = nil }
        independentMeter.cancel()
        eqGeneration = UUID(); eqDownload?.cancel(); eqDownload = nil; enginePlayback.stop(); player.isMuted = false
        tracks = []; waitingForReady = false; requestedPosition = 0; lastPosition = 0; error = ""
        queueRevision += 1; player.replaceCurrentItem(with: nil); publish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        fadeInActive = false; fadeNextAutomatically = false; player.volume = baseVolume
        ended = false; requestedPosition = max(0, seconds); lastPosition = requestedPosition
        if enginePlayback.ready {
            do { try enginePlayback.seek(requestedPosition, playing: wantsPlay) }
            catch { fallbackFromEngine() }
        }
        if wantsPlay && (recovery.pending || player.currentItem?.status == .failed) {
            recovery.cancel(resetBudget: true); load(position: requestedPosition); return
        }
        if player.currentItem?.status != .readyToPlay { publish(); return }
        seekCurrentItem(to: requestedPosition)
    }
    private func seekCurrentItem(to seconds: Double) {
        let item = itemGeneration; seekGeneration = UUID(); let seek = seekGeneration
        waitingForReady = true
        // Small tolerance lets the streaming decoder seek to nearby buffered samples.
        // Keep exact seeks for downloaded local files.
        let tolerance = current?.offline == true ? CMTime.zero : CMTime(seconds: 0.15, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.itemGeneration == item, self.seekGeneration == seek else { return }
                    self.waitingForReady = false
                    if self.wantsPlay && self.player.currentItem?.status == .readyToPlay { self.player.playImmediately(atRate: 1) }
                    self.publish()
                }
            }
    }
    func volume(_ value: Double) { if value.isFinite { baseVolume = Float(max(0, min(1, value))); updateFade() } }
    func transitionDuration(_ value: Double) {
        guard value.isFinite else { return }
        transitionSeconds = max(0, min(5, value))
        UserDefaults.standard.set(transitionSeconds, forKey: "nw-transition-seconds")
        updateFade(); publish()
    }
    private func updateFade() {
        defer {
            if enginePlayback.ready { enginePlayback.volume = player.volume; player.isMuted = true }
            else { player.isMuted = false }
        }
        guard transitionSeconds > 0 else { fadeInActive = false; player.volume = baseVolume; return }
        guard wantsPlay, !waitingForReady else { player.volume = fadeInActive ? 0 : baseVolume; return }
        let position = playbackPosition
        let duration = player.currentItem?.duration.seconds ?? .nan
        guard position.isFinite else { return }
        let known = duration.isFinite && duration > 0.2
        let span = known ? min(transitionSeconds, duration / 4) : transitionSeconds
        if fadeInActive && position >= span { fadeInActive = false }
        let hasNext = repeatMode != 0 || waveActive || index + 1 < tracks.count || (shuffle && tracks.count > 1)
        let entry = fadeInActive ? max(0, min(1, position / span)) : 1
        let exit = known && hasNext ? max(0, min(1, (duration - position) / span)) : 1
        player.volume = baseVolume * Float(min(entry, exit))
    }
    deinit { if let fadeObserver { player.removeTimeObserver(fadeObserver) } }

    func modes(repeatMode: Int, shuffle: Bool) { self.repeatMode = max(0, min(2, repeatMode)); self.shuffle = shuffle; publish() }
    private var previousRestartTrackID: String?
    private var previousRestartAt: TimeInterval = -Double.infinity
    func step(_ direction: Int) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let repeated = previousRestartTrackID == tracks[index].id && now - previousRestartAt < 3
        let position = playbackPosition
        if direction < 0 && !repeated && position.isFinite && position > 3 {
            previousRestartTrackID = tracks[index].id
            previousRestartAt = now
            seek(0)
            return
        }
        previousRestartTrackID = nil; previousRestartAt = -Double.infinity
        if waveActive && direction > 0 && index + 1 >= tracks.count {
            recovery.cancel(resetBudget: true); independentMeter.cancel(keepingEnvelope: true); resumeAfterInterruption = false
            wantsPlay = true; waveWaiting = true; enginePlayback.pause(); player.pause(); refillWave(force: true); publish(); return
        }
        if shuffle && direction > 0 && tracks.count > 1 {
            let choices = waveActive ? tracks.indices.filter { $0 > index } : tracks.indices.filter { $0 != index }
            index = choices.randomElement() ?? index
        } else { index = (index + direction + tracks.count) % tracks.count }
        load(); play()
    }
    private func restartSmoothly() {
        if enginePlayback.ready { seek(0); return }
        fadeInActive = transitionSeconds > 0; requestedPosition = 0; lastPosition = 0; ended = false; player.volume = fadeInActive ? 0 : baseVolume
        seekCurrentItem(to: 0)
    }
    private func finishTrack() {
        if repeatMode == 2 { restartSmoothly() }
        else if waveActive && index + 1 >= tracks.count {
            fadeNextAutomatically = true
            waveWaiting = true; enginePlayback.pause(); player.pause(); refillWave(force: true); publish()
        }
        else if shuffle || index + 1 < tracks.count || repeatMode == 1 { fadeNextAutomatically = true; step(1) }
        else { ended = true; pause() }
    }
    private func refillWave(force: Bool = false) {
        guard waveActive, wantsPlay, waveTask == nil, let origin, current != nil,
              Date() >= waveRetryAt, force || tracks.count - index - 1 <= 8 else { return }
        var excluded = waveSeen
        excluded.append(contentsOf: tracks.dropFirst(index).map { $0.id })
        var seen = Set<String>()
        excluded = excluded.filter { seen.insert($0).inserted }
        guard let base = URL(string: "api/wave", relativeTo: origin)?.absoluteURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "exclude", value: Array(excluded.suffix(200)).joined(separator: ","))] + WaveSettings.keys.map { URLQueryItem(name: $0, value: waveSettings.dictionary[$0]) }
        guard let url = components.url else { return }
        var request = URLRequest(url: url); request.timeoutInterval = 60
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        let generation = waveGeneration
        waveTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async {
                guard let self, self.waveGeneration == generation, self.waveActive else { return }
                self.waveTask = nil; self.waveRetryAt = Date().addingTimeInterval(5)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let data, data.count <= 2 * 1024 * 1024, let raw = json?["tracks"] as? [[String: Any]] else {
                    self.error = "Не удалось пополнить волну. Повторим запрос."; self.publish(); return
                }
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
                let waiting = Set(self.tracks.dropFirst(self.index).map { $0.id })
                var added = Set<String>()
                let fresh = raw.prefix(20).compactMap { item -> NativeTrack? in
                    guard let id = item["id"] as? String, !id.isEmpty, id.count <= 80,
                          id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                          !waiting.contains(id), !self.waveSeen.contains(id), added.insert(id).inserted else { return nil }
                    return NativeTrack(id: id, title: item["title"] as? String ?? "",
                        artist: item["artist"] as? String ?? "", album: item["album"] as? String ?? "",
                        duration: (item["duration"] as? NSNumber)?.doubleValue ?? 0, cover: item["cover_url"] as? String, source: item["source"] as? String,
                sourceURL: item["source_url"] as? String, remote: item["is_remote"] as? Bool ?? false, offline: item["_offline"] as? Bool ?? false, offlineAccount: item["_offline_account"] as? String ?? "", offlineLyrics: item["_offline_lyrics"] as? [String: Any])
                }
                if fresh.isEmpty {
                    self.error = json?["message"] as? String ?? "Новые треки пока не найдены."; self.publish(); return
                }
                self.error = ""; self.waveRetryAt = Date().addingTimeInterval(30)
                let removeCount = max(0, self.index - 5)
                if removeCount > 0 { self.tracks.removeFirst(removeCount); self.index -= removeCount }
                let ordered = RecommendationOrder.arrange(fresh, current: self.current?.id ?? "", identity: { $0.id }, title: { $0.title }, artist: { $0.artist })
                self.tracks.append(contentsOf: ordered); self.queueRevision += 1
                if self.waveWaiting && self.wantsPlay { self.waveWaiting = false; self.step(1) }
                self.publish()
            }
        }
        waveTask?.resume()
    }
    func setPremiumSound(_ values: [Double], until: Double) {
        eqBands = values; eqExpiry = until
        eqRequested = Date().timeIntervalSince1970 < until
        enginePlayback.set(values, until: until)
        // The tap only measures aura. EQ is applied once in the audible engine.
        audioMeter.equalizer.set([0,0,0,0,0], until: 0)
        if eqRequested { prepareEqualizerPlayback() }
        else { eqGeneration = UUID(); eqDownload?.cancel(); eqDownload = nil; eqAttempted = false }
    }
    var premiumSoundAvailable: Bool { enginePlayback.ready }
    private func prepareEqualizerPlayback() {
        guard eqRequested, !eqAttempted, let current, let origin else { return }
        eqAttempted = true
        let requestGeneration = eqGeneration
        let generation = itemGeneration
        let local = OfflineStore.audio(origin: origin, account: current.offlineAccount.isEmpty ? offlineAccount : current.offlineAccount, id: current.id)
        if let local { activateEqualizerFile(local, temporary: false, generation: generation); return }
        premiumSoundStatus = "Готовим аудиофайл для эквалайзера. Музыка продолжает играть."
        var request = URLRequest(url: origin.appendingPathComponent("api/offline-export/" + current.id))
        request.url = URL(string: "api/offline-export/" + current.id + "?download=true&wait=true", relativeTo: origin)
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        let download = EnvelopeDownload(origin: origin)
        eqDownload = download
        download.start(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.itemGeneration == generation, self.eqGeneration == requestGeneration, self.eqRequested else {
                    if case let .success(file) = result { try? FileManager.default.removeItem(at: file) }
                    return
                }
                self.eqDownload = nil
                switch result {
                case let .success(file): self.activateEqualizerFile(file, temporary: true, generation: generation)
                case .failure: self.premiumSoundStatus = "Не удалось подготовить файл для EQ. Повторите выбор пресета или включите другой трек."; self.eqAttempted = false
                }
            }
        }
    }
    private func activateEqualizerFile(_ file: URL, temporary: Bool, generation: UUID) {
        guard itemGeneration == generation else { if temporary { try? FileManager.default.removeItem(at: file) }; return }
        let position = waitingForReady ? requestedPosition : playbackPosition
        player.isMuted = true
        do {
            try enginePlayback.load(file, temporary: temporary, position: position.isFinite ? position : lastPosition, playing: wantsPlay)
            enginePlayback.set(eqBands, until: eqExpiry)
            player.isMuted = true
            waitingForReady = false
            premiumSoundStatus = "Эквалайзер подключён к аудиовыходу."
            updateFade(); publish()
        } catch {
            if temporary { try? FileManager.default.removeItem(at: file) }
            player.isMuted = false
            premiumSoundStatus = "Формат этого файла не поддерживает EQ. Музыка играет без обработки."
        }
    }
    private func fallbackFromEngine() {
        let position = enginePlayback.position
        enginePlayback.stop(); player.isMuted = false
        premiumSoundStatus = "Аудиовыход изменился. Музыка играет без EQ."
        seekCurrentItem(to: position)
    }
    private func configureAudioMeter(for item: AVPlayerItem) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        usesLiveMeter = AudioOutputPolicy.usesAudioTap(outputs)
        if !usesLiveMeter {
            audioMeter.detach(from: item)
        } else if !audioMeter.attached {
            audioMeter.attach(to: item)
        }
    }
    private func refreshIndependentMeter() {
        guard appIsActive, (audible || wantsPlay),
              let current, let origin, !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty else { return }
        // Live taps can take a moment to start, but avoid downloading a second
        // copy of the track once live PCM analysis is already available.
        if usesLiveMeter && audioMeter.processing { return }
        let key = origin.absoluteString + "|" + offlineAccount + "|" + current.offlineAccount + "|" + current.id
        guard independentMeter.needsPreparation(for: key) else { return }
        let local = OfflineStore.audio(origin: origin, account: current.offlineAccount.isEmpty ? offlineAccount : current.offlineAccount, id: current.id)
        var request = URLRequest(url: origin.appendingPathComponent("api/offline-export/" + current.id))
        request.url = URL(string: "api/offline-export/" + current.id + "?download=true&wait=true", relativeTo: origin)
        request.timeoutInterval = 90
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        independentMeter.prepare(key: key, local: local, request: request, origin: origin)
    }
    private func routeChanged(_ note: Notification) {
        if let item = player.currentItem { configureAudioMeter(for: item) }
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { publish(); return }
        // Disconnecting headphones still pauses, so audio cannot unexpectedly
        // start on the iPhone speaker. A route change never starts paused music.
        if reason == .oldDeviceUnavailable {
            // Compare the previous output against the new output. Only pause when
            // personal listening ends on the built-in speaker/receiver.
            let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .outputs.map { $0.portType } ?? []
            let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
            let wasHeadphones = previous.contains { headphonePorts.contains($0) }
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType }
            let nowOnSpeaker = outputs.contains(.builtInSpeaker) || outputs.contains(.builtInReceiver)
            if wasHeadphones && nowOnSpeaker {
                pause()
                return
            }
        }
        if enginePlayback.ready {
            do { try enginePlayback.rebuild(playing: wantsPlay) }
            catch { fallbackFromEngine() }
            publish(); return
        }
        if reason == .oldDeviceUnavailable && !wantsPlay { return }
        if wantsPlay && !waitingForReady && !recovery.pending && player.currentItem?.status == .readyToPlay {
            switch reason {
            case .newDeviceAvailable, .override, .routeConfigurationChange:
                player.playImmediately(atRate: 1)
            default: break
            }
        }
        publish()
    }
    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            let resume = wantsPlay || resumeAfterInterruption
            pause(); resumeAfterInterruption = resume
        }
        else {
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) { play() }
            resumeAfterInterruption = false
        }
    }
    private func fetchArtwork(_ track: NativeTrack, generation: UUID) {
        if let cover = track.cover, cover.hasPrefix("data:image/"), let comma = cover.firstIndex(of: ","),
           let data = Data(base64Encoded: String(cover[cover.index(after: comma)...])), data.count < 2 * 1024 * 1024, let image = UIImage(data: data) {
            artwork = makeArtwork(image); publish(); return
        }
        guard let origin, let cover = track.cover, let url = URL(string: cover, relativeTo: origin)?.absoluteURL,
              ServerAddress.sameOrigin(origin, url), url.path.hasPrefix("/api/covers/") else { return }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        artworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data, data.count <= 6 * 1024 * 1024,
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.itemGeneration == generation else { return }
                self.artwork = self.makeArtwork(image); self.publish()
            }
        }
        artworkTask?.resume()
    }
    private func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    private func placeholder() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
            UIColor(red: 0.12, green: 0.08, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 150),
                .foregroundColor: UIColor(red: 0.73, green: 0.6, blue: 1, alpha: 1)]
            let label = NSAttributedString(string: "NW", attributes: attrs)
            let size = label.size(); label.draw(at: CGPoint(x: (512-size.width)/2, y: (512-size.height)/2))
        }
    }
    func auraLevels() -> [Double] {
        let playing = audible
        if usesLiveMeter && audioMeter.processing { return audioMeter.frequencyLevels(playing: playing) }
        let fallback = independentMeter.level(at: playbackPosition, playing: playing)
        return [fallback, fallback, fallback, fallback]
    }
    func audioLevel() -> Double {
        let playing = audible
        return usesLiveMeter && audioMeter.processing ? audioMeter.level(playing: playing) : independentMeter.level(at: playbackPosition, playing: playing)
    }
    func meterState() -> [String: Any] {
        ["id": current?.id ?? "", "level": audioLevel(), "ready": (usesLiveMeter && audioMeter.processing) || independentMeter.envelope != nil]
    }
    func snapshot(includeQueue: Bool = true) -> [String: Any] {
        let duration = player.currentItem?.duration.seconds ?? 0
        let position = enginePlayback.ready ? enginePlayback.position : ((waitingForReady || player.currentItem?.status == .failed) ? requestedPosition : playbackPosition)
        return ["id": current?.id ?? "", "origin": origin?.absoluteString ?? "",
            "position": position.isFinite ? max(0, position) : 0.0,
            "duration": duration.isFinite ? max(0, duration) : (current?.duration ?? 0),
            "playing": wantsPlay, "audible": audible, "account": offlineAccount, "ended": ended, "repeat": repeatMode, "shuffle": shuffle,
            "volume": baseVolume, "smoothTransitions": true, "transitionSeconds": transitionSeconds, "queueRevision": queueRevision, "queueIds": includeQueue ? tracks.map { $0.id } : [], "error": error,
            "wave": waveActive, "waveSupported": true,
            "audioOutput": AVAudioSession.sharedInstance().currentRoute.outputs.map { ["type": $0.portType.rawValue, "name": $0.portName] },
            "audioTap": audioMeter.attached, "independentAuraReady": independentMeter.envelope != nil,
            "queueTracks": (includeQueue ? tracks : []).map { track -> [String: Any] in
                var item: [String: Any] = ["id": track.id, "title": track.title, "artist": track.artist,
                    "album": track.album, "duration": track.duration, "is_remote": track.remote]
                if let cover = track.cover { item["cover_url"] = cover }
                if let source = track.source { item["source"] = source }
                if let sourceURL = track.sourceURL { item["source_url"] = sourceURL }
                item["_offline"] = track.offline; item["_offline_account"] = track.offlineAccount
                if let lyrics = track.offlineLyrics { item["_offline_lyrics"] = lyrics }
                return item
            }]
    }
    // The same session owns this AVPlayer, its metadata and every remote command.
    // Retry only when the session becomes eligible; an activation callback never
    // starts another attempt when activation failed.
    private func activateNowPlayingSession() {
        guard current != nil, wantsPlay, !activatingNowPlaying,
              !nowPlayingSession.isActive, nowPlayingSession.canBecomeActive else { return }
        activatingNowPlaying = true
        nowPlayingSession.becomeActiveIfPossible { [weak self] activated in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activatingNowPlaying = false
                if activated, self.current != nil { self.publish() }
            }
        }
    }
    private func publish() {
        let commands = nowPlayingSession.remoteCommandCenter
        commands.nextTrackCommand.isEnabled = tracks.count > 1
        commands.previousTrackCommand.isEnabled = !tracks.isEmpty
        commands.playCommand.isEnabled = current != nil
        commands.pauseCommand.isEnabled = current != nil
        commands.togglePlayPauseCommand.isEnabled = current != nil
        commands.changePlaybackPositionCommand.isEnabled = current != nil
        if let current, !appIsActive {
            let state = snapshot(includeQueue: false)
            var info: [String: Any] = [MPMediaItemPropertyTitle: current.title,
                MPMediaItemPropertyArtist: current.artist, MPMediaItemPropertyAlbumTitle: current.album,
                MPMediaItemPropertyPlaybackDuration: state["duration"] ?? 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: state["position"] ?? 0,
                MPNowPlayingInfoPropertyPlaybackRate: audible ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
                MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
                MPNowPlayingInfoPropertyPlaybackQueueCount: tracks.count,
                MPNowPlayingInfoPropertyExternalContentIdentifier: current.id]
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = info
            activateNowPlayingSession()
        } else { nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = nil }
        onChange?()
    }
}





