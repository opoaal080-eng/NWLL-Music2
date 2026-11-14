package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.widget.TextView;

/** Vector controls keep the same shape on every Android font and display scale. */
final class NativeIconButton extends TextView {
    private final Paint ink=new Paint(Paint.ANTI_ALIAS_FLAG);
    NativeIconButton(Context c){super(c);setSingleLine(true);setHorizontallyScrolling(false);setIncludeFontPadding(false);setWillNotDraw(false);}
    static boolean isIcon(String s){return s!=null&&(s.matches("[▶Ⅱ⌕☰⋯♡♥⇄⇥↻⌄×‹⚙⊖⌂▤✧]|\\|‹|›\\|")||"⇄✦".equals(s));}
    @Override protected void onDraw(Canvas canvas){
        String symbol=getText().toString();if(!isIcon(symbol)){super.onDraw(canvas);return;}
        float size=Math.min(Math.min(getWidth(),getHeight())*.56f,32*getResources().getDisplayMetrics().density);
        canvas.save();canvas.translate(getScrollX(),getScrollY());canvas.translate((getWidth()-size)/2,(getHeight()-size)/2);canvas.scale(size/24,size/24);
        ink.setColor(getCurrentTextColor());ink.setStrokeWidth(1.8f);ink.setStrokeCap(Paint.Cap.ROUND);ink.setStrokeJoin(Paint.Join.ROUND);ink.setStyle(Paint.Style.STROKE);
        Path p=new Path();
        switch(symbol){
            case "▶":p.moveTo(7,4);p.lineTo(20,12);p.lineTo(7,20);p.close();ink.setStyle(Paint.Style.FILL);canvas.drawPath(p,ink);break;
            case "Ⅱ":ink.setStyle(Paint.Style.FILL);canvas.drawRoundRect(6,4,10,20,1,1,ink);canvas.drawRoundRect(14,4,18,20,1,1,ink);break;
            case "⌕":canvas.drawCircle(10,10,7,ink);canvas.drawLine(15,15,22,22,ink);break;
            case "☰":for(int y=5;y<=19;y+=7)canvas.drawLine(3,y,21,y,ink);break;
            case "⋯":ink.setStyle(Paint.Style.FILL);for(int x=5;x<=19;x+=7)canvas.drawCircle(x,12,1.5f,ink);break;
            case "⌄":canvas.drawLine(4,8,12,16,ink);canvas.drawLine(12,16,20,8,ink);break;
            case "×":canvas.drawLine(5,5,19,19,ink);canvas.drawLine(5,19,19,5,ink);break;
            case "♡":case "♥":p.moveTo(12,21);p.cubicTo(-8,9,6,-4,12,6);p.cubicTo(18,-4,32,9,12,21);if(symbol.equals("♥"))ink.setStyle(Paint.Style.FILL);canvas.drawPath(p,ink);break;
            case "|‹":ink.setStyle(Paint.Style.FILL);canvas.drawRoundRect(4,4,6,20,1,1,ink);p.moveTo(19,4);p.lineTo(7.5f,12);p.lineTo(19,20);p.close();canvas.drawPath(p,ink);break;
            case "›|":ink.setStyle(Paint.Style.FILL);canvas.drawRoundRect(18,4,20,20,1,1,ink);p.moveTo(5,4);p.lineTo(16.5f,12);p.lineTo(5,20);p.close();canvas.drawPath(p,ink);break;
            case "↻":p.moveTo(4,8);p.cubicTo(7,1,19,1,21,10);p.lineTo(21,4);p.moveTo(21,10);p.lineTo(15,10);p.moveTo(20,16);p.cubicTo(17,23,5,23,3,14);p.lineTo(3,20);p.moveTo(3,14);p.lineTo(9,14);canvas.drawPath(p,ink);break;
            // Device-to-device handoff, distinct from shuffle arrows.
            case "⇥":canvas.drawRoundRect(1,4,8,19,1.5f,1.5f,ink);
                canvas.drawRoundRect(17,4,23,19,1.5f,1.5f,ink);
                canvas.drawLine(10,11.5f,16,11.5f,ink);
                canvas.drawLine(13.5f,8.5f,16.5f,11.5f,ink);
                canvas.drawLine(13.5f,14.5f,16.5f,11.5f,ink);break;
            case "⇄":case "⇄✦":p.moveTo(3,7.5f);p.lineTo(20,7.5f);p.moveTo(16,4);p.lineTo(20,7.5f);p.lineTo(16,11);
                p.moveTo(21,16.5f);p.lineTo(4,16.5f);p.moveTo(8,13);p.lineTo(4,16.5f);p.lineTo(8,20);
                canvas.drawPath(p,ink);
                if(symbol.equals("⇄✦")){ink.setStyle(Paint.Style.FILL);canvas.drawCircle(12,12,1.6f,ink);}break;
            case "‹":p.moveTo(15,4);p.lineTo(7,12);p.lineTo(15,20);canvas.drawPath(p,ink);break;
            case "⊖":canvas.drawCircle(12,12,8,ink);canvas.drawLine(8,12,16,12,ink);break;
            case "⚙":canvas.drawCircle(12,12,6.5f,ink);canvas.drawCircle(12,12,2.3f,ink);for(int i=0;i<8;i++){double angle=i*Math.PI/4;canvas.drawLine(12+(float)Math.cos(angle)*7,12+(float)Math.sin(angle)*7,12+(float)Math.cos(angle)*9.5f,12+(float)Math.sin(angle)*9.5f,ink);}break;
            case "⌂":p.moveTo(3,11);p.lineTo(12,3);p.lineTo(21,11);p.moveTo(5.6f,10);p.lineTo(5.6f,21);p.lineTo(18.4f,21);p.lineTo(18.4f,10);canvas.drawPath(p,ink);break;
            case "▤":canvas.drawRoundRect(4,3,20,21,2,2,ink);for(int y=8;y<=16;y+=4)canvas.drawLine(8,y,16,y,ink);break;
            case "✧":p.moveTo(12,2);p.lineTo(14.3f,9.7f);p.lineTo(22,12);p.lineTo(14.3f,14.3f);p.lineTo(12,22);p.lineTo(9.7f,14.3f);p.lineTo(2,12);p.lineTo(9.7f,9.7f);p.close();canvas.drawPath(p,ink);break;
        }
        canvas.restore();
    }
}
