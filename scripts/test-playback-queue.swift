import Foundation

@main struct PlaybackQueueTests {
    static func main() {
        func edit(_ track: String, _ tracks: [String], index: Int = 0,
                  queued: Set<String> = [], next: Bool = false, limit: Int = 1000)
            -> PlaybackQueueInsertion.Edit<String>? {
            PlaybackQueueInsertion.inserting(track, into: tracks, currentIndex: index,
                queuedIDs: queued, next: next, limit: limit, id: { $0 })
        }

        let first = edit("X", ["A", "B", "C"])!
        precondition(first.tracks == ["A", "X", "B", "C"])
        precondition(first.index == 0 && first.queuedIDs == ["X"])
        let second = edit("Y", first.tracks, index: first.index, queued: first.queuedIDs)!
        precondition(second.tracks == ["A", "X", "Y", "B", "C"], "Manual requests must remain FIFO")
        let priority = edit("Z", second.tracks, index: second.index, queued: second.queuedIDs, next: true)!
        precondition(priority.tracks == ["A", "Z", "X", "Y", "B", "C"], "Play next precedes existing manual requests")
        precondition(priority.queuedIDs == ["Z", "X", "Y"])
        precondition(PlaybackQueueInsertion.nextQueuedIndex(in: priority.tracks,
            after: 0, queuedIDs: priority.queuedIDs, id: { $0 }) == 1)

        let resumed = edit("W", priority.tracks, index: 2, queued: ["Y"])!
        precondition(resumed.tracks == ["A", "Z", "X", "Y", "W", "B", "C"])
        precondition(resumed.index == 2 && resumed.queuedIDs == ["Y", "W"])
        precondition(Array(resumed.tracks.suffix(2)) == ["B", "C"], "The original source must resume unchanged")
        precondition(PlaybackQueueInsertion.nextQueuedIndex(in: resumed.tracks,
            after: 4, queuedIDs: [], id: { $0 }) == nil)

        let existingFuture = edit("C", ["history", "A", "B", "C", "D"], index: 1)!
        precondition(existingFuture.tracks == ["history", "A", "C", "B", "D"])
        precondition(existingFuture.index == 1)
        let existingHistory = edit("history", ["history", "A", "B", "C"], index: 1)!
        precondition(existingHistory.tracks == ["A", "history", "B", "C"])
        precondition(existingHistory.index == 0 && existingHistory.tracks[existingHistory.index] == "A")
        let existingManual = edit("X", second.tracks, queued: second.queuedIDs, next: true)!
        precondition(existingManual.tracks == second.tracks, "Selecting a queued song must not duplicate it")
        let moveManual = edit("Y", second.tracks, queued: second.queuedIDs, next: true)!
        precondition(moveManual.tracks == ["A", "Y", "X", "B", "C"])

        let duplicates = edit("B", ["B", "A", "B", "C", "B"], index: 1)!
        precondition(duplicates.tracks == ["A", "B", "C"] && duplicates.index == 0)
        precondition(edit("A", ["A", "B"]) == nil, "Queueing the current song must not replace it")
        precondition(edit("", ["A"]) == nil)
        precondition(edit("X", []) == nil)
        precondition(edit("X", ["A"], index: -1) == nil)
        precondition(edit("X", ["A"], index: 1) == nil)
        precondition(edit("X", ["A", "B", "C"], limit: 3) == nil, "A full queue must reject new songs without truncating the source")
        precondition(edit("C", ["A", "B", "C"], limit: 3)?.tracks == ["A", "C", "B"])

        // Async wave refill can append source tracks, and queue reordering may
        // interleave them. A later insertion restores a single manual prefix.
        let refilled = edit("Z", ["A", "X", "B", "Y", "C", "fresh"], queued: ["old", "A", "X", "Y"])!
        precondition(refilled.tracks == ["A", "X", "Y", "Z", "B", "C", "fresh"])
        precondition(refilled.queuedIDs == ["X", "Y", "Z"], "Stale/manual history markers must not survive")
        precondition(PlaybackQueueInsertion.nextQueuedIndex(in: ["A", "B", "X", "C"],
            after: 0, queuedIDs: ["X"], id: { $0 }) == 2, "Manual requests take precedence over shuffled source selection")
        precondition(PlaybackQueueInsertion.nextQueuedIndex(in: ["A"],
            after: 1, queuedIDs: ["A"], id: { $0 }) == nil)
        print("Playback queue insertion, source preservation, duplicates and manual priority passed")
    }
}
