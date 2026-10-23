package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.view.View;

/** Small outline icons for the iPhone-style navigation panel. */
final class NavigationMenuIcon extends View {
    private final String kind;
    private final int color;
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    NavigationMenuIcon(Context context,String kind,int color){super(context);this.kind=kind;this.color=color;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
    @Override protected void onDraw(Canvas c){
        super.onDraw(c);c.save();float size=Math.min(getWidth(),getHeight());c.translate((getWidth()-size)/2,(getHeight()-size)/2);c.scale(size/24,size/24);
        paint.setColor(color);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(1.6f);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);Path p=new Path();
        switch(kind){
            case "home":p.moveTo(3,11);p.lineTo(12,3);p.lineTo(21,11);p.moveTo(5,10);p.lineTo(5,21);p.lineTo(10,21);p.lineTo(10,15);p.lineTo(14,15);p.lineTo(14,21);p.lineTo(19,21);p.lineTo(19,10);break;
            case "search":c.drawCircle(10,10,6,paint);c.drawLine(15,15,21,21,paint);break;
            case "heart":p.moveTo(12,21);p.cubicTo(-5,10,5,-3,12,6);p.cubicTo(19,-3,29,10,12,21);break;
            case "list":for(int y=6;y<=18;y+=6){c.drawCircle(4,y,.7f,paint);c.drawLine(9,y,21,y,paint);}break;
            case "download":p.moveTo(12,3);p.lineTo(12,15);p.moveTo(8,11);p.lineTo(12,15);p.lineTo(16,11);p.moveTo(4,15);p.lineTo(4,21);p.lineTo(20,21);p.lineTo(20,15);break;
            case "sparkles":p.moveTo(10,3);p.lineTo(12,9);p.lineTo(18,11);p.lineTo(12,13);p.lineTo(10,19);p.lineTo(8,13);p.lineTo(2,11);p.lineTo(8,9);p.close();c.drawLine(19,3,19,7,paint);c.drawLine(17,5,21,5,paint);break;
            case "stats":c.drawRoundRect(3,13,7,21,1,1,paint);c.drawRoundRect(10,7,14,21,1,1,paint);c.drawRoundRect(17,3,21,21,1,1,paint);break;
            case "star":for(int i=0;i<10;i++){double a=-Math.PI/2+i*Math.PI/5;float r=i%2==0?10:4.5f;float x=12+(float)Math.cos(a)*r,y=12+(float)Math.sin(a)*r;if(i==0)p.moveTo(x,y);else p.lineTo(x,y);}p.close();break;
            case "settings":c.drawCircle(12,12,6.5f,paint);c.drawCircle(12,12,2.5f,paint);for(int i=0;i<8;i++){double a=i*Math.PI/4;c.drawLine(12+(float)Math.cos(a)*7,12+(float)Math.sin(a)*7,12+(float)Math.cos(a)*9.5f,12+(float)Math.sin(a)*9.5f,paint);}break;
            case "sliders":for(int i=0;i<3;i++){float y=5+i*7,x=i==1?15:8;c.drawLine(3,y,x-2,y,paint);c.drawLine(x+2,y,21,y,paint);c.drawCircle(x,y,2,paint);}break;
            case "mail":c.drawRoundRect(3,5,21,19,2,2,paint);p.moveTo(3,6);p.lineTo(12,13);p.lineTo(21,6);break;
            default:c.drawCircle(12,7,4,paint);p.moveTo(4,21);p.cubicTo(4,11,20,11,20,21);break;
        }
        c.drawPath(p,paint);c.restore();
    }
}
