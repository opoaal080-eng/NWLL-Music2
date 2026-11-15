package fun.nightwell.music;

import org.junit.Test;
import java.net.SocketTimeoutException;
import static org.junit.Assert.*;

public final class RequestBudgetTest {
    private static final class Clock implements RequestBudget.Clock {
        long value;
        @Override public long millis() { return value; }
    }
    @Test public void profileAndFallbackSpendOneDeadline() throws Exception {
        Clock clock = new Clock();
        RequestBudget budget = new RequestBudget(12000, clock);
        assertEquals(12000, budget.remainingMillis());
        clock.value = 4000; // Profile connection setup.
        assertEquals(8000, budget.remainingMillis());
        clock.value = 9500; // Old server profile lookup failed; fallback may use only 2.5s.
        assertEquals(2500, budget.remainingMillis());
        clock.value = 12000;
        try { budget.remainingMillis(); fail("Deadline must not restart for fallback"); }
        catch (SocketTimeoutException expected) {}
    }
    @Test public void timeoutCannotBecomeZeroWhichMeansInfiniteSocketWait() throws Exception {
        Clock clock = new Clock();
        RequestBudget budget = new RequestBudget(10, clock);
        clock.value = 9;
        assertEquals(1, budget.remainingMillis());
        clock.value = 11;
        try { budget.remainingMillis(); fail("Expired budget must throw, not return 0"); }
        catch (SocketTimeoutException expected) {}
    }
    @Test public void invalidDurationsAreRejected() {
        for(long duration : new long[]{0,-1,180001}) {
            try { new RequestBudget(duration);fail("Invalid duration: " + duration); }
            catch(IllegalArgumentException expected) {}
        }
    }
}
