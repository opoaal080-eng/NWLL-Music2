package fun.nightwell.music;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.util.Base64;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Supplier;

/** Native Android account UI based on the iOS ProfileSettingsView and AccountAccessView.
 * Uses the same authenticated endpoints; no WebView or duplicate account state.
 */
final class NightwellAccountUI {
    static final int AVATAR_REQUEST=637;
    private final MainActivity host;
    private final NativeAPI api;
    private final Supplier<String> user;
    private final ExecutorService avatarIO=Executors.newSingleThreadExecutor(r->{
        Thread t=new Thread(r,"NightwellProfileAvatar");t.setDaemon(true);return t;
    });
    private FrameLayout header;
    private ImageView headerImage, profileImage;
    private Bitmap bitmap;
    private String bitmapUser="",nickname="",avatarURL="";
    private long profileRefreshAt;
    private TextView profileNotice;
    private EditText nicknameInput;
    NightwellAccountUI(MainActivity host,NativeAPI api,Supplier<String> user){
        this.host=host;this.api=api;this.user=user;
    }
    void close(){avatarIO.shutdownNow();}
    private int dp(int n){return host.dp(n);}
    private TextView text(String text,int size){return host.text(text,size);}
    private LinearLayout column(){return host.column();}
    private LinearLayout row(){return host.row();}
    private String owner(){return user.get();}
    private void notice(String text){
        if(profileNotice!=null)profileNotice.setText(text);
        else Toast.makeText(host,text,Toast.LENGTH_LONG).show();
    }
    void bindHeaderAvatar(FrameLayout target){
        if(header!=target||headerImage==null){
            header=target;
            headerImage=new ImageView(host);
            headerImage.setScaleType(ImageView.ScaleType.CENTER_CROP);
            GradientDrawable shape=new GradientDrawable();
            shape.setColor(0xff26242c);shape.setCornerRadius(dp(22));
            headerImage.setBackground(shape);headerImage.setClipToOutline(true);
            header.addView(headerImage,new FrameLayout.LayoutParams(-1,-1));
        }
        boolean same=bitmap!=null&&bitmapUser.equals(owner());
        headerImage.setVisibility(same?View.VISIBLE:View.GONE);
        headerImage.setImageBitmap(same?bitmap:null);
        if(!owner().isEmpty()&&!same)refreshMetadata(false);
    }
    private TextView profileMonogram;
    void showProfile(){
        if(owner().isEmpty()){host.auth();return;}
        profileNotice=null;
        Dialog full=new Dialog(host,android.R.style.Theme_DeviceDefault_NoActionBar);
        LinearLayout shell=column();
        shell.setPadding(dp(18),dp(15),dp(18),dp(15));
        shell.setBackground(new GradientDrawable(GradientDrawable.Orientation.TL_BR,new int[]{
            0xff4e174d,0xff822263,0xff42346f,0xff112b53}));
        LinearLayout nav=row();nav.setGravity(Gravity.CENTER_VERTICAL);
        TextView title=text("Профиль",21);title.setTypeface(null,android.graphics.Typeface.BOLD);
        title.setGravity(Gravity.CENTER);
        View spacer=new View(host);nav.addView(spacer,new LinearLayout.LayoutParams(dp(72),dp(55)));
        nav.addView(title,new LinearLayout.LayoutParams(0,dp(55),1));
        TextView done=text("Готово",15);done.setTypeface(null,android.graphics.Typeface.BOLD);
        done.setGravity(Gravity.CENTER);
        done.setBackground(profileGlass(20));
        done.setOnClickListener(v->full.dismiss());
        nav.addView(done,new LinearLayout.LayoutParams(dp(77),dp(50)));
        shell.addView(nav,new LinearLayout.LayoutParams(-1,dp(90)));

        ScrollView scroll=new ScrollView(host);scroll.setFillViewport(false);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout panel=column();panel.setPadding(dp(2),dp(8),dp(2),dp(25));
        scroll.addView(panel);
        shell.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));

        LinearLayout card=column();card.setPadding(dp(18),dp(15),dp(18),dp(16));
        card.setBackground(profileGlass(26));
        LinearLayout caption=row();caption.setGravity(Gravity.CENTER_VERTICAL);
        caption.addView(new NavigationMenuIcon(host,"person",0xfff8f3fb),
            new LinearLayout.LayoutParams(dp(22),dp(22)));
        TextView cardTitle=text("Профиль",19);cardTitle.setTypeface(null,android.graphics.Typeface.BOLD);
        cardTitle.setPadding(dp(12),0,0,0);caption.addView(cardTitle);
        card.addView(caption);
        LinearLayout identity=row();identity.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams idParams=new LinearLayout.LayoutParams(-1,dp(82));
        idParams.topMargin=dp(12);
        android.widget.FrameLayout avatar=new android.widget.FrameLayout(host);
        avatar.setBackground(profileGlass(38));
        avatar.setClipToOutline(true);
        profileMonogram=text("N",30);profileMonogram.setGravity(Gravity.CENTER);
        profileMonogram.setTypeface(null,android.graphics.Typeface.BOLD);
        avatar.addView(profileMonogram,new android.widget.FrameLayout.LayoutParams(-1,-1));
        profileImage=new ImageView(host);profileImage.setScaleType(ImageView.ScaleType.CENTER_CROP);
        profileImage.setVisibility(bitmap!=null&&bitmapUser.equals(owner())?View.VISIBLE:View.GONE);
        if(bitmap!=null&&bitmapUser.equals(owner()))profileImage.setImageBitmap(bitmap);
        avatar.addView(profileImage,new android.widget.FrameLayout.LayoutParams(-1,-1));
        identity.addView(avatar,new LinearLayout.LayoutParams(dp(72),dp(72)));
        TextView photo=host.sheetAction("◈  Изменить аватар",this::selectAvatar);
        photo.setBackground(profileGlass(17));
        LinearLayout.LayoutParams photoParams=new LinearLayout.LayoutParams(0,dp(48),1);
        photoParams.leftMargin=dp(15);identity.addView(photo,photoParams);
        card.addView(identity,idParams);
        nicknameInput=new EditText(host);nicknameInput.setHint("Ник, от 2 до 32 символов");
        nicknameInput.setSingleLine(true);host.styleField(nicknameInput);
        nicknameInput.setText(nickname);
        LinearLayout.LayoutParams nickParams=new LinearLayout.LayoutParams(-1,dp(54));
        nickParams.topMargin=dp(8);card.addView(nicknameInput,nickParams);
        TextView save=host.sheetAction("Сохранить ник",()->saveNickname());
        save.setBackground(profileGlass(18));
        LinearLayout.LayoutParams saveParams=new LinearLayout.LayoutParams(-2,dp(50));
        saveParams.topMargin=dp(10);card.addView(save,saveParams);
        profileNotice=text("",12);profileNotice.setTextColor(0xfff8cbda);
        profileNotice.setPadding(dp(4),dp(7),dp(4),dp(1));card.addView(profileNotice);
        LinearLayout.LayoutParams cardParams=new LinearLayout.LayoutParams(-1,-2);
        cardParams.bottomMargin=dp(12);panel.addView(card,cardParams);

        addProfileRow(panel,"person","Устройства и семья",this::showDevicesFamily);
        addProfileRow(panel,"library","Виджеты",()->
            Toast.makeText(host,"Виджеты Android ещё не реализованы",Toast.LENGTH_SHORT).show());
        addProfileRow(panel,"stats","Статистика",()->host.feature("stats"));
        addProfileRow(panel,"star",host.premiumAllowed()?
            "Nightwell Premium · Подписка активна":"Nightwell Premium",host::premium);
        addProfileRow(panel,"download","Выйти из аккаунта",()->new AlertDialog.Builder(host)
            .setTitle("Выйти из аккаунта?")
            .setMessage("Музыка и загруженные треки не будут удалены.")
            .setNegativeButton("Отмена",null)
            .setPositiveButton("Выйти",(d,n)->{
                full.dismiss();clearIdentity();host.selectMenu("Выйти");
            }).show());
        full.setContentView(shell);
        android.view.Window w=full.getWindow();
        if(w!=null){
            w.setBackgroundDrawableResource(android.R.color.transparent);
            w.clearFlags(android.view.WindowManager.LayoutParams.FLAG_FULLSCREEN);
            w.addFlags(android.view.WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
            w.setStatusBarColor(0xff451747);
            w.setNavigationBarColor(0xff112b53);
            w.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        }
        full.show();
        if(full.getWindow()!=null)
            full.getWindow().setLayout(android.view.WindowManager.LayoutParams.MATCH_PARENT,
                android.view.WindowManager.LayoutParams.MATCH_PARENT);
        refreshMetadata(true);
    }
    private android.graphics.drawable.Drawable profileGlass(int radius){
        GradientDrawable bg=new GradientDrawable(GradientDrawable.Orientation.TL_BR,
            new int[]{0x99613a67,0x88543a64,0x88413762});
        bg.setCornerRadius(dp(radius));bg.setStroke(dp(1),0x55e0a2d7);return bg;
    }
    private void addProfileRow(LinearLayout parent,String icon,String label,Runnable click){
        LinearLayout row=row();row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(15),dp(9),dp(13),dp(9));row.setBackground(profileGlass(21));
        row.addView(new NavigationMenuIcon(host,icon,0xfffaf2ff),
            new LinearLayout.LayoutParams(dp(25),dp(25)));
        TextView title=text(label,16);title.setTypeface(null,android.graphics.Typeface.BOLD);
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,-2,1);
        lp.leftMargin=dp(14);row.addView(title,lp);
        TextView chevron=text("›",27);chevron.setTextColor(0xfff8d5ef);
        row.addView(chevron,new LinearLayout.LayoutParams(dp(25),-2));
        row.setOnClickListener(v->click.run());
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,dp(64));
        p.bottomMargin=dp(11);parent.addView(row,p);
    }
    private void addAction(LinearLayout panel,String title,Runnable onClick){
        TextView action=host.sheetAction(title,onClick);
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,dp(48));
        params.bottomMargin=dp(8);panel.addView(action,params);
    }
    private void clearIdentity(){
        bitmap=null;bitmapUser="";nickname="";avatarURL="";
        profileRefreshAt=0;
        if(headerImage!=null){headerImage.setImageBitmap(null);headerImage.setVisibility(View.GONE);}
    }
    private void refreshMetadata(boolean force){
        String scope=owner();if(scope.isEmpty())return;
        long now=android.os.SystemClock.elapsedRealtime();
        if(!force&&now-profileRefreshAt<45000)return;
        profileRefreshAt=now;
        host.task(()->api.request("api/profile/me"),profile->{
            if(!scope.equals(owner()))return;
            nickname=profile.optString("nickname","");
            if(nicknameInput!=null&&nicknameInput.isAttachedToWindow()&&!nicknameInput.hasFocus())
                nicknameInput.setText(nickname);
            String next=profile.optString("avatar_url","");
            if(!next.isEmpty()&&(!next.equals(avatarURL)||bitmap==null||!scope.equals(bitmapUser))){
                avatarURL=next;downloadAvatar(scope,next);
            }else if(next.isEmpty()){
                avatarURL="";bitmap=null;bitmapUser=scope;
                if(headerImage!=null){headerImage.setImageBitmap(null);headerImage.setVisibility(View.GONE);}
                if(profileImage!=null){profileImage.setImageBitmap(null);profileImage.setVisibility(View.GONE);}
            }
        });
    }
    private void downloadAvatar(String account,String source){
        avatarIO.execute(()->{
            HttpURLConnection conn=null;
            try{
                URL url=new URL(new URL(api.origin),source);
                if(!ServerAddress.sameOrigin(api.origin,url.toString()))return;
                conn=api.connection(url.getPath()+(url.getQuery()==null?"":"?"+url.getQuery()));
                if(conn.getResponseCode()!=200)return;
                byte[] raw=NativeAPI.read(conn.getInputStream(),768*1024+1);
                Bitmap result=BitmapFactory.decodeByteArray(raw,0,raw.length);
                if(result==null||result.getWidth()<8||result.getHeight()<8)return;
                host.runOnUiThread(()->{
                    if(host.isDestroyed()||!account.equals(owner())||!source.equals(avatarURL))return;
                    bitmap=result;bitmapUser=account;
                    if(headerImage!=null){headerImage.setImageBitmap(result);headerImage.setVisibility(View.VISIBLE);}
                    if(profileImage!=null){profileImage.setImageBitmap(result);profileImage.setVisibility(View.VISIBLE);}
                });
            }catch(Exception ignored){
                // Cached metadata is still useful if the optional avatar fails.
            }finally{if(conn!=null)conn.disconnect();}
        });
    }
    private void saveNickname(){
        String value=nicknameInput.getText().toString().trim();
        if(value.length()<2||value.length()>32){notice("Ник должен быть от 2 до 32 символов");return;}
        String account=owner();notice("Сохраняем ник…");
        host.task(()->api.request("api/profile/me","PUT",new JSONObject().put("nickname",value)),data->{
            if(!account.equals(owner()))return;
            nickname=data.optString("nickname",value);
            notice("Ник сохранён");
        });
    }
    private void selectAvatar(){
        Intent choose=new Intent(Intent.ACTION_OPEN_DOCUMENT);
        choose.setType("image/*");choose.addCategory(Intent.CATEGORY_OPENABLE);
        try{host.startActivityForResult(choose,AVATAR_REQUEST);}
        catch(Exception ex){notice("Не удалось открыть галерею");}
    }
    void avatarSelected(int result,Intent data){
        if(result!=Activity.RESULT_OK||data==null||data.getData()==null)return;
        Uri selected=data.getData();String account=owner();notice("Обновляем аватар…");
        avatarIO.execute(()->{
            try{
                BitmapFactory.Options opts=new BitmapFactory.Options();opts.inJustDecodeBounds=true;
                try(InputStream input=host.getContentResolver().openInputStream(selected)){BitmapFactory.decodeStream(input,null,opts);}
                if(opts.outWidth<=0||opts.outHeight<=0)throw new IllegalArgumentException("Изображение не поддерживается");
                opts.inJustDecodeBounds=false;
                int sample=1;
                while(Math.max(opts.outWidth,opts.outHeight)/sample>720)sample*=2;
                opts.inSampleSize=sample;
                Bitmap picture;
                try(InputStream input=host.getContentResolver().openInputStream(selected)){picture=BitmapFactory.decodeStream(input,null,opts);}
                if(picture==null)throw new IllegalArgumentException("Не удалось открыть изображение");
                int width=picture.getWidth(),height=picture.getHeight();
                float scale=Math.min(1f,480f/Math.max(width,height));
                Bitmap scaled=scale<1?Bitmap.createScaledBitmap(picture,Math.max(1,Math.round(width*scale)),Math.max(1,Math.round(height*scale)),true):picture;
                ByteArrayOutputStream output=new ByteArrayOutputStream();
                scaled.compress(Bitmap.CompressFormat.JPEG,82,output);
                byte[] jpg=output.toByteArray();
                if(jpg.length>768*1024)throw new IllegalArgumentException("Изображение слишком большое");
                JSONObject request=new JSONObject().put("mime","image/jpeg")
                    .put("avatar_base64",Base64.encodeToString(jpg,Base64.NO_WRAP));
                JSONObject response=api.request("api/profile/avatar","POST",request);
                host.runOnUiThread(()->{
                    if(host.isDestroyed()||!account.equals(owner()))return;
                    bitmap=scaled;bitmapUser=account;
                    if(headerImage!=null){headerImage.setImageBitmap(scaled);headerImage.setVisibility(View.VISIBLE);}
                    if(profileImage!=null){profileImage.setImageBitmap(scaled);profileImage.setVisibility(View.VISIBLE);}
                    avatarURL=response.optString("avatar_url","");
                    notice("Аватар обновлён");
                });
            }catch(Exception ex){
                host.runOnUiThread(()->notice("Ошибка аватара: "+ex.getMessage()));
            }
        });
    }
    void showDevicesFamily(){
        if(owner().isEmpty()){host.auth();return;}
        LinearLayout panel=column();panel.setPadding(dp(16),dp(6),dp(16),dp(12));
        ScrollView scroll=new ScrollView(host);scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(panel);
        TextView message=text("Загружаем устройства и семью…",14);
        panel.addView(message);
        AlertDialog dialog=new AlertDialog.Builder(host).setTitle("Устройства и семья")
            .setView(scroll).setPositiveButton("Готово",null).create();
        host.styleSheet(dialog);dialog.show();
        fetchFamily(panel,message,dialog);
    }
    private void fetchFamily(LinearLayout panel,TextView message,AlertDialog dialog){
        final String account=owner();
        host.task(()->new JSONObject()
            .put("devices",api.request("api/devices"))
            .put("family",api.request("api/family")),data->{
            if(dialog==null||!dialog.isShowing()||!account.equals(owner()))return;
            panel.removeAllViews();
            JSONObject devices=data.optJSONObject("devices");
            if(devices!=null){
                panel.addView(host.sectionLabel("Устройства"));
                int limit=devices.optInt("limit",2),count=devices.optInt("count",0);
                TextView countLabel=text("Подключено "+count+" из "+limit,13);
                countLabel.setTextColor(NightwellDesign.SECONDARY);
                panel.addView(countLabel);
                JSONArray list=devices.optJSONArray("devices");
                for(int i=0;list!=null&&i<list.length();i++){
                    JSONObject device=list.optJSONObject(i);if(device==null)continue;
                    String deviceId=device.optString("id");
                    boolean isCurrent=device.optBoolean("current");
                    String name=device.optString("name","Устройство");
                    String label=name+" · "+device.optString("platform","")
                        +(isCurrent?" · Это устройство":"")
                        +(device.optBoolean("blocked")?" · Заблокировано":"");
                    addAction(panel,label,isCurrent?()->Toast.makeText(host,"Это текущее устройство",Toast.LENGTH_SHORT).show():
                        ()->confirmAction("Удалить устройство «"+name+"»?","api/devices/"+Uri.encode(deviceId),"DELETE",panel,message,dialog));
                }
            }
            JSONObject familyResponse=data.optJSONObject("family");
            JSONObject family=familyResponse==null?null:familyResponse.optJSONObject("family");
            panel.addView(host.sectionLabel("Семья"));
            if(family==null){
                panel.addView(text("Можно присоединиться к семейной группе по приглашению.",13));
            }else{
                String role=family.optString("role","");
                JSONArray members=family.optJSONArray("members");
                panel.addView(text("Участники: "+(members==null?0:members.length()),13));
                for(int i=0;members!=null&&i<members.length();i++){
                    JSONObject member=members.optJSONObject(i);if(member==null)continue;
                    String memberId=member.optString("account_id");
                    String label=memberId+" · "+member.optString("role");
                    if("owner".equals(role)&&!"owner".equals(member.optString("role"))){
                        addAction(panel,label,()->confirmAction("Удалить участника?","api/family/members/"+Uri.encode(memberId),"DELETE",panel,message,dialog));
                    }else panel.addView(text(label,13));
                }
                if("owner".equals(role)){
                    addAction(panel,"Пригласить в семью",()->{
                        host.task(()->api.request("api/family/invitations","POST",new JSONObject()),invite->{
                            String url=invite.optString("invite_url");
                            if(url.isEmpty())return;
                            android.content.ClipboardManager clip=(android.content.ClipboardManager)
                                host.getSystemService(android.content.Context.CLIPBOARD_SERVICE);
                            clip.setPrimaryClip(android.content.ClipData.newPlainText("Приглашение Nightwell",url));
                            Intent share=new Intent(Intent.ACTION_SEND);share.setType("text/plain");
                            share.putExtra(Intent.EXTRA_TEXT,url);
                            host.startActivity(Intent.createChooser(share,"Приглашение в семью"));
                        });
                    });
                    addAction(panel,"Удалить семью",()->confirmAction("Удалить семейную группу?","api/family","DELETE",panel,message,dialog));
                }else addAction(panel,"Выйти из семьи",()->confirmAction("Покинуть семейную группу?","api/family/leave","POST",panel,message,dialog));
            }
            addAction(panel,"Присоединиться по приглашению",()->joinFamily(panel,message,dialog));
        });
    }
    private void confirmAction(String title,String path,String method,LinearLayout panel,
                               TextView note,AlertDialog dialog){
        new AlertDialog.Builder(host).setTitle(title).setNegativeButton("Отмена",null)
            .setPositiveButton("Подтвердить",(d,n)->host.task(
                ()->api.request(path,method,new JSONObject()),
                result->fetchFamily(panel,note,dialog))).show();
    }
    private void joinFamily(LinearLayout panel,TextView note,AlertDialog dialog){
        EditText input=new EditText(host);input.setHint("Ссылка или код приглашения");host.styleField(input);
        LinearLayout frame=column();frame.setPadding(dp(16),dp(9),dp(16),dp(9));frame.addView(input);
        new AlertDialog.Builder(host).setTitle("Вступить в семью").setView(frame)
            .setNegativeButton("Отмена",null).setPositiveButton("Присоединиться",(d,n)->{
                String token=input.getText().toString().trim();
                int where=token.indexOf("#invite=");if(where>=0)token=token.substring(where+8);
                if(!token.matches("[A-Za-z0-9_-]{43}")){
                    Toast.makeText(host,"Неверный код приглашения",Toast.LENGTH_LONG).show();return;
                }
                final String actual=token;
                host.task(()->api.request("api/family/invitations/accept","POST",
                    new JSONObject().put("token",actual)),result->fetchFamily(panel,note,dialog));
            }).show();
    }
}
