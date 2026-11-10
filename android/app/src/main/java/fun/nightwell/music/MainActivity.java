package fun.nightwell.music;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;
import android.text.*;
import android.net.Uri;
import org.json.*;
import java.util.*;
import java.util.concurrent.*;

@androidx.annotation.OptIn(markerClass=androidx.media3.common.util.UnstableApi.class)
public final class MainActivity extends Activity {
    private boolean redirectedToFirstRun;
    private final Handler ui=new Handler(Looper.getMainLooper());
    private final ExecutorService io=Executors.newFixedThreadPool(3);
    private final ExecutorService waveIO=Executors.newSingleThreadExecutor();
    private final ExecutorService prefetch=Executors.newSingleThreadExecutor();
    private final ExecutorService playlistIndexer=Executors.newSingleThreadExecutor();
    private TextView liveHandoff, compactHandoff;
    private boolean handoffCollapsed = false;
    private Runnable handoffCollapseTask;
    private TextView nightwellBadge, nightwellMenuStatus;
    private ProgressBar nightwellMenuSpinner;
    private String nightwellStatus = "Проверка…";
    private final Runnable nightwellProbe = new Runnable() {
        @Override public void run() {
            if (smokeMode) { setNightwellStatus("Онлайн"); return; }
            if (!visible || isDestroyed()) return;
            io.execute(() -> {
                String result;
                if (!hasNetwork()) result = "Оффлайн";
                else {
                    java.net.HttpURLConnection connection = null;
                    try {
                        connection = (java.net.HttpURLConnection) new java.net.URL(origin + "api/me").openConnection();
                        connection.setConnectTimeout(4000);
                        connection.setReadTimeout(4000);
                        connection.setUseCaches(false);
                        connection.setRequestProperty("Accept", "application/json");
                        int code = connection.getResponseCode();
                        String type = connection.getContentType();
                        boolean valid = type != null && type.toLowerCase(java.util.Locale.ROOT).contains("json");
                        result = valid && ((code >= 200 && code < 300) || code == 401) ? "Онлайн" : "Ограничен";
                    } catch (Exception ex) { result = hasNetwork() ? "Ограничен" : "Оффлайн"; }
                    finally { if (connection != null) connection.disconnect(); }
                }
                final String next = result;
                ui.post(() -> {
                    if (isDestroyed() || !visible) return;
                    setNightwellStatus(next);
                    ui.removeCallbacks(nightwellProbe);
                    ui.postDelayed(nightwellProbe, 12000);
                });
            });
        }
    };
    private boolean hasNetwork() {
        android.net.ConnectivityManager manager =
            (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        if (manager == null) return false;
        if (Build.VERSION.SDK_INT >= 23) return manager.getActiveNetwork() != null;
        android.net.NetworkInfo info = manager.getActiveNetworkInfo();
        return info != null && info.isConnected();
    }
    private void setNightwellStatus(String value) {
        nightwellStatus = value;
        boolean connecting = value.equals("Загрузка…") || value.equals("Проверка…");
        int color = connecting ? 0xff67a8ff : value.equals("Онлайн") ? 0xff5fe7a3 :
                    value.equals("Ограничен") ? 0xffffc076 : 0xffa7abb7;
        if (nightwellBadge != null) {
            nightwellBadge.setText("●");
            nightwellBadge.setTextColor(color);
            nightwellBadge.setContentDescription("Подключение Nightwell: "+value);
        }
        if (nightwellMenuStatus != null) {
            nightwellMenuStatus.setText("●");
            nightwellMenuStatus.setTextColor(color);
            nightwellMenuStatus.setContentDescription("Подключение Nightwell: "+value);
            nightwellMenuStatus.setVisibility(connecting?View.GONE:View.VISIBLE);
        }
        if (nightwellMenuSpinner != null)
            nightwellMenuSpinner.setVisibility(connecting?View.VISIBLE:View.GONE);
    }
    private JSONObject liveRemote;
    private boolean liveOwner, liveBusy;
    private int liveRevision;
    private long liveLastPoll, liveLastWrite;
    private String liveDevice(){
        android.content.SharedPreferences prefs=getSharedPreferences("live-sync",MODE_PRIVATE);
        String value=prefs.getString("device","");
        if(!value.matches("[A-Za-z0-9_-]{8,100}")){
            value="android_"+java.util.UUID.randomUUID().toString().replace("-","");
            prefs.edit().putString("device",value).apply();
        }
        return value;
    }
    private void livePoll(){
        if(smokeMode||!sessionReady||user.isEmpty()||playback==null||liveBusy)return;
        long now=android.os.SystemClock.elapsedRealtime();
        if(now-liveLastPoll<4500)return;
        liveLastPoll=now;
        liveBusy=true;
        final String owner=user;
        io.execute(()->{
            try{
                JSONObject state=api.request("api/playback/state");
                ui.post(()->{
                    liveBusy=false;
                    if(isDestroyed()||!owner.equals(user))return;
                    liveRevision=state.optInt("revision");
                    boolean mine=liveDevice().equals(state.optString("device_id"));
                    if(liveOwner&&!mine&&playback!=null&&playback.player.isPlaying())playback.pause();
                    liveOwner=mine;
                    if(mine||state.optString("track_id").isEmpty())liveRemote=null;
                    else liveRemote=state;
                    refreshLiveHandoff();
                    if(liveOwner&&now-liveLastWrite>5000)publishLive(false);
                });
            }catch(Exception ex){ui.post(()->{liveBusy=false;});}
        });
    }
    private void refreshLiveHandoff(){
        boolean show=!user.isEmpty()&&liveRemote!=null&&
            !liveRemote.optString("track_id").isEmpty()&&!backgroundOnly;
        if(!show){
            handoffCollapsed=false;
            if(handoffCollapseTask!=null)ui.removeCallbacks(handoffCollapseTask);
            handoffCollapseTask=null;
        }else if(!handoffCollapsed&&handoffCollapseTask==null){
            handoffCollapseTask=()->{
                handoffCollapseTask=null;
                if(liveRemote==null||isDestroyed())return;
                handoffCollapsed=true;
                refreshLiveHandoff();
            };
            ui.postDelayed(handoffCollapseTask,8000);
        }
        if(liveHandoff!=null)liveHandoff.setVisibility(show&&!handoffCollapsed?View.VISIBLE:View.GONE);
        if(compactHandoff!=null)compactHandoff.setVisibility(show&&handoffCollapsed?View.VISIBLE:View.GONE);
    }
    private void publishLive(boolean takeover){
        if(smokeMode||liveBusy||user.isEmpty()||playback==null||(!takeover&&!liveOwner))return;
        JSONObject snapshot;
        try{snapshot=new JSONObject(playback.snapshot(true));}
        catch(Exception error){return;}
        JSONArray tracks=snapshot.optJSONArray("queueTracks");
        if(tracks==null)return;
        JSONArray ids=new JSONArray();
        for(int i=0;i<tracks.length()&&i<950;i++){
            JSONObject item=tracks.optJSONObject(i);
            if(item!=null&&!item.optBoolean("_offline"))ids.put(item.optString("id"));
        }
        String selected=snapshot.optString("id");
        if(selected.isEmpty())return;
        boolean found=false;
        for(int i=0;i<ids.length();i++)if(selected.equals(ids.optString(i))){found=true;break;}
        if(!found)return;
        liveBusy=true;
        final String owner=user;
        io.execute(()->{
            try{
                int revision=liveRevision;
                if(takeover)revision=api.request("api/playback/state").optInt("revision");
                JSONObject payload=new JSONObject()
                    .put("revision",revision).put("device_id",liveDevice())
                    .put("takeover",takeover).put("track_id",selected)
                    .put("queue",ids).put("position",Math.max(0,Math.min(86400,snapshot.optDouble("position"))))
                    .put("playing",snapshot.optBoolean("playing"))
                    .put("repeat",snapshot.optInt("repeat"))
                    .put("shuffle",snapshot.optBoolean("shuffle"))
                    .put("wave",snapshot.optBoolean("wave"));
                JSONObject response=api.request("api/playback/state","PUT",payload);
                ui.post(()->{
                    liveBusy=false;
                    if(isDestroyed()||!owner.equals(user))return;
                    liveRevision=response.optInt("revision");liveOwner=true;liveRemote=null;
                    liveLastWrite=android.os.SystemClock.elapsedRealtime();
                    refreshLiveHandoff();
                });
            }catch(Exception ex){ui.post(()->{liveBusy=false;liveOwner=false;});}
        });
    }
    private void continueLiveHere(){
        if(liveBusy||liveRemote==null||playback==null||user.isEmpty())return;
        final String owner=user;liveBusy=true;
        io.execute(()->{
            try{
                JSONObject remote=api.request("api/playback/state");
                if(remote.optString("track_id").isEmpty())throw new java.io.IOException("На другом устройстве нет трека");
                JSONObject library=api.request("api/playback/queue");
                JSONArray songs=library.optJSONArray("tracks");
                if(songs==null)throw new java.io.IOException("Очередь недоступна");
                String target=remote.optString("track_id");
                boolean found=false;
                for(int i=0;i<songs.length();i++){
                    JSONObject item=songs.optJSONObject(i);
                    if(item!=null&&target.equals(item.optString("id"))){found=true;break;}
                }
                if(!found)throw new java.io.IOException("Трек уже недоступен");
                JSONObject wanted=new JSONObject(remote.toString());
                wanted.put("revision",remote.optInt("revision"));
                wanted.put("device_id",liveDevice());wanted.put("takeover",true);
                JSONObject accepted=api.request("api/playback/state","PUT",wanted);
                ui.post(()->{
                    liveBusy=false;
                    if(isDestroyed()||!owner.equals(user)||playback==null)return;
                    try{
                        playback.prepare(new JSONObject()
                            .put("id",target).put("queue",songs).put("origin",origin)
                            .put("account",owner).put("wave",remote.optBoolean("wave"))
                            .put("wave_preferences",WaveSettings.read(this,origin,owner).json())
                            .put("position",Math.max(0,(long)(remote.optDouble("position")*1000))).toString());
                        playback.modes(remote.optInt("repeat"),remote.optBoolean("shuffle"));
                        if(remote.optBoolean("playing"))playback.play();
                        liveRevision=accepted.optInt("revision");liveOwner=true;
                        liveRemote=null;liveLastWrite=android.os.SystemClock.elapsedRealtime();
                        refreshLiveHandoff();updatePlayback();
                    }catch(Exception error){status.setText("Не удалось восстановить очередь");}
                });
            }catch(Exception ex){ui.post(()->{
                liveBusy=false;
                if(!isDestroyed()&&owner.equals(user))status.setText(friendly(ex));
            });}
        });
    }
    private TextView homeLyric;private JSONObject activeLyrics;private String homeLine="";private int homeWord=-2;
    private final java.util.ArrayList<Object> homeKineticSpans=new java.util.ArrayList<>();
    private final Runnable homeKineticTicker=new Runnable(){
        @Override public void run(){
            if(isDestroyed()||!visible)return;
            boolean playing=playback!=null&&playback.player.getPlayWhenReady();
            if(homeLyric!=null&&homeLyric.isAttachedToWindow()&&
                (screen.equals("Главная")||backgroundOnly)&&!full){
                syncHomeLyrics(playback.player.getCurrentPosition()/1000.0);
            }
            ui.postDelayed(this,playing?150:650);
        }
    };private boolean lastPlaying,mixing;private final java.util.ArrayDeque<String> mixRecent=new java.util.ArrayDeque<>();
    private NativeAPI api;
    private String supportUploadTicket="";private boolean supportUploadAdmin;
    private PlaybackService playback;
    private boolean bindingRegistered,visible,full,lyricsOpen,downloads,backgroundOnly;
    private String user="",screen="Главная",selectedPlaylist="",query="",currentID="",origin;
    private int trackTransitionDirection=1;
    private volatile int generation;
    private final LatestRequest waveRequest=new LatestRequest(),accountRequest=new LatestRequest();
    private JSONArray catalog=new JSONArray(),shown=new JSONArray(),playlists=new JSONArray(),queue=new JSONArray();
    private final Set<String> likes=new HashSet<>();
    private final java.util.LinkedHashMap<String,JSONArray> searchCache =
        new java.util.LinkedHashMap<String,JSONArray>(24,0.75f,true) {
            @Override protected boolean removeEldestEntry(java.util.Map.Entry<String,JSONArray> entry) {
                return size()>24;
            }
        };
    private LinearLayout root,body,dock,head,landscapeRail;
    private TextView status,miniTitle,miniArtist,miniPlay,miniPrev,miniNext,miniLike;
    private android.widget.ImageView miniCover;private android.graphics.drawable.ClipDrawable miniProgress;
    private ArtworkCache artworkCache;
    private TextView fullTime,homePlay,fullPlay,fullLike,fullDislike,fullAudioOutput,fullShuffle;
    private SeekBar seek;
    // Search glow renders behind the text and follows its true selection caret.
    // Its frame clock runs only while the input field has focus.
    private static final class WhiteSearchCaretGlow extends View {
        private final android.graphics.Paint paint = new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);
        private float caretX = 38f, destinationX = 38f;
        private boolean active;
        WhiteSearchCaretGlow(android.content.Context context){super(context);setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);}
        void follow(float x){destinationX=Math.max(0,x);if(active)invalidate();}
        void running(boolean enabled){active=enabled;caretX=destinationX;invalidate();}
        @Override protected void onDraw(android.graphics.Canvas canvas){
            super.onDraw(canvas);
            if(!active||getWidth()<=0||getHeight()<=0)return;
            // Fast easing makes the soft trailing highlight catch up to cursor
            // moves, including cursor taps and horizontal EditText scrolling.
            caretX+=(destinationX-caretX)*.36f;
            float radius=getResources().getDisplayMetrics().density*89f;
            float x=Math.max(0,Math.min(getWidth(),caretX)),y=getHeight()*.5f;
            float pulse=.89f+.11f*(float)Math.sin(android.os.SystemClock.uptimeMillis()*.014);
            paint.setShader(new android.graphics.RadialGradient(x,y,radius,
                new int[]{android.graphics.Color.argb((int)(112*pulse),255,255,255),0x26ffffff,0x00ffffff},
                new float[]{0f,.38f,1f},android.graphics.Shader.TileMode.CLAMP));
            canvas.drawCircle(x,y,radius,paint);
            paint.setShader(null);
            paint.setColor(android.graphics.Color.argb((int)(62*pulse),255,255,255));
            canvas.drawRoundRect(x-3*getResources().getDisplayMetrics().density,y-20*getResources().getDisplayMetrics().density,
                x+3*getResources().getDisplayMetrics().density,y+20*getResources().getDisplayMetrics().density,
                7*getResources().getDisplayMetrics().density,7*getResources().getDisplayMetrics().density,paint);
            postInvalidateDelayed(16);
        }
    }
    private static final class CursorAwareSearchField extends EditText {
        Runnable selectionUpdated;
        CursorAwareSearchField(android.content.Context context){super(context);}
        @Override protected void onSelectionChanged(int start,int end){
            super.onSelectionChanged(start,end);
            if(selectionUpdated!=null)post(selectionUpdated);
        }
    }
    private EditText search;
    private LinearLayout artistStrip;
    private TextView lyricsText;private android.widget.ScrollView lyricsScroll;private JSONArray lyricLines;
    private int activeLyric=-2,activeLyricWord=-2;
    private String lyricsTrack="",lyricLayoutTrack="";
    private final android.util.SparseArray<int[]> lyricRanges=new android.util.SparseArray<>();
    private final java.util.ArrayList<Object> lyricDynamicSpans=new java.util.ArrayList<>();
    private static final java.util.regex.Pattern KINETIC_TOKENS=java.util.regex.Pattern.compile("\\S+");
    private final Runnable lyricTicker=new Runnable(){
        @Override public void run(){
            if(lyricsText==null||playback==null)return;
            if(!visible){ui.postDelayed(this,450);return;}
            boolean playing=playback.player.getPlayWhenReady();
            if(playing)syncLyrics(playback.player.getCurrentPosition()/1000.0);
            ui.postDelayed(this,playing?160:450);
        }
    };
    private ListView list;
    private TrackAdapter adapter;
    private RibbonView ribbon;
    private HomeSparklesView atmosphere;
    private Runnable pendingSearch;
    private PopupWindow navigationPopup;
    private android.widget.ImageView profileAvatarButton;
    private android.graphics.Bitmap cachedProfileAvatar;
    private String cachedProfileUser="", cachedProfileNickname="";
    private static final int PLAYLIST_DOCUMENT = 633;
    private AlertDialog transferDialog;
    private EditText transferInput,transferTitle;
    private Spinner transferMode;
    private TextView transferNote;
    private int transferReadGeneration;
    private long libraryGeneration,lastResumeRefresh;
    private int connectionRecoveryAttempts;
    private final Runnable connectionRecovery=()->retryConnectionIfVisible();
    private void retryConnectionIfVisible(){if(visible&&!smokeMode&&!isDestroyed())load();}
    private String downloadProgress="";
    private String pendingDeepLinkTrack="";
    private boolean sessionReady,smokeMode;
    private void acceptDeepLink(Intent intent){
        if(intent==null||intent.getData()==null)return;
        Uri uri=intent.getData();String scheme=uri.getScheme(),host=uri.getHost(),id=null;
        if("https".equalsIgnoreCase(scheme)&&"music.nightwell.fun".equalsIgnoreCase(host)&&uri.getPathSegments().size()==2&&"track".equals(uri.getPathSegments().get(0)))id=uri.getPathSegments().get(1);
        else if("nightwell".equalsIgnoreCase(scheme)&&"track".equalsIgnoreCase(host)&&uri.getPathSegments().size()==1)id=uri.getPathSegments().get(0);
        if(id==null||!id.matches("[0-9a-fA-F]{32}"))return;
        pendingDeepLinkTrack=id;intent.setData(null);
        openPendingTrack();
    }
    private void openPendingTrack(){
        if(!sessionReady||pendingDeepLinkTrack.isEmpty()||api==null||catalog==null||playback==null)return;
        if(user.isEmpty()){auth();return;}
        final String id=pendingDeepLinkTrack;pendingDeepLinkTrack="";
        JSONObject selected=null;
        for(int i=0;i<catalog.length();i++){JSONObject t=catalog.optJSONObject(i);if(t!=null&&id.equalsIgnoreCase(t.optString("id"))){selected=t;break;}}
        if(selected!=null){play(selected,new JSONArray().put(selected),false);openPlayer();return;}
        task(()->api.request("api/shared-track/"+id),v->{
            JSONArray tracks=v.optJSONArray("tracks");if(tracks!=null)for(int i=0;i<tracks.length();i++){
                JSONObject track=tracks.optJSONObject(i);
                if(track!=null&&id.equalsIgnoreCase(track.optString("id"))){play(track,new JSONArray().put(track),false);openPlayer();return;}
            }
            status.setText("Трек по ссылке не найден");
        });
    }
    @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);acceptDeepLink(intent);}

    private long lastDownloadProgressPoll;
    private final Runnable tick=new Runnable(){
        @Override public void run(){
            premiumTick();
            updatePlayback();
            // Text and content descriptions are immutable until the audio
            // route actually changes. Don't invalidate this view every tick.
            if(fullAudioOutput!=null&&fullAudioOutput.isAttachedToWindow()){
                String output=audioOutputName();
                String label="♫  "+output+"  ⌄";
                if(!android.text.TextUtils.equals(fullAudioOutput.getText(),label)){
                    fullAudioOutput.setText(label);
                    fullAudioOutput.setContentDescription(
                        "Устройство вывода: "+output+". Изменить");
                }
            }
            // SharedPreferences.getAll() copies the entire background-download
            // index. No need to do it twice a second while music is playing.
            long now=android.os.SystemClock.elapsedRealtime();
            if(now-lastDownloadProgressPoll>=2500){
                lastDownloadProgressPoll=now;
                String next=BackgroundDownloads.progress(MainActivity.this);
                if(!next.equals(downloadProgress)){
                    downloadProgress=next;
                    if(status!=null)status.setText(next);
                }
            }
            if(visible){
                livePoll();
                ui.postDelayed(this,playback!=null&&playback.player.getPlayWhenReady()?500:1200);
            }
        }
    };
    private final androidx.media3.common.Player.Listener playbackIntentObserver=new androidx.media3.common.Player.Listener(){
        @Override public void onPlayWhenReadyChanged(boolean ready,int reason){if(!ready&&mixing)cancelMix();}
        @Override public void onMediaItemTransition(androidx.media3.common.MediaItem item,int reason){if(mixing)cancelMix();}
    };
    private final ServiceConnection connection=new ServiceConnection(){public void onServiceConnected(ComponentName n,IBinder b){playback=((PlaybackService.LocalBinder)b).getService();playback.player.addListener(playbackIntentObserver);if(!smokeMode&&pendingDeepLinkTrack.isEmpty())playback.restorePlayback(origin,user);updatePlayback();openPendingTrack();}public void onServiceDisconnected(ComponentName n){playback=null;}};
    @Override public void onCreate(Bundle saved){super.onCreate(saved);if(!getSharedPreferences("nw-first-run",MODE_PRIVATE).getBoolean("done-v1",false)&&!getIntent().getBooleanExtra("nativeSmoke",false)&&getIntent().getData()==null){redirectedToFirstRun=true;startActivity(new Intent(this,FirstRunActivity.class));finish();return;}ArtistTaste.load(this);artworkCache=new ArtworkCache(this);smokeMode=(getApplicationInfo().flags&android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)!=0&&getIntent().getBooleanExtra("nativeSmoke",false);origin="https://music.nightwell.fun/";user=getSharedPreferences("native-api",MODE_PRIVATE).getString("account","");api=new NativeAPI(this,origin);restoreRecent();if(!smokeMode&&!user.isEmpty())restoreLibrarySnapshot(user);if(Build.VERSION.SDK_INT>=30)getWindow().setDecorFitsSystemWindows(false);else getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE|View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN|View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);if(Build.VERSION.SDK_INT>=28){WindowManager.LayoutParams windowParams=getWindow().getAttributes();windowParams.layoutInDisplayCutoutMode=WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;getWindow().setAttributes(windowParams);}getWindow().setStatusBarColor(Color.TRANSPARENT);getWindow().setNavigationBarColor(Color.TRANSPARENT);if(Build.VERSION.SDK_INT>=29)getWindow().setNavigationBarContrastEnforced(false);getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);bindingRegistered=bindService(new Intent(this,PlaybackService.class).setAction("nightwell.local"),connection,BIND_AUTO_CREATE);build();if(smokeMode){smokeFixture(getIntent().getStringExtra("screen"));}else{acceptDeepLink(getIntent());load();}
        if(saved!=null&&saved.getBoolean("transfer.open",false)){nativeTransfer();transferTitle.setText(saved.getString("transfer.title","Перенос музыки"));transferInput.setText(getSharedPreferences("transfer-draft",MODE_PRIVATE).getString("text",""));transferMode.setSelection(saved.getInt("transfer.mode",2));}
    }
    @Override public void onConfigurationChanged(android.content.res.Configuration config){
        super.onConfigurationChanged(config);
        if(redirectedToFirstRun||root==null)return;
        boolean wasFull=full;
        // Rebuild only the views. The playback service and current queue survive.
        build();
        if(wasFull&&current()!=null)openPlayer();
    }
    @Override protected void onSaveInstanceState(Bundle saved){
        if(transferDialog!=null&&transferDialog.isShowing()){
            saved.putBoolean("transfer.open",true);saved.putString("transfer.title",transferTitle.getText().toString());saved.putInt("transfer.mode",transferMode.getSelectedItemPosition());
            // Keep a potentially 1 MB document out of the Activity/Binder state bundle.
            getSharedPreferences("transfer-draft",MODE_PRIVATE).edit().putString("text",transferInput.getText().toString()).apply();
        }
        super.onSaveInstanceState(saved);
    }

    @Override protected void onResume(){super.onResume();if(redirectedToFirstRun)return;restoreRecent();visible=true;ui.removeCallbacks(nightwellProbe);ui.post(nightwellProbe);if(!smokeMode&&sessionReady&&SystemClock.elapsedRealtime()-lastResumeRefresh>30000)load();if(premiumRefresh!=null)premiumRefresh.run();BackgroundDownloads.reconcile(this);if(ribbon!=null)ribbon.running(!smokeMode&&!full&&screen.equals("Главная"));ui.removeCallbacks(tick);if(!smokeMode)ui.post(tick);ui.removeCallbacks(homeKineticTicker);if(!smokeMode)ui.post(homeKineticTicker);}
    @Override protected void onPause(){super.onPause();if(redirectedToFirstRun)return;ui.removeCallbacks(nightwellProbe);ui.removeCallbacks(connectionRecovery);if(navigationPopup!=null)navigationPopup.dismiss();if(playback!=null)playback.persistPlayback(true);visible=false;if(ribbon!=null)ribbon.running(false);ui.removeCallbacks(tick);ui.removeCallbacks(homeKineticTicker);}
    @Override protected void onDestroy(){if(redirectedToFirstRun){super.onDestroy();return;}ui.removeCallbacks(nightwellProbe);generation++;cancelMix();accountRequest.cancel();if(api!=null)api.close();ui.removeCallbacksAndMessages(null);if(artworkCache!=null)artworkCache.close();io.shutdownNow();waveIO.shutdownNow();prefetch.shutdownNow();playlistIndexer.shutdownNow();if(playback!=null)playback.player.removeListener(playbackIntentObserver);if(bindingRegistered){unbindService(connection);bindingRegistered=false;}super.onDestroy();}
    int dp(float n){return (int)(n*getResources().getDisplayMetrics().density+.5f);}
    boolean isLandscapeLayout(){
        android.content.res.Configuration c=getResources().getConfiguration();
        return c.orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE
            && c.screenHeightDp<650;
    }
    private void addLandscapeTab(String glyph,String label,String destination){
        TextView button=iconButton(glyph,()->navigate(destination));
        button.setContentDescription(label);
        button.setTextSize(21);
        button.setPadding(0,0,0,0);
        button.setBackground(touchSurface(screen.equals(destination)?0x662d303b:0x2220232b,14));
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(dp(46),dp(42));
        params.bottomMargin=dp(4);
        landscapeRail.addView(button,params);
    }
    LinearLayout column(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    TextView text(String label,int size){TextView v=new TextView(this);v.setText(label);v.setTextSize(size);v.setTextColor(0xfff3f3f5);v.setFontFeatureSettings("kern");v.setIncludeFontPadding(false);v.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_HIGH_QUALITY);v.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NORMAL);return v;}
    // One visual system. Dark enough to prevent the underlying player text
    // shining through dialogs, with soft lighting rather than outlined boxes.
    GradientDrawable glass(int corners){
        GradientDrawable d=new GradientDrawable(GradientDrawable.Orientation.TL_BR,
            new int[]{0xff303237,0xff1c1e23,0xff121317});
        d.setCornerRadius(dp(corners));d.setStroke(dp(1),0x36ffffff);
        return d;
    }
    GradientDrawable surface(){return glass(30);}
    GradientDrawable fieldSurface(int color,int corners){
        GradientDrawable fill=new GradientDrawable(GradientDrawable.Orientation.TL_BR,
            new int[]{0xff292b30,0xff202126});
        fill.setCornerRadius(dp(corners));fill.setStroke(dp(1),0x24ffffff);return fill;
    }
    android.graphics.drawable.Drawable touchSurface(int color,int corners){GradientDrawable fill=fieldSurface(color,corners);GradientDrawable mask=new GradientDrawable();mask.setColor(Color.WHITE);mask.setCornerRadius(dp(corners));return new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x30ffffff),fill,mask);}
    TextView sectionLabel(String label){TextView v=text(label.toUpperCase(java.util.Locale.ROOT),11);v.setLetterSpacing(.095f);v.setTextColor(0xffadb0b8);v.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));v.setPadding(dp(5),dp(12),dp(5),dp(7));return v;}
    void styleField(EditText view){view.setTextColor(0xfff4f4f7);view.setHintTextColor(0xff8f95a5);view.setTextSize(15);view.setMinHeight(dp(50));view.setBackground(fieldSurface(0x88262a33,16));view.setPadding(dp(14),dp(10),dp(14),dp(10));}
    void styleSwitch(android.widget.Switch view){view.setTextColor(0xfff0f1f6);view.setTextSize(15);view.setPadding(dp(2),dp(10),dp(2),dp(10));}
    void styleSheet(AlertDialog dialog){
        dialog.setOnShowListener(ignored->{
            Window window=dialog.getWindow();
            if(window==null)return;
            window.setBackgroundDrawable(surface());
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams params=window.getAttributes();
            params.dimAmount=.76f;
            window.setAttributes(params);
            int width=Math.min(dp(isLandscapeLayout()?650:480),
                getResources().getDisplayMetrics().widthPixels-dp(isLandscapeLayout()?22:28));
            window.setLayout(width,WindowManager.LayoutParams.WRAP_CONTENT);
            View decor=window.getDecorView();
            decor.setPadding(dp(7),dp(7),dp(7),dp(10));
            decor.post(()->{
                int limit=getResources().getDisplayMetrics().heightPixels-
                    dp(isLandscapeLayout()?24:54);
                if(decor.getHeight()>limit)window.setLayout(width,limit);
            });
            for(int which:new int[]{AlertDialog.BUTTON_POSITIVE,
                    AlertDialog.BUTTON_NEGATIVE,AlertDialog.BUTTON_NEUTRAL}){
                Button button=dialog.getButton(which);
                if(button==null)continue;
                button.setAllCaps(false);
                button.setTextSize(14);
                button.setTextColor(which==AlertDialog.BUTTON_NEGATIVE?
                    0xffb6bac7:0xffeeeeee);
                button.setMinHeight(dp(44));
            }
            if(android.animation.ValueAnimator.areAnimatorsEnabled()){
                decor.setAlpha(0f);
                decor.setScaleX(.97f);decor.setScaleY(.97f);
                decor.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(200)
                    .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
            }
        });
    }
    // Use a wide bottom sheet for the major navigation screens; keep generic
    // one-off confirmation dialogs as small floating windows.
    void styleNavigationSheet(AlertDialog dialog){
        dialog.setOnShowListener(ignored->{
            Window window=dialog.getWindow();
            if(window==null)return;
            window.setBackgroundDrawable(surface());
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams attrs=window.getAttributes();
            attrs.gravity=Gravity.BOTTOM;
            attrs.dimAmount=.80f;
            window.setAttributes(attrs);
            int width=getResources().getDisplayMetrics().widthPixels-
                dp(isLandscapeLayout()?30:16);
            int maxHeight=(int)(getResources().getDisplayMetrics().heightPixels*
                (isLandscapeLayout()?.91f:.83f));
            window.setLayout(width,WindowManager.LayoutParams.WRAP_CONTENT);
            View decor=window.getDecorView();
            decor.setPadding(dp(6),dp(5),dp(6),dp(9));
            decor.post(()->{
                if(decor.getHeight()>maxHeight)window.setLayout(width,maxHeight);
            });
            window.setNavigationBarColor(0xff0d0e11);
            for(int which:new int[]{AlertDialog.BUTTON_POSITIVE,AlertDialog.BUTTON_NEGATIVE}){
                Button button=dialog.getButton(which);
                if(button==null)continue;
                button.setAllCaps(false);
                button.setTextSize(14);
                button.setTextColor(0xfff1f2f5);
                button.setBackground(touchSurface(0xff33353b,14));
                button.setPadding(dp(14),dp(9),dp(14),dp(9));
            }
            if(android.animation.ValueAnimator.areAnimatorsEnabled()){
                decor.setAlpha(0f);decor.setTranslationY(dp(15));
                decor.animate().alpha(1f).translationY(0f).setDuration(240)
                    .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
            }
        });
    }

    // Wrap each logical setting in a quiet surface instead of stacking a
    // wall of loose controls, hints and sliders.
    void arrangeSettingsControls(LinearLayout panel){
        java.util.List<View> old=new java.util.ArrayList<>();
        for(int i=0;i<panel.getChildCount();i++)old.add(panel.getChildAt(i));
        panel.removeAllViews();
        for(int i=0;i<old.size();i++){
            View v=old.get(i);
            LinearLayout card=column();
            card.setPadding(dp(12),dp(9),dp(12),dp(9));card.setBackground(fieldSurface(0xff26282d,16));
            card.addView(v,new LinearLayout.LayoutParams(-1,-2));
            if(i+1<old.size()){
                View next=old.get(i+1);
                boolean hint=next instanceof TextView &&
                    ((TextView)next).getTextSize()/getResources().getDisplayMetrics().scaledDensity<14 &&
                    !(v instanceof TextView && ((TextView)v).getTextSize()/getResources().getDisplayMetrics().scaledDensity<14);
                boolean seek=next instanceof SeekBar && v instanceof TextView;
                if(hint||seek){
                    i++;
                    LinearLayout.LayoutParams child=new LinearLayout.LayoutParams(-1,-2);
                    child.topMargin=dp(5);
                    card.addView(next,child);
                }
            }
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);
            lp.bottomMargin=dp(8);panel.addView(card,lp);
        }
    }

    TextView sheetAction(String label,Runnable run){TextView v=action(label,run);v.setTextSize(14);v.setMaxLines(2);v.setEllipsize(android.text.TextUtils.TruncateAt.END);v.setGravity(Gravity.CENTER_VERTICAL);v.setTextColor(0xfff4f4f6);v.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));v.setPadding(dp(14),dp(10),dp(14),dp(10));v.setMinHeight(dp(46));v.setBackground(touchSurface(0xff292b30,15));return v;}
    TextView action(String label,Runnable run){TextView v=NativeIconButton.isIcon(label)?new NativeIconButton(this):text(label,16);v.setText(label);v.setTextColor(0xfff3f3f5);v.setTextSize(NativeIconButton.isIcon(label)?20:16);if(NativeIconButton.isIcon(label))v.setContentDescription(iconLabel(label));v.setGravity(Gravity.CENTER);v.setPadding(dp(12),dp(9),dp(12),dp(9));v.setMinHeight(dp(48));v.setOnClickListener(x->run.run());return v;}
    TextView iconButton(String label,Runnable run){TextView v=action(label,run);v.setPadding(0,0,0,0);v.setTextSize(19);v.setTextColor(0xfff1f1f6);v.setBackground(touchSurface(0xa52b2e34,16));return v;}
    void toggleBackgroundOnly(){backgroundOnly=!backgroundOnly;build();}
    private int depthQueuePage = 0;

    void showQueue(){
        int current=playback==null?-1:playback.player.getCurrentMediaItemIndex();
        depthQueuePage=queue.length()==0?0:Math.min(queue.length()-1,Math.max(0,current+1));
        boolean depth=getSharedPreferences("appearance",MODE_PRIVATE)
            .getBoolean("nw-depth-queue",true);
        if(depth){showDepthQueue();return;}
        ScrollView scroll=new ScrollView(this);
        scroll.setFillViewport(false);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout entries=column();
        entries.setPadding(dp(15),dp(7),dp(15),dp(12));
        scroll.addView(entries);
        int currentIndex=Math.max(0,current);
        int from=Math.max(0,currentIndex-35);
        int to=Math.min(queue.length(),Math.max(currentIndex+85,75));
        if(queue.length()==0){
            TextView empty=text("В очереди пока нет треков",15);
            empty.setGravity(Gravity.CENTER);
            empty.setTextColor(0xffbec0c8);
            empty.setPadding(dp(12),dp(30),dp(12),dp(30));
            entries.addView(empty);
        }
        final View[] focused={null};
        for(int i=from;i<to;i++){
            JSONObject track=queue.optJSONObject(i);
            if(track==null)continue;
            boolean playing=i==current;
            if(i==from||i==current||i==current+1){
                String section=i==current?"СЕЙЧАС ИГРАЕТ":i==current+1?"ДАЛЕЕ":"РАНЕЕ";
                TextView caption=sectionLabel(section);
                caption.setTextColor(playing?0xfffafafa:0xffa2a6af);
                LinearLayout.LayoutParams cp=new LinearLayout.LayoutParams(-1,-2);
                cp.topMargin=dp(i==from?0:12);
                cp.bottomMargin=dp(5);
                entries.addView(caption,cp);
            }
            LinearLayout line=row();
            line.setPadding(dp(10),dp(7),dp(10),dp(7));
            line.setBackground(touchSurface(playing?0xff373940:0xff24262b,17));
            TextView index=text(playing?"♫":String.valueOf(i+1),12);
            index.setTextColor(playing?0xfff6f6f8:0xff999da8);
            index.setGravity(Gravity.CENTER);
            line.addView(index,new LinearLayout.LayoutParams(dp(25),dp(44)));
            ImageView artwork=new ImageView(this);
            artwork.setScaleType(ImageView.ScaleType.CENTER_CROP);
            GradientDrawable shape=new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0xff4c5057,0xff1f2127});
            shape.setCornerRadius(dp(9));
            artwork.setBackground(shape);
            artwork.setClipToOutline(true);
            LinearLayout.LayoutParams imageParams=new LinearLayout.LayoutParams(dp(44),dp(44));
            imageParams.leftMargin=dp(6);
            line.addView(artwork,imageParams);
            if(artworkCache!=null)artworkCache.load(artwork,origin,track.optString("cover_url"));
            LinearLayout names=column();
            names.setGravity(Gravity.CENTER_VERTICAL);
            names.setPadding(dp(12),0,0,0);
            TextView title=text(track.optString("title","Без названия"),14);
            title.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
            title.setMaxLines(1);
            title.setEllipsize(android.text.TextUtils.TruncateAt.END);
            TextView artist=text(track.optString("artist","Nightwell Music"),12);
            artist.setTextColor(playing?0xffccd0d9:0xff989ca6);
            artist.setMaxLines(1);
            artist.setEllipsize(android.text.TextUtils.TruncateAt.END);
            artist.setPadding(0,dp(4),0,0);
            names.addView(title);
            names.addView(artist);
            line.addView(names,new LinearLayout.LayoutParams(0,-2,1));
            TextView chevron=text(playing?"▮▮":"›",18);
            chevron.setTextColor(playing?0xfff5f5f7:0xff737781);
            chevron.setGravity(Gravity.CENTER);
            line.addView(chevron,new LinearLayout.LayoutParams(dp(26),dp(44)));
            final JSONObject selected=track;
            line.setOnClickListener(view->play(selected,queue,false));
            LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,dp(62));
            params.bottomMargin=dp(6);
            entries.addView(line,params);
            if(playing)focused[0]=line;
        }
        AlertDialog dialog=new AlertDialog.Builder(this)
            .setTitle("Очередь воспроизведения")
            .setView(scroll)
            .setPositiveButton("Готово",null).create();
        styleNavigationSheet(dialog);
        dialog.show();
        if(focused[0]!=null)scroll.post(()->scroll.scrollTo(0,
            Math.max(0,focused[0].getTop()-dp(140))));
    }
    void reorderUpcoming(int from,int to){
        if(playback==null)return;
        playback.moveUpcomingTrack(from,to);
        try{queue=new JSONObject(playback.snapshot(true)).optJSONArray("queueTracks");}
        catch(Exception ignored){}
        if(queue==null)queue=new JSONArray();
        updatePlayback();
    }
    // Visible confirmation without interrupting the current song.
    void depthQueueFeedback(android.view.View card,String message){
        card.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY);
        android.widget.Toast.makeText(this,message,android.widget.Toast.LENGTH_SHORT).show();
        final float sx=card.getScaleX(),sy=card.getScaleY();
        card.animate().scaleX(sx+0.045f).scaleY(sy+0.045f).setDuration(120)
            .withEndAction(()->card.animate().scaleX(sx).scaleY(sy).setDuration(160).start()).start();
    }

    // A single in-place carousel. Page changes never recreate the dialog.
    // Previously switching between cards closed and reopened AlertDialog, which
    // looked like flickering and lost swipe/long-press gesture continuity.
    void showDepthQueue(){
        final int playing=playback==null?-1:playback.player.getCurrentMediaItemIndex();
        final int total=queue==null?0:queue.length();
        depthQueuePage=total==0?0:Math.min(total-1,Math.max(0,depthQueuePage));
        final boolean motion=android.animation.ValueAnimator.areAnimatorsEnabled();
        final android.content.res.Configuration configuration=getResources().getConfiguration();
        final boolean landscape=isLandscapeLayout();

        LinearLayout panel=column();
        panel.setPadding(dp(14),dp(14),dp(14),dp(12));
        ScrollView scroll=new ScrollView(this);
        scroll.setFillViewport(false);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(panel);
        TextView eyebrow=text("Т В О Я   М У З Ы К А",10);
        eyebrow.setLetterSpacing(.1f);
        eyebrow.setTextColor(0xffaeb1bb);
        panel.addView(eyebrow);

        LinearLayout heading=row();
        heading.setPadding(0,dp(4),0,dp(10));
        TextView headingTitle=text("Объёмная очередь",22);
        headingTitle.setTypeface(android.graphics.Typeface.create("sans-serif",android.graphics.Typeface.BOLD));
        headingTitle.setSingleLine(true);
        headingTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);
        heading.addView(headingTitle,new LinearLayout.LayoutParams(0,dp(42),1));
        TextView close=iconButton("×",()->{});
        close.setContentDescription("Закрыть очередь");
        close.setBackground(touchSurface(0xff303238,15));
        heading.addView(close,new LinearLayout.LayoutParams(dp(43),dp(43)));
        panel.addView(heading);

        int maxWidth=Math.max(190,configuration.screenWidthDp-(landscape?140:80));
        final int cardWidthDp=Math.min(280,maxWidth);
        final int cardHeightDp=Math.min(Math.round(cardWidthDp*1.08f),
            Math.max(180,Math.round(configuration.screenHeightDp*(landscape?.56f:.50f))));
        final FrameLayout deck=new FrameLayout(this);
        deck.setClipChildren(false);
        deck.setClipToPadding(false);
        panel.addView(deck,new LinearLayout.LayoutParams(-1,dp(cardHeightDp+33)));

        final LinearLayout pager=row();
        pager.setGravity(Gravity.CENTER_VERTICAL);
        pager.setPadding(dp(4),dp(4),dp(4),dp(3));
        TextView previous=iconButton("‹",()->{});
        previous.setContentDescription("Предыдущая карточка в очереди");
        TextView counter=text("",13);
        counter.setGravity(Gravity.CENTER);
        counter.setTextColor(0xffc8cbd2);
        TextView next=iconButton("›",()->{});
        next.setContentDescription("Следующая карточка в очереди");
        pager.addView(previous,new LinearLayout.LayoutParams(dp(46),dp(44)));
        pager.addView(counter,new LinearLayout.LayoutParams(0,dp(44),1));
        pager.addView(next,new LinearLayout.LayoutParams(dp(46),dp(44)));
        panel.addView(pager);

        TextView help=text("Нажатие: воспроизвести   ·   Удержание: следующим\nЛистай влево и вправо, чтобы увидеть всю очередь",11);
        help.setGravity(Gravity.CENTER);
        help.setMaxLines(3);
        help.setLineSpacing(dp(2),1f);
        help.setTextColor(0xffadb1bb);
        help.setPadding(dp(3),dp(10),dp(3),dp(3));
        panel.addView(help);

        AlertDialog dialog=new AlertDialog.Builder(this).setView(scroll).create();
        close.setOnClickListener(v->dialog.dismiss());

        final Runnable[] render=new Runnable[1];
        final boolean[] transitioning={false};
        final java.util.function.IntConsumer changePage=direction->{
            int nextPosition=Math.max(0,Math.min(total-1,depthQueuePage+direction));
            if(total==0||nextPosition==depthQueuePage||transitioning[0])return;
            transitioning[0]=true;
            depthQueuePage=nextPosition;
            if(!motion){
                render[0].run();
                transitioning[0]=false;
                return;
            }
            deck.animate().cancel();
            deck.animate().alpha(.25f).translationX(dp(-direction*24))
                .setDuration(125).withEndAction(()->{
                    if(!dialog.isShowing()){transitioning[0]=false;return;}
                    deck.setTranslationX(dp(direction*26));
                    render[0].run();
                    deck.animate().alpha(1f).translationX(0f)
                        .setDuration(225)
                        .setInterpolator(new android.view.animation.DecelerateInterpolator())
                        .withEndAction(()->transitioning[0]=false).start();
                }).start();
        };
        previous.setOnClickListener(v->changePage.accept(-1));
        next.setOnClickListener(v->changePage.accept(1));
        render[0]=()->{
            deck.removeAllViews();
            deck.setClipChildren(false);
            counter.setText(total==0?"Очередь пуста":(depthQueuePage+1)+" / "+total);
            previous.setEnabled(total>0&&depthQueuePage>0);
            next.setEnabled(total>0&&depthQueuePage<total-1);
            previous.setAlpha(previous.isEnabled()?1f:.28f);
            next.setAlpha(next.isEnabled()?1f:.28f);
            if(total==0){
                TextView empty=text("Добавь музыку, чтобы появилась очередь",14);
                empty.setTextColor(0xffc5c7d0);
                empty.setGravity(Gravity.CENTER);
                deck.addView(empty,new FrameLayout.LayoutParams(-1,-1));
                return;
            }
            int available=Math.min(3,total-depthQueuePage);
            for(int rank=available-1;rank>=0;rank--){
                final int position=depthQueuePage+rank;
                final JSONObject track=queue.optJSONObject(position);
                if(track==null)continue;
                final FrameLayout card=new FrameLayout(this);
                card.setClickable(rank==0);
                card.setFocusable(rank==0);
                card.setContentDescription(
                    (position<playing?"Ранее. ":position==playing?"Сейчас играет. ":"Далее. ")+
                    track.optString("title")+", "+track.optString("artist")+
                    ". Нажми для воспроизведения, удерживай чтобы поставить следующим");
                GradientDrawable plate=new GradientDrawable();
                plate.setColor(0xff17181d);
                plate.setCornerRadius(dp(18));
                plate.setStroke(dp(1),rank==0?0x77ffffff:0x2cffffff);
                card.setBackground(plate);
                card.setClipToOutline(true);
                card.setElevation(dp(8+available-rank*2));

                ImageView artwork=new ImageView(this);
                artwork.setScaleType(ImageView.ScaleType.CENTER_CROP);
                FrameLayout.LayoutParams coverLayout=new FrameLayout.LayoutParams(
                    -1,dp(cardHeightDp-72),Gravity.TOP);
                card.addView(artwork,coverLayout);
                String coverPath=track.optString("cover_url");
                if(coverPath.isEmpty())coverPath="/api/covers/"+track.optString("id");
                if(artworkCache!=null)artworkCache.load(artwork,origin,coverPath);

                TextView section=text(position<playing?"РАНЕЕ":
                    position==playing?"СЕЙЧАС ИГРАЕТ":"ДАЛЕЕ",10);
                section.setTextColor(0xfff4f5f7);
                section.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
                section.setPadding(dp(10),dp(6),dp(10),dp(6));
                section.setBackground(touchSurface(0xff282a2f,13));
                FrameLayout.LayoutParams labelParams=new FrameLayout.LayoutParams(
                    -2,-2,Gravity.TOP|Gravity.START);
                labelParams.leftMargin=dp(11);labelParams.topMargin=dp(11);
                card.addView(section,labelParams);

                LinearLayout description=column();
                description.setGravity(Gravity.CENTER_VERTICAL);
                description.setPadding(dp(13),dp(9),dp(13),dp(9));
                description.setBackgroundColor(0xff191a1e);
                TextView title=text(track.optString("title","Без названия"),15);
                title.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
                title.setMaxLines(1);
                title.setEllipsize(android.text.TextUtils.TruncateAt.END);
                description.addView(title);
                TextView artist=text(track.optString("artist","Nightwell Music"),12);
                artist.setTextColor(0xffaaadb7);
                artist.setMaxLines(1);
                artist.setEllipsize(android.text.TextUtils.TruncateAt.END);
                artist.setPadding(0,dp(4),0,0);
                description.addView(artist);
                card.addView(description,new FrameLayout.LayoutParams(
                    -1,dp(72),Gravity.BOTTOM));

                FrameLayout.LayoutParams layout=new FrameLayout.LayoutParams(
                    dp(cardWidthDp),dp(cardHeightDp),Gravity.CENTER_HORIZONTAL|Gravity.TOP);
                layout.topMargin=dp(6);
                deck.addView(card,layout);
                float targetScale=1f-rank*.055f;
                float targetY=dp(rank*12);
                float targetX=dp(rank*11);
                float yaw=rank*5.8f;
                card.setCameraDistance(dp(3500));
                card.setPivotX(dp(cardWidthDp)/2f);
                card.setPivotY(dp(cardHeightDp)/2f);
                card.setTranslationX(targetX);
                card.setRotationX(rank*1.4f);
                card.setRotationY(yaw);
                if(motion){
                    card.setAlpha(0f);
                    card.setScaleX(targetScale*.94f);
                    card.setScaleY(targetScale*.94f);
                    card.setTranslationY(targetY+dp(15));
                    card.animate().alpha(1f).scaleX(targetScale).scaleY(targetScale)
                        .translationY(targetY).setStartDelay((available-1-rank)*38L)
                        .setDuration(265)
                        .setInterpolator(new android.view.animation.DecelerateInterpolator())
                        .start();
                }else{
                    card.setAlpha(1f);card.setScaleX(targetScale);
                    card.setScaleY(targetScale);card.setTranslationY(targetY);
                }

                if(rank!=0)continue;
                Runnable playCard=()->{
                    if(dialog.isShowing())dialog.dismiss();
                    if(position==playing)depthQueueFeedback(card,"Уже играет");
                    else play(track,queue,false);
                };
                Runnable playNext=()->{
                    if(position<=playing+1){
                        depthQueueFeedback(card,position<playing?
                            "Этот трек уже звучал":position==playing?
                            "Сейчас играет":"Уже следующий в очереди");
                        return;
                    }
                    reorderUpcoming(position,playing+1);
                    depthQueueFeedback(card,"Добавлено следующим");
                    depthQueuePage=Math.min(queue.length()-1,Math.max(0,playing+1));
                    render[0].run();
                };
                card.setOnClickListener(v->playCard.run());
                card.setOnLongClickListener(v->{playNext.run();return true;});
                android.view.GestureDetector gestures=new android.view.GestureDetector(
                    this,new android.view.GestureDetector.SimpleOnGestureListener(){
                        @Override public boolean onDown(MotionEvent event){return true;}
                        @Override public boolean onSingleTapUp(MotionEvent event){
                            card.performClick();return true;
                        }
                        @Override public void onLongPress(MotionEvent event){
                            card.performLongClick();
                        }
                        @Override public boolean onFling(MotionEvent first,MotionEvent last,
                            float velocityX,float velocityY){
                            if(first==null||last==null)return false;
                            float dx=last.getX()-first.getX();
                            if(Math.abs(dx)<dp(48)||
                                Math.abs(dx)<Math.abs(last.getY()-first.getY())*1.2f||
                                Math.abs(velocityX)<dp(140))return false;
                            changePage.accept(dx<0?1:-1);
                            return true;
                        }
                    });
                card.setOnTouchListener((v,event)->gestures.onTouchEvent(event));
            }
        };
        styleSheet(dialog);
        dialog.show();
        render[0].run();
    }

    void build(){
        if(ribbon!=null)ribbon.running(false);full=false;lyricsOpen=false;seek=null;fullTime=null;fullPlay=null;fullLike=null;fullDislike=null;fullAudioOutput=null;
        // Render scenery and aura across the window, outside the padded controls.
        android.widget.FrameLayout scene=new android.widget.FrameLayout(this);
        scene.setBackground(new NativeSceneryDrawable(this));
        atmosphere=new HomeSparklesView(this);scene.addView(atmosphere,new android.widget.FrameLayout.LayoutParams(-1,-1));
        ribbon=new RibbonView(this);ui.post(this::applyPremium);ribbon.meter(()->playback==null?0:playback.level());ribbon.bands(index->playback==null?0:playback.bandLevel(index));
        ribbon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        scene.addView(ribbon,new android.widget.FrameLayout.LayoutParams(-1,-1));
        boolean landscape=isLandscapeLayout();
        root=column();root.setPadding(dp(landscape?10:16),dp(landscape?5:9),dp(landscape?10:16),0);
        scene.addView(root,new android.widget.FrameLayout.LayoutParams(-1,-1));setContentView(scene);
        root.setOnApplyWindowInsetsListener((v,insets)->{int top,bottom;if(Build.VERSION.SDK_INT>=30){android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());top=bars.top;bottom=Math.max(bars.bottom,insets.getInsets(WindowInsets.Type.ime()).bottom);}else{top=insets.getSystemWindowInsetTop();bottom=insets.getSystemWindowInsetBottom();}v.setPadding(dp(isLandscapeLayout()?10:16),dp(isLandscapeLayout()?5:9)+top,dp(isLandscapeLayout()?10:16),bottom);return insets;});root.requestApplyInsets();
        head=row();android.widget.ImageView brand=new android.widget.ImageView(this);brand.setImageResource(R.drawable.nightwell_mark);brand.setScaleType(android.widget.ImageView.ScaleType.FIT_CENTER);brand.setOnClickListener(v->navigate("Главная"));head.addView(brand,new LinearLayout.LayoutParams(dp(42),dp(42)));LinearLayout wordmark=column();wordmark.setGravity(Gravity.CENTER_VERTICAL);wordmark.setPadding(dp(9),0,0,0);
        TextView brandName=text("Nightwell",27);brandName.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);brandName.setTextColor(0xfff3f3f5);brandName.setIncludeFontPadding(false);brandName.setSingleLine(true);brandName.setAutoSizeTextTypeUniformWithConfiguration(20,27,1,android.util.TypedValue.COMPLEX_UNIT_SP);
        wordmark.addView(brandName,new LinearLayout.LayoutParams(-1,dp(landscape?27:33)));
        TextView brandCaption=text("M U S I C",12);brandCaption.setIncludeFontPadding(false);brandCaption.setSingleLine(true);brandCaption.setTextColor(0xff92959f);LinearLayout.LayoutParams captionParams=new LinearLayout.LayoutParams(-1,-2);captionParams.topMargin=dp(1);wordmark.addView(brandCaption,captionParams);
        wordmark.setOnClickListener(v->navigate("Главная"));wordmark.setContentDescription("Nightwell Music, на главный экран");head.addView(wordmark,new LinearLayout.LayoutParams(0,-2,1));if(landscape){brandName.setTextSize(20);brandCaption.setTextSize(9);}TextView searchButton=iconButton("⌕",()->navigate("Поиск"));searchButton.setBackground(touchSurface(0x40202228,24));head.addView(searchButton,new LinearLayout.LayoutParams(dp(48),dp(48)));
        compactHandoff=iconButton("⇄",this::continueLiveHere);
        compactHandoff.setContentDescription("Продолжить на этом устройстве");
        compactHandoff.setVisibility(View.GONE);
        head.addView(compactHandoff,new LinearLayout.LayoutParams(dp(44),dp(48)));
        android.widget.ImageView menuButton=new android.widget.ImageView(this);menuButton.setImageResource(android.R.drawable.ic_menu_myplaces);menuButton.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);menuButton.setPadding(dp(8),dp(8),dp(8),dp(8));menuButton.setBackground(touchSurface(0x40202228,24));menuButton.setOnClickListener(v->menu());menuButton.setContentDescription("Меню профиля");profileAvatarButton=menuButton;
        head.setLayoutTransition(new android.animation.LayoutTransition());
        head.addView(menuButton,new LinearLayout.LayoutParams(dp(48),dp(48)));refreshProfileAvatar();LinearLayout.LayoutParams headerParams=new LinearLayout.LayoutParams(-1,dp(landscape?52:58));headerParams.bottomMargin=dp(landscape?3:8);root.addView(head,headerParams);if(backgroundOnly)head.setVisibility(View.GONE);
        nightwellBadge = text("", 11);
        nightwellBadge.setContentDescription("Состояние подключения Nightwell");
        setNightwellStatus(nightwellStatus);
        // Connectivity indicator lives beside the Menu title, not in a
        // dedicated line above the contents.
        liveHandoff=sheetAction("Музыка на другом устройстве · Продолжить здесь",this::continueLiveHere);
        liveHandoff.setVisibility(View.GONE);root.addView(liveHandoff);
        refreshLiveHandoff();
        LinearLayout contentRow=row();
        root.addView(contentRow,new LinearLayout.LayoutParams(-1,0,1));
        // In landscape, navigation stays in the profile menu. Keep the
        // full viewport for the actual library and playback controls.
        landscapeRail=null;
        body=column();
        contentRow.addView(body,new LinearLayout.LayoutParams(0,-1,1));
        status=text("",landscape?10:12);
        status.setMaxLines(landscape?1:3);
        root.addView(status);
        dock=row();dock.setPadding(dp(10),dp(10),dp(10),dp(11));GradientDrawable fill=new GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT,new int[]{0x1affffff,0x38ffffff});fill.setCornerRadius(dp(34));miniProgress=new android.graphics.drawable.ClipDrawable(fill,Gravity.LEFT,android.graphics.drawable.ClipDrawable.HORIZONTAL);GradientDrawable glassDock=new GradientDrawable(GradientDrawable.Orientation.TL_BR,new int[]{0xff303138,0xff1a1b20});glassDock.setCornerRadius(dp(24));glassDock.setStroke(dp(1),0x30ffffff);dock.setBackground(null);
        miniCover=new android.widget.ImageView(this);miniCover.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);GradientDrawable coverShape=new GradientDrawable(GradientDrawable.Orientation.TL_BR,new int[]{0xff53565c,0xff24262c});coverShape.setCornerRadius(dp(12));miniCover.setBackground(coverShape);miniCover.setClipToOutline(true);miniCover.setOnClickListener(v->openPlayer());LinearLayout.LayoutParams coverParams=new LinearLayout.LayoutParams(dp(47),dp(47));coverParams.rightMargin=dp(10);dock.addView(miniCover,coverParams);
        LinearLayout labels=column();miniTitle=text("Выбери трек",15);miniTitle.setMaxLines(1);miniTitle.setTextSize(15);miniTitle.setLetterSpacing(-.015f);miniTitle.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);miniArtist=text("Nightwell Music",12);miniArtist.setMaxLines(1);miniArtist.setTextSize(12);miniArtist.setLetterSpacing(.005f);miniArtist.setTextColor(0xffa4a6b1);miniTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);miniArtist.setEllipsize(android.text.TextUtils.TruncateAt.END);labels.addView(miniTitle);labels.addView(miniArtist);labels.setOnClickListener(v->openPlayer());dock.addView(labels,new LinearLayout.LayoutParams(0,-2,1));miniPrev=action("|‹",()->previous());miniPlay=action("▶",()->toggle());miniNext=action("›|",()->{nextTrack();});miniLike=action("♡",()->toggleFavorite(current()));miniLike.setTextColor(0xffeeeeee);miniPlay.setTextSize(23);miniNext.setTextSize(24);miniPlay.setPadding(0,0,0,0);miniNext.setPadding(0,0,0,0);miniPlay.setTextColor(0xffeeeeee);miniPlay.setBackground(null);miniPrev.setPadding(0,0,0,0);miniLike.setPadding(0,0,0,0);if(getResources().getConfiguration().screenWidthDp>=440)dock.addView(miniLike,new LinearLayout.LayoutParams(dp(38),dp(48)));dock.addView(miniPlay,new LinearLayout.LayoutParams(dp(48),dp(48)));dock.addView(miniNext,new LinearLayout.LayoutParams(dp(42),dp(48)));
        FrameLayout dockContainer=new FrameLayout(this);
        dockContainer.setBackground(glassDock);
        dockContainer.setClipToOutline(true);
        dockContainer.addView(dock,new FrameLayout.LayoutParams(-1,-2));
        View railBackground=new View(this);
        railBackground.setBackgroundColor(0x2dffffff);
        dockContainer.addView(railBackground,new FrameLayout.LayoutParams(-1,dp(3),Gravity.BOTTOM));
        View playedRail=new View(this);
        playedRail.setBackground(miniProgress);
        dockContainer.addView(playedRail,new FrameLayout.LayoutParams(-1,dp(3),Gravity.BOTTOM));
        LinearLayout.LayoutParams dockParams=new LinearLayout.LayoutParams(-1,-2);
        dockParams.topMargin=dp(landscape?3:9);
        root.addView(dockContainer,dockParams);
        if(backgroundOnly)dockContainer.setVisibility(View.GONE);android.view.GestureDetector miniGestures=gestures(false);labels.setOnTouchListener((v,event)->miniGestures.onTouchEvent(event));dock.setOnTouchListener((v,event)->miniGestures.onTouchEvent(event));
        showScreen();updatePlayback();loadMiniCover(current());
    }
    // Audio routing is controlled by Android. Report the current media route without
    // changing the communication device (which would affect calls instead of music).
    String audioOutputName(){
        try{
            android.media.MediaRouter router=(android.media.MediaRouter)getSystemService(MEDIA_ROUTER_SERVICE);
            if(router!=null){
                android.media.MediaRouter.RouteInfo route=router.getSelectedRoute(android.media.MediaRouter.ROUTE_TYPE_LIVE_AUDIO);
                if(route!=null&&route.getName(this)!=null)return route.getName(this).toString();
            }
        }catch(Exception ignored){}
        return "Аудиовыход Android";
    }
    void chooseAudioOutput(){
        // Use the platform output picker when available. Never allow an unsupported
        // routing API or missing Settings activity to crash the music player.
        try{
            if(android.os.Build.VERSION.SDK_INT>=34){
                android.media.MediaRouter2 router=android.media.MediaRouter2.getInstance(this);
                java.lang.reflect.Method method=android.media.MediaRouter2.class.getMethod("showSystemOutputSwitcher");
                if(Boolean.TRUE.equals(method.invoke(router)))return;
            }
        }catch(Throwable ignored){
            android.util.Log.w("NightwellAudioRoute","System output picker unavailable",ignored);
        }
        try{
            new AlertDialog.Builder(this)
                .setTitle("Устройство вывода")
                .setMessage("Сейчас: "+audioOutputName()+"\\nВыберите настройки подключения устройства.")
                .setItems(new String[]{"Bluetooth","Настройки звука"},(dialog,which)->{
                    try{
                        Intent intent=new Intent(which==0
                            ?android.provider.Settings.ACTION_BLUETOOTH_SETTINGS
                            :android.provider.Settings.ACTION_SOUND_SETTINGS);
                        if(intent.resolveActivity(getPackageManager())!=null)startActivity(intent);
                        else startActivity(new Intent(android.provider.Settings.ACTION_SETTINGS));
                    }catch(Throwable error){
                        android.util.Log.w("NightwellAudioRoute","Cannot open audio settings",error);
                        android.widget.Toast.makeText(this,"Не удалось открыть настройки устройства",android.widget.Toast.LENGTH_SHORT).show();
                    }
                })
                .setNegativeButton("Отмена",null)
                .show();
        }catch(Throwable error){
            android.util.Log.e("NightwellAudioRoute","Cannot show audio route dialog",error);
            android.widget.Toast.makeText(this,"Выбор устройства сейчас недоступен",android.widget.Toast.LENGTH_SHORT).show();
        }
    }
    // Compact two-level navigation, matching iOS. Only the header owns the
    // connection indicator, Additional action and profile avatar.
    void menu(){
        if(navigationPopup!=null)navigationPopup.dismiss();
        final android.widget.ImageView opener=profileAvatarButton;
        LinearLayout shell=column();
        shell.setPadding(dp(12),dp(12),dp(12),dp(11));
        shell.setBackground(glass(22));
        LinearLayout top=row();top.setPadding(dp(2),0,dp(1),dp(8));
        TextView title=text("Меню",19);title.setTypeface(null,android.graphics.Typeface.BOLD);
        title.setSingleLine(true);
        top.addView(title,new LinearLayout.LayoutParams(0,dp(40),1));
        nightwellMenuStatus=text("●",14);
        nightwellMenuStatus.setGravity(Gravity.CENTER);
        top.addView(nightwellMenuStatus,new LinearLayout.LayoutParams(dp(21),dp(36)));
        nightwellMenuSpinner=new ProgressBar(this);
        nightwellMenuSpinner.setIndeterminate(true);
        nightwellMenuSpinner.setIndeterminateTintList(
            android.content.res.ColorStateList.valueOf(0xff67a8ff));
        top.addView(nightwellMenuSpinner,new LinearLayout.LayoutParams(dp(17),dp(24)));
        TextView additional=iconButton("⊞",()->{});
        additional.setTextSize(18);
        additional.setContentDescription("Дополнительно");
        LinearLayout.LayoutParams moreParams=new LinearLayout.LayoutParams(dp(38),dp(38));
        moreParams.leftMargin=dp(7);top.addView(additional,moreParams);
        android.widget.ImageView avatar=new android.widget.ImageView(this);
        if(cachedProfileAvatar!=null&&!user.isEmpty()){
            avatar.setImageBitmap(cachedProfileAvatar);
            avatar.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
            avatar.setClipToOutline(true);
        }else avatar.setImageResource(android.R.drawable.ic_menu_myplaces);
        avatar.setPadding(dp(6),dp(6),dp(6),dp(6));
        avatar.setBackground(touchSurface(0x9d303237,22));
        avatar.setContentDescription(user.isEmpty()?"Войти":"Открыть профиль");
        LinearLayout.LayoutParams avatarParams=new LinearLayout.LayoutParams(dp(38),dp(38));
        avatarParams.leftMargin=dp(7);top.addView(avatar,avatarParams);
        shell.addView(top);
        View headerDivider=new View(this);
        headerDivider.setBackgroundColor(0x26ffffff);
        LinearLayout.LayoutParams dividerParams=new LinearLayout.LayoutParams(-1,dp(1));
        dividerParams.bottomMargin=dp(8);
        shell.addView(headerDivider,dividerParams);
        ScrollView scroll=new ScrollView(this);
        scroll.setFillViewport(false);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout entries=column();
        scroll.addView(entries);
        shell.addView(scroll);
        int width=Math.min(dp(302),getResources().getDisplayMetrics().widthPixels-dp(24));
        int maxHeight=getResources().getDisplayMetrics().heightPixels-dp(isLandscapeLayout()?55:95);
        PopupWindow popup=new PopupWindow(shell,width,WindowManager.LayoutParams.WRAP_CONTENT,true);
        navigationPopup=popup;
        popup.setBackgroundDrawable(glass(22));
        popup.setElevation(dp(22));
        popup.setOutsideTouchable(true);
        popup.setInputMethodMode(PopupWindow.INPUT_METHOD_NOT_NEEDED);
        popup.setOnDismissListener(()->{
            if(navigationPopup==popup)navigationPopup=null;
            nightwellMenuStatus=null;
            nightwellMenuSpinner=null;
            if(opener!=null&&opener.isAttachedToWindow()){
                opener.setVisibility(View.VISIBLE);
                opener.animate().alpha(1f).setDuration(180).start();
            }
        });
        final boolean[] extra={false};
        Runnable render=()->{
            entries.removeAllViews();
            String[] tabs=extra[0]
                ? (user.isEmpty()?new String[]{"Слушать вместе","Обращения"}:
                    new String[]{"Слушать вместе","Моя статистика","Перенос плейлистов","Обращения"})
                : (user.isEmpty()?new String[]{"Войти","Главная","Настройки"}:
                    new String[]{"Главная","Избранное","Плейлисты","Офлайн","Nightwell Premium","Настройки"});
            for(String tab:tabs){
                final String glyph;
                switch(tab){
                    case "Главная":glyph="⌂";break;
                    case "Избранное":glyph="♡";break;
                    case "Плейлисты":glyph="▤";break;
                    case "Офлайн":glyph="↓";break;
                    case "Настройки":glyph="⚙";break;
                    case "Nightwell Premium":glyph="✧";break;
                    case "Слушать вместе":glyph="◉";break;
                    case "Моя статистика":glyph="▥";break;
                    case "Перенос плейлистов":glyph="⇩";break;
                    default:glyph="↗";
                }
                boolean active=tab.equals(screen);
                LinearLayout item=row();
                item.setPadding(dp(10),0,dp(9),0);
                item.setBackground(touchSurface(active?0xff3b3d43:0xff25272c,13));
                TextView symbol=text(glyph,18);
                symbol.setGravity(Gravity.CENTER);
                symbol.setTextColor(active?0xffffffff:0xffaeb3bd);
                item.addView(symbol,new LinearLayout.LayoutParams(dp(27),dp(44)));
                TextView name=text(tab,13);
                name.setTypeface(android.graphics.Typeface.create(active?"sans-serif-medium":"sans-serif",0));
                name.setSingleLine(true);
                name.setEllipsize(android.text.TextUtils.TruncateAt.END);
                LinearLayout.LayoutParams textParams=new LinearLayout.LayoutParams(0,-2,1);
                textParams.leftMargin=dp(9);
                item.addView(name,textParams);
                TextView chevron=text("›",18);
                chevron.setTextColor(0xff777b85);
                item.addView(chevron);
                item.setOnClickListener(v->{popup.dismiss();selectMenu(tab);});
                LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,dp(44));
                p.bottomMargin=dp(4);
                entries.addView(item,p);
            }
            entries.measure(View.MeasureSpec.makeMeasureSpec(width-dp(24),View.MeasureSpec.EXACTLY),
                            View.MeasureSpec.makeMeasureSpec(0,View.MeasureSpec.UNSPECIFIED));
            popup.setHeight(Math.min(maxHeight,entries.getMeasuredHeight()+dp(78)));
        };
        additional.setOnClickListener(v->{
            extra[0]=!extra[0];
            title.setText(extra[0]?"Дополнительно":"Меню");
            additional.setText(extra[0]?"‹":"⊞");
            additional.setContentDescription(extra[0]?"Назад в меню":"Дополнительно");
            render.run();
            popup.update(width,popup.getHeight());
        });
        avatar.setOnClickListener(v->{
            popup.dismiss();
            if(user.isEmpty())auth();else profile();
        });
        render.run();
        setNightwellStatus(nightwellStatus);
        popup.showAtLocation(head,Gravity.TOP|Gravity.RIGHT,dp(12),
            Math.max(dp(58),getWindow().getDecorView().getRootWindowInsets()==null?
                dp(65):dp(80)));
        if(android.animation.ValueAnimator.areAnimatorsEnabled()){
            shell.setAlpha(0f);shell.setTranslationY(-dp(9));
            shell.animate().alpha(1f).translationY(0).setDuration(220)
                .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
        }
        if(opener!=null){
            opener.animate().alpha(0f).setDuration(150).withEndAction(()->{
                if(navigationPopup==popup)opener.setVisibility(View.GONE);
            }).start();
        }
    }

    private String togetherCode="";
    private int togetherGeneration=0;

    private String togetherRoomCode(String input){
        String value=input==null?"":input.trim();
        try{
            Uri uri=Uri.parse(value);
            if("https".equalsIgnoreCase(uri.getScheme())){
                if(!Uri.parse(origin).getHost().equalsIgnoreCase(uri.getHost()))return "";
                value=uri.getQueryParameter("together");
            }else if("nightwell".equalsIgnoreCase(uri.getScheme())
                     &&"together".equalsIgnoreCase(uri.getHost()))
                value=uri.getLastPathSegment();
        }catch(Exception ignored){}
        return value!=null&&value.matches("[A-Za-z0-9_-]{24}")?value:"";
    }

    void together(){
        if(user.isEmpty()){auth();return;}
        final String owner=user;
        LinearLayout panel=column();panel.setPadding(dp(18),dp(14),dp(18),dp(18));
        TextView summary=text("Пригласи друга по ссылке и слушайте одну очередь.",13);
        summary.setTextColor(0xffb7bac3);panel.addView(summary);
        EditText invite=new EditText(this);
        invite.setHint("Код комнаты или ссылка");
        invite.setSingleLine(true);styleField(invite);
        LinearLayout.LayoutParams inputParams=new LinearLayout.LayoutParams(-1,-2);
        inputParams.topMargin=dp(15);panel.addView(invite,inputParams);
        TextView state=text(togetherCode.isEmpty()?"Нет активной комнаты":"Комната "+togetherCode,14);
        state.setTextColor(0xffe2e4ea);
        state.setPadding(0,dp(15),0,dp(10));panel.addView(state);
        TextView create=sheetAction("Создать комнату",()->{});
        TextView join=sheetAction("Присоединиться",()->{});
        TextView share=sheetAction("Поделиться приглашением",()->{});
        TextView previous=sheetAction("Предыдущий",()->{});
        TextView toggle=sheetAction("Воспроизведение / пауза",()->{});
        TextView next=sheetAction("Следующий",()->{});
        TextView leave=sheetAction("Покинуть комнату",()->{});
        for(TextView item:new TextView[]{create,join,share,previous,toggle,next,leave}){
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);
            p.bottomMargin=dp(8);panel.addView(item,p);
        }
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Слушать вместе")
            .setView(panel).setPositiveButton("Готово",null).create();
        final Runnable[] refreshUI={null};
        refreshUI[0]=()->{
            boolean joined=!togetherCode.isEmpty();
            state.setText(joined?"Комната "+togetherCode:"Нет активной комнаты");
            invite.setVisibility(joined?View.GONE:View.VISIBLE);
            create.setVisibility(joined?View.GONE:View.VISIBLE);
            join.setVisibility(joined?View.GONE:View.VISIBLE);
            share.setVisibility(joined?View.VISIBLE:View.GONE);
            previous.setVisibility(joined?View.VISIBLE:View.GONE);
            toggle.setVisibility(joined?View.VISIBLE:View.GONE);
            next.setVisibility(joined?View.VISIBLE:View.GONE);
            leave.setVisibility(joined?View.VISIBLE:View.GONE);
        };
        create.setOnClickListener(v->{
            create.setEnabled(false);
            state.setText("Создаём комнату…");
            task(()->api.request("api/together/rooms","POST",new JSONObject()),response->{
                create.setEnabled(true);
                togetherCode=response.optJSONObject("room")==null?"":response.optJSONObject("room").optString("code");
                refreshUI[0].run();
            });
        });
        join.setOnClickListener(v->{
            String target=togetherRoomCode(invite.getText().toString());
            if(target.isEmpty()){state.setText("Введи код из 24 символов или ссылку.");return;}
            join.setEnabled(false);state.setText("Подключаемся…");
            task(()->api.request("api/together/rooms/"+target+"/join","POST",new JSONObject()),
                response->{join.setEnabled(true);togetherCode=target;refreshUI[0].run();});
        });
        share.setOnClickListener(v->{
            if(togetherCode.isEmpty())return;
            String url=origin+"?together="+togetherCode;
            Intent send=new Intent(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT,url);
            startActivity(Intent.createChooser(send,"Пригласить слушать вместе"));
        });
        java.util.function.Consumer<String> command=action->{
            if(togetherCode.isEmpty())return;
            final String codeSnapshot=togetherCode;
            task(()->api.request("api/together/rooms/"+codeSnapshot+"/command","POST",
                new JSONObject().put("action",action)),ignored->{});
        };
        previous.setOnClickListener(v->command.accept("previous"));
        toggle.setOnClickListener(v->command.accept("play"));
        next.setOnClickListener(v->command.accept("next"));
        leave.setOnClickListener(v->{
            String codeSnapshot=togetherCode;togetherCode="";
            togetherGeneration++;
            refreshUI[0].run();
            task(()->api.request("api/together/rooms/"+codeSnapshot+"/leave","POST",new JSONObject()),
                ignored->{});
        });
        int generation=++togetherGeneration;
        Runnable[] poll={null};
        poll[0]=()->{
            if(!dialog.isShowing()||!owner.equals(user)||generation!=togetherGeneration)return;
            final String codeSnapshot=togetherCode;
            if(!codeSnapshot.isEmpty()){
                io.execute(()->{
                    try{
                        JSONObject result=api.request("api/together/rooms/"+codeSnapshot);
                        JSONObject room=result.optJSONObject("room");
                        ui.post(()->{
                            if(!dialog.isShowing()||generation!=togetherGeneration||
                               !codeSnapshot.equals(togetherCode)||room==null)return;
                            JSONArray members=room.optJSONArray("members");
                            state.setText("Комната "+codeSnapshot+"\nУчастников: "+
                                (members==null?0:members.length()));
                            JSONObject track=room.optJSONObject("track");
                            if(track!=null&&playback!=null){
                                String desired=track.optString("id");
                                if(!desired.isEmpty()&&!desired.equals(currentID)){
                                    JSONArray tracks=room.optJSONArray("queue");
                                    if(tracks==null||tracks.length()==0)tracks=new JSONArray().put(track);
                                    play(track,tracks,false);
                                }else if(!desired.isEmpty()){
                                    double seconds=room.optDouble("position_ms",0)/1000.0;
                                    if(room.optBoolean("playing")&&
                                       Math.abs(playback.player.getCurrentPosition()/1000.0-seconds)>2.0)
                                        playback.seek(seconds);
                                    if(room.optBoolean("playing")&&!playback.player.getPlayWhenReady())
                                        playback.play();
                                    if(!room.optBoolean("playing")&&playback.player.getPlayWhenReady())
                                        playback.pause();
                                }
                            }
                        });
                    }catch(Exception ignored){}
                });
            }
            ui.postDelayed(poll[0],1600);
        };
        dialog.setOnDismissListener(v->{togetherGeneration++;ui.removeCallbacks(poll[0]);});
        styleSheet(dialog);dialog.show();
        refreshUI[0].run();
        ui.postDelayed(poll[0],800);
    }

    void profile(){
        if(user.isEmpty()){auth();return;}
        LinearLayout panel=column();
        panel.setPadding(dp(20),dp(13),dp(20),dp(14));
        LinearLayout header=row();
        header.setPadding(dp(1),dp(4),dp(1),dp(12));
        android.widget.ImageView avatar=new android.widget.ImageView(this);
        if(cachedProfileAvatar!=null){
            avatar.setImageBitmap(cachedProfileAvatar);
            avatar.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
        }else{
            avatar.setImageResource(android.R.drawable.ic_menu_myplaces);
            avatar.setPadding(dp(13),dp(13),dp(13),dp(13));
        }
        avatar.setBackground(fieldSurface(0xff292b30,34));
        avatar.setClipToOutline(true);
        avatar.setElevation(dp(2));
        header.addView(avatar,new LinearLayout.LayoutParams(dp(68),dp(68)));
        LinearLayout identity=column();
        identity.setGravity(Gravity.CENTER_VERTICAL);
        identity.setPadding(dp(16),0,0,0);
        String nickname=cachedProfileNickname.isEmpty()?"Твой профиль":cachedProfileNickname;
        TextView title=text(nickname,21);
        title.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
        title.setMaxLines(1);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        identity.addView(title);
        TextView caption=text("Аккаунт Nightwell Music",13);
        caption.setTextColor(0xffa2a6b0);
        caption.setPadding(0,dp(6),0,0);
        identity.addView(caption);
        header.addView(identity,new LinearLayout.LayoutParams(0,dp(68),1));
        panel.addView(header);
        View rule=new View(this);rule.setBackgroundColor(0x26ffffff);
        LinearLayout.LayoutParams line=new LinearLayout.LayoutParams(-1,dp(1));
        line.bottomMargin=dp(14);
        panel.addView(rule,line);
        TextView editAvatar=sheetAction("▧    Изменить аватар    ›",this::selectProfileAvatar);
        TextView editNick=sheetAction("✎    Изменить ник    ›",this::editProfileNickname);
        LinearLayout.LayoutParams a1=new LinearLayout.LayoutParams(-1,dp(53));
        a1.bottomMargin=dp(9);panel.addView(editAvatar,a1);
        panel.addView(editNick,new LinearLayout.LayoutParams(-1,dp(53)));
        View space=new View(this);
        panel.addView(space,new LinearLayout.LayoutParams(-1,dp(16)));
        TextView logout=sheetAction("↪    Выйти из аккаунта",()->{});
        logout.setTextColor(0xffffaaa9);
        logout.setBackground(touchSurface(0xff30262a,17));
        panel.addView(logout,new LinearLayout.LayoutParams(-1,dp(54)));
        AlertDialog sheet=new AlertDialog.Builder(this).setTitle("Профиль")
            .setView(panel).setPositiveButton("Готово",null).create();
        logout.setOnClickListener(v->new AlertDialog.Builder(this)
            .setTitle("Выйти из аккаунта?")
            .setNegativeButton("Отмена",null)
            .setPositiveButton("Выйти",(dialog,which)->{
                sheet.dismiss();
                selectMenu("Выйти");
            }).show());
        styleNavigationSheet(sheet);sheet.show();
    }

    void selectMenu(String tab){
        if(tab.equals("Перенести музыку")||tab.equals("Перенос плейлистов")){nativeTransfer();return;}
        if(tab.equals("Слушать вместе")){together();return;}
         if(tab.equals("Моя статистика")){feature("stats");return;}
        if(tab.equals("Nightwell Premium")){premium();return;}
        if(tab.equals("Настройки"))settings();
        else if(tab.equals("Настройка подборки"))waveSettings();
        else if(tab.equals("Обращения"))supportTickets(false);
        else if(tab.equals("Профиль"))profile();
        else if(tab.equals("Только фон")||tab.equals("Показать интерфейс"))toggleBackgroundOnly();
        else if(tab.equals("Войти"))auth();
        else if(tab.equals("Выйти")){cancelMix();accountRequest.cancel();task(()->{api.request("api/logout","POST",null);new SessionStore(this).clear();clearLibrarySnapshot();return new JSONObject();},v->{libraryGeneration++;user="";searchCache.clear();playlists=new JSONArray();selectedPlaylist="";sessionReady=true;api.updateCSRF("");getSharedPreferences("native-api",MODE_PRIVATE).edit().putString("account","").apply();catalog=new JSONArray();shown=new JSONArray();likes.clear();if(playback!=null)playback.stop();navigate("Главная");});}
        else navigate(tab);
    }

    View supportCard(String subject,String state,Runnable click){
        LinearLayout card=column();card.setPadding(dp(16),dp(13),dp(16),dp(13));
        TextView name=text(subject,16);name.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);
        TextView stateView=text(state.equals("new")?"Новое":state.equals("in_progress")?"В работе":state.equals("waiting_user")?"Ожидает ответа":state.equals("resolved")?"Решено":"Закрыто",12);
        stateView.setTextColor(0xffe7e7e7);
        card.addView(name);card.addView(stateView);
        card.setBackground(touchSurface(0xaa252a33,26));
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(0,dp(8),0,dp(8));card.setLayoutParams(lp);card.setOnClickListener(v->click.run());
        return card;
    }
    void supportTickets(boolean adminMode){
        if(user.isEmpty()){auth();return;}
        task(()->api.request(adminMode?"api/support/admin/tickets":"api/support/tickets"),data->{
            JSONArray tickets=data.optJSONArray("tickets");
            LinearLayout panel=column();panel.setPadding(dp(18),dp(12),dp(18),dp(12));
            ScrollView scroll=new ScrollView(this);scroll.addView(panel);
            AlertDialog dialog=new AlertDialog.Builder(this).setTitle(adminMode?"Управление обращениями":"Обращения").setView(scroll).setNegativeButton("Закрыть",null).create();
            if(!adminMode)panel.addView(action("＋ Новое обращение",()->{dialog.dismiss();supportCreate();}));
            panel.addView(action(adminMode?"Мои обращения":"Администрирование",()->{
                dialog.dismiss();
                if(adminMode)supportTickets(false);
                else task(()->api.request("api/support/admin/tickets"),result->supportTickets(true));
            }));
            if(tickets!=null)for(int i=0;i<tickets.length();i++){
                JSONObject item=tickets.optJSONObject(i);if(item==null)continue;
                String id=item.optString("id");
                panel.addView(supportCard(item.optString("subject"),item.optString("status"),()->{dialog.dismiss();supportDetail(id,adminMode);}));
            }
            styleSheet(dialog);dialog.show();
        });
    }
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        if(request==635){
            if(result==RESULT_OK&&data!=null&&data.getData()!=null)uploadProfileAvatar(data.getData());
            return;
        }
        if(request==72){handleAudioImportResult(request,result,data);return;}
        if(request==PLAYLIST_DOCUMENT){handlePlaylistDocument(result,data);return;}
        if(request!=631&&request!=632)return;
        if(result!=RESULT_OK||data==null||data.getData()==null||supportUploadTicket.isEmpty()){
            supportUploadTicket="";return;
        }
        final String id=supportUploadTicket;final boolean adminMode=supportUploadAdmin;
        supportUploadTicket="";
        final Uri uri=data.getData();
        task(()->{
            String name="";
            try(android.database.Cursor cursor=getContentResolver().query(uri,new String[]{android.provider.OpenableColumns.DISPLAY_NAME},null,null,null)){
                if(cursor!=null&&cursor.moveToFirst())name=cursor.getString(0);
            }
            byte[] bytes;
            try(java.io.InputStream input=getContentResolver().openInputStream(uri);java.io.ByteArrayOutputStream buffer=new java.io.ByteArrayOutputStream()){
                if(input==null)throw new java.io.IOException("Не удалось открыть файл");
                byte[] chunk=new byte[65536];int n;
                while((n=input.read(chunk))!=-1){if(buffer.size()+n>10*1024*1024)throw new java.io.IOException("Максимум 10 МБ");buffer.write(chunk,0,n);}
                bytes=buffer.toByteArray();
            }
            if(name==null||name.trim().isEmpty()){
                String mime=getContentResolver().getType(uri);
                String extension=mime==null?null:android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime);
                name=(extension!=null&&!extension.isEmpty())?"attachment."+extension:"attachment";
            }
            return api.uploadSupportAttachment(id,name,bytes);
        },uploadResult->supportDetail(id,adminMode));
    }
    void chooseSupportAttachment(){
        new AlertDialog.Builder(this).setTitle("Прикрепить вложение")
            .setItems(new String[]{"Файлы","Галерея"},(dialog,which)->{
                Intent choose=new Intent(which==0?Intent.ACTION_OPEN_DOCUMENT:Intent.ACTION_GET_CONTENT);
                choose.setType(which==0?"*/*":"image/*");
                choose.addCategory(Intent.CATEGORY_OPENABLE);
                try{startActivityForResult(choose,which==0?631:632);}
                catch(android.content.ActivityNotFoundException ex){
                    supportUploadTicket="";
                    Toast.makeText(this,"Нет приложения для выбора вложения",Toast.LENGTH_LONG).show();
                }
            }).setNegativeButton("Отмена",(dialog,which)->supportUploadTicket="").show();
    }
    void supportCreate(){
        LinearLayout form=column();form.setPadding(dp(16),dp(8),dp(16),dp(8));
        EditText subject=new EditText(this),body=new EditText(this);
        subject.setHint("Тема");body.setHint("Описание обращения");body.setMinLines(4);styleField(subject);styleField(body);
        form.addView(subject);
        Spinner kindPicker=new Spinner(this);
        String[] labels={"Вопрос","Ошибка","Предложение","Аккаунт","Другое"};
        String[] values={"question","bug","suggestion","account","other"};
        kindPicker.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,labels));kindPicker.setBackground(fieldSurface(0x88262a33,18));
        form.addView(kindPicker);form.addView(body);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Новое обращение").setView(form).setNegativeButton("Отмена",null).setPositiveButton("Отправить",null).create();
        styleSheet(dialog);dialog.show();
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{
            if(subject.length()<4||body.length()<5){Toast.makeText(this,"Заполни тему и описание",Toast.LENGTH_SHORT).show();return;}
            task(()->api.request("api/support/tickets","POST",new JSONObject().put("subject",subject.getText().toString()).put("body",body.getText().toString()).put("kind",values[kindPicker.getSelectedItemPosition()])),result->{dialog.dismiss();supportTickets(false);});
        });
    }
    void downloadSupportFile(String id,JSONObject attachment){
        io.execute(()->{
            try{
                byte[] bytes=api.downloadSupportAttachment(id,attachment.optString("id"));
                if(bytes.length>10*1024*1024)throw new java.io.IOException("Файл больше 10 МБ");
                String name=attachment.optString("name","attachment").replace("/","_").replace("\\","_");
                String mime=attachment.optString("mime","application/octet-stream");
                if(mime==null||mime.trim().isEmpty())mime="application/octet-stream";
                final String contentType=mime;
                if(android.os.Build.VERSION.SDK_INT<29){
                    java.io.File folder=new java.io.File(getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS),"Nightwell Music");
                    if(!folder.exists()&&!folder.mkdirs())throw new java.io.IOException("Не удалось создать папку");
                    java.io.File target=new java.io.File(folder,name);
                    try(java.io.FileOutputStream out=new java.io.FileOutputStream(target)){out.write(bytes);}
                    ui.post(()->Toast.makeText(this,"Файл сохранён: "+target.getAbsolutePath(),Toast.LENGTH_LONG).show());
                    return;
                }
                android.content.ContentValues values=new android.content.ContentValues();
                values.put(android.provider.MediaStore.Downloads.DISPLAY_NAME,name);
                values.put(android.provider.MediaStore.Downloads.MIME_TYPE,contentType);
                values.put(android.provider.MediaStore.Downloads.IS_PENDING,1);
                values.put(android.provider.MediaStore.Downloads.RELATIVE_PATH,android.os.Environment.DIRECTORY_DOWNLOADS+"/Nightwell Music");
                Uri saved=getContentResolver().insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,values);
                if(saved==null)throw new java.io.IOException("Не удалось сохранить файл");
                try(java.io.OutputStream out=getContentResolver().openOutputStream(saved)){
                    if(out==null)throw new java.io.IOException("Файл недоступен");
                    out.write(bytes);
                }catch(Exception writeError){
                    getContentResolver().delete(saved,null,null);
                    throw writeError;
                }
                android.content.ContentValues ready=new android.content.ContentValues();
                ready.put(android.provider.MediaStore.Downloads.IS_PENDING,0);
                getContentResolver().update(saved,ready,null,null);
                ui.post(()->{
                    Intent view=new Intent(Intent.ACTION_VIEW).setDataAndType(saved,contentType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    try{startActivity(view);}catch(android.content.ActivityNotFoundException ex){Toast.makeText(this,"Сохранено в Загрузки/Nightwell Music",Toast.LENGTH_LONG).show();}
                });
            }catch(Exception ex){
                ui.post(()->Toast.makeText(this,"Ошибка файла: "+ex.getMessage(),Toast.LENGTH_LONG).show());
            }
        });
    }
    View supportMessage(JSONObject m){
        boolean administrator="admin".equals(m.optString("author_role"));
        LinearLayout bubble=column();bubble.setPadding(dp(14),dp(12),dp(14),dp(12));
        TextView caption=text(administrator?"Поддержка":"Пользователь",12);caption.setTextColor(0xffe7e7e7);
        bubble.addView(caption);bubble.addView(text(m.optString("body"),15));
        GradientDrawable bg=new GradientDrawable();bg.setCornerRadius(dp(22));bg.setColor(administrator?0x663e3051:0x55333340);
        bubble.setBackground(bg);
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(0,dp(5),0,dp(5));bubble.setLayoutParams(lp);
        return bubble;
    }
    View supportAttachment(JSONObject file,Runnable onClick){
        TextView row=action("📎  "+file.optString("name")+"  ·  "+Math.max(1,(file.optLong("size")+1023)/1024)+" КБ",onClick);
        row.setMinHeight(dp(48));return row;
    }
    void supportDetail(String id,boolean adminMode){
        task(()->api.request((adminMode?"api/support/admin/tickets/":"api/support/tickets/")+id),data->{
            LinearLayout panel=column();panel.setPadding(dp(16),dp(8),dp(16),dp(8));
            panel.addView(supportCard(data.optString("subject"),data.optString("status"),()->{}));
            panel.addView(text("Переписка",17));
            JSONArray messages=data.optJSONArray("messages");
            if(messages!=null)for(int i=0;i<messages.length();i++){JSONObject m=messages.optJSONObject(i);if(m!=null)panel.addView(supportMessage(m));}
            JSONArray attachments=data.optJSONArray("attachments");
            panel.addView(text("Вложения ("+(attachments==null?0:attachments.length())+")",17));
            if(attachments!=null)for(int a=0;a<attachments.length();a++){
                JSONObject attachment=attachments.optJSONObject(a);if(attachment==null)continue;
                panel.addView(supportAttachment(attachment,()->downloadSupportFile(id,attachment)));
            }
            ScrollView scroll=new ScrollView(this);scroll.addView(panel);
            AlertDialog dialog=new AlertDialog.Builder(this).setTitle(data.optString("subject")).setView(scroll).setNegativeButton("Закрыть",null).create();
            if(!data.optString("status").equals("closed"))panel.addView(action("Прикрепить файл до 10 МБ",()->{supportUploadTicket=id;supportUploadAdmin=adminMode;dialog.dismiss();chooseSupportAttachment();}));
            if(!data.optString("status").equals("closed"))panel.addView(action(adminMode?"Ответить":"Дополнить",()->{
                EditText reply=new EditText(this);reply.setMinLines(3);
                new AlertDialog.Builder(this).setTitle("Сообщение").setView(reply).setNegativeButton("Отмена",null).setPositiveButton("Отправить",(d,n)->task(()->api.request((adminMode?"api/support/admin/tickets/":"api/support/tickets/")+id+"/messages","POST",new JSONObject().put("body",reply.getText().toString())),result->{dialog.dismiss();supportDetail(id,adminMode);})).show();
            }));
            if(adminMode)panel.addView(action("Изменить статус",()->{
                String[] statuses={"new","in_progress","waiting_user","resolved","closed"};
                new AlertDialog.Builder(this).setItems(statuses,(d,n)->task(()->api.request("api/support/admin/tickets/"+id+"/status","PATCH",new JSONObject().put("status",statuses[n])),result->{dialog.dismiss();supportDetail(id,true);})).show();
            }));
            styleSheet(dialog);dialog.show();
        });
    }
    private boolean autoFavoritesEnabled() {
        return !user.isEmpty() && getSharedPreferences("auto-favorites", MODE_PRIVATE).getBoolean(origin+"|"+user,false);
    }
    private void setAutoFavoritesEnabled(boolean enabled) {
        if(user.isEmpty()){auth();return;}
        getSharedPreferences("auto-favorites",MODE_PRIVATE).edit().putBoolean(origin+"|"+user,enabled).apply();
        if(enabled)checkAutoFavoriteDownloads();
    }
    private long lastFavoriteDownloadCheck;
    private void checkAutoFavoriteDownloads() {
        if(!autoFavoritesEnabled()||catalog.length()==0||likes.isEmpty())return;
        if(android.os.SystemClock.elapsedRealtime()-lastFavoriteDownloadCheck<120000)return;
        lastFavoriteDownloadCheck=android.os.SystemClock.elapsedRealtime();
        JSONArray missing=new JSONArray();
        for(int i=0;i<catalog.length();i++){
            JSONObject track=catalog.optJSONObject(i);
            if(track==null||!likes.contains(track.optString("id")))continue;
            if(OfflineStore.audio(this,origin,user,track.optString("id"))==null)missing.put(track);
            if(missing.length()>=500)break;
        }
        if(missing.length()>0)download(missing);
    }
    void toggleFavorite(JSONObject track){
        if(user.isEmpty()){auth();return;}if(track==null)return;
        final String id=track.optString("id");final boolean remove=likes.contains(id);
        task(()->api.request("api/likes/"+id,remove?"DELETE":"POST",null),v->{
            if(remove)likes.remove(id);else{likes.add(id);if(ribbon!=null)ribbon.flash();}
            refreshFavoriteButtons();updatePlayback();updateList();
            if(!remove&&autoFavoritesEnabled())download(new JSONArray().put(track));
            Toast.makeText(this,remove?"Убрано из избранного":"Добавлено в избранное",Toast.LENGTH_SHORT).show();
        });
    }
    void refreshFavoriteButtons(){
        boolean liked=likes.contains(currentID);
        for(TextView button:new TextView[]{miniLike,fullLike})if(button!=null){
            setLabel(button,liked?"♥":"♡");button.setContentDescription(liked?"Убрать из избранного":"Добавить в избранное");
            button.setTextColor(liked?0xffeeeeee:0xffa4a6b1);
        }
    }
    void navigate(String next){generation++;api.cancelSearch();if(pendingSearch!=null)ui.removeCallbacks(pendingSearch);screen=next;selectedPlaylist="";query="";if(full)build();else showScreen();}
    void showScreen(){
        if(atmosphere!=null)atmosphere.setVisibility(screen.equals("Главная")?View.VISIBLE:View.GONE);
        if(android.animation.ValueAnimator.areAnimatorsEnabled()){body.setAlpha(.5f);body.animate().alpha(1).setDuration(180);}
        if(ribbon!=null){ribbon.running(false);ribbon.setVisibility(View.GONE);}body.removeAllViews();list=null;search=null;artistStrip=null;adapter=null;
        if(!screen.equals("Главная")){
            TextView title=text(screen,isLandscapeLayout()?21:30);
            title.setMaxLines(1);title.setEllipsize(android.text.TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams titleLayout=new LinearLayout.LayoutParams(-1,-2);
            titleLayout.bottomMargin=dp(isLandscapeLayout()?7:13);
            body.addView(title,titleLayout);
        }
        if(screen.equals("Главная")){
            boolean compact=getResources().getConfiguration().orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE;
            android.widget.FrameLayout stage=new android.widget.FrameLayout(this);body.addView(stage,new LinearLayout.LayoutParams(-1,0,1));
            ribbon.setVisibility(View.VISIBLE);ribbon.running(visible&&!smokeMode);
            LinearLayout intro=column();intro.setGravity(Gravity.CENTER);intro.setPadding(0,0,0,0);
            TextView theme=text("Твой ритм",compact?30:Math.min(48,getResources().getConfiguration().screenWidthDp/8));theme.setTypeface(android.graphics.Typeface.create("sans-serif",android.graphics.Typeface.BOLD));theme.setLetterSpacing(-.035f);theme.setIncludeFontPadding(false);theme.setLineSpacing(0,.92f);theme.setMaxLines(2);theme.setAutoSizeTextTypeUniformWithConfiguration(25,43,1,android.util.TypedValue.COMPLEX_UNIT_SP);intro.addView(theme);theme.setGravity(Gravity.CENTER);
            android.widget.FrameLayout.LayoutParams introParams=new android.widget.FrameLayout.LayoutParams(-1,-2,Gravity.CENTER);
            introParams.bottomMargin=dp(compact?150:165);
            stage.addView(intro,introParams);
            homePlay=action("▶",()->{if(currentID.isEmpty())wave();else toggle();});homePlay.setTextColor(0xff111215);homePlay.setTextSize(31);homePlay.setBackground(touchSurface(0xfff1f1f2,44));homePlay.setElevation(dp(5));android.widget.FrameLayout.LayoutParams playParams=new android.widget.FrameLayout.LayoutParams(dp(88),dp(88),Gravity.CENTER);if(compact){playParams.gravity=Gravity.CENTER_VERTICAL|Gravity.RIGHT;playParams.rightMargin=dp(50);}else playParams.topMargin=dp(30);stage.addView(homePlay,playParams);
            TextView mix=action("Новая подборка",this::wave);mix.setOnLongClickListener(v->{waveSettings();return true;});mix.setContentDescription("Новая подборка. Удерживай, чтобы настроить");mix.setTextSize(14);mix.setBackground(touchSurface(0xff2b2d33,21));mix.setTextColor(0xffffffff);mix.setTypeface(null,android.graphics.Typeface.BOLD);android.widget.FrameLayout.LayoutParams mixParams=new android.widget.FrameLayout.LayoutParams(dp(184),dp(44),Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);mixParams.bottomMargin=dp(compact?20:124);stage.addView(mix,mixParams);
            homeLyric=text("",16);homeLine="";homeWord=-2;homeKineticSpans.clear();homeLyric.setGravity(Gravity.CENTER);homeLyric.setTextColor(0xffe1e1e1);homeLyric.setMaxLines(2);homeLyric.setOnClickListener(v->{JSONObject t=current();if(t!=null)showLyrics(t);});android.widget.FrameLayout.LayoutParams lyricParams=new android.widget.FrameLayout.LayoutParams(-1,dp(50),Gravity.BOTTOM);stage.addView(homeLyric,lyricParams);if(compact)homeLyric.setVisibility(View.VISIBLE);
            if(compact&&!backgroundOnly){
                // Real two-column landscape layout. Prevent the album/lyrics
                // area from overlapping playback controls on short screens.
                stage.removeView(intro);
                stage.removeView(homePlay);
                stage.removeView(mix);
                stage.removeView(homeLyric);
                LinearLayout twoColumns=row();
                twoColumns.setGravity(Gravity.CENTER_VERTICAL);
                twoColumns.setPadding(dp(12),dp(4),dp(12),dp(4));
                LinearLayout left=column();
                left.setGravity(Gravity.CENTER);
                left.addView(intro,new LinearLayout.LayoutParams(-1,-2));
                LinearLayout controls=row();controls.setGravity(Gravity.CENTER);
                homePlay.setTextSize(26);
                controls.addView(homePlay,new LinearLayout.LayoutParams(dp(68),dp(68)));
                LinearLayout.LayoutParams waveParams=new LinearLayout.LayoutParams(dp(150),dp(38));
                waveParams.leftMargin=dp(10);
                mix.setTextSize(12);
                controls.addView(mix,waveParams);
                left.addView(controls,new LinearLayout.LayoutParams(-1,-2));
                twoColumns.addView(left,new LinearLayout.LayoutParams(0,-1,0.46f));
                LinearLayout lyricColumn=column();lyricColumn.setGravity(Gravity.CENTER);
                homeLyric.setTextSize(18);
                homeLyric.setMaxLines(3);
                homeLyric.setGravity(Gravity.CENTER);
                homeLyric.setPadding(dp(12),dp(5),dp(12),dp(5));
                lyricColumn.addView(homeLyric,new LinearLayout.LayoutParams(-1,-2));
                twoColumns.addView(lyricColumn,new LinearLayout.LayoutParams(0,-1,0.54f));
                stage.addView(twoColumns,new android.widget.FrameLayout.LayoutParams(-1,-1));
            }
            if(backgroundOnly){
                intro.setVisibility(View.GONE);
                mix.setVisibility(View.GONE);
                homePlay.setVisibility(View.GONE);
                homeLyric.setTextSize(27);homeLyric.setAutoSizeTextTypeUniformWithConfiguration(19,29,1,android.util.TypedValue.COMPLEX_UNIT_SP);homeLyric.setLineSpacing(dp(4),1.05f);
                homeLyric.setTypeface(android.graphics.Typeface.create("sans-serif",android.graphics.Typeface.BOLD));
                homeLyric.setTextColor(0xffeeeeee);
                homeLyric.setMaxLines(5);
                homeLyric.setGravity(Gravity.CENTER);
                homeLyric.setPadding(dp(18),dp(12),dp(18),dp(12));
                android.widget.FrameLayout.LayoutParams centeredLyrics=new android.widget.FrameLayout.LayoutParams(-1,-2,Gravity.CENTER);
                centeredLyrics.leftMargin=dp(10);
                centeredLyrics.rightMargin=dp(10);
                homeLyric.setLayoutParams(centeredLyrics);
                homeLyric.setMinHeight(dp(100));
                TextView restore=iconButton("×",this::toggleBackgroundOnly);
                stage.addView(restore,new android.widget.FrameLayout.LayoutParams(dp(48),dp(48),Gravity.TOP|Gravity.LEFT));
            }
            // After a tab/rotation rebuild the new TextView is attached on
            // the next UI traversal. Restore the current lyric immediately.
            ui.postDelayed(()->{
                if(homeLyric!=null&&homeLyric.isAttachedToWindow()&&!full
                    &&(screen.equals("Главная")||backgroundOnly)&&playback!=null)
                    syncHomeLyrics(playback.player.getCurrentPosition()/1000.0);
            },70);
            return;
        }
        if(screen.equals("Поиск")){
            FrameLayout searchBox=new FrameLayout(this);
            searchBox.setBackground(touchSurface(0xff202228,24));
            searchBox.setClipToOutline(true);
            WhiteSearchCaretGlow glow=new WhiteSearchCaretGlow(this);
            searchBox.addView(glow,new FrameLayout.LayoutParams(-1,-1));
            CursorAwareSearchField entry=new CursorAwareSearchField(this);
            search=entry;
            search.setTextColor(Color.WHITE);
            search.setSingleLine(true);
            search.setTextSize(16);
            search.setHintTextColor(0xff999ca8);
            search.setPadding(dp(16),dp(14),dp(16),dp(14));
            search.setBackgroundColor(Color.TRANSPARENT);
            search.setHint("Трек или исполнитель");
            search.setSelectAllOnFocus(false);
            searchBox.addView(search,new FrameLayout.LayoutParams(-1,-2));
            body.addView(searchBox,new LinearLayout.LayoutParams(-1,-2));
            Runnable moveGlow=()->{
                if(search==null||!search.isAttachedToWindow()||search.getLayout()==null)return;
                int insertion=Math.max(0,search.getSelectionStart());
                float caret=search.getLayout().getPrimaryHorizontal(insertion)
                    +search.getTotalPaddingLeft()-search.getScrollX();
                glow.follow(caret);
            };
            entry.selectionUpdated=moveGlow;
            search.setOnFocusChangeListener((view,focused)->{
                moveGlow.run();
                glow.running(focused);
            });
            search.addOnLayoutChangeListener((view,left,top,right,bottom,oldLeft,oldTop,oldRight,oldBottom)->moveGlow.run());
            search.addTextChangedListener(new TextWatcher(){
                public void beforeTextChanged(CharSequence s,int st,int c,int a){}
                public void onTextChanged(CharSequence s,int st,int before,int count){
                    query=s.toString();search(query);search.post(moveGlow);
                }
                public void afterTextChanged(Editable e){}
            });
            shown=new JSONArray();
            artistStrip=column();body.addView(artistStrip);
        }
        else if(screen.equals("Избранное")){shown=new JSONArray();for(int i=0;i<catalog.length();i++)if(likes.contains(catalog.optJSONObject(i).optString("id")))shown.put(catalog.optJSONObject(i));shown=sortedFavorites(shown);LinearLayout actionsRow=row();actionsRow.setGravity(Gravity.RIGHT|Gravity.CENTER_VERTICAL);TextView sort=iconButton("⇅",()->favoriteSortMenu());sort.setContentDescription("Сортировка избранного");TextView more=iconButton("⋯",()->collectionMenu("likes",""));LinearLayout.LayoutParams sortParams=new LinearLayout.LayoutParams(dp(47),dp(46));actionsRow.addView(sort,sortParams);LinearLayout.LayoutParams moreParams=new LinearLayout.LayoutParams(dp(47),dp(46));moreParams.leftMargin=dp(7);actionsRow.addView(more,moreParams);body.addView(actionsRow);}
        else if(screen.equals("Плейлисты")){
            android.widget.ScrollView scroll=new android.widget.ScrollView(this);
            LinearLayout entries=column();
            scroll.addView(entries);
            body.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
            entries.addView(sheetAction("Умные плейлисты · Premium",()->feature("smart")));
            entries.addView(sheetAction("Подборки дня · обновляются ежедневно",this::dailyPublicPlaylists));
            entries.addView(action("＋ Создать плейлист",()->input("Новый плейлист",
                name->task(()->api.request("api/playlists","POST",
                    new JSONObject().put("name",name)),v->load()))));
            boolean wide=isLandscapeLayout();
            LinearLayout left=column(),right=column();
            if(wide){
                LinearLayout columns=row();
                LinearLayout.LayoutParams aColumn=new LinearLayout.LayoutParams(0,-2,1);
                aColumn.rightMargin=dp(6);
                columns.addView(left,aColumn);
                columns.addView(right,new LinearLayout.LayoutParams(0,-2,1));
                entries.addView(columns);
            }
            for(int i=0;i<playlists.length();i++){
                JSONObject p=playlists.optJSONObject(i);
                if(p==null)continue;
                LinearLayout item=row();item.setBackground(surface());
                TextView title=action(p.optString("name"),()->openPlaylist(p));
                title.setGravity(Gravity.CENTER_VERTICAL|Gravity.LEFT);
                title.setMaxLines(2);
                title.setEllipsize(android.text.TextUtils.TruncateAt.END);
                item.addView(title,new LinearLayout.LayoutParams(0,-2,1));
                item.addView(action("⋯",()->collectionMenu("playlist",p.optString("id"))),
                    new LinearLayout.LayoutParams(dp(48),dp(48)));
                LinearLayout.LayoutParams gap=new LinearLayout.LayoutParams(-1,-2);
                gap.bottomMargin=dp(wide?6:10);
                (wide?(i%2==0?left:right):entries).addView(item,gap);
            }
            return;
        }
        else if(screen.equals("Офлайн")){
            body.addView(action("Добавить аудиофайлы",this::importFiles));
            TextView repairNotice=text("",13);
            body.addView(repairNotice);
            task(()->new JSONObject(OfflineStore.operation(this,origin,"{\"op\":\"listAll\"}")),v->{
                if(!screen.equals("Офлайн"))return;
                shown=v.optJSONArray("tracks");
                JSONArray damaged=v.optJSONArray("damaged"),retryable=new JSONArray();
                if(damaged!=null&&damaged.length()>0){
                    repairNotice.setText("Не воспроизводятся: "+damaged.length()+". Названия и обложки сохранились, но аудиофайлы повреждены.");
                    for(int i=0;i<damaged.length();i++){
                        JSONObject item=damaged.optJSONObject(i);
                        if(item!=null&&!item.optString("id").startsWith("local_"))retryable.put(item);
                    }
                    if(retryable.length()>0){
                        TextView retry=action("↻ Скачать повреждённые треки повторно",()->download(retryable));
                        body.addView(retry,2);
                    }
                }
                updateList();
            });
            shown=new JSONArray();
        }
        list=new ListView(this);list.setDivider(null);list.setCacheColorHint(Color.TRANSPARENT);adapter=new TrackAdapter();list.setAdapter(adapter);body.addView(list,new LinearLayout.LayoutParams(-1,0,1));list.setOnItemClickListener((p,v,pos,id)->play(shown.optJSONObject(pos),shown,false));list.setOnItemLongClickListener((p,v,pos,id)->{trackMenu(shown.optJSONObject(pos));return true;});
    }
    void updateList(){
        if(shown==null)shown=new JSONArray();
        // Search results are already normalized by NativeAPI off the UI thread.
        if(!screen.equals("Поиск")){
            for(int i=0;i<shown.length();i++)NativeAPI.normalizeTrack(shown.optJSONObject(i));
        }
        if(adapter!=null)adapter.notifyDataSetChanged();
    }
    private void restoreLibrarySnapshot(String account) {
        try {
            String raw=getSharedPreferences("library-snapshot",MODE_PRIVATE).getString("snapshot",null);
            if(raw==null)return;
            JSONObject snapshot=new JSONObject(raw);
            if(!account.equals(snapshot.optString("account")))return;
            JSONArray tracks=snapshot.optJSONArray("tracks");
            if(tracks!=null){
                for(int i=0;i<tracks.length();i++)NativeAPI.normalizeTrack(tracks.optJSONObject(i));
                catalog=tracks;
            }
            JSONArray savedPlaylists=snapshot.optJSONArray("playlists");
            if(savedPlaylists!=null)playlists=savedPlaylists;
            JSONArray savedLikes=snapshot.optJSONArray("likes");
            if(savedLikes!=null){likes.clear();for(int i=0;i<savedLikes.length();i++)likes.add(savedLikes.optString(i));}
        }catch(Exception ignored){}
    }
    private final Runnable pendingLibrarySave=this::persistLibrarySnapshot;
    private void saveLibrarySnapshot(){
        if(user.isEmpty()||smokeMode)return;
        // Batch the three section responses instead of serializing the
        // complete catalogue three times on the main thread.
        ui.removeCallbacks(pendingLibrarySave);
        ui.postDelayed(pendingLibrarySave,650);
    }
    private void persistLibrarySnapshot(){
        if(user.isEmpty()||smokeMode||isDestroyed())return;
        final String owner=user;
        final JSONArray tracks=catalog,lists=playlists,ids=new JSONArray(likes);
        io.execute(()->{
            try{
                JSONObject snapshot=new JSONObject();
                snapshot.put("account",owner);
                JSONArray trimmed=new JSONArray();
                for(int i=0;i<Math.min(tracks.length(),1500);i++)trimmed.put(tracks.opt(i));
                snapshot.put("tracks",trimmed);
                snapshot.put("playlists",lists);
                snapshot.put("likes",ids);
                String value=snapshot.toString();
                if(value.length()>1250000||!owner.equals(user))return;
                getSharedPreferences("library-snapshot",MODE_PRIVATE)
                    .edit().putString("snapshot",value).apply();
            }catch(Exception ignored){}
        });
    }
    private void clearLibrarySnapshot(){
        getSharedPreferences("library-snapshot",MODE_PRIVATE).edit().remove("snapshot").apply();
    }
    void load(){
        ui.removeCallbacks(connectionRecovery);
        lastResumeRefresh=SystemClock.elapsedRealtime();
        final long ticket=accountRequest.start(()->{});
        io.execute(()->{
            try {
                JSONObject me=api.request("api/me");
                ui.post(()->{
                    if(isDestroyed()||!accountRequest.complete(ticket))return;
                    connectionRecoveryAttempts=0;
                    ui.removeCallbacks(connectionRecovery);
                    api.updateCSRF(me.optString("csrf",""));
                    JSONObject account=me.optJSONObject("user");
                    String nextAccount=account==null?"":account.optString("id");
                    if(!nextAccount.equals(user)){
                        clearLibrarySnapshot();
                        libraryGeneration++;catalog=new JSONArray();shown=new JSONArray();playlists=new JSONArray();likes.clear();selectedPlaylist="";
                        if(playback!=null)playback.stop();
                    }
                    boolean accountChanged=!nextAccount.equals(user);
                    user=nextAccount;
                    if(!nextAccount.equals(getSharedPreferences("native-api",MODE_PRIVATE).getString("account","")))searchCache.clear();
                    if(accountChanged)restoreRecent();
                    getSharedPreferences("native-api",MODE_PRIVATE).edit().putString("account",user).apply();
                    sessionReady=true;
                    if(playback!=null&&pendingDeepLinkTrack.isEmpty())playback.restorePlayback(origin,user);
                    if(!full&&!screen.equals("Поиск"))showScreen();
                    openPendingTrack();
                    if(!user.isEmpty())loadLibrary(user);
                });
            }catch(Exception ex){
                ui.post(()->{
                    if(isDestroyed()||!accountRequest.complete(ticket))return;
                    // Only an explicit unauthenticated response invalidates the local session.
                    // Temporary network failures must never discard saved account or music.
                    if(ex instanceof NetworkRetry.HttpFailure && ((NetworkRetry.HttpFailure)ex).status==401){
                        new SessionStore(this).clear();
                        clearLibrarySnapshot();
                        api.updateCSRF("");
                        libraryGeneration++;
                        user="";
                        catalog=new JSONArray();
                        shown=new JSONArray();
                        playlists=new JSONArray();
                        likes.clear();
                        selectedPlaylist="";
                        getSharedPreferences("native-api",MODE_PRIVATE).edit().putString("account","").apply();
                        if(playback!=null)playback.stop();
                        if(!full&&!screen.equals("Поиск"))showScreen();
                    }
                    sessionReady=true;
                    status.setText(friendly(ex));
                    // Reconnect automatically after transient outages, without a busy loop.
                    if(visible && !(ex instanceof NetworkRetry.HttpFailure && ((NetworkRetry.HttpFailure)ex).status==401)
                            && connectionRecoveryAttempts<3){
                        int delay=10000*(1<<connectionRecoveryAttempts++);
                        ui.removeCallbacks(connectionRecovery);
                        ui.postDelayed(connectionRecovery,delay);
                    }
                });
            }
        });
    }
    void loadLibrary(String account){
        final long revision=++libraryGeneration;
        final NativeAPI client=api;
        io.execute(()->{
            try{
                JSONObject value=client.request("api/tracks");
                JSONArray tracks=value.optJSONArray("tracks");
                ui.post(()->{if(!isDestroyed()&&client==api&&revision==libraryGeneration&&account.equals(user)&&tracks!=null){
                    catalog=tracks;saveLibrarySnapshot();checkAutoFavoriteDownloads();if(!full&&!screen.equals("Поиск"))showScreen();
                }});
            }catch(Exception ex){ui.post(()->{if(!isDestroyed()&&client==api&&revision==libraryGeneration&&account.equals(user))status.setText(friendly(ex));});}
        });
        io.execute(()->{
            try{
                JSONObject value=client.request("api/likes");
                JSONArray ids=value.optJSONArray("ids");
                ui.post(()->{if(!isDestroyed()&&client==api&&revision==libraryGeneration&&account.equals(user)&&ids!=null){
                    likes.clear();for(int i=0;i<ids.length();i++)likes.add(ids.optString(i));saveLibrarySnapshot();checkAutoFavoriteDownloads();
                    if(!full&&screen.equals("Избранное"))showScreen();
                }});
            }catch(Exception ignored){}
        });
        io.execute(()->{
            try{
                JSONObject value=client.request("api/playlists");
                JSONArray items=value.optJSONArray("playlists");
                ui.post(()->{if(!isDestroyed()&&client==api&&revision==libraryGeneration&&account.equals(user)&&items!=null){
                    playlists=items;ownedSearchIndex=null;saveLibrarySnapshot();warmPlaylistSearchIndex(items,account,revision);if(!full&&screen.equals("Плейлисты"))showScreen();
                }});
            }catch(Exception ignored){}
        });
    }
    void smokeFixture(String page){try{user="smoke";catalog=new JSONArray();for(int i=0;i<24;i++)catalog.put(new JSONObject().put("id",String.format(java.util.Locale.ROOT,"%032x",i+1)).put("title",i==0?"Очень длинное название трека, которое должно аккуратно поместиться":"Трек "+(i+1)).put("artist","Nightwell Music · Исполнитель"));queue=catalog;playlists=new JSONArray();for(int i=0;i<16;i++)playlists.put(new JSONObject().put("id","fixture"+i).put("name","Мой плейлист "+(i+1)));for(int i=0;i<catalog.length();i++)likes.add(catalog.getJSONObject(i).getString("id"));currentID=catalog.getJSONObject(0).getString("id");miniTitle.setText(catalog.getJSONObject(0).getString("title"));miniArtist.setText("Nightwell Music");if("transfer".equals(page)){nativeTransfer();}else if("menu".equals(page)){head.post(this::menu);}else if("profile".equals(page))profile();else if("player".equals(page))openPlayer();else if("settings".equals(page))settings();else if("settings-playback".equals(page))settingsPage("Воспроизведение");else if("premium-sound".equals(page)||"premium-appearance".equals(page)){premiumOwner=user;premiumUntil=System.currentTimeMillis()+3600000;premiumChecked=System.currentTimeMillis();premiumPrefs=new JSONObject().put("bands",new JSONArray("[0,0,0,0,0]")).put("presets",new JSONObject()).put("theme","nightwell").put("ribbon_speed",1).put("ribbon_intensity",1);if("premium-sound".equals(page))equalizerPanel();else appearancePanel();}else if("wave-settings".equals(page))waveSettings();else if("auth".equals(page))auth();else if("queue".equals(page))showQueue();else if(page!=null)navigate(page);}catch(JSONException e){throw new IllegalStateException(e);}}
    String friendly(Exception error){if(error instanceof java.net.UnknownHostException||error instanceof java.net.ConnectException||error instanceof java.net.SocketTimeoutException)return "Нет соединения. Офлайн-файлы доступны в меню.";String message=error.getMessage();return message!=null&&!message.startsWith("Unable")&&message.length()<180?message:"Не удалось выполнить действие. Повтори попытку.";}
    interface Work{JSONObject run()throws Exception;} interface Done{void run(JSONObject value);}
    void task(Work work,Done done){io.execute(()->{try{JSONObject value=work.run();ui.post(()->{if(!isDestroyed())done.run(value);});}catch(Exception ex){ui.post(()->{if(!isDestroyed())status.setText(friendly(ex));});}});}
    // Fill a small playlist index one by one in a separate executor.
    // Search and all playback requests continue independently.
    private void warmPlaylistSearchIndex(JSONArray list,String owner,long revision){
        final String server=origin;
        playlistIndexer.execute(()->{
            NativeAPI client=new NativeAPI(this,server);
            try{
                for(int i=0;i<Math.min(24,list.length());i++){
                    if(Thread.currentThread().isInterrupted()||isDestroyed()||
                       revision!=libraryGeneration||!owner.equals(user)||!server.equals(origin))return;
                    JSONObject p=list.optJSONObject(i);
                    if(p==null)continue;
                    String id=p.optString("id");
                    if(id.isEmpty())continue;
                    String key="playlist|"+server+"|"+owner+"|"+id;
                    android.content.SharedPreferences prefs=getSharedPreferences("playlist-snapshots",MODE_PRIVATE);
                    if(prefs.contains(key))continue;
                    try{
                        JSONObject payload=client.request("api/playlists/"+
                            java.net.URLEncoder.encode(id,"UTF-8")+"/tracks");
                        JSONArray songs=payload.optJSONArray("tracks");
                        if(songs==null||songs.toString().length()>=750000)continue;
                        prefs.edit().putString(key,songs.toString()).apply();
                        ownedSearchIndex=null;
                        ui.post(()->{
                            if(isDestroyed()||!owner.equals(user)||!screen.equals("Поиск")
                               ||query.trim().length()<2)return;
                            String text=query.trim();
                            JSONArray owned=cachedOwnedTracks();
                            JSONArray local=matchingOwnTracks(text,owned);
                            shown=rankOwnedSearch(concatTracks(local,shown),text,owned);
                            updateList();
                        });
                    }catch(Exception ignored){}
                    try{Thread.sleep(450);}catch(InterruptedException interrupted){
                        Thread.currentThread().interrupt();return;
                    }
                }
            }finally{client.close();}
        });
    }

    private static JSONArray concatTracks(JSONArray... sources){
        JSONArray combined=new JSONArray();
        for(JSONArray list:sources)if(list!=null)
            for(int i=0;i<list.length();i++){
                JSONObject t=list.optJSONObject(i);if(t!=null)combined.put(t);
            }
        return combined;
    }
    // Flatten saved playlist tracks at most once per short search session.
    // Without this, typing each character re-parsed up to 65 large JSON lists.
    private volatile JSONArray ownedSearchIndex;
    private volatile String ownedSearchScope="";
    private volatile long ownedSearchExpires;
    private JSONArray cachedOwnedTracks(){
        String scope=origin+"|"+user+"|"+playlists.length();
        JSONArray memo=ownedSearchIndex;
        if(memo!=null&&scope.equals(ownedSearchScope)&&
            android.os.SystemClock.elapsedRealtime()<ownedSearchExpires)return memo;
        JSONArray result=new JSONArray();
        android.content.SharedPreferences pref=getSharedPreferences("playlist-snapshots",MODE_PRIVATE);
        for(int i=0;i<Math.min(65,playlists.length());i++){
            JSONObject list=playlists.optJSONObject(i);
            if(list==null)continue;
            String raw=pref.getString(playlistSnapshotKey(list.optString("id")),"");
            if(raw.isEmpty())continue;
            try{
                JSONArray stored=new JSONArray(raw);
                for(int j=0;j<Math.min(2000,stored.length());j++){
                    JSONObject track=stored.optJSONObject(j);
                    if(track!=null)result.put(track);
                }
            }catch(JSONException ignored){}
        }
        ownedSearchScope=scope;
        ownedSearchExpires=android.os.SystemClock.elapsedRealtime()+90000;
        ownedSearchIndex=result;
        return result;
    }
    private JSONArray rankOwnedSearch(JSONArray input,String query,JSONArray library){
        Set<String> own=new HashSet<>(likes);
        if(library!=null)for(int i=0;i<library.length();i++){
            JSONObject track=library.optJSONObject(i);
            if(track!=null)own.add(track.optString("id"));
        }
        java.util.LinkedHashMap<String,JSONObject> unique=new java.util.LinkedHashMap<>();
        if(input!=null)for(int i=0;i<input.length();i++){
            JSONObject t=input.optJSONObject(i);
            if(t==null)continue;
            String id=t.optString("id");
            if(!id.isEmpty()&&!unique.containsKey(id))unique.put(id,t);
        }
        java.util.List<JSONObject> ranked=new java.util.ArrayList<>(unique.values());
        // Sorting used to normalize titles and artists on every comparator
        // invocation (O(n log n)). Calculate each relevance score only once.
        java.util.HashMap<String,Integer> scores=new java.util.HashMap<>(ranked.size());
        for(JSONObject item:ranked){
            scores.put(item.optString("id"),RecommendationOrder.searchScore(
                query,item.optString("title"),item.optString("artist")));
        }
        ranked.sort((x,y)->{
            String a=x.optString("id"),b=y.optString("id");
            int owned=Boolean.compare(own.contains(b),own.contains(a));
            if(owned!=0)return owned;
            return Integer.compare(scores.getOrDefault(b,0),scores.getOrDefault(a,0));
        });
        JSONArray out=new JSONArray();
        for(int i=0;i<Math.min(200,ranked.size());i++)out.put(ranked.get(i));
        return out;
    }
    private JSONArray matchingOwnTracks(String query,JSONArray playlistTracks){
        JSONArray values=concatTracks(playlistTracks,catalog);
        JSONArray result=new JSONArray();
        String wanted=RecommendationOrder.key(query);
        String[] words=query.trim().split("\\s+");
        for(int i=0;i<values.length();i++){
            JSONObject item=values.optJSONObject(i);if(item==null)continue;
            String combined=RecommendationOrder.key(item.optString("title")+" "+item.optString("artist"));
            boolean matches=combined.contains(wanted);
            if(!matches&&words.length>1){
                matches=true;
                for(String part:words)if(!combined.contains(RecommendationOrder.key(part))){
                    matches=false;break;
                }
            }
            if(matches)result.put(item);
        }
        return rankOwnedSearch(result,query,playlistTracks);
    }
    private String hiddenRecommendationKey() { return origin + "|" + (user.isEmpty() ? "device" : user); }
    private String recentKey() { return origin + "|" + (user.isEmpty() ? "device" : user); }
    private static String limitedExclusions(java.util.Set<String> values) {
        java.util.List<String> items=new java.util.ArrayList<>(values);
        return android.text.TextUtils.join(",",items.subList(Math.max(0,items.size()-160),items.size()));
    }
    private void restoreRecent() {
        mixRecent.clear();
        String encoded=getSharedPreferences("recommendation-history",MODE_PRIVATE).getString(recentKey(),"[]");
        try {
            JSONArray items=new JSONArray(encoded);
            for(int i=Math.max(0,items.length()-120);i<items.length();i++) {
                String id=items.optString(i);
                if(!id.isEmpty())mixRecent.addLast(id);
            }
        }catch(Exception ignored){}
    }
    private void rememberRecent(String id) {
        if(id.isEmpty())return;
        mixRecent.remove(id);mixRecent.addLast(id);
        while(mixRecent.size()>120)mixRecent.removeFirst();
        getSharedPreferences("recommendation-history",MODE_PRIVATE).edit()
            .putString(recentKey(),new JSONArray(mixRecent).toString()).apply();
    }
    private java.util.Set<String> hiddenArtists() {
        return new java.util.HashSet<>(getSharedPreferences("recommendation-artists",MODE_PRIVATE)
            .getStringSet(hiddenRecommendationKey(),java.util.Collections.emptySet()));
    }
    private boolean isArtistHidden(JSONObject track) {
        return hiddenArtists().contains(RecommendationOrder.key(track.optString("artist")));
    }
    private void toggleArtistHidden(JSONObject track) {
        String normalized=RecommendationOrder.key(track.optString("artist"));
        if(normalized.isEmpty())return;
        java.util.Set<String> artists=hiddenArtists();
        if(!artists.add(normalized))artists.remove(normalized);
        getSharedPreferences("recommendation-artists",MODE_PRIVATE).edit()
            .putStringSet(hiddenRecommendationKey(),artists).apply();
        status.setText(artists.contains(normalized)?"Исполнитель скрыт из подборок":"Исполнитель возвращён в подборки");
    }
    private java.util.Set<String> hiddenRecommendations() {
        return new java.util.HashSet<>(getSharedPreferences("recommendation-hides", MODE_PRIVATE)
            .getStringSet(hiddenRecommendationKey(), java.util.Collections.emptySet()));
    }
    void toggleRecommendationHidden(JSONObject track) {
        java.util.Set<String> hidden = hiddenRecommendations();
        String id = track.optString("id");
        if (id.isEmpty()) return;
        if (!hidden.add(id)) hidden.remove(id);
        getSharedPreferences("recommendation-hides", MODE_PRIVATE).edit()
            .putStringSet(hiddenRecommendationKey(), hidden).apply();
        status.setText(hidden.contains(id) ? "Трек больше не появится в новых подборках" : "Трек снова может появляться в подборках");
    }
    void search(String value) { search(value,0); }
    void search(String value,int attempt) {
        final int gen=++generation;
        api.cancelSearch();
        if(pendingSearch!=null)ui.removeCallbacks(pendingSearch);
        final String text=value.trim();
        if(text.isEmpty()){
            shown=new JSONArray();updateList();
            if(artistStrip!=null)artistStrip.removeAllViews();
            status.setText("");return;
        }
        if(text.length()<2){
            shown=new JSONArray();updateList();
            if(artistStrip!=null)artistStrip.removeAllViews();
            status.setText("Введи ещё один символ");return;
        }
        final String cacheKey=hiddenRecommendationKey()+"|"+text.toLowerCase(java.util.Locale.ROOT);
        final JSONArray cached=attempt==0?searchCache.get(cacheKey):null;
        if(attempt==0) {
            shown=cached==null?new JSONArray():cached;
            updateList();
        }
        pendingSearch=()->{
            status.setText("Ищем полные версии…");
            io.execute(()->{
                if(gen!=generation)return;
                final JSONArray library=cachedOwnedTracks();
                final JSONArray own=matchingOwnTracks(text,library);
                if(attempt==0) {
                    JSONArray quick=rankOwnedSearch(concatTracks(own,cached),text,library);
                    final JSONArray localArtists=localArtistSuggestions(text,quick);
                    ui.post(()->{
                        if(gen==generation&&screen.equals("Поиск")) {
                            shown=quick;updateList();
                            showArtistStrip(localArtists);
                        }
                    });
                }
                try {
                    if(gen!=generation)return;
                    if(attempt==0&&!user.isEmpty()) {
                        // Do not block audio-track search while the artist directory responds.
                        io.execute(()->{
                            try {
                                JSONObject artistData=api.request("api/artists?q="+java.net.URLEncoder.encode(text,"UTF-8")+"&limit=16");
                                JSONArray serverArtists=artistData.optJSONArray("artists");
                                if(serverArtists!=null&&serverArtists.length()>0) {
                                    final JSONArray verified = verifyDirectoryArtists(serverArtists);
                                    ui.post(()->{if(gen==generation&&screen.equals("Поиск"))
                                        showArtistStrip(verified);});
                                }
                            } catch(Exception ignored) { /* Older server: keep local suggestions. */ }
                        });
                    }
                    if(gen!=generation)return;
                    JSONObject found=api.search("api/tracks?q="+java.net.URLEncoder.encode(text,"UTF-8"));
                    if(gen!=generation)return;
                    // Sorting and artist suggestions can take hundreds of milliseconds.
                    // Complete both on the worker before touching the UI.
                    final JSONArray remote=rankOwnedSearch(
                        concatTracks(own,found.optJSONArray("tracks")),text,library);
                    final JSONArray remoteArtists=localArtistSuggestions(text,remote);
                    ui.post(()->{
                        if(gen!=generation||!screen.equals("Поиск"))return;
                        boolean pending=found.optBoolean("search_pending");
                        if(!pending||remote.length()>0) {
                            shown=remote;updateList();
                            showArtistStrip(remoteArtists);
                        }
                        if(!pending)searchCache.put(cacheKey,remote);
                        status.setText(found.optString("search_message",""));
                        if(pending&&attempt<11)ui.postDelayed(()->{
                            if(gen==generation)search(text,attempt+1);
                        },Math.max(1500,Math.min(10000,found.optLong("search_retry_after",2)*1000)));
                    });
                }catch(Exception ex){
                    ui.post(()->{if(gen==generation)status.setText(friendly(ex));});
                }
            });
        };
        ui.postDelayed(pendingSearch,attempt==0?300:0);
    }


    private java.util.List<String> splitArtistNames(String raw) {
        if(!ArtistAttribution.isKnown(raw))return new java.util.ArrayList<>();
        java.util.LinkedHashMap<String,String> artists=new java.util.LinkedHashMap<>();
        if(raw==null)return new java.util.ArrayList<>();
        String prepared=raw.replaceAll("(?i)[(\\[]\\s*(?:feat\\.?|ft\\.?|featuring)\\s+",", ")
            .replaceAll("(?i)\\s+(?:feat\\.?|ft\\.?|featuring|&|×|x)\\s+",", ")
            .replaceAll("[)\\]]","");
        for(String token:prepared.split(",")) {
            String name=token.trim(),key=RecommendationOrder.key(name);
            if(!key.isEmpty()&&!artists.containsKey(key)&&name.length()<160)artists.put(key,name);
            if(artists.size()>=10)break;
        }
        return new java.util.ArrayList<>(artists.values());
    }

    private boolean trackByArtist(JSONObject track,String name) {
        if(track==null)return false;
        String wanted=RecommendationOrder.key(name);
        for(String artist:splitArtistNames(track.optString("artist"))) {
            if(wanted.equals(RecommendationOrder.key(artist)))return true;
        }
        return false;
    }

    private JSONArray localArtistSuggestions(String query,JSONArray tracks) {
        java.util.LinkedHashMap<String,JSONObject> found=new java.util.LinkedHashMap<>();
        String q=RecommendationOrder.key(query);
        if(q.length()<2)return new JSONArray();
        for(int i=0;i<tracks.length()&&found.size()<12;i++) {
            JSONObject track=tracks.optJSONObject(i);
            if(track==null)continue;
            for(String name:splitArtistNames(track.optString("artist"))) {
                String key=RecommendationOrder.key(name);
                if(key.contains(q)&&!found.containsKey(key)) {
                    JSONObject item=new JSONObject();
                    try{item.put("id",key).put("name",name);}catch(JSONException ignored){}
                    found.put(key,item);
                }
            }
        }
        JSONArray values=new JSONArray();for(JSONObject value:found.values())values.put(value);
        return values;
    }

    private JSONArray verifyDirectoryArtists(JSONArray candidates){
        // Called from the IO executor, never from the main/UI thread.
        java.util.HashSet<String> known=new java.util.HashSet<>();
        for(JSONArray list:new JSONArray[]{shown,catalog}){
            if(list==null)continue;
            for(int i=0;i<Math.min(list.length(),2500);i++){
                JSONObject track=list.optJSONObject(i);
                if(track==null)continue;
                for(String artist:splitArtistNames(track.optString("artist")))
                    known.add(RecommendationOrder.key(artist));
            }
        }
        JSONArray verified=new JSONArray();
        for(int i=0;i<Math.min(candidates.length(),16);i++){
            JSONObject candidate=candidates.optJSONObject(i);
            if(candidate==null)continue;
            if("nightwell".equals(candidate.optString("source"))&&
               !known.contains(RecommendationOrder.key(candidate.optString("name"))))continue;
            verified.put(candidate);
        }
        return verified;
    }

    private void showArtistStrip(JSONArray artists) {
        if(artistStrip==null||!screen.equals("Поиск"))return;
        artistStrip.removeAllViews();
        if(artists==null||artists.length()==0)return;
        TextView heading=text("Исполнители",15);
        heading.setPadding(dp(2),dp(12),0,dp(8));
        artistStrip.addView(heading);
        HorizontalScrollView scroll=new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        LinearLayout row=row();row.setGravity(Gravity.CENTER_VERTICAL);
        for(int i=0;i<Math.min(16,artists.length());i++) {
            JSONObject item=artists.optJSONObject(i);
            if(item==null)continue;
            String name=item.optString("name").trim(),url=item.optString("image_url");
            if(!ArtistAttribution.isKnown(name))continue;
            // Older artist-directory APIs can list remote posting accounts. Never expose
            // such a directory entry unless a normalized track really credits that name.
            LinearLayout chip=row();chip.setGravity(Gravity.CENTER_VERTICAL);
            chip.setPadding(dp(10),dp(6),dp(12),dp(6));
            chip.setBackground(touchSurface(0x553a3a42,22));
            TextView initial=text(name.substring(0,1).toUpperCase(java.util.Locale.ROOT),14);
            initial.setGravity(Gravity.CENTER);
            initial.setBackground(touchSurface(0x6635353c,14));
            chip.addView(initial,new LinearLayout.LayoutParams(dp(29),dp(29)));
            if(url.startsWith("https://")&&artworkCache!=null) {
                ImageView image=new ImageView(this);
                image.setScaleType(ImageView.ScaleType.CENTER_CROP);
                image.setBackground(touchSurface(0x6635353c,14));
                image.setClipToOutline(true);
                chip.removeView(initial);
                chip.addView(image,new LinearLayout.LayoutParams(dp(29),dp(29)));
                artworkCache.loadArtist(image,url);
            }
            TextView label=text(name,13);label.setSingleLine(true);label.setMaxWidth(dp(145));
            label.setEllipsize(android.text.TextUtils.TruncateAt.END);
            label.setPadding(dp(8),0,0,0);
            chip.addView(label);
            chip.setOnClickListener(v->openArtistProfile(name));
            LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-2,dp(42));
            params.rightMargin=dp(8);
            row.addView(chip,params);
        }
        scroll.addView(row);
        artistStrip.addView(scroll);
    }

    private void chooseArtist(String raw) {
        if(!ArtistAttribution.isKnown(raw))return;
        java.util.List<String> artists=splitArtistNames(raw);
        if(artists.isEmpty())return;
        if(artists.size()==1){openArtistProfile(artists.get(0));return;}
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Выбери исполнителя")
            .setItems(artists.toArray(new String[0]),(d,index)->openArtistProfile(artists.get(index)))
            .create();
        styleSheet(dialog);dialog.show();
    }

    private void openArtistProfile(String name) {
        final String artistName=name.trim();
        if(artistName.isEmpty())return;
        LinearLayout content=column();
        content.setPadding(dp(18),dp(16),dp(18),dp(14));
        LinearLayout top=row();top.setGravity(Gravity.CENTER_VERTICAL);
        android.widget.FrameLayout portrait=new android.widget.FrameLayout(this);
        TextView initial=text(artistName.substring(0,1).toUpperCase(java.util.Locale.ROOT),28);
        initial.setGravity(Gravity.CENTER);
        initial.setBackground(touchSurface(0x6635353c,32));
        portrait.addView(initial,new android.widget.FrameLayout.LayoutParams(dp(70),dp(70)));
        ImageView photo=new ImageView(this);
        photo.setScaleType(ImageView.ScaleType.CENTER_CROP);
        photo.setClipToOutline(true);
        photo.setBackground(touchSurface(0x1135353c,32));
        portrait.addView(photo,new android.widget.FrameLayout.LayoutParams(dp(70),dp(70)));
        top.addView(portrait,new LinearLayout.LayoutParams(dp(70),dp(70)));
        TextView title=text(artistName,22);
        title.setTypeface(null,android.graphics.Typeface.BOLD);
        title.setPadding(dp(14),0,0,0);
        top.addView(title,new LinearLayout.LayoutParams(0,-2,1));
        content.addView(top);
        TextView info=text("Загружаем треки…",13);
        info.setTextColor(0xffbcbec8);info.setPadding(0,dp(15),0,dp(10));
        content.addView(info);
        LinearLayout songs=column();content.addView(songs);
        ScrollView scroll=new ScrollView(this);scroll.addView(content);
        AlertDialog dialog=new AlertDialog.Builder(this).setView(scroll)
            .setNegativeButton("Закрыть",(d,w)->{}).create();
        styleSheet(dialog);dialog.show();
        String owner=user;
        io.execute(()->{
            JSONObject profile=null;
            JSONArray candidates=null;
            try {
                String encoded=java.net.URLEncoder.encode(artistName,"UTF-8");
                try {
                    profile=api.request("api/artists/profile?name="+encoded);
                    candidates=profile.optJSONArray("tracks");
                }catch(Exception ex){
                    // Older server may not have this route.
                }
                boolean anyCredited=false;
                if(candidates!=null)for(int i=0;i<candidates.length();i++){
                    JSONObject item=candidates.optJSONObject(i);
                    if(trackByArtist(item,artistName)){anyCredited=true;break;}
                }
                if(!anyCredited){
                    // Old directory indexed the uploader. Do not use its avatar/count.
                    profile=null;
                    JSONObject fallback=api.request("api/tracks?q="+encoded);
                    candidates=fallback.optJSONArray("tracks");
                }
            } catch(Exception ex) {}
            JSONArray filtered=new JSONArray();
            if(candidates!=null)for(int i=0;i<candidates.length()&&filtered.length()<250;i++){
                JSONObject track=candidates.optJSONObject(i);
                if(trackByArtist(track,artistName))filtered.put(track);
            }
            final JSONArray finalTracks=filtered;
            final JSONObject finalProfile=profile;
            ui.post(()->{
                if(!dialog.isShowing()||!owner.equals(user))return;
                JSONObject artist=finalProfile==null?null:finalProfile.optJSONObject("artist");
                if(artist!=null) {
                    String url=artist.optString("image_url");
                    if(artworkCache!=null)artworkCache.loadArtist(photo,url);
                }
                int total=finalProfile==null?finalTracks.length():finalProfile.optInt("total",finalTracks.length());
                info.setText(total==0?"Треки пока не найдены":"Треки · "+total);
                for(int i=0;i<finalTracks.length();i++) {
                    JSONObject track=finalTracks.optJSONObject(i);
                    if(track==null)continue;
                    TextView line=text(track.optString("title"),15);
                    line.setPadding(dp(12),dp(12),dp(12),dp(12));
                    line.setBackground(touchSurface(0x222f3035,16));
                    LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,-2);
                    params.bottomMargin=dp(6);
                    line.setOnClickListener(v->{dialog.dismiss();play(track,finalTracks,false);});
                    songs.addView(line,params);
                }
            });
        });
    }

    void play(JSONObject track,JSONArray tracks,boolean wave){
        play(track,tracks,wave,new JSONArray());
    }
    void play(JSONObject track,JSONArray tracks,boolean wave,JSONArray seedArtists){if(track==null)return;if(user.isEmpty()&&!track.optBoolean("_offline")){auth();return;}if(playback==null){status.setText("Аудиоплеер запускается. Повтори через секунду.");return;}try{cancelMix();playback.prepare(new JSONObject().put("id",track.getString("id")).put("queue",tracks).put("origin",origin).put("account",user.isEmpty()?"device":user).put("wave",wave).put("wave_seed_artists",seedArtists)
            .put("wave_preferences",WaveSettings.read(this,origin,user).json()).toString());if(playback.player.getCurrentMediaItem()==null||!track.getString("id").equals(playback.player.getCurrentMediaItem().mediaId)){status.setText("Аудиофайл недоступен. Открой «Офлайн» и скачай его снова.");return;}playback.play();updatePlayback();publishLive(true);}catch(Exception ex){status.setText(friendly(ex));}}
    void toggle(){cancelMix();if(playback!=null){if(playback.player.getPlayWhenReady())playback.pause();else playback.play();updatePlayback();if(liveOwner)publishLive(false);}}
    private long lastPrevious;private String previousID="";
    void nextTrack(){trackTransitionDirection=1;cancelMix();if(playback!=null)playback.requestPreparedNext();}
    void previous(){trackTransitionDirection=-1;cancelMix();if(playback==null)return;long now=SystemClock.uptimeMillis();if(playback.player.getCurrentPosition()>3000&&!(currentID.equals(previousID)&&now-lastPrevious<3000)){previousID=currentID;lastPrevious=now;playback.seek(0);}else{previousID="";playback.player.seekToPreviousMediaItem();}}
    void waveSettings(){
        if(user.isEmpty()){auth();return;}
        final String account=user;
        WaveSettings draft=WaveSettings.read(this,origin,account);
        LinearLayout panel=column();panel.setPadding(dp(20),dp(10),dp(20),dp(14));
        TextView hint=text("Выбери, что хочется услышать сейчас",15);hint.setTextColor(0xffd0d0d0);hint.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);panel.addView(hint);
        TextView caption=text("Удерживай «Новая подборка», чтобы быстро открыть это окно прямо с главного экрана.",13);caption.setTextColor(0xff9ea6b9);caption.setPadding(0,dp(4),0,dp(8));panel.addView(caption);
        final Runnable[] render={null};
        render[0]=()->{
            while(panel.getChildCount()>2)panel.removeViewAt(2);
            for(int group=0;group<3;group++){
                final int section=group;TextView title=text(WaveSettings.TITLES[group],15);title.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);title.setTextColor(0xfff2f2f6);title.setPadding(0,dp(10),0,dp(5));panel.addView(title);
                for(int start=0;start<WaveSettings.VALUES[group].length;start+=2){LinearLayout line=row();
                    for(int option=start;option<Math.min(start+2,WaveSettings.VALUES[group].length);option++){
                        final int choice=option;boolean checked=draft.selected[section]==choice;
                        TextView chip=action((checked?"✓  ":"")+WaveSettings.LABELS[section][choice],()->{draft.selected[section]=choice;render[0].run();});
                        chip.setTextSize(13);chip.setTextColor(checked?0xff201914:0xfff0e7f7);GradientDrawable chipFill=new GradientDrawable();chipFill.setCornerRadius(dp(24));chipFill.setColor(checked?0xffeeeeee:0xaa282c35);chipFill.setStroke(dp(1),checked?0x4dfff0d0:0x20ffffff);chip.setBackground(chipFill);chip.setSelected(checked);
                        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(0,dp(44),1);params.setMargins(dp(3),dp(3),dp(3),dp(3));line.addView(chip,params);
                    }panel.addView(line);
                }
            }
            TextView note=text("Настроение и язык определяются по описанию треков и могут совпадать не точно.",12);note.setTextColor(0xffaaaaaa);note.setPadding(0,dp(8),0,0);panel.addView(note);
        };render[0].run();
        android.widget.ScrollView scroll=new android.widget.ScrollView(this);scroll.addView(panel);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Настроить подборку").setView(scroll).setPositiveButton("Применить",null).setNeutralButton("Сбросить",null).setNegativeButton("Отмена",null).create();
        styleSheet(dialog);dialog.show();
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v->{java.util.Arrays.fill(draft.selected,0);render[0].run();});
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
            task(()->{try{JSONObject result=api.request("api/wave-options");if(result.optInt("version")<1)throw new java.io.IOException();return result;}catch(Exception error){ui.post(()->{if(dialog.isShowing())dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true);});throw new java.io.IOException("Для настроек подборки нужно обновить сервер Nightwell Music.");}},value->{
                if(!account.equals(user)||isDestroyed())return;
                cancelMix();draft.save(this,origin,account);dialog.dismiss();wave();
            });
        });
    }
    void cancelMix(){waveRequest.cancel();mixing=false;}
    void wave(){
        if(mixing)return;if(user.isEmpty()){auth();return;}
        final NativeAPI client=new NativeAPI(this,origin);
        final long ticket=waveRequest.start(client::close);
        final String account=user,playingID=currentID;
        final WaveSettings settings=WaveSettings.read(this,origin,account);
        final java.util.Set<String> hidden=hiddenRecommendations();
        hidden.addAll(SkipFeedback.recentIDs(this,origin,account));
        final java.util.Set<String> blockedArtists=hiddenArtists();
        mixing=true;status.setText("Подбираем…");
        final java.util.LinkedHashSet<String> excluded=new java.util.LinkedHashSet<>(mixRecent);
        for(int i=0;i<Math.min(8,queue.length());i++)excluded.add(queue.optJSONObject(i).optString("id"));
        if(!playingID.isEmpty())excluded.add(playingID);
        java.util.List<String> hiddenForServer=new java.util.ArrayList<>(hidden);
        java.util.Collections.sort(hiddenForServer);
        for(int i=0;i<Math.min(hiddenForServer.size(),80);i++)excluded.add(hiddenForServer.get(i));
        final java.util.Set<String> recentForRank=new java.util.HashSet<>(mixRecent);
        waveIO.execute(()->{
            try{
                if(!waveRequest.pending(ticket))return;
                String nonce=UUID.randomUUID().toString();
                JSONObject value=client.search("api/wave?mix="+nonce+settings.query()+"&exclude="+java.net.URLEncoder.encode(limitedExclusions(excluded),"UTF-8"));
                JSONArray raw=value.optJSONArray("tracks");
                if((raw==null||raw.length()==0)&&!playingID.isEmpty())raw=client.search("api/wave?mix="+nonce+settings.query()+"&exclude="+playingID).optJSONArray("tracks");
                final JSONArray fresh=new JSONArray();
                if(raw!=null)for(int i=0;i<raw.length();i++)if(!playingID.equals(raw.optJSONObject(i).optString("id"))&&!hidden.contains(raw.optJSONObject(i).optString("id")))fresh.put(raw.optJSONObject(i));
                // Sort and deduplicate on the recommendation worker.
                final JSONArray ordered=new JSONArray();
                if(fresh.length()>0){
                    java.util.List<JSONObject> candidates=new java.util.ArrayList<>();
                    for(int i=0;i<fresh.length();i++)candidates.add(fresh.optJSONObject(i));
                    for(JSONObject track:RecommendationOrder.arrange(
                            candidates,recentForRank,hidden,blockedArtists,playingID,
                            t->t.optString("id"),t->t.optString("title"),t->t.optString("artist")))
                        ordered.put(track);
                }
                ui.post(()->{
                    if(isDestroyed()||!waveRequest.complete(ticket))return;
                    mixing=false;
                    if(!account.equals(user))return;
                    if(ordered.length()>0){
                        status.setText("");play(ordered.optJSONObject(0),ordered,true);
                    }else status.setText(fresh.length()>0
                        ?"Все найденные треки скрыты фильтрами рекомендаций."
                        :"Новых треков пока нет. Попробуй чуть позже.");
                });
            }catch(Exception e){ui.post(()->{if(isDestroyed()||!waveRequest.complete(ticket))return;mixing=false;status.setText(friendly(e));});}
            finally{client.close();}
        });
    }

    void setLabel(TextView view,String value){if(view!=null&&!android.text.TextUtils.equals(view.getText(),value))view.setText(value);}
    void updatePlayback(){if(smokeMode||playback==null)return;try{JSONObject state=new JSONObject(playback.snapshot(false));String next=state.optString("id");boolean trackChanged=!currentID.equals(next);boolean queueChanged=trackChanged||queue==null||queue.length()!=state.optInt("queueCount");if(queueChanged){queue=new JSONObject(playback.snapshot(true)).optJSONArray("queueTracks");}if(queue==null)queue=new JSONArray();JSONObject t=null;if(queueChanged){for(int i=0;i<queue.length();i++){JSONObject item=queue.optJSONObject(i);if(item!=null&&next.equals(item.optString("id"))){t=item;break;}}setLabel(miniTitle,t==null?"Выбери трек":t.optString("title"));setLabel(miniArtist,t==null?"Nightwell Music":t.optString("artist"));}if(miniProgress!=null){double fraction=state.optBoolean("nextPreparing")?state.optDouble("preparationFraction"):state.optDouble("position")/Math.max(1,state.optDouble("duration"));miniProgress.setLevel((int)Math.max(0,Math.min(10000,10000*fraction)));}setLabel(miniPlay,state.optBoolean("playing")?"Ⅱ":"▶");if(homePlay!=null)setLabel(homePlay,state.optBoolean("playing")?"Ⅱ":"▶");if(fullPlay!=null)setLabel(fullPlay,state.optBoolean("playing")?"Ⅱ":"▶");if(ribbon!=null)ribbon.playing(state.optBoolean("playing"));if(trackChanged){currentID=next;refreshFavoriteButtons();if(!next.isEmpty()){rememberRecent(next);checkTrackAudioQuality(t);prefetchClip(t);}activeLyrics=null;homeLine="";homeWord=-2;homeKineticSpans.clear();if(homeLyric!=null)homeLyric.setText("");loadMiniCover(t);fetchLyricsAndPreload();animateTrackTransition();updateList();if(full)openPlayer();}if(seek!=null&&!seek.isPressed()){int duration=(int)Math.max(1,state.optDouble("duration"));seek.setMax(duration);seek.setProgress((int)state.optDouble("position"));seek.setSecondaryProgress((int)(duration*state.optDouble("bufferFraction")));}if(fullTime!=null)setLabel(fullTime,time(state.optDouble("position"))+"     /     "+time(state.optDouble("duration")));if(!state.optString("error").isEmpty())status.setText(state.optString("error"));syncLyrics(state.optDouble("position"));syncHomeLyrics(state.optDouble("position"));if(lastPlaying!=state.optBoolean("playing")){lastPlaying=state.optBoolean("playing");updateList();}}catch(Exception ignored){}}
    void animateTrackTransition(){
        if(dock==null||!dock.isShown())return;
        final float slide=dp(24)*trackTransitionDirection;
        for(View view:new View[]{miniCover,miniTitle,miniArtist}){
            if(view==null)continue;
            view.animate().cancel();
            view.setAlpha(.25f);
            view.setTranslationX(slide);
            view.animate().translationX(0).alpha(1f).setDuration(340)
                .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
        }
    }
    String time(double seconds){int v=Math.max(0,(int)seconds);return String.format(java.util.Locale.ROOT,"%d:%02d",v/60,v%60);}
    JSONObject current(){for(int i=0;i<queue.length();i++)if(queue.optJSONObject(i).optString("id").equals(currentID))return queue.optJSONObject(i);return null;}
    String iconLabel(String icon){switch(icon){case "⌕":return "Поиск музыки";case "☰":return "Открыть меню";case "⋯":return "Действия с треком";case "⌄":return "Свернуть плеер";case "×":return "Закрыть";case "|‹":return "Предыдущий трек";case "›|":return "Следующий трек";case "♡":case "♥":return "Избранное";case "⇄":return "Перемешать";case "↻":return "Повтор";default:return "Воспроизведение";}}
    void openPlayer(){
        JSONObject track=current();if(track==null)return;prefetchClip(track);full=true;
        if(landscapeRail!=null)landscapeRail.setVisibility(View.GONE);if(atmosphere!=null)atmosphere.setVisibility(View.GONE);if(ribbon!=null){ribbon.running(false);ribbon.setVisibility(View.GONE);}dock.setVisibility(View.GONE);head.setVisibility(View.GONE);body.removeAllViews();
        LinearLayout top=row();
        TextView close=iconButton("⌄",()->{full=false;build();});
        top.addView(close,new LinearLayout.LayoutParams(dp(48),dp(48)));
        LinearLayout center=column();center.setGravity(Gravity.CENTER);
        fullAudioOutput=text("♫  "+audioOutputName()+"  ⌄",12);
        fullAudioOutput.setGravity(Gravity.CENTER);
        fullAudioOutput.setSingleLine(true);
        fullAudioOutput.setEllipsize(android.text.TextUtils.TruncateAt.END);
        fullAudioOutput.setPadding(dp(10),0,dp(10),0);
        fullAudioOutput.setMinHeight(0);
        fullAudioOutput.setBackground(touchSurface(0x6620222b,16));
        fullAudioOutput.setContentDescription("Устройство вывода: "+audioOutputName()+". Изменить");
        fullAudioOutput.setOnClickListener(v->chooseAudioOutput());
        LinearLayout.LayoutParams routeParams=new LinearLayout.LayoutParams(-2,dp(30));
        routeParams.gravity=Gravity.CENTER_HORIZONTAL;
        center.addView(fullAudioOutput,routeParams);
        TextView caption=text("СЕЙЧАС ИГРАЕТ",11);caption.setLetterSpacing(.16f);caption.setTextColor(0xffc4c5cc);
        caption.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams captionParams=new LinearLayout.LayoutParams(-1,dp(24));
        center.addView(caption,captionParams);
        top.addView(center,new LinearLayout.LayoutParams(0,dp(50),1));
        top.addView(iconButton("⋯",()->fullPlayerMenu(track)),new LinearLayout.LayoutParams(dp(48),dp(48)));
        body.addView(top);
        android.widget.ScrollView scroll=new android.widget.ScrollView(this);scroll.setFillViewport(true);scroll.setClipToPadding(false);LinearLayout content=column();content.setPadding(dp(2),dp(6),dp(2),dp(18));scroll.addView(content);body.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        boolean landscapePlayer=getResources().getConfiguration().orientation==
            android.content.res.Configuration.ORIENTATION_LANDSCAPE;
        LinearLayout details=content;
        if(landscapePlayer){
            LinearLayout split=row();split.setGravity(Gravity.TOP);
            content.addView(split,new LinearLayout.LayoutParams(-1,-2));
            LinearLayout artworkColumn=column();artworkColumn.setGravity(Gravity.TOP);
            split.addView(artworkColumn,new LinearLayout.LayoutParams(0,-2,0.46f));
            details=column();
            details.setPadding(dp(8),0,dp(8),0);
            split.addView(details,new LinearLayout.LayoutParams(0,-2,0.54f));
            addCover(track,artworkColumn);
        }else addCover(track,content);
        LinearLayout metadata=row();metadata.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout names=column();
        TextView title=text(track.optString("title"),23);title.setMaxLines(2);title.setLetterSpacing(-.025f);title.setLineSpacing(dp(2),1f);title.setAutoSizeTextTypeUniformWithConfiguration(18,23,1,android.util.TypedValue.COMPLEX_UNIT_SP);title.setEllipsize(android.text.TextUtils.TruncateAt.END);title.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);title.setPadding(dp(2),dp(12),dp(4),dp(6));names.addView(title);
        TextView artist=text(track.optString("artist")+"  ›",14);artist.setTextColor(0xffd3d3da);artist.setMaxLines(2);artist.setEllipsize(android.text.TextUtils.TruncateAt.END);artist.setPadding(dp(6),dp(4),dp(6),dp(4));artist.setBackground(null);artist.setOnClickListener(v->chooseArtist(track.optString("artist")));artist.setContentDescription("Открыть исполнителя");names.addView(artist);
        metadata.addView(names,new LinearLayout.LayoutParams(0,-2,1));
        fullLike=iconButton(likes.contains(track.optString("id"))?"♥":"♡",()->toggleFavorite(current()));
        fullLike.setContentDescription(likes.contains(track.optString("id"))?"Убрать из избранного":"Добавить в избранное");
        fullLike.setTextColor(likes.contains(track.optString("id"))?0xffeeeeee:0xffa4a6b1);
        LinearLayout.LayoutParams likeParams=new LinearLayout.LayoutParams(dp(48),dp(48));
        likeParams.setMargins(dp(4),0,dp(0),0);
        fullDislike=iconButton("⊖",()->{
            JSONObject selected=current();
            if(selected==null)return;
            toggleRecommendationHidden(selected);
            if(fullDislike!=null){
                boolean hidden=hiddenRecommendations().contains(selected.optString("id"));
                fullDislike.setAlpha(hidden?1f:.55f);
                fullDislike.setContentDescription(hidden?"Вернуть в рекомендации":"Не рекомендовать");
            }
        });
        boolean hidden=hiddenRecommendations().contains(track.optString("id"));
        fullDislike.setAlpha(hidden?1f:.55f);
        fullDislike.setTextColor(0xffd4d5db);
        fullDislike.setTextSize(23);
        fullDislike.setContentDescription(hidden?"Вернуть в рекомендации":"Не рекомендовать");
        metadata.addView(fullDislike,new LinearLayout.LayoutParams(dp(44),dp(48)));
        metadata.addView(fullLike,likeParams);
        LinearLayout.LayoutParams metadataParams=new LinearLayout.LayoutParams(-1,-2);
        metadataParams.bottomMargin=dp(4);
        details.addView(metadata,metadataParams);
        LinearLayout transport=column();
        transport.setPadding(dp(4),dp(6),dp(4),dp(5));
        transport.setBackground(null);
        transport.setClipChildren(false);
        transport.setClipToPadding(false);
        LinearLayout.LayoutParams transportParams=new LinearLayout.LayoutParams(-1,-2);
        transportParams.topMargin=dp(isLandscapeLayout()?5:13);
        details.addView(transport,transportParams);
        seek=new SeekBar(this);seek.setMinimumHeight(dp(44));seek.setProgressTintList(android.content.res.ColorStateList.valueOf(0xfff0f0f0));seek.setSecondaryProgressTintList(android.content.res.ColorStateList.valueOf(0x88c6c9d0));seek.setProgressBackgroundTintList(android.content.res.ColorStateList.valueOf(0x333b3d43));android.graphics.drawable.GradientDrawable tinyThumb=new android.graphics.drawable.GradientDrawable();tinyThumb.setShape(android.graphics.drawable.GradientDrawable.OVAL);tinyThumb.setColor(0xfff8f8f8);tinyThumb.setStroke(dp(1),0x88ffffff);tinyThumb.setSize(dp(8),dp(8));seek.setThumb(tinyThumb);seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onProgressChanged(SeekBar b,int p,boolean user){}public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){cancelMix();if(playback!=null)playback.seek(b.getProgress());}});transport.addView(seek);fullTime=text("",12);fullTime.setPadding(dp(5),0,dp(5),dp(5));fullTime.setTextColor(0xffc8c8c8);transport.addView(fullTime);
        LinearLayout controls=row();controls.setGravity(Gravity.CENTER);
        TextView shuffleButton=iconButton("⇄",()->{
            if(playback==null)return;
            int next=(playback.shuffleMode+1)%3;
            playback.setShuffleMode(next);
            if(fullShuffle!=null){
                fullShuffle.setText(next==2?"⇄✦":"⇄");
                fullShuffle.setTextColor(next==0?0xff999ba6:0xffeeeeee);
                fullShuffle.setContentDescription(new String[]{"Перемешивание выключено","Обычное перемешивание","Умное перемешивание"}[next]);
            }
        });
        fullShuffle=shuffleButton;
        int activeShuffle=playback==null?0:playback.shuffleMode;
        shuffleButton.setText(activeShuffle==2?"⇄✦":"⇄");
        shuffleButton.setTextColor(activeShuffle==0?0xff999ba6:0xffeeeeee);
        shuffleButton.setContentDescription(new String[]{"Перемешивание выключено","Обычное перемешивание","Умное перемешивание"}[activeShuffle]);
        TextView backward=iconButton("|‹",this::previous);
        fullPlay=iconButton(playback!=null&&playback.player.getPlayWhenReady()?"Ⅱ":"▶",this::toggle);
        TextView forward=iconButton("›|",this::nextTrack);
        TextView repeatButton=iconButton("↻",()->{if(playback!=null)playback.setRepeat((playback.player.getRepeatMode()==androidx.media3.common.Player.REPEAT_MODE_ONE?0:
            playback.player.getRepeatMode()==androidx.media3.common.Player.REPEAT_MODE_ALL?2:1));});
        for(TextView button:new TextView[]{shuffleButton,backward,forward,repeatButton}){
            button.setBackground(null);button.setPadding(0,0,0,0);button.setTextSize(25);
        }
        backward.setTextSize(31);forward.setTextSize(31);
        fullPlay.setTextColor(0xffeeeeee);fullPlay.setTextSize(30);
        GradientDrawable playSurface=new GradientDrawable();
        playSurface.setColor(0xfff3f3f5);
        playSurface.setCornerRadius(dp(34));
        android.graphics.drawable.RippleDrawable playRipple=new android.graphics.drawable.RippleDrawable(
            android.content.res.ColorStateList.valueOf(0x33000000),playSurface,null);
        fullPlay.setBackground(playRipple);
        fullPlay.setTextColor(0xff16171a);
        fullPlay.setElevation(dp(4));
        fullPlay.setPadding(0,0,0,0);
        controls.addView(shuffleButton,new LinearLayout.LayoutParams(0,dp(56),1));
        controls.addView(backward,new LinearLayout.LayoutParams(0,dp(59),1));
        LinearLayout.LayoutParams centerPlay=new LinearLayout.LayoutParams(dp(66),dp(66));
        centerPlay.leftMargin=dp(2);centerPlay.rightMargin=dp(2);
        controls.addView(fullPlay,centerPlay);
        controls.addView(forward,new LinearLayout.LayoutParams(0,dp(59),1));
        controls.addView(repeatButton,new LinearLayout.LayoutParams(0,dp(56),1));
        transport.addView(controls);
        TextView queueButton=action("Объёмная очередь  ·  "+queue.length()+"   ›",this::showQueue);
        queueButton.setTextSize(13);
        queueButton.setTextColor(0xffc1c4ce);
        queueButton.setMinHeight(dp(43));
        queueButton.setPadding(dp(8),dp(9),dp(8),dp(7));
        queueButton.setBackground(null);
        LinearLayout.LayoutParams queueParams=new LinearLayout.LayoutParams(-1,dp(46));
        queueParams.topMargin=dp(10);
        transport.addView(queueButton,queueParams);
        if(android.animation.ValueAnimator.areAnimatorsEnabled()){
            content.setAlpha(0f);
            content.setTranslationY(dp(10));
            content.animate().alpha(1f).translationY(0f).setDuration(270)
                .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
        }
        updatePlayback();
    }
    void loadMiniCover(JSONObject track) {
        if (miniCover == null || artworkCache == null) return;
        artworkCache.load(miniCover,origin,track==null?"":track.optString("cover_url"));
    }
    void addCover(JSONObject track,LinearLayout parent) {
        boolean classic="classic".equals(getSharedPreferences("appearance",MODE_PRIVATE)
            .getString("nw-cover-style","immersive"));
        boolean landscape=getResources().getConfiguration().orientation==
            android.content.res.Configuration.ORIENTATION_LANDSCAPE;
        int width=getResources().getConfiguration().screenWidthDp;
        int height=getResources().getConfiguration().screenHeightDp;
        // A cover must not push playback controls outside the viewport.
        // Immersive remains broad, while classic has wider side margins.
        int preferred=classic?width-54:width-20;
        int maxByHeight=(int)(height*(landscape?.66f:.43f));
        int side=landscape?Math.min(width/2-26,height-120):
            Math.min(preferred,maxByHeight);
        side=Math.max(145,Math.min(side,380));
        android.widget.FrameLayout artwork=new android.widget.FrameLayout(this);
        GradientDrawable backdrop=new GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            new int[]{0xff4b4e55,0xff292b31,0xff131418});
        backdrop.setCornerRadius(dp(classic?23:25));
        backdrop.setStroke(dp(1),0x4cffffff);
        artwork.setBackground(backdrop);
        artwork.setClipToOutline(true);
        artwork.setElevation(dp(7));
        TextView placeholder=text("N",94);
        placeholder.setGravity(Gravity.CENTER);
        placeholder.setTypeface(android.graphics.Typeface.create("sans-serif-black",0));
        placeholder.setTextColor(0x25ffffff);
        placeholder.setContentDescription("Обложка Nightwell Music");
        artwork.addView(placeholder,new android.widget.FrameLayout.LayoutParams(-1,-1));
        android.widget.ImageView cover=classic
            ?new android.widget.ImageView(this):new NightwellMotionCover(this);
        cover.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
        cover.setBackgroundColor(Color.TRANSPARENT);
        android.view.GestureDetector detector=gestures(true);
        cover.setOnTouchListener((view,event)->detector.onTouchEvent(event));
        artwork.addView(cover,new android.widget.FrameLayout.LayoutParams(-1,-1));
        LinearLayout.LayoutParams layout=new LinearLayout.LayoutParams(dp(side),dp(side));
        layout.gravity=Gravity.CENTER_HORIZONTAL;
        layout.topMargin=dp(7);
        layout.bottomMargin=dp(13);
        parent.addView(artwork,layout);
        if(artworkCache!=null)artworkCache.load(cover,origin,track.optString("cover_url"));
    }
    String[] trackNames(JSONArray items){String[] names=new String[items.length()];for(int i=0;i<names.length;i++)names[i]=items.optJSONObject(i).optString("title");return names;}
    JSONObject cachedLyrics(String id)throws Exception {
        // Application files survive automatic cache eviction. The name is
        // scoped by server and hashed so provider IDs cannot escape the folder.
        java.security.MessageDigest digest=java.security.MessageDigest.getInstance("SHA-256");
        byte[] raw=digest.digest((origin+"|"+id).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        StringBuilder key=new StringBuilder();
        for(byte b:raw)key.append(String.format(java.util.Locale.ROOT,"%02x",b&0xff));
        java.io.File root=new java.io.File(getFilesDir(),"native-lyrics");
        if(!root.isDirectory()&&!root.mkdirs())throw new java.io.IOException("No lyrics storage");
        java.io.File file=new java.io.File(root,key+".json");
        if(file.isFile()&&file.length()>0&&file.length()<1024*1024){
            try{
                JSONObject saved=new JSONObject(new String(java.nio.file.Files.readAllBytes(
                    file.toPath()),java.nio.charset.StandardCharsets.UTF_8));
                if("found".equals(saved.optString("status"))||"instrumental".equals(saved.optString("status")))
                    return saved;
            }catch(Exception ignored){}
        }
        // Migrate the former purgeable 30-day cache without requiring network.
        if(id.matches("[A-Za-z0-9_-]{1,80}")){
            java.io.File legacy=new java.io.File(new java.io.File(getCacheDir(),"native-lyrics"),id+".json");
            if(legacy.isFile()&&legacy.length()>0&&legacy.length()<1024*1024)try{
                JSONObject saved=new JSONObject(new String(java.nio.file.Files.readAllBytes(
                    legacy.toPath()),java.nio.charset.StandardCharsets.UTF_8));
                if("found".equals(saved.optString("status"))||"instrumental".equals(saved.optString("status"))){
                    java.nio.file.Files.write(file.toPath(),saved.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
                    return saved;
                }
            }catch(Exception ignored){}
        }
        JSONObject value=api.request("api/lyrics/"+id);
        if("found".equals(value.optString("status"))||"instrumental".equals(value.optString("status"))){
            // Keep the entire JSON, including line/word timestamps and plain
            // lyric text. Do not replace a richer saved version with less data.
            if(file.isFile())try{
                JSONObject previous=new JSONObject(new String(java.nio.file.Files.readAllBytes(
                    file.toPath()),java.nio.charset.StandardCharsets.UTF_8));
                if(value.optJSONArray("lines")==null&&previous.optJSONArray("lines")!=null)
                    value.put("lines",previous.getJSONArray("lines")).put("synced",true);
                if(value.optString("plain").isEmpty()&&!previous.optString("plain").isEmpty())
                    value.put("plain",previous.optString("plain"));
            }catch(Exception ignored){}
            byte[] bytes=value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
            if(bytes.length<1024*1024)java.nio.file.Files.write(file.toPath(),bytes);
        }
        return value;
    }
    boolean lyricsPending(JSONObject value){String state=value.optString("status");return state.equals("loading")||state.equals("pending")||state.equals("unavailable");}
    void fetchLyricsAndPreload(){final String id=currentID;if(id.isEmpty())return;final JSONArray upcoming=new JSONArray();for(int i=0;i<queue.length();i++)if(queue.optJSONObject(i).optString("id").equals(id)){for(int j=i+1;j<Math.min(queue.length(),i+13);j++)upcoming.put(queue.optJSONObject(j).optString("id"));break;}
        if(artworkCache!=null) {
            int warmed=0;
            for(int i=0;i<queue.length()&&warmed<3;i++) {
                JSONObject next=queue.optJSONObject(i);
                if(next!=null&&next.optString("id").equals(id)) {
                    for(int j=i+1;j<queue.length()&&warmed<3;j++,warmed++) {
                        JSONObject upcomingTrack=queue.optJSONObject(j);
                        if(upcomingTrack!=null)artworkCache.prefetch(origin,upcomingTrack.optString("cover_url"));
                    }
                    break;
                }
            }
        }
        // Request server preloads only once current playback is audible. Lyrics never block them.
        if(!user.isEmpty()&&upcoming.length()>0){
            final Runnable warm=new Runnable(){int attempts=0;
                @Override public void run(){
                    if(!currentID.equals(id)||isDestroyed())return;
                    if(playback==null||!playback.player.isPlaying()){
                        if(++attempts<12)ui.postDelayed(this,500);
                        return;
                    }
                    io.execute(()->{try{api.request("api/preload","POST",new JSONObject().put("ids",upcoming).put("current_id",id));}catch(Exception ignored){}});
                }
            };
            ui.postDelayed(warm,1000);
        }
        prefetch.execute(()->{try{JSONObject value=cachedLyrics(id);ui.post(()->{if(currentID.equals(id))acceptLyrics(id,value);});if(!user.isEmpty()){for(int i=0;i<Math.min(2,upcoming.length());i++)try{cachedLyrics(upcoming.optString(i));}catch(Exception ignored){}}}catch(Exception ignored){}});
    }
    private String lyricsPollID="";private int lyricsRound;
    void acceptLyrics(String id,JSONObject value){
        if(!currentID.equals(id)||isDestroyed())return;activeLyrics=value;
        if(homeLyric!=null&&playback!=null)
            syncHomeLyrics(playback.player.getCurrentPosition()/1000.0);
        if(lyricsText!=null&&lyricsTrack.equals(id)){lyricLines=value.optBoolean("synced")?value.optJSONArray("lines"):null;activeLyric=-2;activeLyricWord=-2;lyricLayoutTrack="";if(lyricLines==null)lyricsText.setText(value.optString("plain",value.optString("message",lyricsPending(value)?"Ищем подходящий текст…":"Текст пока не найден")));syncLyrics(playback==null?0:playback.player.getCurrentPosition()/1000.0);}
        if(!lyricsPollID.equals(id)){lyricsPollID=id;lyricsRound=0;}
        if(lyricsPending(value)&&lyricsRound++<20){int round=lyricsRound;ui.postDelayed(()->{if(!currentID.equals(id)||round!=lyricsRound)return;task(()->cachedLyrics(id),next->acceptLyrics(id,next));},Math.max(2000,Math.min(60000,value.optLong("retry_after",3)*1000)));}
    }
    void syncHomeLyrics(double position){
        if(homeLyric==null||!homeLyric.isAttachedToWindow())return;
        String line="";JSONObject active=null,next=null;
        // Media3 isPlaying briefly becomes false during rebuffering, even
        // while the same song remains selected. Don't erase its last lyric.
        boolean hasTrack=playback!=null&&!currentID.isEmpty();
        if(getSharedPreferences("appearance",MODE_PRIVATE)
                .getBoolean("ambient-lyrics",true)&&hasTrack&&
                activeLyrics!=null&&activeLyrics.optBoolean("synced")){
            JSONArray lines=activeLyrics.optJSONArray("lines");
            if(lines!=null){
                for(int i=0;i<lines.length();i++){
                    JSONObject candidate=lines.optJSONObject(i);
                    if(candidate==null)continue;
                    if(candidate.optDouble("time")<=position){
                        active=candidate;
                        next=lines.optJSONObject(i+1);
                    }else break;
                }
                if(active!=null){
                    // A gap between LRC lines is not a reason to blank Home.
                    // Keep the latest line until the next timestamp.
                    line=active.optString("text");
                }
            }
        }
        boolean kinetic=getSharedPreferences("appearance",MODE_PRIVATE)
            .getBoolean("nw-kinetic-lyrics",true);
        int word=kinetic&&active!=null&&!line.isEmpty()?
            lyricWordAt(active,next,position):-1;
        boolean changedLine=!line.equals(homeLine)
            ||!line.contentEquals(homeLyric.getText());
        // The previous opacity animation could be cancelled while alpha=0.
        // Restore visibility on every update, including when no word changes.
        homeLyric.animate().cancel();
        if(homeLyric.getAlpha()<1f)homeLyric.setAlpha(1f);
        if(homeLyric.getTranslationY()!=0f)homeLyric.setTranslationY(0f);
        if(changedLine){
            homeLine=line;
            homeWord=-2;
            homeKineticSpans.clear();
            if(line.isEmpty()){
                homeLyric.setText("");
                return;
            }
            homeLyric.setText(new android.text.SpannableStringBuilder(line),
                TextView.BufferType.SPANNABLE);
        }
        if(line.isEmpty()||(!changedLine&&homeWord==word))return;
        homeWord=word;
        if(!(homeLyric.getText() instanceof android.text.Spannable))return;
        android.text.Spannable styled=(android.text.Spannable)homeLyric.getText();
        for(Object span:homeKineticSpans)styled.removeSpan(span);
        homeKineticSpans.clear();
        if(!kinetic)return;
        java.util.regex.Matcher matcher=KINETIC_TOKENS.matcher(line);
        int ordinal=0;
        while(matcher.find()){
            int from=matcher.start(),to=matcher.end();
            android.text.style.ForegroundColorSpan color=
                new android.text.style.ForegroundColorSpan(
                    ordinal<=word?0xffffffff:0xffa0a2af);
            styled.setSpan(color,from,to,android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            homeKineticSpans.add(color);
            if(ordinal==word){
                android.text.style.BackgroundColorSpan glow=
                    new android.text.style.BackgroundColorSpan(0x24ffffff);
                styled.setSpan(glow,from,to,android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                homeKineticSpans.add(glow);
            }
            ordinal++;
        }
        homeLyric.invalidate();
    }
    void showLyrics(JSONObject track){String id=track.optString("id");status.setText("Ищем текст…");task(()->cachedLyrics(id),v->{
        if(!currentID.equals(id))return;acceptLyrics(id,v);lyricLines=v.optBoolean("synced")?v.optJSONArray("lines"):null;lyricsTrack=id;activeLyric=-2;activeLyricWord=-2;
        lyricsScroll=new android.widget.ScrollView(this);lyricsText=text("",26);lyricsText.setGravity(Gravity.CENTER);lyricsText.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);lyricsText.setPadding(dp(22),dp(28),dp(22),dp(28));lyricsText.setLineSpacing(dp(16),1);lyricsScroll.addView(lyricsText);
        if(lyricLines==null||lyricLines.length()==0)lyricsText.setText(v.optString("plain",v.optString("message",lyricsPending(v)?"Ищем подходящий текст…":"Текст пока не найден")));
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Текст песни · "+v.optString("source")).setView(lyricsScroll).setPositiveButton("Закрыть",null).create();dialog.setOnDismissListener(d->{ui.removeCallbacks(lyricTicker);lyricsText=null;lyricsScroll=null;lyricLines=null;lyricLayoutTrack="";lyricDynamicSpans.clear();});styleSheet(dialog);dialog.show();status.setText("");syncLyrics(playback==null?0:playback.player.getCurrentPosition()/1000.0);ui.removeCallbacks(lyricTicker);ui.postDelayed(lyricTicker,160);
    });}
    // Build clickable lyric spans once per lyrics payload. Each word tick updates
    // only the existing paint spans, not the text, its layout, or the scroll offset.
    void prepareLyricLayout(){
        if(lyricsText==null||lyricLines==null)return;
        lyricRanges.clear();lyricDynamicSpans.clear();
        StringBuilder content=new StringBuilder();
        final String track=lyricsTrack;
        for(int i=0;i<lyricLines.length();i++){
            JSONObject line=lyricLines.optJSONObject(i);
            if(line==null)continue;
            int begin=content.length();
            content.append(line.optString("text")).append("\n\n");
            lyricRanges.put(i,new int[]{begin,content.length()});
        }
        android.text.SpannableStringBuilder styled=new android.text.SpannableStringBuilder(content);
        if(styled.length()>0)styled.setSpan(
            new android.text.style.ForegroundColorSpan(0xff9c9c9c),0,styled.length(),
            android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        for(int i=0;i<lyricLines.length();i++){
            int[] range=lyricRanges.get(i);
            JSONObject line=lyricLines.optJSONObject(i);
            if(range==null||line==null||range[0]>=range[1])continue;
            final double seconds=line.optDouble("time",-1);
            if(seconds<0||!Double.isFinite(seconds))continue;
            styled.setSpan(new android.text.style.ClickableSpan(){
                @Override public void onClick(View view){
                    if(track.equals(currentID)&&playback!=null)playback.seek(seconds);
                }
                @Override public void updateDrawState(android.text.TextPaint paint){
                    paint.setUnderlineText(false);
                }
            },range[0],range[1],android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        lyricsText.setHighlightColor(Color.TRANSPARENT);
        lyricsText.setMovementMethod(android.text.method.LinkMovementMethod.getInstance());
        lyricsText.setText(styled,android.widget.TextView.BufferType.SPANNABLE);
        lyricLayoutTrack=lyricsTrack;
    }

    // Optional exact word stamps from the server (seconds or Lyricsfile ms),
    // otherwise interpolate using phonetic-length weights in a bounded window.
    int lyricWordAt(JSONObject line,JSONObject next,double position){
        if(line==null)return -1;
        String text=line.optString("text","");
        JSONArray exact=line.optJSONArray("words");
        double lineStart=line.optDouble("time",position);
        double lineEnd=next==null?lineStart+4:next.optDouble("time",lineStart+4);
        if(exact!=null&&exact.length()>0){
            StringBuilder combined=new StringBuilder();
            double prior=-1;
            int selected=-1;boolean valid=true;
            for(int j=0;j<exact.length();j++){
                JSONObject word=exact.optJSONObject(j);
                if(word==null){valid=false;break;}
                combined.append(word.optString("text",""));
                double start=word.has("start")?word.optDouble("start",-1):
                    word.has("time")?word.optDouble("time",-1):
                    word.optDouble("start_ms",-1000)/1000.0;
                if(!Double.isFinite(start)||start<lineStart-.25||
                   start>lineEnd+.5||start<prior){valid=false;break;}
                if(start<=position)selected=j;
                prior=start;
            }
            // Highlight indices must match the visible whitespace tokens.
            java.util.regex.Matcher matched=KINETIC_TOKENS.matcher(text);
            int visibleWords=0;
            while(matched.find())visibleWords++;
            if(valid&&exact.length()==visibleWords&&
                combined.toString().trim().equals(text.trim()))return selected;
        }
        java.util.regex.Matcher matcher=KINETIC_TOKENS.matcher(text);
        java.util.ArrayList<Double> weights=new java.util.ArrayList<>();
        double sum=0;
        while(matcher.find()){
            String token=matcher.group();int letters=0,vowels=0;boolean punctuation=false;
            for(int j=0;j<token.length();j++){
                char c=token.charAt(j);
                if(Character.isLetter(c))letters++;
                if("aeiouyAEIOUYаеёиоуыэюяАЕЁИОУЫЭЮЯ".indexOf(c)>=0)vowels++;
                if(",.!?:;".indexOf(c)>=0)punctuation=true;
            }
            double weight=.55+Math.min(letters,16)*.16+
                Math.min(vowels,8)*.18+(punctuation?.20:0);
            weights.add(weight);sum+=weight;
        }
        if(weights.isEmpty())return -1;
        double span=Math.max(.3,lineEnd-lineStart);
        double singing=Math.min(span,Math.max(1.1,weights.size()*1.45));
        double progress=Math.max(0,Math.min(.99999,(position-lineStart)/singing));
        double cumulative=0;
        for(int j=0;j<weights.size();j++){
            cumulative+=weights.get(j)/Math.max(.01,sum);
            if(progress<cumulative)return j;
        }
        return weights.size()-1;
    }

    void syncLyrics(double position){
        if(lyricsText==null||lyricLines==null||!currentID.equals(lyricsTrack))return;
        int current=-1;
        for(int i=0;i<lyricLines.length();i++){
            JSONObject entry=lyricLines.optJSONObject(i);
            if(entry!=null&&entry.optDouble("time")<=position)current=i;
        }
        boolean kinetic=getSharedPreferences("appearance",MODE_PRIVATE)
            .getBoolean("nw-kinetic-lyrics",true);
        int word=kinetic&&current>=0
            ?lyricWordAt(lyricLines.optJSONObject(current),lyricLines.optJSONObject(current+1),position)
            :-1;
        if(!lyricsTrack.equals(lyricLayoutTrack)||lyricRanges.size()!=lyricLines.length()){
            prepareLyricLayout();activeLyric=-2;activeLyricWord=-2;
        }
        if(current==activeLyric&&word==activeLyricWord)return;
        boolean changedLine=current!=activeLyric;
        activeLyric=current;activeLyricWord=word;
        if(!(lyricsText.getText() instanceof android.text.Spannable))return;
        android.text.Spannable styled=(android.text.Spannable)lyricsText.getText();
        for(Object span:lyricDynamicSpans)styled.removeSpan(span);
        lyricDynamicSpans.clear();
        if(current>=0){
            int[] range=lyricRanges.get(current);
            JSONObject line=lyricLines.optJSONObject(current);
            if(range!=null&&line!=null){
                android.text.style.ForegroundColorSpan activeColor=
                    new android.text.style.ForegroundColorSpan(kinetic?0xffbcbcc9:0xffeeeeee);
                styled.setSpan(activeColor,range[0],range[1],android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                lyricDynamicSpans.add(activeColor);
                if(kinetic){
                    java.util.regex.Matcher m=KINETIC_TOKENS.matcher(line.optString("text",""));
                    int ordinal=0;
                    while(m.find()){
                        int begin=range[0]+m.start(),finish=range[0]+m.end();
                        if(ordinal<=word){
                            android.text.style.ForegroundColorSpan lit=
                                new android.text.style.ForegroundColorSpan(0xffffffff);
                            styled.setSpan(lit,begin,finish,android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                            lyricDynamicSpans.add(lit);
                        }
                        if(ordinal==word){
                            android.text.style.BackgroundColorSpan glow=
                                new android.text.style.BackgroundColorSpan(0x24ffffff);
                            styled.setSpan(glow,begin,finish,android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                            lyricDynamicSpans.add(glow);
                        }
                        ordinal++;
                    }
                }
            }
        }
        lyricsText.invalidate();
        if(changedLine&&current>=0){
            int[] highlighted=lyricRanges.get(current);
            final int offset=highlighted==null?0:highlighted[0];
            lyricsText.post(()->{
                if(lyricsText==null||lyricsScroll==null||lyricsText.getLayout()==null)return;
                int line=lyricsText.getLayout().getLineForOffset(
                    Math.min(offset,lyricsText.length()));
                lyricsScroll.smoothScrollTo(0,Math.max(0,
                    lyricsText.getLayout().getLineTop(line)-lyricsScroll.getHeight()/3));
            });
        }
    }

    // Seeded Rhythm uses the same streaming endpoint as the existing Wave.
    // Matching and deduplication happen off the UI thread.
    void seededRhythmByTrack(JSONObject track){
        if(track!=null)startSeededRhythm(new JSONArray().put(track),track);
    }
    void seededRhythmByPlaylist(String playlistID){
        if(user.isEmpty()){auth();return;}
        status.setText("Подбираем похожую музыку…");
        task(()->api.request("api/playlists/"+playlistID+"/tracks"),response->{
            JSONArray seeds=response.optJSONArray("tracks");
            if(seeds==null||seeds.length()==0){status.setText("В плейлисте пока нет треков.");return;}
            startSeededRhythm(seeds,null);
        });
    }
    void startSeededRhythm(JSONArray seeds,JSONObject selected){
        if(user.isEmpty()){auth();return;}
        if(mixing)return;
        final NativeAPI client=new NativeAPI(this,origin);
        final long ticket=waveRequest.start(client::close);
        final String owner=user;
        final WaveSettings preferences=WaveSettings.read(this,origin,user);
        final Set<String> hidden=hiddenRecommendations(),blocked=hiddenArtists();
        final JSONArray playlistCopies=cachedOwnedTracks();
        final java.util.List<String> artists=SeededRhythm.artists(seeds);
        mixing=true;status.setText("Подбираем похожую музыку…");
        io.execute(()->{
            try{
                if(!waveRequest.pending(ticket))return;
                JSONArray local=SeededRhythm.rank(
                    concatTracks(catalog,playlistCopies,queue),seeds,hidden,blocked);
                JSONArray fresh=local;
                if(local.length()<24){
                    java.util.LinkedHashSet<String> excluded=new java.util.LinkedHashSet<>();
                    for(int i=0;i<Math.min(100,seeds.length());i++){
                        JSONObject seed=seeds.optJSONObject(i);if(seed!=null)excluded.add(seed.optString("id"));
                    }
                    String url="api/wave?mix="+UUID.randomUUID()
                        +preferences.query()+"&artists="+java.net.URLEncoder.encode(
                            android.text.TextUtils.join(",",artists),"UTF-8")
                        +"&exclude="+java.net.URLEncoder.encode(limitedExclusions(excluded),"UTF-8");
                    try {
                        JSONObject response=client.search(url);
                        fresh=SeededRhythm.rank(
                            concatTracks(local,response.optJSONArray("tracks")),seeds,hidden,blocked);
                    } catch(Exception offline) {
                        // Keep usable local recommendations if the provider is slow or offline.
                        fresh=local;
                    }
                }
                final JSONArray result=fresh;
                ui.post(()->{
                    if(isDestroyed()||!waveRequest.complete(ticket))return;
                    mixing=false;
                    if(!owner.equals(user))return;
                    if(result.length()==0){
                        status.setText("Не удалось найти похожие треки в доступном каталоге.");
                        return;
                    }
                    JSONArray playing=new JSONArray();
                    if(selected!=null)playing.put(selected);
                    for(int i=0;i<result.length();i++)playing.put(result.optJSONObject(i));
                    JSONArray artistSeeds=new JSONArray();
                    for(String artist:artists)artistSeeds.put(artist);
                    status.setText("");
                    play(playing.optJSONObject(0),playing,true,artistSeeds);
                });
            }catch(Exception error){
                ui.post(()->{
                    if(!isDestroyed()&&waveRequest.complete(ticket)){
                        mixing=false;status.setText(friendly(error));
                    }
                });
            }finally{client.close();}
        });
    }

    private final java.util.Map<String,ClipEntry> clipCache=new java.util.HashMap<>();
    private final Set<String> clipPending=new HashSet<>();
    private static final class ClipEntry{
        final String id;final long expires;
        ClipEntry(String id,long expires){this.id=id;this.expires=expires;}
    }
    private String foundClip(JSONObject track){
        if(track==null)return null;
        ClipEntry entry=clipCache.get(track.optString("id"));
        return entry!=null&&System.currentTimeMillis()<entry.expires&&!entry.id.isEmpty()?entry.id:null;
    }
    private void prefetchClip(JSONObject track){
        if(track==null||user.isEmpty())return;
        final String id=track.optString("id");
        if(id.isEmpty()||clipPending.contains(id))return;
        ClipEntry prior=clipCache.get(id);
        if(prior!=null&&prior.expires>System.currentTimeMillis())return;
        clipPending.add(id);
        final String title=track.optString("title"),artist=track.optString("artist"),owner=user;
        io.execute(()->{
            String video="";
            try{
                String url="api/music-videos/clip?title="+java.net.URLEncoder.encode(title,"UTF-8")
                    +"&artist="+java.net.URLEncoder.encode(artist,"UTF-8");
                JSONObject match=api.request(url);
                if(match.optBoolean("available")){
                    String candidate=match.optString("video_id");
                    if(candidate.matches("[A-Za-z0-9_-]{11}"))video=candidate;
                }
            }catch(Exception ignored){}
            final String ready=video;
            ui.post(()->{
                clipPending.remove(id);
                if(!owner.equals(user)||isDestroyed())return;
                clipCache.put(id,new ClipEntry(ready,System.currentTimeMillis()
                    +(ready.isEmpty()?15L*60*1000:6L*60*60*1000)));
                if(clipCache.size()>250)clipCache.clear();
            });
        });
    }
    void openClip(JSONObject track){
        String video=foundClip(track);
        if(video==null){prefetchClip(track);status.setText("Клип пока не найден.");return;}
        if(playback!=null)playback.pause();
        android.webkit.WebView web=new android.webkit.WebView(this);
        web.getSettings().setJavaScriptEnabled(true);
        web.getSettings().setDomStorageEnabled(true);
        web.setWebChromeClient(new android.webkit.WebChromeClient());
        String html="<html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>"
            +"<body style=\"margin:0;background:black\"><iframe width=\"100%\" height=\"100%\" "
            +"src=\"https://www.youtube-nocookie.com/embed/"+video+"?playsinline=1&amp;controls=1\" "
            +"allow=\"accelerometer;autoplay;encrypted-media;gyroscope;picture-in-picture\" "
            +"allowfullscreen referrerpolicy=\"strict-origin-when-cross-origin\" style=\"border:0\"></iframe></body></html>";
        web.loadDataWithBaseURL(origin,html,"text/html","UTF-8",null);
        android.widget.FrameLayout videoFrame=new android.widget.FrameLayout(this);
        videoFrame.addView(web,new android.widget.FrameLayout.LayoutParams(-1,dp(260)));
        AlertDialog dialog=new AlertDialog.Builder(this)
            .setTitle("Клип · "+track.optString("title")).setView(videoFrame)
            .setNegativeButton("Закрыть",null).create();
        dialog.setOnDismissListener(d->{
            web.stopLoading();
            web.loadUrl("about:blank");
            web.destroy();
        });
        styleSheet(dialog);
        dialog.show();
    }
    void fullPlayerMenu(JSONObject track){
        prefetchClip(track);
        boolean video=foundClip(track)!=null;
        boolean classic="classic".equals(getSharedPreferences("appearance",MODE_PRIVATE)
            .getString("nw-cover-style","immersive"));
        boolean animate=getSharedPreferences("appearance",MODE_PRIVATE)
            .getBoolean("nw-animated-album-artwork",true);
        java.util.List<String> options=new java.util.ArrayList<>();
        options.add("Твой ритм по треку");
        if(video)options.add("Клип");
        options.add("Качество звука");
        options.add("Эквалайзер");
        if(!classic)options.add(animate?"Отключить анимацию обложки":"Включить анимацию обложки");
        options.add("Действия с треком");
        nightwellOptions("Плеер",options.toArray(new String[0]),n->{
            String item=options.get(n);
            if(item.equals("Твой ритм по треку"))seededRhythmByTrack(track);
            else if(item.equals("Клип"))openClip(track);
            else if(item.equals("Качество звука"))qualityPlayerMenu();
            else if(item.equals("Эквалайзер"))feature("sound");
            else if(item.contains("анимацию обложки")){
                getSharedPreferences("appearance",MODE_PRIVATE).edit()
                    .putBoolean("nw-animated-album-artwork",!animate).apply();
                if(full)openPlayer();
            }else trackMenu(track);
        });
    }
    void qualityPlayerMenu(){
        final String[] labels={"Авто","Низкое","Среднее","Высокое"};
        final String[] codes={"auto","low","medium","high"};
        String chosen=getSharedPreferences("playback",MODE_PRIVATE)
            .getString("nw-audio-quality","auto");
        if("economy".equals(chosen))chosen="low";
        String[] options=new String[labels.length];
        for(int i=0;i<labels.length;i++)
            options[i]=(codes[i].equals(chosen)?"✓  ":"")+labels[i];
        nightwellOptions("Качество звука",options,selection->{
            String quality=codes[selection];
            getSharedPreferences("playback",MODE_PRIVATE).edit()
                .putString("nw-audio-quality",quality).apply();
            lastQualityNoticeKey="";
            status.setText("Качество изменится со следующего трека");
            verifyAudioQualitySupport();
        });
    }
    void trackMenu(JSONObject track){
        String id=track.optString("id");
        final boolean video=foundClip(track)!=null;
        java.util.List<String> actionsList=new java.util.ArrayList<>();
        actionsList.add("Твой ритм по треку");
        if(video)actionsList.add("Клип");
        boolean downloaded=OfflineStore.audio(this,origin,user,id)!=null;
        actionsList.addAll(java.util.Arrays.asList(
            likes.contains(id)?"Убрать из избранного":"В избранное",
            downloaded?"Удалить загрузку":"Скачать","Поделиться","Добавить в плейлист",
            hiddenRecommendations().contains(id)?"Вернуть в рекомендации":"Не рекомендовать",
            isArtistHidden(track)?"Вернуть исполнителя":"Не рекомендовать исполнителя"));
        AlertDialog actions=new AlertDialog.Builder(this).setTitle(track.optString("title"))
            .setItems(actionsList.toArray(new String[0]),(d,chosen)->{
                if(chosen==0){seededRhythmByTrack(track);return;}
                if(video&&chosen==1){openClip(track);return;}
                int n=chosen-(video?2:1);
                if(n==0)toggleFavorite(track);
                else if(n==1){
                    if(downloaded){
                        task(()->new JSONObject(OfflineStore.operation(this,origin,
                            new JSONObject().put("op","remove").put("account",user)
                                .put("id",id).toString())),
                            result->{status.setText("Загрузка удалена");if(screen.equals("Офлайн"))showScreen();});
                    }else download(new JSONArray().put(track));
                }
                else if(n==2)share(origin+"track/"+id);
                else if(n==4)toggleRecommendationHidden(track);
                else if(n==5)toggleArtistHidden(track);
                else {
                    String[] names=new String[playlists.length()];
                    for(int i=0;i<names.length;i++)names[i]=playlists.optJSONObject(i).optString("name");
                    AlertDialog choose=new AlertDialog.Builder(this).setTitle("В плейлист")
                        .setItems(names,(x,i)->task(()->api.request(
                            "api/playlists/"+playlists.optJSONObject(i).getString("id")+"/tracks/"+id,
                            "POST",null),v->{})).create();
                    styleSheet(choose);choose.show();
                }
            }).create();
        styleSheet(actions);actions.show();
    }
    private String playlistSnapshotKey(String id){return "playlist|"+origin+"|"+user+"|"+id;}
    void openPlaylist(JSONObject p){
        final int gen=++generation;api.cancelSearch();
        if(pendingSearch!=null)ui.removeCallbacks(pendingSearch);
        final String id=p.optString("id");
        screen=p.optString("name");selectedPlaylist=id;
        String cached=getSharedPreferences("playlist-snapshots",MODE_PRIVATE).getString(playlistSnapshotKey(id),null);
        try{shown=cached==null?new JSONArray():new JSONArray(cached);}catch(Exception ignored){shown=new JSONArray();}
        showScreen();updateList();
        task(()->api.request("api/playlists/"+id+"/tracks"),v->{
            if(gen!=generation||!id.equals(selectedPlaylist))return;
            JSONArray tracks=v.optJSONArray("tracks");if(tracks==null)return;
            shown=tracks;updateList();
            if(tracks.toString().length()<750000){
                getSharedPreferences("playlist-snapshots",MODE_PRIVATE)
                    .edit().putString(playlistSnapshotKey(id),tracks.toString()).apply();
                ownedSearchIndex=null;
            }
        });
    }
    void nightwellOptions(String title,String[] options,java.util.function.IntConsumer selected){
        LinearLayout panel=column();panel.setPadding(dp(12),dp(10),dp(12),dp(12));
        TextView heading=text(title,19);heading.setTextColor(0xffeeeeee);heading.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);heading.setPadding(dp(6),dp(4),dp(6),dp(10));panel.addView(heading);
        AlertDialog dialog=new AlertDialog.Builder(this).setView(panel).create();
        for(int index=0;index<options.length;index++){
            final int choice=index;
            TextView entry=sheetAction(options[index],()->{dialog.dismiss();selected.accept(choice);});
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,dp(47));lp.setMargins(0,dp(3),0,dp(3));panel.addView(entry,lp);
        }
        styleSheet(dialog);dialog.show();
    }
    void collectionMenu(String kind,String id){
        String[] options=kind.equals("playlist")
            ?new String[]{"Твой ритм по плейлисту","Скачать всё","Поделиться","Удалить"}
            :new String[]{"Скачать всё","Поделиться"};
        nightwellOptions("Действия",options,selected->{
            if(kind.equals("playlist")&&selected==0){seededRhythmByPlaylist(id);return;}
            int n=selected-(kind.equals("playlist")?1:0);
            if(n==0){if(kind.equals("likes"))download(shown);else task(()->api.request("api/playlists/"+id+"/tracks"),v->download(v.optJSONArray("tracks")));}
            else if(n==1)shareCollection(kind,id);
            else {AlertDialog confirm=new AlertDialog.Builder(this).setMessage("Удалить плейлист?").setNegativeButton("Отмена",null).setPositiveButton("Удалить",(d,b)->task(()->api.request("api/playlists/"+id,"DELETE",null),v->load())).create();styleSheet(confirm);confirm.show();}
        });
    }
    void shareCollection(String kind,String playlistID){
        final String server=origin;
        final NativeAPI client=api;
        final String owner=user;
        status.setText("Готовим подборку для отправки…");
        io.execute(()->{
            String content=null;
            // New servers can return a public, revocable share link. Validate
            // the destination, never concatenate a path without a separator.
            try{
                JSONObject response=client.request("api/shares","POST",
                    new JSONObject().put("kind",kind).put("playlist_id",playlistID));
                String path=response.optString("path","").trim();
                if(!path.isEmpty()){
                    java.net.URI base=new java.net.URI(server);
                    java.net.URI link=base.resolve(path).normalize();
                    if("https".equalsIgnoreCase(link.getScheme()) &&
                        base.getHost().equalsIgnoreCase(link.getHost())){
                        content=link.toString();
                    }
                }
            }catch(Exception ignored){
                // Old Nightwell servers do not have /api/shares.
            }
            if(content==null){
                try{
                    JSONArray tracks=new JSONArray();
                    String label="Избранное";
                    if("playlist".equals(kind)){
                        JSONObject data=client.request("api/playlists/"+playlistID+"/tracks");
                        JSONArray received=data.optJSONArray("tracks");
                        if(received!=null)tracks=received;
                        for(int i=0;i<playlists.length();i++){
                            JSONObject p=playlists.optJSONObject(i);
                            if(p!=null && playlistID.equals(p.optString("id"))){
                                label=p.optString("name","Плейлист");break;
                            }
                        }
                    } else {
                        for(int i=0;i<catalog.length();i++){
                            JSONObject track=catalog.optJSONObject(i);
                            if(track!=null&&likes.contains(track.optString("id")))tracks.put(track);
                        }
                    }
                    if(tracks.length()>0){
                        StringBuilder text=new StringBuilder("🎵 ").append(label)
                            .append("\nNightwell Music\n");
                        for(int i=0;i<Math.min(tracks.length(),300);i++){
                            JSONObject track=tracks.optJSONObject(i);
                            if(track==null)continue;
                            text.append("\n").append(i+1).append(". ")
                                .append(track.optString("artist","Исполнитель"))
                                .append(" — ").append(track.optString("title","Трек"));
                        }
                        if(tracks.length()>300)
                            text.append("\nИ ещё ").append(tracks.length()-300).append(" треков");
                        content=text.toString();
                    }
                }catch(Exception ignored){}
            }
            final String ready=content;
            ui.post(()->{
                if(isDestroyed()||!server.equals(origin)||!owner.equals(user))return;
                if(ready!=null&&!ready.isEmpty()){
                    status.setText("");
                    share(ready);
                }else status.setText("Не удалось подготовить подборку для отправки");
            });
        });
    }
    void share(String url){startActivity(Intent.createChooser(new Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,url),"Поделиться"));}
    void download(JSONArray items){if(items==null)return;if(user.isEmpty()){auth();return;}String account=user;status.setText("Добавляем в фоновую очередь…");task(()->{if(!api.request("api/premium/me").optBoolean("premium"))throw new java.io.IOException("Скачивание доступно с Premium — 150 ₽ за 30 дней.");BackgroundDownloads.enqueue(this,origin,account,items);return new JSONObject();},v->status.setText(BackgroundDownloads.progress(this)));}
    interface InputDone{void run(String value);}
    void input(String title,InputDone done){EditText field=new EditText(this);AlertDialog dialog=new AlertDialog.Builder(this).setTitle(title).setView(field).setPositiveButton("Сохранить",(d,n)->done.run(field.getText().toString())).setNegativeButton("Отмена",null).create();styleSheet(dialog);dialog.show();}
    private String lastQualityNoticeKey="";
    private void verifyAudioQualitySupport() {
        if(user.isEmpty()||api==null)return;
        final String host=origin, owner=user;
        final NativeAPI client=api;
        io.execute(()->{
            boolean supported=false;
            try{
                JSONObject result=client.request("api/audio-quality/options");
                JSONArray options=result.optJSONArray("options");
                for(int i=0;options!=null&&i<options.length();i++){
                    JSONObject option=options.optJSONObject(i);
                    if(option!=null&&"high".equals(option.optString("id"))){
                        supported=true;break;
                    }
                }
            }catch(Exception ignored){}
            final boolean ready=supported;
            ui.post(()->{
                if(isDestroyed()||!host.equals(origin)||!owner.equals(user))return;
                getSharedPreferences("playback",MODE_PRIVATE).edit()
                    .putBoolean("nw-quality-ready",ready)
                    .putString("nw-quality-ready-origin",host).apply();
                if(!ready)status.setText("Сервер не поддерживает выбор качества, используется обычный поток");
            });
        });
    }
    private void checkTrackAudioQuality(JSONObject track) {
        if(track==null||track.optBoolean("_offline")||api==null)return;
        final String quality=getSharedPreferences("playback",MODE_PRIVATE)
            .getString("nw-audio-quality","auto");
        if("auto".equals(quality))return;
        final String requested=("low".equals(quality)||"economy".equals(quality))?
            "economy":"high";
        final String trackID=track.optString("id"), host=origin,owner=user;
        final String key=host+"|"+trackID+"|"+quality;
        if(trackID.isEmpty()||key.equals(lastQualityNoticeKey))return;
        lastQualityNoticeKey=key;
        boolean supported=getSharedPreferences("playback",MODE_PRIVATE)
            .getBoolean("nw-quality-ready",false)&&
            host.equals(getSharedPreferences("playback",MODE_PRIVATE)
            .getString("nw-quality-ready-origin",""));
        if(!supported){
            status.setText("Качество изменится со следующего трека после проверки сервера");
            verifyAudioQualitySupport();
            return;
        }
        final NativeAPI client=api;
        io.execute(()->{
            String notice="";
            try {
                JSONObject result=client.request("api/audio-quality/options?track_id="+
                    java.net.URLEncoder.encode(trackID,"UTF-8")+"&quality="+requested);
                if(result.optBoolean("fallback")){
                    String available=result.optString("selected_quality","original");
                    String label="economy".equals(available)?"Низкое":
                        "high".equals(available)?"Высокое":"Исходное";
                    notice="Выбранное качество недоступно. Используется: "+label;
                }
            }catch(Exception ignored){
                notice="Качество не проверено, воспроизводится доступный поток";
            }
            final String finalNotice=notice;
            ui.post(()->{
                if(isDestroyed()||!host.equals(origin)||!owner.equals(user)||
                    !trackID.equals(currentID))return;
                if(!finalNotice.isEmpty())status.setText(finalNotice);
            });
        });
    }

    private void editProfileNickname(){
        if(user.isEmpty()){auth();return;}
        task(()->api.request("api/profile/me"),profile->{
            android.widget.EditText field=new android.widget.EditText(this);
            field.setSingleLine(true);
            field.setText(profile.optString("nickname",""));
            field.setHint("Ник, от 2 до 32 символов");
            new AlertDialog.Builder(this).setTitle("Изменить ник")
                .setView(field).setNegativeButton("Отмена",null)
                .setPositiveButton("Сохранить",(d,which)->{
                    String nickname=field.getText().toString().trim();
                    if(nickname.length()<2||nickname.length()>32){
                        status.setText("Ник должен содержать от 2 до 32 символов");return;
                    }
                    task(()->{
                        JSONObject body=new JSONObject();body.put("nickname",nickname);
                        return api.request("api/profile/me","PUT",body);
                    },saved->{cachedProfileNickname=saved.optString("nickname",nickname);
                        status.setText("Ник сохранён");});
                }).show();
        });
    }
    private void selectProfileAvatar(){
        if(user.isEmpty()){auth();return;}
        try{
            Intent intent=new Intent(Intent.ACTION_GET_CONTENT);
            intent.setType("image/*");
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            startActivityForResult(Intent.createChooser(intent,"Выбери аватар"),635);
        }catch(Throwable error){status.setText("Не удалось открыть галерею");}
    }
    private void uploadProfileAvatar(Uri uri){
        if(user.isEmpty())return;
        task(()->{
            android.graphics.Bitmap bitmap;
            try(java.io.InputStream input=getContentResolver().openInputStream(uri)){
                if(input==null)throw new java.io.IOException("Не удалось открыть фотографию");
                bitmap=android.graphics.BitmapFactory.decodeStream(input);
            }
            if(bitmap==null)throw new java.io.IOException("Неподдерживаемый формат");
            int width=bitmap.getWidth(),height=bitmap.getHeight();
            float scale=Math.min(1f,512f/Math.max(width,height));
            android.graphics.Bitmap image=android.graphics.Bitmap.createScaledBitmap(bitmap,
                Math.max(1,Math.round(width*scale)),Math.max(1,Math.round(height*scale)),true);
            java.io.ByteArrayOutputStream output=new java.io.ByteArrayOutputStream();
            image.compress(android.graphics.Bitmap.CompressFormat.JPEG,76,output);
            byte[] bytes=output.toByteArray();
            if(bytes.length>768*1024)throw new java.io.IOException("Уменьши размер фотографии");
            JSONObject body=new JSONObject();
            body.put("mime","image/jpeg");
            body.put("avatar_base64",android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP));
            return api.request("api/profile/avatar","POST",body);
        },saved->{cachedProfileUser="";refreshProfileAvatar();status.setText("Аватар обновлён");});
    }
    private void refreshProfileAvatar(){
        if(user.isEmpty()){cachedProfileUser="";cachedProfileNickname="";cachedProfileAvatar=null;return;}
        if(user.equals(cachedProfileUser)){
            if(cachedProfileAvatar!=null&&profileAvatarButton!=null){
                profileAvatarButton.setPadding(0,0,0,0);
                profileAvatarButton.setImageBitmap(cachedProfileAvatar);
            }
            return;
        }
        final String requestedUser=user;
        cachedProfileUser=user;
        io.execute(()->{
            try{
                JSONObject profile=api.request("api/profile/me");
                String urlPath=profile.optString("avatar_url","");
                String nickname=profile.optString("nickname","");
                android.graphics.Bitmap image=null;
                if(urlPath.startsWith("/api/profile/avatar/")){
                    String requestOrigin=origin.endsWith("/")?origin.substring(0,origin.length()-1):origin;
                    java.net.HttpURLConnection c=(java.net.HttpURLConnection)new java.net.URL(requestOrigin+urlPath).openConnection();
                    c.setConnectTimeout(5000);c.setReadTimeout(5000);
                    try{
                        if(c.getResponseCode()==200){
                            java.io.ByteArrayOutputStream out=new java.io.ByteArrayOutputStream();
                            try(java.io.InputStream stream=c.getInputStream()){
                                byte[] buffer=new byte[8192];int len;
                                while((len=stream.read(buffer))!=-1&&out.size()<=768*1024)out.write(buffer,0,len);
                            }
                            if(out.size()<=768*1024)image=android.graphics.BitmapFactory.decodeByteArray(out.toByteArray(),0,out.size());
                        }
                    }finally{c.disconnect();}
                }
                final android.graphics.Bitmap ready=image;
                ui.post(()->{if(!requestedUser.equals(user))return;
                    cachedProfileNickname=nickname;cachedProfileAvatar=ready;
                    if(profileAvatarButton!=null&&ready!=null){
                        profileAvatarButton.setPadding(0,0,0,0);profileAvatarButton.setImageBitmap(ready);
                    }
                });
            }catch(Exception ignored){cachedProfileUser="";}
        });
    }

    void settings(){
        LinearLayout list=column();
        list.setPadding(dp(19),dp(6),dp(19),dp(13));
        TextView introduction=text("Настрой музыку под себя",13);
        introduction.setTextColor(0xffadb0b9);
        introduction.setPadding(dp(4),0,0,dp(16));
        list.addView(introduction);
        final String[] pages={"Кастомизация","Воспроизведение","Оформление","О приложении"};
        final String[] captions={
            "Обложки, очередь и текст песен",
            "Звук, загрузка и переходы",
            "Темы и визуальные эффекты",
            "Версия и сведения о сборке"
        };
        final String[] symbols={"◈","♫","✧","ⓘ"};
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Настройки")
            .setView(list).setPositiveButton("Готово",null).create();
        for(int i=0;i<pages.length;i++){
            final String selected=pages[i];
            LinearLayout item=row();
            item.setPadding(dp(12),0,dp(10),0);
            item.setBackground(touchSurface(0xff282a30,15));
            TextView symbol=text(symbols[i],20);
            symbol.setTextColor(0xffd5d6dc);symbol.setGravity(Gravity.CENTER);
            symbol.setBackground(fieldSurface(0xff33353a,12));
            item.addView(symbol,new LinearLayout.LayoutParams(dp(40),dp(40)));
            LinearLayout names=column();names.setPadding(dp(11),0,0,0);
            TextView title=text(selected,15);
            title.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
            TextView subtitle=text(captions[i],11);
            subtitle.setTextColor(0xffa7aab4);subtitle.setPadding(0,dp(4),0,0);
            names.addView(title);names.addView(subtitle);
            item.addView(names,new LinearLayout.LayoutParams(0,-2,1));
            TextView chevron=text("›",21);chevron.setTextColor(0xff9b9da6);
            item.addView(chevron,new LinearLayout.LayoutParams(dp(18),-2));
            LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,dp(68));
            params.bottomMargin=dp(7);
            list.addView(item,params);
            item.setOnClickListener(v->{dialog.dismiss();settingsPage(selected);});
        }
        styleNavigationSheet(dialog);dialog.show();
    }

    void settingsPage(String page){
        LinearLayout panel=column();
        panel.setPadding(dp(14),dp(12),dp(14),dp(14));
        ScrollView scroll=new ScrollView(this);
        scroll.setFillViewport(false);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(panel);
        if("Кастомизация".equals(page)){
        final String currentCoverStyle=getSharedPreferences("appearance",MODE_PRIVATE)
            .getString("nw-cover-style","immersive");
        TextView coverStyleButton=sheetAction(
            "Стиль обложки · "+("classic".equals(currentCoverStyle)?"Классическая":"Во весь экран"),
            ()->{});
        coverStyleButton.setOnClickListener(view->nightwellOptions("Стиль обложки",
            new String[]{"Во весь экран · плавные края","Классическая · скруглённый квадрат"},
            option->{
                String style=option==1?"classic":"immersive";
                getSharedPreferences("appearance",MODE_PRIVATE).edit()
                    .putString("nw-cover-style",style).apply();
                coverStyleButton.setText("Стиль обложки · "+
                    (option==1?"Классическая":"Во весь экран"));
                if(full)ui.post(()->openPlayer());
            }));
        panel.addView(coverStyleButton);
        android.widget.Switch depthQueue=new android.widget.Switch(this);
        depthQueue.setText("Объёмная очередь");
        styleSwitch(depthQueue);
        depthQueue.setChecked(getSharedPreferences("appearance",MODE_PRIVATE)
            .getBoolean("nw-depth-queue",true));
        depthQueue.setOnCheckedChangeListener((view,enabled)->
            getSharedPreferences("appearance",MODE_PRIVATE).edit()
                .putBoolean("nw-depth-queue",enabled).apply());
        panel.addView(depthQueue);
        TextView depthHint=text("Стопка обложек и быстрый выбор следующей песни. Если выключить, останется обычная очередь.",12);
        depthHint.setTextColor(0xff9fa6b8);panel.addView(depthHint);
        android.widget.Switch kineticText=new android.widget.Switch(this);
        kineticText.setText("Кинетический текст песен");
        styleSwitch(kineticText);
        kineticText.setChecked(getSharedPreferences("appearance",MODE_PRIVATE)
            .getBoolean("nw-kinetic-lyrics",true));
        kineticText.setOnCheckedChangeListener((view,enabled)->
            getSharedPreferences("appearance",MODE_PRIVATE).edit()
                .putBoolean("nw-kinetic-lyrics",enabled).apply());
        panel.addView(kineticText);
            android.widget.Switch animatedCover=new android.widget.Switch(this);
            animatedCover.setText("Анимация полноэкранной обложки");
            styleSwitch(animatedCover);
            animatedCover.setChecked(getSharedPreferences("appearance",MODE_PRIVATE)
                .getBoolean("nw-animated-album-artwork",true));
            animatedCover.setEnabled(!"classic".equals(getSharedPreferences("appearance",MODE_PRIVATE)
                .getString("nw-cover-style","immersive")));
            animatedCover.setOnCheckedChangeListener((button,enabled)->{
                getSharedPreferences("appearance",MODE_PRIVATE).edit()
                    .putBoolean("nw-animated-album-artwork",enabled).apply();
                if(full)openPlayer();
            });
            panel.addView(animatedCover);
        }else if("Воспроизведение".equals(page)){
            android.widget.Switch keepPlaying=new android.widget.Switch(this);
            keepPlaying.setText("Играть текущий трек до готовности следующего");
            styleSwitch(keepPlaying);
            keepPlaying.setChecked(getSharedPreferences("playback",MODE_PRIVATE)
                .getBoolean("nw-keep-current-until-ready",true));
            keepPlaying.setOnCheckedChangeListener((button,enabled)->{
                getSharedPreferences("playback",MODE_PRIVATE).edit()
                    .putBoolean("nw-keep-current-until-ready",enabled).apply();
                if(playback!=null)playback.settingKeepCurrentUntilReady(enabled);
            });
            panel.addView(keepPlaying);
            TextView keepHint=text("Название и обложка следующего трека появляются во время подготовки. Предыдущий продолжает звучать до готовности нового.",12);
            keepHint.setTextColor(0xffaeb2ba);panel.addView(keepHint);
        android.widget.Switch autoFavorites=new android.widget.Switch(this);
        autoFavorites.setText("Автоматически скачивать избранное · Premium");
        styleSwitch(autoFavorites);
        autoFavorites.setChecked(autoFavoritesEnabled());
        autoFavorites.setEnabled(!user.isEmpty());
        autoFavorites.setOnCheckedChangeListener((b,enabled)->setAutoFavoritesEnabled(enabled));
        panel.addView(autoFavorites);
        TextView label=text("Переход между треками · 0.8 с",15);
        label.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);
        panel.addView(label);
        SeekBar duration=new SeekBar(this);duration.setMax(50);
        duration.setProgress((int)(getSharedPreferences("playback",MODE_PRIVATE).getFloat("nw-transition-seconds",.8f)*10));
        duration.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar b,int p,boolean fromUser){
                label.setText("Переход между треками · "+p/10.0+" с");
                if(fromUser&&playback!=null)playback.transitionDuration(p/10.0);
            }
            public void onStartTrackingTouch(SeekBar b){}
            public void onStopTrackingTouch(SeekBar b){}
        });
        panel.addView(duration);
        final int[] values={0,4,8,12};
        int selected=getSharedPreferences("playback",MODE_PRIVATE).getInt("nw-stream-buffer-seconds",0);
        int selectedIndex=0;
        for(int i=0;i<values.length;i++)if(values[i]==selected)selectedIndex=i;
        TextView bufferLabel=text("Буфер потока · "+(selected==0?"Быстрый (1 с)":selected+" с"),15);
        bufferLabel.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);
        panel.addView(bufferLabel);
        SeekBar buffer=new SeekBar(this);buffer.setMax(values.length-1);buffer.setProgress(selectedIndex);
        buffer.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar bar,int progress,boolean fromUser){
                int seconds=values[Math.min(values.length-1,Math.max(0,progress))];
                bufferLabel.setText("Буфер потока · "+(seconds==0?"Быстрый (1 с)":seconds+" с"));
                if(fromUser)getSharedPreferences("playback",MODE_PRIVATE).edit().putInt("nw-stream-buffer-seconds",seconds).apply();
            }
            public void onStartTrackingTouch(SeekBar bar){}
            public void onStopTrackingTouch(SeekBar bar){}
        });
        panel.addView(buffer);
        TextView equalLabel=text("Одинаковая громкость · Выкл.",15);
        equalLabel.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);
        panel.addView(equalLabel);
        SeekBar equalVolume=new SeekBar(this);equalVolume.setMax(10);
        int equalPreset=Math.max(0,Math.min(100,getSharedPreferences("playback",MODE_PRIVATE).getInt("nw-equal-volume",0)));
        equalVolume.setProgress(equalPreset/10);
        equalLabel.setText(equalPreset==0?"Одинаковая громкость · Выкл.":"Одинаковая громкость · "+equalPreset+"%");
        equalVolume.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar b,int value,boolean fromUser){
                int percent=value*10;
                equalLabel.setText(percent==0?"Одинаковая громкость · Выкл.":"Одинаковая громкость · "+percent+"%");
                if(fromUser){
                    getSharedPreferences("playback",MODE_PRIVATE).edit().putInt("nw-equal-volume",percent).apply();
                    if(playback!=null)playback.setEqualVolume(percent);
                }
            }
            public void onStartTrackingTouch(SeekBar b){}
            public void onStopTrackingTouch(SeekBar b){}
        });
        panel.addView(equalVolume);
        TextView loudnessHint=text("Выравнивает громкие записи по измеренному звуку без дополнительных сетевых запросов.",12);
        loudnessHint.setTextColor(0xffa3a3ae);panel.addView(loudnessHint);
        TextView hint=text("Быстрый режим уменьшает ожидание звука, 8–12 с помогают при нестабильной сети. Изменение применяется после полного перезапуска Nightwell Music.",12);
        hint.setTextColor(0xffa3a3ae);hint.setPadding(0,0,0,dp(12));panel.addView(hint);
        TextView metrics=text("Диагностика: "+(playback==null?"Плеер запускается":playback.playbackDiagnostics()),12);
        metrics.setTextColor(0xffbcbcc3);panel.addView(metrics);
        android.widget.Switch ambient=new android.widget.Switch(this);
        ambient.setText("Показывать текст рядом с лентами");
        styleSwitch(ambient);
        ambient.setChecked(getSharedPreferences("appearance",MODE_PRIVATE).getBoolean("ambient-lyrics",true));
        ambient.setOnCheckedChangeListener((button,checked)->getSharedPreferences("appearance",MODE_PRIVATE).edit().putBoolean("ambient-lyrics",checked).apply());
        panel.addView(ambient);
        }else if("Оформление".equals(page)){
        panel.addView(sheetAction("Темы и ленты · Premium",()->feature("appearance")));

        }else{
        TextView version=text("Nightwell Music "+BuildConfig.VERSION_NAME+" ("+BuildConfig.VERSION_CODE+")",12);
        version.setTextColor(0xff9696a1);version.setPadding(0,dp(12),0,0);panel.addView(version);
        }
        arrangeSettingsControls(panel);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle(page).setView(scroll)
            .setPositiveButton("Назад",(d,w)->settings())
            .setNegativeButton("Закрыть",null).create();
        styleNavigationSheet(dialog);dialog.show();
    }

    private JSONObject premiumPrefs=new JSONObject();private String premiumOwner="";private long premiumUntil,premiumChecked;private boolean premiumLoading;
    boolean premiumAllowed(){return !user.isEmpty()&&user.equals(premiumOwner)&&System.currentTimeMillis()<premiumUntil;}
    void applyPremium(){
        boolean allowed=premiumAllowed();double[] values=new double[5];JSONArray raw=premiumPrefs.optJSONArray("bands");if(allowed&&raw!=null)for(int i=0;i<5;i++)values[i]=raw.optDouble(i,0);
        if(playback!=null)playback.premiumEqualizer.set(values,allowed?premiumUntil:0);
        if(ribbon!=null){ribbon.premiumSpeed=allowed?premiumPrefs.optDouble("ribbon_speed",1):1;ribbon.premiumIntensity=allowed?premiumPrefs.optDouble("ribbon_intensity",1):1;ribbon.premiumTheme=allowed?premiumPrefs.optString("theme","nightwell"):"nightwell";ribbon.colorSpeed=allowed?getSharedPreferences("aura-color-speed",MODE_PRIVATE).getFloat(user,1):1;}
        if(ribbon!=null){
            android.content.SharedPreferences aura=getSharedPreferences("aura-response",MODE_PRIVATE);
            ribbon.setAuraResponse(aura.getBoolean(user+"|aura_voice",true),aura.getBoolean(user+"|aura_low",true),aura.getBoolean(user+"|aura_mid",true),aura.getBoolean(user+"|aura_high",true));
        }
        if(root!=null){String theme=allowed?premiumPrefs.optString("theme"):"";int tint=theme.equals("aurora")?0x66105a45:theme.equals("ocean")?0x660c3f73:theme.equals("sunset")?0x6682282d:Color.TRANSPARENT;root.setBackgroundColor(tint);}
    }
    void premiumTick(){if(!premiumOwner.equals(user)||premiumUntil>0&&!premiumAllowed()){premiumUntil=0;premiumPrefs=new JSONObject();premiumOwner=user;premiumChecked=0;applyPremium();}if(!premiumLoading&&System.currentTimeMillis()-premiumChecked>300000)loadPremium(()->{});}
    void loadPremium(Runnable done){if(premiumLoading)return;premiumLoading=true;premiumChecked=System.currentTimeMillis();String owner=user;premiumUntil=0;applyPremium();io.execute(()->{
        JSONObject prefs=null;long expiry=0;try{JSONObject state=api.request("api/premium/me");if(state.optBoolean("premium")){prefs=api.request("api/premium/preferences").getJSONObject("preferences");expiry=(long)(state.optDouble("expires_at")*1000);}}catch(Exception ignored){}
        final JSONObject result=prefs;final long until=expiry;ui.post(()->{premiumLoading=false;if(isDestroyed()||!owner.equals(user))return;premiumOwner=owner;premiumPrefs=result==null?new JSONObject():result;premiumUntil=until;applyPremium();done.run();});
    });}
    void feature(String kind){loadPremium(()->{if(!premiumAllowed()){status.setText("Для этой функции нужен Premium. Музыку можно слушать бесплатно.");return;}if(kind.equals("sound"))equalizerPanel();else if(kind.equals("appearance"))appearancePanel();else if(kind.equals("smart"))smartPanel();else statisticsPanel();});}
    void savePremium(TextView note){if(!premiumAllowed()){note.setText("Нужен действующий Premium");return;}String owner=user;try{JSONObject draft=new JSONObject(premiumPrefs.toString());draft.remove("aura_color_speed");task(()->api.request("api/premium/preferences","PUT",draft),data->{if(!owner.equals(user)){premiumUntil=0;applyPremium();return;}applyPremium();note.setText("Настройки сохранены в аккаунте.");});}catch(Exception e){note.setText("Не удалось сохранить настройки");}}
    private Dialog featureWindow;
    private Runnable presetAction;
    LinearLayout premiumCard(LinearLayout parent,String title){
        LinearLayout card=column();card.setPadding(dp(14),dp(12),dp(14),dp(12));card.setBackground(new NativeSurfaceDrawable(card,26));
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(9);parent.addView(card,lp);
        if(!title.isEmpty()){TextView label=text(title,17);label.setTextColor(0xfff3f3f5);label.setTypeface(null,android.graphics.Typeface.BOLD);label.setPadding(0,0,0,dp(8));card.addView(label);}return card;
    }
    TextView premiumAction(String label,Runnable action){TextView button=sheetAction(label,action);button.setMinHeight(dp(48));button.setPadding(dp(14),dp(10),dp(14),dp(10));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=dp(8);button.setLayoutParams(lp);if(label.startsWith("Сохранить")||label.equals("Проверить оплату")){button.setGravity(Gravity.CENTER);button.setTypeface(null,android.graphics.Typeface.BOLD);button.setTextColor(0xff191a20);button.setBackground(touchSurface(0xffeeeeee,24));}return button;}
    EditText premiumInput(String hint,int limit){EditText input=new EditText(this);input.setHint(hint);input.setTextColor(Color.WHITE);input.setHintTextColor(0xff999ca8);input.setSingleLine(true);input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(limit)});input.setPadding(dp(12),dp(12),dp(12),dp(12));input.setBackground(touchSurface(0xff292c33,22));return input;}
    Dialog premiumSheet(String title,LinearLayout panel,boolean compact,Runnable extra){
        Dialog dialog=new Dialog(this);LinearLayout shell=column();shell.setPadding(dp(14),dp(8),dp(14),dp(10));GradientDrawable sheet=surface();sheet.setColor(0xff17191f);sheet.setCornerRadius(dp(30));shell.setBackground(sheet);
        View handle=new View(this);GradientDrawable bar=new GradientDrawable();bar.setColor(0xff454852);bar.setCornerRadius(dp(3));handle.setBackground(bar);LinearLayout.LayoutParams hp=new LinearLayout.LayoutParams(dp(36),dp(4));hp.gravity=Gravity.CENTER_HORIZONTAL;hp.bottomMargin=dp(8);shell.addView(handle,hp);
        LinearLayout header=row();TextView heading=text(title,21);heading.setTypeface(null,android.graphics.Typeface.BOLD);header.addView(heading,new LinearLayout.LayoutParams(0,-2,1));
        if(extra!=null){TextView more=iconButton("⋯",extra);more.setContentDescription("Дополнительные настройки эквалайзера");header.addView(more,new LinearLayout.LayoutParams(dp(48),dp(48)));}
        TextView close=iconButton("×",dialog::dismiss);close.setContentDescription("Готово");header.addView(close,new LinearLayout.LayoutParams(dp(48),dp(48)));shell.addView(header);
        panel.setPadding(dp(2),dp(8),dp(2),dp(2));ScrollView scroll=new ScrollView(this);scroll.setFillViewport(false);scroll.setClipToPadding(false);scroll.addView(panel);shell.addView(scroll,new LinearLayout.LayoutParams(-1,-2));
        dialog.setContentView(shell);Window w=dialog.getWindow();if(w!=null){w.setBackgroundDrawableResource(android.R.color.transparent);w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);w.setDimAmount(.65f);w.setGravity(Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);}
        shell.getViewTreeObserver().addOnGlobalLayoutListener(()->{int max=(int)(getResources().getDisplayMetrics().heightPixels*.82)-header.getHeight()-dp(55);if(panel.getHeight()>max&&scroll.getLayoutParams().height!=max){scroll.getLayoutParams().height=max;scroll.requestLayout();}else if(panel.getHeight()<max&&scroll.getLayoutParams().height!=-2){scroll.getLayoutParams().height=-2;scroll.requestLayout();}});
        dialog.setOnShowListener(d->{Window win=dialog.getWindow();if(win==null)return;int width=Math.min(dp(520),getResources().getDisplayMetrics().widthPixels-dp(24));win.setLayout(width,-2);WindowManager.LayoutParams attrs=win.getAttributes();attrs.y=dp(6);win.setAttributes(attrs);shell.post(()->{int limit=(int)(getResources().getDisplayMetrics().heightPixels*.88);if(shell.getHeight()>limit)scroll.getLayoutParams().height=Math.max(dp(120),limit-header.getHeight()-dp(55));scroll.requestLayout();});shell.setAlpha(0);shell.setScaleX(.94f);shell.setScaleY(.94f);shell.setTranslationY(dp(22));shell.animate().alpha(1).scaleX(1).scaleY(1).translationY(0).setDuration(340).setInterpolator(new android.view.animation.DecelerateInterpolator()).start();});
        return dialog;
    }
    void featureDialog(String title,LinearLayout panel){if(featureWindow!=null)featureWindow.dismiss();Dialog dialog=premiumSheet(title,panel,false,title.equals("Эквалайзер")?presetAction:null);featureWindow=dialog;dialog.setOnDismissListener(d->{if(featureWindow==dialog)featureWindow=null;});dialog.show();}
    void equalizerPanel(){
        LinearLayout panel=column(),card=premiumCard(panel,"Звук под вас · ±6 дБ");
        TextView note=text("Настройте звучание под себя",14);note.setTextColor(0xffa4a6b1);note.setPadding(0,0,0,dp(12));card.addView(note);
        final String[] names={"Без изменений","Бас","Вокал","Мягкий звук"};final double[][] presets={{0,0,0,0,0},{4,2,0,-1,0},{-2,0,3,2,-1},{1,0,-1,-2,-3}};
        final String[] chosen={""};SeekBar[] sliders=new SeekBar[5];
        final TextView[] selectorRef=new TextView[1];
        TextView selector=premiumAction("Пресет · Свои настройки  ▾",()->{
            ArrayList<String> choices=new ArrayList<>(Arrays.asList(names));JSONObject custom=premiumPrefs.optJSONObject("presets");if(custom!=null)custom.keys().forEachRemaining(choices::add);
            nightwellOptions("Пресет",choices.toArray(new String[0]),index->{double[] selected=new double[5];if(index<4)selected=presets[index];else{JSONArray own=premiumPrefs.optJSONObject("presets").optJSONArray(choices.get(index));for(int i=0;i<5;i++)selected[i]=own.optDouble(i);}
                try{JSONArray bands=new JSONArray();for(double db:selected)bands.put(db);premiumPrefs.put("bands",bands);}catch(JSONException ignored){}
                for(int i=0;i<5;i++)sliders[i].setProgress((int)((selected[i]+6)*2));chosen[0]=choices.get(index);selectorRef[0].setText("Пресет · "+chosen[0]+"  ▾");applyPremium();savePremium(note);
            });
        });selectorRef[0]=selector;card.addView(selector);
        LinearLayout rack=row();rack.setPadding(0,dp(16),0,dp(16));card.addView(rack);String[] frequencies={"60","250","1k","4k","12k"};JSONArray values=premiumPrefs.optJSONArray("bands");
        for(int i=0;i<5;i++){final int band=i;LinearLayout lane=column();lane.setGravity(Gravity.CENTER);rack.addView(lane,new LinearLayout.LayoutParams(0,-2,1));double initial=values==null?0:values.optDouble(i);TextView label=text(String.format(Locale.ROOT,"%+.1f",initial),12);lane.addView(label);VerticalEqualizerSlider slider=new VerticalEqualizerSlider(this);slider.setContentDescription(new String[]{"60 Гц","250 Гц","1 кГц","4 кГц","12 кГц"}[i]);slider.setProgressTintList(android.content.res.ColorStateList.valueOf(0xffeeeeee));slider.setThumbTintList(android.content.res.ColorStateList.valueOf(0xffeeeeee));slider.setProgress((int)((initial+6)*2));sliders[i]=slider;
            slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onProgressChanged(SeekBar b,int value,boolean fromUser){double db=value/2.0-6;try{premiumPrefs.getJSONArray("bands").put(band,db);}catch(Exception ignored){}label.setText(String.format(Locale.ROOT,"%+.1f",db));if(fromUser){chosen[0]="";selector.setText("Пресет · Свои настройки  ▾");}applyPremium();}public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){savePremium(note);}});
            slider.onCommit=()->{chosen[0]="";selector.setText("Пресет · Свои настройки  ▾");savePremium(note);};lane.addView(slider,new LinearLayout.LayoutParams(dp(40),dp(180)));lane.addView(text(frequencies[i],12));
        }
        presetAction=()->{
            LinearLayout options=column(),entry=premiumCard(options,"Свой пресет");EditText name=premiumInput("Название",40);entry.addView(name);TextView result=text("Можно сохранить до восьми пресетов",14);entry.addView(result);
            entry.addView(premiumAction("Сохранить пресет",()->{String key=name.getText().toString().trim();if(key.isEmpty()||Arrays.asList(names).contains(key)||Arrays.asList("__proto__","constructor","prototype").contains(key)){result.setText("Введите другое название");return;}try{JSONObject own=premiumPrefs.optJSONObject("presets");if(own==null){own=new JSONObject();premiumPrefs.put("presets",own);}if(!own.has(key)&&own.length()>=8){result.setText("Можно сохранить до восьми пресетов");return;}own.put(key,new JSONArray(premiumPrefs.getJSONArray("bands").toString()));chosen[0]=key;selector.setText("Пресет · "+key+"  ▾");savePremium(result);}catch(Exception e){result.setText("Не удалось сохранить пресет");}}));
            if(!chosen[0].isEmpty()&&premiumPrefs.optJSONObject("presets")!=null&&premiumPrefs.optJSONObject("presets").has(chosen[0]))entry.addView(premiumAction("Удалить свой пресет",()->{premiumPrefs.optJSONObject("presets").remove(chosen[0]);chosen[0]="";selector.setText("Пресет · Свои настройки  ▾");savePremium(result);}));
            premiumSheet("Настройки эквалайзера",options,true,null).show();
        };
        featureDialog("Эквалайзер",panel);
    }
    void appearancePanel(){
        LinearLayout panel=column(),card=premiumCard(panel,"Ваше оформление");TextView note=text("Цвет и движение музыкальной ауры",14);note.setTextColor(0xffa4a6b1);note.setPadding(0,0,0,dp(12));card.addView(note);
        String[][] options={{"Nightwell","Северное сияние","Океан","Закат"},{"Медленно","Обычно","Быстро"},{"Мягко","Обычно","Ярко"},{"Медленно","Обычно","Быстро"}};String[] keys={"theme","ribbon_speed","ribbon_intensity","aura_color_speed"},titles={"Фон","Скорость лент","Выразительность","Смена цветов"},themes={"nightwell","aurora","ocean","sunset"};
        for(int i=0;i<4;i++){final int key=i;int selected=i==0?Math.max(0,Arrays.asList(themes).indexOf(premiumPrefs.optString("theme"))):(i==3?getSharedPreferences("aura-color-speed",MODE_PRIVATE).getFloat(user,1):premiumPrefs.optDouble(keys[i],1))==.5?0:(i==3?getSharedPreferences("aura-color-speed",MODE_PRIVATE).getFloat(user,1):premiumPrefs.optDouble(keys[i],1))==1?1:2;
            TextView choice=premiumAction(titles[i]+" · "+options[i][selected]+"  ▾",()->{});choice.setOnClickListener(v->nightwellOptions(titles[key],options[key],n->{try{premiumPrefs.put(keys[key],key==0?themes[n]:new double[]{.5,1,1.5}[n]);if(key==3)getSharedPreferences("aura-color-speed",MODE_PRIVATE).edit().putFloat(user,(float)new double[]{.5,1,1.5}[n]).apply();choice.setText(titles[key]+" · "+options[key][n]+"  ▾");applyPremium();}catch(Exception ignored){}}));card.addView(choice);
        }
        card.addView(sectionLabel("Реакция ауры"));
        TextView explanation=text("Выбери, на какие составляющие музыки будет реагировать аура. Можно включить несколько сразу.",13);
        explanation.setTextColor(0xffa9aec0);explanation.setPadding(0,dp(4),0,dp(8));card.addView(explanation);
        String[] auraLabels={"Голос","Низкие частоты","Средние частоты","Высокие частоты"};
        String[] names={"aura_voice","aura_low","aura_mid","aura_high"};
        android.content.SharedPreferences appearance=getSharedPreferences("aura-response",MODE_PRIVATE);
        for(int i=0;i<names.length;i++){
            final String name=names[i];
            android.widget.Switch toggle=new android.widget.Switch(this);
            toggle.setText(auraLabels[i]);styleSwitch(toggle);
            toggle.setChecked(appearance.getBoolean(user+"|"+name,true));
            toggle.setOnCheckedChangeListener((button,enabled)->{
                appearance.edit().putBoolean(user+"|"+name,enabled).apply();
                if(ribbon!=null)ribbon.setAuraResponse(appearance.getBoolean(user+"|aura_voice",true),appearance.getBoolean(user+"|aura_low",true),appearance.getBoolean(user+"|aura_mid",true),appearance.getBoolean(user+"|aura_high",true));
            });
            card.addView(toggle);
        }
        card.addView(premiumAction("Сохранить оформление",()->savePremium(note)));featureDialog("Оформление",panel);
    }
    void dailyPublicPlaylists(){
        final String owner=user;
        if(owner.isEmpty()){auth();return;}
        task(()->api.request("api/daily-public-playlists"),data->{
            if(!owner.equals(user))return;
            JSONArray items=data.optJSONArray("playlists");
            LinearLayout outer=column(),panel=premiumCard(outer,"Подборки дня");
            panel.addView(text("Обновляются раз в сутки для твоего аккаунта",14));
            if(items==null||items.length()==0)panel.addView(text("Пока нет доступных подборок",14));
            for(int i=0;items!=null&&i<items.length();i++){
                JSONObject playlist=items.optJSONObject(i);
                if(playlist==null)continue;
                JSONArray tracks=playlist.optJSONArray("tracks");
                LinearLayout dailyRow=row();
                TextView listen=sheetAction("▶ "+playlist.optString("name")+" · "+playlist.optInt("count")+" треков",()->{
                    if(tracks!=null&&tracks.length()>0)play(tracks.optJSONObject(0),tracks,false);
                    else status.setText("В подборке пока нет музыки");
                });
                dailyRow.addView(listen,new LinearLayout.LayoutParams(0,-2,1));
                final TextView[] saveRef=new TextView[1];
                TextView save=iconButton(playlist.optBoolean("saved")?"♥":"♡",()->{
                    if(playlist.optBoolean("saved"))return;
                    JSONArray trackIDs=new JSONArray();
                    if(tracks!=null)for(int k=0;k<tracks.length();k++){
                        JSONObject item=tracks.optJSONObject(k);if(item!=null)trackIDs.put(item.optString("id"));
                    }
                    final String savedOwner=user;
                    task(()->api.request("api/daily-public-playlists/"+
                       Uri.encode(playlist.optString("id"))+"/save","POST",
                       new JSONObject().put("track_ids",trackIDs)),result->{
                        if(!savedOwner.equals(user))return;
                        saveRef[0].setText("♥");saveRef[0].setContentDescription("Сохранено в плейлисты с датой");
                        playlist.remove("saved");
                        try{playlist.put("saved",true);}catch(Exception ignored){}
                        status.setText("Сохранено в плейлисты: "+result.optString("name"));
                        loadLibrary(user);
                    });
                });
                saveRef[0]=save;
                save.setContentDescription(playlist.optBoolean("saved")?"Сохранено в плейлисты":"Сохранить подборку в плейлисты");
                dailyRow.addView(save,new LinearLayout.LayoutParams(dp(52),dp(56)));
                panel.addView(dailyRow);
            }
            featureDialog("Подборки дня",outer);
        });
    }
    void smartPanel(){String owner=user;task(()->api.request("api/premium/smart-playlists"),data->{if(!owner.equals(user))return;LinearLayout outer=column(),panel=premiumCard(outer,"Ваши подборки");panel.addView(text("Состав пересчитывается при открытии. История — за последние 90 дней.",14));JSONArray rules=data.optJSONArray("playlists");for(int i=0;rules!=null&&i<rules.length();i++){JSONObject rule=rules.optJSONObject(i);String id=rule.optString("id");panel.addView(sheetAction("▶ "+rule.optString("name"),()->task(()->api.request("api/premium/smart-playlists/"+Uri.encode(id)+"/tracks"),result->{if(!owner.equals(user))return;JSONArray items=result.optJSONArray("tracks");if(items!=null&&items.length()>0){play(items.optJSONObject(0),items,false);}else status.setText("Пока нет подходящих треков");})));panel.addView(sheetAction("Удалить «"+rule.optString("name")+"»",()->task(()->api.request("api/premium/smart-playlists/"+Uri.encode(id),"DELETE",null),v->smartPanel())));}
        EditText name=new EditText(this);name.setHint("Название подборки");name.setTextColor(Color.WHITE);name.setFilters(new InputFilter[]{new InputFilter.LengthFilter(60)});panel.addView(name);Spinner kind=new Spinner(this);kind.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"Избранное","Недавно добавленные","Не слушал 14 дней"}));panel.addView(kind);panel.addView(sheetAction("Создать умный плейлист",()->{if(name.getText().toString().trim().isEmpty())return;String ruleTitle=name.getText().toString().trim(),ruleType=new String[]{"favorites","recently_added","long_unheard"}[kind.getSelectedItemPosition()];task(()->api.request("api/premium/smart-playlists","POST",new JSONObject().put("name",ruleTitle).put("kind",ruleType).put("days",14).put("track_limit",50)),v->smartPanel());}));featureDialog("Умные плейлисты",outer);});}
    void statisticsPanel(){String owner=user;task(()->api.request("api/premium/statistics"),data->{if(!owner.equals(user))return;LinearLayout outer=column(),panel=premiumCard(outer,"Последние 90 дней");panel.addView(text("Прослушано: "+Math.round(data.optDouble("seconds")/60)+" мин. · Сессий: "+data.optInt("sessions")+"\nПоследние 90 дней. Месяцы по UTC.",17));String[] keys={"months","artists","tracks"},titles={"По месяцам","Любимые исполнители","Любимые треки"},labels={"month","artist","title"};for(int i=0;i<3;i++){panel=premiumCard(outer,titles[i]);JSONArray rows=data.optJSONArray(keys[i]);for(int k=0;rows!=null&&k<rows.length();k++){JSONObject row=rows.optJSONObject(k);panel.addView(text(row.optString(labels[i])+" · "+Math.round(row.optDouble("seconds")/60)+" мин.",15));}}featureDialog("Моя статистика",outer);});}

    private Runnable premiumRefresh;
    void premium(){
        LinearLayout panel=column();panel.setPadding(dp(20),dp(14),dp(20),dp(20));
        TextView summary=text("150 ₽ за 30 дней. Автопродление зависит от условий Lava.\nМузыку можно слушать бесплатно. Premium открывает скачивания, эквалайзер с пресетами, оформление, умные плейлисты и статистику. Эквалайзер — в трёх точках плеера; оформление — в настройках; умные подборки — в плейлистах; статистика — в меню.",16);panel.addView(summary);
        LinearLayout active=column();active.setGravity(Gravity.CENTER_HORIZONTAL);active.setVisibility(View.GONE);panel.addView(active);
        TextView checkmark=text("✓",56);checkmark.setTextColor(0xff101d13);checkmark.setGravity(Gravity.CENTER);GradientDrawable medallion=new GradientDrawable(GradientDrawable.Orientation.TL_BR,new int[]{0xff90ffc0,0xff29c76c});medallion.setShape(GradientDrawable.OVAL);checkmark.setBackground(medallion);checkmark.setElevation(dp(10));LinearLayout.LayoutParams checkParams=new LinearLayout.LayoutParams(dp(80),dp(80));checkParams.gravity=Gravity.CENTER_HORIZONTAL;checkParams.bottomMargin=dp(10);active.addView(checkmark,checkParams);
        TextView activeTitle=text("Подписка активна",27);activeTitle.setGravity(Gravity.CENTER);active.addView(activeTitle);
        TextView activeDate=text("",17);activeDate.setGravity(Gravity.CENTER);active.addView(activeDate);
        LinearLayout hints=column();hints.setVisibility(View.GONE);
        TextView features=premiumAction("Функции Premium  ▾",()->{android.animation.LayoutTransition transition=new android.animation.LayoutTransition();transition.setDuration(260);active.setLayoutTransition(transition);hints.setVisibility(hints.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE);});active.addView(features);active.addView(hints);
        String[][] items={{"Скачивания","Меню трека → Скачать"},{"Эквалайзер","Три точки в большом плеере"},{"Оформление","Меню приложения → Настройки"},{"Умные плейлисты","Плейлисты → Умные плейлисты"},{"Статистика","Меню приложения → Моя статистика"}};
        for(String[] item:items){LinearLayout itemView=premiumCard(hints,item[0]);TextView hint=text(item[1],14);hint.setTextColor(0xffaab4c7);itemView.addView(hint);}
        TextView renewalNote=text("",14);active.addView(renewalNote);
        TextView renewalCancel=premiumAction("Отключить автопродление",()->{});renewalCancel.setVisibility(View.GONE);active.addView(renewalCancel);
        TextView note=text("Проверяем подписку…",15);panel.addView(note);
        TextView terms=text(PremiumTerms.TEXT,15);terms.setTextIsSelectable(true);terms.setVisibility(View.GONE);
        TextView read=sheetAction("Условия подписки",()->terms.setVisibility(terms.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE));panel.addView(read);panel.addView(terms);
        // Seller details remain available in the expandable Premium terms, not in the purchase sheet.
        CheckBox consent=new CheckBox(this);consent.setText("Я ознакомился с условиями Premium и согласен с оплатой на указанный срок");consent.setTextColor(0xfff3f3f5);consent.setMinHeight(dp(48));panel.addView(consent);
        panel.addView(text("Оплата откроется в браузере. Войдите на сайте в тот же аккаунт, что и в приложении, и подтвердите актуальные условия. Доступность оплаты проверяется на сайте.",14));
        Button pay=new Button(this);pay.setText("Перейти к оплате на сайте");pay.setEnabled(false);panel.addView(pay);
        consent.setOnCheckedChangeListener((button,checked)->pay.setEnabled(checked&&BuildConfig.EXTERNAL_PREMIUM_PAYMENTS));
        if(!BuildConfig.EXTERNAL_PREMIUM_PAYMENTS)panel.addView(text("Внешняя оплата отключена в этой сборке.",14));
        pay.setOnClickListener(v->{if(!consent.isChecked()||!BuildConfig.EXTERNAL_PREMIUM_PAYMENTS)return;Uri url=Uri.parse(origin).buildUpon().path("/premium.html").clearQuery().fragment(null).build();if(!"https".equals(url.getScheme()))return;try{startActivity(new Intent(Intent.ACTION_VIEW,url));}catch(ActivityNotFoundException e){note.setText("Установите браузер для открытия страницы.");}});
        TextView refresh=premiumAction("Проверить оплату",()->{});panel.addView(refresh);
        panel.addView(text("Возврат из браузера сам по себе не подтверждает оплату. Статус проверяет сервер.",14));
        ScrollView scroll=new ScrollView(this);scroll.addView(panel);
        scroll.removeView(panel);Dialog dialog=premiumSheet("Nightwell Premium",panel,true,null);
        final boolean[] checking={false};
        renewalCancel.setOnClickListener(v->new AlertDialog.Builder(this).setTitle("Отключить автопродление?").setMessage("Оплаченный Premium останется активным до конца срока.").setNegativeButton("Назад",null).setPositiveButton("Отключить",(d,w)->{
            renewalCancel.setEnabled(false);String owner=user;
            io.execute(()->{boolean ok=false;try{JSONObject result=api.request("api/premium/lava/cancel-renewal","POST",new JSONObject());ok="disabled".equals(result.optString("auto_renewal"));}catch(Exception ignored){}
                final boolean confirmed=ok;ui.post(()->{if(isDestroyed()||!dialog.isShowing()||!owner.equals(user))return;renewalCancel.setEnabled(true);renewalNote.setText(confirmed?"Автопродление отключено. Оплаченный срок сохранён.":"Lava не подтвердила отмену.");if(confirmed)renewalCancel.setVisibility(View.GONE);});});
        }).show());
        Runnable check=()->{if(checking[0]||!dialog.isShowing())return;checking[0]=true;refresh.setEnabled(false);String owner=user;io.execute(()->{
            String message,renewalText="";long expiry=0;boolean allowCancel=false;try{JSONObject value=api.request("api/premium/me");expiry=value.optBoolean("premium")?(long)(value.optDouble("expires_at",0)*1000):0;message=expiry>System.currentTimeMillis()?"":value.optBoolean("test_premium")?"Тестовый платёж подтверждён; платная подписка не активирована.":"Активной подписки нет.";if(expiry>System.currentTimeMillis())try{JSONObject renewal=api.request("api/premium/lava/renewal");boolean subscribed=renewal.optBoolean("has_lava_subscription"),disabled="disabled".equals(renewal.optString("auto_renewal"));allowCancel=subscribed&&!disabled;renewalText=disabled?"Автопродление отключено":subscribed?"Статус автопродления не подтверждён":"Автопродление не требуется";}catch(Exception e){renewalText="Статус автопродления недоступен";}}catch(Exception e){message="Статус недоступен. Войдите в аккаунт и проверьте соединение.";}
            final String result=message,renewalLabel=renewalText;final long until=expiry;final boolean showCancel=allowCancel;ui.post(()->{checking[0]=false;if(isDestroyed()||!dialog.isShowing())return;refresh.setEnabled(true);if(!owner.equals(user)){consent.setChecked(false);note.setText("Аккаунт изменился. Откройте Premium заново.");return;}boolean enabled=until>System.currentTimeMillis();active.setVisibility(enabled?View.VISIBLE:View.GONE);summary.setVisibility(enabled?View.GONE:View.VISIBLE);read.setVisibility(enabled?View.GONE:View.VISIBLE);terms.setVisibility(View.GONE);consent.setVisibility(enabled?View.GONE:View.VISIBLE);pay.setVisibility(enabled?View.GONE:View.VISIBLE);refresh.setText(enabled?"Обновить статус":"Проверить оплату");for(int i=0;i<panel.getChildCount();i++){View child=panel.getChildAt(i);if(child!=active&&child!=note&&child!=refresh)child.setVisibility(enabled?View.GONE:View.VISIBLE);}terms.setVisibility(View.GONE);renewalNote.setText(enabled?renewalLabel:"");renewalCancel.setVisibility(enabled&&showCancel?View.VISIBLE:View.GONE);activeDate.setText(enabled?"Активна до "+java.text.DateFormat.getDateInstance(java.text.DateFormat.LONG,new java.util.Locale("ru","RU")).format(new java.util.Date(until)):"");if(enabled){checkmark.setScaleX(.45f);checkmark.setScaleY(.45f);checkmark.setAlpha(0f);checkmark.animate().scaleX(1f).scaleY(1f).alpha(1f).setDuration(420).start();}note.setText(result);});
        });};
        refresh.setOnClickListener(v->check.run());premiumRefresh=check;dialog.setOnDismissListener(d->{if(premiumRefresh==check)premiumRefresh=null;});dialog.show();check.run();
    }
    private AlertDialog activeAuthDialog;
    void auth(){
        if(activeAuthDialog!=null&&activeAuthDialog.isShowing())return;
        LinearLayout form=column();form.setPadding(dp(20),dp(4),dp(20),dp(8));
        TextView caption=text("Войди в аккаунт Nightwell Music или создай новый.",14);caption.setTextColor(0xff9fa6b8);caption.setPadding(0,0,0,dp(10));form.addView(caption);
        EditText email=new EditText(this),password=new EditText(this);
        email.setHint("Email");email.setInputType(33);password.setHint("Пароль");password.setInputType(129);
        styleField(email);styleField(password);
        LinearLayout.LayoutParams field=new LinearLayout.LayoutParams(-1,-2);field.bottomMargin=dp(10);
        form.addView(email,field);form.addView(password);
        TextView feedback=text("",13);feedback.setTextColor(0xffffb1b1);feedback.setPadding(0,dp(8),0,dp(4));feedback.setVisibility(View.GONE);form.addView(feedback);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Вход").setView(form)
            .setPositiveButton("Войти",null).setNeutralButton("Регистрация",null)
            .setNegativeButton("Отмена",null).create();
        styleSheet(dialog);dialog.setOnDismissListener(d->{if(activeAuthDialog==dialog)activeAuthDialog=null;});
        activeAuthDialog=dialog;dialog.show();
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->loginFromDialog(dialog,email,password,feedback,false));
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v->loginFromDialog(dialog,email,password,feedback,true));
    }
    void loginFromDialog(AlertDialog dialog,EditText email,EditText password,TextView feedback,boolean register){
        String address=email.getText().toString().trim(),secret=password.getText().toString();
        if(address.isEmpty()||secret.isEmpty()){feedback.setText("Введи email и пароль.");feedback.setVisibility(View.VISIBLE);return;}
        feedback.setText(register?"Регистрируем аккаунт…":"Выполняем вход…");feedback.setTextColor(0xffdddddd);feedback.setVisibility(View.VISIBLE);
        Button accept=dialog.getButton(AlertDialog.BUTTON_POSITIVE),signup=dialog.getButton(AlertDialog.BUTTON_NEUTRAL);
        accept.setEnabled(false);signup.setEnabled(false);
        final boolean[] pending={true};
        ui.postDelayed(()->{if(!pending[0]||isDestroyed()||!dialog.isShowing())return;pending[0]=false;accept.setEnabled(true);signup.setEnabled(true);feedback.setTextColor(0xffffb1b1);feedback.setText("Вход не завершился за 35 секунд. Сервер не отвечает приложению. Попробуй снова.");},35000);
        io.execute(()->{
            try{
                JSONObject response=api.request(register?"api/register":"api/login","POST",
                    new JSONObject().put("email",address).put("password",secret));
                ui.post(()->{
                    if(!pending[0]||isDestroyed()||!dialog.isShowing())return;
                    pending[0]=false;accept.setEnabled(true);signup.setEnabled(true);
                    api.updateCSRF(response.optString("csrf"));
                    feedback.setText("Вход выполнен. Загружаем аккаунт…");
                    dialog.dismiss();
                    load();
                });
            }catch(Exception error){
                ui.post(()->{
                    if(!pending[0]||isDestroyed()||!dialog.isShowing())return;
                    pending[0]=false;accept.setEnabled(true);signup.setEnabled(true);
                    feedback.setTextColor(0xffffb1b1);
                    feedback.setText("Не удалось войти: "+friendly(error));
                    feedback.setVisibility(View.VISIBLE);
                });
            }
        });
    }
    android.view.GestureDetector gestures(boolean expanded){return new android.view.GestureDetector(this,new android.view.GestureDetector.SimpleOnGestureListener(){public boolean onDown(android.view.MotionEvent e){return true;}public boolean onSingleTapUp(android.view.MotionEvent e){if(!expanded)openPlayer();return true;}public boolean onFling(android.view.MotionEvent start,android.view.MotionEvent end,float vx,float vy){if(start==null||end==null)return false;float dx=end.getX()-start.getX(),dy=end.getY()-start.getY();if(Math.abs(dx)>dp(65)&&Math.abs(dx)>Math.abs(dy)*1.25f){if(playback==null)return false;if(dx<0)nextTrack();else previous();return true;}if(expanded&&dy>dp(90)&&dy>Math.abs(dx)*1.35f){full=false;build();return true;}return false;}});}
    @Override public void onBackPressed(){if(backgroundOnly){backgroundOnly=false;build();}else if(full){full=false;build();}else if(!screen.equals("Главная"))navigate("Главная");else super.onBackPressed();}
    void importFiles(){Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("audio/*").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);startActivityForResult(i,72);}
    void handleAudioImportResult(int request,int result,Intent data){if(request!=72||result!=RESULT_OK||data==null)return;ArrayList<Uri> uris=new ArrayList<>();if(data.getClipData()!=null)for(int i=0;i<data.getClipData().getItemCount();i++)uris.add(data.getClipData().getItemAt(i).getUri());else if(data.getData()!=null)uris.add(data.getData());io.execute(()->{for(Uri uri:uris)try{OfflineStore.importFile(this,origin,uri);}catch(Exception ex){ui.post(()->status.setText("Не удалось импортировать файл"));}ui.post(()->navigate("Офлайн"));});}
    final class TrackAdapter extends BaseAdapter {
        public int getCount(){return shown.length();}public Object getItem(int p){return shown.optJSONObject(p);}public long getItemId(int p){return p;}
        public View getView(int position,View recycled,ViewGroup parent){LinearLayout r;TextView title,artist,more;if(recycled==null){r=row();r.setPadding(dp(12),dp(12),dp(8),dp(12));LinearLayout labels=column();title=text("",16);title.setMaxLines(2);artist=text("",12);artist.setMaxLines(1);labels.addView(title);labels.addView(artist);r.addView(labels,new LinearLayout.LayoutParams(0,-2,1));r.addView(new PlayingIndicator(MainActivity.this),new LinearLayout.LayoutParams(dp(20),dp(20)));more=action("⋯",()->{});r.addView(more);r.setTag(new TextView[]{title,artist,more});}else r=(LinearLayout)recycled;TextView[] holder=(TextView[])r.getTag();JSONObject t=shown.optJSONObject(position);holder[0].setText(t.optString("title"));PlayingIndicator indicator=(PlayingIndicator)r.getChildAt(1);indicator.setVisibility(currentID.equals(t.optString("id"))?View.VISIBLE:View.GONE);indicator.playing(lastPlaying);holder[1].setText(t.optString("artist"));holder[1].setOnClickListener(v->play(t,shown,false));holder[1].setContentDescription("Воспроизвести "+t.optString("title"));holder[2].setOnClickListener(v->trackMenu(t));r.setOnClickListener(v->play(t,shown,false));r.setContentDescription("Воспроизвести "+t.optString("title"));r.setBackgroundColor(currentID.equals(t.optString("id"))?0x22ffb260:Color.TRANSPARENT);return r;}
    }
    private String favoriteOrder="recent";
    private void favoriteSortMenu(){
        loadPremium(()->{
            if(!premiumAllowed()){premium();return;}
            String[] variants={"Недавние","По названию","По исполнителю"};
            nightwellOptions("Сортировка · Premium",variants,index->{favoriteOrder=new String[]{"recent","title","artist"}[index];selectMenu("Избранное");});
        });
    }
    private JSONArray sortedFavorites(JSONArray items){
        if(!premiumAllowed()||favoriteOrder.equals("recent"))return items;
        ArrayList<JSONObject> result=new ArrayList<>();
        for(int i=0;i<items.length();i++){JSONObject item=items.optJSONObject(i);if(item!=null)result.add(item);}
        String column=favoriteOrder.equals("title")?"title":"artist";
        result.sort((a,b)->java.text.Collator.getInstance(new java.util.Locale("ru")).compare(a.optString(column),b.optString(column)));
        JSONArray sorted=new JSONArray();for(JSONObject item:result)sorted.put(item);return sorted;
    }
    void choosePlaylistDocument(){
        Intent choose=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try{startActivityForResult(choose,PLAYLIST_DOCUMENT);}catch(ActivityNotFoundException ex){if(transferNote!=null)transferNote.setText("На устройстве недоступен выбор файлов. Можно вставить список треков в поле ниже.");}
    }
    void handlePlaylistDocument(int result,Intent data){
        if(result!=RESULT_OK||data==null||data.getData()==null||transferDialog==null||!transferDialog.isShowing())return;
        final Uri uri=data.getData();final AlertDialog dialog=transferDialog;final EditText target=transferInput;final TextView note=transferNote;final int ticket=++transferReadGeneration;
        note.setText("Читаем файл…");dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(false);
        io.execute(()->{
            try{
                String name="Список треков";
                try(android.database.Cursor cursor=getContentResolver().query(uri,new String[]{android.provider.OpenableColumns.DISPLAY_NAME},null,null,null)){if(cursor!=null&&cursor.moveToFirst()&&!cursor.isNull(0))name=cursor.getString(0);}
                final String fileName=name;final String text;
                try(java.io.InputStream stream=getContentResolver().openInputStream(uri)){text=PlaylistImportFile.read(stream);}
                ui.post(()->{if(transferDialog!=dialog||!dialog.isShowing()||ticket!=transferReadGeneration)return;target.setText(text);note.setText("Выбран файл: "+fileName);dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(true);});
            }catch(Exception ex){ui.post(()->{if(transferDialog!=dialog||!dialog.isShowing()||ticket!=transferReadGeneration)return;note.setText(ex.getMessage()==null?"Не удалось прочитать файл":ex.getMessage());dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(true);});}
        });
    }
    private String transferKey="",transferStage="";
    private String transferMissingReport="";
    private Button transferMissingButton;
    private long transferSampleAt;
    private int transferSampleProgress;
    private boolean transferBusy;
    void transferRequest(Work work,Done done,TextView label,AlertDialog dialog){
        final String owner=user;final NativeAPI client=api;
        io.execute(()->{try{JSONObject value=work.run();ui.post(()->{if(!isDestroyed()&&dialog.isShowing()&&transferDialog==dialog&&owner.equals(user)&&client==api)done.run(value);});}
            catch(Exception ex){ui.post(()->{if(dialog.isShowing()&&transferDialog==dialog){transferBusy=false;label.setText(friendly(ex)+"\nНажми «Обновить», чтобы проверить состояние переноса.");dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(true);dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setText("Обновить");dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v->{if(transferKey.isEmpty()){transferRequest(()->client.request("api/imports"),r->{JSONArray jobs=r.optJSONArray("jobs");if(jobs!=null&&jobs.length()>0){transferKey=jobs.optJSONObject(0).optString("id");pollTransfer(transferKey,label,dialog);}else{label.setText("Перенос не запущен. Проверь список и повтори поиск.");dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setText("Найти треки");dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener((View.OnClickListener)dialog.getButton(AlertDialog.BUTTON_NEUTRAL).getTag());}},label,dialog);}else pollTransfer(transferKey,label,dialog);});}});}});
    }
    void nativeTransfer(){
        if(transferDialog!=null&&transferDialog.isShowing())transferDialog.dismiss();
        transferKey="";transferStage="";transferBusy=false;transferMissingReport="";
        LinearLayout panel=column();panel.setPadding(dp(16),dp(10),dp(16),dp(8));
        EditText title=new EditText(this);title.setSingleLine(true);title.setText("Перенос музыки");title.setHint("Название плейлиста");title.setFilters(new InputFilter[]{new InputFilter.LengthFilter(80)});styleField(title);panel.addView(title);transferTitle=title;
        Spinner modes=new Spinner(this);String[] modeNames={"Точный","Умный","Максимальный"};modes.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,modeNames));modes.setSelection(2);panel.addView(modes);transferMode=modes;
        TextView info=text("JSON, CSV или TXT до 1 МБ. Разбор списка и удаление дублей выполняются на устройстве.",12);info.setPadding(0,dp(8),0,dp(8));panel.addView(info);panel.addView(sheetAction("Выбрать файл",this::choosePlaylistDocument));
        EditText input=new EditText(this);input.setMinLines(3);input.setMaxLines(5);input.setGravity(Gravity.TOP);input.setHint("Список треков");styleField(input);input.setSaveEnabled(false);panel.addView(input);transferInput=input;
        TextView result=text("Поиск выполняется на телефоне. Сервер получает только найденные ID.",13);
        panel.addView(result);transferNote=result;
        Button missing=new Button(this);
        missing.setAllCaps(false);missing.setText("Показать ненайденные треки");
        missing.setVisibility(View.GONE);
        missing.setOnClickListener(v->{
            if(transferMissingReport.isEmpty())return;
            final String report=transferMissingReport;
            String preview=report.length()>14000?report.substring(0,14000)+"\n…":report;
            new AlertDialog.Builder(this).setTitle("Ненайденные треки")
                .setMessage(preview)
                .setNegativeButton("Закрыть",null)
                .setPositiveButton("Поделиться",(d,which)->{
                    Intent intent=new Intent(Intent.ACTION_SEND);
                    intent.setType("text/plain");
                    intent.putExtra(Intent.EXTRA_TEXT,report);
                    startActivity(Intent.createChooser(intent,"Список ненайденных"));
                }).show();
        });
        transferMissingButton=missing;panel.addView(missing);
        ScrollView form=new ScrollView(this);form.addView(panel);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Перенести музыку").setView(form).setNegativeButton("Закрыть",null).setNeutralButton("Найти треки",null).setPositiveButton("Добавить",null).create();
        transferDialog=dialog;
        dialog.setOnDismissListener(ignored->{if(transferDialog==dialog){transferReadGeneration++;transferDialog=null;transferInput=null;transferTitle=null;transferMode=null;transferNote=null;}});
        styleSheet(dialog);dialog.show();dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
        View.OnClickListener startTransfer=v->{
            if(transferBusy)return;
            String raw=input.getText().toString(),name=title.getText().toString().trim();if(raw.trim().isEmpty()||name.isEmpty()){result.setText("Укажи название плейлиста и список треков");return;}
            String mode=new String[]{"safe","balanced","wide"}[modes.getSelectedItemPosition()];
            transferBusy=true;transferStage="";dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(false);dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);result.setText("Разбираем список на устройстве…");
            final NativeAPI client=api;
            transferRequest(()->{
                JSONArray prepared=TransferPreparation.parse(raw);
                // One catalog fetch. All matching runs on this phone, not the
                // Nightwell server and without hundreds of search requests.
                JSONArray indexed=client.request("api/tracks").optJSONArray("tracks");
                if(indexed==null||indexed.length()==0)
                    throw new java.io.IOException("Каталог ещё не загружен. Повтори позже.");
                JSONArray matched=DeviceTransferMatcher.match(prepared,indexed,mode);
                return client.request("api/imports/client","POST",
                    new JSONObject().put("provider","yandex").put("name",name)
                        .put("items",matched).put("mode",mode));
            },response->{
                transferKey=response.optString("id");if(transferKey.isEmpty()){transferBusy=false;result.setText("Сервер не вернул номер переноса");dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(true);return;}
                getSharedPreferences("transfer-draft",MODE_PRIVATE).edit().putString("job|"+origin+"|"+user,transferKey).apply();
                pollTransfer(transferKey,result,dialog);
            },result,dialog);
        };
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setTag(startTransfer);dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(startTransfer);
        String saved=getSharedPreferences("transfer-draft",MODE_PRIVATE).getString("job|"+origin+"|"+user,"");
        if(!saved.isEmpty()){transferKey=saved;dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(false);pollTransfer(saved,result,dialog);}
    }
    private String transferETA(JSONObject job){
        String stage=job.optString("state");int done=stage.equals("saving")?job.optInt("saved"):job.optInt("progress");int total=stage.equals("saving")?job.optInt("matched"):job.optInt("total");long now=android.os.SystemClock.elapsedRealtime();
        if(!stage.equals(transferStage)||done<transferSampleProgress){transferStage=stage;transferSampleAt=now;transferSampleProgress=done;}
        if(!stage.equals("matching")&&!stage.equals("saving"))return "";
        int delta=done-transferSampleProgress;if(delta<2||now-transferSampleAt<3000)return "\nОцениваем оставшееся время…";
        long seconds=Math.max(1,Math.round((now-transferSampleAt)/1000.0/delta*Math.max(0,total-done)));
        return "\nОсталось примерно "+(seconds<60?"меньше минуты":((seconds+59)/60)+" мин");
    }
    private void pollTransfer(String key,TextView label,AlertDialog dialog){
        if(!dialog.isShowing()||!key.equals(transferKey))return;
        final NativeAPI client=api;
        transferRequest(()->client.request("api/imports/"+Uri.encode(key)),response->{
            if(!key.equals(transferKey))return;
            String state=response.optString("state");
            label.setText(response.optString("message","Поиск")+"\nПроверено "+response.optInt("progress")+"/"+response.optInt("total")+" · Найдено "+response.optInt("matched")+transferETA(response));
            JSONArray details=response.optJSONArray("items");
            if(details!=null&&details.length()>0){
                StringBuilder missing=new StringBuilder();int count=0;
                for(int i=0;i<details.length();i++){
                    JSONObject item=details.optJSONObject(i);
                    if(item==null||(!item.isNull("track_id")&&item.has("track_id")))continue;
                    count++;
                    missing.append(count).append(". ").append(item.optString("artist"))
                           .append(" — ").append(item.optString("title"));
                    String reason=item.optString("reason","");
                    if(!reason.isEmpty())missing.append(" (").append(reason).append(")");
                    missing.append("\n");
                }
                transferMissingReport=missing.toString();
                if(transferMissingButton!=null){
                    transferMissingButton.setText("Не найдено: "+count+" · Показать список");
                    transferMissingButton.setVisibility(count>0?View.VISIBLE:View.GONE);
                }
            }
            boolean active=state.equals("matching")||state.equals("reading")||state.equals("saving");transferBusy=active;
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(!active);
            if(!active){dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setText("Найти треки");dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener((View.OnClickListener)dialog.getButton(AlertDialog.BUTTON_NEUTRAL).getTag());}
            boolean canAdd=(state.equals("ready")||state.equals("error"))&&response.optInt("matched")>0;
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(canAdd);
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setText("Добавить");
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{if(transferBusy)return;transferBusy=true;dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(false);label.setText("Создаём плейлист…");transferRequest(()->client.request("api/imports/"+Uri.encode(key)+"/commit","POST",new JSONObject()),x->pollTransfer(key,label,dialog),label,dialog);});
            if(active)ui.postDelayed(()->pollTransfer(key,label,dialog),2000);
            if(state.equals("done")){label.setText("Плейлист создан. Добавлено треков: "+response.optInt("saved"));getSharedPreferences("transfer-draft",MODE_PRIVATE).edit().remove("job|"+origin+"|"+user).apply();load();}
        },label,dialog);
    }
}
