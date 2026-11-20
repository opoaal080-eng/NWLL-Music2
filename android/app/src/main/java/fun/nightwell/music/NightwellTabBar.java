package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;

/** iOS Nightwell navigation, fully rendered on one Canvas, with no stock tabs. */
final class NightwellTabBar extends View {
    interface Listener { void select(int tab); }
    private final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path=new Path();
    private Listener listener;
    private int active=0;
    private boolean premiumVisible=true;
    private final String[] labels={"Главная","Поиск","Медиатека","Premium"};
    private float downX,downY;

    NightwellTabBar(Context c){
        super(c);
        setMinimumHeight(dp(62));
        setClickable(true);
        setContentDescription("Навигация Nightwell Music");
    }
    private float dp(float n){return n*getResources().getDisplayMetrics().density;}
    void setListener(Listener next){listener=next;}
    void setActive(int value){if(active!=value){active=value;invalidate();}}
    void setPremiumVisible(boolean value){premiumVisible=value;invalidate();}
    private int count(){return premiumVisible?4:3;}
    @Override protected void onMeasure(int ws,int hs){
        setMeasuredDimension(MeasureSpec.getSize(ws),dpInt(62));
    }
    private int dpInt(float n){return Math.round(dp(n));}
    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        float w=getWidth(),h=getHeight(),cell=w/count();
        p.setStyle(Paint.Style.FILL);
        p.setColor(0x15000000);
        canvas.drawRoundRect(new RectF(0,0,w,h),dp(19),dp(19),p);
        p.setStrokeWidth(dp(.8f));
        p.setStyle(Paint.Style.STROKE);
        p.setColor(0x38ffffff);
        canvas.drawRoundRect(new RectF(dp(.5f),dp(.5f),w-dp(.5f),h-dp(.5f)),dp(19),dp(19),p);
        for(int i=0;i<count();i++){
            float cx=(i+.5f)*cell;
            boolean selected=active==i;
            int color=selected?0xffffffff:0x90ffffff;
            if(selected){
                p.setStyle(Paint.Style.FILL);
                p.setColor(0x24ffffff);
                canvas.drawRoundRect(new RectF(i*cell+dp(5),dp(3),
                    (i+1)*cell-dp(5),h-dp(4)),dp(16),dp(16),p);
            }
            canvas.save();
            canvas.translate(cx,dp(18));
            drawSymbol(canvas,i,color,selected);
            canvas.restore();
            p.setShader(null);
            p.setStyle(Paint.Style.FILL);
            p.setColor(color);
            p.setTypeface(android.graphics.Typeface.create("sans-serif", selected?
                android.graphics.Typeface.BOLD:android.graphics.Typeface.NORMAL));
            p.setTextSize(dp(10.3f));
            p.setTextAlign(Paint.Align.CENTER);
            canvas.drawText(labels[i],cx,h-dp(10),p);
        }
    }
    private void stroke(int color,boolean selected){
        p.setColor(color);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(dp(selected?2.25f:1.85f));
        p.setStrokeCap(Paint.Cap.ROUND);
        p.setStrokeJoin(Paint.Join.ROUND);
    }
    private void drawSymbol(Canvas c,int icon,int color,boolean selected){
        stroke(color,selected);
        switch(icon){
        case 0: // house
            path.reset();path.moveTo(-dp(10),-dp(1));path.lineTo(0,-dp(9));path.lineTo(dp(10),-dp(1));
            path.lineTo(dp(9),dp(9));path.lineTo(-dp(9),dp(9));path.close();
            c.drawPath(path,p);
            c.drawRoundRect(new RectF(-dp(2.6f),dp(3),dp(2.6f),dp(9)),dp(1),dp(1),p);
            break;
        case 1: // magnifier
            c.drawCircle(-dp(2),-dp(2),dp(7),p);
            c.drawLine(dp(3.6f),dp(3.6f),dp(10),dp(10),p);
            break;
        case 2: // stacked library cards
            c.drawRoundRect(new RectF(-dp(7),-dp(10),dp(11),dp(6)),dp(2.5f),dp(2.5f),p);
            c.drawLine(-dp(11),-dp(5),-dp(11),dp(9),p);
            c.drawLine(-dp(11),dp(9),dp(6),dp(9),p);
            break;
        case 3: // star
            path.reset();
            for(int i=0;i<10;i++){
                float angle=(float)(-Math.PI/2+i*Math.PI/5);
                float rad=dp(i%2==0?10:4.6f);
                float x=(float)Math.cos(angle)*rad;
                float y=(float)Math.sin(angle)*rad;
                if(i==0)path.moveTo(x,y);else path.lineTo(x,y);
            }
            path.close();
            c.drawPath(path,p);
            break;
        }
    }
    @Override public boolean onTouchEvent(MotionEvent event){
        switch(event.getActionMasked()){
        case MotionEvent.ACTION_DOWN:
            downX=event.getX();downY=event.getY();
            setPressed(true);return true;
        case MotionEvent.ACTION_CANCEL:setPressed(false);return true;
        case MotionEvent.ACTION_UP:
            setPressed(false);
            if(Math.abs(event.getX()-downX)>dp(25)||Math.abs(event.getY()-downY)>dp(25))return true;
            int selected=Math.min(count()-1,Math.max(0,(int)(event.getX()/(getWidth()/(float)count()))));
            if(listener!=null)listener.select(selected);
            performClick();
            return true;
        default:return true;
        }
    }
    @Override public boolean performClick(){super.performClick();return true;}
}