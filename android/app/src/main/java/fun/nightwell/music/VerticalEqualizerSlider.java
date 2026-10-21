package fun.nightwell.music;
import android.content.Context;
import android.graphics.Canvas;
import android.view.MotionEvent;
import android.widget.SeekBar;

/** Native SeekBar semantics and accessibility, oriented vertically. */
final class VerticalEqualizerSlider extends SeekBar {
 Runnable onCommit;
 VerticalEqualizerSlider(Context c){super(c);setMax(24);setSplitTrack(false);}
 @Override protected synchronized void onMeasure(int w,int h){super.onMeasure(h,w);setMeasuredDimension(getMeasuredHeight(),getMeasuredWidth());}
 @Override protected void onSizeChanged(int w,int h,int oldw,int oldh){super.onSizeChanged(h,w,oldh,oldw);}
 @Override protected synchronized void onDraw(Canvas c){c.rotate(-90);c.translate(-getHeight(),0);super.onDraw(c);}
 @Override public boolean onTouchEvent(MotionEvent e){if(!isEnabled())return false;switch(e.getActionMasked()){case MotionEvent.ACTION_DOWN:getParent().requestDisallowInterceptTouchEvent(true);setPressed(true);break;case MotionEvent.ACTION_MOVE:break;case MotionEvent.ACTION_UP:setPressed(false);getParent().requestDisallowInterceptTouchEvent(false);performClick();if(onCommit!=null)post(onCommit);break;case MotionEvent.ACTION_CANCEL:setPressed(false);getParent().requestDisallowInterceptTouchEvent(false);return true;default:return false;}setProgress(Math.round(getMax()*(1-Math.max(0,Math.min(1,e.getY()/Math.max(1,getHeight()))))));return true;}
 @Override public boolean performClick(){return super.performClick();}
}
