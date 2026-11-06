package fun.nightwell.music;

import android.app.AlertDialog;
import android.content.ClipboardManager;
import android.content.ClipData;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.*;
import org.json.*;
import java.util.concurrent.*;

/** Native Together controls; music stays in Nightwell's own Media3 PlaybackService. */
final class NativeTogetherAndroid {
    private final MainActivity activity;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService network = Executors.newSingleThreadExecutor();
    private volatile String roomCode = "";
    private String invite = "";
    private JSONObject room;
    private AlertDialog dialog;
    private LinearLayout content;
    private TextView notice;
    private long suppressUntil;
    private boolean polling, closed;
    NativeTogetherAndroid(MainActivity host) { activity = host; }
    static String parseCode(String input) {
        if(input==null)return null;
        String value=input.trim();
        try {
            if(value.contains("://")) {
                android.net.Uri uri=android.net.Uri.parse(value);
                if(!"music.nightwell.fun".equalsIgnoreCase(uri.getHost()))return null;
                value=uri.getQueryParameter("together");
            }
        } catch(Exception ignored) {return null;}
        return value!=null&&value.matches("[A-Za-z0-9_-]{24}")?value:null;
    }
    void invite(String code) {
        String parsed=parseCode(code);
        if(parsed!=null) {invite=parsed;open();}
    }
    boolean connected() {return !roomCode.isEmpty();}
    boolean mayControl() {
        return room!=null&&(activity.togetherUser().equals(room.optString("owner"))||room.optBoolean("allow_control"));
    }
    void open() {
        if(activity.togetherUser().isEmpty()){activity.togetherRequireLogin();return;}
        if(dialog!=null&&dialog.isShowing()){render();return;}
        ScrollView scroll=new ScrollView(activity);
        content=new LinearLayout(activity);
        content.setOrientation(LinearLayout.VERTICAL);
        int pad=dp(18);content.setPadding(pad,pad,pad,pad);
        scroll.addView(content);
        dialog=new AlertDialog.Builder(activity).setTitle("Nightwell Together")
            .setView(scroll).setNegativeButton("Закрыть",(d,w)->{}).create();
        dialog.setOnDismissListener(d->{dialog=null;content=null;notice=null;});
        render();dialog.show();
    }
    private int dp(float d){return (int)(d*activity.getResources().getDisplayMetrics().density+.5f);}
    private TextView text(String s) {
        TextView result=new TextView(activity);result.setText(s);result.setTextColor(0xffeeeeee);
        result.setTextSize(15);result.setPadding(0,dp(9),0,dp(9));return result;
    }
    private void button(String name,Runnable task) {
        Button b=new Button(activity);b.setAllCaps(false);b.setText(name);
        b.setOnClickListener(v->task.run());
        content.addView(b,new LinearLayout.LayoutParams(-1,-2));
    }
    private void render() {
        if(content==null)return;
        content.removeAllViews();
        content.addView(text("Один трек, общая очередь и приглашение только по ссылке."));
        notice=text("");content.addView(notice);
        if(roomCode.isEmpty()) {
            button("Создать комнату",()->request("api/together/rooms",new JSONObject(),true));
            EditText input=new EditText(activity);
            input.setSingleLine();input.setHint("Ссылка или код комнаты");input.setText(invite);
            input.setTextColor(0xffffffff);input.setHintTextColor(0xffaaaaaa);content.addView(input);
            button("Присоединиться",()->{
                String code=parseCode(input.getText().toString());
                if(code==null){message("Нужна действительная ссылка приглашения");return;}
                invite=code;request("api/together/rooms/"+code+"/join",new JSONObject(),true);
            });
            return;
        }
        JSONObject data=room;
        content.addView(text(data==null?"Подключаемся…":data.optJSONObject("track")==null?"Выбери трек":data.optJSONObject("track").optString("title")));
        content.addView(text(data==null?"":data.optJSONObject("track")==null?"":data.optJSONObject("track").optString("artist")));
        int count=data==null?1:data.optJSONArray("members")==null?0:data.optJSONArray("members").length();
        content.addView(text("Участников: "+count+"/10"));
        button("Пригласить по ссылке",()->{
            String url="https://music.nightwell.fun/?together="+roomCode;
            ClipboardManager manager=(ClipboardManager)activity.getSystemService(Context.CLIPBOARD_SERVICE);
            if(manager!=null)manager.setPrimaryClip(ClipData.newPlainText("Nightwell Together",url));
            message("Ссылка скопирована");
        });
        if(mayControl()) {
            button(data!=null&&data.optBoolean("playing")?"Пауза":"Воспроизвести",()->command(data!=null&&data.optBoolean("playing")?"pause":"play",null));
            button("Предыдущий трек",()->command("previous",null));
            button("Следующий трек",()->command("next",null));
        }
        button("Добавить текущий трек в очередь",()->{
            String id=activity.togetherCurrentID();
            if(id.isEmpty()){message("Сначала включи трек");return;}
            try{request("api/together/rooms/"+roomCode+"/queue",new JSONObject().put("track_id",id),false);}
            catch(Exception e){message(e.getMessage());}
        });
        button("Вернуться к друзьям",()->{
            if(room!=null)applyRemote(room,true);
        });
        if(data!=null) {
            JSONArray people=data.optJSONArray("members");
            if(people!=null) {
                content.addView(text("Участники"));
                for(int i=0;i<people.length();i++){
                    JSONObject p=people.optJSONObject(i);
                    if(p!=null)content.addView(text("• "+(p.optString("name").startsWith("User-")?"Участник":p.optString("name"))+(p.optString("id").equals(data.optString("owner"))?" · ведущий":"")));
                }
            }
            JSONArray queue=data.optJSONArray("queue");
            if(queue!=null) {
                content.addView(text("Общая очередь"));
                for(int i=0;i<queue.length()&&i<50;i++){
                    JSONObject track=queue.optJSONObject(i);
                    if(track==null)continue;
                    String id=track.optString("id");
                    if(mayControl())button("▶ "+track.optString("artist")+" · "+track.optString("title"),()->command("track",id));
                    else content.addView(text(track.optString("artist")+" · "+track.optString("title")));
                }
            }
            if(activity.togetherUser().equals(data.optString("owner"))) {
                Switch toggle=new Switch(activity);toggle.setText("Разрешить всем управлять");toggle.setTextColor(0xffffffff);
                toggle.setChecked(data.optBoolean("allow_control"));
                toggle.setOnCheckedChangeListener((v,checked)->{
                    try{request("api/together/rooms/"+roomCode+"/settings",new JSONObject().put("allow_control",checked),false);}
                    catch(Exception ex){message(ex.getMessage());}
                });content.addView(toggle);
            }
        }
        button("Покинуть комнату",()->{
            String old=roomCode;roomCode="";room=null;render();
            request("api/together/rooms/"+old+"/leave",new JSONObject(),false);
        });
    }
    private void message(String m){if(notice!=null)notice.setText(m);}
    private void request(String endpoint,JSONObject payload,boolean activate) {
        if(closed)return;
        network.execute(()->{
            try {
                JSONObject response=activity.togetherAPI().request(endpoint,"POST",payload);
                main.post(()->{
                    if(closed)return;
                    if(activate) {
                        JSONObject joined=response.optJSONObject("room");
                        if(joined==null){message("Сервер не вернул комнату");return;}
                        room=joined;roomCode=joined.optString("code");render();startPoll();
                        if(endpoint.equals("api/together/rooms")&&!activity.togetherCurrentID().isEmpty())command("track",activity.togetherCurrentID());
                    }else {fetch();}
                });
            } catch(Exception ex){main.post(()->message(ex.getMessage()));}
        });
    }
    private void command(String action,String trackID) {
        if(!connected()||!mayControl())return;
        try {
            JSONObject body=new JSONObject().put("action",action);
            if(trackID!=null)body.put("track_id",trackID);
            request("api/together/rooms/"+roomCode+"/command",body,false);
        }catch(Exception ex){message(ex.getMessage());}
    }
    boolean nativeNext(String action) {
        if(!connected()||!mayControl()||android.os.SystemClock.elapsedRealtime()<suppressUntil)return false;
        command(action,null);return true;
    }
    void nativeTrack(String id) {
        if(!connected()||!mayControl()||android.os.SystemClock.elapsedRealtime()<suppressUntil||id.equals(room==null?"":room.optJSONObject("track")==null?"":room.optJSONObject("track").optString("id")))return;
        command("track",id);
    }
    void nativeToggle(boolean play) {
        if(!connected()||!mayControl()||android.os.SystemClock.elapsedRealtime()<suppressUntil||room==null)return;
        if(play!=room.optBoolean("playing"))command(play?"play":"pause",null);
    }
    private void startPoll() {
        if(polling)return;polling=true;
        main.post(new Runnable() {
            @Override public void run(){
                if(closed||roomCode.isEmpty()){polling=false;return;}
                fetch();main.postDelayed(this,1600);
            }
        });
    }
    private void fetch() {
        final String code=roomCode;
        if(code.isEmpty()||closed)return;
        network.execute(()->{
            try {
                JSONObject data=activity.togetherAPI().request("api/together/rooms/"+code).getJSONObject("room");
                main.post(()->{
                    if(!code.equals(roomCode)||closed)return;
                    room=data;applyRemote(data,false);render();
                });
            }catch(Exception ex){main.post(()->message("Переподключаемся к комнате…"));}
        });
    }
    private void applyRemote(JSONObject data,boolean explicit) {
        JSONObject track=data.optJSONObject("track");
        if(track==null)return;
        String id=track.optString("id");
        long target=data.optLong("position_ms");
        if(data.optBoolean("playing"))target+=Math.max(0,System.currentTimeMillis()-data.optLong("updated_at_ms"));
        boolean changed=!id.equals(activity.togetherCurrentID());
        if(changed) {
            suppressUntil=android.os.SystemClock.elapsedRealtime()+4000;
            JSONArray queue=data.optJSONArray("queue");
            JSONArray full=new JSONArray();
            boolean found=false;
            if(queue!=null)for(int i=0;i<queue.length();i++){
                JSONObject item=queue.optJSONObject(i);
                if(item!=null){full.put(item);if(id.equals(item.optString("id")))found=true;}
            }
            if(!found)full.put(track);
            activity.togetherPlay(track,full);
            activity.togetherSeek(target);
        }else if(explicit||Math.abs(target-activity.togetherPosition())>1500) {
            suppressUntil=android.os.SystemClock.elapsedRealtime()+2500;
            activity.togetherSeek(target);
        }
        if(data.optBoolean("playing")!=activity.togetherIsPlaying()){
            suppressUntil=android.os.SystemClock.elapsedRealtime()+2500;
            activity.togetherSetPlaying(data.optBoolean("playing"));
        }
    }
    void shutdown() {
        closed=true;roomCode="";network.shutdownNow();
    }
}
