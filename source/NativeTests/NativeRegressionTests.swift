import XCTest
import AVFoundation
@testable import NightwellMusic

private actor LyricsStub: LyricsService {
    let responses: [Lyrics]
    var calls = 0
    init(_ responses: [Lyrics]) { self.responses = responses }
    func fetchLyrics(_ id: String) async throws -> Lyrics { defer { calls += 1 }; return responses[min(calls, responses.count - 1)] }
    func count() -> Int { calls }
}
@MainActor final class NativeRegressionTests: XCTestCase {
    let origin = URL(string: "https://music.nightwell.fun/")!
    func track(_ id: String = "regression") -> Track { Track(id: id, title: "Song", artist: "Artist") }
    func waitForResult(_ model: NativeLyrics) async throws {
        for _ in 0..<100 {
            if model.value?.status == "found" { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Client stopped waiting before the lyrics search completed")
    }
    func testWaveSettingsAreValidatedAndScopedToAccount() {
        let account = "wave_test_" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: WaveSettings.key(origin, account)) }
        let settings = WaveSettings(["character": "discover", "mood": "calm", "language": "instrumental"])
        settings.save(origin, account)
        XCTAssertEqual(WaveSettings.read(origin, account), settings)
        XCTAssertEqual(WaveSettings.read(origin, account + "_other"), WaveSettings())
        XCTAssertEqual(WaveSettings(["character": "invalid&exclude=anything", "mood": "unknown", "language": "bad"]), WaveSettings())
        XCTAssertEqual(settings.query, "&character=discover&mood=calm&language=instrumental")
    }
    func testRecommendationDiversityKeepsRelevantLeaderAndRemovesDuplicates() {
        let candidates = [Track(id: "a", title: "First", artist: "A"), Track(id: "b", title: "Second", artist: "A"), Track(id: "duplicate", title: "First!", artist: "A"), Track(id: "c", title: "Third", artist: "B"), Track(id: "d", title: "Fourth", artist: "C")]
        let ranked = RecommendationOrder.arrange(candidates, identity: { $0.id }, title: { $0.title }, artist: { $0.artist })
        XCTAssertEqual(ranked.first?.id, "a")
        XCTAssertEqual(ranked.count, 4)
        XCTAssertNotEqual(ranked[0].artist, ranked[1].artist)
        let fresh = RecommendationOrder.arrange(candidates, recent: ["a"], current: "b", identity: { $0.id }, title: { $0.title }, artist: { $0.artist })
        XCTAssertFalse(fresh.contains { $0.id == "b" })
        XCTAssertNotEqual(fresh.first?.id, "a")
    }
    func testSharedTrackURLsValidateHostAndTrackID() {
        let id = "80adb8c0f574439fac645585493e955a"
        XCTAssertEqual(DeepLink.trackID(from: URL(string: "nightwell://track/" + id)!), id)
        XCTAssertEqual(DeepLink.trackID(from: URL(string: "https://music.nightwell.fun/track/" + id)!), id)
        XCTAssertNil(DeepLink.trackID(from: URL(string: "https://example.org/track/" + id)!))
        XCTAssertNil(DeepLink.trackID(from: URL(string: "nightwell://track/not-a-track")!))
        XCTAssertNil(DeepLink.trackID(from: URL(string: "https://music.nightwell.fun/track/" + id + "/extra")!))
    }
    func testServerLoadingResponseIsPolledUntilFound() async throws {
        let stub = LyricsStub([Lyrics(status: "loading", retry_after: 5), Lyrics(status: "found", plain: "available again", synced: false)])
        let model = NativeLyrics(cacheEnabled: false, sleep: { _ in await Task.yield() })
        model.select(track(), api: stub, origin: origin, online: true)
        try await waitForResult(model)
        let count = await stub.count(); XCTAssertEqual(count, 2)
        XCTAssertEqual(model.value?.plain, "available again")
    }
    func testTemporaryProviderFailureIsRetried() async throws {
        let stub = LyricsStub([Lyrics(status: "unavailable", retry_after: 60), Lyrics(status: "found", lines: [.init(time: 10, text: "line")], synced: true)])
        let model = NativeLyrics(cacheEnabled: false, sleep: { _ in await Task.yield() })
        model.select(track(), api: stub, origin: origin, online: true)
        try await waitForResult(model)
        XCTAssertEqual(model.value?.synced, true)
        let count = await stub.count(); XCTAssertEqual(count, 2)
    }
    func testNewTrackCancelsPreviousLyrics() async throws {
        let first = LyricsStub([Lyrics(status: "loading", retry_after: 5)])
        let second = LyricsStub([Lyrics(status: "found", plain: "second")])
        let model = NativeLyrics(cacheEnabled: false)
        model.select(track("first"), api: first, origin: origin, online: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        model.select(track("second"), api: second, origin: origin, online: true)
        try await waitForResult(model)
        XCTAssertEqual(model.trackID, "second"); XCTAssertEqual(model.value?.plain, "second")
    }
    func testPlayerQueueRetainsDownloadedLyricsMetadata() throws {
        let player = NativePlayer.shared
        defer { player.stop() }
        var saved = track("saved_snapshot"); saved._offline = true
        saved._offline_lyrics = Lyrics(status: "found", plain: "saved metadata", synced: false)
        player.prepare(["id": saved.id, "queue": [saved.dictionary], "account": "device"], origin: origin, cookies: [])
        let raw = try XCTUnwrap(player.snapshot()["queueTracks"] as? [[String: Any]])
        let decoded = try JSONDecoder().decode([Track].self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(decoded.first?._offline_lyrics?.plain, "saved metadata")
    }
    func testLegacyDownloadedLyricsRemainAvailableWithoutLogin() async throws {
        let stub = LyricsStub([Lyrics(status: "not_found")])
        var saved = track("saved_song"); saved._offline = true
        saved._offline_lyrics = Lyrics(status: "found", plain: "saved on device", synced: false)
        let model = NativeLyrics(cacheEnabled: false)
        model.select(saved, api: stub, origin: origin, online: false)
        try await waitForResult(model)
        XCTAssertEqual(model.value?.plain, "saved on device")
        let calls = await stub.count(); XCTAssertEqual(calls, 0)
    }
    func testPlaybackMemoryKeepsPositionQueueAndModesWithinAccount() {
        let account = "test_" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: PlaybackMemory.key(origin, account)) }
        PlaybackMemory(id: "second", tracks: [track("first"), track("second")], position: 87.5, repeatMode: 2, shuffle: true, wave: true).save(origin, account)
        let restored = PlaybackMemory.read(origin, account)
        XCTAssertEqual(restored?.position, 87.5); XCTAssertEqual(restored?.id, "second")
        XCTAssertEqual(restored?.tracks.map(\.id), ["first", "second"])
        XCTAssertEqual(restored?.repeatMode, 2); XCTAssertEqual(restored?.shuffle, true)
        XCTAssertNil(PlaybackMemory.read(origin, account + "_other"))
    }
    func testIncompleteDownloadCannotBecomeOfflineTrack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"error\":\"not an audio file\"}".utf8).write(to: file)
        let account = "test_" + UUID().uuidString
        XCTAssertThrowsError(try OfflineStore.saveDownloadedFile(file, track: track(), origin: origin, account: account))
        XCTAssertNil(OfflineStore.audio(origin: origin, account: account, id: "regression"))
    }
    func testPlaybackRecoveryBudgetAndDuplicateFailures() {
        var callbacks: [() -> Void] = []
        var delays: [TimeInterval] = []
        let recovery = PlaybackRecovery(enqueue: { delay, action in delays.append(delay); callbacks.append(action) })
        var rebuilt = 0
        for attempt in 1...3 {
            XCTAssertTrue(recovery.schedule { rebuilt += 1 })
            XCTAssertTrue(recovery.schedule { XCTFail("Duplicate recovery") })
            XCTAssertEqual(recovery.attempts, attempt)
            callbacks.removeFirst()()
            XCTAssertEqual(rebuilt, attempt)
        }
        XCTAssertFalse(recovery.schedule { XCTFail("Unbounded recovery") })
        XCTAssertEqual(delays, [1, 2, 4])
    }
    func testPlaybackRecoveryCancellationAndTrackReplacement() {
        var callbacks: [() -> Void] = []
        let recovery = PlaybackRecovery(enqueue: { _, action in callbacks.append(action) })
        recovery.schedule { XCTFail("Paused track restarted") }
        recovery.cancel()
        callbacks.removeFirst()()
        XCTAssertFalse(recovery.pending)
        XCTAssertEqual(recovery.attempts, 1)
        recovery.schedule { XCTFail("Old track restarted") }
        recovery.cancel(resetBudget: true)
        var rebuilt = false
        recovery.schedule { rebuilt = true }
        callbacks.removeFirst()()
        XCTAssertFalse(rebuilt)
        XCTAssertTrue(recovery.pending)
        callbacks.removeFirst()()
        XCTAssertTrue(rebuilt)
        XCTAssertEqual(recovery.attempts, 1)
    }
    func testPlaybackRecoveryOnlyRetriesTransientNetworkFailures() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: timeout])
        XCTAssertTrue(PlaybackRecovery.isTransient(wrapped))
        XCTAssertTrue(PlaybackRecovery.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(PlaybackRecovery.isTransient(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(PlaybackRecovery.isTransient(URLError(.fileDoesNotExist)))
        XCTAssertFalse(PlaybackRecovery.isTransient(nil))
    }
    func testMissingOfflineFileClearsPreviousPlayerItem() {
        let player = NativePlayer.shared
        defer { player.stop() }
        player.player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/tmp/previous-track.m4a")))
        var missing = track("missing_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        missing._offline = true
        player.prepare(["id": missing.id, "queue": [missing.dictionary], "account": "device"], origin: origin, cookies: [])
        XCTAssertNil(player.player.currentItem)
        XCTAssertEqual(player.snapshot()["playing"] as? Bool, false)
        XCTAssertTrue((player.snapshot()["error"] as? String ?? "").contains("Офлайн-файл не найден"))
    }
    func testStopClearsPendingPositionAndPlaybackState() {
        let player = NativePlayer.shared
        var missing = track("missing_stop"); missing._offline = true
        player.prepare(["id": missing.id, "queue": [missing.dictionary], "account": "device", "position": 45000], origin: origin, cookies: [])
        player.stop()
        let state = player.snapshot()
        XCTAssertEqual(state["id"] as? String, "")
        XCTAssertEqual(state["position"] as? Double, 0)
        XCTAssertEqual(state["playing"] as? Bool, false)
        XCTAssertEqual(state["error"] as? String, "")
    }
    private func withOfflinePlayer(_ action: (NativePlayer) async throws -> Void) async throws {
        let id = "playback_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let account = "test_" + UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
            buffer.frameLength = 88200
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for frame in 0..<88200 { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 80 / 44100) * 0.01) }
            let output = try AVAudioFile(forWriting: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000], commonFormat: .pcmFormatFloat32, interleaved: false)
            try output.write(from: buffer)
        }
        var saved = track(id); saved._offline = true
        try OfflineStore.saveDownloadedFile(file, track: saved, origin: origin, account: account)
        let player = NativePlayer.shared
        defer {
            player.stop()
            _ = try? OfflineStore.operation(["op": "remove", "id": id, "account": account], origin: origin)
        }
        player.prepare(["id": id, "queue": [saved.dictionary], "account": account], origin: origin, cookies: [])
        for _ in 0..<200 {
            if player.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(player.player.currentItem?.status, .readyToPlay)
        try await action(player)
    }
    private func postInterruption(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue, AVAudioSessionInterruptionOptionKey: resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
    }
    func testExplicitPauseDuringInterruptionPreventsAutomaticResume() async throws {
        try await withOfflinePlayer { player in
            player.play()
            XCTAssertEqual(player.snapshot()["playing"] as? Bool, true)
            postInterruption(.began)
            player.pause()
            postInterruption(.ended, resume: true)
            XCTAssertEqual(player.snapshot()["playing"] as? Bool, false)
            XCTAssertEqual(player.player.rate, 0)
        }
    }
    func testReplacementQueueDuringInterruptionDoesNotResume() async throws {
        try await withOfflinePlayer { player in
            player.play()
            XCTAssertEqual(player.snapshot()["playing"] as? Bool, true)
            postInterruption(.began)
            var replacement = track("missing_replacement"); replacement._offline = true
            player.prepare(["id": replacement.id, "queue": [replacement.dictionary], "account": "device"], origin: origin, cookies: [])
            postInterruption(.ended, resume: true)
            XCTAssertEqual(player.snapshot()["playing"] as? Bool, false)
            XCTAssertNil(player.player.currentItem)
        }
    }
    func testRapidSeekKeepsLatestPositionWithoutStartingPausedPlayer() async throws {
        try await withOfflinePlayer { player in
            player.seek(0.2)
            player.seek(1.2)
            for _ in 0..<200 {
                if abs(player.player.currentTime().seconds - 1.2) < 0.05 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(player.player.currentTime().seconds, 1.2, accuracy: 0.05)
            XCTAssertEqual(player.snapshot()["playing"] as? Bool, false)
            XCTAssertEqual(player.player.rate, 0)
        }
    }
    func testWirelessOutputsBypassVisualizerProcessing() {
        let outputs: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay]
        for output in outputs {
            XCTAssertFalse(AudioOutputPolicy.usesAudioTap([output]))
            XCTAssertFalse(AudioOutputPolicy.usesAudioTap([.builtInSpeaker, output]))
        }
        XCTAssertFalse(AudioOutputPolicy.usesAudioTap([]))
        XCTAssertTrue(AudioOutputPolicy.usesAudioTap([.builtInSpeaker]))
        XCTAssertTrue(AudioOutputPolicy.usesAudioTap([.headphones]))
        XCTAssertTrue(AudioOutputPolicy.usesAudioTap([.usbAudio]))
    }
    func testVisualizerCanBeRemovedFromAnExistingPlayerItem() {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/meter-test.m4a"))
        item.audioMix = AVMutableAudioMix()
        let meter = LocalAudioMeter()
        meter.detach(from: item)
        XCTAssertNil(item.audioMix)
        XCTAssertFalse(meter.attached)
        XCTAssertEqual(meter.level(playing: true), 0)
    }
    private func envelopeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<16000 {
            let time = Double(frame) / 8000
            channel[frame] = time >= 0.5 && time < 1.5 ? Float(sin(time * 2 * .pi * 80) * 0.12) : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    func testIndependentEnvelopeTracksRealAudioAndPlaybackPosition() throws {
        let file = try envelopeFixture(); defer { try? FileManager.default.removeItem(at: file) }
        let value = try TrackEnvelope.analyse(file)
        XCTAssertTrue(value.valid)
        XCTAssertEqual(value.duration, 2, accuracy: 0.01)
        XCTAssertLessThan(value.level(at: 0.1, playing: true), 0.001)
        XCTAssertGreaterThan(value.level(at: 0.7, playing: true), 0.05)
        XCTAssertLessThan(value.level(at: 1.8, playing: true), 0.005)
        XCTAssertEqual(value.level(at: 0.7, playing: false), 0)
        XCTAssertEqual(value.level(at: -.infinity, playing: true), 0)
        XCTAssertEqual(value.level(at: .nan, playing: true), 0)
        XCTAssertEqual(value.level(at: 3, playing: true), 0)
        // Seeking back selects the same music energy, independent of call order.
        let level = value.level(at: 0.7, playing: true)
        _ = value.level(at: 1.8, playing: true)
        XCTAssertEqual(value.level(at: 0.7, playing: true), level)
    }
    func testIndependentEnvelopeCancellationStopsDecoding() throws {
        let file = try envelopeFixture(); defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try TrackEnvelope.analyse(file, cancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
    func testIndependentAnalysisDoesNotModifyPlayerOutput() throws {
        let file = try envelopeFixture(); defer { try? FileManager.default.removeItem(at: file) }
        let item = AVPlayerItem(url: file)
        let category = AVAudioSession.sharedInstance().category
        _ = try TrackEnvelope.analyse(file)
        XCTAssertNil(item.audioMix)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, category)
    }
}

