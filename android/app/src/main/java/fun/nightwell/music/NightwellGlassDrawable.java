package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;

/**
 * Draws a Nightwell frosted surface directly on Canvas.
 * It is deliberately independent from Android's Material widget skins.
 */
final class NightwellGlassDrawable extends Drawable {
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint edge = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final float radius;
    private final int tint;
    private int alpha = 255;

    NightwellGlassDrawable(Context c, float radiusDp, int tint){
        radius=NightwellDesign.dp(c,radiusDp);
        this.tint=tint;
        edge.setStyle(Paint.Style.STROKE);
        edge.setStrokeWidth(Math.max(1f,c.getResources().getDisplayMetrics().density));
    }

    @Override public void draw(Canvas canvas){
        Rect b=getBounds();
        if(b.isEmpty())return;
        float r=Math.min(radius,Math.min(b.width(),b.height())*.5f);
        RectF rect=new RectF(b.left+.8f,b.top+.8f,b.right-.8f,b.bottom-.8f);
        fill.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,
            new int[]{0x66565c65,tint,0x44303943},new float[]{0f,.46f,1f},Shader.TileMode.CLAMP));
        fill.setAlpha(alpha);
        canvas.drawRoundRect(rect,r,r,fill);
        fill.setShader(null);
        edge.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,
            new int[]{0x77ffffff,0x44ffffff,0x26ffffff},
            new float[]{0f,.45f,1f},Shader.TileMode.CLAMP));
        edge.setAlpha(alpha);
        canvas.drawRoundRect(rect,r,r,edge);
        edge.setShader(null);
    }
    @Override public void setAlpha(int value){alpha=value;invalidateSelf();}
    @Override public void setColorFilter(ColorFilter filter){fill.setColorFilter(filter);invalidateSelf();}
    @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
}