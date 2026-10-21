package fun.nightwell.music;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.drawable.Drawable;

/** Full-bleed Halloween background shared with the iOS visual design. */
final class NativeSceneryDrawable extends Drawable {
    private final Bitmap background;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private int alpha = 255;
    private ColorFilter filter;

    NativeSceneryDrawable(Context context) {
        background = BitmapFactory.decodeResource(context.getResources(), R.drawable.season_background);
    }

    @Override public void draw(Canvas canvas) {
        Rect bounds = getBounds();
        if (bounds.isEmpty()) return;
        if (background == null || background.isRecycled()) {
            canvas.drawColor(Color.rgb(14, 8, 25));
            return;
        }
        int bw = background.getWidth(), bh = background.getHeight();
        float scale = Math.max((float) bounds.width() / bw, (float) bounds.height() / bh);
        int srcW = Math.min(bw, Math.round(bounds.width() / scale));
        int srcH = Math.min(bh, Math.round(bounds.height() / scale));
        int x = (bw - srcW) / 2, y = (bh - srcH) / 2;
        paint.setAlpha(alpha);
        paint.setColorFilter(filter);
        canvas.drawBitmap(background, new Rect(x, y, x + srcW, y + srcH), bounds, paint);
    }

    @Override public void setAlpha(int value) { alpha = value; invalidateSelf(); }
    @Override public void setColorFilter(ColorFilter value) { filter = value; invalidateSelf(); }
    @Override public int getOpacity() { return PixelFormat.OPAQUE; }
}
