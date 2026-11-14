package fun.nightwell.music;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public final class ManualPlaybackQueueTest {
    private static List<String> ids(String... ids) { return Arrays.asList(ids); }
    private static Set<String> queued(String... ids) { return new HashSet<>(Arrays.asList(ids)); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static void same(Object actual, Object expected, String message) {
        check(expected.equals(actual), message + ": expected " + expected + ", got " + actual);
    }
    private static List<String> traversal(List<String> ids, int[] order) {
        check(order.length == ids.size(), "Shuffle order must cover the whole queue");
        Set<Integer> visited = new HashSet<>();
        List<String> result = new ArrayList<>();
        for (int index : order) {
            check(index >= 0 && index < ids.size() && visited.add(index),
                    "Shuffle indices must form a permutation");
            result.add(ids.get(index));
        }
        return result;
    }

    public static void main(String[] args) {
        ManualPlaybackQueue.Edit first = ManualPlaybackQueue.insert("X", ids("A", "B", "C"), 0, queued(), false, 1000);
        same(first.ids, ids("A", "X", "B", "C"), "First request must precede the source remainder");
        ManualPlaybackQueue.Edit second = ManualPlaybackQueue.insert("Y", first.ids, first.currentIndex, first.queuedIds, false, 1000);
        same(second.ids, ids("A", "X", "Y", "B", "C"), "Manual requests must remain FIFO");
        ManualPlaybackQueue.Edit next = ManualPlaybackQueue.insert("Z", second.ids, second.currentIndex, second.queuedIds, true, 1000);
        same(next.ids, ids("A", "Z", "X", "Y", "B", "C"), "Play next must precede older manual requests");
        same(next.queuedIds, queued("Z", "X", "Y"), "Only manual future items carry priority");
        check(next.currentIndex == 0, "Current track must not change");
        ManualPlaybackQueue.Edit resumed = ManualPlaybackQueue.insert("W", next.ids, 2, queued("Y"), false, 1000);
        same(resumed.ids, ids("A", "Z", "X", "Y", "W", "B", "C"), "Source must resume after remaining manual requests");
        check(resumed.currentIndex == 2, "Adding more requests must retain the current index");

        ManualPlaybackQueue.Edit history = ManualPlaybackQueue.insert("past", ids("past", "A", "B", "C"), 1, queued(), false, 1000);
        same(history.ids, ids("A", "past", "B", "C"), "Move a history occurrence instead of duplicating it");
        check(history.currentIndex == 0 && history.ids.get(history.currentIndex).equals("A"), "Removing history must adjust current index");
        ManualPlaybackQueue.Edit future = ManualPlaybackQueue.insert("C", ids("past", "A", "B", "C", "D"), 1, queued(), true, 1000);
        same(future.ids, ids("past", "A", "C", "B", "D"), "Move a future occurrence and retain source order");
        ManualPlaybackQueue.Edit duplicate = ManualPlaybackQueue.insert("B", ids("B", "A", "B", "C", "B"), 1, queued(), false, 1000);
        same(duplicate.ids, ids("A", "B", "C"), "Remove every occurrence of the requested duplicate ID");
        check(duplicate.currentIndex == 0, "Duplicate history removal must preserve current identity");
        ManualPlaybackQueue.Edit normalize = ManualPlaybackQueue.insert("Z", ids("A", "X", "B", "Y", "C", "fresh"), 0, queued("old", "A", "X", "Y"), false, 1000);
        same(normalize.ids, ids("A", "X", "Y", "Z", "B", "C", "fresh"), "Refill/source additions must not split manual priority");
        same(normalize.queuedIds, queued("X", "Y", "Z"), "Drop stale/history priority markers");

        check(ManualPlaybackQueue.insert("A", ids("A", "B"), 0, queued(), false, 1000) == null, "Reject current track");
        check(ManualPlaybackQueue.insert("", ids("A"), 0, queued(), false, 1000) == null, "Reject empty ID");
        check(ManualPlaybackQueue.insert(null, ids("A"), 0, queued(), false, 1000) == null, "Reject null ID");
        check(ManualPlaybackQueue.insert("X", ids(), 0, queued(), false, 1000) == null, "Reject empty queue");
        check(ManualPlaybackQueue.insert("X", ids("A"), -1, queued(), false, 1000) == null, "Reject negative current index");
        check(ManualPlaybackQueue.insert("X", ids("A"), 1, queued(), false, 1000) == null, "Reject past-end current index");
        check(ManualPlaybackQueue.insert("X", ids("A", "B", "C"), 0, queued(), false, 3) == null, "Full queue must reject a new track without truncating source");
        same(ManualPlaybackQueue.insert("C", ids("A", "B", "C"), 0, queued(), false, 3).ids,
                ids("A", "C", "B"), "A full queue may move an existing track");

        List<String> playlist = ids("past", "A", "X", "Y", "B", "C", "D");
        List<String> shuffled = traversal(playlist, ManualPlaybackQueue.shuffleOrder(playlist, 1,
                queued("X", "Y"), ids("A", "C", "B", "past", "D", "Y", "X")));
        same(shuffled, ids("A", "X", "Y", "C", "B", "past", "D"), "Manual FIFO must precede unchanged source shuffle traversal");
        List<String> midShuffle = ids("A", "B", "C", "X", "D");
        same(traversal(midShuffle, ManualPlaybackQueue.shuffleOrder(midShuffle, 2,
                queued("X"), ids("B", "A", "C", "D"))),
                ids("B", "A", "C", "X", "D"),
                "Already visited shuffle prefix must stay before current so repeat-off tail is only X,D");
        List<String> replayFromHistory = ids("B", "C", "A", "D");
        same(traversal(replayFromHistory, ManualPlaybackQueue.shuffleOrder(replayFromHistory, 1,
                queued("A"), ids("B", "A", "C", "D"))),
                ids("B", "C", "A", "D"),
                "A deliberately requeued history song moves after current without replaying other history");
        List<String> repeated = ids("A", "duplicate", "X", "duplicate", "tail");
        same(traversal(repeated, ManualPlaybackQueue.shuffleOrder(repeated, 0,
                queued("X"), ids("duplicate", "A", "tail", "duplicate", "X"))),
                ids("duplicate", "A", "X", "tail", "duplicate"), "Duplicate legacy IDs still need distinct shuffle indices");
        same(traversal(ids("A", "B", "new"), ManualPlaybackQueue.shuffleOrder(ids("A", "B", "new"), 0,
                queued(), ids("A", "B", "gone"))), ids("A", "B", "new"), "Include new IDs and ignore removed traversal IDs");
        check(ManualPlaybackQueue.shuffleOrder(Collections.emptyList(), -1, queued(), Collections.emptyList()).length == 0,
                "Empty shuffle order must be safe");
        System.out.println("Manual queue: FIFO/play-next, original source, history/deduplication, capacity and shuffle priority passed");
    }
}
