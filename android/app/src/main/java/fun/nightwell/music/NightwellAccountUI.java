package fun.nightwell.music;

import android.app.Activity;
import android.app.AlertDialog;
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
    void showProfile(){
        if(owner().isEmpty()){host.auth();return;}
        profileNotice=null;
        LinearLayout panel=column();panel.setPadding(dp(16),dp(7),dp(16),dp(12));
        ScrollView scroll=new ScrollView(host);scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(panel);
        LinearLayout identity=row();identity.setPadding(0,dp(6),0,dp(14));
        profileImage=new ImageView(host);
        profileImage.setScaleType(ImageView.ScaleType.CENTER_CROP);
        GradientDrawable circle=new GradientDrawable();circle.setColor(0xff343038);circle.setCornerRadius(dp(40));
        profileImage.setBackground(circle);profileImage.setClipToOutline(true);
        if(bitmap!=null&&bitmapUser.equals(owner()))profileImage.setImageBitmap(bitmap);
        identity.addView(profileImage,new LinearLayout.LayoutParams(dp(64),dp(64)));
        TextView photo=host.sheetAction("Изменить аватар",this::selectAvatar);
        LinearLayout.LayoutParams photoParams=new LinearLayout.LayoutParams(0,dp(52),1);
        photoParams.leftMargin=dp(13);identity.addView(photo,photoParams);panel.addView(identity);
        nicknameInput=new EditText(host);nicknameInput.setHint("Ник, от 2 до 32 символов");
        nicknameInput.setSingleLine(true);host.styleField(nicknameInput);
        nicknameInput.setText(nickname);panel.addView(nicknameInput);
        TextView save=host.sheetAction("Сохранить ник",()->saveNickname());
        LinearLayout.LayoutParams saveParams=new LinearLayout.LayoutParams(-1,dp(50));
        saveParams.topMargin=dp(10);panel.addView(save,saveParams);
        profileNotice=text("",12);profileNotice.setTextColor(NightwellDesign.MUTED);
        profileNotice.setPadding(dp(4),dp(8),dp(4),dp(8));panel.addView(profileNotice);
        panel.addView(host.sectionLabel("Аккаунт"));
        addAction(panel,"Устройства и семья",this::showDevicesFamily);
        addAction(panel,"Nightwell Premium",host::premium);
        addAction(panel,"Моя статистика",()->host.feature("stats"));
        addAction(panel,"Настройки",host::settings);
        addAction(panel,"Выйти из аккаунта",()->new AlertDialog.Builder(host)
            .setTitle("Выйти из аккаунта?")
            .setMessage("Музыка и загруженные треки не будут удалены.")
            .setNegativeButton("Отмена",null)
            .setPositiveButton("Выйти",(d,n)->{clearIdentity();host.selectMenu("Выйти");})
            .show());
        AlertDialog dialog=new AlertDialog.Builder(host).setTitle("Профиль")
            .setView(scroll).setPositiveButton("Готово",null).create();
        host.styleSheet(dialog);dialog.show();
        refreshMetadata(true);
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
                if(profileImage!=null)profileImage.setImageBitmap(null);
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
                    if(profileImage!=null)profileImage.setImageBitmap(result);
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
                    if(profileImage!=null)profileImage.setImageBitmap(scaled);
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
