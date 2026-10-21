package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.widget.TextView;

/** Vector controls keep the same shape on every Android font and display scale. */
final class NativeIconButton extends TextView {
    private final Paint ink=new Paint(Paint.ANTI_ALIAS_FLAG);
    NativeIconButton(Context c){super(c);setSingleLine(true);setHorizontallyScrolling(false);setIncludeFontPadding(false);setWillNotDraw(false);}
    static boolean isIcon(String s){return s.matches("[▶Ⅱ⌕☰⋯♡♥⇄↻⌄×]|\\|‹|›\\|");}
    @Override protected void onDraw(Canvas canvas){
        String symbol=getText().toString();if(!isIcon(symbol)){super.onDraw(canvas);return;}
        float size=Math.min(getWidth(),getHeight())*.44f;size=Math.min(size,Math.max(24*getResources().getDisplayMetrics().density,getTextSize()));
        canvas.save();canvas.translate(getScrollX(),getScrollY());canvas.translate((getWidth()-size)/2,(getHeight()-size)/2);canvas.scale(size/24,size/24);
        ink.setColor(getCurrentTextColor());ink.setStrokeWidth(1.8f);ink.setStrokeCap(Paint.Cap.ROUND);ink.setStrokeJoin(Paint.Join.ROUND);ink.setStyle(Paint.Style.STROKE);
        Path p=new Path();
        switch(symbol){
            case "▶":p.moveTo(7,3);p.lineTo(21,12);p.lineTo(7,21);p.close();ink.setStyle(Paint.Style.FILL);canvas.drawPath(p,ink);break;
            case "Ⅱ":canvas.drawLine(8,4,8,20,ink);canvas.drawLine(16,4,16,20,ink);break;
            case "⌕":canvas.drawCircle(10,10,7,ink);canvas.drawLine(15,15,22,22,ink);break;
            case "☰":for(int y=5;y<=19;y+=7)canvas.drawLine(3,y,21,y,ink);break;
            case "⋯":ink.setStyle(Paint.Style.FILL);for(int x=5;x<=19;x+=7)canvas.drawCircle(x,12,1.5f,ink);break;
            case "⌄":canvas.drawLine(4,8,12,16,ink);canvas.drawLine(12,16,20,8,ink);break;
            case "×":canvas.drawLine(5,5,19,19,ink);canvas.drawLine(5,19,19,5,ink);break;
            case "♡":case "♥":p.moveTo(12,21);p.cubicTo(-8,9,6,-4,12,6);p.cubicTo(18,-4,32,9,12,21);if(symbol.equals("♥"))ink.setStyle(Paint.Style.FILL);canvas.drawPath(p,ink);break;
            case "|‹":canvas.drawLine(4,4,4,20,ink);p.moveTo(20,4);p.lineTo(6,12);p.lineTo(20,20);p.close();canvas.drawPath(p,ink);break;
            case "›|":canvas.drawLine(20,4,20,20,ink);p.moveTo(4,4);p.lineTo(18,12);p.lineTo(4,20);p.close();canvas.drawPath(p,ink);break;
            case "↻":p.moveTo(4,8);p.cubicTo(7,1,19,1,21,10);p.lineTo(21,4);p.moveTo(21,10);p.lineTo(15,10);p.moveTo(20,16);p.cubicTo(17,23,5,23,3,14);p.lineTo(3,20);p.moveTo(3,14);p.lineTo(9,14);canvas.drawPath(p,ink);break;
            case "⇄":p.moveTo(3,5);p.cubicTo(12,5,12,19,21,19);p.moveTo(17,15);p.lineTo(21,19);p.lineTo(17,23);p.moveTo(3,19);p.cubicTo(12,19,12,5,21,5);p.moveTo(17,1);p.lineTo(21,5);p.lineTo(17,9);canvas.drawPath(p,ink);break;
        }
        canvas.restore();
    }
}
