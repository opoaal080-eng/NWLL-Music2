package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.drawable.Drawable;
import java.util.Locale;

/**
 * A unified family of crisp, monochrome 24x24 UI symbols.
 * No Android system icons, emoji glyphs or external icon fonts.
 */
final class NightwellGlyphDrawable extends Drawable {
    private final Paint pen = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final String kind;
    private final int size;
    private int color = 0xffe6e8ed;
    private int alpha = 255;

    NightwellGlyphDrawable(Context context,String kind) {
        this.kind=kind;
        this.size=Math.round(23*context.getResources().getDisplayMetrics().density);
        pen.setStrokeCap(Paint.Cap.ROUND);
        pen.setStrokeJoin(Paint.Join.ROUND);
    }
    static String cleanLabel(String title) {
        if(title==null)return "";
        String value=title.trim();
        for(String prefix:new String[]{"⇥  ","▧    ","✎    ","✧    ","↪    ",
                "＋  ","▶ ","↻ ","📎  ","♫  "}) {
            if(value.startsWith(prefix)) {
                value=value.substring(prefix.length()).trim();
                break;
            }
        }
        if(value.endsWith("    ›"))value=value.substring(0,value.length()-5).trim();
        return value;
    }
    static NightwellGlyphDrawable forLabel(Context context,String title) {
        String value=cleanLabel(title).toLowerCase(Locale.ROOT);
        String kind;
        if(value.contains("удалить")||value.contains("покинуть")||value.contains("выйти"))
            kind="trash";
        else if(value.contains("следующ")||value.contains("играть следующим"))
            kind="next";
        else if(value.contains("предыдущ"))
            kind="previous";
        else if(value.contains("воспроизвед")||value.contains("слушать")||value.contains("запустить"))
            kind="play";
        else if(value.contains("избранн")||value.contains("сердц"))
            kind="heart";
        else if(value.contains("скача")||value.contains("загруз"))
            kind="download";
        else if(value.contains("плейлист")||value.contains("медиатек")||value.contains("коллекци"))
            kind="playlist";
        else if(value.contains("очеред"))
            kind="queue";
        else if(value.contains("поделиться")||value.contains("отправ")||value.contains("приглашени"))
            kind="share";
        else if(value.contains("копировать")||value.contains("скопировать"))
            kind="copy";
        else if(value.contains("клип")||value.contains("видео"))
            kind="video";
        else if(value.contains("ритм")||value.contains("подборк")||value.contains("рекомендац")||value.contains("умные"))
            kind="sparkle";
        else if(value.contains("исполнитель")||value.contains("артист")||value.contains("ник"))
            kind="person";
        else if(value.contains("аватар")||value.contains("профил")||value.contains("аккаунт"))
            kind="person";
        else if(value.contains("качеств")||value.contains("буфер")||value.contains("звук"))
            kind="sliders";
        else if(value.contains("эквалайзер")||value.contains("громкост"))
            kind="equalizer";
        else if(value.contains("анимаци")||value.contains("обложк"))
            kind="disc";
        else if(value.contains("тем")||value.contains("оформлен")||value.contains("стиль"))
            kind="appearance";
        else if(value.contains("устройств")||value.contains("комнату")||value.contains("присоединиться"))
            kind="devices";
        else if(value.contains("premium")||value.contains("подписк"))
            kind="star";
        else if(value.contains("добавить")||value.contains("создать")||value.contains("новое"))
            kind="plus";
        else if(value.contains("изменить")||value.contains("настро")||value.contains("управлен"))
            kind="sliders";
        else if(value.contains("ссылк"))
            kind="link";
        else if(value.contains("файл")||value.contains("прикрепить"))
            kind="file";
        else if(value.contains("повторно")||value.contains("обновить"))
            kind="repeat";
        else if(value.equals("ещё")||value.contains("дополнитель"))
            kind="more";
        else if(value.contains("скрыть")||value.contains("не рекомендовать")||value.contains("вернуть"))
            kind="block";
        else if(value.contains("условия")||value.contains("помощ"))
            kind="info";
        else kind="chevron";
        return new NightwellGlyphDrawable(context,kind);
    }
    void setInk(int color){this.color=color;invalidateSelf();}
    @Override public int getIntrinsicWidth(){return size;}
    @Override public int getIntrinsicHeight(){return size;}
    @Override public void draw(Canvas canvas){
        Rect bounds=getBounds();
        float side=Math.min(bounds.width(),bounds.height());
        if(side<=0)return;
        canvas.save();
        canvas.translate(bounds.centerX()-side/2f,bounds.centerY()-side/2f);
        canvas.scale(side/24f,side/24f);
        pen.setColor(color);pen.setAlpha(alpha);pen.setStyle(Paint.Style.STROKE);
        pen.setStrokeWidth(1.7f);
        Path p=new Path();
        switch(kind){
            case "next":
                p.moveTo(5,5);p.lineTo(16,12);p.lineTo(5,19);p.close();
                pen.setStyle(Paint.Style.FILL);canvas.drawPath(p,pen);canvas.drawRoundRect(18,5,20,19,1,1,pen);break;
            case "previous":
                p.moveTo(19,5);p.lineTo(8,12);p.lineTo(19,19);p.close();
                pen.setStyle(Paint.Style.FILL);canvas.drawPath(p,pen);canvas.drawRoundRect(4,5,6,19,1,1,pen);break;
            case "play":
                p.moveTo(7,4);p.lineTo(20,12);p.lineTo(7,20);p.close();
                pen.setStyle(Paint.Style.FILL);canvas.drawPath(p,pen);break;
            case "heart":
                p.moveTo(12,20);p.cubicTo(8,17.5f,3,14.2f,3,9);
                p.cubicTo(3,2,10,3,12,7);p.cubicTo(14,3,21,2,21,9);
                p.cubicTo(21,14.2f,16,17.5f,12,20);p.close();canvas.drawPath(p,pen);break;
            case "download":
                p.moveTo(12,3);p.lineTo(12,15);p.moveTo(7.5f,11);p.lineTo(12,15.5f);p.lineTo(16.5f,11);
                p.moveTo(4,17);p.lineTo(4,21);p.lineTo(20,21);p.lineTo(20,17);canvas.drawPath(p,pen);break;
            case "queue":
                for(int y=6;y<=18;y+=6){canvas.drawCircle(4,y,0.7f,pen);canvas.drawLine(9,y,20,y,pen);}break;
            case "playlist":
                canvas.drawRoundRect(4,3,20,21,2,2,pen);
                canvas.drawLine(8,8,16,8,pen);canvas.drawLine(8,12,16,12,pen);canvas.drawLine(8,16,14,16,pen);break;
            case "share":
                canvas.drawCircle(6,12,2,pen);canvas.drawCircle(18,6,2,pen);canvas.drawCircle(18,18,2,pen);
                canvas.drawLine(8,11,16,7,pen);canvas.drawLine(8,13,16,17,pen);break;
            case "copy":
                canvas.drawRoundRect(8,7,20,21,2,2,pen);
                p.moveTo(5,17);p.lineTo(4,17);p.quadTo(3,17,3,15);p.lineTo(3,5);
                p.quadTo(3,3,5,3);p.lineTo(15,3);canvas.drawPath(p,pen);break;
            case "video":
                canvas.drawRoundRect(3,5,16,19,2,2,pen);p.moveTo(17,9);p.lineTo(21,6);p.lineTo(21,18);p.lineTo(17,15);canvas.drawPath(p,pen);break;
            case "sparkle":
                p.moveTo(12,2);p.lineTo(14.5f,9.5f);p.lineTo(22,12);p.lineTo(14.5f,14.5f);
                p.lineTo(12,22);p.lineTo(9.5f,14.5f);p.lineTo(2,12);p.lineTo(9.5f,9.5f);p.close();
                canvas.drawPath(p,pen);break;
            case "person":
                canvas.drawCircle(12,8,3.3f,pen);
                p.moveTo(4.5f,20);p.cubicTo(4.5f,13,19.5f,13,19.5f,20);canvas.drawPath(p,pen);break;
            case "sliders":
                for(int k=0;k<3;k++){
                    float y=5+k*7,x=k==1?16:8;
                    canvas.drawLine(3,y,x-3,y,pen);canvas.drawLine(x+3,y,21,y,pen);canvas.drawCircle(x,y,2.1f,pen);
                }break;
            case "equalizer":
                canvas.drawRoundRect(4,13,7,21,1,1,pen);
                canvas.drawRoundRect(10,5,13,21,1,1,pen);
                canvas.drawRoundRect(16,9,19,21,1,1,pen);break;
            case "disc":
                canvas.drawCircle(12,12,8,pen);canvas.drawCircle(12,12,2.2f,pen);break;
            case "appearance":
                canvas.drawCircle(12,12,8,pen);
                p.moveTo(12,4);p.cubicTo(6,7,6,17,12,20);p.cubicTo(18,17,18,7,12,4);canvas.drawPath(p,pen);break;
            case "devices":
                canvas.drawRoundRect(2,5,10,19,1.5f,1.5f,pen);
                canvas.drawRoundRect(16,5,22,19,1.5f,1.5f,pen);
                canvas.drawLine(11.5f,12,14,12,pen);break;
            case "star":
                for(int k=0;k<10;k++){
                    double ang=-Math.PI/2+k*Math.PI/5;
                    float rad=k%2==0?9.3f:4.4f;
                    float x=12+(float)Math.cos(ang)*rad,y=12+(float)Math.sin(ang)*rad;
                    if(k==0)p.moveTo(x,y);else p.lineTo(x,y);
                }
                p.close();canvas.drawPath(p,pen);break;
            case "plus":
                canvas.drawLine(12,4,12,20,pen);canvas.drawLine(4,12,20,12,pen);break;
            case "trash":
                canvas.drawRoundRect(6,7,18,21,1,1,pen);
                canvas.drawLine(4,6,20,6,pen);canvas.drawLine(9,3,15,3,pen);
                canvas.drawLine(10,11,10,17,pen);canvas.drawLine(14,11,14,17,pen);break;
            case "link":
                canvas.drawRoundRect(1,7,13,17,5,5,pen);canvas.drawRoundRect(11,7,23,17,5,5,pen);break;
            case "file":
                p.moveTo(6,3);p.lineTo(15,3);p.lineTo(20,8);p.lineTo(20,21);p.lineTo(6,21);p.close();
                p.moveTo(15,3);p.lineTo(15,8);p.lineTo(20,8);canvas.drawPath(p,pen);break;
            case "repeat":
                p.moveTo(5,7);p.cubicTo(9,2,17,2,20,9);p.moveTo(16,7);p.lineTo(20,9);p.lineTo(21,4);
                p.moveTo(19,17);p.cubicTo(15,22,7,22,4,15);p.moveTo(8,17);p.lineTo(4,15);p.lineTo(3,20);
                canvas.drawPath(p,pen);break;
            case "block":
                canvas.drawCircle(12,12,8.5f,pen);canvas.drawLine(6,18,18,6,pen);break;
            case "more":
                pen.setStyle(Paint.Style.FILL);
                for(int x=5;x<=19;x+=7)canvas.drawCircle(x,12,1.6f,pen);break;
            case "info":
                canvas.drawCircle(12,12,8.5f,pen);
                canvas.drawLine(12,11,12,17,pen);
                pen.setStyle(Paint.Style.FILL);canvas.drawCircle(12,7.5f,1.2f,pen);break;
            default:
                p.moveTo(9,5);p.lineTo(16,12);p.lineTo(9,19);canvas.drawPath(p,pen);break;
        }
        canvas.restore();
    }
    @Override public void setAlpha(int a){alpha=a;invalidateSelf();}
    @Override public void setColorFilter(ColorFilter filter){pen.setColorFilter(filter);invalidateSelf();}
    @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
}
