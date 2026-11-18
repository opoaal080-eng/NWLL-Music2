package fun.nightwell.music;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.os.SystemClock;
import android.view.View;
import android.view.animation.LinearInterpolator;

/** Three transparent moving palm fronds; the sunset underneath has no static leaves. */
final class PalmSwayOverlay extends View {
    private static Bitmap[] sharedFoliage;
    private final Bitmap[] foliage;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private ValueAnimator animator;
    private float phase;
    private long lastFrame;

    PalmSwayOverlay(Context context) {
        super(context);
        setClickable(false);
        setFocusable(false);
        foliage = getFoliage(context);
    }

    private static synchronized Bitmap[] getFoliage(Context context) {
        if (sharedFoliage != null) return sharedFoliage;
        int[] resources = {R.drawable.vice_fronds_0, R.drawable.vice_fronds_1,
                           R.drawable.vice_fronds_2};
        Bitmap[] images = new Bitmap[resources.length];
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inPreferredConfig = Bitmap.Config.ARGB_8888;
        options.inSampleSize = 2;
        for (int index = 0; index < resources.length; index++)
            images[index] = BitmapFactory.decodeResource(context.getResources(), resources[index], options);
        sharedFoliage = images;
        return images;
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (getWidth() < 1 || getHeight() < 1) return;
        float[] pivotX = {0f, 1f, 1f}, pivotY = {.42f, .20f, .90f};
        float[] degrees = {3.0f, -3.4f, 2.8f};
        for (int i = 0; i < foliage.length; i++) {
            Bitmap layer = foliage[i];
            if (layer == null) continue;
            float scale = Math.max((float)getWidth() / layer.getWidth(),
                                   (float)getHeight() / layer.getHeight());
            float left = (getWidth() - layer.getWidth() * scale) / 2f;
            float top = (getHeight() - layer.getHeight() * scale) / 2f;
            float amount = (float)Math.sin(phase + i * 1.7f) * degrees[i];
            canvas.save();
            canvas.rotate(amount,left + pivotX[i] * layer.getWidth() * scale,
                                 top + pivotY[i] * layer.getHeight() * scale);
            canvas.translate(left, top);
            canvas.scale(scale, scale);
            canvas.drawBitmap(layer, 0, 0, paint);
            canvas.restore();
        }
    }

    @Override protected void onAttachedToWindow(){super.onAttachedToWindow();updateAnimation();}
    @Override protected void onDetachedFromWindow(){stopAnimation();super.onDetachedFromWindow();}
    @Override protected void onWindowVisibilityChanged(int state){super.onWindowVisibilityChanged(state);updateAnimation();}
    @Override protected void onVisibilityChanged(View changedView,int state){super.onVisibilityChanged(changedView,state);updateAnimation();}

    private void updateAnimation() {
        boolean active = isAttachedToWindow() && getVisibility() == VISIBLE
                        && getWindowVisibility() == VISIBLE && ValueAnimator.areAnimatorsEnabled();
        if (!active) {stopAnimation();return;}
        if (animator != null) return;
        animator = ValueAnimator.ofFloat(0f,(float)(Math.PI * 2));
        animator.setDuration(6800);
        animator.setRepeatCount(ValueAnimator.INFINITE);
        animator.setInterpolator(new LinearInterpolator());
        animator.addUpdateListener(a -> {
            phase = (float)a.getAnimatedValue();
            long now = SystemClock.uptimeMillis();
            if (now - lastFrame >= 55) {lastFrame = now;invalidate();}
        });
        animator.start();
    }
    private void stopAnimation(){if(animator != null){animator.cancel();animator = null;}}
}
