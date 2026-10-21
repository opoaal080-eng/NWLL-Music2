package fun.nightwell.music;

import java.io.*;
import java.net.*;

// GETs only. A mutation may have reached the server even if its response was lost.
final class NetworkRetry {
    interface Operation<T> { T run() throws Exception; }
    interface Cancelled { boolean get(); }
    interface Sleeper { void sleep(long millis) throws InterruptedException; }
    static final class HttpFailure extends IOException {
        final int status;
        HttpFailure(int status, String message) { super(message); this.status = status; }
    }
    static <T> T run(boolean safe, Cancelled cancelled, Operation<T> operation) throws Exception {
        return run(safe, cancelled, operation, Thread::sleep);
    }
    static <T> T run(boolean safe, Cancelled cancelled, Operation<T> operation, Sleeper sleeper) throws Exception {
        long[] delays = {500, 1500};
        for (int attempt = 0; ; attempt++) {
            check(cancelled);
            try {
                T result = operation.run();
                check(cancelled);
                return result;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt(); throw e;
            } catch (Exception e) {
                check(cancelled);
                if (!safe || attempt >= delays.length || !transientFailure(e)) throw e;
                try { sleeper.sleep(delays[attempt]); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw interrupted; }
            }
        }
    }
    private static void check(Cancelled cancelled) throws InterruptedIOException {
        if (Thread.currentThread().isInterrupted() || cancelled.get()) throw new InterruptedIOException("Запрос отменён");
    }
    private static boolean transientFailure(Exception e) {
        if (e instanceof HttpFailure) {
            int status = ((HttpFailure)e).status;
            return status == 408 || status == 500 || status == 502 || status == 503 || status == 504;
        }
        return e instanceof SocketTimeoutException || e instanceof ConnectException ||
            e instanceof UnknownHostException || e instanceof NoRouteToHostException ||
            e instanceof SocketException || e instanceof EOFException;
    }
}
