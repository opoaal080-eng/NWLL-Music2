#if canImport(NowPlaying)
import XCTest
import NowPlaying
import UIKit
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

    func testLateArtworkRepublishesCompactNowPlayingWithoutOpeningExpandedPlayer() throws {
        let model = NightwellNowPlayingModel()
        let playing = track("artwork")
        model.update(track: playing, playing: true, position: 11, queueCount: 3)
        let before = model.contentUpdateSerial
        let snapshot = try XCTUnwrap(model.playbackSnapshot)

        // Simulate the album cover arriving after playback has started,
        // without a user action on Dynamic Island.
        model.updateArtwork(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertGreaterThan(model.contentUpdateSerial, before)
        XCTAssertEqual(model.imageData?.count, 4)
        XCTAssertNotNil(model.content)
        XCTAssertEqual(model.playbackSnapshot, snapshot)
        let updated = model.contentUpdateSerial
        model.update(track: playing, playing: true, position: 11, queueCount: 3)
        XCTAssertEqual(model.contentUpdateSerial, updated)

        model.update(track: track("next"), playing: true, position: 0,
                     queueCount: 3)
        XCTAssertGreaterThan(model.contentUpdateSerial, updated)
    }

    func testTrackChangesDoNotCarryPreviousCoverOrLoseLateArtwork() throws {
        let model = NightwellNowPlayingModel()
        let first = Data([1, 2, 3, 4])
        let last = Data([5, 6, 7, 8])
        model.update(track: track("first"), playing: true, position: 10,
                     queueCount: 2, initialArtwork: first)
        XCTAssertEqual(model.imageData, first)
        let firstRevision = model.contentUpdateSerial

        // Audio can advance before a CDN cover has arrived.
        model.update(track: track("second"), playing: true, position: 0,
                     queueCount: 2, initialArtwork: nil)
        XCTAssertNil(model.imageData,
            "The previous track's art must not accompany the next title")
        XCTAssertGreaterThan(model.contentUpdateSerial, firstRevision)
        let secondRevision = model.contentUpdateSerial

        // The arrival of the cover must update content even after playback
        // is already active, without requiring interaction with Dynamic Island.
        model.updateArtwork(last)
        XCTAssertEqual(model.imageData, last)
        XCTAssertGreaterThan(model.contentUpdateSerial, secondRevision)
        let thirdRevision = model.contentUpdateSerial
        model.update(track: track("second"), playing: true, position: 0,
                     queueCount: 2, initialArtwork: model.imageData)
        XCTAssertEqual(model.contentUpdateSerial, thirdRevision)
        XCTAssertEqual(model.imageData, last)
    }

    func testLockScreenArtworkCacheProvidesCoverWithoutNetwork() throws {
        let origin = try XCTUnwrap(URL(string: "https://music.example.invalid/"))
        let id = "lock_screen_" + UUID().uuidString
        let native = NativeTrack(id: id, title: "Cover Cache", artist: "Test",
                                 album: "Offline Test", duration: 50,
                                 cover: "https://covers.example.invalid/" + id + ".jpg",
                                 source: nil, sourceURL: nil, remote: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96),
                                              format: format).image { context in
            UIColor(red: 0.8, green: 0.25, blue: 0.45, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
        LockScreenArtworkCache.save(source, origin: origin, track: native)
        let restored = try XCTUnwrap(LockScreenArtworkCache.load(origin: origin, track: native))
        XCTAssertEqual(restored.size, CGSize(width: 96, height: 96))
        let imageData = try XCTUnwrap(restored.jpegData(compressionQuality: 0.86))
        XCTAssertGreaterThan(imageData.count, 100)
        let different = NativeTrack(id: native.id, title: native.title,
                                    artist: native.artist, album: native.album,
                                    duration: native.duration,
                                    cover: "https://covers.example.invalid/changed.jpg",
                                    source: nil, sourceURL: nil, remote: true)
        XCTAssertNil(LockScreenArtworkCache.load(origin: origin, track: different),
            "A changed artwork URL must never reuse an older cover")
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
