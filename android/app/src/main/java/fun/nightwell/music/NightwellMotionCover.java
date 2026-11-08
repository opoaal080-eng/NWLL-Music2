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
import androidx.appcompat.widget.AppCompatImageView;

/**
 * Lightweight Ken Burns artwork motion, without fetching video or decoding
 * frames. The vertical alpha falloff blends the cover into the player.
 * Animations are disposed when the view is detached.
 */
public final class NightwellMotionCover extends AppCompatImageView {
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
        ObjectAnimator scaleX=ObjectAnimator.ofFloat(this,View.SCALE_X,1.0f,1.045f);
        ObjectAnimator scaleY=ObjectAnimator.ofFloat(this,View.SCALE_Y,1.0f,1.045f);
        ObjectAnimator move=ObjectAnimator.ofFloat(this,View.TRANSLATION_X,4f,-4f);
        for(ObjectAnimator animator:new ObjectAnimator[]{scaleX,scaleY,move}){
            animator.setDuration(8500);
            animator.setInterpolator(new AccelerateDecelerateInterpolator());
            animator.setRepeatCount(ValueAnimator.INFINITE);
            animator.setRepeatMode(ValueAnimator.REVERSE);
        }
        motion=new AnimatorSet();
        motion.playTogether(scaleX,scaleY,move);
        motion.start();
    }

    @Override protected void onDetachedFromWindow(){
        if(motion!=null){motion.cancel();motion=null;}
        super.onDetachedFromWindow();
    }
}
