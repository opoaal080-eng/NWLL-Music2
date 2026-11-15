package fun.nightwell.music;

import java.net.SocketTimeoutException;

/** One monotonic deadline shared by metadata lookup and any fallback lookup. */
final class RequestBudget {
    interface Clock { long millis(); }
    private final Clock clock;
    private final long deadline;

    RequestBudget(long millis) { this(millis, () -> System.nanoTime() / 1_000_000L); }
    RequestBudget(long millis, Clock clock) {
        if (millis <= 0 || millis > 180000) throw new IllegalArgumentException("Invalid request budget");
        this.clock = clock;
        this.deadline = clock.millis() + millis;
    }
    int remainingMillis() throws SocketTimeoutException {
        long remaining = deadline - clock.millis();
        if (remaining <= 0) throw new SocketTimeoutException("Источник музыки отвечает слишком долго. Повтори запрос.");
        return (int)Math.min(Integer.MAX_VALUE, remaining);
    }
}
