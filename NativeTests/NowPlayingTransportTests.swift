#if canImport(NowPlaying)
import XCTest
import NowPlaying
@testable import NightwellMusic

@available(iOS 27.0, *)
@MainActor
final class NowPlayingTransportTests: XCTestCase {
    private func track(_ id: String) -> NightwellNowPlayingTrack {
        NightwellNowPlayingTrack(NativeTrack(id: id, title: "Track " + id,
            artist: "Artist", album: "Album", duration: 180,
            cover: nil, source: nil, sourceURL: nil, remote: true))
    }

    func testPauseImmediatelyPublishesPausedSnapshotAndKeepsSystemContent() throws {
        let model = NightwellNowPlayingModel()
        let item = track("one")
        model.update(track: item, playing: true, position: 42, queueCount: 2)
        model.update(track: item, playing: false, position: 42.125, queueCount: 2)
        let paused = try XCTUnwrap(model.playbackSnapshot)
        XCTAssertEqual(paused, MediaPlaybackSnapshot(state: .paused,
            elapsedTime: 42.125, timestamp: model.snapshotDate))
        XCTAssertNotNil(model.content)
        XCTAssertTrue(model.canNavigate)
        // Repeated timer/artwork updates after Pause must leave it paused.
        for _ in 0..<10 {
            model.updateArtwork(nil)
            model.update(track: item, playing: false, position: 42.125, queueCount: 2)
            XCTAssertEqual(model.playbackSnapshot, paused)
        }
    }

    func testImmediateResumePublishesPlayingSnapshotAtTheSamePosition() {
        let model = NightwellNowPlayingModel()
        let item = track("one")
        model.update(track: item, playing: true, position: 12, queueCount: 1)
        model.update(track: item, playing: false, position: 12.1, queueCount: 1)
        model.update(track: item, playing: true, position: 12.1, queueCount: 1)
        XCTAssertEqual(model.playbackSnapshot, MediaPlaybackSnapshot(state: .playing(),
            elapsedTime: 12.1, timestamp: model.snapshotDate))
        XCTAssertNotNil(model.content)
    }

    func testPausedTrackChangeAndStopDoNotKeepThePreviousRunningSnapshot() {
        let model = NightwellNowPlayingModel()
        model.update(track: track("one"), playing: true, position: 0.2, queueCount: 2)
        model.update(track: track("two"), playing: false, position: 0, queueCount: 2)
        XCTAssertEqual(model.playbackSnapshot, MediaPlaybackSnapshot(state: .paused,
            elapsedTime: 0, timestamp: model.snapshotDate))
        model.update(track: nil, playing: false, position: 0, queueCount: 0)
        XCTAssertNil(model.content)
        XCTAssertNil(model.playbackSnapshot)
    }
}
#endif
