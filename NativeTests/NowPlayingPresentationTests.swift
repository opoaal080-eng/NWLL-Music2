#if canImport(NowPlaying)
import XCTest
@testable import NightwellMusic

@available(iOS 27.0, *)
@MainActor
final class NowPlayingPresentationTests: XCTestCase {
    private func track(_ id: String) -> NightwellNowPlayingTrack {
        NightwellNowPlayingTrack(NativeTrack(id: id, title: "Track " + id,
            artist: "Artist", album: "Album", duration: 180,
            cover: nil, source: nil, sourceURL: nil, remote: true))
    }

    func testForegroundTicksHideContentWithoutDiscardingPlaybackOrCommands() {
        let model = NightwellNowPlayingModel()
        let item = track("one")
        model.update(track: item, playing: true, position: 12, queueCount: 2,
                     presentationEnabled: true)
        XCTAssertNotNil(model.content)
        XCTAssertNotNil(model.playbackSnapshot)
        let commandCount = model.commands.count
        for position in [12.1, 12.5, 13.0] {
            model.update(track: item, playing: true, position: position, queueCount: 2,
                         presentationEnabled: false)
            XCTAssertNil(model.content)
            XCTAssertNil(model.playbackSnapshot)
            XCTAssertTrue(model.isPlaying)
            XCTAssertEqual(model.commands.count, commandCount)
            XCTAssertTrue(model.canNavigate)
        }
    }

    func testPauseAndImmediateBackgroundRestoreKeepExactPlayheadAndArtwork() {
        let model = NightwellNowPlayingModel()
        let item = track("one")
        let artwork = Data([1, 2, 3])
        model.update(track: item, playing: true, position: 42, queueCount: 1,
                     presentationEnabled: true)
        model.update(track: item, playing: false, position: 42.125, queueCount: 1,
                     presentationEnabled: false)
        model.updateArtwork(artwork)
        // Less than the usual 0.5s publication threshold: revealing must still
        // capture a fresh exact position and timestamp rather than extrapolate.
        let restoreStarted = Date.now
        model.update(track: item, playing: false, position: 42.25, queueCount: 1,
                     presentationEnabled: true)
        XCTAssertNotNil(model.content)
        XCTAssertNotNil(model.playbackSnapshot)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.elapsedTime, 42.25)
        XCTAssertGreaterThanOrEqual(model.snapshotDate, restoreStarted)
        XCTAssertEqual(model.imageData, artwork)
    }

    func testTrackChangedWhileHiddenRestoresNewTrackAndStopClearsIt() {
        let model = NightwellNowPlayingModel()
        model.update(track: track("one"), playing: true, position: 90, queueCount: 2,
                     presentationEnabled: true)
        model.update(track: track("two"), playing: true, position: 0.1, queueCount: 2,
                     presentationEnabled: false)
        XCTAssertNil(model.content)
        model.update(track: track("two"), playing: true, position: 0.2, queueCount: 2,
                     presentationEnabled: true)
        XCTAssertEqual(model.track?.id, "two")
        XCTAssertEqual(model.elapsedTime, 0.2)
        XCTAssertNotNil(model.content)
        model.update(track: nil, playing: false, position: 0, queueCount: 0,
                     presentationEnabled: false)
        model.update(track: nil, playing: false, position: 0, queueCount: 0,
                     presentationEnabled: true)
        XCTAssertNil(model.content)
        XCTAssertNil(model.playbackSnapshot)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.canNavigate)
    }
}
#endif
