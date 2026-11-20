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
 * Nightwell's own pressable glass surface. No Android RippleDrawable,
 * Material button skin, ActionBar, or platform-themed pressed indicator.
 */
final class NightwellPressDrawable extends Drawable {
    private final Paint brush=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint borderPaint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final float radius;
    private final int color;
    private final boolean outlined;
    private boolean pressed;
    private int alpha=255;

    NightwellPressDrawable(Context context,int color,float radiusDp,boolean border){
        this.radius=NightwellDesign.dp(context,radiusDp);
        this.color=color;
        outlined=border;
        borderPaint.setStyle(Paint.Style.STROKE);
        borderPaint.setStrokeWidth(Math.max(1f,context.getResources().getDisplayMetrics().density*.85f));
    }

    @Override public boolean isStateful(){return true;}
    @Override protected boolean onStateChange(int[] states){
        boolean value=false;
        for(int state:states)if(state==android.R.attr.state_pressed) {value=true;break;}
        if(pressed==value)return false;
        pressed=value;invalidateSelf();return true;
    }
    @Override public void draw(Canvas canvas){
        Rect b=getBounds();
        if(b.isEmpty())return;
        float r=Math.min(radius,Math.min(b.width(),b.height())/2f);
        RectF rect=new RectF(b.left+.7f,b.top+.7f,b.right-.7f,b.bottom-.7f);
        brush.setStyle(Paint.Style.FILL);
        brush.setColor(color);
        brush.setAlpha(alpha);
        canvas.drawRoundRect(rect,r,r,brush);
        brush.setColor(pressed?0x26ffffff:0x06ffffff);
        canvas.drawRoundRect(rect,r,r,brush);
        brush.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,
            new int[]{pressed?0x1affffff:0x20ffffff,0x00000000,0x12000000},
            new float[]{0f,.5f,1f},Shader.TileMode.CLAMP));
        canvas.drawRoundRect(rect,r,r,brush);
        brush.setShader(null);
        if(outlined){
            borderPaint.setColor(pressed?0x88ffffff:0x42ffffff);
            borderPaint.setAlpha(alpha);
            canvas.drawRoundRect(rect,r,r,borderPaint);
        }
    }
    @Override public void setAlpha(int value){alpha=value;invalidateSelf();}
    @Override public void setColorFilter(ColorFilter filter){brush.setColorFilter(filter);invalidateSelf();}
    @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
}