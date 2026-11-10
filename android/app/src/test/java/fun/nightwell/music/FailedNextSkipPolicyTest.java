package fun.nightwell.music;

import org.junit.Test;
import static org.junit.Assert.*;

public final class FailedNextSkipPolicyTest {
    @Test public void ordinaryRepeatedNextDoesNotEnableSkip() {
        FailedNextSkipPolicy policy=new FailedNextSkipPolicy();
        assertFalse(policy.maySkip("now",""));
        assertFalse(policy.maySkip("now","Подготавливаем следующий трек"));
        assertFalse(policy.maySkip("now","Не удалось запустить текущий трек"));
    }

    @Test public void errorMustMatchShownText() {
        FailedNextSkipPolicy policy=new FailedNextSkipPolicy();
        policy.reportFailed("now","bad","Не удалось подготовить следующий трек");
        assertFalse(policy.maySkip("now",FailedNextSkipPolicy.FAILURE_MESSAGE));
        policy.reportFailed("now","bad","Не удалось загрузить трек. Попробуй ещё раз.");
        assertFalse(policy.maySkip("now","Ошибка соединения"));
        assertTrue(policy.maySkip("now","Не удалось загрузить трек. Нажми Далее."));
        assertTrue(policy.wasFailed("now","bad"));
        assertFalse(policy.wasFailed("now","working"));
    }

    @Test public void skipBelongsToCurrentTrackOnly() {
        FailedNextSkipPolicy policy=new FailedNextSkipPolicy();
        policy.reportFailed("now","bad",FailedNextSkipPolicy.FAILURE_MESSAGE);
        assertFalse(policy.maySkip("another",FailedNextSkipPolicy.FAILURE_MESSAGE));
        assertFalse(policy.wasFailed("another","bad"));
        policy.reportFailed("another","other",FailedNextSkipPolicy.FAILURE_MESSAGE);
        assertFalse(policy.wasFailed("another","bad"));
        assertTrue(policy.wasFailed("another","other"));
    }

    @Test public void multipleFailuresCanBeBypassedAfterSecondError() {
        FailedNextSkipPolicy policy=new FailedNextSkipPolicy();
        policy.reportFailed("playing","bad-a",FailedNextSkipPolicy.FAILURE_MESSAGE);
        policy.reportFailed("playing","bad-b",FailedNextSkipPolicy.FAILURE_MESSAGE);
        assertTrue(policy.wasFailed("playing","bad-a"));
        assertTrue(policy.wasFailed("playing","bad-b"));
        assertFalse(policy.wasFailed("playing","good-c"));
        policy.clear();
        assertFalse(policy.maySkip("playing",FailedNextSkipPolicy.FAILURE_MESSAGE));
    }

    @Test public void noMessageMeansNoSkip() {
        FailedNextSkipPolicy policy=new FailedNextSkipPolicy();
        policy.reportFailed("now","bad",FailedNextSkipPolicy.FAILURE_MESSAGE);
        assertFalse(policy.maySkip("now",""));
        assertFalse(policy.maySkip("now","Сетевое соединение восстанавливается"));
    }
}
