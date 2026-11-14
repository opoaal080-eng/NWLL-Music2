package fun.nightwell.music;
import android.content.Context;
import org.json.*;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

final class NativeAPI {
    final Context context;
    final String origin;
    volatile String csrf="";
    private HttpURLConnection activeSearch;
    private long searchGeneration;
    // Disconnect may block on an underlying socket. Never do that on Android's UI thread.
    private static final java.util.concurrent.ExecutorService SEARCH_CANCEL_IO =
        java.util.concurrent.Executors.newSingleThreadExecutor(r -> {
            Thread worker = new Thread(r, "NightwellSearchCancel");
            worker.setDaemon(true);
            return worker;
        });
    private volatile boolean closed;
    private final java.util.Set<HttpURLConnection> activeConnections=java.util.Collections.newSetFromMap(new java.util.WeakHashMap<>());
    NativeAPI(Context context,String origin){this.context=context.getApplicationContext();this.origin=origin;csrf=this.context.getSharedPreferences("native-api",Context.MODE_PRIVATE).getString("csrf|"+origin,"");}
    void updateCSRF(String value){csrf=value;context.getSharedPreferences("native-api",Context.MODE_PRIVATE).edit().putString("csrf|"+origin,value).apply();}
    /** Pseudonymous Android signing-key-scoped device ID, stable after reinstall. */
    static String deviceID(Context context){
        String androidID=android.provider.Settings.Secure.getString(
            context.getContentResolver(),android.provider.Settings.Secure.ANDROID_ID);
        if(androidID==null||androidID.trim().isEmpty()){
            android.content.SharedPreferences prefs=context.getSharedPreferences("nw-device",Context.MODE_PRIVATE);
            String saved=prefs.getString("id","");
            if(saved.matches("android_[0-9a-f]{32}"))return saved;
            saved="android_"+java.util.UUID.randomUUID().toString().replace("-","");
            prefs.edit().putString("id",saved).apply();
            return saved;
        }
        try{
            byte[] hash=java.security.MessageDigest.getInstance("SHA-256")
                .digest(("nightwell-account-device-v1:"+androidID+":"+context.getPackageName())
                    .getBytes(StandardCharsets.UTF_8));
            StringBuilder result=new StringBuilder("android_");
            for(int i=0;i<16;i++)result.append(String.format(java.util.Locale.ROOT,"%02x",hash[i]&0xff));
            return result.toString();
        }catch(Exception e){return "android_"+java.util.UUID.randomUUID().toString().replace("-");}
    }
    static String deviceLabel(){
        return (android.os.Build.MANUFACTURER+" "+android.os.Build.MODEL).trim();
    }
    static String cookie(Context context,String origin){String value=new SessionStore(context).restore(origin);String token=SessionStore.token(value);return token==null?"":"nw_session="+token;}
    JSONObject uploadSupportAttachment(String ticketId,String name,byte[] data) throws Exception {
        if(data.length==0||data.length>10*1024*1024)throw new IOException("Максимум 10 МБ");
        String boundary="NW"+java.util.UUID.randomUUID().toString().replace("-","");
        HttpURLConnection c=connection("api/support/tickets/"+ticketId+"/attachments");
        try{
            c.setRequestMethod("POST");c.setDoOutput(true);
            c.setRequestProperty("X-CSRF-Token",csrf);
            c.setRequestProperty("Content-Type","multipart/form-data; boundary="+boundary);
            String safe=name.replace('"','_').replace('\r','_').replace('\n','_');
            byte[] head=("--"+boundary+"\r\nContent-Disposition: form-data; name=\"file\"; filename=\""+safe+"\"\r\nContent-Type: application/octet-stream\r\n\r\n").getBytes(StandardCharsets.UTF_8);
            byte[] tail=("\r\n--"+boundary+"--\r\n").getBytes(StandardCharsets.UTF_8);
            c.setFixedLengthStreamingMode(head.length+data.length+tail.length);
            try(OutputStream out=c.getOutputStream()){out.write(head);out.write(data);out.write(tail);}
            return response(c);
        }finally{c.disconnect();}
    }
    byte[] downloadSupportAttachment(String ticketId,String attachmentId) throws Exception {
        HttpURLConnection c=connection("api/support/tickets/"+ticketId+"/attachments/"+attachmentId);
        try {
            if(c.getResponseCode()!=200)throw new IOException("Файл недоступен: HTTP "+c.getResponseCode());
            return read(c.getInputStream(),10*1024*1024+1);
        } finally { c.disconnect(); }
    }
    JSONObject request(String path) throws Exception{return request(path,"GET",null);}
    void close(){
        HttpURLConnection[] pending;
        synchronized(activeConnections){closed=true;pending=activeConnections.toArray(new HttpURLConnection[0]);activeConnections.clear();}
        cancelSearch();
        // Closing a socket can block inside Android's HTTP stack.
        // Mark the client closed immediately; disconnect off the UI thread.
        SEARCH_CANCEL_IO.execute(()->{
            for(HttpURLConnection connection:pending){
                try{connection.disconnect();}catch(Exception ignored){}
            }
        });
    }
    synchronized void cancelSearch(){
        searchGeneration++;
        HttpURLConnection value=activeSearch;
        activeSearch=null;
        if(value!=null)SEARCH_CANCEL_IO.execute(value::disconnect);
    }
    private synchronized boolean searchCancelled(long generation){return closed||searchGeneration!=generation;}
    JSONObject search(String path)throws Exception {
        final long generation;
        synchronized(this){generation=searchGeneration;}
        return NetworkRetry.run(true,()->searchCancelled(generation),()->{
            HttpURLConnection c=connection(path);
            synchronized(this){if(closed||searchGeneration!=generation){c.disconnect();throw new InterruptedIOException("Поиск отменён");}activeSearch=c;}
            try{return response(c);}
            finally{synchronized(this){if(activeSearch==c)activeSearch=null;}c.disconnect();}
        });
    }
    JSONObject request(String path,String method,JSONObject body) throws Exception {
        return NetworkRetry.run(method.equals("GET"),()->closed,()->requestOnce(path,method,body));
    }
    private JSONObject requestOnce(String path,String method,JSONObject body) throws Exception {
        HttpURLConnection c=connection(path);
        try {
            c.setRequestMethod(method);
            if(!method.equals("GET")){byte[] bytes=(body==null?"{}":body.toString()).getBytes(StandardCharsets.UTF_8);c.setRequestProperty("X-CSRF-Token",csrf);c.setRequestProperty("Content-Type","application/json");c.setFixedLengthStreamingMode(bytes.length);c.setDoOutput(true);try(OutputStream out=c.getOutputStream()){out.write(bytes);}}
            JSONObject value=response(c);
            if(path.equals("api/login")||path.equals("api/register")){
                boolean found=false;
                java.util.Map<String,java.util.List<String>> headers=c.getHeaderFields();
                for(java.util.Map.Entry<String,java.util.List<String>> header:headers.entrySet()){
                    if(header.getKey()==null||!header.getKey().equalsIgnoreCase("Set-Cookie"))continue;
                    for(String entry:header.getValue()){
                        if(SessionStore.token(entry)==null)continue;
                        found=true;
                        new SessionStore(context).save(origin,entry);
                    }
                }
                if(!found)throw new IOException("В ответе сервера нет подходящего cookie nw_session. Проверь формат Set-Cookie.");
                if(cookie(context,origin).isEmpty())throw new IOException("Cookie получен, но Android не сохранил сессию. Проверь Android Keystore.");
            }
            return value;
        }finally{c.disconnect();}
    }
    private JSONObject response(HttpURLConnection c)throws Exception {
        int code=c.getResponseCode();
        if(code>=400){
            String message="Ошибка сервера: "+code;
            try{message=new JSONObject(new String(read(c.getErrorStream(),4*1024*1024),StandardCharsets.UTF_8)).optString("error",message);}
            catch(Exception ignored){} // HTML/empty error bodies must retain the HTTP status.
            throw new NetworkRetry.HttpFailure(code,message);
        }
        if(code==204||code==205||c.getContentLengthLong()==0)return new JSONObject();
        int limit=c.getURL().getPath().equals("/api/tracks")?32*1024*1024:4*1024*1024;
        byte[] bytes=read(c.getInputStream(),limit);
        if(bytes.length==0)return new JSONObject();
        JSONObject payload=new JSONObject(new String(bytes,StandardCharsets.UTF_8));
        normalizeArtistCredits(payload);
        return payload;
    }
    /** Normalize only known track-shaped JSON, not artist-directory/user objects. */
    static void normalizeArtistCredits(JSONObject payload) {
        if(payload==null)return;
        normalizeTrack(payload);
        String[] arrays={"tracks","queue","items","playlists","recommendations"};
        for(String name:arrays){
            JSONArray list=payload.optJSONArray(name);
            if(list==null)continue;
            for(int i=0;i<Math.min(5000,list.length());i++){
                JSONObject item=list.optJSONObject(i);
                if(item!=null)normalizeArtistCredits(item);
            }
        }
        String[] objects={"track","current","playlist"};
        for(String key:objects){
            JSONObject item=payload.optJSONObject(key);
            if(item!=null)normalizeArtistCredits(item);
        }
    }

