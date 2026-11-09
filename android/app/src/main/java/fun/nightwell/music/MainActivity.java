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
    private final Handler ui=new Handler(Looper.getMainLooper());
    private final ExecutorService io=Executors.newFixedThreadPool(3);
    private final ExecutorService prefetch=Executors.newSingleThreadExecutor();
    private TextView liveHandoff;
    private View handoffCompact;
    private boolean handoffAvailable, handoffCollapsed;
    private final Runnable handoffAutoCollapse = () -> collapseLiveHandoff(true);
    private TextView nightwellBadge, nightwellMenuStatus;
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
        int color = value.equals("Онлайн") ? 0xff64d98b :
                    value.equals("Ограничен") ? 0xffffbd64 : 0xffa7abb7;
        if (nightwellBadge != null) {
            nightwellBadge.setText("● Nightwell · " + value);
            nightwellBadge.setTextColor(color);
        }
        if (nightwellMenuStatus != null) {
            nightwellMenuStatus.setText(value);
            nightwellMenuStatus.setTextColor(color);
        }
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
            !liveRemote.optString("track_id").isEmpty()&&!backgroundOnly&&!full;
        if(!show){
            ui.removeCallbacks(handoffAutoCollapse);
            handoffAvailable=false;handoffCollapsed=false;
            if(liveHandoff!=null){liveHandoff.animate().cancel();liveHandoff.setVisibility(View.GONE);}
            if(handoffCompact!=null){handoffCompact.animate().cancel();handoffCompact.setVisibility(View.GONE);}
            return;
        }
        if(!handoffAvailable){
            handoffAvailable=true;handoffCollapsed=false;
            scheduleHandoffCollapse();
        }
        if(liveHandoff!=null){
            liveHandoff.animate().cancel();
            liveHandoff.setAlpha(1f);liveHandoff.setScaleX(1f);liveHandoff.setScaleY(1f);
            liveHandoff.setTranslationY(0f);
            liveHandoff.setVisibility(handoffCollapsed?View.GONE:View.VISIBLE);
        }
        if(handoffCompact!=null){
            handoffCompact.animate().cancel();
            handoffCompact.setAlpha(1f);handoffCompact.setScaleX(1f);handoffCompact.setScaleY(1f);
            handoffCompact.setVisibility(handoffCollapsed?View.VISIBLE:View.GONE);
        }
    }
    private void scheduleHandoffCollapse(){
        ui.removeCallbacks(handoffAutoCollapse);
        if(handoffAvailable&&!handoffCollapsed&&getSharedPreferences("appearance",MODE_PRIVATE).getBoolean("handoff-auto-collapse",true))ui.postDelayed(handoffAutoCollapse,4800);
    }
    private void collapseLiveHandoff(boolean animate){
        if(!handoffAvailable||handoffCollapsed)return;
        handoffCollapsed=true;
        ui.removeCallbacks(handoffAutoCollapse);
        if(liveHandoff==null||handoffCompact==null||!animate||!liveHandoff.isAttachedToWindow()){
            refreshLiveHandoff();return;
        }
        liveHandoff.animate().cancel();handoffCompact.animate().cancel();
        handoffCompact.setVisibility(View.VISIBLE);handoffCompact.setAlpha(0f);
        handoffCompact.setScaleX(.75f);handoffCompact.setScaleY(.75f);
        handoffCompact.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(300)
            .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
        liveHandoff.animate().alpha(0f).scaleX(.93f).scaleY(.85f)
            .translationY(-dp(12)).setDuration(280)
            .withEndAction(()->{
                if(handoffCollapsed)liveHandoff.setVisibility(View.GONE);
                liveHandoff.setAlpha(1f);liveHandoff.setScaleX(1f);
                liveHandoff.setScaleY(1f);liveHandoff.setTranslationY(0f);
            }).start();
    }
    private void expandLiveHandoff(){
        if(!handoffAvailable||!handoffCollapsed)return;
        handoffCollapsed=false;
        if(liveHandoff==null||handoffCompact==null){refreshLiveHandoff();return;}
        liveHandoff.animate().cancel();handoffCompact.animate().cancel();
        liveHandoff.setVisibility(View.VISIBLE);liveHandoff.setAlpha(0f);
        liveHandoff.setScaleX(.94f);liveHandoff.setScaleY(.85f);
        liveHandoff.setTranslationY(-dp(10));
        liveHandoff.animate().alpha(1f).scaleX(1f).scaleY(1f).translationY(0f)
            .setDuration(320).setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
        handoffCompact.animate().alpha(0f).scaleX(.8f).scaleY(.8f).setDuration(220)
            .withEndAction(()->{
                if(!handoffCollapsed)handoffCompact.setVisibility(View.GONE);
                handoffCompact.setAlpha(1f);handoffCompact.setScaleX(1f);handoffCompact.setScaleY(1f);
            }).start();
        scheduleHandoffCollapse();
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
    private TextView homeLyric;private JSONObject activeLyrics;private String homeLine="";private boolean lastPlaying,mixing;private final java.util.ArrayDeque<String> mixRecent=new java.util.ArrayDeque<>();
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
    private final LinkedHashMap<String,JSONObject> favoriteDetails=new LinkedHashMap<>();
    private long lastFavoriteRecovery;
    private volatile int favoriteRecoveryGeneration;
    private final ArrayList<String> likeOrder=new ArrayList<>();
    private final java.util.LinkedHashMap<String,JSONArray> searchCache =
        new java.util.LinkedHashMap<String,JSONArray>(24,0.75f,true) {
            @Override protected boolean removeEldestEntry(java.util.Map.Entry<String,JSONArray> entry) {
                return size()>24;
            }
        };
    private LinearLayout root,body,dock,head;
    private TextView status,miniTitle,miniArtist,miniPlay,miniPrev,miniNext,miniLike;
    private android.widget.ImageView miniCover;private CircularProgressRing miniProgressRing;
    private ArtworkCache artworkCache;
    private TextView fullTime,homePlay,fullPlay,fullLike,fullDislike,fullAudioOutput,fullShuffle;
    private SeekBar seek;
    private EditText search;
    private LinearLayout artistStrip;
    private TextView lyricsText;private android.widget.ScrollView lyricsScroll;private JSONArray lyricLines;private int activeLyric=-2;private String lyricsTrack="";
    private ListView list;
    private TrackAdapter adapter;
    private RibbonView ribbon;
    private HomeSparklesView atmosphere;
    private ArtworkAmbientView ambient;
    private Runnable pendingSearch;
    private PopupWindow navigationPopup;
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
    private NativeTogetherAndroid together;
    private String pendingTogetherCode="";
    void openPendingTogether(){if(together!=null&&sessionReady&&!user.isEmpty()&&!pendingTogetherCode.isEmpty()){String code=pendingTogetherCode;pendingTogetherCode="";ui.post(()->together.invite(code));}}
    NativeAPI togetherAPI(){return api;}
    String togetherUser(){return user;}
    String togetherCurrentID(){return currentID==null?"":currentID;}
    long togetherPosition(){return playback==null?0:Math.max(0,playback.player.getCurrentPosition());}
    boolean togetherIsPlaying(){return playback!=null&&playback.player.getPlayWhenReady();}
    void togetherRequireLogin(){auth();}
    void togetherPlay(JSONObject track,JSONArray items){play(track,items,false);}
    void togetherSeek(long position){if(playback!=null)playback.seek(Math.max(0,position)/1000.0);}
    void togetherSetPlaying(boolean playing){if(playback==null)return;if(playing)playback.play();else playback.pause();updatePlayback();}
    private void acceptDeepLink(Intent intent){
        if(intent==null||intent.getData()==null)return;
        Uri uri=intent.getData();String scheme=uri.getScheme(),host=uri.getHost(),id=null;
        if("https".equalsIgnoreCase(scheme)&&"music.nightwell.fun".equalsIgnoreCase(host)){
            String room=NativeTogetherAndroid.parseCode(uri.getQueryParameter("together"));
            if(room!=null){pendingTogetherCode=room;intent.setData(null);openPendingTogether();return;}
        }
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

    private final Runnable tick=new Runnable(){public void run(){premiumTick();updatePlayback();if(fullAudioOutput!=null&&fullAudioOutput.isAttachedToWindow()){String output=audioOutputName();fullAudioOutput.setText("♫  "+output+"  ⌄");fullAudioOutput.setContentDescription("Устройство вывода: "+output+". Изменить");}String next=BackgroundDownloads.progress(MainActivity.this);if(!next.equals(downloadProgress)){downloadProgress=next;status.setText(next);}if(visible){livePoll();ui.postDelayed(this,playback!=null&&playback.player.getPlayWhenReady()?500:1200);}}};
    private final androidx.media3.common.Player.Listener playbackIntentObserver=new androidx.media3.common.Player.Listener(){
        @Override public void onPlayWhenReadyChanged(boolean ready,int reason){if(!ready&&mixing)cancelMix();}
        @Override public void onMediaItemTransition(androidx.media3.common.MediaItem item,int reason){if(mixing)cancelMix();if(shuffleMode()==2)ui.post(()->prepareSmartNext());}
    };
    private final ServiceConnection connection=new ServiceConnection(){public void onServiceConnected(ComponentName n,IBinder b){playback=((PlaybackService.LocalBinder)b).getService();playback.player.addListener(playbackIntentObserver);if(!smokeMode&&pendingDeepLinkTrack.isEmpty())playback.restorePlayback(origin,user);if(getSharedPreferences("playback",MODE_PRIVATE).contains("nw-shuffle-mode"))applyShuffleMode(shuffleMode());updatePlayback();openPendingTrack();}public void onServiceDisconnected(ComponentName n){playback=null;}};
    @Override public void onCreate(Bundle saved){super.onCreate(saved);together=new NativeTogetherAndroid(this);artworkCache=new ArtworkCache(this);smokeMode=(getApplicationInfo().flags&android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)!=0&&getIntent().getBooleanExtra("nativeSmoke",false);origin="https://music.nightwell.fun/";user=getSharedPreferences("native-api",MODE_PRIVATE).getString("account","");api=new NativeAPI(this,origin);restoreRecent();if(!smokeMode&&!user.isEmpty())restoreLibrarySnapshot(user);if(Build.VERSION.SDK_INT>=30)getWindow().setDecorFitsSystemWindows(false);else getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE|View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN|View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);if(Build.VERSION.SDK_INT>=28){WindowManager.LayoutParams windowParams=getWindow().getAttributes();windowParams.layoutInDisplayCutoutMode=WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;getWindow().setAttributes(windowParams);}getWindow().setStatusBarColor(Color.TRANSPARENT);getWindow().setNavigationBarColor(Color.TRANSPARENT);if(Build.VERSION.SDK_INT>=29)getWindow().setNavigationBarContrastEnforced(false);getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);bindingRegistered=bindService(new Intent(this,PlaybackService.class).setAction("nightwell.local"),connection,BIND_AUTO_CREATE);build();if(smokeMode){smokeFixture(getIntent().getStringExtra("screen"));}else{acceptDeepLink(getIntent());load();}
        if(saved!=null&&saved.getBoolean("transfer.open",false)){nativeTransfer();transferTitle.setText(saved.getString("transfer.title","Перенос музыки"));transferInput.setText(getSharedPreferences("transfer-draft",MODE_PRIVATE).getString("text",""));transferMode.setSelection(saved.getInt("transfer.mode",2));}
    }
    @Override protected void onSaveInstanceState(Bundle saved){
        if(transferDialog!=null&&transferDialog.isShowing()){
            saved.putBoolean("transfer.open",true);saved.putString("transfer.title",transferTitle.getText().toString());saved.putInt("transfer.mode",transferMode.getSelectedItemPosition());
            // Keep a potentially 1 MB document out of the Activity/Binder state bundle.
            getSharedPreferences("transfer-draft",MODE_PRIVATE).edit().putString("text",transferInput.getText().toString()).apply();
        }
        super.onSaveInstanceState(saved);
    }

    @Override protected void onResume(){super.onResume();restoreRecent();visible=true;openPendingTogether();ui.removeCallbacks(nightwellProbe);ui.post(nightwellProbe);if(!smokeMode&&sessionReady&&SystemClock.elapsedRealtime()-lastResumeRefresh>30000)load();if(premiumRefresh!=null)premiumRefresh.run();BackgroundDownloads.reconcile(this);updateArtworkAppearance();ui.removeCallbacks(tick);if(!smokeMode)ui.post(tick);}
    @Override protected void onPause(){super.onPause();ui.removeCallbacks(nightwellProbe);ui.removeCallbacks(connectionRecovery);if(navigationPopup!=null)navigationPopup.dismiss();if(playback!=null)playback.persistPlayback(true);visible=false;if(ribbon!=null)ribbon.running(false);ui.removeCallbacks(tick);}
    @Override protected void onDestroy(){if(together!=null)together.shutdown();ui.removeCallbacks(nightwellProbe);generation++;cancelMix();accountRequest.cancel();if(api!=null)api.close();ui.removeCallbacksAndMessages(null);if(artworkCache!=null)artworkCache.close();io.shutdownNow();prefetch.shutdownNow();if(playback!=null)playback.player.removeListener(playbackIntentObserver);if(bindingRegistered){unbindService(connection);bindingRegistered=false;}super.onDestroy();}
    int dp(float n){return (int)(n*getResources().getDisplayMetrics().density+.5f);}
    LinearLayout column(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    TextView text(String label,int size){TextView v=new TextView(this);v.setText(label);v.setTextSize(size);v.setTextColor(NightwellDesign.PRIMARY);v.setTypeface(android.graphics.Typeface.create("sans-serif",android.graphics.Typeface.NORMAL));v.setFontFeatureSettings("kern");v.setIncludeFontPadding(false);v.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_HIGH_QUALITY);v.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);return v;}
    GradientDrawable surface(){return NightwellDesign.surface(this,NightwellDesign.SURFACE,24,true);}
    GradientDrawable fieldSurface(int color,int corners){return NightwellDesign.surface(this,color,Math.min(corners,24),true);}
    android.graphics.drawable.Drawable touchSurface(int color,int corners){return NightwellDesign.ripple(this,color,Math.min(corners,28),true);}
    TextView sectionLabel(String label){TextView v=text(label.toUpperCase(java.util.Locale.ROOT),11);v.setLetterSpacing(.105f);v.setTextColor(NightwellDesign.MUTED);v.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));v.setPadding(dp(3),dp(18),0,dp(10));return v;}
    void styleField(EditText view){view.setTextSize(15);NightwellDesign.styleField(this,view);}
    void styleSwitch(android.widget.Switch view){view.setTextColor(NightwellDesign.PRIMARY);view.setTextSize(15);view.setMinHeight(dp(52));view.setPadding(dp(5),dp(8),dp(5),dp(8));view.setShowText(false);view.setThumbTintList(android.content.res.ColorStateList.valueOf(0xfff5f6f7));view.setTrackTintList(new android.content.res.ColorStateList(new int[][]{new int[]{android.R.attr.state_checked},new int[]{}},new int[]{0xff6a7078,0xff34373b}));}
    void styleSheet(AlertDialog dialog){dialog.setOnShowListener(ignored->{
        android.view.Window window=dialog.getWindow();
        if(window!=null){
            window.setBackgroundDrawable(NightwellDesign.surface(this,NightwellDesign.SURFACE,24,true));
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams params=window.getAttributes();params.dimAmount=.78f;window.setAttributes(params);
            window.setDimAmount(.78f);
            int width=Math.min(dp(520),getResources().getDisplayMetrics().widthPixels-dp(28));
            window.setLayout(width,WindowManager.LayoutParams.WRAP_CONTENT);
            window.getDecorView().setPadding(dp(12),dp(6),dp(12),dp(12));
            window.getDecorView().post(()->{
                int limit=getResources().getDisplayMetrics().heightPixels-dp(64);
                if(window.getDecorView().getHeight()>limit)window.setLayout(width,limit);
            });
            View shell=window.getDecorView();shell.setAlpha(0f);shell.setScaleX(.97f);shell.setScaleY(.97f);
            shell.animate().alpha(1).scaleX(1f).scaleY(1f).setDuration(210)
                .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
        }
        for(int which:new int[]{AlertDialog.BUTTON_POSITIVE,AlertDialog.BUTTON_NEGATIVE,AlertDialog.BUTTON_NEUTRAL}){
            Button b=dialog.getButton(which);if(b==null)continue;
            b.setAllCaps(false);b.setTextSize(14);b.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
            b.setTextColor(which==AlertDialog.BUTTON_NEGATIVE?NightwellDesign.MUTED:NightwellDesign.PRIMARY);
            b.setMinHeight(dp(46));b.setBackground(NightwellDesign.ripple(this,NightwellDesign.RAISED,14,true));
        }
    });}
    TextView sheetAction(String label,Runnable run){TextView v=action(label,run);v.setTextSize(15);v.setMaxLines(2);v.setEllipsize(android.text.TextUtils.TruncateAt.END);v.setGravity(Gravity.CENTER_VERTICAL);v.setTextColor(NightwellDesign.PRIMARY);v.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));v.setPadding(dp(16),dp(12),dp(16),dp(12));v.setMinHeight(dp(52));v.setBackground(NightwellDesign.ripple(this,NightwellDesign.SURFACE,18,true));return v;}
    TextView action(String label,Runnable run){TextView v=NativeIconButton.isIcon(label)?new NativeIconButton(this):text(label,16);v.setText(label);v.setTextColor(NightwellDesign.PRIMARY);v.setTextSize(NativeIconButton.isIcon(label)?20:16);if(NativeIconButton.isIcon(label))v.setContentDescription(iconLabel(label));v.setGravity(Gravity.CENTER);v.setPadding(dp(13),dp(11),dp(13),dp(11));v.setMinHeight(dp(48));v.setOnClickListener(x->run.run());return v;}
    TextView iconButton(String label,Runnable run){TextView v=action(label,run);v.setPadding(0,0,0,0);v.setTextSize(20);v.setTextColor(NightwellDesign.PRIMARY);v.setBackground(NightwellDesign.ripple(this,0xb0212326,16,true));return v;}
    void toggleBackgroundOnly(){backgroundOnly=!backgroundOnly;build();}
    void showQueue(){
        final JSONArray snapshot=queue==null?new JSONArray():queue;
        LinearLayout content=column();
        content.setPadding(dp(13),dp(8),dp(13),dp(7));
        TextView intro=text("Очередь воспроизведения",22);
        NightwellDesign.headline(intro);
        intro.setPadding(dp(5),dp(12),dp(5),dp(7));
        content.addView(intro);
        TextView count=text(snapshot.length()+" треков",13);
        count.setTextColor(NightwellDesign.MUTED);
        count.setPadding(dp(5),0,dp(5),dp(12));
        content.addView(count);
        ListView items=new ListView(this);
        items.setDivider(new android.graphics.drawable.ColorDrawable(NightwellDesign.SURFACE));
        items.setDividerHeight(dp(5));
        items.setSelector(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        items.setVerticalScrollBarEnabled(false);
        final String playingId=currentID;
        BaseAdapter adapter=new BaseAdapter(){
            @Override public int getCount(){return snapshot.length();}
            @Override public Object getItem(int position){return snapshot.optJSONObject(position);}
            @Override public long getItemId(int position){return position;}
            @Override public View getView(int position,View convertView,ViewGroup parent){
                JSONObject t=snapshot.optJSONObject(position);
                if(t==null)t=new JSONObject();
                LinearLayout row=row();
                row.setPadding(dp(11),dp(11),dp(11),dp(11));
                boolean current=playingId.equals(t.optString("id"));
                row.setBackground(NightwellDesign.ripple(MainActivity.this,
                    current?NightwellDesign.SELECTED:NightwellDesign.RAISED,15,false));
                TextView order=text(current?"▶":String.valueOf(position+1),13);
                order.setTextColor(current?NightwellDesign.PRIMARY:NightwellDesign.MUTED);
                order.setGravity(Gravity.CENTER);
                row.addView(order,new LinearLayout.LayoutParams(dp(31),dp(46)));
                LinearLayout name=column();
                name.setPadding(dp(9),0,0,0);
                TextView title=text(t.optString("title","Без названия"),14);
                NightwellDesign.headline(title);title.setSingleLine(true);
                title.setEllipsize(android.text.TextUtils.TruncateAt.END);name.addView(title);
                TextView artist=text(t.optString("artist",""),12);
                NightwellDesign.detail(artist);artist.setSingleLine(true);
                artist.setEllipsize(android.text.TextUtils.TruncateAt.END);
                artist.setPadding(0,dp(5),0,0);name.addView(artist);
                row.addView(name,new LinearLayout.LayoutParams(0,-2,1));
                return row;
            }
        };
        items.setAdapter(adapter);
        content.addView(items,new LinearLayout.LayoutParams(-1,
            Math.min(dp(480),Math.max(dp(100),dp(68)*Math.min(7,snapshot.length())))));
        AlertDialog dialog=new AlertDialog.Builder(this).setView(content)
            .setNegativeButton("Закрыть",null).create();
        items.setOnItemClickListener((p,v,index,id)->{
            JSONObject track=snapshot.optJSONObject(index);
            if(track!=null){dialog.dismiss();play(track,snapshot,false);}
        });
        styleSheet(dialog);dialog.show();
    }
    void build(){
        if(ribbon!=null)ribbon.running(false);full=false;lyricsOpen=false;seek=null;fullTime=null;fullPlay=null;fullLike=null;fullDislike=null;fullAudioOutput=null;fullShuffle=null;
        // Render scenery and aura across the window, outside the padded controls.
        android.widget.FrameLayout scene=new android.widget.FrameLayout(this);
        scene.setBackground(new NativeSceneryDrawable(this));
        ambient=new ArtworkAmbientView(this);scene.addView(ambient,new android.widget.FrameLayout.LayoutParams(-1,-1));
        // Old active ribbons and starfield are deliberately removed from the view tree.
        atmosphere=null;ribbon=null;ui.post(this::applyPremium);
        root=column();root.setPadding(dp(16),dp(10),dp(16),0);
        scene.addView(root,new android.widget.FrameLayout.LayoutParams(-1,-1));setContentView(scene);
        root.setOnApplyWindowInsetsListener((v,insets)->{int top,bottom;if(Build.VERSION.SDK_INT>=30){android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());top=bars.top;bottom=Math.max(bars.bottom,insets.getInsets(WindowInsets.Type.ime()).bottom);}else{top=insets.getSystemWindowInsetTop();bottom=insets.getSystemWindowInsetBottom();}v.setPadding(dp(16),dp(9)+top,dp(16),bottom+dp(4));return insets;});root.requestApplyInsets();
        head=row();android.widget.ImageView brand=new android.widget.ImageView(this);brand.setImageResource(R.drawable.nightwell_mark);brand.setScaleType(android.widget.ImageView.ScaleType.FIT_CENTER);brand.setOnClickListener(v->navigate("Главная"));head.addView(brand,new LinearLayout.LayoutParams(dp(40),dp(40)));LinearLayout wordmark=column();wordmark.setGravity(Gravity.CENTER_VERTICAL);wordmark.setPadding(dp(9),0,0,0);
        TextView brandName=text("Nightwell",24);NightwellDesign.headline(brandName);brandName.setSingleLine(true);brandName.setAutoSizeTextTypeUniformWithConfiguration(19,24,1,android.util.TypedValue.COMPLEX_UNIT_SP);
        wordmark.addView(brandName,new LinearLayout.LayoutParams(-1,dp(33)));
        TextView brandCaption=text("M  U  S  I  C",10);brandCaption.setIncludeFontPadding(false);brandCaption.setSingleLine(true);brandCaption.setTextColor(NightwellDesign.MUTED);LinearLayout.LayoutParams captionParams=new LinearLayout.LayoutParams(-1,-2);captionParams.topMargin=dp(1);wordmark.addView(brandCaption,captionParams);
        wordmark.setOnClickListener(v->navigate("Главная"));wordmark.setContentDescription("Nightwell Music, на главный экран");head.addView(wordmark,new LinearLayout.LayoutParams(0,-2,1));TextView searchButton=iconButton("⌕",()->navigate("Поиск"));searchButton.setBackground(NightwellDesign.ripple(this,0x99171a1e,16,true));head.addView(searchButton,new LinearLayout.LayoutParams(dp(44),dp(48)));handoffCompact=new HandoffButton(this);handoffCompact.setBackground(NightwellDesign.ripple(this,0x99171a1e,16,true));handoffCompact.setOnClickListener(v->expandLiveHandoff());handoffCompact.setContentDescription("Продолжить на этом устройстве. Развернуть плашку");handoffCompact.setVisibility(View.GONE);head.addView(handoffCompact,new LinearLayout.LayoutParams(dp(40),dp(48)));TextView menuButton=iconButton("☰",this::menu);menuButton.setBackground(NightwellDesign.ripple(this,0x99171a1e,16,true));head.addView(menuButton,new LinearLayout.LayoutParams(dp(44),dp(48)));LinearLayout.LayoutParams headerParams=new LinearLayout.LayoutParams(-1,dp(58));headerParams.bottomMargin=dp(8);root.addView(head,headerParams);if(backgroundOnly)head.setVisibility(View.GONE);
        nightwellBadge = text("", 11);
        nightwellBadge.setContentDescription("Состояние подключения Nightwell");
        setNightwellStatus(nightwellStatus);
        if (!backgroundOnly) {
            LinearLayout.LayoutParams networkParams = new LinearLayout.LayoutParams(-1, dp(17));
            networkParams.bottomMargin = dp(3);
            root.addView(nightwellBadge, networkParams);
        }
        liveHandoff=sheetAction("Музыка на другом устройстве · Продолжить здесь",this::continueLiveHere);
        liveHandoff.setContentDescription("Продолжить музыку на этом устройстве. Удерживай, чтобы свернуть");
        liveHandoff.setOnLongClickListener(v->{collapseLiveHandoff(true);return true;});
        liveHandoff.setVisibility(View.GONE);root.addView(liveHandoff);
        refreshLiveHandoff();
        body=column();root.addView(body,new LinearLayout.LayoutParams(-1,0,1));status=text("",12);status.setTextColor(NightwellDesign.MUTED);status.setGravity(Gravity.CENTER);status.setMaxLines(2);status.setPadding(dp(4),dp(3),dp(4),dp(3));root.addView(status);dock=row();dock.setPadding(dp(10),dp(10),dp(10),dp(10));dock.setBackground(NightwellDesign.surface(this,0xe7191b1f,22,true));dock.setClipToOutline(true);
        miniCover=new android.widget.ImageView(this);miniCover.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);GradientDrawable coverShape=new GradientDrawable();coverShape.setColor(0x443e2d52);coverShape.setCornerRadius(dp(getSharedPreferences("appearance",MODE_PRIVATE).getBoolean("cover-classic",false)?16:9));miniCover.setBackground(coverShape);miniCover.setClipToOutline(true);miniCover.setOnClickListener(v->openPlayer());LinearLayout.LayoutParams coverParams=new LinearLayout.LayoutParams(dp(44),dp(44));coverParams.rightMargin=dp(10);dock.addView(miniCover,coverParams);
        LinearLayout labels=column();miniTitle=text("Выбери трек",15);miniTitle.setMaxLines(1);miniTitle.setTextSize(15);miniTitle.setLetterSpacing(-.015f);miniTitle.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);miniArtist=text("Nightwell Music",12);miniArtist.setMaxLines(1);miniArtist.setTextSize(12);miniArtist.setLetterSpacing(.005f);miniArtist.setTextColor(0xffa4a6b1);miniTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);miniArtist.setEllipsize(android.text.TextUtils.TruncateAt.END);labels.addView(miniTitle);labels.addView(miniArtist);labels.setOnClickListener(v->openPlayer());dock.addView(labels,new LinearLayout.LayoutParams(0,-2,1));miniPrev=action("|‹",()->previous());miniPlay=action("▶",()->toggle());miniNext=action("›|",()->{nextTrack();});miniLike=action("♡",()->toggleFavorite(current()));miniLike.setTextColor(0xffeeeeee);miniPlay.setTextSize(23);miniNext.setTextSize(24);miniPlay.setPadding(0,0,0,0);miniNext.setPadding(0,0,0,0);miniPlay.setTextColor(NightwellDesign.PRIMARY);miniPlay.setBackground(null);miniPrev.setPadding(0,0,0,0);miniLike.setPadding(0,0,0,0);if(getResources().getConfiguration().screenWidthDp>=380)dock.addView(miniLike,new LinearLayout.LayoutParams(dp(40),dp(48)));dock.addView(miniPrev,new LinearLayout.LayoutParams(dp(40),dp(48)));miniProgressRing=new CircularProgressRing(this);miniProgressRing.addView(miniPlay,new android.widget.FrameLayout.LayoutParams(-1,-1));dock.addView(miniProgressRing,new LinearLayout.LayoutParams(dp(48),dp(48)));dock.addView(miniNext,new LinearLayout.LayoutParams(dp(44),dp(48)));LinearLayout.LayoutParams dockParams=new LinearLayout.LayoutParams(-1,-2);dockParams.topMargin=dp(8);dockParams.bottomMargin=dp(5);root.addView(dock,dockParams);if(backgroundOnly)dock.setVisibility(View.GONE);android.view.GestureDetector miniGestures=gestures(false);labels.setOnTouchListener((v,event)->miniGestures.onTouchEvent(event));dock.setOnTouchListener((v,event)->miniGestures.onTouchEvent(event));
        showScreen();updateArtworkAppearance();updatePlayback();loadMiniCover(current());
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
    void menu(){
        if(navigationPopup!=null)navigationPopup.dismiss();
        View anchor=head.getChildAt(head.getChildCount()-1);
        LinearLayout entries=column();
        entries.setPadding(dp(10),dp(12),dp(10),dp(12));

        LinearLayout brandRow=row();
        brandRow.setPadding(dp(8),dp(8),dp(8),dp(14));
        TextView monogram=text("N",22);
        monogram.setGravity(Gravity.CENTER);
        NightwellDesign.headline(monogram);
        monogram.setBackground(NightwellDesign.surface(this,NightwellDesign.RAISED,14,true));
        brandRow.addView(monogram,new LinearLayout.LayoutParams(dp(46),dp(46)));
        LinearLayout brandCopy=column();
        brandCopy.setPadding(dp(12),0,0,0);
        TextView brandTitle=text("Nightwell Music",16);
        NightwellDesign.headline(brandTitle);
        brandCopy.addView(brandTitle);
        TextView connectionState=text(nightwellStatus,12);
        connectionState.setPadding(0,dp(4),0,0);
        brandCopy.addView(connectionState);
        nightwellMenuStatus=connectionState;setNightwellStatus(nightwellStatus);
        brandRow.addView(brandCopy,new LinearLayout.LayoutParams(0,-2,1));
        entries.addView(brandRow);
        entries.addView(NightwellDesign.hairline(this),
            new LinearLayout.LayoutParams(-1,Math.max(1,dp(1))));
        TextView libraryLabel=sectionLabel("Библиотека");
        libraryLabel.setPadding(dp(10),dp(15),0,dp(8));
        entries.addView(libraryLabel);

        String[] tabs={"Главная","Поиск","Избранное","Плейлисты","Офлайн",
            "Слушать вместе","Моя статистика","Nightwell Premium",
            "Перенести музыку","Настройки","Настройка подборки",
            "Обращения",user.isEmpty()?"Войти":"Выйти"};
        String[] icons={"home","search","heart","list","download",
            "list","stats","star","download","settings","sliders","mail","person"};
        for(int i=0;i<tabs.length;i++){
            if(i==5||i==8||i==12){
                TextView title=sectionLabel(i==5?"ВОЗМОЖНОСТИ":i==8?"ПРИЛОЖЕНИЕ":"АККАУНТ");
                title.setPadding(dp(10),dp(18),0,dp(8));
                entries.addView(title);
            }
            final String tab=tabs[i];
            boolean selected=tab.equals(screen)||(tab.equals("Плейлисты")&&!selectedPlaylist.isEmpty());
            int color=tab.equals("Выйти")?NightwellDesign.DANGER:
                selected?NightwellDesign.PRIMARY:NightwellDesign.SECONDARY;
            LinearLayout item=row();
            item.setPadding(dp(11),0,dp(10),0);
            item.setMinimumHeight(dp(46));
            item.setBackground(NightwellDesign.ripple(this,
                selected?NightwellDesign.SELECTED:NightwellDesign.SURFACE,14,false));
            item.addView(new NavigationMenuIcon(this,icons[i],color),
                new LinearLayout.LayoutParams(dp(20),dp(20)));
            TextView label=text(tab.equals("Обращения")?"Поддержка":tab,14);
            label.setTextColor(color);
            label.setTypeface(android.graphics.Typeface.create(
                selected?"sans-serif-medium":"sans-serif",0));
            label.setSingleLine(true);
            label.setEllipsize(android.text.TextUtils.TruncateAt.END);
            label.setPadding(dp(12),0,dp(4),0);
            item.addView(label,new LinearLayout.LayoutParams(0,-2,1));
            if(selected){
                View dot=new View(this);
                dot.setBackground(NightwellDesign.surface(this,NightwellDesign.PRIMARY,3,false));
                item.addView(dot,new LinearLayout.LayoutParams(dp(5),dp(5)));
            }
            item.setContentDescription(label.getText());
            item.setOnClickListener(v->{
                if(navigationPopup!=null)navigationPopup.dismiss();
                selectMenu(tab);
            });
            LinearLayout.LayoutParams rowParams=new LinearLayout.LayoutParams(-1,-2);
            rowParams.bottomMargin=dp(3);
            entries.addView(item,rowParams);
        }
        TextView footer=text("Nightwell Music  ·  "+BuildConfig.VERSION_NAME,11);
        footer.setGravity(Gravity.CENTER);
        footer.setTextColor(NightwellDesign.MUTED);
        footer.setPadding(0,dp(14),0,dp(2));
        entries.addView(footer);

        ScrollView scroll=new ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setFillViewport(false);
        scroll.addView(entries);
        android.graphics.Rect frame=new android.graphics.Rect();
        anchor.getWindowVisibleDisplayFrame(frame);
        int[] location=new int[2];anchor.getLocationOnScreen(location);
        int available=Math.max(dp(140),frame.bottom-location[1]-anchor.getHeight()-dp(10));
        int width=Math.min(dp(296),frame.width()-dp(26));
        PopupWindow popup=new PopupWindow(scroll,width,WindowManager.LayoutParams.WRAP_CONTENT,true);
        navigationPopup=popup;
        popup.setOnDismissListener(()->{if(navigationPopup==popup){navigationPopup=null;nightwellMenuStatus=null;}});
        GradientDrawable panel=NightwellDesign.surface(this,NightwellDesign.SURFACE,22,true);
        popup.setBackgroundDrawable(panel);
        popup.setElevation(dp(16));
        popup.setOutsideTouchable(true);
        popup.setInputMethodMode(PopupWindow.INPUT_METHOD_NOT_NEEDED);
        scroll.setBackground(panel);scroll.setClipToOutline(true);
        entries.measure(View.MeasureSpec.makeMeasureSpec(width,View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0,View.MeasureSpec.UNSPECIFIED));
        popup.setHeight(Math.min(entries.getMeasuredHeight()+dp(4),available));
        popup.showAsDropDown(anchor,0,dp(7),Gravity.END);
        scroll.setAlpha(0f);
        scroll.setTranslationY(-dp(8));
        scroll.animate().alpha(1f).translationY(0).setDuration(190)
            .setInterpolator(new android.view.animation.DecelerateInterpolator()).start();
    }
    void selectMenu(String tab){
        if(tab.equals("Слушать вместе")){together.open();return;}
        if(tab.equals("Перенести музыку")){nativeTransfer();return;}
         if(tab.equals("Моя статистика")){feature("stats");return;}
        if(tab.equals("Nightwell Premium")){premium();return;}
        if(tab.equals("Настройки"))settings();
        else if(tab.equals("Настройка подборки"))waveSettings();
        else if(tab.equals("Обращения"))supportTickets(false);
        else if(tab.equals("Только фон")||tab.equals("Показать интерфейс"))toggleBackgroundOnly();
        else if(tab.equals("Войти"))auth();
        else if(tab.equals("Выйти")){cancelMix();accountRequest.cancel();task(()->{api.request("api/logout","POST",null);new SessionStore(this).clear();clearLibrarySnapshot();getSharedPreferences("favorite-track-cache",MODE_PRIVATE).edit().remove(favoriteDetailsKey()).apply();return new JSONObject();},v->{libraryGeneration++;user="";searchCache.clear();playlists=new JSONArray();selectedPlaylist="";sessionReady=true;openPendingTogether();api.updateCSRF("");getSharedPreferences("native-api",MODE_PRIVATE).edit().putString("account","").apply();catalog=new JSONArray();shown=new JSONArray();likes.clear();likeOrder.clear();if(playback!=null)playback.stop();navigate("Главная");});}
        else navigate(tab);
    }

    View supportCard(String subject,String state,Runnable click){
        LinearLayout card=column();card.setPadding(dp(16),dp(13),dp(16),dp(13));
        TextView name=text(subject,16);name.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);
        TextView stateView=text(state.equals("new")?"Новое":state.equals("in_progress")?"В работе":state.equals("waiting_user")?"Ожидает ответа":state.equals("resolved")?"Решено":"Закрыто",12);
        stateView.setTextColor(NightwellDesign.MUTED);
        card.addView(name);card.addView(stateView);
        card.setBackground(NightwellDesign.ripple(this,NightwellDesign.SURFACE,18,true));
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
            if(remove){likes.remove(id);likeOrder.remove(id);}
            else{likes.add(id);likeOrder.remove(id);likeOrder.add(0,id);rememberFavorite(track);if(ribbon!=null)ribbon.flash();}
            saveLibrarySnapshot();
            refreshFavoriteButtons();updatePlayback();
            if(screen.equals("Избранное"))showScreen();else updateList();
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
        updateArtworkAppearance();
        if(android.animation.ValueAnimator.areAnimatorsEnabled()){body.setAlpha(.5f);body.animate().alpha(1).setDuration(180);}
        body.removeAllViews();list=null;search=null;artistStrip=null;adapter=null;
        if(!screen.equals("Главная")){
            TextView pageTitle=text(screen,28);NightwellDesign.headline(pageTitle);
            pageTitle.setSingleLine(true);pageTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams titleLayout=new LinearLayout.LayoutParams(-1,-2);
            titleLayout.topMargin=dp(12);titleLayout.bottomMargin=dp(18);
            body.addView(pageTitle,titleLayout);
        }
        if(screen.equals("Главная")){
            boolean compact=getResources().getConfiguration().orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE;
            android.widget.FrameLayout stage=new android.widget.FrameLayout(this);body.addView(stage,new LinearLayout.LayoutParams(-1,0,1));
            updateArtworkAppearance();
            LinearLayout intro=column();intro.setGravity(Gravity.CENTER_HORIZONTAL);
            intro.setPadding(0,dp(compact?8:32),0,0);
            TextView eyebrow=text("ТВОЯ МУЗЫКА",11);eyebrow.setTextColor(NightwellDesign.SECONDARY);
            eyebrow.setLetterSpacing(.24f);eyebrow.setGravity(Gravity.CENTER);
            intro.addView(eyebrow);
            TextView theme=text("Твой ритм",compact?30:42);NightwellDesign.headline(theme);
            theme.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
            theme.setGravity(Gravity.CENTER);
            theme.setMaxLines(2);theme.setAutoSizeTextTypeUniformWithConfiguration(27,44,1,android.util.TypedValue.COMPLEX_UNIT_SP);
            theme.setPadding(0,dp(10),0,0);intro.addView(theme);
            TextView subtitle=text("Музыка, которая подходит тебе",14);
            subtitle.setTextColor(NightwellDesign.SECONDARY);
            subtitle.setGravity(Gravity.CENTER);
            subtitle.setPadding(0,dp(8),0,0);
            intro.addView(subtitle);
            stage.addView(intro,new android.widget.FrameLayout.LayoutParams(-1,-2,Gravity.TOP));
            homePlay=action("▶",()->{if(currentID.isEmpty())wave();else toggle();});homePlay.setTextColor(NightwellDesign.BACKGROUND);homePlay.setTextSize(31);homePlay.setBackground(NightwellDesign.ripple(this,0xeef5f6f7,44,false));homePlay.setElevation(dp(9));android.widget.FrameLayout.LayoutParams playParams=new android.widget.FrameLayout.LayoutParams(dp(88),dp(88),Gravity.CENTER);if(compact){playParams.gravity=Gravity.CENTER_VERTICAL|Gravity.RIGHT;playParams.rightMargin=dp(50);}else playParams.topMargin=dp(30);stage.addView(homePlay,playParams);
            TextView mix=action("Новая подборка",this::wave);mix.setOnLongClickListener(v->{waveSettings();return true;});mix.setContentDescription("Новая подборка. Удерживай, чтобы настроить");mix.setTextSize(14);mix.setBackground(NightwellDesign.ripple(this,NightwellDesign.RAISED,17,true));mix.setTextColor(NightwellDesign.PRIMARY);mix.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));android.widget.FrameLayout.LayoutParams mixParams=new android.widget.FrameLayout.LayoutParams(dp(184),dp(44),Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);mixParams.bottomMargin=dp(compact?18:106);stage.addView(mix,mixParams);
            homeLyric=text("",16);homeLyric.setGravity(Gravity.CENTER);homeLyric.setTextColor(0xffe1e1e1);homeLyric.setMaxLines(2);homeLyric.setOnClickListener(v->{JSONObject t=current();if(t!=null)showLyrics(t);});android.widget.FrameLayout.LayoutParams lyricParams=new android.widget.FrameLayout.LayoutParams(-1,dp(50),Gravity.BOTTOM);stage.addView(homeLyric,lyricParams);if(compact)homeLyric.setVisibility(View.GONE);
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
            }return;
        }
        if(screen.equals("Поиск")){
            LinearLayout searchRow=row();
            searchRow.setBackground(NightwellDesign.ripple(this,NightwellDesign.FIELD,19,true));
            searchRow.setPadding(dp(9),0,dp(8),0);
            TextView icon=action("⌕",()->{if(search!=null){search.requestFocus();((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(search,android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT);}});
            icon.setPadding(0,0,0,0);icon.setTextColor(NightwellDesign.MUTED);
            searchRow.addView(icon,new LinearLayout.LayoutParams(dp(38),dp(48)));
            search=new EditText(this);search.setTextColor(NightwellDesign.PRIMARY);
            search.setSingleLine(true);search.setTextSize(15);search.setHintTextColor(NightwellDesign.MUTED);
            search.setPadding(dp(8),dp(10),dp(8),dp(10));
            search.setBackgroundColor(Color.TRANSPARENT);
            search.setHint("Название, артист или альбом");
            search.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH);
            searchRow.addView(search,new LinearLayout.LayoutParams(0,dp(54),1));
            LinearLayout.LayoutParams searchLayout=new LinearLayout.LayoutParams(-1,-2);
            searchLayout.bottomMargin=dp(15);body.addView(searchRow,searchLayout);
            search.addTextChangedListener(new TextWatcher(){
                public void beforeTextChanged(CharSequence s,int st,int c,int a){}
                public void onTextChanged(CharSequence s,int st,int before,int count){
                    query=s.toString();search(query);
                }
                public void afterTextChanged(Editable e){}
            });
            shown=new JSONArray();artistStrip=column();body.addView(artistStrip);
        }
        else if(screen.equals("Избранное")){shown=sortedFavorites(buildFavorites());recoverMissingFavorites();LinearLayout actionsRow=row();actionsRow.setGravity(Gravity.CENTER_VERTICAL);
            TextView info=text(shown.length()+" треков",13);
            info.setTextColor(NightwellDesign.MUTED);
            actionsRow.addView(info,new LinearLayout.LayoutParams(0,-2,1));
            TextView sort=iconButton("⇅",()->favoriteSortMenu());
            sort.setContentDescription("Сортировать избранное");
            actionsRow.addView(sort,new LinearLayout.LayoutParams(dp(46),dp(46)));
            TextView more=iconButton("⋯",()->collectionMenu("likes",""));
            LinearLayout.LayoutParams moreParams=new LinearLayout.LayoutParams(dp(46),dp(46));
            moreParams.leftMargin=dp(8);actionsRow.addView(more,moreParams);
            LinearLayout.LayoutParams actionsParams=new LinearLayout.LayoutParams(-1,-2);
            actionsParams.bottomMargin=dp(12);body.addView(actionsRow,actionsParams);}
        else if(screen.equals("Плейлисты")){
            android.widget.ScrollView scroll=new android.widget.ScrollView(this);
            scroll.setVerticalScrollBarEnabled(false);scroll.setClipToPadding(false);
            LinearLayout entries=column();entries.setPadding(0,0,0,dp(16));
            scroll.addView(entries);body.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
            TextView create=sheetAction("＋  Создать плейлист",()->input("Новый плейлист",
                name->task(()->api.request("api/playlists","POST",new JSONObject().put("name",name)),v->load())));
            NightwellDesign.styleButton(this,create,true);
            create.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams cta=new LinearLayout.LayoutParams(-1,dp(52));
            cta.bottomMargin=dp(15);entries.addView(create,cta);
            TextView smart=sectionLabel("Подборки Nightwell");entries.addView(smart);
            addPlaylistEntry(entries,"Умные плейлисты","Premium · по твоим предпочтениям",()->feature("smart"),null);
            addPlaylistEntry(entries,"Подборки дня","Обновляются ежедневно",this::dailyPublicPlaylists,null);
            entries.addView(sectionLabel("Твои плейлисты"));
            if(playlists.length()==0){
                TextView empty=text("Здесь будут твои плейлисты",14);
                empty.setTextColor(NightwellDesign.MUTED);
                empty.setPadding(dp(10),dp(24),dp(10),dp(24));
                empty.setGravity(Gravity.CENTER);entries.addView(empty);
            }
            for(int i=0;i<playlists.length();i++){
                JSONObject p=playlists.optJSONObject(i);
                if(p==null)continue;
                addPlaylistEntry(entries,p.optString("name"),"Личная медиатека",
                    ()->openPlaylist(p),()->collectionMenu("playlist",p.optString("id")));
            }
            return;
        }
        else if(screen.equals("Офлайн")){
            TextView importButton=sheetAction("＋  Добавить аудиофайлы",this::importFiles);
            NightwellDesign.styleButton(this,importButton,false);
            LinearLayout.LayoutParams importParams=new LinearLayout.LayoutParams(-1,dp(50));
            importParams.bottomMargin=dp(12);
            body.addView(importButton,importParams);
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
        list=new ListView(this);
        list.setDivider(new android.graphics.drawable.ColorDrawable(NightwellDesign.BACKGROUND));
        list.setDividerHeight(dp(7));
        list.setSelector(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        list.setVerticalScrollBarEnabled(false);
        list.setCacheColorHint(Color.TRANSPARENT);
        list.setClipToPadding(false);
        list.setPadding(0,dp(3),0,dp(18));
        adapter=new TrackAdapter();list.setAdapter(adapter);
        body.addView(list,new LinearLayout.LayoutParams(-1,0,1));
        list.setOnItemClickListener((p,v,pos,id)->{
            JSONObject item=shown.optJSONObject(pos);
            if(item==null)return;
            if(item.optBoolean("_unresolved")){
                status.setText("Сведения об этом треке пока недоступны. Обновляем избранное.");
                recoverMissingFavorites();return;
            }
            play(item,shown,false);
        });
        list.setOnItemLongClickListener((p,v,pos,id)->{trackMenu(shown.optJSONObject(pos));return true;});
    }

    private void addPlaylistEntry(LinearLayout parent,String name,String subtitle,
                                  Runnable open,Runnable more){
        LinearLayout container=row();
        container.setBackground(NightwellDesign.ripple(this,NightwellDesign.SURFACE,18,true));
        container.setPadding(dp(12),dp(12),dp(10),dp(12));
        View iconBackground=new View(this);
        iconBackground.setBackground(NightwellDesign.surface(this,NightwellDesign.RAISED,12,false));
        android.widget.FrameLayout cover=new android.widget.FrameLayout(this);
        cover.addView(iconBackground,new android.widget.FrameLayout.LayoutParams(-1,-1));
        TextView glyph=text("♫",24);glyph.setTextColor(NightwellDesign.PRIMARY);
        glyph.setGravity(Gravity.CENTER);
        cover.addView(glyph,new android.widget.FrameLayout.LayoutParams(-1,-1));
        container.addView(cover,new LinearLayout.LayoutParams(dp(48),dp(48)));
        LinearLayout copy=column();copy.setPadding(dp(12),0,dp(4),0);
        TextView title=text(name,15);NightwellDesign.headline(title);
        title.setSingleLine(true);title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        copy.addView(title);
        TextView detail=text(subtitle,12);NightwellDesign.detail(detail);
        detail.setPadding(0,dp(5),0,0);detail.setSingleLine(true);
        detail.setEllipsize(android.text.TextUtils.TruncateAt.END);copy.addView(detail);
        copy.setOnClickListener(v->open.run());
        container.addView(copy,new LinearLayout.LayoutParams(0,-2,1));
        if(more!=null){
            TextView action=iconButton("⋯",more);
            action.setBackgroundColor(Color.TRANSPARENT);
            container.addView(action,new LinearLayout.LayoutParams(dp(42),dp(44)));
        }else{
            TextView arrow=text("›",25);arrow.setTextColor(NightwellDesign.MUTED);
            arrow.setGravity(Gravity.CENTER);
            container.addView(arrow,new LinearLayout.LayoutParams(dp(24),dp(44)));
        }
        container.setOnClickListener(v->open.run());
        LinearLayout.LayoutParams margins=new LinearLayout.LayoutParams(-1,-2);
        margins.bottomMargin=dp(9);parent.addView(container,margins);
    }

    void updateList(){
        if(shown==null)shown=new JSONArray();
        // Search results are already normalized by NativeAPI off the UI thread.
        if(!screen.equals("Поиск")){
            for(int i=0;i<shown.length();i++)NativeAPI.normalizeTrack(shown.optJSONObject(i));
        }
        rememberFavorites(shown);if(adapter!=null)adapter.notifyDataSetChanged();
    }
    // The /api/likes endpoint provides IDs, while /api/tracks may be a partial catalog.
    // Keep the last known metadata so favorites never disappear on catalog refresh.
    private String favoriteDetailsKey(){
        return origin+"|"+(user.isEmpty()?"device":user);
    }
    private void rememberFavorite(JSONObject track){
        if(track==null)return;
        String id=track.optString("id");
        if(id.isEmpty()||!likes.contains(id)||track.optBoolean("_unresolved"))return;
        favoriteDetails.put(id,track);
    }
    private void rememberFavorites(JSONArray tracks){
        if(tracks==null)return;
        for(int i=0;i<tracks.length();i++)rememberFavorite(tracks.optJSONObject(i));
    }
    private void restoreFavoriteDetails(){
        favoriteDetails.clear();
        try{
            String value=getSharedPreferences("favorite-track-cache",MODE_PRIVATE)
                .getString(favoriteDetailsKey(),"[]");
            JSONArray items=new JSONArray(value);
            for(int i=0;i<items.length();i++){
                JSONObject t=items.optJSONObject(i);
                if(t!=null&&!t.optString("id").isEmpty())favoriteDetails.put(t.optString("id"),t);
            }
        }catch(Exception ignored){}
    }
    private void saveFavoriteDetails(){
        if(user.isEmpty()||smokeMode)return;
        JSONArray items=new JSONArray();
        // Prefer recent favorites, but retain a practical bounded offline index.
        for(String id:likeOrder){
            JSONObject track=favoriteDetails.get(id);
            if(track!=null)items.put(track);
            if(items.length()>=1200)break;
        }
        String value=items.toString();
        if(value.length()>1100000)return;
        getSharedPreferences("favorite-track-cache",MODE_PRIVATE).edit()
            .putString(favoriteDetailsKey(),value).apply();
    }
    private JSONArray buildFavorites(){
        LinkedHashMap<String,JSONObject> available=new LinkedHashMap<>(favoriteDetails);
        for(int i=0;i<catalog.length();i++){
            JSONObject item=catalog.optJSONObject(i);
            if(item!=null&&likes.contains(item.optString("id")))
                available.put(item.optString("id"),item);
        }
        for(int i=0;i<queue.length();i++){
            JSONObject item=queue.optJSONObject(i);
            if(item!=null&&likes.contains(item.optString("id")))
                available.put(item.optString("id"),item);
        }
        JSONArray values=new JSONArray();
        HashSet<String> included=new HashSet<>();
        for(String id:likeOrder){
            if(!likes.contains(id)||!included.add(id))continue;
            JSONObject item=available.get(id);
            if(item==null){
                item=new JSONObject();
                try{item.put("id",id).put("title","Трек из избранного")
                    .put("artist","Загружаем сведения")
                    .put("_unresolved",true);}catch(JSONException ignored){}
            }else rememberFavorite(item);
            values.put(item);
        }
        for(String id:likes){
            if(!included.add(id))continue;
            JSONObject item=available.get(id);
            if(item!=null)values.put(item);
        }
        return values;
    }
    private void recoverMissingFavorites(){
        if(user.isEmpty()||smokeMode)return;
        long now=SystemClock.elapsedRealtime();
        if(now-lastFavoriteRecovery<45000)return;
        ArrayList<String> missing=new ArrayList<>();
        for(String id:likeOrder)if(!favoriteDetails.containsKey(id)
            &&id.matches("[a-fA-F0-9]{32}")){
            missing.add(id);
            if(missing.size()>=16)break;
        }
        if(missing.isEmpty())return;
        lastFavoriteRecovery=now;
        final String owner=user;
        final int generation=++favoriteRecoveryGeneration;
        // Existing shared-track endpoint is used only as a best-effort metadata source.
        // Do not overwrite the user's favorites set if metadata is unavailable.
        prefetch.execute(()->{
            ArrayList<JSONObject> recovered=new ArrayList<>();
            for(String id:missing){
                if(generation!=favoriteRecoveryGeneration||Thread.currentThread().isInterrupted())return;
                try{
                    JSONObject result=api.request("api/shared-track/"+id);
                    JSONArray tracks=result.optJSONArray("tracks");
                    if(tracks!=null)for(int k=0;k<tracks.length();k++){
                        JSONObject item=tracks.optJSONObject(k);
                        if(item!=null&&id.equalsIgnoreCase(item.optString("id")))
                            recovered.add(item);
                    }
                }catch(Exception ignored){}
            }
            ui.post(()->{
                if(isDestroyed()||!owner.equals(user)||generation!=favoriteRecoveryGeneration)return;
                for(JSONObject item:recovered)rememberFavorite(item);
                if(!recovered.isEmpty()){
                    saveFavoriteDetails();
                    if("Избранное".equals(screen)&&!full)showScreen();
                }
            });
        });
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
            if(savedLikes!=null){likes.clear();likeOrder.clear();for(int i=0;i<savedLikes.length();i++){String id=savedLikes.optString(i);if(likes.add(id))likeOrder.add(id);}}
            restoreFavoriteDetails();rememberFavorites(catalog);
        }catch(Exception ignored){}
    }
    private void saveLibrarySnapshot(){
        if(user.isEmpty()||smokeMode)return;
        try {
            JSONObject snapshot=new JSONObject();
            snapshot.put("account",user);
            JSONArray tracks=new JSONArray();
            for(int i=0;i<Math.min(catalog.length(),1500);i++)tracks.put(catalog.opt(i));
            snapshot.put("tracks",tracks);
            snapshot.put("playlists",playlists);
            snapshot.put("likes",new JSONArray(likeOrder));
            rememberFavorites(catalog);saveFavoriteDetails();
            String value=snapshot.toString();
            if(value.length()>750000)return;
            getSharedPreferences("library-snapshot",MODE_PRIVATE).edit().putString("snapshot",value).apply();
        }catch(Exception ignored){}
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
                        libraryGeneration++;favoriteRecoveryGeneration++;catalog=new JSONArray();shown=new JSONArray();playlists=new JSONArray();likes.clear();likeOrder.clear();favoriteDetails.clear();selectedPlaylist="";
                        if(playback!=null)playback.stop();
                    }
                    boolean accountChanged=!nextAccount.equals(user);
                    user=nextAccount;
                    if(!nextAccount.equals(getSharedPreferences("native-api",MODE_PRIVATE).getString("account","")))searchCache.clear();
                    if(accountChanged)restoreRecent();
                    getSharedPreferences("native-api",MODE_PRIVATE).edit().putString("account",user).apply();
                    sessionReady=true;openPendingTogether();
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
                        likes.clear();likeOrder.clear();
                        selectedPlaylist="";
                        getSharedPreferences("native-api",MODE_PRIVATE).edit().putString("account","").apply();
                        if(playback!=null)playback.stop();
                        if(!full&&!screen.equals("Поиск"))showScreen();
                    }
                    sessionReady=true;openPendingTogether();
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
                    catalog=tracks;rememberFavorites(tracks);saveLibrarySnapshot();checkAutoFavoriteDownloads();if(!full&&!screen.equals("Поиск"))showScreen();
                }});
            }catch(Exception ex){ui.post(()->{if(!isDestroyed()&&client==api&&revision==libraryGeneration&&account.equals(user))status.setText(friendly(ex));});}
        });
        io.execute(()->{
            try{
                JSONObject value=client.request("api/likes");
                JSONArray ids=value.optJSONArray("ids");
                ui.post(()->{if(!isDestroyed()&&client==api&&revision==libraryGeneration&&account.equals(user)&&ids!=null){
                    likes.clear();likeOrder.clear();for(int i=0;i<ids.length();i++){String id=ids.optString(i);if(likes.add(id))likeOrder.add(id);}
                    rememberFavorites(value.optJSONArray("tracks"));rememberFavorites(value.optJSONArray("items"));
                    rememberFavorites(catalog);saveLibrarySnapshot();checkAutoFavoriteDownloads();
                    if(!full&&screen.equals("Избранное"))showScreen();
                }});
            }catch(Exception ignored){}
        });
        io.execute(()->{
            try{
                JSONObject value=client.request("api/playlists");
                JSONArray items=value.optJSONArray("playlists");
                ui.post(()->{if(!isDestroyed()&&client==api&&revision==libraryGeneration&&account.equals(user)&&items!=null){
                    playlists=items;saveLibrarySnapshot();if(!full&&screen.equals("Плейлисты"))showScreen();
                }});
            }catch(Exception ignored){}
        });
    }
    void smokeFixture(String page){try{user="smoke";catalog=new JSONArray();for(int i=0;i<24;i++)catalog.put(new JSONObject().put("id",String.format(java.util.Locale.ROOT,"%032x",i+1)).put("title",i==0?"Очень длинное название трека, которое должно аккуратно поместиться":"Трек "+(i+1)).put("artist","Nightwell Music · Исполнитель"));queue=catalog;playlists=new JSONArray();for(int i=0;i<16;i++)playlists.put(new JSONObject().put("id","fixture"+i).put("name","Мой плейлист "+(i+1)));for(int i=0;i<catalog.length();i++)likes.add(catalog.getJSONObject(i).getString("id"));currentID=catalog.getJSONObject(0).getString("id");miniTitle.setText(catalog.getJSONObject(0).getString("title"));miniArtist.setText("Nightwell Music");if("transfer".equals(page)){nativeTransfer();}else if("menu".equals(page)){head.post(this::menu);}else if("player".equals(page))openPlayer();else if("settings".equals(page))settings();else if("premium-sound".equals(page)||"premium-appearance".equals(page)){premiumOwner=user;premiumUntil=System.currentTimeMillis()+3600000;premiumChecked=System.currentTimeMillis();premiumPrefs=new JSONObject().put("bands",new JSONArray("[0,0,0,0,0]")).put("presets",new JSONObject()).put("theme","nightwell").put("ribbon_speed",1).put("ribbon_intensity",1);if("premium-sound".equals(page))equalizerPanel();else appearancePanel();}else if("wave-settings".equals(page))waveSettings();else if("auth".equals(page))auth();else if("queue".equals(page))showQueue();else if(page!=null)navigate(page);}catch(JSONException e){throw new IllegalStateException(e);}}
    String friendly(Exception error){if(error instanceof java.net.UnknownHostException||error instanceof java.net.ConnectException||error instanceof java.net.SocketTimeoutException)return "Нет соединения. Офлайн-файлы доступны в меню.";String message=error.getMessage();return message!=null&&!message.startsWith("Unable")&&message.length()<180?message:"Не удалось выполнить действие. Повтори попытку.";}
    interface Work{JSONObject run()throws Exception;} interface Done{void run(JSONObject value);}
    void task(Work work,Done done){io.execute(()->{try{JSONObject value=work.run();ui.post(()->{if(!isDestroyed())done.run(value);});}catch(Exception ex){ui.post(()->{if(!isDestroyed())status.setText(friendly(ex));});}});}
    JSONArray rankSearchResults(JSONArray tracks, String query) {
        java.util.List<JSONObject> items = new java.util.ArrayList<>();
        if (tracks != null) for (int i = 0; i < tracks.length(); i++) {
            JSONObject track = tracks.optJSONObject(i);
            if (track != null) items.add(track);
        }
        JSONArray ranked = new JSONArray();
        int visible=0;
        for (JSONObject track : RecommendationOrder.rankSearch(items, query,
            t -> t.optString("title"), t -> t.optString("artist"))) {
            if(visible++>=200)break;
            ranked.put(track);
        }
        return ranked;
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
                if(attempt==0&&cached==null) {
                    java.util.List<JSONObject> local=new java.util.ArrayList<>();
                    String target=RecommendationOrder.key(text);
                    for(int i=0;i<Math.min(2000,catalog.length());i++) {
                        JSONObject item=catalog.optJSONObject(i);
                        if(item==null)continue;
                        String label=RecommendationOrder.key(item.optString("title")+" "+item.optString("artist"));
                        if(label.contains(target))local.add(item);
                    }
                    JSONArray quick=new JSONArray();
                    int previewCount=0;
                    for(JSONObject item:RecommendationOrder.rankSearch(local,text,
                        t->t.optString("title"),t->t.optString("artist"))) {
                        if(previewCount++>=140)break;
                        quick.put(item);
                    }
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
                    final JSONArray remote=rankSearchResults(found.optJSONArray("tracks"),text);
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

    void play(JSONObject track,JSONArray tracks,boolean wave){if(track==null)return;if(user.isEmpty()&&!track.optBoolean("_offline")){auth();return;}if(playback==null){status.setText("Аудиоплеер запускается. Повтори через секунду.");return;}try{cancelMix();playback.prepare(new JSONObject().put("id",track.getString("id")).put("queue",tracks).put("origin",origin).put("account",user.isEmpty()?"device":user).put("wave",wave).put("wave_preferences",WaveSettings.read(this,origin,user).json()).toString());if(playback.player.getCurrentMediaItem()==null||!track.getString("id").equals(playback.player.getCurrentMediaItem().mediaId)){status.setText("Аудиофайл недоступен. Открой «Офлайн» и скачай его снова.");return;}playback.play();updatePlayback();publishLive(true);if(together!=null)together.nativeTrack(track.optString("id"));}catch(Exception ex){status.setText(friendly(ex));}}
    void toggle(){cancelMix();if(playback!=null){if(playback.player.getPlayWhenReady())playback.pause();else playback.play();updatePlayback();if(together!=null)together.nativeToggle(playback.player.getPlayWhenReady());if(liveOwner)publishLive(false);}}
    private long lastPrevious;private String previousID="";
    void nextTrack(){if(together!=null&&together.nativeNext("next"))return;trackTransitionDirection=1;cancelMix();if(playback!=null){if(shuffleMode()==2)prepareSmartNext();playback.player.seekToNextMediaItem();}}
    void previous(){if(together!=null&&together.nativeNext("previous"))return;trackTransitionDirection=-1;cancelMix();if(playback==null)return;long now=SystemClock.uptimeMillis();if(playback.player.getCurrentPosition()>3000&&!(currentID.equals(previousID)&&now-lastPrevious<3000)){previousID=currentID;lastPrevious=now;playback.seek(0);}else{previousID="";playback.player.seekToPreviousMediaItem();}}
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
        io.execute(()->{
            try{
                if(!waveRequest.pending(ticket))return;
                String nonce=UUID.randomUUID().toString();
                JSONObject value=client.search("api/wave?mix="+nonce+settings.query()+"&exclude="+java.net.URLEncoder.encode(limitedExclusions(excluded),"UTF-8"));
                JSONArray raw=value.optJSONArray("tracks");
                if((raw==null||raw.length()==0)&&!playingID.isEmpty())raw=client.search("api/wave?mix="+nonce+settings.query()+"&exclude="+playingID).optJSONArray("tracks");
                final JSONArray fresh=new JSONArray();
                if(raw!=null)for(int i=0;i<raw.length();i++)if(!playingID.equals(raw.optJSONObject(i).optString("id"))&&!hidden.contains(raw.optJSONObject(i).optString("id")))fresh.put(raw.optJSONObject(i));
                ui.post(()->{
                    if(isDestroyed()||!waveRequest.complete(ticket))return;
                    mixing=false;
                    if(!account.equals(user))return;
                    if(fresh.length()>0){
                        java.util.List<JSONObject> candidates=new java.util.ArrayList<>();for(int i=0;i<fresh.length();i++)candidates.add(fresh.optJSONObject(i));
                        JSONArray ordered=new JSONArray();
                        for(JSONObject t:RecommendationOrder.arrange(candidates,new java.util.HashSet<>(mixRecent),hidden,blockedArtists,playingID,t->t.optString("id"),t->t.optString("title"),t->t.optString("artist")))ordered.put(t);
                        if(ordered.length()==0){status.setText("Все найденные треки скрыты фильтрами рекомендаций.");return;}
                        status.setText("");play(ordered.optJSONObject(0),ordered,true);
                    }else status.setText("Новых треков пока нет. Попробуй чуть позже.");
                });
            }catch(Exception e){ui.post(()->{if(isDestroyed()||!waveRequest.complete(ticket))return;mixing=false;status.setText(friendly(e));});}
            finally{client.close();}
        });
    }

    void setLabel(TextView view,String value){if(view!=null&&!android.text.TextUtils.equals(view.getText(),value))view.setText(value);}
    void updatePlayback(){if(smokeMode||playback==null)return;try{JSONObject state=new JSONObject(playback.snapshot(false));String next=state.optString("id");if(!currentID.equals(next)||queue.length()!=state.optInt("queueCount")){queue=new JSONObject(playback.snapshot(true)).optJSONArray("queueTracks");}if(queue==null)queue=new JSONArray();JSONObject t=null;for(int i=0;i<queue.length();i++)if(queue.optJSONObject(i).optString("id").equals(next)){t=queue.optJSONObject(i);break;}rememberFavorite(t);setLabel(miniTitle,t==null?"Выбери трек":t.optString("title"));setLabel(miniArtist,t==null?"Nightwell Music":t.optString("artist"));refreshFavoriteButtons();if(miniProgressRing!=null)miniProgressRing.setProgress(state.optDouble("position")/Math.max(1,state.optDouble("duration")));if(ambient!=null){ambient.setPlaybackActive(state.optBoolean("playing"));updateArtworkReaction();}setLabel(miniPlay,state.optBoolean("playing")?"Ⅱ":"▶");if(homePlay!=null)setLabel(homePlay,state.optBoolean("playing")?"Ⅱ":"▶");if(fullPlay!=null)setLabel(fullPlay,state.optBoolean("playing")?"Ⅱ":"▶");if(ribbon!=null)ribbon.playing(state.optBoolean("playing"));if(!currentID.equals(next)){currentID=next;if(!next.isEmpty()){rememberRecent(next);checkTrackAudioQuality(t);}activeLyrics=null;homeLine="";loadMiniCover(t);fetchLyricsAndPreload();animateTrackTransition();updateList();if(full)openPlayer();}if(seek!=null&&!seek.isPressed()){seek.setMax((int)Math.max(1,state.optDouble("duration")));seek.setProgress((int)state.optDouble("position"));}if(fullTime!=null)setLabel(fullTime,time(state.optDouble("position"))+"     /     "+time(state.optDouble("duration")));if(!state.optString("error").isEmpty())status.setText(state.optString("error"));syncLyrics(state.optDouble("position"));syncHomeLyrics(state.optDouble("position"));if(lastPlaying!=state.optBoolean("playing")){lastPlaying=state.optBoolean("playing");updateList();}}catch(Exception ignored){}}
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
        JSONObject track=current();if(track==null)return;full=true;updateArtworkAppearance();dock.setVisibility(View.GONE);head.setVisibility(View.GONE);body.removeAllViews();
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
        fullAudioOutput.setBackground(NightwellDesign.ripple(this,0x99202226,13,true));
        fullAudioOutput.setContentDescription("Устройство вывода: "+audioOutputName()+". Изменить");
        fullAudioOutput.setOnClickListener(v->chooseAudioOutput());
        LinearLayout.LayoutParams routeParams=new LinearLayout.LayoutParams(-2,dp(30));
        routeParams.gravity=Gravity.CENTER_HORIZONTAL;
        center.addView(fullAudioOutput,routeParams);
        TextView caption=text("СЕЙЧАС ИГРАЕТ",11);caption.setLetterSpacing(.16f);caption.setTextColor(NightwellDesign.SECONDARY);
        caption.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams captionParams=new LinearLayout.LayoutParams(-1,dp(24));
        center.addView(caption,captionParams);
        top.addView(center,new LinearLayout.LayoutParams(0,dp(60),1));
        top.addView(iconButton("⋯",()->fullPlayerMenu(track)),new LinearLayout.LayoutParams(dp(48),dp(48)));
        body.addView(top);
        android.widget.ScrollView scroll=new android.widget.ScrollView(this);scroll.setFillViewport(true);scroll.setClipToPadding(false);LinearLayout content=column();content.setPadding(0,dp(16),0,dp(16));scroll.addView(content);body.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        addCover(track,content);
        LinearLayout metadata=row();metadata.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout names=column();
        TextView title=text(track.optString("title"),25);title.setMaxLines(2);title.setLetterSpacing(-.025f);title.setLineSpacing(dp(2),1f);title.setAutoSizeTextTypeUniformWithConfiguration(19,25,1,android.util.TypedValue.COMPLEX_UNIT_SP);title.setEllipsize(android.text.TextUtils.TruncateAt.END);title.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);title.setPadding(dp(8),dp(18),dp(8),dp(6));names.addView(title);
        TextView artist=text(track.optString("artist")+"  ›",12);artist.setTextColor(0xffd3d3da);artist.setMaxLines(2);artist.setEllipsize(android.text.TextUtils.TruncateAt.END);artist.setPadding(dp(10),dp(6),dp(10),dp(6));artist.setBackground(NightwellDesign.ripple(this,0x99202226,14,true));artist.setOnClickListener(v->chooseArtist(track.optString("artist")));artist.setContentDescription("Открыть исполнителя");names.addView(artist);
        metadata.addView(names,new LinearLayout.LayoutParams(0,-2,1));
        fullLike=iconButton(likes.contains(track.optString("id"))?"♥":"♡",()->toggleFavorite(current()));
        fullLike.setContentDescription(likes.contains(track.optString("id"))?"Убрать из избранного":"Добавить в избранное");
        fullLike.setTextColor(likes.contains(track.optString("id"))?0xffeeeeee:0xffa4a6b1);
        LinearLayout.LayoutParams likeParams=new LinearLayout.LayoutParams(dp(48),dp(48));
        likeParams.setMargins(dp(4),0,dp(0),0);
        fullDislike=iconButton("👎",()->{
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
        fullDislike.setContentDescription(hidden?"Вернуть в рекомендации":"Не рекомендовать");
        metadata.addView(fullDislike,new LinearLayout.LayoutParams(dp(44),dp(48)));
        metadata.addView(fullLike,likeParams);
        content.addView(metadata);
        LinearLayout transport=column();transport.setPadding(dp(16),dp(14),dp(16),dp(9));transport.setBackground(NightwellDesign.surface(this,0xa71c1e22,24,true));content.addView(transport);
        seek=new SeekBar(this);styleSeekBar(seek);seek.setMinimumHeight(dp(44));seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onProgressChanged(SeekBar b,int p,boolean user){}public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){cancelMix();if(playback!=null)playback.seek(b.getProgress());}});transport.addView(seek);fullTime=text("",12);fullTime.setPadding(dp(8),0,dp(8),dp(12));fullTime.setTextColor(NightwellDesign.SECONDARY);transport.addView(fullTime);
        LinearLayout controls=row();controls.setGravity(Gravity.CENTER);
        TextView shuffleButton=iconButton("⇄",this::cycleShuffleMode);fullShuffle=shuffleButton;refreshShuffleButton();
        TextView backward=iconButton("|‹",this::previous);
        fullPlay=iconButton(playback!=null&&playback.player.getPlayWhenReady()?"Ⅱ":"▶",this::toggle);
        TextView forward=iconButton("›|",this::nextTrack);
        TextView repeatButton=iconButton("↻",()->{if(playback!=null)playback.modes((playback.player.getRepeatMode()+1)%3,playback.player.getShuffleModeEnabled());});
        for(TextView button:new TextView[]{shuffleButton,backward,forward,repeatButton}){
            button.setBackground(null);button.setPadding(0,0,0,0);button.setTextSize(25);
        }
        backward.setTextSize(31);forward.setTextSize(31);
        fullPlay.setTextColor(NightwellDesign.BACKGROUND);fullPlay.setTextSize(30);
        fullPlay.setBackground(NightwellDesign.ripple(this,0xfff5f6f7,38,false));
        fullPlay.setPadding(0,0,0,0);
        controls.addView(shuffleButton,new LinearLayout.LayoutParams(0,dp(56),1));
        controls.addView(backward,new LinearLayout.LayoutParams(0,dp(64),1));
        LinearLayout.LayoutParams centerPlay=new LinearLayout.LayoutParams(dp(76),dp(76));
        centerPlay.leftMargin=dp(2);centerPlay.rightMargin=dp(2);
        controls.addView(fullPlay,centerPlay);
        controls.addView(forward,new LinearLayout.LayoutParams(0,dp(64),1));
        controls.addView(repeatButton,new LinearLayout.LayoutParams(0,dp(56),1));
        transport.addView(controls);
        TextView queueButton=action("Дальше в очереди  ·  "+queue.length(),this::showQueue);queueButton.setTextSize(14);queueButton.setTextColor(0xffc8c8c8);transport.addView(queueButton);updatePlayback();
    }
    void loadMiniCover(JSONObject track) {
        if (miniCover == null || artworkCache == null) return;
        artworkCache.load(miniCover,origin,track==null?"":track.optString("cover_url"),bitmap->{
            if(ambient!=null){
                ambient.setArtwork(bitmap);
                if(miniProgressRing!=null)miniProgressRing.setAccent(ambient.accentColor());
            }
        });
    }
    void addCover(JSONObject track,LinearLayout parent) {
        android.widget.ImageView cover=new android.widget.ImageView(this);
        cover.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
        android.view.GestureDetector detector=gestures(true);
        cover.setOnTouchListener((v,event)->detector.onTouchEvent(event));
        GradientDrawable corners=new GradientDrawable();
        corners.setColor(0x33251936);boolean classic=getSharedPreferences("appearance",MODE_PRIVATE).getBoolean("cover-classic",false);corners.setCornerRadius(dp(classic?25:8));
        cover.setBackground(corners);cover.setClipToOutline(true);
        int edge=Math.max(160,Math.min((int)(getResources().getConfiguration().screenHeightDp*
            (getResources().getConfiguration().screenHeightDp<700?.25f:.36f)),
            Math.min(getSharedPreferences("appearance",MODE_PRIVATE).getBoolean("cover-classic",false)?330:410,getResources().getConfiguration().screenWidthDp-(getSharedPreferences("appearance",MODE_PRIVATE).getBoolean("cover-classic",false)?44:4))));
        LinearLayout.LayoutParams coverLayout=new LinearLayout.LayoutParams(dp(edge),dp(edge));
        coverLayout.gravity=Gravity.CENTER_HORIZONTAL;
        parent.addView(cover,coverLayout);
        if(artworkCache!=null)artworkCache.load(cover,origin,track.optString("cover_url"));
    }
    String[] trackNames(JSONArray items){String[] names=new String[items.length()];for(int i=0;i<names.length;i++)names[i]=items.optJSONObject(i).optString("title");return names;}
    JSONObject cachedLyrics(String id)throws Exception {
        java.io.File dir=new java.io.File(getCacheDir(),"native-lyrics");dir.mkdirs();java.io.File file=new java.io.File(dir,id+".json");
        if(file.isFile()&&file.length()<2*1024*1024){try{JSONObject cached=new JSONObject(new String(java.nio.file.Files.readAllBytes(file.toPath()),java.nio.charset.StandardCharsets.UTF_8));long ttl=cached.optBoolean("lookup_complete",true)?30L*86400000:3600000;if(System.currentTimeMillis()-file.lastModified()<ttl&&cached.optString("status").equals("found"))return cached;}catch(Exception ignored){}}
        JSONObject value=api.request("api/lyrics/"+id);if(value.optString("status").equals("found"))java.nio.file.Files.write(file.toPath(),value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));return value;
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
        if(lyricsText!=null&&lyricsTrack.equals(id)){lyricLines=value.optBoolean("synced")?value.optJSONArray("lines"):null;activeLyric=-2;if(lyricLines==null)lyricsText.setText(value.optString("plain",value.optString("message",lyricsPending(value)?"Ищем подходящий текст…":"Текст пока не найден")));syncLyrics(playback==null?0:playback.player.getCurrentPosition()/1000.0);}
        if(!lyricsPollID.equals(id)){lyricsPollID=id;lyricsRound=0;}
        if(lyricsPending(value)&&lyricsRound++<20){int round=lyricsRound;ui.postDelayed(()->{if(!currentID.equals(id)||round!=lyricsRound)return;task(()->cachedLyrics(id),next->acceptLyrics(id,next));},Math.max(2000,Math.min(60000,value.optLong("retry_after",3)*1000)));}
    }
    void syncHomeLyrics(double position){
        if(homeLyric==null)return;
        String line="";double start=-1;
        if(getSharedPreferences("appearance",MODE_PRIVATE).getBoolean("ambient-lyrics",true)
            &&playback!=null&&playback.player.isPlaying()&&activeLyrics!=null&&activeLyrics.optBoolean("synced")){
            JSONArray lines=activeLyrics.optJSONArray("lines");
            if(lines!=null)for(int i=0;i<lines.length();i++){
                JSONObject entry=lines.optJSONObject(i);
                if(entry!=null&&entry.optDouble("time")<=position){
                    line=entry.optString("text");start=entry.optDouble("time");
                }else break;
            }
        }
        // Leave each line visible briefly, then fade it out until the next timed line.
        if(start>=0&&position-start>4.5)line="";
        if(!line.equals(homeLine)){
            homeLine=line;
            homeLyric.animate().cancel();
            if(line.isEmpty()){
                homeLyric.animate().alpha(0).translationY(-dp(6)).setDuration(550).start();
            }else{
                homeLyric.setText(line);homeLyric.setAlpha(0);homeLyric.setTranslationY(dp(8));
                homeLyric.animate().alpha(1).translationY(0).setDuration(350).start();
            }
        }
    }
    void showLyrics(JSONObject track){String id=track.optString("id");status.setText("Ищем текст…");task(()->cachedLyrics(id),v->{
        if(!currentID.equals(id))return;acceptLyrics(id,v);lyricLines=v.optBoolean("synced")?v.optJSONArray("lines"):null;lyricsTrack=id;activeLyric=-2;
        lyricsScroll=new android.widget.ScrollView(this);lyricsText=text("",26);lyricsText.setGravity(Gravity.CENTER);lyricsText.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);lyricsText.setPadding(dp(22),dp(28),dp(22),dp(28));lyricsText.setLineSpacing(dp(16),1);lyricsScroll.addView(lyricsText);
        if(lyricLines==null||lyricLines.length()==0)lyricsText.setText(v.optString("plain",v.optString("message",lyricsPending(v)?"Ищем подходящий текст…":"Текст пока не найден")));
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Текст песни · "+v.optString("source")).setView(lyricsScroll).setPositiveButton("Закрыть",null).create();dialog.setOnDismissListener(d->{lyricsText=null;lyricsScroll=null;lyricLines=null;});styleSheet(dialog);dialog.show();status.setText("");syncLyrics(playback==null?0:playback.player.getCurrentPosition()/1000.0);
    });}
    void syncLyrics(double position){if(lyricsText==null||lyricLines==null||!currentID.equals(lyricsTrack))return;int current=-1;for(int i=0;i<lyricLines.length();i++)if(lyricLines.optJSONObject(i).optDouble("time")<=position)current=i;if(current==activeLyric)return;activeLyric=current;StringBuilder all=new StringBuilder();int start=0,end=0;for(int i=0;i<lyricLines.length();i++){if(i==current)start=all.length();all.append(lyricLines.optJSONObject(i).optString("text")).append("\n\n");if(i==current)end=all.length();}android.text.SpannableString styled=new android.text.SpannableString(all);styled.setSpan(new android.text.style.ForegroundColorSpan(0xff9c9c9c),0,styled.length(),0);if(current>=0){styled.setSpan(new android.text.style.ForegroundColorSpan(0xffeeeeee),start,end,0);styled.setSpan(new android.text.style.StyleSpan(android.graphics.Typeface.BOLD),start,end,0);}lyricsText.setText(styled);final int offset=start;lyricsText.post(()->{if(lyricsText==null||lyricsScroll==null||lyricsText.getLayout()==null)return;int line=lyricsText.getLayout().getLineForOffset(Math.min(offset,lyricsText.length()));lyricsScroll.smoothScrollTo(0,Math.max(0,lyricsText.getLayout().getLineTop(line)-lyricsScroll.getHeight()/3));});}

    void fullPlayerMenu(JSONObject track){
        nightwellOptions("Плеер",new String[]{"Качество звука","Эквалайзер","Действия с треком"},
            n->{if(n==0)qualityPlayerMenu();else if(n==1)feature("sound");else trackMenu(track);});
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
        String offlineOwner=track.optString("_offline_account",user.isEmpty()?"device":user);
        boolean saved=OfflineStore.audio(this,origin,offlineOwner,id)!=null;
        String[] options={
            likes.contains(id)?"Убрать из избранного":"В избранное",
            saved?"Удалить загрузку":"Скачать", "Поделиться", "Добавить в плейлист",
            hiddenRecommendations().contains(id)?"Вернуть в рекомендации":"Не рекомендовать",
            isArtistHidden(track)?"Вернуть исполнителя":"Не рекомендовать исполнителя"
        };
        AlertDialog actions=new AlertDialog.Builder(this).setTitle(track.optString("title"))
            .setItems(options,(d,n)->{
                if(n==0)toggleFavorite(track);
                else if(n==1){
                    if(saved){
                        try {
                            String reply=OfflineStore.operation(this,origin,new JSONObject()
                                .put("op","remove").put("account",offlineOwner).put("id",id).toString());
                            if(new JSONObject(reply).optBoolean("ok")) {
                                status.setText("Загрузка удалена");
                                if(screen.equals("Офлайн"))showScreen();
                            }else status.setText("Не удалось удалить загрузку");
                        } catch(Exception ex){status.setText("Не удалось удалить загрузку");}
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
            shown=tracks;rememberFavorites(tracks);updateList();
            if(tracks.toString().length()<750000)getSharedPreferences("playlist-snapshots",MODE_PRIVATE)
                .edit().putString(playlistSnapshotKey(id),tracks.toString()).apply();
        });
    }
    void nightwellOptions(String title,String[] options,java.util.function.IntConsumer selected){
        LinearLayout panel=column();panel.setPadding(dp(18),dp(14),dp(18),dp(16));
        TextView heading=text(title,21);heading.setTextColor(0xffeeeeee);heading.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);heading.setPadding(dp(8),dp(4),dp(8),dp(16));panel.addView(heading);
        AlertDialog dialog=new AlertDialog.Builder(this).setView(panel).create();
        for(int index=0;index<options.length;index++){
            final int choice=index;
            TextView entry=sheetAction(options[index],()->{dialog.dismiss();selected.accept(choice);});
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,dp(54));lp.setMargins(0,dp(4),0,dp(4));panel.addView(entry,lp);
        }
        styleSheet(dialog);dialog.show();
    }
    void collectionMenu(String kind,String id){
        String[] options=kind.equals("playlist")?new String[]{"Скачать всё","Поделиться","Удалить"}:new String[]{"Скачать всё","Поделиться"};
        nightwellOptions("Действия",options,n->{
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
    void download(JSONArray items){
        if(items==null)return;
        if(user.isEmpty()){auth();return;}
        JSONArray allowed=new JSONArray();int blocked=0;
        for(int i=0;i<items.length();i++){
            JSONObject t=items.optJSONObject(i);
            if(t==null)continue;
            if("audius".equalsIgnoreCase(t.optString("source"))||t.optString("id").startsWith("audius_"))blocked++;
            else allowed.put(t);
        }
        if(allowed.length()==0){
            status.setText("Треки Audius пока нельзя скачать: сервер запрещает офлайн-экспорт.");
            return;
        }
        if(blocked>0)status.setText("Часть треков Audius недоступна офлайн. Загружаем остальные…");
        else status.setText("Добавляем в фоновую очередь…");
        String account=user;
        task(()->{
            if(!api.request("api/premium/me").optBoolean("premium"))
                throw new java.io.IOException("Скачивание доступно с Premium — 150 ₽ за 30 дней.");
            BackgroundDownloads.enqueue(this,origin,account,allowed);
            return new JSONObject();
        },v->status.setText(BackgroundDownloads.progress(this)));
    }
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


    private void updateArtworkAppearance() {
        if(ambient==null)return;
        android.content.SharedPreferences appearance=getSharedPreferences("appearance",MODE_PRIVATE);
        boolean home=!full&&"Главная".equals(screen);
        boolean enabled=full
            ?appearance.getBoolean("player-artwork-background",true)
            :home&&appearance.getBoolean("home-artwork-background",true);
        boolean gradient=appearance.getBoolean("artwork-gradient-enabled",true);
        ambient.setVisibility(enabled&&gradient?View.VISIBLE:View.GONE);
        int strengthIndex=appearance.getInt("artwork-reactive-strength",1);
        int speedIndex=appearance.getInt("artwork-motion-speed",0);
        float reaction=new float[]{.05f,.11f,.19f}[Math.max(0,Math.min(2,strengthIndex))];
        float speed=new float[]{.55f,1f,1.45f}[Math.max(0,Math.min(2,speedIndex))];
        boolean premium=premiumAllowed();
        if(premium){
            reaction*=Math.max(.5f,Math.min(1.5f,(float)premiumPrefs.optDouble("ribbon_intensity",1)));
            speed*=Math.max(.5f,Math.min(1.5f,(float)premiumPrefs.optDouble("ribbon_speed",1)));
        }
        float transitionSpeed=premium?
            getSharedPreferences("aura-color-speed",MODE_PRIVATE).getFloat(user,1):1f;
        String theme=premium?premiumPrefs.optString("theme","nightwell"):"nightwell";
        ambient.configure(enabled&&gradient,appearance.getBoolean("artwork-reactive",true),
            reaction,speed,transitionSpeed,theme);
        updateArtworkReaction();
    }

    private void updateArtworkReaction() {
        if(ambient==null||ambient.getVisibility()!=View.VISIBLE||playback==null){
            if(ambient!=null)ambient.setAudioLevel(0);
            return;
        }
        if(!playback.player.isPlaying()){ambient.setAudioLevel(0);return;}
        android.content.SharedPreferences prefs=getSharedPreferences("aura-response",MODE_PRIVATE);
        String[] bands={"aura_voice","aura_low","aura_mid","aura_high"};
        double total=0;
        int count=0;
        for(int i=0;i<bands.length;i++)if(prefs.getBoolean(user+"|"+bands[i],true)){
            double value=playback.bandLevel(i);
            if(Double.isFinite(value))total+=Math.max(0,Math.min(1,value));
            count++;
        }
        double sample=count==0?0:Math.max(0,Math.min(1,total/count));
        if(count>0)sample=Math.max(sample,Math.min(1,Math.max(0,playback.level()))*.6);
        ambient.setAudioLevel(sample);
    }

    private void addArtworkToggle(LinearLayout panel,String label,String key,boolean defaultValue){
        android.widget.Switch toggle=new android.widget.Switch(this);
        toggle.setText(label);styleSwitch(toggle);
        android.content.SharedPreferences prefs=getSharedPreferences("appearance",MODE_PRIVATE);
        toggle.setChecked(prefs.getBoolean(key,defaultValue));
        toggle.setOnCheckedChangeListener((button,value)->{
            prefs.edit().putBoolean(key,value).apply();
            if("handoff-auto-collapse".equals(key)){
                ui.removeCallbacks(handoffAutoCollapse);
                if(value)scheduleHandoffCollapse();
            }else if("ambient-lyrics".equals(key)){
                if(!value&&homeLyric!=null)homeLyric.setText("");
                else if(playback!=null)syncHomeLyrics(playback.player.getCurrentPosition()/1000d);
            }else updateArtworkAppearance();
        });
        panel.addView(toggle);
    }

    private void addArtworkChoice(LinearLayout panel,String label,String[] options,
                                  String key,int fallback){
        boolean shuffle="shuffle-mode".equals(key);
        android.content.SharedPreferences prefs=getSharedPreferences(
            shuffle?"playback":"appearance",MODE_PRIVATE);
        String preferenceKey=shuffle?"nw-shuffle-mode":key;
        int fallbackValue="cover-style".equals(key)&&prefs.getBoolean("cover-classic",false)?1:fallback;
        int selected=Math.max(0,Math.min(options.length-1,prefs.getInt(preferenceKey,fallbackValue)));
        TextView choice=sheetAction(label+" · "+options[selected],()->{});
        choice.setOnClickListener(v->nightwellOptions(label,options,n->{
            prefs.edit().putInt(preferenceKey,n).apply();
            choice.setText(label+" · "+options[n]);
            if(shuffle)applyShuffleMode(n);
            else if("cover-style".equals(key)){
                prefs.edit().putBoolean("cover-classic",n==1).apply();
                if(miniCover!=null){
                    GradientDrawable shape=new GradientDrawable();
                    shape.setColor(0x443e2d52);shape.setCornerRadius(dp(n==1?16:9));
                    miniCover.setBackground(shape);
                }
            }else updateArtworkAppearance();
        }));
        panel.addView(choice);
    }

    private int shuffleMode(){
        android.content.SharedPreferences prefs=getSharedPreferences("playback",MODE_PRIVATE);
        if(prefs.contains("nw-shuffle-mode"))
            return Math.max(0,Math.min(2,prefs.getInt("nw-shuffle-mode",0)));
        return playback!=null&&playback.player.getShuffleModeEnabled()?1:0;
    }

    private void applyShuffleMode(int mode) {
        if(playback!=null){
            playback.modes(playback.player.getRepeatMode(),mode==1);
            if(mode==2)prepareSmartNext();
        }
        refreshShuffleButton();
    }

    private void cycleShuffleMode(){
        int next=(shuffleMode()+1)%3;
        getSharedPreferences("playback",MODE_PRIVATE).edit().putInt("nw-shuffle-mode",next).apply();
        applyShuffleMode(next);
    }

    private void refreshShuffleButton(){
        if(fullShuffle==null)return;
        int mode=shuffleMode();
        fullShuffle.setText(mode==2?"✦":"⇄");
        fullShuffle.setTextColor(mode==0?0xffa4a6b1:0xffeeeeee);
        fullShuffle.setContentDescription(
            mode==0?"Перемешивание выключено. Включить обычное":
            mode==1?"Обычное перемешивание. Включить умное":
            "Умное перемешивание. Выключить");
    }

    private void prepareSmartNext(){
        if(shuffleMode()!=2||playback==null||queue==null||queue.length()<3)return;
        androidx.media3.exoplayer.ExoPlayer player=playback.player;
        if(player.getShuffleModeEnabled())player.setShuffleModeEnabled(false);
        int index=player.getCurrentMediaItemIndex();
        if(index<0||index+1>=player.getMediaItemCount())return;
        JSONObject current=current();
        String artist=current==null?"":RecommendationOrder.key(current.optString("artist"));
        int best=index+1;
        double bestScore=-999;
        Set<String> seen=new HashSet<>();
        for(int i=index+1;i<Math.min(player.getMediaItemCount(),index+24);i++){
            String id=player.getMediaItemAt(i).mediaId;
            if(!seen.add(id))continue;
            JSONObject track=null;
            for(int j=0;j<queue.length();j++){
                JSONObject item=queue.optJSONObject(j);
                if(item!=null&&id.equals(item.optString("id"))){track=item;break;}
            }
            if(track==null)continue;
            String candidateArtist=RecommendationOrder.key(track.optString("artist"));
            double score=1.0+Math.random()*.45;
            if(!candidateArtist.isEmpty()&&candidateArtist.equals(artist))score-=2;
            if(id.equals(currentID))score-=4;
            if(score>bestScore){bestScore=score;best=i;}
        }
        if(best!=index+1)player.moveMediaItem(best,index+1);
    }

    void styleSeekBar(SeekBar seek){
        seek.setProgressTintList(android.content.res.ColorStateList.valueOf(NightwellDesign.PRIMARY));
        seek.setThumbTintList(android.content.res.ColorStateList.valueOf(NightwellDesign.PRIMARY));
        seek.setProgressBackgroundTintList(android.content.res.ColorStateList.valueOf(NightwellDesign.BORDER));
        seek.setPadding(dp(4),dp(6),dp(4),dp(6));
        seek.setMinimumHeight(dp(44));
    }

    void settings(){
        LinearLayout panel=column();
        panel.setPadding(dp(16),dp(12),dp(16),dp(16));
        android.widget.ScrollView scroll=new android.widget.ScrollView(this);
        scroll.setFillViewport(false);
        scroll.addView(panel);
        TextView subtitle=text("Оформи приложение под себя и настрой поведение плеера.",14);
        subtitle.setTextColor(NightwellDesign.MUTED);
        subtitle.setPadding(0,0,0,dp(12));panel.addView(subtitle);
        panel.addView(sectionLabel("Оформление"));
        LinearLayout appearanceGroup=column();
        appearanceGroup.setBackground(NightwellDesign.surface(this,NightwellDesign.SURFACE,20,true));
        appearanceGroup.setPadding(dp(14),dp(11),dp(14),dp(13));
        panel.addView(appearanceGroup);
        appearanceGroup.addView(sheetAction("Темы и движение фона · Premium",()->feature("appearance")));
        appearanceGroup.addView(sheetAction("Эквалайзер · Premium",()->feature("sound")));
        addArtworkToggle(appearanceGroup,"Цветной фон на главной","home-artwork-background",true);
        addArtworkToggle(appearanceGroup,"Фон плеера под цвета обложки","player-artwork-background",true);
        addArtworkToggle(appearanceGroup,"Фоновый градиент","artwork-gradient-enabled",true);
        addArtworkToggle(appearanceGroup,"Лёгкая реакция фона на музыку","artwork-reactive",true);
        addArtworkToggle(appearanceGroup,"Текст песни на главной","ambient-lyrics",true);
        addArtworkChoice(appearanceGroup,"Сила реакции фона",new String[]{"Очень слабая","Мягкая","Заметная"},"artwork-reactive-strength",1);
        addArtworkChoice(appearanceGroup,"Скорость движения цвета",new String[]{"Медленно","Обычно","Побыстрее"},"artwork-motion-speed",0);
        addArtworkChoice(appearanceGroup,"Стиль обложек",new String[]{"На всю ширину","Классический, с округлением"},"cover-style",0);
        addArtworkToggle(appearanceGroup,"Автосворачивание продолжения","handoff-auto-collapse",true);
        panel.addView(sectionLabel("Воспроизведение"));
        LinearLayout playbackGroup=column();
        playbackGroup.setBackground(NightwellDesign.surface(this,NightwellDesign.SURFACE,20,true));
        playbackGroup.setPadding(dp(14),dp(12),dp(14),dp(14));
        panel.addView(playbackGroup);
        playbackGroup.addView(sheetAction("Качество звука",this::qualityPlayerMenu));
        playbackGroup.addView(sheetAction("Настройка подборки",this::waveSettings));
        addArtworkChoice(playbackGroup,"Перемешивание",new String[]{"Выключено","Обычное","Умное"},"shuffle-mode",shuffleMode());

        android.widget.Switch autoFavorites=new android.widget.Switch(this);
        autoFavorites.setText("Автоматически скачивать избранное · Premium");
        styleSwitch(autoFavorites);
        autoFavorites.setChecked(autoFavoritesEnabled());
        autoFavorites.setEnabled(!user.isEmpty());
        autoFavorites.setOnCheckedChangeListener((b,enabled)->setAutoFavoritesEnabled(enabled));
        playbackGroup.addView(autoFavorites);
        float savedFade=getSharedPreferences("playback",MODE_PRIVATE).getFloat("nw-transition-seconds",1.5f);TextView label=text(String.format(Locale.ROOT,"Переход между треками · %.1f с",savedFade),15);
        label.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
        playbackGroup.addView(label);
        SeekBar duration=new SeekBar(this);styleSeekBar(duration);duration.setMax(50);
        duration.setProgress((int)(getSharedPreferences("playback",MODE_PRIVATE).getFloat("nw-transition-seconds",1.5f)*10));
        duration.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar b,int p,boolean fromUser){
                label.setText("Переход между треками · "+p/10.0+" с");
                if(fromUser&&playback!=null)playback.transitionDuration(p/10.0);
            }
            public void onStartTrackingTouch(SeekBar b){}
            public void onStopTrackingTouch(SeekBar b){}
        });
        playbackGroup.addView(duration);
        final int[] values={0,4,8,12};
        int selected=getSharedPreferences("playback",MODE_PRIVATE).getInt("nw-stream-buffer-seconds",0);
        int selectedIndex=0;
        for(int i=0;i<values.length;i++)if(values[i]==selected)selectedIndex=i;
        TextView bufferLabel=text("Буфер потока · "+(selected==0?"Быстрый (1 с)":selected+" с"),15);
        bufferLabel.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
        playbackGroup.addView(bufferLabel);
        SeekBar buffer=new SeekBar(this);styleSeekBar(buffer);buffer.setMax(values.length-1);buffer.setProgress(selectedIndex);
        buffer.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar bar,int progress,boolean fromUser){
                int seconds=values[Math.min(values.length-1,Math.max(0,progress))];
                bufferLabel.setText("Буфер потока · "+(seconds==0?"Быстрый (1 с)":seconds+" с"));
                if(fromUser)getSharedPreferences("playback",MODE_PRIVATE).edit().putInt("nw-stream-buffer-seconds",seconds).apply();
            }
            public void onStartTrackingTouch(SeekBar bar){}
            public void onStopTrackingTouch(SeekBar bar){}
        });
        playbackGroup.addView(buffer);
        TextView equalLabel=text("Одинаковая громкость · Выкл.",15);
        equalLabel.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
        playbackGroup.addView(equalLabel);
        SeekBar equalVolume=new SeekBar(this);styleSeekBar(equalVolume);equalVolume.setMax(10);
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
        playbackGroup.addView(equalVolume);
        TextView loudnessHint=text("Выравнивает громкие записи по измеренному звуку без дополнительных сетевых запросов.",12);
        loudnessHint.setTextColor(NightwellDesign.MUTED);playbackGroup.addView(loudnessHint);
        TextView hint=text("Быстрый режим уменьшает ожидание звука, 8–12 с помогают при нестабильной сети. Изменение применяется после полного перезапуска Nightwell Music.",12);
        hint.setTextColor(NightwellDesign.MUTED);hint.setPadding(0,0,0,dp(12));playbackGroup.addView(hint);
        TextView metrics=text("Диагностика: "+(playback==null?"Плеер запускается":playback.playbackDiagnostics()),12);
        metrics.setTextColor(NightwellDesign.MUTED);playbackGroup.addView(metrics);
        // Lyrics control lives in the appearance section.
        TextView version=text("Nightwell Music "+BuildConfig.VERSION_NAME+" ("+BuildConfig.VERSION_CODE+")",12);
        version.setTextColor(NightwellDesign.MUTED);version.setPadding(0,dp(12),0,0);panel.addView(version);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Настройки Nightwell Music").setView(scroll).setPositiveButton("Готово",null).create();
        Runnable diagnosticsTick=new Runnable(){
            public void run(){
                if(!dialog.isShowing())return;
                metrics.setText("Диагностика: "+(playback==null?"Нет данных":playback.playbackDiagnostics()));
                ui.postDelayed(this,1000);
            }
        };
        dialog.setOnDismissListener(d->ui.removeCallbacks(diagnosticsTick));
        styleSheet(dialog);dialog.show();ui.post(diagnosticsTick);
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
        if(root!=null)root.setBackgroundColor(Color.TRANSPARENT);updateArtworkAppearance();
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
        LinearLayout card=column();card.setPadding(dp(16),dp(14),dp(16),dp(14));card.setBackground(NightwellDesign.surface(this,NightwellDesign.RAISED,18,true));
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(9);parent.addView(card,lp);
        if(!title.isEmpty()){TextView label=text(title,17);NightwellDesign.headline(label);label.setPadding(0,0,0,dp(10));card.addView(label);}return card;
    }
    TextView premiumAction(String label,Runnable action){TextView button=sheetAction(label,action);button.setMinHeight(dp(48));button.setPadding(dp(14),dp(10),dp(14),dp(10));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=dp(8);button.setLayoutParams(lp);if(label.startsWith("Сохранить")||label.equals("Проверить оплату")){button.setGravity(Gravity.CENTER);button.setTypeface(null,android.graphics.Typeface.BOLD);button.setTextColor(0xff191a20);button.setBackground(touchSurface(0xffeeeeee,24));}return button;}
    EditText premiumInput(String hint,int limit){EditText input=new EditText(this);input.setHint(hint);input.setSingleLine(true);input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(limit)});styleField(input);return input;}
    Dialog premiumSheet(String title,LinearLayout panel,boolean compact,Runnable extra){
        Dialog dialog=new Dialog(this);LinearLayout shell=column();shell.setPadding(dp(16),dp(9),dp(16),dp(14));GradientDrawable sheet=NightwellDesign.surface(this,NightwellDesign.SURFACE,24,true);shell.setBackground(sheet);
        View handle=new View(this);GradientDrawable bar=new GradientDrawable();bar.setColor(0xff565a60);bar.setCornerRadius(dp(4));handle.setBackground(bar);LinearLayout.LayoutParams hp=new LinearLayout.LayoutParams(dp(36),dp(4));hp.gravity=Gravity.CENTER_HORIZONTAL;hp.bottomMargin=dp(8);shell.addView(handle,hp);
        LinearLayout header=row();TextView heading=text(title,21);NightwellDesign.headline(heading);header.addView(heading,new LinearLayout.LayoutParams(0,-2,1));
        if(extra!=null){TextView more=iconButton("⋯",extra);more.setContentDescription("Дополнительные настройки эквалайзера");header.addView(more,new LinearLayout.LayoutParams(dp(48),dp(48)));}
        TextView close=iconButton("×",dialog::dismiss);close.setContentDescription("Готово");header.addView(close,new LinearLayout.LayoutParams(dp(48),dp(48)));shell.addView(header);
        panel.setPadding(dp(2),dp(8),dp(2),dp(2));ScrollView scroll=new ScrollView(this);scroll.setFillViewport(false);scroll.setClipToPadding(false);scroll.addView(panel);shell.addView(scroll,new LinearLayout.LayoutParams(-1,-2));
        dialog.setContentView(shell);Window w=dialog.getWindow();if(w!=null){w.setBackgroundDrawableResource(android.R.color.transparent);w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);w.setDimAmount(.78f);w.setGravity(Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);}
        shell.getViewTreeObserver().addOnGlobalLayoutListener(()->{int max=(int)(getResources().getDisplayMetrics().heightPixels*.82)-header.getHeight()-dp(55);if(panel.getHeight()>max&&scroll.getLayoutParams().height!=max){scroll.getLayoutParams().height=max;scroll.requestLayout();}else if(panel.getHeight()<max&&scroll.getLayoutParams().height!=-2){scroll.getLayoutParams().height=-2;scroll.requestLayout();}});
        dialog.setOnShowListener(d->{Window win=dialog.getWindow();if(win==null)return;int width=Math.min(dp(520),getResources().getDisplayMetrics().widthPixels-dp(24));win.setLayout(width,-2);WindowManager.LayoutParams attrs=win.getAttributes();attrs.y=dp(6);win.setAttributes(attrs);shell.post(()->{int limit=(int)(getResources().getDisplayMetrics().heightPixels*.88);if(shell.getHeight()>limit)scroll.getLayoutParams().height=Math.max(dp(120),limit-header.getHeight()-dp(55));scroll.requestLayout();});shell.setAlpha(0);shell.setScaleX(.94f);shell.setScaleY(.94f);shell.setTranslationY(dp(22));shell.animate().alpha(1).scaleX(1).scaleY(1).translationY(0).setDuration(245).setInterpolator(new android.view.animation.DecelerateInterpolator()).start();});
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
        LinearLayout panel=column(),card=premiumCard(panel,"Ваше оформление");TextView note=text("Цвета обложки и мягкая реакция фонового градиента",14);note.setTextColor(0xffa4a6b1);note.setPadding(0,0,0,dp(12));card.addView(note);
        String[][] options={{"Цвета обложки","Северное сияние","Океан","Закат"},{"Медленно","Обычно","Быстро"},{"Мягко","Обычно","Ярко"},{"Медленно","Обычно","Быстро"}};String[] keys={"theme","ribbon_speed","ribbon_intensity","aura_color_speed"},titles={"Оттенок фона","Скорость движения","Выразительность","Смена цветов"},themes={"nightwell","aurora","ocean","sunset"};
        for(int i=0;i<4;i++){final int key=i;int selected=i==0?Math.max(0,Arrays.asList(themes).indexOf(premiumPrefs.optString("theme"))):(i==3?getSharedPreferences("aura-color-speed",MODE_PRIVATE).getFloat(user,1):premiumPrefs.optDouble(keys[i],1))==.5?0:(i==3?getSharedPreferences("aura-color-speed",MODE_PRIVATE).getFloat(user,1):premiumPrefs.optDouble(keys[i],1))==1?1:2;
            TextView choice=premiumAction(titles[i]+" · "+options[i][selected]+"  ▾",()->{});choice.setOnClickListener(v->nightwellOptions(titles[key],options[key],n->{try{premiumPrefs.put(keys[key],key==0?themes[n]:new double[]{.5,1,1.5}[n]);if(key==3)getSharedPreferences("aura-color-speed",MODE_PRIVATE).edit().putFloat(user,(float)new double[]{.5,1,1.5}[n]).apply();choice.setText(titles[key]+" · "+options[key][n]+"  ▾");applyPremium();}catch(Exception ignored){}}));card.addView(choice);
        }
        card.addView(sectionLabel("Реакция фона на музыку"));
        TextView explanation=text("Выбери частоты, на которые мягко реагирует фон. Можно включить несколько сразу.",13);
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
                updateArtworkReaction();
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
    android.view.GestureDetector gestures(boolean expanded){return new android.view.GestureDetector(this,new android.view.GestureDetector.SimpleOnGestureListener(){public boolean onDown(android.view.MotionEvent e){return true;}public boolean onSingleTapUp(android.view.MotionEvent e){if(expanded){JSONObject track=current();if(track!=null)showLyrics(track);}else openPlayer();return true;}public boolean onFling(android.view.MotionEvent start,android.view.MotionEvent end,float vx,float vy){if(start==null||end==null)return false;float dx=end.getX()-start.getX(),dy=end.getY()-start.getY();if(Math.abs(dx)>dp(65)&&Math.abs(dx)>Math.abs(dy)*1.25f){if(playback==null)return false;if(dx<0)nextTrack();else previous();return true;}if(expanded&&dy>dp(90)&&dy>Math.abs(dx)*1.35f){full=false;build();return true;}return false;}});}
    @Override public void onBackPressed(){if(backgroundOnly){backgroundOnly=false;build();}else if(full){full=false;build();}else if(!screen.equals("Главная"))navigate("Главная");else super.onBackPressed();}
    void importFiles(){Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("audio/*").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);startActivityForResult(i,72);}
    void handleAudioImportResult(int request,int result,Intent data){if(request!=72||result!=RESULT_OK||data==null)return;ArrayList<Uri> uris=new ArrayList<>();if(data.getClipData()!=null)for(int i=0;i<data.getClipData().getItemCount();i++)uris.add(data.getClipData().getItemAt(i).getUri());else if(data.getData()!=null)uris.add(data.getData());io.execute(()->{for(Uri uri:uris)try{OfflineStore.importFile(this,origin,uri);}catch(Exception ex){ui.post(()->status.setText("Не удалось импортировать файл"));}ui.post(()->navigate("Офлайн"));});}
    final class TrackAdapter extends BaseAdapter {
        final class Holder {
            final android.widget.ImageView cover;
            final TextView title,artist,more;
            final PlayingIndicator indicator;
            Holder(android.widget.ImageView cover,TextView title,TextView artist,
                   TextView more,PlayingIndicator indicator){
                this.cover=cover;this.title=title;this.artist=artist;
                this.more=more;this.indicator=indicator;
            }
        }

        @Override public int getCount(){return shown==null?0:shown.length();}
        @Override public Object getItem(int p){return shown==null?null:shown.optJSONObject(p);}
        @Override public long getItemId(int p){return p;}

        @Override public View getView(int position,View recycled,ViewGroup parent){
            LinearLayout row;
            Holder holder;
            if(!(recycled instanceof LinearLayout)||!(recycled.getTag() instanceof Holder)){
                row=row();
                row.setGravity(Gravity.CENTER_VERTICAL);
                row.setPadding(dp(10),dp(9),dp(7),dp(9));
                row.setMinimumHeight(dp(70));
                android.widget.ImageView cover=new android.widget.ImageView(MainActivity.this);
                cover.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
                GradientDrawable shape=NightwellDesign.surface(MainActivity.this,
                    NightwellDesign.RAISED,12,false);
                cover.setBackground(shape);
                cover.setClipToOutline(true);
                LinearLayout.LayoutParams coverParams=
                    new LinearLayout.LayoutParams(dp(50),dp(50));
                coverParams.rightMargin=dp(12);
                row.addView(cover,coverParams);
                LinearLayout labels=column();
                labels.setGravity(Gravity.CENTER_VERTICAL);
                TextView title=text("",15);
                NightwellDesign.headline(title);
                title.setMaxLines(1);title.setEllipsize(android.text.TextUtils.TruncateAt.END);
                labels.addView(title);
                TextView artist=text("",12);
                NightwellDesign.detail(artist);
                artist.setSingleLine(true);
                artist.setEllipsize(android.text.TextUtils.TruncateAt.END);
                artist.setPadding(0,dp(5),0,0);
                labels.addView(artist);
                row.addView(labels,new LinearLayout.LayoutParams(0,-2,1));
                PlayingIndicator indicator=new PlayingIndicator(MainActivity.this);
                row.addView(indicator,new LinearLayout.LayoutParams(dp(22),dp(22)));
                TextView more=iconButton("⋯",()->{});
                more.setBackgroundColor(Color.TRANSPARENT);
                LinearLayout.LayoutParams actionParams=
                    new LinearLayout.LayoutParams(dp(40),dp(46));
                actionParams.leftMargin=dp(4);
                row.addView(more,actionParams);
                holder=new Holder(cover,title,artist,more,indicator);
                row.setTag(holder);
            }else{
                row=(LinearLayout)recycled;
                holder=(Holder)row.getTag();
            }

            JSONObject track=shown.optJSONObject(position);
            if(track==null){
                holder.title.setText("");
                holder.artist.setText("");
                holder.cover.setImageDrawable(null);
                holder.indicator.setVisibility(View.GONE);
                return row;
            }
            holder.title.setText(track.optString("title","Без названия"));
            holder.artist.setText(track.optString("artist","Неизвестный исполнитель"));
            boolean active=currentID.equals(track.optString("id"));
            holder.indicator.setVisibility(active?View.VISIBLE:View.GONE);
            holder.indicator.playing(lastPlaying);
            holder.artist.setOnClickListener(v->chooseArtist(track.optString("artist")));
            holder.artist.setContentDescription(
                ArtistAttribution.isKnown(track.optString("artist"))?
                    "Открыть исполнителя":"Исполнитель не указан");
            holder.more.setOnClickListener(v->trackMenu(track));
            row.setBackground(NightwellDesign.ripple(MainActivity.this,
                active?NightwellDesign.SELECTED:NightwellDesign.SURFACE,18,true));
            if(artworkCache!=null)artworkCache.load(holder.cover,origin,track.optString("cover_url"));
            row.setContentDescription(track.optString("title")+", "+track.optString("artist"));
            return row;
        }
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
        ArrayList<JSONObject> result=new ArrayList<>();
        for(int i=0;i<items.length();i++){JSONObject item=items.optJSONObject(i);if(item!=null)result.add(item);}
        if(!premiumAllowed()||favoriteOrder.equals("recent")){
            HashMap<String,Integer> rank=new HashMap<>();
            for(int i=0;i<likeOrder.size();i++)rank.putIfAbsent(likeOrder.get(i),i);
            result.sort((a,b)->Integer.compare(rank.getOrDefault(a.optString("id"),Integer.MAX_VALUE),
                rank.getOrDefault(b.optString("id"),Integer.MAX_VALUE)));
        }else{
            String column=favoriteOrder.equals("title")?"title":"artist";
            result.sort((a,b)->java.text.Collator.getInstance(new java.util.Locale("ru"))
                .compare(a.optString(column),b.optString(column)));
        }
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
        transferKey="";transferStage="";transferBusy=false;
        LinearLayout panel=column();panel.setPadding(dp(16),dp(10),dp(16),dp(8));
        EditText title=new EditText(this);title.setSingleLine(true);title.setText("Перенос музыки");title.setHint("Название плейлиста");title.setFilters(new InputFilter[]{new InputFilter.LengthFilter(80)});styleField(title);panel.addView(title);transferTitle=title;
        Spinner modes=new Spinner(this);String[] modeNames={"Точный","Умный","Максимальный"};modes.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,modeNames));modes.setSelection(2);panel.addView(modes);transferMode=modes;
        TextView info=text("JSON, CSV или TXT до 1 МБ. Разбор списка и удаление дублей выполняются на устройстве.",12);info.setPadding(0,dp(8),0,dp(8));panel.addView(info);panel.addView(sheetAction("Выбрать файл",this::choosePlaylistDocument));
        EditText input=new EditText(this);input.setMinLines(3);input.setMaxLines(5);input.setGravity(Gravity.TOP);input.setHint("Список треков");styleField(input);input.setSaveEnabled(false);panel.addView(input);transferInput=input;
        TextView result=text("После поиска нажми «Добавить», чтобы создать плейлист.",13);panel.addView(result);transferNote=result;
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
            transferRequest(()->{JSONArray prepared=TransferPreparation.parse(raw);return client.request("api/imports","POST",new JSONObject().put("provider","yandex").put("name",name).put("text",prepared.toString()).put("url","").put("mode",mode));},response->{
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
