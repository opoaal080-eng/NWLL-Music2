package fun.nightwell.music;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.SystemClock;
import android.widget.SeekBar;

/**
 * Native scrubbing, playback and buffered secondary progress stay intact.
 * Only the preparation overlay is custom, in the same horizontal track.
 */
final class PreparingSeekBar extends SeekBar {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF stripe=new RectF();
    private final float density;
    private boolean preparing;
    private float prepared;

    PreparingSeekBar(Context context){
        super(context);
        density=getResources().getDisplayMetrics().density;
    }

    void setPreparation(boolean active,double fraction){
        float next=Double.isFinite(fraction)?
            (float)Math.max(0,Math.min(1,fraction)):0;
        if(active==preparing&&Math.abs(prepared-next)<.001f)return;
        preparing=active;
        prepared=next;
        invalidate();
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        if(!preparing)return;
        // In parallel with the still-audible track's main progress, show
        // incoming-audio readiness as a thin white strip above the slider.
        float left=getPaddingLeft()+6f*density;
        float right=getWidth()-getPaddingRight()-6f*density;
        if(right<=left)return;
        float width=right-left;
        float height=2.2f*density;
        float y=getHeight()/2f-7f*density;
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(null);
        paint.setColor(0x36ffffff);
        stripe.set(left,y,left+width,y+height);
        canvas.drawRoundRect(stripe,height/2f,height/2f,paint);
        if(prepared>.008f){
            paint.setColor(0xaaffffff);
            stripe.set(left,y,left+width*prepared,y+height);
            canvas.drawRoundRect(stripe,height/2f,height/2f,paint);
        }else{
            float phase=ValueAnimator.areAnimatorsEnabled()?
                (SystemClock.uptimeMillis()%1450L)/1450f:.45f;
            float shimmer=Math.min(width*.34f,95f*density);
            float x=left-shimmer+(width+shimmer)*phase;
            paint.setColor(0xb8ffffff);
            stripe.set(Math.max(left,x),y,Math.min(right,x+shimmer),y+height);
            if(stripe.right>stripe.left)
                canvas.drawRoundRect(stripe,height/2f,height/2f,paint);
            if(ValueAnimator.areAnimatorsEnabled()&&isShown())
                postInvalidateDelayed(33);
        }
    }
}
