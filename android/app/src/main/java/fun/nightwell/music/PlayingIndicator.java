package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.view.View;
final class PlayingIndicator extends View {
    private final Paint paint=new Paint(3);private boolean playing;
    PlayingIndicator(Context context){super(context);paint.setColor(0xffffb260);}
    void playing(boolean value){playing=value;setContentDescription(value?"Сейчас играет":"На паузе");invalidate();}
    @Override protected void onDraw(Canvas canvas){super.onDraw(canvas);float w=getWidth()/7f;double t=android.os.SystemClock.uptimeMillis()/180.0;for(int i=0;i<4;i++){float h=(float)(getHeight()*(playing&&android.animation.ValueAnimator.areAnimatorsEnabled()?.25+.7*Math.abs(Math.sin(t+i*1.1)):.25));canvas.drawRoundRect(i*w*2,(getHeight()-h)/2,i*w*2+w,(getHeight()+h)/2,w/2,w/2,paint);}if(playing&&isShown()&&android.animation.ValueAnimator.areAnimatorsEnabled())postInvalidateDelayed(100);}
}
