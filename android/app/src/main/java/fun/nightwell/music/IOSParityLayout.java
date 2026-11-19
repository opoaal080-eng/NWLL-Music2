package fun.nightwell.music;

import android.app.Dialog;
import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.*;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.util.*;

/** iOS-parity presentation layer for Nightwell Music.
 * Keeps all playback/account/network actions in the native Android host.
 */
final class IOSParityLayout {
  private final MainActivity a;
  IOSParityLayout(MainActivity activity){a=activity;}
  int d(int px){return a.dp(px);}
  LinearLayout column(){return a.column();}
  LinearLayout row(){return a.row();}
  TextView text(String s,int size){return a.text(s,size);}
  boolean vice(){return a.getSharedPreferences("appearance",Context.MODE_PRIVATE).getString("visual-theme","vice").equals("vice");}
  int accent(){return vice()?0xffffca68:0xffeeeeee;}
  int pink(){return vice()?0xffff3b9b:0xffe0e0e4;}
  Drawable glass(int radius){return glassColor(0x704a2b55,radius);}
  Drawable glassColor(int color,int radius){
    GradientDrawable bg=new GradientDrawable(GradientDrawable.Orientation.TL_BR,
       new int[]{color,0x8a57375f,0x83313859});
    bg.setCornerRadius(d(radius));bg.setStroke(Math.max(1,d(1)),vice()?0x50ffb8e7:0x50ffffff);
    return bg;
  }
  Drawable backdrop(boolean brighter){
    return new GradientDrawable(GradientDrawable.Orientation.TL_BR,
      vice()?new int[]{brighter?0xff571653:0xff35113f,0xff862361,0xff41437c,0xff172950}:
      new int[]{0xff111112,0xff232326,0xff131316,0xff09090b});
  }
  Drawable tabBackground(){
    GradientDrawable drawable=new GradientDrawable();
    drawable.setColor(Color.TRANSPARENT);
    drawable.setCornerRadius(d(20));return drawable;
  }
  TextView heading(String s,int size){
    TextView v=text(s,size);v.setTextColor(0xffffffff);v.setTypeface(Typeface.create("sans-serif",Typeface.BOLD));
    return v;
  }
  void renderHeader(LinearLayout head,String screen,Runnable profile,Runnable settings,Runnable menu,Runnable home,
                    NightwellAccountUI accountUI){
    head.removeAllViews();
    head.setGravity(Gravity.CENTER_VERTICAL);
    if(screen.equals("Медиатека")){
      headerIcon(head,"settings",settings);
      TextView center=heading("Медиатека",19);center.setGravity(Gravity.CENTER);
      head.addView(center,new LinearLayout.LayoutParams(0,-1,1));
      headerIcon(head,"list",menu);
    } else if(screen.equals("Плейлисты")||screen.equals("Избранное")||screen.equals("Офлайн")){
      headerIcon(head,"back",()->a.navigate("Медиатека"));
      headerIcon(head,"settings",settings);
      TextView center=heading(screen.equals("Плейлисты")?"":screen,18);center.setGravity(Gravity.CENTER);
      head.addView(center,new LinearLayout.LayoutParams(0,-1,1));
      headerIcon(head,"list",menu);
    } else {
      TextView mark=heading("N",25);mark.setGravity(Gravity.CENTER);
      mark.setBackground(NightwellDesign.ripple(a,0xff08080a,11,false));
      mark.setContentDescription("На главную");mark.setOnClickListener(v->home.run());
      head.addView(mark,new LinearLayout.LayoutParams(d(43),d(43)));
      LinearLayout word=column();word.setGravity(Gravity.CENTER_VERTICAL);word.setPadding(d(9),0,0,0);
      word.addView(heading("Nightwell",23));
      TextView letters=text("M U S I C",10);letters.setLetterSpacing(.24f);letters.setTextColor(0xaaffffff);
      word.addView(letters);word.setOnClickListener(v->home.run());
      head.addView(word,new LinearLayout.LayoutParams(0,-2,1));
      FrameLayout avatar=new FrameLayout(a);
      avatar.setBackground(NightwellDesign.ripple(a,0xff08080b,24,false));
      TextView n=heading("N",23);n.setGravity(Gravity.CENTER);
      avatar.addView(n,new FrameLayout.LayoutParams(-1,-1));
      avatar.setContentDescription("Открыть профиль");
      avatar.setOnClickListener(v->profile.run());
      head.addView(avatar,new LinearLayout.LayoutParams(d(44),d(44)));
      accountUI.bindHeaderAvatar(avatar);
      a.setProfileAvatarHeader(avatar);
      avatar.setContentDescription(a.isSignedIn()?"Открыть профиль":"Войти в аккаунт");
    }
  }
  void headerIcon(LinearLayout target,String icon,Runnable action){
    FrameLayout holder=new FrameLayout(a);
    holder.addView(new NavigationMenuIcon(a,icon,0xfff4f4f6),
        new FrameLayout.LayoutParams(d(25),d(25),Gravity.CENTER));
    holder.setOnClickListener(v->action.run());holder.setContentDescription(
        icon.equals("settings")?"Настройки":icon.equals("back")?"Назад":"Дополнительно");
    target.addView(holder,new LinearLayout.LayoutParams(d(45),d(48)));
  }
  void applyBackdrop(ImageView sunset,PalmSwayOverlay palms,String screen,boolean full){
    if(sunset==null||palms==null)return;
    if(full){sunset.setVisibility(View.GONE);palms.setVisibility(View.GONE);return;}
    boolean vice=vice(),playlist=screen.equals("Плейлисты");
    if(!vice||playlist){
      sunset.setImageDrawable(backdrop(false));
      sunset.setScaleType(ImageView.ScaleType.FIT_XY);
      palms.setVisibility(View.GONE);
    } else {
      sunset.setImageResource(R.drawable.vice_sky);
      sunset.setScaleType(ImageView.ScaleType.CENTER_CROP);
      palms.setVisibility(View.VISIBLE);
    }
    sunset.setVisibility(View.VISIBLE);
  }
  // The screenshot's transparent tab row intentionally has no opaque gray backing.
  void styleBottomTabs(LinearLayout tabs){
    tabs.setBackgroundColor(Color.TRANSPARENT);tabs.setClipToOutline(false);
    tabs.setPadding(0,0,0,0);
  }
  void library(LinearLayout body,JSONArray favorites,JSONArray playlists,ArtworkCache artwork,String origin){
    ScrollView scroll=new ScrollView(a);scroll.setFillViewport(false);scroll.setVerticalScrollBarEnabled(false);
    LinearLayout content=column();content.setPadding(0,d(15),0,d(16));
    scroll.addView(content);body.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
    LinearLayout hero=row();hero.setGravity(Gravity.CENTER_VERTICAL);
    TextView heart=heading("♥",65);heart.setGravity(Gravity.CENTER);heart.setTextColor(0xffff6ea4);
    heart.setShadowLayer(d(5),0,d(2),0x668a3fff);
    hero.addView(heart,new LinearLayout.LayoutParams(d(88),d(88)));
    LinearLayout name=column();name.setPadding(d(8),0,0,0);
    TextView label=heading("Избранное",24);name.addView(label);
    TextView count=text(favorites.length()+" треков",14);count.setTextColor(0xccffffff);
    LinearLayout.LayoutParams countP=new LinearLayout.LayoutParams(-1,-2);countP.topMargin=d(7);
    name.addView(count,countP);hero.addView(name,new LinearLayout.LayoutParams(0,-2,1));
    hero.setOnClickListener(v->a.navigate("Избранное"));
    content.addView(hero,new LinearLayout.LayoutParams(-1,d(105)));
    int shown=Math.min(3,favorites.length());
    for(int i=0;i<shown;i++){
      JSONObject track=favorites.optJSONObject(i);if(track==null)continue;
      LinearLayout line=row();line.setPadding(d(7),d(6),d(3),d(6));
      line.setBackground(NightwellDesign.ripple(a,
        track.optString("id").equals(a.currentTrackId())?0x704f3b5b:0x08000000,16,false));
      ImageView cover=new ImageView(a);cover.setScaleType(ImageView.ScaleType.CENTER_CROP);
      cover.setBackground(glassColor(0x66513858,11));cover.setClipToOutline(true);
      line.addView(cover,new LinearLayout.LayoutParams(d(55),d(55)));
      artwork.load(cover,origin,track.optString("cover_url"));
      LinearLayout desc=column();desc.setGravity(Gravity.CENTER_VERTICAL);desc.setPadding(d(12),0,d(3),0);
      TextView title=heading(track.optString("title","Без названия"),16);
      title.setSingleLine(true);title.setEllipsize(android.text.TextUtils.TruncateAt.END);
      desc.addView(title);
      TextView artist=text(track.optString("artist",""),13);artist.setTextColor(0xbdeae7ec);
      artist.setSingleLine(true);artist.setEllipsize(android.text.TextUtils.TruncateAt.END);
      LinearLayout.LayoutParams artp=new LinearLayout.LayoutParams(-1,-2);artp.topMargin=d(5);desc.addView(artist,artp);
      line.addView(desc,new LinearLayout.LayoutParams(0,-2,1));
      FrameLayout more=new FrameLayout(a);more.addView(new NavigationMenuIcon(a,"dots",0xd5ffb8dc),
          new FrameLayout.LayoutParams(d(24),d(24),Gravity.CENTER));
      more.setOnClickListener(v->a.trackMenu(track));
      line.addView(more,new LinearLayout.LayoutParams(d(40),d(52)));
      line.setOnClickListener(v->a.play(track,favorites,false));
      LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,d(69));lp.bottomMargin=d(3);content.addView(line,lp);
    }
    if(favorites.length()==0) {
      TextView empty=text("Твои любимые треки появятся здесь",14);
      empty.setTextColor(0xb9ffffff);empty.setPadding(d(12),d(14),0,d(20));content.addView(empty);
    }
    TextView more=heading("Ещё в медиатеке",19);
    LinearLayout.LayoutParams morep=new LinearLayout.LayoutParams(-1,-2);
    morep.topMargin=d(21);morep.bottomMargin=d(15);content.addView(more,morep);
    twoItems(content,"list","Плейлисты",playlists.length()+" плейлиста","download","Офлайн","Скачанные треки",
      ()->a.navigate("Плейлисты"),()->a.navigate("Офлайн"));
    twoItems(content,"sparkles","Подборки дня","Для тебя","stats","Умные плейлисты","Для тебя",
      a::dailyPublicPlaylists,()->a.feature("smart"));
  }
  void twoItems(LinearLayout parent,String firstIcon,String first,String sub,String secondIcon,String second,String sub2,
                Runnable run1,Runnable run2){
    LinearLayout row=row();row.setGravity(Gravity.TOP);
    row.addView(tile(firstIcon,first,sub,run1),new LinearLayout.LayoutParams(0,d(93),1));
    View space=new View(a);row.addView(space,new LinearLayout.LayoutParams(d(7),1));
    row.addView(tile(secondIcon,second,sub2,run2),new LinearLayout.LayoutParams(0,d(93),1));
    LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,d(103));parent.addView(row,lp);
  }
  LinearLayout tile(String icon,String label,String caption,Runnable action){
    LinearLayout container=column();container.setGravity(Gravity.CENTER_VERTICAL);
    container.setPadding(d(6),d(6),d(6),d(6));
    container.setBackground(NightwellDesign.ripple(a,0x174d2f65,16,false));
    LinearLayout top=row();
    FrameLayout badge=new FrameLayout(a);badge.setBackground(glassColor(0x445e4c6a,12));
    badge.addView(new NavigationMenuIcon(a,icon,0xfff1e5f1),
      new FrameLayout.LayoutParams(d(24),d(24),Gravity.CENTER));
    top.addView(badge,new LinearLayout.LayoutParams(d(43),d(43)));
    TextView name=heading(label,14);
    name.setGravity(Gravity.CENTER_VERTICAL);name.setMaxLines(2);
    LinearLayout.LayoutParams t=new LinearLayout.LayoutParams(0,d(43),1);t.leftMargin=d(7);top.addView(name,t);
    container.addView(top);
    TextView sub=text(caption,12);sub.setTextColor(0xc6eee6ed);
    LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.leftMargin=d(4);p.topMargin=d(5);
    container.addView(sub,p);container.setOnClickListener(v->action.run());return container;
  }
  void playlists(LinearLayout body,JSONArray playlists){
    ScrollView scroll=new ScrollView(a);scroll.setVerticalScrollBarEnabled(false);
    LinearLayout items=column();items.setPadding(d(3),d(25),d(3),d(15));
    scroll.addView(items);body.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
    LinearLayout title=row();title.setGravity(Gravity.CENTER_VERTICAL);
    title.addView(heading("Плейлисты",34),new LinearLayout.LayoutParams(0,-2,1));
    FrameLayout add=new FrameLayout(a);
    add.setBackground(glassColor(0x66533561,15));
    TextView plus=heading("+",33);plus.setGravity(Gravity.CENTER);add.addView(plus,new FrameLayout.LayoutParams(-1,-1));
    add.setContentDescription("Создать плейлист");
    add.setOnClickListener(v->a.input("Новый плейлист",
       name->a.task(()->a.apiRequest("api/playlists","POST",new JSONObject().put("name",name)),result->a.load())));
    title.addView(add,new LinearLayout.LayoutParams(d(50),d(50)));
    LinearLayout.LayoutParams tp=new LinearLayout.LayoutParams(-1,d(74));items.addView(title,tp);
    TextView section=text("Мои плейлисты",18);section.setTextColor(0xeaffffff);
    LinearLayout.LayoutParams sp=new LinearLayout.LayoutParams(-1,-2);sp.topMargin=d(6);sp.bottomMargin=d(14);
    items.addView(section,sp);
    for(int i=0;i<playlists.length();i++){
      JSONObject item=playlists.optJSONObject(i);if(item==null)continue;
      LinearLayout card=row();card.setPadding(d(12),d(10),d(9),d(10));
      card.setBackground(NightwellDesign.ripple(a,0x66a96f9b,22,true));
      FrameLayout icon=new FrameLayout(a);icon.setBackground(glassColor(0x6053476c,13));
      icon.addView(new NavigationMenuIcon(a,"list",0xffffffff),
          new FrameLayout.LayoutParams(d(25),d(25),Gravity.CENTER));
      card.addView(icon,new LinearLayout.LayoutParams(d(46),d(46)));
      TextView name=heading(item.optString("name"),16);name.setPadding(d(15),0,0,0);
      name.setGravity(Gravity.CENTER_VERTICAL);name.setSingleLine(true);
      name.setEllipsize(android.text.TextUtils.TruncateAt.END);
      card.addView(name,new LinearLayout.LayoutParams(0,d(48),1));
      FrameLayout more=new FrameLayout(a);
      more.addView(new NavigationMenuIcon(a,"dots",0xeaffffff),
          new FrameLayout.LayoutParams(d(25),d(25),Gravity.CENTER));
      more.setOnClickListener(v->a.collectionMenu("playlist",item.optString("id")));
      card.addView(more,new LinearLayout.LayoutParams(d(40),d(49)));
      card.setOnClickListener(v->a.openPlaylist(item));
      LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,d(75));lp.bottomMargin=d(10);items.addView(card,lp);
    }
    if(playlists.length()==0)items.addView(text("Создай свой первый плейлист",15));
  }
  void searchHeader(LinearLayout body) {
    // The actual search EditText/result ListView remain Android native.
    TextView subtitle=text("Введи название трека или исполнителя",13);
    subtitle.setTextColor(0xc8d8cbda);
    LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=d(5);
    body.addView(subtitle,lp);
  }
  void moreSheet(){
    Dialog dialog=sheet("Дополнительно",true);
    LinearLayout content=(LinearLayout)dialog.findViewWithTag("nw-content");
    TextView connection=text("●  API доступен · "+a.connectionLabel(),13);
    connection.setTextColor(0xff9ff4ba);
    LinearLayout.LayoutParams cp=new LinearLayout.LayoutParams(-1,-2);cp.bottomMargin=d(20);content.addView(connection,cp);
    addMenuAction(content,"list","Слушать вместе",()->{dialog.dismiss();a.openTogether();});
    addMenuAction(content,"download","Перенос плейлистов",()->{dialog.dismiss();a.nativeTransfer();});
    addMenuAction(content,"mail","Обращения и поддержка",()->{dialog.dismiss();a.supportTickets(false);});
    dialog.show();
  }
  void addMenuAction(LinearLayout parent,String kind,String label,Runnable action){
    LinearLayout v=row();v.setPadding(d(16),0,d(11),0);
    v.setBackground(NightwellDesign.ripple(a,0x7b705275,18,true));
    v.addView(new NavigationMenuIcon(a,kind,0xffeeeeee),new LinearLayout.LayoutParams(d(26),d(26)));
    TextView name=heading(label,15);name.setPadding(d(13),0,0,0);
    v.addView(name,new LinearLayout.LayoutParams(0,-2,1));
    TextView arrow=text("›",24);v.addView(arrow);
    v.setOnClickListener(x->action.run());
    LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,d(54));p.bottomMargin=d(10);
    parent.addView(v,p);
  }
  Dialog sheet(String title,boolean bottom){
    Dialog dialog=new Dialog(a);
    LinearLayout shell=column();
    shell.setPadding(d(17),d(16),d(17),d(17));
    shell.setBackground(glassColor(0xe0441e51,27));
    LinearLayout heading=row();heading.setGravity(Gravity.CENTER_VERTICAL);
    TextView label=heading(title,24);heading.addView(label,new LinearLayout.LayoutParams(0,-2,1));
    TextView close=heading("×",28);close.setGravity(Gravity.CENTER);
    close.setTextColor(0xffff58b3);close.setOnClickListener(v->dialog.dismiss());
    heading.addView(close,new LinearLayout.LayoutParams(d(42),d(43)));
    shell.addView(heading,new LinearLayout.LayoutParams(-1,d(59)));
    ScrollView scroll=new ScrollView(a);scroll.setFillViewport(false);scroll.setVerticalScrollBarEnabled(false);
    LinearLayout content=column();content.setTag("nw-content");content.setPadding(0,d(9),0,d(10));
    scroll.addView(content);shell.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
    dialog.setContentView(shell);
    Window win=dialog.getWindow();
    if(win!=null){
      win.setBackgroundDrawableResource(android.R.color.transparent);
      win.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
      win.setDimAmount(bottom?.48f:.30f);
      win.setGravity(bottom?Gravity.BOTTOM:Gravity.CENTER);
      int width=a.getResources().getDisplayMetrics().widthPixels;
      win.setLayout(Math.max(d(200),width-d(bottom?16:34)),bottom?
          (int)(a.getResources().getDisplayMetrics().heightPixels*.52):
          (int)(a.getResources().getDisplayMetrics().heightPixels*.77));
    }
    dialog.setOnShowListener(v->{
       Window window=dialog.getWindow();if(window!=null){
         int w=a.getResources().getDisplayMetrics().widthPixels;
         window.setLayout(Math.max(d(200),w-d(bottom?16:34)),
             (int)(a.getResources().getDisplayMetrics().heightPixels*(bottom?.52f:.73f)));
       }
    });
    return dialog;
  }
  void settingsHub(){
    Dialog dialog=sheet("Настройки",false);
    LinearLayout content=(LinearLayout)dialog.findViewWithTag("nw-content");
    addSettingsRow(content,"sparkles","Темы","Стандартная и Vice Nights",()->{dialog.dismiss();themes();});
    addSettingsRow(content,"sliders","Кастомизация","Вкладки, обложки, очередь, текст и фон",()->{dialog.dismiss();customization();});
    addSettingsRow(content,"stats","Воспроизведение","Звук, буфер, громкость и офлайн",()->{dialog.dismiss();a.legacySettings();});
    addSettingsRow(content,"person","О приложении","Версия и сведения о сборке",()->{
      dialog.dismiss();new android.app.AlertDialog.Builder(a).setTitle("Nightwell Music")
       .setMessage(BuildConfig.VERSION_NAME+" · Android\nНативное приложение Nightwell Music")
       .setPositiveButton("Готово",null).show();
    });
    dialog.show();
  }
  void addSettingsRow(LinearLayout parent,String icon,String title,String sub,Runnable action){
    LinearLayout card=row();card.setGravity(Gravity.CENTER_VERTICAL);
    card.setPadding(d(14),d(11),d(12),d(11));
    card.setBackground(glassColor(0x77563168,20));
    FrameLayout iconBox=new FrameLayout(a);iconBox.addView(new NavigationMenuIcon(a,icon,0xffffffff),
       new FrameLayout.LayoutParams(d(25),d(25),Gravity.CENTER));
    card.addView(iconBox,new LinearLayout.LayoutParams(d(40),d(50)));
    LinearLayout labels=column();
    TextView h=heading(title,17);labels.addView(h);
    TextView det=text(sub,12);det.setTextColor(0xb9f6e9f5);det.setMaxLines(2);
    LinearLayout.LayoutParams dp=new LinearLayout.LayoutParams(-1,-2);dp.topMargin=d(4);labels.addView(det,dp);
    LinearLayout.LayoutParams textP=new LinearLayout.LayoutParams(0,-2,1);textP.leftMargin=d(6);
    card.addView(labels,textP);
    TextView chevron=text("›",27);chevron.setTextColor(0xaaddc4e2);card.addView(chevron);
    card.setOnClickListener(v->action.run());
    LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,d(79));lp.bottomMargin=d(11);
    parent.addView(card,lp);
  }
  void themes(){
    Dialog dialog=sheet("Темы",false);
    LinearLayout content=(LinearLayout)dialog.findViewWithTag("nw-content");
    content.addView(heading("Темы оформления",18));
    TextView hint=text("Выбранное оформление включается сразу и сохраняется.",13);
    hint.setTextColor(0xbbf4d6e9);
    LinearLayout.LayoutParams hp=new LinearLayout.LayoutParams(-1,-2);hp.topMargin=d(12);
    hp.bottomMargin=d(20);content.addView(hint,hp);
    LinearLayout variants=row();
    variants.addView(themeCard("Стандартная",false,()->{
      setTheme(false);dialog.dismiss();themes();
    }),new LinearLayout.LayoutParams(0,d(260),1));
    View gap=new View(a);variants.addView(gap,new LinearLayout.LayoutParams(d(12),1));
    variants.addView(themeCard("Vice Nights",true,()->{
      setTheme(true);dialog.dismiss();themes();
    }),new LinearLayout.LayoutParams(0,d(260),1));
    content.addView(variants);
    dialog.show();
  }
  LinearLayout themeCard(String label,boolean vice,Runnable choose){
    LinearLayout card=column();card.setPadding(d(8),d(8),d(8),d(10));
    card.setBackground(NightwellDesign.ripple(a,vice?0x995b3663:0xcc242428,20,true));
    TextView image=heading("N",51);image.setGravity(Gravity.TOP|Gravity.LEFT);
    image.setPadding(d(16),d(18),0,0);
    image.setBackground(new GradientDrawable(GradientDrawable.Orientation.TL_BR,
       vice?new int[]{0xff21152d,0xffa72c75,0xff304c7c}:new int[]{0xff1b1b1b,0xff080808}));
    card.addView(image,new LinearLayout.LayoutParams(-1,d(165)));
    TextView name=heading(label+(vice==vice()?" ✓":""),14);
    LinearLayout.LayoutParams np=new LinearLayout.LayoutParams(-1,-2);np.topMargin=d(12);card.addView(name,np);
    TextView description=text(vice?"Неон и закат":"Чёрно-белая",12);
    description.setTextColor(0xbff6d5ee);LinearLayout.LayoutParams dp=new LinearLayout.LayoutParams(-1,-2);
    dp.topMargin=d(7);card.addView(description,dp);card.setOnClickListener(v->choose.run());return card;
  }
  void setTheme(boolean nextVice){
    a.getSharedPreferences("appearance",Context.MODE_PRIVATE).edit()
      .putString("visual-theme",nextVice?"vice":"standard").apply();
    a.build();
  }
  void customization(){
    Dialog dialog=sheet("Кастомизация",false);
    LinearLayout content=(LinearLayout)dialog.findViewWithTag("nw-content");
    content.addView(heading("Кастомизация",19));
    a.addIOSCustomizationControls(content);
    dialog.show();
  }
}
