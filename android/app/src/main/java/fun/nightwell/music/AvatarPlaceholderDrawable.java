package fun.nightwell.music;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.drawable.Drawable;

/** Clean user silhouette in place of Android's unrelated system Places icon. */
final class AvatarPlaceholderDrawable extends Drawable {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

    @Override public void draw(Canvas canvas) {
        Rect bounds = getBounds();
        float side = Math.min(bounds.width(), bounds.height());
        if (side <= 0) return;
        canvas.save();
        canvas.translate(bounds.centerX() - side / 2f, bounds.centerY() - side / 2f);
        canvas.scale(side / 24f, side / 24f);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.7f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setColor(0xfff0f1f4);
        canvas.drawCircle(12f, 8f, 3.5f, paint);
        Path shoulders = new Path();
        shoulders.moveTo(4.3f, 20f);
        shoulders.cubicTo(4.3f, 16.4f, 7.4f, 14.7f, 12f, 14.7f);
        shoulders.cubicTo(16.6f, 14.7f, 19.7f, 16.4f, 19.7f, 20f);
        canvas.drawPath(shoulders, paint);
        canvas.restore();
    }

    @Override public void setAlpha(int alpha) { paint.setAlpha(alpha); invalidateSelf(); }
    @Override public void setColorFilter(ColorFilter filter) { paint.setColorFilter(filter); invalidateSelf(); }
    @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
}
