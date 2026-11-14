package fun.nightwell.music;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.RenderEffect;
import android.graphics.Shader;
import android.os.Build;
import android.os.Looper;
import android.os.SystemClock;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import java.lang.ref.WeakReference;

/** Blurs a small snapshot of the content, while dock controls remain ordinary sibling views. */
final class DockBackdropView extends FrameLayout {
    private static final int DOWNSAMPLE = 6;
    private static final long CAPTURE_INTERVAL = 150;
    private final ImageView image;
    private final Paint mask = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final int[] sourceLocation = new int[2], ownLocation = new int[2];
    private final Runnable pending = this::capture;
    private WeakReference<View> source = new WeakReference<>(null);
    private Bitmap bitmap;
    private Canvas snapshot;
    private int[] pixels, scratch;
    private long lastCapture;
    private boolean capturing;

    DockBackdropView(Context context) {
        super(context);
        setClickable(false); setFocusable(false);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        setAlpha(.6f);
        setClipChildren(false);
        image = new ImageView(context);
        image.setScaleType(ImageView.ScaleType.FIT_XY);
        image.setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        addView(image, new FrameLayout.LayoutParams(-1, -1));
        mask.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
        if (Build.VERSION.SDK_INT >= 31) {
            float radius = 12 * getResources().getDisplayMetrics().density;
            image.setRenderEffect(RenderEffect.createBlurEffect(radius, radius, Shader.TileMode.CLAMP));
        }
    }

    /** Supply the content layer, which must exclude the dock and this backdrop. */
    void setSource(View view) {
        source = new WeakReference<>(view == this ? null : view);
        lastCapture = 0;
        refresh();
    }

    /** Call when content scrolls or changes; repeated requests share one throttled capture. */
    void refresh() {
        if (Looper.myLooper() != Looper.getMainLooper()) { post(this::refresh); return; }
        if (!isAttachedToWindow() || source.get() == null) return;
        removeCallbacks(pending);
        long remaining = CAPTURE_INTERVAL - (SystemClock.uptimeMillis() - lastCapture);
        if (remaining > 0) postDelayed(pending, remaining);
        else capture();
    }

    private void capture() {
        View content = source.get();
        if (capturing || content == null || !isAttachedToWindow()
                || !content.isAttachedToWindow() || getWidth() == 0 || getHeight() == 0) return;
        lastCapture = SystemClock.uptimeMillis();
        int width = Math.max(1, (getWidth() + DOWNSAMPLE - 1) / DOWNSAMPLE);
        int height = Math.max(1, (getHeight() + DOWNSAMPLE - 1) / DOWNSAMPLE);
        if (bitmap == null || bitmap.getWidth() != width || bitmap.getHeight() != height) {
            releaseBitmap();
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            snapshot = new Canvas(bitmap);
            if (Build.VERSION.SDK_INT < 31) {
                pixels = new int[width * height]; scratch = new int[width * height];
            }
        }
        content.getLocationOnScreen(sourceLocation);
        getLocationOnScreen(ownLocation);
        snapshot.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR);
        int saved = snapshot.save();
        snapshot.scale(width / (float) getWidth(), height / (float) getHeight());
        snapshot.translate(sourceLocation[0] - ownLocation[0], sourceLocation[1] - ownLocation[1]);
        capturing = true;
        try { content.draw(snapshot); }
        finally { capturing = false; snapshot.restoreToCount(saved); }
        if (Build.VERSION.SDK_INT < 31) blur(width, height);
        image.setImageBitmap(bitmap);
        image.invalidate(); invalidate();
    }

    @Override protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        int[] colors = new int[17]; float[] positions = new float[17];
        for (int i = 0; i < colors.length; i++) {
            float t = i / 16f;
            float smooth = t * t * t * (t * (t * 6 - 15) + 10);
            colors[i] = (Math.round(255 * smooth) << 24) | 0x00ffffff;
            positions[i] = t * .4f;
        }
        mask.setShader(new LinearGradient(0, 0, 0, Math.max(1, height), colors, positions,
            Shader.TileMode.CLAMP));
        post(this::refresh);
    }

    @Override protected void dispatchDraw(Canvas canvas) {
        if (capturing) return;
        int layer = canvas.saveLayer(0, 0, getWidth(), getHeight(), null);
        super.dispatchDraw(canvas);
        canvas.drawRect(0, 0, getWidth(), getHeight(), mask);
        canvas.restoreToCount(layer);
    }

    // Two separable box passes, at 1/6 resolution, keep pre-Android-12 devices inexpensive.
    private void blur(int width, int height) {
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height);
        boxPass(pixels, scratch, width, height, true);
        boxPass(scratch, pixels, width, height, false);
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height);
    }
    private static void boxPass(int[] input, int[] output, int width, int height, boolean horizontal) {
        int length = horizontal ? width : height, lines = horizontal ? height : width;
        int radius = 3, size = radius * 2 + 1;
        for (int line = 0; line < lines; line++) {
            int a = 0, r = 0, g = 0, b = 0;
            for (int i = -radius; i <= radius; i++) {
                int p = input[index(clamp(i, length), line, width, horizontal)];
                a += p >>> 24; r += p >> 16 & 255; g += p >> 8 & 255; b += p & 255;
            }
            for (int i = 0; i < length; i++) {
                output[index(i, line, width, horizontal)] = (a / size << 24)
                    | (r / size << 16) | (g / size << 8) | b / size;
                int remove = input[index(clamp(i - radius, length), line, width, horizontal)];
                int add = input[index(clamp(i + radius + 1, length), line, width, horizontal)];
                a += (add >>> 24) - (remove >>> 24);
                r += (add >> 16 & 255) - (remove >> 16 & 255);
                g += (add >> 8 & 255) - (remove >> 8 & 255);
                b += (add & 255) - (remove & 255);
            }
        }
    }
    private static int index(int along, int line, int width, boolean horizontal) {
        return horizontal ? line * width + along : along * width + line;
    }
    private static int clamp(int value, int length) { return Math.max(0, Math.min(length - 1, value)); }

    private void releaseBitmap() {
        image.setImageDrawable(null);
        if (bitmap != null) bitmap.recycle();
        bitmap = null; snapshot = null; pixels = null; scratch = null;
    }
    @Override protected void onAttachedToWindow() { super.onAttachedToWindow(); post(this::refresh); }
    @Override protected void onDetachedFromWindow() {
        removeCallbacks(pending);
        releaseBitmap();
        super.onDetachedFromWindow();
    }
}
