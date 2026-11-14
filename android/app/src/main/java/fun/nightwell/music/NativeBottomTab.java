package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.Gravity;
import android.widget.TextView;

/** A consistent, font-independent icon above each bottom navigation label. */
final class NativeBottomTab extends TextView {
    private final String kind;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

    NativeBottomTab(Context context, String kind) {
        super(context);
        this.kind = kind;
        setIncludeFontPadding(false);
        setGravity(Gravity.CENTER_HORIZONTAL | Gravity.BOTTOM);
        setSingleLine(true);
        setTextSize(11f);
        setPadding(0, 0, 0, (int) (5 * getResources().getDisplayMetrics().density));
        setWillNotDraw(false);
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float density = getResources().getDisplayMetrics().density;
        float side = Math.min(25f * density, Math.min(getWidth() * .52f, getHeight() * .48f));
        if (side < 1) return;
        canvas.save();
        canvas.translate((getWidth() - side) / 2f, 5f * density);
        canvas.scale(side / 24f, side / 24f);
        paint.setColor(getCurrentTextColor());
        paint.setStrokeWidth(1.85f);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setStrokeCap(Paint.Cap.ROUND);
        Path p = new Path();
        switch (kind) {
            case "home":
                p.moveTo(3, 11); p.lineTo(12, 3); p.lineTo(21, 11);
                p.moveTo(5.6f, 10); p.lineTo(5.6f, 21); p.lineTo(18.4f, 21); p.lineTo(18.4f, 10);
                p.moveTo(10, 21); p.lineTo(10, 15); p.lineTo(14, 15); p.lineTo(14, 21);
                break;
            case "search":
                canvas.drawCircle(10, 10, 6.5f, paint);
                p.moveTo(15, 15); p.lineTo(21, 21);
                break;
            case "library":
                canvas.drawRoundRect(4, 3, 20, 21, 2, 2, paint);
                p.moveTo(8, 8); p.lineTo(16, 8);
                p.moveTo(8, 12); p.lineTo(16, 12);
                p.moveTo(8, 16); p.lineTo(14, 16);
                break;
            case "premium":
                p.moveTo(12, 2); p.lineTo(14.3f, 9.7f); p.lineTo(22, 12);
                p.lineTo(14.3f, 14.3f); p.lineTo(12, 22);
                p.lineTo(9.7f, 14.3f); p.lineTo(2, 12);
                p.lineTo(9.7f, 9.7f); p.close();
                break;
            default:
                canvas.drawCircle(12, 12, 7, paint);
        }
        canvas.drawPath(p, paint);
        canvas.restore();
    }
}
