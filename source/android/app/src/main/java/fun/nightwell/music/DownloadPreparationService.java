package fun.nightwell.music;
import android.app.*;
import android.content.Intent;
import android.os.*;
import org.json.JSONObject;

/** Preparation must also survive Activity suspension, before DownloadManager can
 * receive the final file URL. Stops immediately when the durable queue is empty. */
public final class DownloadPreparationService extends Service {
    private final java.util.concurrent.ExecutorService io=java.util.concurrent.Executors.newSingleThreadExecutor();
    private volatile boolean running,stopping;private PowerManager.WakeLock wake;
    @Override public IBinder onBind(Intent intent){return null;}
    @Override public void onCreate(){super.onCreate();NotificationManager manager=getSystemService(NotificationManager.class);manager.createNotificationChannel(new NotificationChannel("offline-prepare","Загрузка музыки",NotificationManager.IMPORTANCE_LOW));wake=((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"Nightwell:offline");wake.setReferenceCounted(false);}
    @Override public int onStartCommand(Intent intent,int flags,int startId){
        Notification.Builder note=new Notification.Builder(this,"offline-prepare").setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle("Nightwell Music").setContentText("Готовим треки для офлайн-прослушивания").setOngoing(true).setProgress(0,0,true).setContentIntent(PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT));
        startForeground(413,note.build());if(running)return START_STICKY;running=true;wake.acquire(6L*3600*1000);io.execute(()->{
            try{while(running){java.util.Map.Entry<String,String> entry=BackgroundDownloads.nextPreparation(this);if(entry==null)break;try{JSONObject job=new JSONObject(entry.getValue());NativeAPI api=new NativeAPI(this,job.getString("origin"));String id=job.getJSONObject("track").getString("id");boolean ready=false;int errors=0;
                for(int attempt=0;attempt<100&&running;attempt++){
                    try{JSONObject result=api.request("api/offline-export/"+id);String state=result.optString("status");if(state.equals("ready")){ready=true;break;}if(state.equals("error"))throw new IllegalStateException(result.optString("error"));errors=0;}catch(IllegalStateException terminal){throw terminal;}catch(Exception network){if(++errors>=8)throw network;}
                    Thread.sleep(3000);
                }
                if(!running)break;if(!ready)throw new java.io.IOException("Подготовка заняла слишком много времени");BackgroundDownloads.scheduleReady(this,entry.getKey(),job);
            }catch(Exception failure){if(running)BackgroundDownloads.preparationFailed(this,entry.getKey());}}}finally{new Handler(Looper.getMainLooper()).post(()->{running=false;if(stopping)return;if(BackgroundDownloads.nextPreparation(this)!=null){onStartCommand(null,0,startId);}else{stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}});}
        });return START_STICKY;
    }
    @Override public void onTimeout(int startId,int type){stopping=true;running=false;stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
    @Override public void onDestroy(){stopping=true;running=false;io.shutdownNow();if(wake!=null&&wake.isHeld())wake.release();super.onDestroy();}
}
