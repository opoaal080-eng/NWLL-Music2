package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;

/** Template symbols for navigation, collection actions and library tiles. */
final class NavigationMenuIcon extends View {
    private final String kind;
    private final Paint ink = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private int color;

    NavigationMenuIcon(Context context, String kind, int color) {
        super(context);
        this.kind = kind;
        this.color = color;
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        ink.setStrokeWidth(1.8f);
        ink.setStrokeCap(Paint.Cap.ROUND);
        ink.setStrokeJoin(Paint.Join.ROUND);
    }

    void setColor(int value) {
        color = value;
        invalidate();
    }

    @Override protected void onDraw(Canvas canvas) {
        float width = getWidth() - getPaddingLeft() - getPaddingRight();
        float height = getHeight() - getPaddingTop() - getPaddingBottom();
        float size = Math.min(width, height);
        if (size <= 0) return;
        canvas.save();
        canvas.translate(getPaddingLeft() + (width-size)/2, getPaddingTop() + (height-size)/2);
        canvas.scale(size/24, size/24);
        ink.setColor(color);
        ink.setStyle(Paint.Style.STROKE);
        path.reset();
        switch (kind) {
            case "home":
                path.moveTo(2,11); path.lineTo(12,2.5f); path.lineTo(22,11);
                path.moveTo(4.7f,9); path.lineTo(4.7f,21); path.lineTo(10,21);
                path.lineTo(10,14); path.lineTo(14,14); path.lineTo(14,21);
                path.lineTo(19.3f,21); path.lineTo(19.3f,9);
                if (isSelected()) { path.close(); ink.setStyle(Paint.Style.FILL_AND_STROKE); }
                break;
            case "search":
                canvas.drawCircle(10.2f,10.2f,6.5f,ink);
                canvas.drawLine(15.2f,15.2f,21,21,ink);
                break;
            case "library":
                canvas.drawLine(8,2,16,2,ink);
                canvas.drawLine(6,5,18,5,ink);
                if (isSelected()) ink.setStyle(Paint.Style.FILL);
                canvas.drawRoundRect(3.6f,8,20.4f,22,3,3,ink);
                break;
            case "back":
            case "chevron":
                if (kind.equals("back")) canvas.scale(-1,1,12,12);
                path.moveTo(9,5); path.lineTo(16,12); path.lineTo(9,19);
                break;
            case "settings":
                for (int i = 0; i < 8; i++) {
                    double center = i * Math.PI / 4;
                    double[] angles = {-.36,-.25,-.18,.18,.25,.36};
                    float[] radii = {8,8,10.4f,10.4f,8,8};
                    for (int j = 0; j < angles.length; j++) {
                        float x = 12 + radii[j]*(float)Math.cos(center + angles[j]);
                        float y = 12 + radii[j]*(float)Math.sin(center + angles[j]);
                        if (i == 0 && j == 0) path.moveTo(x,y); else path.lineTo(x,y);
                    }
                }
                path.close();
                canvas.drawCircle(12,12,3.4f,ink);
                break;
            case "additional":
                for (int y = 7; y <= 17; y += 5) canvas.drawLine(2,y,22,y,ink);
                break;
            case "playlist":
                for (int y = 6; y <= 14; y += 4) canvas.drawLine(2,y,11,y,ink);
                path.moveTo(16,18); path.lineTo(16,5); path.lineTo(22,3.5f);
                path.lineTo(22,8); path.lineTo(16,9.5f);
                canvas.drawPath(path,ink);
                ink.setStyle(Paint.Style.FILL);
                canvas.drawOval(9.5f,16,17,22,ink);
                break;
            case "download":
                path.moveTo(12,2); path.lineTo(12,18);
                path.moveTo(5.5f,12); path.lineTo(12,18.5f); path.lineTo(18.5f,12);
                canvas.drawLine(3.5f,22,20.5f,22,ink);
                break;
            case "sparkles":
                ink.setStyle(Paint.Style.FILL);
                sparkle(canvas,14.4f,15,7.8f);
                sparkle(canvas,5.3f,9.2f,4.2f);
                sparkle(canvas,11,3.5f,2.5f);
                break;
            case "waveform":
                float[] peaks = {1,3.5f,7,10,5,8,3.5f,1};
                for (int i = 0; i < peaks.length; i++) {
                    float x = 1.5f+3*i;
                    canvas.drawLine(x,12-peaks[i],x,12+peaks[i],ink);
                }
                break;
            case "person":
                canvas.drawCircle(12,12,10,ink);
                canvas.drawCircle(12,9,3.1f,ink);
                path.moveTo(5.5f,19); path.cubicTo(6,12.4f,18,12.4f,18.5f,19);
                break;
            default:
                throw new IllegalArgumentException("Unknown navigation icon " + kind);
        }
        canvas.drawPath(path,ink);
        canvas.restore();
    }

    private void sparkle(Canvas canvas, float x, float y, float r) {
        path.reset();
        path.moveTo(x,y-r);
        path.quadTo(x+r*.12f,y-r*.14f,x+r*.78f,y);
        path.quadTo(x+r*.12f,y+r*.14f,x,y+r);
        path.quadTo(x-r*.12f,y+r*.14f,x-r*.78f,y);
        path.quadTo(x-r*.12f,y-r*.14f,x,y-r);
        canvas.drawPath(path,ink);
        path.reset();
    }
}
