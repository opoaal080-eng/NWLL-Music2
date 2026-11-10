package fun.nightwell.music;

import java.util.HashSet;
import java.util.Set;

/**
 * Guard for the explicit double-Next gesture.
 * Only failed media IDs that produced the visible "Не удалось загрузить трек"
 * message may be bypassed. Neither slow buffering nor repeated taps during
 * preparation count as a failure.
 */
final class FailedNextSkipPolicy {
    static final String FAILURE_MESSAGE = "Не удалось загрузить трек";
    private String currentId="";
    private final Set<String> failedIds=new HashSet<>();

    void clear() {
        currentId="";
        failedIds.clear();
    }

    void reportFailed(String currentlyPlayingId,String failedId,String visibleMessage) {
        if(currentlyPlayingId==null||currentlyPlayingId.isEmpty()||
           failedId==null||failedId.isEmpty()||
           visibleMessage==null||!visibleMessage.startsWith(FAILURE_MESSAGE))
            return;
        if(!currentlyPlayingId.equals(currentId)) {
            currentId=currentlyPlayingId;
            failedIds.clear();
        }
        failedIds.add(failedId);
    }

    boolean maySkip(String currentlyPlayingId,String visibleMessage) {
        return currentlyPlayingId!=null&&currentlyPlayingId.equals(currentId)
            &&visibleMessage!=null&&visibleMessage.startsWith(FAILURE_MESSAGE)
            &&!failedIds.isEmpty();
    }

    boolean wasFailed(String currentlyPlayingId,String candidateId) {
        return currentlyPlayingId!=null&&currentlyPlayingId.equals(currentId)
            &&candidateId!=null&&failedIds.contains(candidateId);
    }
}
