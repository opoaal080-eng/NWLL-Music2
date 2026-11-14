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
    private volatile int bufferChoiceSeconds = 0; // Read by ExoPlayer's playback threads.

    // Keep the normal allocator/loading policy, but read the current startup
    // threshold instead of baking a preference into a replacement player.
    private final class AdjustableBufferLoadControl extends androidx.media3.exoplayer.DefaultLoadControl {
        private final int minimumRebufferMs;
        AdjustableBufferLoadControl(int minBufferMs,int maxBufferMs,int minimumRebufferMs){
            super(new androidx.media3.exoplayer.upstream.DefaultAllocator(true,C.DEFAULT_BUFFER_SEGMENT_SIZE),
                minBufferMs,maxBufferMs,1000,minimumRebufferMs,C.LENGTH_UNSET,true,0,false);
            this.minimumRebufferMs=minimumRebufferMs;
        }
        @Override public boolean shouldStartPlayback(androidx.media3.exoplayer.LoadControl.Parameters parameters){
            int selected=bufferChoiceSeconds;
            // Auto uses ExoPlayer's adaptive startup/rebuffer decisions instead
            // of disguising a fixed 1-second threshold as an automatic preset.
            if(selected==0)return super.shouldStartPlayback(parameters);
            long thresholdUs=selected*1000000L;
            if(parameters.rebuffering)thresholdUs=Math.max(thresholdUs,minimumRebufferMs*1000L);
            if(parameters.targetLiveOffsetUs!=C.TIME_UNSET)
                thresholdUs=Math.min(thresholdUs,parameters.targetLiveOffsetUs/2);
            long bufferedUs=androidx.media3.common.util.Util.getPlayoutDurationForMediaDuration(
                parameters.bufferedDurationUs,parameters.playbackSpeed);
            return thresholdUs<=0||bufferedUs>=thresholdUs;
        }
    }

    void settingStreamBufferSeconds(int seconds){
        bufferChoiceSeconds=seconds==4||seconds==8||seconds==12?seconds:0;
        getSharedPreferences("playback",MODE_PRIVATE).edit()
            .putInt("nw-stream-buffer-seconds",bufferChoiceSeconds).apply();
    }

    // Stage the next item on a silent ExoPlayer. The live queue remains untouched
    // until the candidate decoder has reached READY, even on slow HLS sources.
    private ExoPlayer pendingNextPlayer;
    private boolean nextPreparing = false, pendingWaveNext = false;
    private int pendingNextGeneration = 0;
    private int pendingNextIndex = C.INDEX_UNSET;
    private String pendingNextId = "";
    private Runnable pendingNextTimeout;
    private final FailedNextSkipPolicy failedNext=new FailedNextSkipPolicy();
    private final HashSet<String> queuedIds=new HashSet<>();
    private String lastEnqueueError="";

    private String activeMediaId(){
        MediaItem item=player==null?null:player.getCurrentMediaItem();
        return item==null?"":item.mediaId;
    }

    private void reportNextLoadFailure(String activeId,String unavailableId){
        if(activeId.isEmpty()||unavailableId.isEmpty())return;
        error=FailedNextSkipPolicy.FAILURE_MESSAGE+
            ". Нажми «Далее» ещё раз, чтобы пропустить его. Текущий трек продолжает играть.";
        failedNext.reportFailed(activeId,unavailableId,error);
    }
    private boolean keepCurrentUntilReady() {
        return getSharedPreferences("playback",MODE_PRIVATE)
            .getBoolean("nw-keep-current-until-ready",true);
    }
    // Manual queue selections must use a stable media ID, not the artwork
    // deck's index which may have moved while recommendations were appended.
    void selectTrack(String id) {
        if(player==null||id==null||id.isEmpty())return;
        failedNext.clear();
        for(int i=0;i<player.getMediaItemCount();i++) {
            if(id.equals(player.getMediaItemAt(i).mediaId)) {
                if(i==player.getCurrentMediaItemIndex()){
                    if(!player.getPlayWhenReady())player.play();
                    return;
                }
                if(keepCurrentUntilReady()&&player.getPlayWhenReady()
                   &&player.getPlaybackState()!=Player.STATE_ENDED) {
                    prepareSelectedIndex(i);
                } else {
                    cancelPreparedNext();
                    player.seekTo(i,0);
                    if(player.getPlaybackState()==Player.STATE_IDLE)player.prepare();
                    player.play();
                }
                return;
            }
        }
    }
    void settingKeepCurrentUntilReady(boolean enabled) {
        getSharedPreferences("playback",MODE_PRIVATE).edit()
            .putBoolean("nw-keep-current-until-ready",enabled).apply();
        if(!enabled&&nextPreparing&&pendingNextIndex!=C.INDEX_UNSET) {
            int target=pendingNextIndex;
            cancelPreparedNext();
            player.seekTo(target,0);
            if(player.getPlaybackState()==Player.STATE_IDLE)player.prepare();
            player.play();
        }
    }
    private void cancelPreparedNext() {
        pendingNextGeneration++;
        nextPreparing = false; pendingWaveNext = false;
        pendingNextIndex = C.INDEX_UNSET; pendingNextId = "";
        if(pendingNextTimeout != null) {
            waveHandler.removeCallbacks(pendingNextTimeout);
            pendingNextTimeout = null;
        }
        if(pendingNextPlayer != null) {
            pendingNextPlayer.release();
            pendingNextPlayer = null;
        }
    }
    void requestPreparedNext() {
        // The first Next always attempts normal preparation. Extra presses
        // during preparation are ignored, not interpreted as skip requests.
        if(player == null || nextPreparing || pendingWaveNext) return;
        int destination=player.getNextMediaItemIndex();
        final String currentId=activeMediaId();
        if(destination!=C.INDEX_UNSET&&failedNext.maySkip(currentId,error)){
            androidx.media3.common.Timeline timeline=player.getCurrentTimeline();
            int attempts=0;
            while(destination!=C.INDEX_UNSET&&attempts++<player.getMediaItemCount()&&
                failedNext.wasFailed(currentId,player.getMediaItemAt(destination).mediaId)){
                destination=timeline.getNextWindowIndex(destination,
                    Player.REPEAT_MODE_OFF,player.getShuffleModeEnabled());
            }
            if(destination==C.INDEX_UNSET||destination==player.getCurrentMediaItemIndex()){
                error=FailedNextSkipPolicy.FAILURE_MESSAGE+
                    ". Других треков для пропуска пока нет.";
                if(waveActive){pendingWaveNext=true;refillWave();}
                return;
            }
        }
        if(destination == C.INDEX_UNSET) {
            if(waveActive) { pendingWaveNext = true; refillWave(); }
            return;
        }
        if(!keepCurrentUntilReady()) {
            failedNext.clear();
            player.seekTo(destination,0);
            if(player.getPlaybackState()==Player.STATE_IDLE)player.prepare();
            player.play();
            return;
        }
        prepareSelectedIndex(destination);
    }
    private void prepareSelectedIndex(int destination) {
        if(player==null || destination<0 || destination>=player.getMediaItemCount())return;
        cancelPreparedNext();
        MediaItem candidate = player.getMediaItemAt(destination);
        if(candidate.localConfiguration == null){
            reportNextLoadFailure(activeMediaId(),candidate.mediaId);
            return;
        }
        nextPreparing = true; pendingNextIndex = destination;
        pendingNextId = candidate.mediaId; error = "";
        int ticket = ++pendingNextGeneration;
        try {
            // The maximum selectable 12-second threshold must fit below the
            // minimum loading watermark, including after a live setting change.
            androidx.media3.exoplayer.DefaultLoadControl loadControl =
                new AdjustableBufferLoadControl(12000,20000,1500);
            ExoPlayer stage = new ExoPlayer.Builder(this)
                .setLoadControl(loadControl).setMediaSourceFactory(fileSources).build();
            stage.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),false);
            stage.setVolume(0f);
            pendingNextPlayer = stage;
            stage.addListener(new Player.Listener() {
                @Override public void onPlaybackStateChanged(int state) {
                    if(ticket != pendingNextGeneration || !nextPreparing) return;
                    if(state == Player.STATE_READY) commitPreparedNext(ticket);
                }
                @Override public void onPlayerError(androidx.media3.common.PlaybackException failure) {
                    if(ticket != pendingNextGeneration) return;
                    final String missed=pendingNextId,active=activeMediaId();
                    cancelPreparedNext();
                    reportNextLoadFailure(active,missed);
                }
            });
            stage.setMediaSource(mediaSource(candidate));
            stage.prepare();
            pendingNextTimeout = () -> {
                if(ticket != pendingNextGeneration || !nextPreparing) return;
                final String missed=pendingNextId,active=activeMediaId();
                cancelPreparedNext();
                reportNextLoadFailure(active,missed);
            };
            waveHandler.postDelayed(pendingNextTimeout, 30000);
        } catch(Exception ex) {
            final String missed=pendingNextId,active=activeMediaId();
            cancelPreparedNext();
            reportNextLoadFailure(active,missed);
        }
    }
    private void commitPreparedNext(int ticket) {
        if(!nextPreparing || ticket != pendingNextGeneration) return;
        int position = C.INDEX_UNSET;
        for(int i=0;i<player.getMediaItemCount();i++)
            if(pendingNextId.equals(player.getMediaItemAt(i).mediaId)) { position=i; break; }
        cancelPreparedNext();
        if(position == C.INDEX_UNSET) {
            error = "Очередь изменилась во время подготовки. Повтори переход.";
            return;
        }
        // The preview has already read and cached initial audio bytes.
        // Real ExoPlayer/MediaSession remain the only audible player.
        failedNext.clear();
        error="";
        player.seekTo(position,0);
        if(player.getPlaybackState() == Player.STATE_IDLE) player.prepare();
        player.play();
    }

    // ExoPlayer may remain BUFFERING indefinitely without delivering
    // onPlayerError. After a bounded wait restart the same track at the
    // buffered playhead, never silently skip to another media item.
    private Runnable bufferingWatchdog;
    private int bufferingRecoveries;
    private String bufferingTrack="";
    private void cancelBufferingWatchdog(){
        if(bufferingWatchdog!=null){
            waveHandler.removeCallbacks(bufferingWatchdog);
            bufferingWatchdog=null;
        }
    }
    private void watchBuffering(){
        cancelBufferingWatchdog();
        if(player==null||player.getPlaybackState()!=Player.STATE_BUFFERING||
           !player.getPlayWhenReady())return;
        final String id=activeMediaId();
        if(!id.equals(bufferingTrack)){
            bufferingTrack=id;
            bufferingRecoveries=0;
        }
        bufferingWatchdog=()->{
            bufferingWatchdog=null;
            if(player==null||!id.equals(activeMediaId())||
               player.getPlaybackState()!=Player.STATE_BUFFERING||
               !player.getPlayWhenReady())return;
            if(bufferingRecoveries>=2){
                error="Соединение нестабильно. Трек продолжает загружаться.";
                return;
            }
            bufferingRecoveries++;
            long position=Math.max(0,player.getCurrentPosition());
            error="Долгая буферизация. Переподключаем аудиопоток…";
            player.seekTo(player.getCurrentMediaItemIndex(),position);
            player.prepare();
            player.play();
            watchBuffering();
        };
        waveHandler.postDelayed(bufferingWatchdog,18000);
    }
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
        // ExoPlayer can report an earlier sample during the pause handoff.
        // Capture the newest known playhead before stopping the decoder.
        lastGoodPositionMs = Math.max(lastGoodPositionMs,current);
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
        }, 850);
    }
    private float baseVolume=1f;
    private boolean fadeInActive=false;
    private double transitionSeconds=.8;
    private int volumeLevelingStrength;
    private double loudnessAverage=0, loudnessGain=1;
    private volatile String cacheScope="guest";
    private String offlineAccount="";
    private volatile String origin = "";
    private String error = "";
    private String retriedTrackId = "";
    private int streamRetryCount = 0;
    private Runnable pendingStreamRetry;
    private boolean waveActive, waveLoading;
    int shuffleMode = 0; // 0 off, 1 random, 2 smart
    private WaveSettings waveSettings=new WaveSettings(new JSONObject());
    private String waveSeedArtists="";
    private int waveGeneration;
    private final LatestRequest waveRequest = new LatestRequest();
    private long waveRetryAt;
    private final ArrayDeque<String> waveSeen = new ArrayDeque<>();
    private final ExecutorService waveIO = Executors.newSingleThreadExecutor();
    private final ExecutorService listeningIO = Executors.newSingleThreadExecutor();
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
        if(player.isPlaying() && volumeLevelingStrength>0){
            double rms=audioMeter.loudnessRMS();
            if(Double.isFinite(rms)&&rms>0.018){
                loudnessAverage=loudnessAverage==0?rms:loudnessAverage*.92+rms*.08;
                double attenuation=Math.max(.48,Math.min(1,.105/Math.max(.025,loudnessAverage)));
                double target=1-(1-attenuation)*volumeLevelingStrength/100.0;
                loudnessGain+=(target-loudnessGain)*.12;
            }
        } else if(volumeLevelingStrength==0) loudnessGain=1;
        float leveled=(float)(baseVolume*loudnessGain);
        if(transitionSeconds<=0){fadeInActive=false;player.setVolume(leveled);return;}
        long duration=player.getDuration(),position=Math.max(0,player.getCurrentPosition());
        boolean known=duration>200 && duration!=C.TIME_UNSET;
        double span=known?Math.min(transitionSeconds*1000,duration/4.0):transitionSeconds*1000;
        if(fadeInActive && position>=span)fadeInActive=false;
        boolean next=waveActive || player.hasNextMediaItem() || player.getRepeatMode()!=Player.REPEAT_MODE_OFF;
        double entry=fadeInActive?Math.max(0,Math.min(1,position/span)):1;
        double exit=known&&next?Math.max(0,Math.min(1,(duration-position)/span)):1;
        player.setVolume(leveled*(float)Math.min(entry,exit));
    }
    public final class LocalBinder extends Binder { PlaybackService getService() { return PlaybackService.this; } }

    @Override public void onCreate() {
        super.onCreate();
        ArtistTaste.load(this);
        transitionSeconds=getSharedPreferences("playback",MODE_PRIVATE).getFloat("nw-transition-seconds",.8f);
        volumeLevelingStrength=Math.max(0,Math.min(100,getSharedPreferences("playback",MODE_PRIVATE).getInt("nw-equal-volume",0)));
        shuffleMode=Math.max(0,Math.min(2,getSharedPreferences("playback",MODE_PRIVATE).getInt("nw-shuffle-mode",0)));
        bufferChoiceSeconds=getSharedPreferences("playback",MODE_PRIVATE).getInt("nw-stream-buffer-seconds",0);
        if(bufferChoiceSeconds!=0 && bufferChoiceSeconds!=4 && bufferChoiceSeconds!=8 && bufferChoiceSeconds!=12) bufferChoiceSeconds=0;
        DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory().setUserAgent("NightwellMusic/0.5").setConnectTimeoutMs(10000).setReadTimeoutMs(20000);
        ResolvingDataSource.Factory source = new ResolvingDataSource.Factory(http, data -> {
            Uri current = data.uri;
            String hostname = current.getHost()==null?"":current.getHost().toLowerCase(java.util.Locale.ROOT);
            boolean own=ServerAddress.sameOrigin(origin,current.toString());
            boolean soundcloudCDN="https".equals(current.getScheme()) &&
                ("playback.media-streaming.soundcloud.cloud".equals(hostname) ||
                 hostname.endsWith(".media-streaming.soundcloud.cloud") ||
                 "cf-hls-media.sndcdn.com".equals(hostname) ||
                 hostname.endsWith(".sndcdn.com"));
            if(!own&&!soundcloudCDN)
                throw new java.io.IOException("Недопустимый аудиоисточник");
            HashMap<String,String> headers = new HashMap<>(data.httpRequestHeaders);
            if(own){
                String cookie=NativeAPI.cookie(this,origin);
                if(cookie!=null)headers.put("Cookie",cookie);
            }else{
                // Session cookies never accompany SoundCloud CDN segments.
                headers.remove("Cookie");
                headers.remove("Authorization");
            }
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
        androidx.media3.exoplayer.DefaultLoadControl buffering =
            new AdjustableBufferLoadControl(20000,60000,3000);
        player = new ExoPlayer.Builder(this,renderers).setLoadControl(buffering).setMediaSourceFactory(fileSources).build();
        player.setAudioAttributes(new AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),true);
        player.setHandleAudioBecomingNoisy(true);
        player.setWakeMode(C.WAKE_MODE_NETWORK);
        player.addListener(new Player.Listener() {
            @Override public void onMediaItemTransition(MediaItem item,int reason) {
                cancelPreparedNext();
                retainUpcomingQueuedIds();
                failedNext.clear();
                cancelBufferingWatchdog();
                bufferingTrack="";
                bufferingRecoveries=0;
                loudnessAverage=0; loudnessGain=1;
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
                    cancelBufferingWatchdog();
                    capturePausePosition();
                    if(reason==Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)cancelStreamRetry();
                    cancelWaveRequest();
                }else { pausedPositionMs=-1; refillWave();watchBuffering(); }
            }
            @Override public void onPlaybackStateChanged(int state) {
                if(state==Player.STATE_READY && readyAfterMs < 0 && startupAt > 0)
                    readyAfterMs=Math.max(0,android.os.SystemClock.elapsedRealtime()-startupAt);
                if(state==Player.STATE_BUFFERING && audibleAfterMs>=0 && player.getPlayWhenReady())
                    bufferingStalls++;
                if(state==Player.STATE_BUFFERING)watchBuffering();
                else {
                    cancelBufferingWatchdog();
                    if(state==Player.STATE_READY){
                        bufferingRecoveries=0;
                        if(error.startsWith("Долгая буферизация")||
                           error.startsWith("Соединение нестабильно"))
                            error="";
                    }
                }
                if(state==Player.STATE_ENDED)refillWave();
            }
            @Override public void onPlayerError(androidx.media3.common.PlaybackException ex) {
                cancelBufferingWatchdog();
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
        // Apply the same one-shot Next behavior to notification, headset and car controls.
        androidx.media3.common.ForwardingPlayer remotePlayer =
            new androidx.media3.common.ForwardingPlayer(player) {
                @Override public void seekToNextMediaItem() { requestPreparedNext(); }
                @Override public void seekToNext() { requestPreparedNext(); }
            };
        session = new MediaSession.Builder(this,remotePlayer).setSessionActivity(open)
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
    // Keep the active decoder and seek position intact while changing
    // the order of future media items. Abort any staged handoff first.
    void moveUpcomingTrack(int from,int to) {
        if(player==null)return;
        int current=player.getCurrentMediaItemIndex();
        int count=player.getMediaItemCount();
        if(from<=current||to<=current||from<0||to<0||
           from>=count||to>=count||from==to)return;
        if(to==current+1) {
            Bundle extras=player.getMediaItemAt(from).mediaMetadata.extras;
            if(extras!=null)try{enqueue(new JSONObject(extras.getString("track","{}")),true);}catch(Exception ignored){}
            return;
        }
        cancelPreparedNext();
        failedNext.clear();
        player.moveMediaItem(from,to);
        rebuildQueueArtists();
        persistPlayback(true);
    }

    String enqueueError(){return lastEnqueueError;}

    // Edit the live playlist in place: never reset or seek its current decoder.
    // Manual requests form a FIFO prefix ahead of the remaining source tracks.
    public boolean enqueue(JSONObject rawTrack,boolean next) {
        lastEnqueueError="";
        if(player==null||rawTrack==null){lastEnqueueError="Аудиоплеер ещё запускается.";return false;}
        if(nextPreparing||pendingWaveNext){lastEnqueueError="Дождись переключения трека и добавь ещё раз.";return false;}
        if(pendingStreamRetry!=null){lastEnqueueError="Плеер восстанавливает соединение. Добавь трек после подключения.";return false;}
        try {
            JSONObject track=new JSONObject(rawTrack.toString());
            String id=track.optString("id");
            if(!id.matches("[A-Za-z0-9_-]{1,80}")){lastEnqueueError="Этот трек недоступен.";return false;}
            if(id.equals(activeMediaId())){lastEnqueueError="Этот трек уже играет.";return false;}
            if(player.getMediaItemCount()==0) {
                String base=origin.isEmpty()?"https://music.nightwell.fun/":origin;
                String account=getSharedPreferences("native-api",MODE_PRIVATE).getString("account","");
                prepare(new JSONObject().put("origin",base).put("account",account.isEmpty()?"device":account)
                    .put("id",id).put("queue",new JSONArray().put(track)).toString());
                if(!id.equals(activeMediaId())){lastEnqueueError=error.isEmpty()?"Этот аудиофайл недоступен.":error;return false;}
                // prepare leaves playWhenReady false, including a first queue.
                persistPlayback(true);
                return true;
            }
            ArrayList<String> priorIds=queueIds();
            ManualPlaybackQueue.Edit edit=ManualPlaybackQueue.insert(id,priorIds,
                player.getCurrentMediaItemIndex(),queuedIds,next,1000);
            if(edit==null){lastEnqueueError="Очередь заполнена. Удали лишние треки перед добавлением.";return false;}
            // Resolve/validate before mutating anything, especially offline files.
            MediaSource requested=mediaSource(mediaItem(track,origin));
            java.util.List<String> priorShuffle=shuffleTraversal();
            // ExoPlayer may retain playWhenReady at the end of a source. A
            // playlist insertion must not restart completed playback by itself.
            if(player.getPlaybackState()==Player.STATE_ENDED)player.setPlayWhenReady(false);
            for(int i=player.getMediaItemCount()-1;i>=0;i--)
                if(id.equals(player.getMediaItemAt(i).mediaId))player.removeMediaItem(i);
            int insertion=edit.ids.indexOf(id);
            player.addMediaSource(insertion,requested);
            // Normalize an existing manual prefix without moving the current item.
            for(int target=edit.currentIndex+1;target<edit.ids.size();target++) {
                String desired=edit.ids.get(target);
                if(desired.equals(player.getMediaItemAt(target).mediaId))continue;
                for(int source=target+1;source<player.getMediaItemCount();source++)
                    if(desired.equals(player.getMediaItemAt(source).mediaId)){
                        player.moveMediaItem(source,target);break;
                    }
            }
            queuedIds.clear();queuedIds.addAll(edit.queuedIds);
            rebuildQueueArtists();
            prioritizeQueuedShuffle(priorShuffle);
            audioPrefetchGeneration++;
            if(player.isPlaying())scheduleNextFilePrefetch();
            persistPlayback(true);
            return true;
        }catch(Exception failure){lastEnqueueError="Не удалось добавить трек. Проверь, доступен ли аудиофайл.";return false;}
    }

    private ArrayList<String> queueIds() {
        ArrayList<String> ids=new ArrayList<>();
        for(int i=0;i<player.getMediaItemCount();i++)ids.add(player.getMediaItemAt(i).mediaId);
        return ids;
    }

    private void retainUpcomingQueuedIds() {
        HashSet<String> upcoming=new HashSet<>();
        for(int i=player.getCurrentMediaItemIndex()+1;i<player.getMediaItemCount();i++)
            upcoming.add(player.getMediaItemAt(i).mediaId);
        queuedIds.retainAll(upcoming);
    }

    private void rebuildQueueArtists() {
        ArrayList<String> artists=new ArrayList<>();
        for(int i=0;i<player.getMediaItemCount();i++){
            CharSequence artist=player.getMediaItemAt(i).mediaMetadata.artist;
            artists.add(artist==null?"":artist.toString().toLowerCase(java.util.Locale.ROOT));
        }
        queueArtists=artists;
    }

    private java.util.List<String> shuffleTraversal() {
        ArrayList<String> traversal=new ArrayList<>();
        androidx.media3.common.Timeline timeline=player.getCurrentTimeline();
        int index=timeline.getFirstWindowIndex(true);
        HashSet<Integer> visited=new HashSet<>();
        while(index!=C.INDEX_UNSET&&index>=0&&index<player.getMediaItemCount()&&visited.add(index)){
            traversal.add(player.getMediaItemAt(index).mediaId);
            index=timeline.getNextWindowIndex(index,Player.REPEAT_MODE_OFF,true);
        }
        return traversal;
    }

    private void prioritizeQueuedShuffle(java.util.List<String> priorTraversal) {
        if(!player.getShuffleModeEnabled()||queuedIds.isEmpty()||player.getCurrentMediaItem()==null)return;
        int[] order=ManualPlaybackQueue.shuffleOrder(queueIds(),player.getCurrentMediaItemIndex(),queuedIds,priorTraversal);
        player.setShuffleOrder(new androidx.media3.exoplayer.source.ShuffleOrder.DefaultShuffleOrder(order,System.nanoTime()));
    }
    void prepare(String json) {
        cancelPreparedNext();
        failedNext.clear();
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
            java.util.ArrayList<String> selectedArtists=new java.util.ArrayList<>();
            int selected = -1;
            for (int i=0;i<queue.length() && i<1000;i++) {
                JSONObject track=queue.getJSONObject(i);String trackId=track.getString("id");
                if (!trackId.matches("[A-Za-z0-9_-]+")) continue;
                try {
                    MediaSource source=mediaSource(mediaItem(track,nextOrigin));
                    if (trackId.equals(id)) selected=items.size();
                    items.add(source);
                    selectedArtists.add(track.optString("artist","").toLowerCase(java.util.Locale.ROOT));
                } catch(Exception invalidItem) {
                    // One missing offline file must not invalidate the rest of a playlist.
                    if(trackId.equals(id)) error="Аудиофайл повреждён. Скачай трек повторно.";
                }
            }
            if(selected<0){
                error="Этот аудиофайл недоступен. Открой «Офлайн» и скачай его снова.";
                return;
            }
            waveActive=false;cancelWaveRequest();
            player.stop();player.setPlayWhenReady(false);
            String account=data.optString("account","");
            if(!account.matches("[A-Za-z0-9_-]{1,80}"))account=String.valueOf(NativeAPI.cookie(this,nextOrigin));
            byte[] digest=java.security.MessageDigest.getInstance("SHA-256").digest((nextOrigin+"|"+account).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder scope=new StringBuilder();for(byte value:digest)scope.append(String.format("%02x",value&255));
            cacheScope=scope.toString();origin=nextOrigin;error="";
            boolean nextWave=data.optBoolean("wave",false);
            waveSettings=new WaveSettings(data.optJSONObject("wave_preferences")==null?new JSONObject():data.optJSONObject("wave_preferences"));
            JSONArray seedArtists=data.optJSONArray("wave_seed_artists");
            java.util.List<String> seeds=new java.util.ArrayList<>();
            if(seedArtists!=null)for(int i=0;i<Math.min(5,seedArtists.length());i++){
                String artist=seedArtists.optString(i,"").trim();
                if(!artist.isEmpty()&&artist.length()<100)seeds.add(artist);
            }
            waveSeedArtists=android.text.TextUtils.join(",",seeds);
            if(!waveActive||!nextWave)waveSeen.clear();
            waveActive=nextWave;waveGeneration++;waveLoading=false;waveRetryAt=0;
            if(waveActive){player.setRepeatMode(Player.REPEAT_MODE_OFF);player.setShuffleModeEnabled(false);}
            queuedIds.clear();
            queueArtists=selectedArtists;
            player.setMediaSources(items,selected,Math.max(0,data.optLong("position",0)));
            JSONArray manual=data.optJSONArray("queuedIds");
            if(manual==null)manual=data.optJSONArray("queued_ids");
            if(manual!=null)for(int i=0;i<manual.length();i++)queuedIds.add(manual.optString(i));
            retainUpcomingQueuedIds();
            prioritizeQueuedShuffle(shuffleTraversal());
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
    void pause() { cancelPreparedNext(); cancelStreamRetry(); capturePausePosition(); player.pause(); }
    void stop() { cancelBufferingWatchdog(); cancelPreparedNext(); audioPrefetchGeneration++; pausedPositionMs=-1; lastGoodPositionMs=0; cancelStreamRetry(); retriedTrackId = ""; streamRetryCount = 0; waveActive=false;cancelWaveRequest();waveSeen.clear();queuedIds.clear();player.stop();player.clearMediaItems();
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
    void setEqualVolume(int percent){
        volumeLevelingStrength=Math.max(0,Math.min(100,percent));
        getSharedPreferences("playback",MODE_PRIVATE).edit().putInt("nw-equal-volume",volumeLevelingStrength).apply();
        if(volumeLevelingStrength==0){loudnessAverage=0;loudnessGain=1;}
        updateFade();
    }
    private java.util.List<String> queueArtists = new ArrayList<>();
    private void setSmartShuffleOrder(){
        int count=player.getMediaItemCount();
        if(count<2)return;
        int current=Math.max(0,player.getCurrentMediaItemIndex());
        java.util.ArrayList<Integer> remaining=new java.util.ArrayList<>();
        for(int i=0;i<count;i++)if(i!=current)remaining.add(i);
        int[] order=new int[count];order[0]=current;
        java.util.ArrayDeque<String> artists=new java.util.ArrayDeque<>();
        java.util.Random random=new java.util.Random();
        String last=current<queueArtists.size()?queueArtists.get(current):"";
        artists.addLast(last);
        for(int position=1;position<count;position++){
            int choice=remaining.get(0);
            double best=Double.NEGATIVE_INFINITY;
            for(int candidate:remaining){
                String artist=candidate<queueArtists.size()?queueArtists.get(candidate):"";
                double score=random.nextDouble()*2;
                if(!artist.isEmpty()&&artist.equals(last))score-=4;
                if(!artist.isEmpty()&&artists.contains(artist))score-=1.6;
                if(score>best){best=score;choice=candidate;}
            }
            order[position]=choice;
            remaining.remove(Integer.valueOf(choice));
            last=choice<queueArtists.size()?queueArtists.get(choice):"";
            artists.addLast(last);
            if(artists.size()>5)artists.removeFirst();
        }
        player.setShuffleOrder(new androidx.media3.exoplayer.source.ShuffleOrder.DefaultShuffleOrder(
            order,random.nextLong()));
    }
    void modes(int repeat, boolean shuffle) {
        // Legacy call from cross-device sync and restored playback.
        setShuffleMode(shuffle ? Math.max(1,shuffleMode) : 0);
        setRepeat(repeat);
    }
    void setRepeat(int repeat) {
        player.setRepeatMode(repeat==1&&!waveActive?Player.REPEAT_MODE_ALL:
            repeat==2?Player.REPEAT_MODE_ONE:Player.REPEAT_MODE_OFF);
    }
    void setShuffleMode(int mode) {
        shuffleMode=Math.max(0,Math.min(2,mode));
        getSharedPreferences("playback",MODE_PRIVATE).edit().putInt("nw-shuffle-mode",shuffleMode).apply();
        if(!waveActive&&shuffleMode==2)setSmartShuffleOrder();
        else if(!waveActive&&shuffleMode==1)player.setShuffleOrder(
            new androidx.media3.exoplayer.source.ShuffleOrder.DefaultShuffleOrder(player.getMediaItemCount()));
        player.setShuffleModeEnabled(!waveActive&&shuffleMode!=0);
        prioritizeQueuedShuffle(shuffleTraversal());
    }
    private MediaSource mediaSource(MediaItem item) {
        if(item.localConfiguration!=null && "file".equals(item.localConfiguration.uri.getScheme()))return new DefaultMediaSourceFactory(new androidx.media3.datasource.DefaultDataSource.Factory(this)).createMediaSource(item);

        return item.localConfiguration!=null && MimeTypes.APPLICATION_M3U8.equals(item.localConfiguration.mimeType)
                ? hlsSources.createMediaSource(item) : fileSources.createMediaSource(item);
    }
    private MediaItem mediaItem(JSONObject track,String base) throws Exception {
        NativeAPI.normalizeTrack(track);
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
        String chosenQuality=getSharedPreferences("playback",MODE_PRIVATE)
            .getString("nw-audio-quality","auto");
        String quality=("low".equals(chosenQuality)||"economy".equals(chosenQuality))?
            "economy":("medium".equals(chosenQuality)||"high".equals(chosenQuality))?"high":"auto";
        boolean supported=getSharedPreferences("playback",MODE_PRIVATE)
            .getBoolean("nw-quality-ready",false) &&
            base.equals(getSharedPreferences("playback",MODE_PRIVATE)
                .getString("nw-quality-ready-origin",""));
        boolean soundcloud=track.optString("source").toLowerCase(java.util.Locale.ROOT).contains("soundcloud") ||
            track.optString("source_url").toLowerCase(java.util.Locale.ROOT).contains("soundcloud.com/");
        String stream=(supported&&soundcloud&&("economy".equals(quality)||"high".equals(quality)))?
            base+"api/audio-quality/stream/"+id+"?quality="+quality+"&format=hls":
            base+"api/stream/"+id+"?cache=1&format="+(remote?"hls":"file");
        MediaItem.Builder item=new MediaItem.Builder().setMediaId(id).setUri(stream).setMediaMetadata(metadata.build());
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
        // Maintain a larger cushion: find new recommendations before the
        // listener gets near the last tracks, without fetching audio in bulk.
        if(player.getMediaItemCount()-index-1>16)return;
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
                result=client.search("api/wave?exclude="+query+settingsQuery+"&artists="+URLEncoder.encode(waveSeedArtists.isEmpty()?ArtistTaste.selectedArtists(this):waveSeedArtists,"UTF-8"));
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
                    rebuildQueueArtists();
                    waveRetryAt=System.currentTimeMillis()+30000;
                    if(pendingWaveNext){pendingWaveNext=false;requestPreparedNext();}
                    else if(ended&&continuePlaying){player.seekTo(firstNew,0);player.prepare();player.play();}
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
        try{JSONObject state=new JSONObject(saved);state.put("queue",state.getJSONArray("queueTracks")).put("position",(long)(state.optDouble("position")*1000)).put("origin",base).put("account",account.isEmpty()?"device":account);prepare(state.toString());setRepeat(state.optInt("repeat"));setShuffleMode(state.optInt("shuffleMode",state.optBoolean("shuffle")?1:0));}catch(Exception ignored){}
    }
    private String listenedID="",listenedSession="",listenedArtist="";
    private double listenedSeconds;
    private long listenedAt=android.os.SystemClock.elapsedRealtime(),reportedAt;
    private boolean wasAudible,manualTransition;
    private void tickListening(){
        if(player==null)return;
        long now=android.os.SystemClock.elapsedRealtime();String id=player.getCurrentMediaItem()==null?"":player.getCurrentMediaItem().mediaId;
        if(wasAudible)listenedSeconds+=Math.max(0,Math.min(5,(now-listenedAt)/1000.0));listenedAt=now;
        if(!id.equals(listenedID)){reportListening(manualTransition&&listenedSeconds<30);manualTransition=false;listenedID=id;listenedArtist=player.getCurrentMediaItem()==null?"":String.valueOf(player.getCurrentMediaItem().mediaMetadata.artist);listenedSession=java.util.UUID.randomUUID().toString();listenedSeconds=0;}
        boolean audible=player.isPlaying();if(now-reportedAt>15000||wasAudible&&!audible)reportListening();wasAudible=audible;
    }
    private void reportListening(){reportListening(false);}
    private void reportListening(boolean skipped){
        reportedAt=android.os.SystemClock.elapsedRealtime();if(listenedID.isEmpty()||offlineAccount.isEmpty()||offlineAccount.equals("device")||listenedID.startsWith("local_")||listenedSeconds<=0)return;
        if(skipped&&waveActive&&listenedSeconds>=3&&listenedSeconds<30)
            SkipFeedback.record(this,origin,offlineAccount,listenedID);
        ArtistTaste.learn(this,listenedSession,listenedArtist,listenedSeconds,skipped);
        final String id=listenedID,sid=listenedSession,base=origin;final double seconds=listenedSeconds;
        listeningIO.execute(()->{
            NativeAPI client=new NativeAPI(this,base);
            try{client.request("api/listening","POST",new JSONObject()
                .put("session_id",sid).put("track_id",id)
                .put("seconds",seconds).put("skipped",skipped));
            }catch(Exception ignored){}finally{client.close();}
        });
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
            if(item!=null && player.getPlayWhenReady()) {
                lastGoodPositionMs=Math.max(lastGoodPositionMs,position);
                // Manual seek() resets the anchor, so ordinary backwards seeking
                // is still honored while stale decoder ticks cannot rewind the UI.
                position=Math.max(position,lastGoodPositionMs);
            } else if(item!=null && pausedPositionMs>=0) {
                position=pausedPositionMs;
            }
            state.put("position",position/1000.0);
            state.put("duration",player.getDuration()==C.TIME_UNSET?0:player.getDuration()/1000.0);
            state.put("playing",player.getPlayWhenReady() && player.getPlaybackState()!=Player.STATE_ENDED);
            state.put("nextPreparing",nextPreparing || pendingWaveNext);
            state.put("displayID",nextPreparing&&!pendingNextId.isEmpty()?pendingNextId:
                item==null?"":item.mediaId);
            // Initial bytes have not yet made the staged stream audible.
            state.put("preparationFraction",nextPreparing&&pendingNextPlayer!=null?
                Math.max(0,Math.min(0.99,pendingNextPlayer.getBufferedPercentage()/100.0)):0);
            long durationMs=player.getDuration();
            long bufferedMs=player.getBufferedPosition();
            state.put("bufferFraction",durationMs>0&&durationMs!=C.TIME_UNSET?
                Math.max(0,Math.min(1,bufferedMs/(double)durationMs)):0);
            state.put("buffering",player.getPlaybackState()==Player.STATE_BUFFERING && player.getPlayWhenReady());
            state.put("ended",player.getPlaybackState()==Player.STATE_ENDED);
            state.put("repeat",player.getRepeatMode()==Player.REPEAT_MODE_ALL?1:player.getRepeatMode()==Player.REPEAT_MODE_ONE?2:0);state.put("shuffle",player.getShuffleModeEnabled());state.put("shuffleMode",shuffleMode);
            state.put("error",error);state.put("volume",baseVolume);state.put("smoothTransitions",true);state.put("transitionSeconds",transitionSeconds);
            state.put("wave_preferences",waveSettings.json());
            JSONArray seeds=new JSONArray();
            if(!waveSeedArtists.isEmpty())for(String artist:waveSeedArtists.split(","))seeds.put(artist);
            state.put("wave_seed_artists",seeds);state.put("wave",waveActive);state.put("waveSupported",true);
            JSONArray manual=new JSONArray();
            for(int i=player.getCurrentMediaItemIndex()+1;i<player.getMediaItemCount();i++)
                if(queuedIds.contains(player.getMediaItemAt(i).mediaId))manual.put(player.getMediaItemAt(i).mediaId);
            state.put("queuedIds",manual);
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
        cancelPreparedNext();
        cancelStreamRetry();
        cancelBufferingWatchdog();
        persistPlayback(true);
        waveActive=false;cancelWaveRequest();audioPrefetchGeneration++;
        waveHandler.removeCallbacksAndMessages(null);waveIO.shutdownNow();listeningIO.shutdownNow();audioPrefetchIO.shutdownNow();artworkIO.shutdownNow();
        if(session!=null)session.release();if(player!=null)player.release();if(audioCache!=null)audioCache.release();super.onDestroy();
    }
}



