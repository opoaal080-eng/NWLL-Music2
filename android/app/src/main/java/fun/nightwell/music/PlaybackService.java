package fun.nightwell.music;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.Player;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.ResolvingDataSource;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.SimpleCache;
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.hls.HlsMediaSource;
import androidx.media3.exoplayer.hls.HlsDataSourceFactory;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.ArrayDeque;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.net.URLEncoder;
import android.os.Handler;
import android.os.Looper;
import android.net.Uri;
import android.os.Bundle;
import androidx.media3.common.MimeTypes;

@androidx.annotation.OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
public final class PlaybackService extends MediaSessionService {
    private final Binder binder = new LocalBinder();
    ExoPlayer player;
    final PremiumEqualizer premiumEqualizer = new PremiumEqualizer();
    private final LocalAudioMeter audioMeter = new LocalAudioMeter();
    private MediaSession session;
    private SimpleCache audioCache;
    private DefaultMediaSourceFactory fileSources;
    private HlsMediaSource.Factory hlsSources;
    private CacheDataSource.Factory cachedSources;
    private final ExecutorService audioPrefetchIO = Executors.newSingleThreadExecutor();
    private volatile int audioPrefetchGeneration = 0;
    private int bufferChoiceSeconds = 0; // 0 means the existing fast 1-second initial buffer
    private long startupAt = 0, readyAfterMs = -1, audibleAfterMs = -1;
    private int bufferingStalls = 0;
    private String measuredTrack = "";
    private String positionTrack = "";
    private long lastGoodPositionMs = 0, pausedPositionMs = -1;
    String playbackDiagnostics() {
        String prepared = readyAfterMs < 0 ? "…" : String.format(java.util.Locale.ROOT, "%.2f с", readyAfterMs / 1000.0);
        String sounded = audibleAfterMs < 0 ? "…" : String.format(java.util.Locale.ROOT, "%.2f с", audibleAfterMs / 1000.0);
        return "Подготовка: " + prepared + " · Звук: " + sounded + " · Остановки: " + bufferingStalls;
    }
    private void beginTrackTiming(MediaItem track) {
        String id = track == null ? "" : track.mediaId;
        measuredTrack = id;
        startupAt = android.os.SystemClock.elapsedRealtime();
        readyAfterMs = -1; audibleAfterMs = -1; bufferingStalls = 0;
        positionTrack = id; lastGoodPositionMs = 0; pausedPositionMs = -1;
        audioPrefetchGeneration++;
    }
    private void capturePausePosition() {
        MediaItem track = player.getCurrentMediaItem();
        if (track == null) { pausedPositionMs = -1; return; }
        if (!track.mediaId.equals(positionTrack)) {
            positionTrack = track.mediaId; lastGoodPositionMs = 0;
        }
        long current = Math.max(0, player.getCurrentPosition());
        if (current > 0 || lastGoodPositionMs == 0) lastGoodPositionMs = current;
        pausedPositionMs = lastGoodPositionMs;
    }
    // Prefetch a small cacheable FILE prefix only. Signed HLS playlists remain fresh.
    // Never compete with the current track until it has an adequate buffer.
    private void scheduleNextFilePrefetch() {
        final int generation = ++audioPrefetchGeneration;
        waveHandler.postDelayed(() -> {
            if (generation != audioPrefetchGeneration || !player.isPlaying()
                    || player.getTotalBufferedDuration() < 8000 || cachedSources == null) return;
            int next = player.getNextMediaItemIndex();
            if (next == C.INDEX_UNSET) return;
            MediaItem item = player.getMediaItemAt(next);
            if (item.localConfiguration == null || MimeTypes.APPLICATION_M3U8.equals(item.localConfiguration.mimeType)) return;
            Uri uri = item.localConfiguration.uri;
            if (!"https".equals(uri.getScheme()) || !ServerAddress.sameOrigin(origin, uri.toString())
                    || uri.getPath() == null || !uri.getPath().startsWith("/api/stream/")) return;
            audioPrefetchIO.execute(() -> {
                if (generation != audioPrefetchGeneration) return;
                DataSource reader = cachedSources.createDataSource();
                try {
                    reader.open(new DataSpec.Builder().setUri(uri).setLength(65536).build());
                    byte[] bytes = new byte[8192];
                    int remaining = 65536, n;
                    while (remaining > 0 && generation == audioPrefetchGeneration
                            && (n = reader.read(bytes, 0, Math.min(bytes.length, remaining))) != C.RESULT_END_OF_INPUT) {
                        if (n <= 0) break;
                        remaining -= n;
                    }
                } catch (Exception ignored) {
                    // Prefetch must never prevent normal playback.
                } finally { try { reader.close(); } catch (Exception ignored) {} }
            });
        }, 3000);
    }
    private float baseVolume=1f;
    private boolean fadeInActive=false;
    private double transitionSeconds=.8;
    private volatile String cacheScope="guest";
    private String offlineAccount="";
    private volatile String origin = "";
    private String error = "";
    private String retriedTrackId = "";
    private int streamRetryCount = 0;
    private Runnable pendingStreamRetry;
    private boolean waveActive, waveLoading;
    private WaveSettings waveSettings=new WaveSettings(new JSONObject());
    private int waveGeneration;
    private final LatestRequest waveRequest = new LatestRequest();
    private long waveRetryAt;
    private final ArrayDeque<String> waveSeen = new ArrayDeque<>();
    private final ExecutorService waveIO = Executors.newSingleThreadExecutor();
    private final com.google.common.util.concurrent.ListeningExecutorService artworkIO = com.google.common.util.concurrent.MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor());
    private final Handler waveHandler = new Handler(Looper.getMainLooper());
    private final Runnable waveTick = new Runnable() { public void run() {
        tickListening();persistPlayback(false);refillWave();waveHandler.postDelayed(this,5000);
    }};
    private final Runnable fadeTick = new Runnable() { public void run() {
        if(player==null || !player.isPlaying())return;
        updateFade();
        long remaining=player.getDuration()-player.getCurrentPosition();
        boolean nearTransition=fadeInActive || (transitionSeconds>0 &&
                player.getDuration()>0 && player.getDuration()!=C.TIME_UNSET &&
                remaining<=Math.max(1500,(long)(transitionSeconds*1000)+500));
        // Avoid 25 volume updates a second while playing the middle of a song.
        waveHandler.postDelayed(this,nearTransition?50:500);
    }};
    private void updateFade() {
        if(player==null)return;
        if(transitionSeconds<=0){fadeInActive=false;player.setVolume(baseVolume);return;}
        long duration=player.getDuration(),position=Math.max(0,player.getCurrentPosition());
        boolean known=duration>200 && duration!=C.TIME_UNSET;
        double span=known?Math.min(transitionSeconds*1000,duration/4.0):transitionSeconds*1000;
        if(fadeInActive && position>=span)fadeInActive=false;
        boolean next=waveActive || player.hasNextMediaItem() || player.getRepeatMode()!=Player.REPEAT_MODE_OFF;
        double entry=fadeInActive?Math.max(0,Math.min(1,position/span)):1;
        double exit=known&&next?Math.max(0,Math.min(1,(duration-position)/span)):1;
        player.setVolume(baseVolume*(float)Math.min(entry,exit));
    }
    public final class LocalBinder extends Binder { PlaybackService getService() { return PlaybackService.this; } }

    @Override public void onCreate() {
        super.onCreate();
        transitionSeconds=getSharedPreferences("playback",MODE_PRIVATE).getFloat("nw-transition-seconds",.8f);
        bufferChoiceSeconds=getSharedPreferences("playback",MODE_PRIVATE).getInt("nw-stream-buffer-seconds",0);
        if(bufferChoiceSeconds!=0 && bufferChoiceSeconds!=4 && bufferChoiceSeconds!=8 && bufferChoiceSeconds!=12) bufferChoiceSeconds=0;
        DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory().setUserAgent("NightwellMusic/0.5").setConnectTimeoutMs(10000).setReadTimeoutMs(20000);
        ResolvingDataSource.Factory source = new ResolvingDataSource.Factory(http, data -> {
            if (!ServerAddress.sameOrigin(origin, data.uri.toString())) throw new java.io.IOException("Недопустимый адрес аудио");
            HashMap<String,String> headers = new HashMap<>(data.httpRequestHeaders);
            String cookie = NativeAPI.cookie(this,origin);
            if (cookie != null) headers.put("Cookie",cookie);
            return data.buildUpon().setHttpRequestHeaders(headers).build();
        });
        audioCache=new SimpleCache(new java.io.File(getFilesDir(),"audio-cache"),
                new LeastRecentlyUsedCacheEvictor(512L*1024*1024),new StandaloneDatabaseProvider(this));
        CacheDataSource.Factory cached=new CacheDataSource.Factory().setCache(audioCache).setUpstreamDataSourceFactory(source)
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR).setCacheKeyFactory(data->cacheScope+"|"+data.uri.toString());
        cachedSources=cached;
        fileSources=new DefaultMediaSourceFactory(cached);
        // Signed HLS manifests must be fetched fresh; only media bytes are reusable.
        hlsSources=new HlsMediaSource.Factory((HlsDataSourceFactory) type ->
                type==C.DATA_TYPE_MANIFEST ? source.createDataSource() : cached.createDataSource());
        androidx.media3.exoplayer.DefaultRenderersFactory renderers = new androidx.media3.exoplayer.DefaultRenderersFactory(this) {
            @Override protected androidx.media3.exoplayer.audio.AudioSink buildAudioSink(android.content.Context context,boolean floats,boolean params) {
                // PCM processors require the PCM path, including for HLS/AAC playback.
                return new androidx.media3.exoplayer.audio.DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(false).setEnableAudioTrackPlaybackParams(params)
                    .setAudioProcessors(new androidx.media3.common.audio.AudioProcessor[]{premiumEqualizer,new androidx.media3.exoplayer.audio.TeeAudioProcessor(audioMeter)}).build();
            }
        };
        // Small (350/1000 ms) restart buffers caused repeated audible stalls
        // on bursty HLS streams. Keep a larger safety margin after rebuffers.
        // Keep Android's existing 1-second fast mode as the default. Other choices
        // increase the startup margin without reducing the 3-second rebuffer reserve.
        int playbackBufferMs = bufferChoiceSeconds == 0 ? 1000 : bufferChoiceSeconds * 1000;
        androidx.media3.exoplayer.DefaultLoadControl buffering = new androidx.media3.exoplayer.DefaultLoadControl.Builder()
            .setBufferDurationsMs(20000,60000,playbackBufferMs,Math.max(3000,playbackBufferMs))
            .setPrioritizeTimeOverSizeThresholds(true).build();
        player = new ExoPlayer.Builder(this,renderers).setLoadControl(buffering).setMediaSourceFactory(fileSources).build();
        player.setAudioAttributes(new AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),true);
        player.setHandleAudioBecomingNoisy(true);
        player.setWakeMode(C.WAKE_MODE_NETWORK);
        player.addListener(new Player.Listener() {
            @Override public void onMediaItemTransition(MediaItem item,int reason) {
                beginTrackTiming(item);
                cancelStreamRetry();
                retriedTrackId = "";
                streamRetryCount = 0;
                manualTransition=reason==Player.MEDIA_ITEM_TRANSITION_REASON_SEEK;tickListening();
                fadeInActive=transitionSeconds>0 && (reason==Player.MEDIA_ITEM_TRANSITION_REASON_AUTO || reason==Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT);
                player.setVolume(fadeInActive?0:baseVolume);
                if(waveActive && item!=null){waveSeen.addLast(item.mediaId);while(waveSeen.size()>120)waveSeen.removeFirst();}
                if(item!=null && !item.mediaId.isEmpty())rememberPlayed(item.mediaId);
                refillWave();
            }
            @Override public void onIsPlayingChanged(boolean playing) {
                if(playing) {
                    if(audibleAfterMs < 0 && startupAt > 0)
                        audibleAfterMs = Math.max(0,android.os.SystemClock.elapsedRealtime()-startupAt);
                    scheduleNextFilePrefetch();
                }
                waveHandler.removeCallbacks(fadeTick);if(playing)waveHandler.post(fadeTick);
            }
            @Override public void onPositionDiscontinuity(Player.PositionInfo oldPosition,
                    Player.PositionInfo newPosition,int reason) {
                if(reason==Player.DISCONTINUITY_REASON_SEEK) {
                    long updated = Math.max(0,newPosition.positionMs);
                    lastGoodPositionMs=updated;
                    if(!player.getPlayWhenReady()) pausedPositionMs=updated;
                }
            }
            @Override public void onPlayWhenReadyChanged(boolean ready,int reason) {
                if(!ready){
                    capturePausePosition();
                    if(reason==Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)cancelStreamRetry();
                    cancelWaveRequest();
                }else { pausedPositionMs=-1; refillWave(); }
            }
            @Override public void onPlaybackStateChanged(int state) {
                if(state==Player.STATE_READY && readyAfterMs < 0 && startupAt > 0)
                    readyAfterMs=Math.max(0,android.os.SystemClock.elapsedRealtime()-startupAt);
                if(state==Player.STATE_BUFFERING && audibleAfterMs>=0 && player.getPlayWhenReady())
                    bufferingStalls++;
                if(state==Player.STATE_ENDED)refillWave();
            }
            @Override public void onPlayerError(androidx.media3.common.PlaybackException ex) {
                if (scheduleStreamRetry(ex)) return;
                player.pause();
                String detail=ex.getErrorCodeName();
                for(Throwable cause=ex;cause!=null;cause=cause.getCause())
                    if(cause instanceof androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)
                        detail="HTTP "+((androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)cause).responseCode;
                error = "Не удалось запустить трек ("+detail+"). Нажми воспроизведение для повторной попытки.";
            }
        });
        PendingIntent open = PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        session = new MediaSession.Builder(this,player).setSessionActivity(open)
                .setBitmapLoader(new androidx.media3.datasource.DataSourceBitmapLoader(
                        artworkIO,source))
                .setCallback(new MediaSession.Callback() {
                    @Override public MediaSession.ConnectionResult onConnect(MediaSession session,MediaSession.ControllerInfo controller) {
                        return new MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                                .setAvailablePlayerCommands(MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                                        .remove(Player.COMMAND_SEEK_BACK).remove(Player.COMMAND_SEEK_FORWARD).build()).build();
                    }
                }).build();
        addSession(session);
        waveHandler.post(waveTick);
    }
    @Override public IBinder onBind(Intent intent) {
        return "nightwell.local".equals(intent.getAction()) ? binder : super.onBind(intent);
    }
    @Override public MediaSession onGetSession(MediaSession.ControllerInfo info) { return session; }

    private void cancelStreamRetry() {
        if (pendingStreamRetry != null) {
            waveHandler.removeCallbacks(pendingStreamRetry);
            pendingStreamRetry = null;
        }
    }
    private boolean scheduleStreamRetry(androidx.media3.common.PlaybackException failure) {
        MediaItem item = player.getCurrentMediaItem();
        if (item == null) return false;
        if (!item.mediaId.equals(retriedTrackId)) streamRetryCount = 0;
        if (streamRetryCount >= 3) return false;
        boolean temporary = false;
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
            if (cause instanceof java.net.SocketTimeoutException ||
                    cause instanceof java.net.ConnectException ||
                    cause instanceof java.net.SocketException ||
                    cause instanceof java.net.UnknownHostException ||
                    cause instanceof java.io.EOFException) temporary = true;
            if (cause instanceof androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException) {
                int code = ((androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException) cause).responseCode;
                temporary = code == 408 || code == 429 || code >= 500 && code <= 599;
                break;
            }
        }
        if (!temporary) return false;
        cancelStreamRetry();
        retriedTrackId = item.mediaId;
        streamRetryCount++;
        final int attempt = streamRetryCount;
        final String id = item.mediaId;
        error = "Соединение прервалось. Повторяем загрузку…";
        final int retryIndex = player.getCurrentMediaItemIndex();
        final long retryPosition = Math.max(0, player.getCurrentPosition());
        pendingStreamRetry = () -> {
            pendingStreamRetry = null;
            if (player.getCurrentMediaItem() == null || !id.equals(player.getCurrentMediaItem().mediaId) ||
                    player.getCurrentMediaItemIndex() != retryIndex) return;
            error = "";
            player.seekTo(retryIndex, retryPosition);
            player.prepare();
            player.play();
        };
        waveHandler.postDelayed(pendingStreamRetry, attempt == 1 ? 1200 : attempt == 2 ? 3000 : 6000);
        return true;
    }
    void prepare(String json) {
        cancelStreamRetry();
        retriedTrackId = "";
        streamRetryCount = 0;
        try {
            JSONObject data = new JSONObject(json);
            String nextOrigin = ServerAddress.normalize(data.getString("origin"));
            if (nextOrigin == null) return;
            offlineAccount=data.optString("account","");
            JSONArray queue = data.getJSONArray("queue");
            String id = data.getString("id");
            ArrayList<MediaSource> items = new ArrayList<>();
            int selected = -1;
            for (int i=0;i<queue.length() && i<1000;i++) {
                JSONObject track=queue.getJSONObject(i);String trackId=track.getString("id");
                if (!trackId.matches("[A-Za-z0-9_-]+")) continue;
                if (trackId.equals(id)) selected=items.size();
                items.add(mediaSource(mediaItem(track,nextOrigin)));
            }
            if(selected<0)return;
            waveActive=false;cancelWaveRequest();
            player.stop();player.setPlayWhenReady(false);
            String account=data.optString("account","");
            if(!account.matches("[A-Za-z0-9_-]{1,80}"))account=String.valueOf(NativeAPI.cookie(this,nextOrigin));
            byte[] digest=java.security.MessageDigest.getInstance("SHA-256").digest((nextOrigin+"|"+account).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder scope=new StringBuilder();for(byte value:digest)scope.append(String.format("%02x",value&255));
            cacheScope=scope.toString();origin=nextOrigin;error="";
            boolean nextWave=data.optBoolean("wave",false);
            waveSettings=new WaveSettings(data.optJSONObject("wave_preferences")==null?new JSONObject():data.optJSONObject("wave_preferences"));
            if(!waveActive||!nextWave)waveSeen.clear();
            waveActive=nextWave;waveGeneration++;waveLoading=false;waveRetryAt=0;
            if(waveActive){player.setRepeatMode(Player.REPEAT_MODE_OFF);player.setShuffleModeEnabled(false);}
            player.setMediaSources(items,selected,Math.max(0,data.optLong("position",0)));
            player.prepare();
        } catch (Exception ex) { error="Не удалось загрузить очередь."; }
    }
    void play() {
        cancelStreamRetry(); retriedTrackId = ""; streamRetryCount = 0; error="";
        if(player.getCurrentMediaItem()!=null && !player.getPlayWhenReady()) {
            startupAt=android.os.SystemClock.elapsedRealtime();
            readyAfterMs=player.getPlaybackState()==Player.STATE_READY ? 0 : -1;
            audibleAfterMs=-1;
        }
        if(player.getPlaybackState()==Player.STATE_IDLE&&player.getMediaItemCount()>0)player.prepare();
        player.play();refillWave();
    }
    void pause() { cancelStreamRetry(); capturePausePosition(); player.pause(); }
    void stop() { audioPrefetchGeneration++; pausedPositionMs=-1; lastGoodPositionMs=0; cancelStreamRetry(); retriedTrackId = ""; streamRetryCount = 0; waveActive=false;cancelWaveRequest();waveSeen.clear();player.stop();player.clearMediaItems();
        if(audioCache!=null)for(String key:new HashSet<>(audioCache.getKeys()))if(key.startsWith(cacheScope+"|"))try{audioCache.removeResource(key);}catch(Exception ignored){}
    }
    void seek(double seconds) {
        if(Double.isFinite(seconds)){
            long position=Math.max(0,(long)(seconds*1000));
            lastGoodPositionMs=position;
            if(!player.getPlayWhenReady())pausedPositionMs=position;
            fadeInActive=false;player.setVolume(baseVolume);player.seekTo(position);
        }
    }
    void transitionDuration(double value) { if(Double.isFinite(value)){transitionSeconds=Math.max(0,Math.min(5,value));getSharedPreferences("playback",MODE_PRIVATE).edit().putFloat("nw-transition-seconds",(float)transitionSeconds).apply();updateFade();} }
    void volume(double value) { if(Double.isFinite(value)){baseVolume=(float)Math.max(0,Math.min(1,value));updateFade();} }
    void modes(int repeat, boolean shuffle) { player.setRepeatMode(repeat==1&&!waveActive?Player.REPEAT_MODE_ALL:repeat==2?Player.REPEAT_MODE_ONE:Player.REPEAT_MODE_OFF);player.setShuffleModeEnabled(!waveActive&&shuffle); }
    private MediaSource mediaSource(MediaItem item) {
        if(item.localConfiguration!=null && "file".equals(item.localConfiguration.uri.getScheme()))return new DefaultMediaSourceFactory(new androidx.media3.datasource.DefaultDataSource.Factory(this)).createMediaSource(item);

        return item.localConfiguration!=null && MimeTypes.APPLICATION_M3U8.equals(item.localConfiguration.mimeType)
                ? hlsSources.createMediaSource(item) : fileSources.createMediaSource(item);
    }
    private MediaItem mediaItem(JSONObject track,String base) throws Exception {
        String id=track.getString("id");
        if(!id.matches("[A-Za-z0-9_-]{1,80}"))throw new IllegalArgumentException("Invalid track");
        Bundle extras=new Bundle();extras.putString("track",track.toString());
        MediaMetadata.Builder metadata=new MediaMetadata.Builder().setTitle(track.optString("title"))
                .setArtist(track.optString("artist")).setAlbumTitle(track.optString("album")).setExtras(extras);
        String cover=track.optString("cover_url","");
        if(cover.startsWith("/api/covers/"))metadata.setArtworkUri(Uri.parse(base).buildUpon().encodedPath(cover).build());
        if(cover.startsWith("data:image/")&&cover.contains(","))try{byte[] bytes=android.util.Base64.decode(cover.substring(cover.indexOf(',')+1),android.util.Base64.DEFAULT);if(bytes.length<2*1024*1024)metadata.setArtworkData(bytes,MediaMetadata.PICTURE_TYPE_FRONT_COVER);}catch(Exception ignored){}
        java.io.File saved=OfflineStore.audio(this,base,track.optString("_offline_account",offlineAccount),id);
        if(saved!=null)return new MediaItem.Builder().setMediaId(id).setUri(Uri.fromFile(saved)).setMimeType(track.optString("_mime","audio/mp4")).setMediaMetadata(metadata.build()).build();
        if(track.optBoolean("_offline",false))throw new java.io.IOException("Offline file missing");
        boolean remote=StreamPolicy.usesHls(track.optBoolean("is_remote",false),track.optString("source"),track.optString("source_url"));
        MediaItem.Builder item=new MediaItem.Builder().setMediaId(id).setUri(base+"api/stream/"+id+"?cache=1&format="+(remote?"hls":"file")).setMediaMetadata(metadata.build());
        if(remote)item.setMimeType(MimeTypes.APPLICATION_M3U8);
        return item.build();
    }
    private void cancelWaveRequest() {
        waveGeneration++;waveLoading=false;waveRequest.cancel();
    }
    private void rememberPlayed(String id) {
        if(origin.isEmpty())return;
        String account=offlineAccount.isEmpty()?"device":offlineAccount;
        String scope=origin+"|"+account;
        android.content.SharedPreferences prefs=getSharedPreferences("recommendation-history",MODE_PRIVATE);
        try {
            JSONArray prior=new JSONArray(prefs.getString(scope,"[]")),updated=new JSONArray();
            for(int i=Math.max(0,prior.length()-119);i<prior.length();i++) {
                String previous=prior.optString(i);
                if(!previous.isEmpty()&&!previous.equals(id))updated.put(previous);
            }
            updated.put(id);
            prefs.edit().putString(scope,updated.toString()).apply();
        }catch(Exception ignored){}
    }
    private void refillWave() {
        if(!waveActive||waveLoading||!player.getPlayWhenReady()||player.getCurrentMediaItem()==null||System.currentTimeMillis()<waveRetryAt)return;
        int index=player.getCurrentMediaItemIndex();
        if(player.getMediaItemCount()-index-1>8)return;
        java.util.LinkedHashSet<String> excluded=new java.util.LinkedHashSet<>(waveSeen);
        for(int i=index;i<player.getMediaItemCount();i++)excluded.add(player.getMediaItemAt(i).mediaId);
        String scope=origin+"|"+(offlineAccount.isEmpty()?"device":offlineAccount);
        java.util.Set<String> hidden=new java.util.HashSet<>(getSharedPreferences("recommendation-hides",MODE_PRIVATE)
            .getStringSet(scope,java.util.Collections.emptySet()));
        hidden.addAll(SkipFeedback.recentIDs(this,origin,offlineAccount));
        java.util.Set<String> blockedArtists=new java.util.HashSet<>(
            getSharedPreferences("recommendation-artists",MODE_PRIVATE)
                .getStringSet(scope,java.util.Collections.emptySet()));
        java.util.Set<String> recent=new java.util.LinkedHashSet<>();
        try {
            JSONArray history=new JSONArray(getSharedPreferences("recommendation-history",MODE_PRIVATE)
                .getString(scope,"[]"));
            for(int i=Math.max(0,history.length()-60);i<history.length();i++)recent.add(history.optString(i));
        }catch(Exception ignored){}
        excluded.addAll(recent);
        java.util.List<String> hiddenList=new java.util.ArrayList<>(hidden);
        java.util.Collections.sort(hiddenList);
        for(int i=0;i<Math.min(70,hiddenList.size());i++)excluded.add(hiddenList.get(i));
        String base=origin;
        String settingsQuery=waveSettings.query();
        NativeAPI client=new NativeAPI(this,base);
        long ticket=waveRequest.start(client::close);
        int generation=waveGeneration;waveLoading=true;
        waveIO.execute(()->{
            JSONObject result=null;String failure="Не удалось пополнить волну. Повторим запрос.";
            try {
                if(!waveRequest.pending(ticket))return;
                java.util.List<String> ids=new java.util.ArrayList<>(excluded);
                String query=URLEncoder.encode(String.join(",",ids.subList(
                    Math.max(0,ids.size()-160),ids.size())),"UTF-8");
                result=client.search("api/wave?exclude="+query+settingsQuery);
            }catch(Exception ignored){}
            finally{client.close();}
            final JSONObject data=result;final String message=failure;
            waveHandler.post(()->{
                if(!waveRequest.complete(ticket)||generation!=waveGeneration||!waveActive)return;
                waveLoading=false;waveRetryAt=System.currentTimeMillis()+5000;
                if(data==null){error=message;return;}
                try {
                    JSONArray raw=data.getJSONArray("tracks");ArrayList<MediaSource> fresh=new ArrayList<>();
                    HashSet<String> waiting=new HashSet<>(waveSeen);
                    for(int i=player.getCurrentMediaItemIndex();i<player.getMediaItemCount();i++)waiting.add(player.getMediaItemAt(i).mediaId);
                    java.util.List<JSONObject> candidates=new ArrayList<>();for(int i=0;i<raw.length()&&i<20;i++)candidates.add(raw.getJSONObject(i));
                    for(JSONObject track:RecommendationOrder.arrange(candidates,recent,hidden,blockedArtists,player.getCurrentMediaItem()==null?"":player.getCurrentMediaItem().mediaId,t->t.optString("id"),t->t.optString("title"),t->t.optString("artist"))){
                        if(waiting.add(track.getString("id")))fresh.add(mediaSource(mediaItem(track,base)));
                    }
                    if(fresh.isEmpty()){error=data.optString("message","Новые треки пока не найдены.");return;}
                    boolean ended=player.getPlaybackState()==Player.STATE_ENDED,continuePlaying=player.getPlayWhenReady();
                    int remove=Math.max(0,player.getCurrentMediaItemIndex()-5);
                    if(remove>0)player.removeMediaItems(0,remove);
                    int firstNew=player.getMediaItemCount();player.addMediaSources(fresh);error="";
                    waveRetryAt=System.currentTimeMillis()+30000;
                    if(ended&&continuePlaying){player.seekTo(firstNew,0);player.prepare();player.play();}
                }catch(Exception ignored){error=message;}
            });
        });
    }
    double level(){return player==null?0:audioMeter.level(player.isPlaying());}
    double bandLevel(int index){return player==null?0:audioMeter.band(index,player.isPlaying());}
    private long lastSaved;
    void persistPlayback(boolean force){
        if(player==null||player.getCurrentMediaItem()==null||origin.isEmpty()||!force&&android.os.SystemClock.elapsedRealtime()-lastSaved<2000)return;
        lastSaved=android.os.SystemClock.elapsedRealtime();
        try{JSONObject state=new JSONObject(snapshot(true));state.put("account",offlineAccount);getSharedPreferences("native-playback",MODE_PRIVATE).edit().putString(origin+"|"+(offlineAccount.isEmpty()?"device":offlineAccount),state.toString()).apply();}catch(Exception ignored){}
    }
    void restorePlayback(String base,String account){
        if(player==null||player.getMediaItemCount()>0)return;
        String saved=getSharedPreferences("native-playback",MODE_PRIVATE).getString(base+"|"+(account.isEmpty()?"device":account),null);if(saved==null)return;
        try{JSONObject state=new JSONObject(saved);state.put("queue",state.getJSONArray("queueTracks")).put("position",(long)(state.optDouble("position")*1000)).put("origin",base).put("account",account.isEmpty()?"device":account);prepare(state.toString());modes(state.optInt("repeat"),state.optBoolean("shuffle"));}catch(Exception ignored){}
    }
    private String listenedID="",listenedSession="";
    private double listenedSeconds;
    private long listenedAt=android.os.SystemClock.elapsedRealtime(),reportedAt;
    private boolean wasAudible,manualTransition;
    private void tickListening(){
        if(player==null)return;
        long now=android.os.SystemClock.elapsedRealtime();String id=player.getCurrentMediaItem()==null?"":player.getCurrentMediaItem().mediaId;
        if(wasAudible)listenedSeconds+=Math.max(0,Math.min(5,(now-listenedAt)/1000.0));listenedAt=now;
        if(!id.equals(listenedID)){reportListening(manualTransition&&listenedSeconds<30);manualTransition=false;listenedID=id;listenedSession=java.util.UUID.randomUUID().toString();listenedSeconds=0;}
        boolean audible=player.isPlaying();if(now-reportedAt>15000||wasAudible&&!audible)reportListening();wasAudible=audible;
    }
    private void reportListening(){reportListening(false);}
    private void reportListening(boolean skipped){
        reportedAt=android.os.SystemClock.elapsedRealtime();if(listenedID.isEmpty()||offlineAccount.isEmpty()||offlineAccount.equals("device")||listenedID.startsWith("local_")||listenedSeconds<=0)return;
        if(skipped&&waveActive&&listenedSeconds>=3&&listenedSeconds<30)
            SkipFeedback.record(this,origin,offlineAccount,listenedID);
        final String id=listenedID,sid=listenedSession,base=origin;final double seconds=listenedSeconds;
        waveIO.execute(()->{try{new NativeAPI(this,base).request("api/listening","POST",new JSONObject().put("session_id",sid).put("track_id",id).put("seconds",seconds).put("skipped",skipped));}catch(Exception ignored){}});
    }
    String meterState() {
        try {
            return new JSONObject().put("id",player.getCurrentMediaItem()==null?"":player.getCurrentMediaItem().mediaId)
                .put("level",audioMeter.level(player.isPlaying())).put("ready",true).toString();
        }catch(Exception ignored){return "{}";}
    }
    String snapshot(){return snapshot(true);}
    String snapshot(boolean includeQueue) {
        try {
            JSONObject state=new JSONObject();
            MediaItem item=player.getCurrentMediaItem();
            state.put("id",item==null?"":item.mediaId);
            state.put("origin",origin);
            long position=Math.max(0,player.getCurrentPosition());
            if(item!=null && !item.mediaId.equals(positionTrack)) {
                positionTrack=item.mediaId; lastGoodPositionMs=position; pausedPositionMs=-1;
            }
            if(player.getPlayWhenReady() && position>0) lastGoodPositionMs=position;
            if(item!=null && !player.getPlayWhenReady() && pausedPositionMs>=0) position=pausedPositionMs;
            state.put("position",position/1000.0);
            state.put("duration",player.getDuration()==C.TIME_UNSET?0:player.getDuration()/1000.0);
            state.put("playing",player.getPlayWhenReady() && player.getPlaybackState()!=Player.STATE_ENDED);
            state.put("ended",player.getPlaybackState()==Player.STATE_ENDED);
            state.put("repeat",player.getRepeatMode()==Player.REPEAT_MODE_ALL?1:player.getRepeatMode()==Player.REPEAT_MODE_ONE?2:0);state.put("shuffle",player.getShuffleModeEnabled());
            state.put("error",error);state.put("volume",baseVolume);state.put("smoothTransitions",true);state.put("transitionSeconds",transitionSeconds);
            state.put("wave_preferences",waveSettings.json());state.put("wave",waveActive);state.put("waveSupported",true);
            JSONArray fullQueue=new JSONArray();
            for(int i=0;includeQueue&&i<player.getMediaItemCount();i++){
                Bundle extras=player.getMediaItemAt(i).mediaMetadata.extras;
                if(extras!=null)fullQueue.put(new JSONObject(extras.getString("track","{}")));
            }
            state.put("queueTracks",fullQueue);
            JSONArray ids=new JSONArray();for(int i=0;includeQueue&&i<player.getMediaItemCount();i++)ids.put(player.getMediaItemAt(i).mediaId);
            state.put("queueIds",ids);state.put("queueCount",player.getMediaItemCount());
            return state.toString();
        } catch(Exception ex) { return "{}"; }
    }
    @Override public void onDestroy() {
        cancelStreamRetry();
        persistPlayback(true);
        waveActive=false;cancelWaveRequest();audioPrefetchGeneration++;
        waveHandler.removeCallbacksAndMessages(null);waveIO.shutdownNow();audioPrefetchIO.shutdownNow();artworkIO.shutdownNow();
        if(session!=null)session.release();if(player!=null)player.release();if(audioCache!=null)audioCache.release();super.onDestroy();
    }
}



