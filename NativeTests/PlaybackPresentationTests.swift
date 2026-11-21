import XCTest
import Combine
@testable import NightwellMusic

@MainActor final class PlaybackPresentationTests: XCTestCase {
    private func track(_ id: String, title: String? = nil) -> Track {
        Track(id: id, title: title ?? id, artist: "Artist", duration: 180)
    }

    private var snapshot: [String: Any] {
        ["id": "A", "displayID": "A", "position": 10.0, "duration": 180.0,
         "displayPosition": 10.0, "displayDuration": 180.0, "playing": true,
         "preparing": false, "bufferFraction": 0.1, "error": "", "queueRevision": 1]
    }

    func testPositionAndBufferTicksKeepProgressLiveWithoutInvalidatingMetadata() {
        let clock = PlaybackClock(observesPlayer: false)
        var value = snapshot
        clock.applySnapshot(value, queueTracks: [track("A"), track("B")])
        var presentationChanges = 0
        var progressChanges = 0
        let metadata = clock.presentation.objectWillChange.sink { presentationChanges += 1 }
        let progress = clock.objectWillChange.sink { progressChanges += 1 }
        defer { metadata.cancel(); progress.cancel() }

        for tick in 1...20 {
            value["position"] = 10.0 + Double(tick) * 0.25
            value["displayPosition"] = 10.0 + Double(tick) * 0.25
            value["bufferFraction"] = 0.1 + Double(tick) * 0.02
            clock.applySnapshot(value)
        }

        XCTAssertEqual(presentationChanges, 0)
        XCTAssertGreaterThan(progressChanges, 0)
        XCTAssertEqual(clock.position, 15)
        XCTAssertEqual(clock.displayPosition, 15)
        XCTAssertEqual(clock.bufferFraction, 0.5, accuracy: 0.0001)
    }

    func testEachMetadataChangeNotifiesAndUnchangedSnapshotsStayQuiet() {
        let clock = PlaybackClock(observesPlayer: false)
        var value = snapshot
        clock.applySnapshot(value, queueTracks: [track("A"), track("B")])
        var changes = 0
        let subscription = clock.presentation.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        let updates: [(String, Any)] = [
            ("id", "B"), ("displayID", "B"), ("playing", false),
            ("preparing", true), ("duration", 200.0), ("displayDuration", 210.0),
            ("error", "Retry"), ("queueRevision", 2)
        ]
        for (index, update) in updates.enumerated() {
            value[update.0] = update.1
            clock.applySnapshot(value)
            XCTAssertEqual(changes, index + 1, "Missing metadata update for \(update.0)")
            clock.applySnapshot(value)
            XCTAssertEqual(changes, index + 1, "An identical snapshot must stay quiet")
        }
        XCTAssertEqual(clock.status.id, "B")
        XCTAssertFalse(clock.status.playing)
    }

    func testTrackHandoffPublishesOneCompleteMetadataUpdateAndPauseKeepsPlayhead() {
        let clock = PlaybackClock(observesPlayer: false)
        clock.applySnapshot(snapshot, queueTracks: [track("A"), track("B")])
        var value = snapshot
        value["displayID"] = "B"
        value["displayPosition"] = 0.0
        value["displayDuration"] = 240.0
        value["preparing"] = true
        value["queueRevision"] = 2
        var changes = 0
        var observedID = ""
        var observedDisplayID = ""
        let subscription = clock.presentation.objectWillChange.sink {
            changes += 1
            observedID = clock.current?.id ?? ""
            observedDisplayID = clock.displayCurrent?.id ?? ""
        }
        defer { subscription.cancel() }

        clock.applySnapshot(value, queueTracks: [track("A"), track("B", title: "Incoming")])
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(observedID, "A")
        XCTAssertEqual(observedDisplayID, "B")
        XCTAssertEqual(clock.displayCurrent?.title, "Incoming")

        value["playing"] = false
        value["position"] = 42.125
        clock.applySnapshot(value)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(clock.position, 42.125, accuracy: 0.0001)
        clock.applySnapshot(value)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(clock.position, 42.125, accuracy: 0.0001)
    }

    func testQueueLookupCacheFollowsDirectAssignmentsAndKeepsFirstDuplicate() {
        let clock = PlaybackClock(observesPlayer: false)
        clock.queue = [track("A", title: "First"), track("A", title: "Duplicate"), track("B")]
        clock.id = "A"
        clock.displayID = "B"
        XCTAssertEqual(clock.currentIndex, 0)
        XCTAssertEqual(clock.current?.title, "First")
        XCTAssertEqual(clock.displayIndex, 2)
        XCTAssertEqual(clock.displayCurrent?.id, "B")

        clock.queue = [track("B", title: "Updated"), track("A", title: "Moved")]
        XCTAssertEqual(clock.currentIndex, 1)
        XCTAssertEqual(clock.current?.title, "Moved")
        XCTAssertEqual(clock.displayIndex, 0)
        XCTAssertEqual(clock.displayCurrent?.title, "Updated")
        clock.displayID = "missing"
        XCTAssertEqual(clock.displayCurrent?.id, "A")
        clock.queue = []
        XCTAssertNil(clock.currentIndex)
        XCTAssertNil(clock.current)
        XCTAssertNil(clock.displayCurrent)
    }

    func testCheckedMetadataRoundTripPreservesOfflineLyricsAndCredits() throws {
        let lyrics = Lyrics(status: "found", plain: "Saved lyrics",
            lines: [.init(time: 0, text: "Saved lyrics")], synced: true, source: "Offline")
        let original = Track(id: "offline_A", title: "Artist — Already checked", artist: "Saved credit",
            duration: 180, source: "soundcloud", is_remote: true, _offline: true,
            _offline_account: "saved_account", _offline_lyrics: lyrics,
            uploader: "Posting account", performer: "Different performer", _artist_checked: true)
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testUncheckedRemoteMetadataStillResolvesArtistCredit() throws {
        let raw: [String: Any] = ["id": "remote_A", "title": "Performer — Song",
            "artist": "Posting account", "source": "soundcloud", "is_remote": true]
        let decoded = try JSONDecoder().decode(Track.self,
            from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(decoded.title, "Song")
        XCTAssertEqual(decoded.artist, "Performer")
        XCTAssertEqual(decoded.uploader, "Posting account")
        XCTAssertEqual(decoded._artist_checked, true)
    }
}
