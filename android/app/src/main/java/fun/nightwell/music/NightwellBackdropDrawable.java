package fun.nightwell.music;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.RadialGradient;
import android.graphics.Rect;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;

/** Original Nightwell canvas gradient, no Material or system UI background. */
final class NightwellBackdropDrawable extends Drawable {
    private final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);
    private int alpha=255;
    private boolean library;

    void setLibrary(boolean value) {
        if (library != value) { library = value; invalidateSelf(); }
    }
    @Override public void draw(Canvas canvas){
        Rect b=getBounds();if(b.isEmpty())return;
        if (library) {
            p.setShader(new LinearGradient(0,b.top,0,b.bottom,
                new int[]{0xff0d1014,0xff080b0d,0xff030606,0xff151517},
                new float[]{0f,.56f,.81f,.94f},Shader.TileMode.CLAMP));
            p.setAlpha(alpha);
            canvas.drawRect(b,p);
            p.setShader(null);
            return;
        }
        p.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,
            new int[]{0xff11151e,0xff080a10,0xff030407},
            new float[]{0f,.55f,1f},Shader.TileMode.CLAMP));
        p.setAlpha(alpha);
        canvas.drawRect(b,p);
        p.setShader(new RadialGradient(b.width()*.84f,b.height()*.23f,
            Math.max(b.width(),b.height())*.63f,
            new int[]{0x482e3d64,0x14263146,0x00000000},
            new float[]{0f,.45f,1f},Shader.TileMode.CLAMP));
        canvas.drawRect(b,p);
        p.setShader(new LinearGradient(b.left,b.top,b.left,b.bottom,
            new int[]{0x18000000,0x00000000,0x99000000},
            new float[]{0f,.46f,1f},Shader.TileMode.CLAMP));
        canvas.drawRect(b,p);
        p.setShader(null);
    }
    @Override public void setAlpha(int v){alpha=v;invalidateSelf();}
    @Override public void setColorFilter(ColorFilter f){p.setColorFilter(f);invalidateSelf();}
    @Override public int getOpacity(){return PixelFormat.OPAQUE;}
}