package fun.nightwell.music;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.os.SystemClock;
import android.view.View;

/** Lightweight animated cover-colour scenery; no per-frame bitmap decoding or blur. */
final class ArtworkAmbientView extends View {
    private final Paint glow = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final int[] from = {0xff24202b, 0xff1d222c};
    private final int[] target = {0xff24202b, 0xff1d222c};
    private long transitionStart;
    private boolean playing;
    private boolean reactive=true, gradient=true;
    private float speed=1f, strength=.12f, audioTarget, audioSmooth, transitionSpeed=1f;
    private String theme="nightwell";
    private final float density;

    ArtworkAmbientView(Context context) {
        super(context);
        density = context.getResources().getDisplayMetrics().density;
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        setClickable(false);
        setLayerType(View.LAYER_TYPE_HARDWARE, null);
    }

    void setPlaybackActive(boolean value) {
        if (playing != value) { playing=value; invalidate(); }
    }

    void setAudioLevel(double level) {
        float value=(float)(Double.isFinite(level)?Math.max(0,Math.min(1,level)):0);
        if(!playing||!reactive)value=0;
        if(Math.abs(audioTarget-value)>.004f){audioTarget=value;invalidate();}
    }

    void configure(boolean gradientEnabled, boolean musicReactive, float reactionStrength,
                   float motionSpeed, float coverTransitionSpeed, String selectedTheme) {
        boolean old=gradient;
        gradient=gradientEnabled;
        reactive=musicReactive;
        strength=Math.max(0f,Math.min(.26f,reactionStrength));
        speed=Math.max(.15f,Math.min(2.5f,motionSpeed));
        transitionSpeed=Math.max(.4f,Math.min(2.5f,coverTransitionSpeed));
        theme=selectedTheme==null?"nightwell":selectedTheme;
        if(!reactive)audioTarget=0;
        if(old!=gradient||isShown())invalidate();
    }

    int accentColor() { return target[0]; }

    void setArtwork(Bitmap bitmap) {
        int[] colors = palette(bitmap);
        if (target[0]==colors[0] && target[1]==colors[1]) return;
        long now=SystemClock.uptimeMillis();
        float blend=transitionStart==0?1f:Math.min(1f,(now-transitionStart)/(820f/transitionSpeed));
        from[0]=mix(from[0],target[0],blend);
        from[1]=mix(from[1],target[1],blend);
        target[0]=colors[0];target[1]=colors[1];
        transitionStart=now;
        invalidate();
    }

    private static int[] palette(Bitmap image) {
        if (image==null || image.isRecycled()) return new int[]{0xff24202b,0xff1d222c};
        float[] bins=new float[12];
        float[] rs=new float[12],gs=new float[12],bs=new float[12];
        float[] hsv=new float[3];
        int stepX=Math.max(1,image.getWidth()/26),stepY=Math.max(1,image.getHeight()/26);
        for(int y=stepY/2;y<image.getHeight();y+=stepY)
            for(int x=stepX/2;x<image.getWidth();x+=stepX){
                int pixel=image.getPixel(x,y);
                Color.colorToHSV(pixel,hsv);
                if(hsv[1]<.19f || hsv[2]<.2f || hsv[2]>.98f)continue;
                int bucket=((int)(hsv[0]/30f))%12;
                float weight=(.5f+hsv[1])*(.5f+hsv[2]);
                bins[bucket]+=weight;
                rs[bucket]+=Color.red(pixel)*weight;
                gs[bucket]+=Color.green(pixel)*weight;
                bs[bucket]+=Color.blue(pixel)*weight;
            }
        int first=-1,second=-1;
        for(int i=0;i<bins.length;i++)if(bins[i]>0&&(first<0||bins[i]>bins[first]))first=i;
        if(first<0)return new int[]{0xff24202b,0xff1d222c};
        for(int i=0;i<bins.length;i++){
            int distance=Math.min(Math.abs(i-first),12-Math.abs(i-first));
            if(distance>=2&&bins[i]>0&&(second<0||bins[i]>bins[second]))second=i;
        }
        int a=average(first,bins,rs,gs,bs);
        int b=second>=0?average(second,bins,rs,gs,bs):mix(a,0xff2b182c,.35f);
        return new int[]{a,b};
    }

    private static int average(int i,float[] weight,float[] r,float[] g,float[] b) {
        return Color.rgb(Math.round(r[i]/weight[i]),Math.round(g[i]/weight[i]),Math.round(b[i]/weight[i]));
    }

    private static int mix(int a,int b,float fraction){
        float t=Math.max(0f,Math.min(1f,fraction));
        return Color.rgb(
            (int)(Color.red(a)+(Color.red(b)-Color.red(a))*t),
            (int)(Color.green(a)+(Color.green(b)-Color.green(a))*t),
            (int)(Color.blue(a)+(Color.blue(b)-Color.blue(a))*t));
    }

    private void layer(Canvas canvas,float x,float y,float radius,int tint,int opacity){
        int center=Color.argb(opacity,Color.red(tint),Color.green(tint),Color.blue(tint));
        glow.setShader(new RadialGradient(x,y,radius,
            new int[]{center,Color.argb(opacity/3,Color.red(tint),Color.green(tint),Color.blue(tint)),Color.TRANSPARENT},
            new float[]{0f,.42f,1f},Shader.TileMode.CLAMP));
        canvas.drawRect(0,0,getWidth(),getHeight(),glow);
        glow.setShader(null);
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        canvas.drawColor(0xff08080b);
        if(!gradient)return;
        int width=getWidth(),height=getHeight();
        if(width<=0||height<=0)return;
        boolean motion=android.animation.ValueAnimator.areAnimatorsEnabled();
        float transition=transitionStart==0?1f:Math.min(1f,
            (SystemClock.uptimeMillis()-transitionStart)/(820f/transitionSpeed));
        int a=mix(from[0],target[0],transition);
        int b=mix(from[1],target[1],transition);
        // Preserve cover colours. Premium themes add just a light undertone.
        int themeAccent="ocean".equals(theme)?0xff177d9e:
            "aurora".equals(theme)?0xff35a681:"sunset".equals(theme)?0xffe07353:0xff08080b;
        if(!"nightwell".equals(theme)){
            a=mix(a,themeAccent,.12f);
            b=mix(b,themeAccent,.12f);
        }
        audioSmooth+=(audioTarget-audioSmooth)*.11f;
        float pulse=(playing&&reactive)?audioSmooth*strength:0f;
        double t=motion?SystemClock.uptimeMillis()/1000.0*
            (playing?.10:.008)*speed:0;
        float span=Math.max(width,height);
        layer(canvas,width*(.16f+.09f*(float)Math.sin(t)),
            height*(.28f+.08f*(float)Math.cos(t*.7)),
            span*(.80f+pulse*.20f),a,Math.min(180,125+(int)(pulse*140)));
        layer(canvas,width*(.87f+.10f*(float)Math.cos(t*.81)),
            height*(.78f+.09f*(float)Math.sin(t*.93)),
            span*(.79f+pulse*.25f),b,Math.min(180,117+(int)(pulse*145)));
        layer(canvas,width*(.43f+.09f*(float)Math.cos(t*.43+2)),
            height*(.56f+.07f*(float)Math.sin(t*.66)),
            span*(.54f+pulse*.14f),mix(a,b,.45f),Math.min(112,58+(int)(pulse*100)));
        if(motion&&isShown()&&getWindowVisibility()==VISIBLE)postInvalidateDelayed(50);
    }
}
