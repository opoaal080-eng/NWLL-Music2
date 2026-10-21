package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.Drawable;

/** Quiet graphite canvas leaves the music aura as the only decorative layer. */
final class NativeSceneryDrawable extends Drawable {
    private final Paint paint=new Paint();
    NativeSceneryDrawable(Context context){}
    @Override public void draw(Canvas canvas){
        Rect b=getBounds();
        paint.setShader(new LinearGradient(0,b.top,0,b.bottom,0xff191b22,0xff111216,Shader.TileMode.CLAMP));
        canvas.drawRect(b,paint);
    }
    @Override public void setAlpha(int alpha){paint.setAlpha(alpha);invalidateSelf();}
    @Override public void setColorFilter(ColorFilter filter){paint.setColorFilter(filter);invalidateSelf();}
    @Override public int getOpacity(){return PixelFormat.OPAQUE;}
}
