import XCTest
import AVFoundation
@testable import NightwellMusic

@MainActor final class PlaybackQueueTests: XCTestCase {
    private let origin = URL(string: "https://music.nightwell.fun/")!
    private func track(_ id: String) -> Track {
        Track(id: id, title: id, artist: "Artist")
    }

    func testEnqueueKeepsCurrentAudioItemSourceAndPlaybackModes() throws {
        let player = NativePlayer.shared
        defer { player.stop() }
        player.prepare(["id": "A", "queue": ["A", "B", "C"].map { track($0).dictionary },
                        "account": "device", "wave": true], origin: origin, cookies: [])
        player.modes(repeatMode: 2, shuffle: true)
        let item = player.player.currentItem
        let before = player.snapshot()
        XCTAssertTrue(player.enqueue(track("X").dictionary))
        XCTAssertTrue(player.enqueue(track("Y").dictionary))
        XCTAssertTrue(player.enqueue(track("Z").dictionary, next: true))
        let after = player.snapshot()
        XCTAssertEqual(after["queueIds"] as? [String], ["A", "Z", "X", "Y", "B", "C"])
        XCTAssertEqual(after["queuedIds"] as? [String], ["Z", "X", "Y"])
        XCTAssertEqual(after["id"] as? String, "A")
        XCTAssertTrue(player.player.currentItem === item, "Enqueue must not replace the decoder item")
        XCTAssertEqual(after["position"] as? Double, before["position"] as? Double)
        XCTAssertEqual(after["playing"] as? Bool, before["playing"] as? Bool)
        XCTAssertEqual(after["repeat"] as? Int, 2)
        XCTAssertEqual(after["shuffle"] as? Bool, true)
        XCTAssertEqual(after["wave"] as? Bool, true)
    }

    func testExistingAndCurrentTracksCannotDuplicateQueueIDs() {
        let player = NativePlayer.shared
        defer { player.stop() }
        player.prepare(["id": "A", "queue": ["past", "A", "B", "C"].map { track($0).dictionary }],
                       origin: origin, cookies: [])
        let item = player.player.currentItem
        XCTAssertTrue(player.enqueue(track("past").dictionary))
        XCTAssertTrue(player.enqueue(track("C").dictionary, next: true))
        XCTAssertFalse(player.enqueue(track("A").dictionary))
        XCTAssertEqual(player.snapshot()["queueIds"] as? [String], ["A", "C", "past", "B"])
        XCTAssertTrue(player.player.currentItem === item)
    }

    func testManualQueuePrioritySurvivesPlaybackMemoryAndRestore() throws {
        let player = NativePlayer.shared
        defer { player.stop() }
        let original = ["A", "X", "B"].map { track($0) }
        let memory = PlaybackMemory(id: "A", tracks: original, position: 15,
            repeatMode: 1, shuffle: true, wave: true, queuedIDs: ["X"])
        let restored = try JSONDecoder().decode(PlaybackMemory.self,
            from: JSONEncoder().encode(memory))
        player.prepare(["id": restored.id, "queue": restored.tracks.map(\.dictionary),
                        "queued_ids": restored.queuedIDs ?? [], "wave": restored.wave],
                       origin: origin, cookies: [])
        XCTAssertTrue(player.enqueue(track("Y").dictionary))
        XCTAssertEqual(player.snapshot()["queueIds"] as? [String], ["A", "X", "Y", "B"])
        // Existing saved sessions lack queuedIDs and must remain readable.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) as? [String: Any])
        legacy.removeValue(forKey: "queuedIDs")
        let old = try JSONDecoder().decode(PlaybackMemory.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.queuedIDs)
    }
}
