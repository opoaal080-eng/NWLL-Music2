package fun.nightwell.music;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import java.util.LinkedHashSet;
import java.util.Set;

/** Four native welcome screens shown once per device. */
public final class FirstRunActivity extends Activity {
    private static final int LIME=0xffecff35, WHITE=0xfff8f8fb, BLACK=0xff08080c;
    private final Set<String> artists=new LinkedHashSet<>();
    private final String[] suggestions={"Кино","Баста","Дмитриенко","Мияги","Кадышева","MACAN",
        "Клава Кока","Дора","The Weeknd","Billie Eilish","Imagine Dragons","Måneskin"};
    private final String[] titles={"Твоя волна. Твоя музыка.","Подборки под любой момент",
        "Слушай даже без интернета","Настроим твой вкус"};
    private final String[] descriptions={"Nightwell узнаёт твой вкус и подбирает новую музыку.",
        "Для прогулок, работы, поездок и любого настроения.",
        "Сохраняй треки и плейлисты, чтобы слушать без сети.",
        "Выбери любимых исполнителей для первых рекомендаций."};
    private int page;
    private String mood="any";
    private int dp(int v){return (int)(v*getResources().getDisplayMetrics().density+.5f);}
    private GradientDrawable bg(int a,int b,int radius){
        GradientDrawable d=new GradientDrawable(GradientDrawable.Orientation.TL_BR,new int[]{a,b});
        d.setCornerRadius(dp(radius));d.setStroke(dp(1),0x33ffffff);return d;
    }
    private TextView text(String value,int size,int color,boolean bold){
        TextView v=new TextView(this);v.setText(value);v.setTextSize(size);v.setTextColor(color);
        v.setGravity(Gravity.CENTER);v.setIncludeFontPadding(false);
        if(bold)v.setTypeface(Typeface.create("sans-serif-black",Typeface.BOLD));
        return v;
    }
    @Override public void onCreate(Bundle state){
        super.onCreate(state);getWindow().setStatusBarColor(BLACK);getWindow().setNavigationBarColor(BLACK);draw();
    }
    private void draw(){
        boolean landscape=getResources().getConfiguration().orientation==
            android.content.res.Configuration.ORIENTATION_LANDSCAPE;
        LinearLayout root=new LinearLayout(this);root.setOrientation(1);
        root.setPadding(dp(landscape?14:22),dp(landscape?4:12),
                        dp(landscape?14:22),dp(landscape?4:16));
        root.setBackgroundColor(BLACK);setContentView(root);
        LinearLayout top=new LinearLayout(this);top.setGravity(Gravity.CENTER_VERTICAL);
        TextView logo=text("〰 NIGHTWELL",17,WHITE,true);logo.setGravity(Gravity.CENTER_VERTICAL|Gravity.LEFT);
        top.addView(logo,new LinearLayout.LayoutParams(0,dp(landscape?38:50),1));
        if(page<3){TextView skip=text("Пропустить",14,0xffb8b8c2,false);
            skip.setOnClickListener(v->done());top.addView(skip,new LinearLayout.LayoutParams(dp(105),dp(landscape?38:50)));}
        root.addView(top);
        LinearLayout middle=new LinearLayout(this);
        middle.setOrientation(landscape?LinearLayout.HORIZONTAL:LinearLayout.VERTICAL);
        middle.setGravity(Gravity.CENTER);
        root.addView(middle,new LinearLayout.LayoutParams(-1,0,1));
        FrameLayout artwork=new FrameLayout(this);
        int a=page==0?0xffc11286:page==1?0xff493af5:page==2?0xff116ad7:0xff20202c;
        int b=page==0?0xff32104c:page==1?0xff072a37:page==2?0xff0a1950:0xff0e0e14;
        artwork.setBackground(bg(a,b,40));
        LinearLayout.LayoutParams hero=landscape
            ?new LinearLayout.LayoutParams(0,-1,1.1f)
            :new LinearLayout.LayoutParams(-1,0,1.6f);
        hero.setMargins(0,dp(landscape?4:14),dp(landscape?16:0),
                        dp(landscape?4:22));
        middle.addView(artwork,hero);
        if(page==3)preferences(artwork);
        else {
            LinearLayout center=new LinearLayout(this);center.setOrientation(1);center.setGravity(Gravity.CENTER);
            artwork.addView(center,new FrameLayout.LayoutParams(-1,-1));
            TextView glyph=text(page==0?"≋":page==1?"◈":"✈",landscape?64:120,LIME,true);
            glyph.setShadowLayer(dp(24),0,0,0x77ecff35);
            center.addView(glyph,new LinearLayout.LayoutParams(-1,0,1));
            TextView caption=text(page==0?"Твой ритм · Открытия":page==1?"Тысячи идей для плейлистов":"↓  Скачано. Доступно офлайн",landscape?12:17,WHITE,true);
            caption.setPadding(dp(14),0,dp(14),dp(23));center.addView(caption);
        }
        LinearLayout copy=new LinearLayout(this);copy.setGravity(Gravity.CENTER);copy.setOrientation(1);
        TextView title=text(titles[page],landscape?26:34,WHITE,true);copy.addView(title);
        TextView desc=text(descriptions[page],landscape?14:16,0xffb3b3c0,false);desc.setPadding(dp(10),dp(14),dp(10),0);
        copy.addView(desc);
        middle.addView(copy,landscape?
            new LinearLayout.LayoutParams(0,-1,1):
            new LinearLayout.LayoutParams(-1,0,.8f));
        LinearLayout bottom=new LinearLayout(this);bottom.setGravity(Gravity.CENTER_VERTICAL);
        for(int i=0;i<4;i++){View dot=new View(this);dot.setBackground(bg(i==page?LIME:0xff53535b,i==page?LIME:0xff53535b,10));
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(dp(i==page?28:7),dp(7));lp.rightMargin=dp(7);bottom.addView(dot,lp);}
        bottom.addView(new View(this),new LinearLayout.LayoutParams(0,1,1));
        TextView button=text(page==3?"Начать  ✓":"Далее  →",16,BLACK,true);
        button.setPadding(dp(22),0,dp(22),0);button.setBackground(bg(LIME,0xffd6ff2c,50));
        button.setOnClickListener(v->{if(page<3){page++;draw();}else done();});
        bottom.addView(button,new LinearLayout.LayoutParams(-2,dp(landscape?44:54)));
        root.addView(bottom,new LinearLayout.LayoutParams(-1,dp(landscape?50:70)));
    }
    private void preferences(FrameLayout hero){
        ScrollView scroll=new ScrollView(this);hero.addView(scroll,new FrameLayout.LayoutParams(-1,-1));
        LinearLayout content=new LinearLayout(this);content.setPadding(dp(16),dp(13),dp(16),dp(13));
        content.setOrientation(1);scroll.addView(content);
        TextView hint=text("ВЫБЕРИ ИСПОЛНИТЕЛЕЙ",15,WHITE,true);content.addView(hint);
        GridLayout grid=new GridLayout(this);grid.setColumnCount(2);
        LinearLayout.LayoutParams glp=new LinearLayout.LayoutParams(-1,-2);glp.topMargin=dp(10);content.addView(grid,glp);
        for(int i=0;i<suggestions.length;i++){
            final String artist=suggestions[i];
            TextView tile=text(artist,13,WHITE,false);tile.setSingleLine(true);
            tile.setEllipsize(android.text.TextUtils.TruncateAt.END);
            tile.setPadding(dp(5),0,dp(5),0);style(tile,artists.contains(artist));
            tile.setOnClickListener(v->{if(!artists.add(artist))artists.remove(artist);style(tile,artists.contains(artist));});
            GridLayout.LayoutParams lp=new GridLayout.LayoutParams(GridLayout.spec(i/2),GridLayout.spec(i%2,1f));
            lp.width=0;lp.height=dp(38);lp.setMargins(dp(3),dp(3),dp(3),dp(3));grid.addView(tile,lp);
        }
        TextView hint2=text("НАСТРОЕНИЕ",15,WHITE,true);
        LinearLayout.LayoutParams label=new LinearLayout.LayoutParams(-1,dp(44));content.addView(hint2,label);
        String[] keys={"any","energetic","calm","happy"},names={"Любое","Бодрое","Спокойно","Весело"};
        LinearLayout moods=new LinearLayout(this);
        for(int i=0;i<keys.length;i++){
            final String key=keys[i];TextView option=text(names[i],11,WHITE,false);style(option,key.equals(mood));
            option.setOnClickListener(v->{mood=key;draw();});
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,dp(34),1);lp.rightMargin=dp(3);
            moods.addView(option,lp);
        }
        content.addView(moods);
    }
    private void style(TextView item,boolean selected){
        item.setTextColor(selected?BLACK:WHITE);
        item.setBackground(bg(selected?LIME:0xff393943,selected?LIME:0xff393943,12));
    }
    private void done(){
        ArtistTaste.seed(this,artists,mood);
        getSharedPreferences("nw-first-run",0).edit().putBoolean("done-v1",true).apply();
        startActivity(new Intent(this,MainActivity.class));finish();
    }
    @Override public void onBackPressed(){if(page>0){page--;draw();}else done();}
}