    static void normalizeTrack(JSONObject track) {
        if(track==null||!track.has("id")||!track.has("title")||!track.has("artist")||
                track.optBoolean("_artist_checked",false))return;
        String source=track.optString("source"),sourceURL=track.optString("source_url");
        boolean remote=ArtistAttribution.isRemote(
            source,sourceURL,track.optBoolean("is_remote",false));
        if(!remote)return;
        ArtistAttribution.Result credit=ArtistAttribution.resolve(
            track.optString("title"),track.optString("artist"),source,sourceURL,remote,
            track.optString("metadata_artist").isEmpty()?track.optString("performer"):track.optString("metadata_artist"),
            track.optString("artist_credit"));
        try {
            track.put("title",credit.title);
            track.put("artist",credit.artist);
            if(credit.uploader!=null&&!track.has("uploader"))
                track.put("uploader",credit.uploader);
            track.put("_artist_checked",true);
        }catch(JSONException ignored){}
    }

    HttpURLConnection connection(String path) throws Exception {
        if(closed)throw new InterruptedIOException("Запрос отменён");
        URL url=new URL(new URL(origin),path);if(!ServerAddress.sameOrigin(origin,url.toString()))throw new IOException("Некорректный адрес");
        HttpURLConnection c=(HttpURLConnection)url.openConnection();c.setInstanceFollowRedirects(false);c.setConnectTimeout(7000);c.setReadTimeout(10000);c.setRequestProperty("Cookie",cookie(context,origin));c.setRequestProperty("X-NW-Device-ID",deviceID(context));c.setRequestProperty("X-NW-Device-Platform","android");
        synchronized(activeConnections){if(closed){c.disconnect();throw new InterruptedIOException("Запрос отменён");}activeConnections.add(c);}
        return c;
    }
    byte[] export(String id)throws Exception{HttpURLConnection c=connection("api/offline-export/"+id);c.setReadTimeout(180000);try{if(c.getResponseCode()!=200)throw new IOException("Не удалось скачать трек");return read(c.getInputStream(),OfflineStore.LIMIT);}finally{c.disconnect();}}
    static byte[] read(InputStream input,int limit)throws Exception{if(input==null)throw new IOException("Пустой ответ сервера");try(InputStream in=input;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[16384];int count;while((count=in.read(b))!=-1){if(out.size()+count>limit)throw new IOException("Слишком большой файл");out.write(b,0,count);}return out.toByteArray();}}
}


