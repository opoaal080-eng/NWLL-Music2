import XCTest
@testable import NightwellMusic

final class PlaybackProgressPresentationTests: XCTestCase {
    func testPlayingProgressSamplesTheLivePlayheadBetweenClockTicks() {
        let position = PlaybackProgressPresentation.position(
            displayPosition: 40, duration: 180, playing: true,
            displayMatchesPlayback: true, livePosition: { 40.375 })
        XCTAssertEqual(position, 40.375)
        XCTAssertEqual(PlaybackProgressPresentation.fraction(position: position, duration: 180), 40.375 / 180)
    }

    func testPausedProgressUsesTheFrozenSnapshotWithoutReadingTheEngine() {
        let position = PlaybackProgressPresentation.position(
            displayPosition: 42.125, duration: 180, playing: false,
            displayMatchesPlayback: true, livePosition: {
                XCTFail("A paused EQ engine must not override the frozen playhead")
                return 35
            })
        XCTAssertEqual(position, 42.125)
    }

    func testIncomingDisplayMetadataStaysAtZeroUntilItOwnsPlayback() {
        let position = PlaybackProgressPresentation.position(
            displayPosition: 0, duration: 240, playing: true,
            displayMatchesPlayback: false, livePosition: {
                XCTFail("The old audible item's playhead belongs to a different track")
                return 179
            })
        XCTAssertEqual(position, 0)
    }

    func testASeekToZeroCanOverrideAnOlderPublishedPosition() {
        XCTAssertEqual(PlaybackProgressPresentation.position(
            displayPosition: 42, duration: 180, playing: true,
            displayMatchesPlayback: true, livePosition: { 0 }), 0)
    }

    func testInvalidLivePositionsKeepTheValidPublishedPlayhead() {
        for live in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(PlaybackProgressPresentation.position(
                displayPosition: 12.5, duration: 180, playing: true,
                displayMatchesPlayback: true, livePosition: { live }), 12.5)
        }
    }

    func testPositionAndFractionRemainFiniteAndWithinTheTrack() {
        XCTAssertEqual(PlaybackProgressPresentation.position(
            displayPosition: 5, duration: 180, playing: true,
            displayMatchesPlayback: true, livePosition: { 181 }), 180)
        XCTAssertEqual(PlaybackProgressPresentation.position(
            displayPosition: .nan, duration: .infinity, playing: false,
            displayMatchesPlayback: true, livePosition: { 99 }), 0)
        XCTAssertEqual(PlaybackProgressPresentation.fraction(position: 181, duration: 180), 1)
        XCTAssertEqual(PlaybackProgressPresentation.fraction(position: -1, duration: 180), 0)
        XCTAssertEqual(PlaybackProgressPresentation.fraction(position: .nan, duration: 180), 0)
        XCTAssertEqual(PlaybackProgressPresentation.fraction(position: 1, duration: 0), 0)
    }
}
