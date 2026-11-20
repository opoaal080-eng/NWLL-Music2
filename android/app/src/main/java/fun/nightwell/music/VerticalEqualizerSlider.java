package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.MotionEvent;
import android.widget.SeekBar;

/** Fully Nightwell-drawn vertical EQ band. Retains drag and accessibility semantics. */
final class VerticalEqualizerSlider extends SeekBar {
    Runnable onCommit;
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    VerticalEqualizerSlider(Context context){
        super(context);
        setMax(24);
        setSplitTrack(false);
        setBackground(null);
    }

    @Override protected synchronized void onDraw(Canvas canvas){
        float cx=getWidth()/2f;
        float pad=NightwellDesign.dp(getContext(),13);
        float top=pad,bottom=Math.max(pad,getHeight()-pad);
        float fraction=(getProgress()-getMin())/(float)Math.max(1,getMax()-getMin());
        float thumbY=bottom-(bottom-top)*Math.max(0,Math.min(1,fraction));

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(NightwellDesign.dp(getContext(),5));
        paint.setColor(NightwellDesign.BORDER);
        canvas.drawLine(cx,top,cx,bottom,paint);
        paint.setColor(NightwellDesign.PRIMARY);
        canvas.drawLine(cx,thumbY,cx,bottom,paint);
        paint.setStyle(Paint.Style.FILL);
        canvas.drawCircle(cx,thumbY,NightwellDesign.dp(getContext(),isPressed()?9:7),paint);
    }

    @Override public boolean onTouchEvent(MotionEvent e){
        if(!isEnabled())return false;
        switch(e.getActionMasked()){
            case MotionEvent.ACTION_DOWN:
                getParent().requestDisallowInterceptTouchEvent(true);
                setPressed(true);
                break;
            case MotionEvent.ACTION_MOVE:
                break;
            case MotionEvent.ACTION_UP:
                setPressed(false);
                getParent().requestDisallowInterceptTouchEvent(false);
                performClick();
                if(onCommit!=null)post(onCommit);
                break;
            case MotionEvent.ACTION_CANCEL:
                setPressed(false);
                getParent().requestDisallowInterceptTouchEvent(false);
                return true;
            default:return false;
        }
        setProgress(Math.round(getMax()*(1-Math.max(0,Math.min(1,e.getY()/Math.max(1,getHeight()))))));
        return true;
    }
    @Override public boolean performClick(){return super.performClick();}
}
