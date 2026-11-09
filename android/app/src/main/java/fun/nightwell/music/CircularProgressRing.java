package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.widget.FrameLayout;

/** Track progress lives around the mini-player play control, never across the dock. */
final class CircularProgressRing extends FrameLayout {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF bounds = new RectF();
    private float progress;
    private int accent=0xffdddddd;
    private final float stroke;

    CircularProgressRing(Context context) {
        super(context);
        stroke=2.4f*getResources().getDisplayMetrics().density;
        setWillNotDraw(false);
        setClipChildren(false);
        setClipToPadding(false);
    }

    void setProgress(double ratio){
        float next=(float)Math.max(0,Math.min(1,Double.isFinite(ratio)?ratio:0));
        if(Math.abs(next-progress)>.0005f){progress=next;invalidate();}
    }

    void setAccent(int color){
        int next=Color.rgb(Color.red(color),Color.green(color),Color.blue(color));
        if(next!=accent){accent=next;invalidate();}
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        float cx=getWidth()/2f,cy=getHeight()/2f;
        float radius=Math.min(cx,cy)-stroke-2f*getResources().getDisplayMetrics().density;
        if(radius<=0)return;
        bounds.set(cx-radius,cy-radius,cx+radius,cy+radius);
        paint.setShader(null);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(stroke);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(0x48ffffff);
        canvas.drawArc(bounds,0,360,false,paint);
        if(progress>0f){
            paint.setColor(accent);
            canvas.drawArc(bounds,-90,progress*360f,false,paint);
        }
    }
}
