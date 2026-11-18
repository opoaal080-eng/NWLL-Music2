package fun.nightwell.music;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.os.Build;
import android.os.SystemClock;
import android.view.View;
import android.view.animation.LinearInterpolator;

/** Lightweight, local parallax for the actual palm leaf silhouettes in Vice Nights. */
final class PalmSwayOverlay extends View {
    private static Bitmap[] shared;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final Bitmap[] foliage;
    private ValueAnimator animator;
    private float phase;
    private long lastFrame;

    PalmSwayOverlay(Context context,int imageResource) {
        super(context);
        setClickable(false);
        setFocusable(false);
        foliage = getOrBuild(context,imageResource);
    }

    private static synchronized Bitmap[] getOrBuild(Context context,int drawable) {
        if (shared != null) return shared;
        BitmapFactory.Options options=new BitmapFactory.Options();
        options.inPreferredConfig=Bitmap.Config.ARGB_8888;
        options.inSampleSize=2; // Foliage uses silhouettes only; reduce memory and upload work.
        Bitmap source=BitmapFactory.decodeResource(context.getResources(),drawable,options);
        if(source==null)return new Bitmap[0];
        int w=source.getWidth(),h=source.getHeight();
        int[] original=new int[w*h];
        source.getPixels(original,0,w,0,0,w,h);
        Bitmap[] made=new Bitmap[3];
        for(int section=0;section<3;section++){
            int[] pixels=new int[original.length];
            for(int y=0;y<h;y++){
                double ny=(double)y/h;
                for(int x=0;x<w;x++){
                    double nx=(double)x/w;
                    int region=nx<.55?0:ny<.56?1:2;
                    if(region!=section)continue;
                    int originalPixel=original[y*w+x];
                    int red=(originalPixel>>16)&255, green=(originalPixel>>8)&255, blue=originalPixel&255;
                    // Very dark, blue-violet pixels are palm silhouettes, not the sunset sky.
                    double alpha=Math.min(1,Math.max(0,(70-red)/25.0))
                               *Math.min(1,Math.max(0,(48-green)/18.0))
                               *Math.min(1,Math.max(0,(100-blue)/28.0));
                    int a=(int)Math.round(225*alpha);
                    if(a!=0)pixels[y*w+x]=(a<<24)|(originalPixel&0x00ffffff);
                }
            }
            Bitmap mask=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888);
            mask.setPixels(pixels,0,w,0,0,w,h);
            made[section]=mask;
        }
        source.recycle();
        shared=made;
        return made;
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if(foliage.length!=3||getWidth()<1||getHeight()<1)return;
        int bw=foliage[0].getWidth(),bh=foliage[0].getHeight();
        float scale=Math.max((float)getWidth()/bw,(float)getHeight()/bh);
        float left=(getWidth()-bw*scale)/2f,top=(getHeight()-bh*scale)/2f;
        float[] pivotX={0f,1f,1f},pivotY={.42f,.20f,.90f};
        float[] degrees={.75f,-.85f,.65f};
        for(int i=0;i<3;i++){
            canvas.save();
            float t=phase+(float)(i*1.7);
            float amount=(float)Math.sin(t)*degrees[i];
            canvas.rotate(amount,left+pivotX[i]*bw*scale,top+pivotY[i]*bh*scale);
            canvas.translate(left,top);
            canvas.scale(scale,scale);
            canvas.drawBitmap(foliage[i],0,0,paint);
            canvas.restore();
        }
    }

    @Override protected void onAttachedToWindow() {super.onAttachedToWindow();updateAnimation();}
    @Override protected void onDetachedFromWindow() {stopAnimation();super.onDetachedFromWindow();}
    @Override protected void onWindowVisibilityChanged(int visibility) {super.onWindowVisibilityChanged(visibility);updateAnimation();}
    @Override protected void onVisibilityChanged(View changedView,int visibility) {super.onVisibilityChanged(changedView,visibility);updateAnimation();}

    private void updateAnimation(){
        boolean allowed=Build.VERSION.SDK_INT<26||ValueAnimator.areAnimatorsEnabled();
        boolean shouldRun=isAttachedToWindow()&&getVisibility()==VISIBLE&&getWindowVisibility()==VISIBLE&&allowed;
        if(!shouldRun){stopAnimation();return;}
        if(animator!=null)return;
        animator=ValueAnimator.ofFloat(0f,(float)(Math.PI*2));
        animator.setDuration(7200);
        animator.setRepeatCount(ValueAnimator.INFINITE);
        animator.setInterpolator(new LinearInterpolator());
        animator.addUpdateListener(animation->{
            phase=(float)animation.getAnimatedValue();
            long now=SystemClock.uptimeMillis();
            if(now-lastFrame>=55){lastFrame=now;invalidate();}
        });
        animator.start();
    }
    private void stopAnimation(){if(animator!=null){animator.cancel();animator=null;}}
}
