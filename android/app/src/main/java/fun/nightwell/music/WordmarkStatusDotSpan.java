package fun.nightwell.music;

import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.text.style.ReplacementSpan;
import androidx.annotation.NonNull;

/**
 * Repaints only the dot in the ordinary lowercase i.
 *
 * A dotless i with a combining dot may shift under font fallback and
 * TextView auto-sizing. Using the same glyph in both passes fixes alignment.
 */
final class WordmarkStatusDotSpan extends ReplacementSpan {
    private static final String LETTER = "i";
    private final int statusColor;
    private final Rect bounds = new Rect();

    WordmarkStatusDotSpan(int statusColor) {
        this.statusColor = statusColor;
    }

    @Override public int getSize(@NonNull Paint paint, CharSequence text,
                                 int start, int end, Paint.FontMetricsInt fm) {
        return Math.round(paint.measureText(LETTER));
    }

    @Override public void draw(@NonNull Canvas canvas, CharSequence text,
                               int start, int end, float x, int top, int y,
                               int bottom, @NonNull Paint paint) {
        int baseColor = paint.getColor();
        canvas.drawText(LETTER, x, y, paint);
        paint.getTextBounds(LETTER, 0, 1, bounds);
        float width = paint.measureText(LETTER);
        float dotBottom = y + bounds.top + paint.getTextSize() * .18f;
        int saved = canvas.save();
        canvas.clipRect(x - 1f, y + bounds.top - 1f,
                        x + width + 1f, dotBottom);
        paint.setColor(statusColor);
        canvas.drawText(LETTER, x, y, paint);
        paint.setColor(baseColor);
        canvas.restoreToCount(saved);
    }
}
