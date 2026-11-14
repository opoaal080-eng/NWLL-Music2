package fun.nightwell.music;

import android.content.Context;
import android.view.MotionEvent;
import android.widget.FrameLayout;

/**
 * Recognizes a horizontal swipe across the whole mini-player, even when it
 * begins over artwork, title or playback controls. Vertical scrolling and
 * regular button taps are delegated to the children without delay.
 */
final class MiniPlayerSwipeFrame extends FrameLayout {
    private final float captureDistance;
    private final float swipeDistance;
    private final Runnable swipeLeft, swipeRight;
    private float startX, startY;
    private boolean swiping;

    MiniPlayerSwipeFrame(Context context, Runnable swipeLeft, Runnable swipeRight) {
        super(context);
        this.swipeLeft = swipeLeft;
        this.swipeRight = swipeRight;
        float density = getResources().getDisplayMetrics().density;
        captureDistance = 12f * density;
        swipeDistance = 43f * density;
        setClickable(true);
    }

    @Override public boolean onInterceptTouchEvent(MotionEvent event) {
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                startX = event.getX();
                startY = event.getY();
                swiping = false;
                return false;
            case MotionEvent.ACTION_MOVE:
                if (swiping) return true;
                float dx = event.getX() - startX;
                float dy = event.getY() - startY;
                if (Math.abs(dx) > captureDistance
                        && Math.abs(dx) > Math.abs(dy) * 1.25f) {
                    swiping = true;
                    return true;
                }
                return false;
            case MotionEvent.ACTION_CANCEL:
            case MotionEvent.ACTION_UP:
                return swiping;
            default:
                return false;
        }
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_UP:
                float dx = event.getX() - startX;
                float dy = event.getY() - startY;
                boolean accepted = swiping && Math.abs(dx) >= swipeDistance
                        && Math.abs(dx) > Math.abs(dy) * 1.25f;
                swiping = false;
                if (accepted) {
                    if (dx < 0) swipeLeft.run();
                    else swipeRight.run();
                }
                return true;
            case MotionEvent.ACTION_CANCEL:
                swiping = false;
                return true;
            default:
                return true;
        }
    }
}
