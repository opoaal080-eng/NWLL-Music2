package fun.nightwell.music;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

/** Pure queue edits; the service applies them without replacing the audible item. */
final class ManualPlaybackQueue {
    static final class Edit {
        final List<String> ids;
        final int currentIndex;
        final Set<String> queuedIds;

        Edit(List<String> ids, int currentIndex, Set<String> queuedIds) {
            this.ids = Collections.unmodifiableList(ids);
            this.currentIndex = currentIndex;
            this.queuedIds = Collections.unmodifiableSet(queuedIds);
        }
    }

    static Edit insert(String requestedID, List<String> ids, int currentIndex,
                       Set<String> queuedIds, boolean next, int limit) {
        if (ids == null || currentIndex < 0 || currentIndex >= ids.size()
                || requestedID == null || requestedID.isEmpty()
                || requestedID.equals(ids.get(currentIndex))) return null;
        if (!ids.contains(requestedID) && ids.size() >= limit) return null;
        Set<String> requested = queuedIds == null ? Collections.emptySet() : queuedIds;

        ArrayList<String> remaining = new ArrayList<>();
        int index = currentIndex;
        for (int i = 0; i < ids.size(); i++) {
            String id = ids.get(i);
            if (requestedID.equals(id)) {
                if (i < currentIndex) index--;
            } else remaining.add(id);
        }

        ArrayList<String> result = new ArrayList<>(remaining.subList(0, index + 1));
        ArrayList<String> manual = new ArrayList<>();
        ArrayList<String> source = new ArrayList<>();
        for (int i = index + 1; i < remaining.size(); i++) {
            String id = remaining.get(i);
            if (requested.contains(id)) manual.add(id);
            else source.add(id);
        }
        if (next) manual.add(0, requestedID);
        else manual.add(requestedID);
        result.addAll(manual);
        result.addAll(source);
        return new Edit(result, index, new LinkedHashSet<>(manual));
    }

    /** Insert requests after current without replaying the already visited shuffle prefix. */
    static int[] shuffleOrder(List<String> ids, int currentIndex, Set<String> queuedIds,
                              List<String> priorTraversal) {
        int[] order = new int[ids.size()];
        boolean[] used = new boolean[ids.size()];
        boolean[] priority = new boolean[ids.size()];
        boolean hasCurrent = currentIndex >= 0 && currentIndex < ids.size();
        if (hasCurrent && queuedIds != null) {
            for (int i = currentIndex + 1; i < ids.size(); i++) {
                priority[i] = queuedIds.contains(ids.get(i));
            }
        }
        ArrayList<Integer> before = new ArrayList<>();
        ArrayList<Integer> after = new ArrayList<>();
        boolean precedesCurrent = hasCurrent;
        if (priorTraversal != null) {
            for (String id : priorTraversal) {
                if (precedesCurrent && Objects.equals(id, ids.get(currentIndex))) {
                    precedesCurrent = false;
                    continue;
                }
                // Match occurrences individually: legacy queues can contain
                // duplicate media IDs, but a ShuffleOrder is a permutation.
                for (int i = 0; i < ids.size(); i++) {
                    if (!used[i] && i != currentIndex && !priority[i]
                            && Objects.equals(id, ids.get(i))) {
                        (precedesCurrent ? before : after).add(i);
                        used[i] = true;
                        break;
                    }
                }
            }
        }
        int count = 0;
        for (int index : before) order[count++] = index;
        if (hasCurrent) {
            order[count++] = currentIndex;
            used[currentIndex] = true;
        }
        for (int i = 0; i < ids.size(); i++) {
            if (priority[i]) {
                order[count++] = i;
                used[i] = true;
            }
        }
        for (int index : after) order[count++] = index;
        for (int i = 0; i < ids.size(); i++) {
            if (!used[i]) order[count++] = i;
        }
        return order;
    }
}
