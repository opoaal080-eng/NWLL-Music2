package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.view.View;

/** Ambient Flow: soft monochrome waves driven by decoded music, never the microphone. */
final class RibbonView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private final AmbientFlowState flow = new AmbientFlowState();
    private final double[] incoming = new double[4];
    private final boolean[] enabled = {true,true,true,true};
    private boolean running, playing;
    private long lastFrame;
    double premiumSpeed=1,premiumIntensity=1,colorSpeed=1;
    String premiumTheme="nightwell";
    private java.util.function.IntToDoubleFunction bands=i->0;
    RibbonView(Context c) { super(c); setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO); setClickable(false); }
    void meter(java.util.function.DoubleSupplier unused) { }
    void bands(java.util.function.IntToDoubleFunction value) { bands=value; }
    void setAuraResponse(boolean voice,boolean low,boolean mid,boolean high) {
        enabled[0]=voice;enabled[1]=low;enabled[2]=mid;enabled[3]=high;invalidate();
    }
    void running(boolean value) {
        if(running!=value){running=value;lastFrame=0;flow.reset();invalidate();}
    }
    void playing(boolean value) {
        if(playing!=value){playing=value;lastFrame=0;if(!value)flow.reset();invalidate();}
    }
    void flash() { invalidate(); } // Likes do not synthesize an audio beat.
    @Override protected void onAttachedToWindow(){super.onAttachedToWindow();lastFrame=0;invalidate();}
    @Override protected void onDetachedFromWindow(){lastFrame=0;flow.reset();super.onDetachedFromWindow();}
    @Override protected void onWindowVisibilityChanged(int visibility){super.onWindowVisibilityChanged(visibility);lastFrame=0;if(visibility==VISIBLE)invalidate();}
    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if(!running||!playing||!isShown()||getWindowVisibility()!=VISIBLE||!android.animation.ValueAnimator.areAnimatorsEnabled())return;
        float w=getWidth(),h=getHeight(),scale=Math.min(w,h);
        if(scale<=1)return;
        long now=android.os.SystemClock.uptimeMillis();
        double dt=lastFrame==0?1.0/30:(now-lastFrame)/1000.0;lastFrame=now;
        for(int i=0;i<4;i++){try{incoming[i]=bands.applyAsDouble(i);}catch(RuntimeException ignored){incoming[i]=0;}}
        flow.update(incoming,enabled,premiumIntensity,premiumSpeed,dt);
        for(int stream=0;stream<4;stream++) {
            double level=flow.levels[stream],phase=flow.time+stream*1.7;
            if(level<.001)continue;
            path.reset();
            for(int step=0;step<=48;step++) {
                double u=step/48.0;
                float x=(float)(w*(-.16+u*1.32));
                float y=(float)(h*(.28+stream*.15+Math.sin(u*5.4+phase)*(.055+level*.055)+Math.sin(u*10.2-phase*.7+stream)*.022));
                if(step==0)path.moveTo(x,y);else path.lineTo(x,y);
            }
            paint.setStyle(Paint.Style.STROKE);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
            paint.setShader(new LinearGradient(-w*.16f,0,w*1.16f,0,
                    new int[]{0x00ffffff,0xffffffff,0xffffffff,0xffffffff,0x00ffffff},
                    new float[]{0,.2f,.54f,.82f,1},Shader.TileMode.CLAMP));
            // Nested low-opacity strokes feather the edge on Android 8+ without a full-screen software blur.
            for(int layer=11;layer>=0;layer--) {
                double fraction=layer/11.0;
                paint.setStrokeWidth((float)(scale*(.025+fraction*.20+level*.035)));
                paint.setAlpha((int)(255*level*(.018+(1-fraction)*.012)));
                canvas.drawPath(path,paint);
            }
            float cx=(float)(w*(.5+Math.sin(phase*.62)*.34));
            float cy=(float)(h*(.30+stream*.14+Math.cos(phase*.48)*.07));
            float radius=(float)(scale*(.30+level*.12));
            paint.setStyle(Paint.Style.FILL);paint.setAlpha(255);
            paint.setShader(new RadialGradient(cx,cy,radius,new int[]{Color.argb((int)(255*level*.065),255,255,255),0x00ffffff},null,Shader.TileMode.CLAMP));
            canvas.drawCircle(cx,cy,radius,paint);
        }
        paint.setShader(null);paint.setAlpha(255);
        postInvalidateDelayed(33);
    }
}
