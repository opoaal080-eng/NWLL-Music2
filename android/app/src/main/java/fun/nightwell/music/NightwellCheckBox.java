package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.text.TextPaint;
import android.text.Layout;
import android.text.StaticLayout;
import android.widget.CheckBox;

/** Own-drawn premium consent control. Preserves checked state and semantics. */
public final class NightwellCheckBox extends CheckBox {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint type=new TextPaint(Paint.ANTI_ALIAS_FLAG);
    public NightwellCheckBox(Context context){
        super(context);
        setButtonDrawable(android.R.color.transparent);
        setPadding(NightwellDesign.dp(context,8),NightwellDesign.dp(context,9),
            NightwellDesign.dp(context,8),NightwellDesign.dp(context,9));
        setMinHeight(NightwellDesign.dp(context,78));
    }
    @Override protected void onDraw(Canvas canvas){
        float density=getResources().getDisplayMetrics().density;
        float box=23*density,cy=getHeight()/2f;
        float x=getPaddingLeft(),y=cy-box/2;
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(isChecked()?NightwellDesign.PRIMARY:NightwellDesign.FIELD);
        canvas.drawRoundRect(x,y,x+box,y+box,6*density,6*density,paint);
        if(!isChecked()){
            paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(density);
            paint.setColor(NightwellDesign.BORDER);
            canvas.drawRoundRect(x,y,x+box,y+box,6*density,6*density,paint);
            paint.setStyle(Paint.Style.FILL);
        }else{
            paint.setColor(NightwellDesign.BACKGROUND);
            paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(2.4f*density);
            paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
            android.graphics.Path tick=new android.graphics.Path();
            tick.moveTo(x+5*density,cy);tick.lineTo(x+10*density,cy+4*density);tick.lineTo(x+18*density,cy-5*density);
            canvas.drawPath(tick,paint);paint.setStyle(Paint.Style.FILL);
        }
        type.setTypeface(getTypeface());type.setTextSize(getTextSize());type.setColor(getCurrentTextColor());
        float textX=x+box+12*density;
        int available=Math.max(1,(int)(getWidth()-getPaddingRight()-textX));
        CharSequence shown=getText()==null?"":getText();
        StaticLayout layout=StaticLayout.Builder.obtain(shown,0,shown.length(),type,available)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false)
            .build();
        canvas.save();
        canvas.translate(textX,Math.max(getPaddingTop(),cy-layout.getHeight()/2f));
        layout.draw(canvas);
        canvas.restore();
    }
}
