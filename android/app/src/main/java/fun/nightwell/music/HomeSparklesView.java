package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.view.View;

/** Subtle white stars remain visible when music is paused. */
final class HomeSparklesView extends View {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final float[] x=new float[36],y=new float[36];
    HomeSparklesView(Context context){
        super(context);setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);setClickable(false);
        java.util.Random random=new java.util.Random(27102026);
        for(int i=0;i<36;i++){x[i]=random.nextFloat();y[i]=random.nextFloat();}
    }
    @Override protected void onWindowVisibilityChanged(int visibility){super.onWindowVisibilityChanged(visibility);if(visibility==VISIBLE)invalidate();}
    @Override protected void onVisibilityChanged(View view,int visibility){super.onVisibilityChanged(view,visibility);if(visibility==VISIBLE)invalidate();}
    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);boolean moving=android.animation.ValueAnimator.areAnimatorsEnabled();
        double t=moving?android.os.SystemClock.uptimeMillis()/1000.0:0;
        float density=getResources().getDisplayMetrics().density;
        for(int i=0;i<36;i++){
            double shimmer=moving?.5+.5*Math.sin(t*(.7+i%5*.14)+i*1.618):.55;
            float radius=(float)(density*(.55+shimmer*.65));
            paint.setColor(Color.argb((int)(255*(.09+shimmer*.37)),255,255,255));
            canvas.drawCircle(x[i]*getWidth(),y[i]*getHeight(),radius,paint);
        }
        if(moving&&isShown()&&getWindowVisibility()==VISIBLE)postInvalidateDelayed(50);
    }
}
