package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.view.View;

/** Compact transfer action that sits between search and menu. */
final class HandoffButton extends View {
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path triangle=new Path();
    private final RectF phone=new RectF();
    private final RectF signal=new RectF();

    HandoffButton(Context context){
        super(context);
        setClickable(true);
        setFocusable(true);
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        float unit=getResources().getDisplayMetrics().density;
        float cx=getWidth()/2f,cy=getHeight()/2f;
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(unit*1.7f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setColor(0xffeeeeef);
        phone.set(cx-11*unit,cy-12*unit,cx+6*unit,cy+12*unit);
        canvas.drawRoundRect(phone,3*unit,3*unit,paint);
        paint.setStyle(Paint.Style.FILL);
        triangle.reset();
        triangle.moveTo(cx-5*unit,cy-5*unit);
        triangle.lineTo(cx+2*unit,cy);
        triangle.lineTo(cx-5*unit,cy+5*unit);
        triangle.close();
        canvas.drawPath(triangle,paint);
        paint.setStyle(Paint.Style.STROKE);
        signal.set(cx-7*unit,cy-10*unit,cx+18*unit,cy+10*unit);
        canvas.drawArc(signal,-50,96,false,paint);
        signal.set(cx-6*unit,cy-7*unit,cx+13*unit,cy+7*unit);
        canvas.drawArc(signal,-48,94,false,paint);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(0xffedb4d6);
        canvas.drawCircle(cx+14*unit,cy-14*unit,2.3f*unit,paint);
    }
}
