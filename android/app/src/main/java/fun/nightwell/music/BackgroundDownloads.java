package fun.nightwell.music;

import android.app.DownloadManager;
import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import org.json.*;
import java.io.*;
import java.util.*;

/** The Android system owns network work, connectivity retries and notifications.
 * Metadata remains in private app storage until the result is imported atomically. */
final class BackgroundDownloads {
    private static final String PREFS="native-downloads";
    private static final java.util.concurrent.ExecutorService imports=java.util.concurrent.Executors.newSingleThreadExecutor();
    private static SharedPreferences prefs(Context c){return c.getSharedPreferences(PREFS,Context.MODE_PRIVATE);}
    static void enqueue(Context context,String origin,String account,JSONArray tracks)throws Exception {
        Context c=context.getApplicationContext();DownloadManager manager=(DownloadManager)c.getSystemService(Context.DOWNLOAD_SERVICE);
        synchronized(BackgroundDownloads.class){
            if(prefs(c).getAll().isEmpty())c.getSharedPreferences("native-download-result",Context.MODE_PRIVATE).edit().clear().commit();
            Set<String> existing=new HashSet<>();for(Object raw:prefs(c).getAll().values())if(raw instanceof String)try{JSONObject j=new JSONObject((String)raw);existing.add(j.getString("origin")+"|"+j.getString("account")+"|"+j.getJSONObject("track").getString("id"));}catch(Exception ignored){}
            for(int i=0;i<tracks.length();i++){
                JSONObject track=tracks.optJSONObject(i);if(track==null)continue;String id=track.optString("id"),key=origin+"|"+account+"|"+id;
                if(!id.matches("[A-Za-z0-9_-]{1,80}")||track.optBoolean("_offline")||!existing.add(key)||OfflineStore.audio(c,origin,account,id)!=null)continue;
                JSONObject job=new JSONObject().put("origin",origin).put("account",account).put("track",track);
                if(!prefs(c).edit().putString("prepare."+UUID.randomUUID(),job.toString()).commit())throw new IOException("Не удалось сохранить очередь загрузки");
            }
        }
        c.startForegroundService(new Intent(c,DownloadPreparationService.class));
        reconcile(c);
    }
    static synchronized Map.Entry<String,String> nextPreparation(Context c){for(Map.Entry<String,?> entry:prefs(c).getAll().entrySet())if(entry.getKey().startsWith("prepare.")&&entry.getValue() instanceof String)return new AbstractMap.SimpleImmutableEntry<>(entry.getKey(),(String)entry.getValue());return null;}
    static synchronized void scheduleReady(Context c,String key,JSONObject job)throws Exception {
        String origin=job.getString("origin"),id=job.getJSONObject("track").getString("id");
        DownloadManager manager=(DownloadManager)c.getSystemService(Context.DOWNLOAD_SERVICE);
        DownloadManager.Request request=new DownloadManager.Request(Uri.parse(origin+"api/offline-export/"+id+"?download=true"))
            .setTitle(job.getJSONObject("track").optString("title","Nightwell Music"))
            .setDescription("Сохранение музыки для офлайн-прослушивания")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setAllowedOverMetered(true).setAllowedOverRoaming(false)
            .setDestinationInExternalFilesDir(c,"downloads",UUID.randomUUID()+".m4a")
            .addRequestHeader("Cookie",NativeAPI.cookie(c,origin));
        long download=manager.enqueue(request);
        if(!prefs(c).edit().remove(key).putString(Long.toString(download),job.toString()).commit()){manager.remove(download);throw new IOException("Не удалось сохранить очередь");}
    }
    static synchronized void preparationFailed(Context c,String key){finish(c,key,false);}
    static void reconcile(Context context){Context c=context.getApplicationContext();imports.execute(()->{
        DownloadManager manager=(DownloadManager)c.getSystemService(Context.DOWNLOAD_SERVICE);
        synchronized(BackgroundDownloads.class){
            for(String key:new ArrayList<>(prefs(c).getAll().keySet())){
                long id;try{id=Long.parseLong(key);}catch(Exception e){continue;}
                try(Cursor cursor=manager.query(new DownloadManager.Query().setFilterById(id))){
                    if(cursor==null||!cursor.moveToFirst()){finish(c,key,false);continue;}
                    int state=cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS));
                    if(state==DownloadManager.STATUS_SUCCESSFUL){
                        JSONObject job=new JSONObject(prefs(c).getString(key,"{}"));
                        try(android.os.ParcelFileDescriptor fd=manager.openDownloadedFile(id);InputStream in=new android.os.ParcelFileDescriptor.AutoCloseInputStream(fd)){
                            OfflineStore.saveStream(c,job.getString("origin"),job.getString("account"),job.getJSONObject("track"),in);
                        }
                        finish(c,key,true);manager.remove(id);
                    }else if(state==DownloadManager.STATUS_FAILED){finish(c,key,false);manager.remove(id);}
                }catch(Exception e){finish(c,key,false);manager.remove(id);}
            }
        }
    });}
    private static void finish(Context c,String key,boolean success){prefs(c).edit().remove(key).commit();SharedPreferences p=c.getSharedPreferences("native-download-result",Context.MODE_PRIVATE);p.edit().putInt(success?"added":"failed",p.getInt(success?"added":"failed",0)+1).apply();}
    static String progress(Context c){int pending=prefs(c).getAll().size();SharedPreferences p=c.getSharedPreferences("native-download-result",Context.MODE_PRIVATE);int added=p.getInt("added",0),failed=p.getInt("failed",0);return pending>0?"Загрузка в фоне · осталось: "+pending:added+failed>0?"Скачано: "+added+" · ошибок: "+failed:"";}
    static void completed(Context context,android.content.BroadcastReceiver.PendingResult result){Context c=context.getApplicationContext();reconcile(c);imports.execute(result::finish);}
}
