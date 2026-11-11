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

/**
 * Artwork-derived COLORS ONLY. Never draws the cover bitmap.
 * Player preserves the artwork's spatial colour arrangement; Home slowly
 * moves the same palette as an ambient gradient.
 */
final class CoverPaletteView extends View {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG|Paint.FILTER_BITMAP_FLAG);
    private final int[] colors=new int[16];
    private boolean hasPalette,homeMode;
    private long start=SystemClock.uptimeMillis();
    CoverPaletteView(Context context){super(context);setLayerType(View.LAYER_TYPE_SOFTWARE,null);}
    void setHomeMode(boolean home){
        homeMode=home;invalidate();
    }
    void setArtwork(Bitmap bitmap){
        if(bitmap==null||bitmap.isRecycled()){
            hasPalette=false;invalidate();return;
        }
        // 4 x 4 spatial colour samples, each averaged over a neighbourhood.
        for(int y=0;y<4;y++)for(int x=0;x<4;x++){
            long red=0,green=0,blue=0;int count=0;
            for(int sy=0;sy<5;sy++)for(int sx=0;sx<5;sx++){
                int px=Math.min(bitmap.getWidth()-1,
                    Math.max(0,(int)((x+.16f+sx*.17f)/4f*bitmap.getWidth())));
                int py=Math.min(bitmap.getHeight()-1,
                    Math.max(0,(int)((y+.16f+sy*.17f)/4f*bitmap.getHeight())));
                int c=bitmap.getPixel(px,py);
                red+=Color.red(c);green+=Color.green(c);blue+=Color.blue(c);count++;
            }
            colors[y*4+x]=Color.rgb((int)(red/count),(int)(green/count),(int)(blue/count));
        }
        hasPalette=true;start=SystemClock.uptimeMillis();invalidate();
    }
    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        int w=getWidth(),h=getHeight();if(w<=0||h<=0)return;
        canvas.drawColor(0xff090a0e);
        if(!hasPalette)return;
        float t=(SystemClock.uptimeMillis()-start)/6000f;
        float radius=Math.max(w,h)*(homeMode?.73f:.57f);
        // Draw translucent soft colour pools, not an enlarged cover.
        for(int y=0;y<4;y++)for(int x=0;x<4;x++){
            int c=colors[y*4+x];
            float cx=(x+.5f)/4f*w;
            float cy=(y+.5f)/4f*h;
            if(homeMode){
                cx+=Math.sin(t*.43+x*.95+y*.31)*w*.14f;
                cy+=Math.cos(t*.35+y*.89+x*.27)*h*.12f;
            }
            int alpha=homeMode?100:115;
            paint.setShader(new RadialGradient(cx,cy,radius,
                new int[]{Color.argb(alpha,Color.red(c),Color.green(c),Color.blue(c)),
                    Color.argb(alpha/3,Color.red(c),Color.green(c),Color.blue(c)),
                    Color.TRANSPARENT},
                new float[]{0f,.45f,1f},Shader.TileMode.CLAMP));
            canvas.drawCircle(cx,cy,radius,paint);
        }
        paint.setShader(null);
        paint.setColor(0x76000000);
        canvas.drawRect(0,0,w,h,paint);
        if(homeMode)postInvalidateDelayed(70);
    }
}
