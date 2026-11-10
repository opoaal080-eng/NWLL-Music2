package fun.nightwell.music;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.SystemClock;
import android.widget.FrameLayout;

/**
 * Mini-player progress. The circle stays around Play/Pause instead of
 * stretching across the mini-player dock.
 *
 * White arc: playback; muted arc: buffered audio.
 * During handoff the white arc represents staged audio preparation.
 * If the source doesn't expose a buffered fraction, use an indeterminate
 * moving arc rather than inventing a percentage.
 */
final class CircularProgressRing extends FrameLayout {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF bounds = new RectF();
    private final float density;
    private float played;
    private float buffered;
    private float prepared;
    private boolean preparing;
    private boolean buffering;

    CircularProgressRing(Context context) {
        super(context);
        density=getResources().getDisplayMetrics().density;
        setWillNotDraw(false);
        setClipChildren(false);
        setClipToPadding(false);
    }

    void setPlaybackState(double playedRatio,double bufferedRatio,
                          boolean isPreparing,double preparedRatio,boolean isBuffering){
        float nextPlayed=clamp(playedRatio);
        float nextBuffered=clamp(bufferedRatio);
        float nextPrepared=clamp(preparedRatio);
        if(played==nextPlayed && buffered==nextBuffered &&
            prepared==nextPrepared && preparing==isPreparing &&
            buffering==isBuffering)return;
        played=nextPlayed;
        buffered=nextBuffered;
        prepared=nextPrepared;
        preparing=isPreparing;
        buffering=isBuffering;
        invalidate();
    }

    private static float clamp(double value){
        return Double.isFinite(value)?(float)Math.max(0,Math.min(1,value)):0;
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        float thickness=2.5f*density;
        float radius=Math.min(getWidth(),getHeight())/2f-thickness/2f-1.7f*density;
        if(radius<=0)return;
        float cx=getWidth()/2f,cy=getHeight()/2f;
        bounds.set(cx-radius,cy-radius,cx+radius,cy+radius);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(thickness);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setShader(null);

        paint.setColor(0x55ffffff);
        canvas.drawArc(bounds,-90,360,false,paint);

        // Preparing the next track while the previous one is still audible.
        if(preparing){
            paint.setColor(0x55ffffff);
            if(played>.002f)canvas.drawArc(bounds,-90,played*360f,false,paint);
            if(prepared>.008f){
                paint.setColor(0xfff5f6f8);
                canvas.drawArc(bounds,-90,prepared*360f,false,paint);
            }else if(ValueAnimator.areAnimatorsEnabled()){
                float phase=(SystemClock.uptimeMillis()%1350L)/1350f;
                paint.setColor(0xfff5f6f8);
                canvas.drawArc(bounds,-90+phase*360f,78,false,paint);
            }else{
                paint.setColor(0xfff5f6f8);
                canvas.drawArc(bounds,-90,68,false,paint);
            }
        }else{
            if(buffered>.002f){
                paint.setColor(0x99ffffff);
                canvas.drawArc(bounds,-90,buffered*360f,false,paint);
            }
            if(played>.002f){
                paint.setColor(0xfff5f6f8);
                canvas.drawArc(bounds,-90,played*360f,false,paint);
            }
            if(buffering && buffered<=played+.01f){
                if(ValueAnimator.areAnimatorsEnabled()){
                    float phase=(SystemClock.uptimeMillis()%1350L)/1350f;
                    paint.setColor(0xfff5f6f8);
                    canvas.drawArc(bounds,-90+phase*360f,78,false,paint);
                }else{
                    paint.setColor(0xfff5f6f8);
                    canvas.drawArc(bounds,-90,68,false,paint);
                }
            }
        }
        if(((preparing&&prepared<=.008f)||
             (!preparing&&buffering&&buffered<=played+.01f))&&
             ValueAnimator.areAnimatorsEnabled()&&isShown()){
            postInvalidateDelayed(33);
        }
    }
}
