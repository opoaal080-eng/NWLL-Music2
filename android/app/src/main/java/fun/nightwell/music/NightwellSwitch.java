package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.text.TextPaint;
import android.text.TextUtils;
import android.view.Gravity;
import android.widget.Switch;

/** Custom-painted switch and text with Android checked-state accessibility. */
@SuppressWarnings("deprecation")
public final class NightwellSwitch extends Switch {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint textPaint=new TextPaint(Paint.ANTI_ALIAS_FLAG);
    public NightwellSwitch(Context context){
        super(context);
        setGravity(Gravity.CENTER_VERTICAL);
        setBackground(NightwellDesign.ripple(context,NightwellDesign.SURFACE,13,false));
        setMinimumHeight(NightwellDesign.dp(context,52));
    }
    @Override protected void onDraw(Canvas canvas){
        final float density=getResources().getDisplayMetrics().density;
        final float trackW=47*density,trackH=28*density,thumb=10*density;
        final float right=getWidth()-getPaddingRight(),cy=getHeight()/2f;
        final float x=right-trackW,top=cy-trackH/2;
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(isChecked()?0xffe9e9eb:NightwellDesign.BORDER);
        canvas.drawRoundRect(x,top,right,top+trackH,trackH/2,trackH/2,paint);
        paint.setColor(isChecked()?NightwellDesign.BACKGROUND:NightwellDesign.PRIMARY);
        canvas.drawCircle(isChecked()?right-trackH/2:x+trackH/2,cy,thumb,paint);
        textPaint.setTextSize(getTextSize());
        textPaint.setTypeface(getTypeface());
        textPaint.setColor(getCurrentTextColor());
        float available=Math.max(0,x-getPaddingLeft()-13*density);
        CharSequence truncated=TextUtils.ellipsize(getText(),textPaint,available,TextUtils.TruncateAt.END);
        Paint.FontMetrics metrics=textPaint.getFontMetrics();
        float baseline=cy-(metrics.ascent+metrics.descent)/2;
        canvas.drawText(truncated.toString(),getPaddingLeft(),baseline,textPaint);
    }
}
