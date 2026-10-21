package fun.nightwell.music;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.view.View;
import java.util.Random;

/** Restrained autumn light and haze, rendered once behind the home controls. */
final class HalloweenAtmosphere extends View {
    private final Paint ink=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Shader grain;
    private Shader ember,haze;

    HalloweenAtmosphere(Context context){
        super(context);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        setClickable(false);
        setFocusable(false);
        Random random=new Random(20261031L);
        int[] pixels=new int[128*128];
        for(int i=0;i<pixels.length;i++){
            int tone=random.nextBoolean()?255:0;
            pixels[i]=Color.argb(random.nextInt(6),tone,tone,tone);
        }
        Bitmap texture=Bitmap.createBitmap(pixels,128,128,Bitmap.Config.ARGB_8888);
        grain=new BitmapShader(texture,Shader.TileMode.REPEAT,Shader.TileMode.REPEAT);
    }

    @Override protected void onSizeChanged(int w,int h,int oldW,int oldH){
        if(w<=0||h<=0)return;
        ember=new RadialGradient(w*1.06f,h*.3f,Math.max(w,h)*.6f,
                new int[]{0x42a45d2e,0x14563829,0x00563829},new float[]{0,.45f,1},Shader.TileMode.CLAMP);
        haze=new RadialGradient(w*.5f,h*.63f,Math.max(1,w*.9f),
                new int[]{0x166d7081,0x006d7081},null,Shader.TileMode.CLAMP);
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        int w=getWidth(),h=getHeight();
        if(w<=0||h<=0)return;
        ink.setShader(ember);canvas.drawRect(0,0,w,h,ink);
        // A wide, low veil of mist has no hard edge or illustrated silhouette.
        canvas.save();canvas.scale(1,.35f,w*.5f,h*.63f);
        ink.setShader(haze);canvas.drawRect(-w,-h,w*2,h*3,ink);canvas.restore();
        ink.setShader(grain);canvas.drawRect(0,0,w,h,ink);ink.setShader(null);
    }
}
