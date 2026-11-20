package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.widget.SeekBar;

/** Own-drawn Nightwell slider, preserving native drag and accessibility semantics. */
public final class NightwellSlider extends SeekBar {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    public NightwellSlider(Context context){
        super(context);
        setBackground(null);
        setMinimumHeight(NightwellDesign.dp(context,38));
        setSplitTrack(false);
    }
    @Override protected synchronized void onDraw(Canvas canvas){
        int w=getWidth(),h=getHeight();
        if(w==0||h==0)return;
        float pad=NightwellDesign.dp(getContext(),9);
        float left=Math.max(pad,getPaddingLeft()+pad/2);
        float right=Math.min(w-pad,w-getPaddingRight()-pad/2);
        float y=h/2f;
        float fraction=(getProgress()-getMin())/(float)Math.max(1,getMax()-getMin());
        float x=left+(right-left)*Math.min(1f,Math.max(0f,fraction));
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(NightwellDesign.dp(getContext(),4));
        paint.setColor(NightwellDesign.BORDER);
        canvas.drawLine(left,y,right,y,paint);
        paint.setColor(NightwellDesign.PRIMARY);
        canvas.drawLine(left,y,x,y,paint);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(isEnabled()?NightwellDesign.PRIMARY:NightwellDesign.MUTED);
        canvas.drawCircle(x,y,NightwellDesign.dp(getContext(),isPressed()?8:6),paint);
    }
}
