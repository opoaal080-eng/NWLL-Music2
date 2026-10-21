package fun.nightwell.music;

// Completion is consumed on the UI thread. Workers may check pending() before
// starting network work. Cancellation also disconnects the underlying request.
final class LatestRequest {
    private long revision;
    private boolean pending;
    private Runnable cancellation;
    synchronized long start(Runnable onCancel) {
        cancel(); pending = true; cancellation = onCancel; return revision;
    }
    synchronized void cancel() {
        revision++; pending = false;
        Runnable action = cancellation; cancellation = null;
        if (action != null) action.run();
    }
    synchronized boolean pending(long ticket) { return pending && revision == ticket; }
    synchronized boolean complete(long ticket) {
        if (!pending(ticket)) return false;
        pending = false; cancellation = null; return true;
    }
}
