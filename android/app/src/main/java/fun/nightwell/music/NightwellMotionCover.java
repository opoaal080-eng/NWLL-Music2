package fun.nightwell.music;

import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.Shader;
import android.os.Build;
import android.view.View;
import android.view.animation.AccelerateDecelerateInterpolator;
import android.widget.ImageView;

/**
 * Lightweight Ken Burns artwork motion, without fetching video or decoding
 * frames. The vertical alpha falloff blends the cover into the player.
 * Animations are disposed when the view is detached.
 */
public final class NightwellMotionCover extends ImageView {
    private final Paint fadeMask=new Paint(Paint.ANTI_ALIAS_FLAG);
    private AnimatorSet motion;

    public NightwellMotionCover(Context context){super(context);setLayerType(View.LAYER_TYPE_HARDWARE,null);}

    @Override protected void onDraw(Canvas canvas){
        if(getWidth()<=0||getHeight()<=0){super.onDraw(canvas);return;}
        int layer=canvas.saveLayer(0,0,getWidth(),getHeight(),null);
        super.onDraw(canvas);
        float height=getHeight();
        fadeMask.setShader(new LinearGradient(0,0,0,height,
            new int[]{0x00ffffff,0x66ffffff,0xffffffff,0xffffffff,0x66ffffff,0x00ffffff},
            new float[]{0f,.12f,.31f,.69f,.88f,1f},Shader.TileMode.CLAMP));
        fadeMask.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
        canvas.drawRect(0,0,getWidth(),getHeight(),fadeMask);
        fadeMask.setXfermode(null);
        fadeMask.setShader(null);
        canvas.restoreToCount(layer);
    }

    @Override protected void onAttachedToWindow(){
        super.onAttachedToWindow();
        if(Build.VERSION.SDK_INT>=26&&!ValueAnimator.areAnimatorsEnabled())return;
        if(!getContext().getSharedPreferences("appearance",Context.MODE_PRIVATE)
                .getBoolean("nw-animated-album-artwork",true))return;
        ObjectAnimator scaleX=ObjectAnimator.ofFloat(this,View.SCALE_X,1.035f,1.085f);
        ObjectAnimator scaleY=ObjectAnimator.ofFloat(this,View.SCALE_Y,1.035f,1.085f);
        ObjectAnimator move=ObjectAnimator.ofFloat(this,View.TRANSLATION_X,7f,-7f);
        ObjectAnimator vertical=ObjectAnimator.ofFloat(this,View.TRANSLATION_Y,-6f,6f);
        ObjectAnimator tilt=ObjectAnimator.ofFloat(this,View.ROTATION,-0.45f,0.45f);
        for(ObjectAnimator animator:new ObjectAnimator[]{scaleX,scaleY,move,vertical,tilt}){
            animator.setDuration(8500);
            animator.setInterpolator(new AccelerateDecelerateInterpolator());
            animator.setRepeatCount(ValueAnimator.INFINITE);
            animator.setRepeatMode(ValueAnimator.REVERSE);
        }
        motion=new AnimatorSet();
        motion.playTogether(scaleX,scaleY,move,vertical,tilt);
        motion.start();
    }

    @Override protected void onDetachedFromWindow(){
        if(motion!=null){motion.cancel();motion=null;}
        super.onDetachedFromWindow();
    }
}
