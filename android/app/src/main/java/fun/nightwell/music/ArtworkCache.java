package fun.nightwell.music;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.LruCache;
import android.widget.ImageView;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Comparator;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Bounded, single-flight memory/disk artwork cache shared by mini and full player. */
final class ArtworkCache {
    private final Context context;
    private final LruCache<String, Bitmap> memory = new LruCache<String, Bitmap>(32 * 1024 * 1024) {
        @Override protected int sizeOf(String key, Bitmap bitmap) { return bitmap.getByteCount(); }
    };
    private final ExecutorService io = Executors.newFixedThreadPool(4);
    private final ConcurrentHashMap<String, CompletableFuture<Bitmap>> inFlight = new ConcurrentHashMap<>();
    // A missing provider cover must not be re-downloaded whenever a ListView
    // recycles its row. Use monotonic time so clock changes cannot extend it.
    private final ConcurrentHashMap<String,Long> retryAfter = new ConcurrentHashMap<>();
    private static final long FAILURE_BACKOFF_MS = 8000;
    private int savedCount;

    private boolean temporarilyUnavailable(String identity) {
        Long until = retryAfter.get(identity);
        if (until == null) return false;
        if (until > android.os.SystemClock.elapsedRealtime()) return true;
        retryAfter.remove(identity,until);
        return false;
    }
    private void markUnavailable(String identity) {
        long now = android.os.SystemClock.elapsedRealtime();
        retryAfter.put(identity,now+FAILURE_BACKOFF_MS);
        if (retryAfter.size()>256) {
            for (java.util.Map.Entry<String,Long> item:retryAfter.entrySet())
                if (item.getValue()<=now) retryAfter.remove(item.getKey(),item.getValue());
            int extra=retryAfter.size()-224;
            if(extra>0)for(String old:retryAfter.keySet()) {
                retryAfter.remove(old);
                if(--extra<=0)break;
            }
        }
    }

    ArtworkCache(Context context) { this.context = context.getApplicationContext(); }
    private boolean valid(String path) { return path != null && path.startsWith("/api/covers/"); }
    private String key(String origin, String path) { return origin + path; }
    /** Resolve track artwork while keeping authenticated cover requests on the server. */
    void loadTrack(ImageView target, String origin, JSONObject track) {
        if (track == null) { load(target, origin, null); return; }
        String raw = track.optString("cover_url", "").trim();
        if (raw.length() <= 2048 && valid(raw)) {
            load(target, origin, raw);
            return;
        }
        if (!raw.isEmpty() && raw.length() <= 2048) {
            try {
                URL url = new URL(raw);
                if ("https".equalsIgnoreCase(url.getProtocol()) && url.getUserInfo() == null
                        && !url.getHost().isEmpty()) {
                    if (ServerAddress.sameOrigin(origin, url.toString()) && valid(url.getPath()))
                        load(target, origin, url.getFile());
                    else
                        loadArtist(target, url.toExternalForm()); // Public HTTPS art carries no session cookie.
                    return;
                }
            } catch (Exception ignored) {}
        }
        String id = track.optString("id", "");
        boolean remote = ArtistAttribution.isRemote(track.optString("source", ""),
            track.optString("source_url", ""), track.optBoolean("is_remote", false));
        load(target, origin, remote && id.matches("[A-Za-z0-9_-]{1,160}")
            ? "/api/covers/" + id : null);
    }
    /** Bind playlist and queue artwork from either a server path or an HTTPS URL. */
    void loadCoverUrl(ImageView target, String origin, String raw) {
        if (raw == null || raw.length() > 2048) {
            load(target, origin, null);
            return;
        }
        String value = raw.trim();
        if (valid(value)) {
            load(target, origin, value);
            return;
        }
        try {
            URL url = new URL(value);
            if ("https".equalsIgnoreCase(url.getProtocol())
                    && url.getUserInfo() == null && !url.getHost().isEmpty()) {
                if (ServerAddress.sameOrigin(origin, url.toExternalForm()) && valid(url.getPath()))
                    load(target, origin, url.getFile());
                else
                    loadArtist(target, url.toExternalForm());
                return;
            }
        } catch (Exception ignored) {}
        load(target, origin, null);
    }

    void load(ImageView target, String origin, String path) {
        if (!valid(path)) { target.setTag(null); target.setImageDrawable(null); return; }
        String identity = key(origin,path);
        if(identity.equals(target.getTag())&&target.getDrawable()!=null)return;
        if(!identity.equals(target.getTag()))target.setImageDrawable(null);
        target.setTag(identity);
        Bitmap cached = memory.get(identity);
        if (cached != null) { target.setImageBitmap(cached); return; }
        if (temporarilyUnavailable(identity)) return;
        CompletableFuture<Bitmap> job = request(origin,path);
        job.thenAccept(bitmap -> {
            if (bitmap == null) return;
            target.post(() -> {
                if (identity.equals(target.getTag()) && target.isAttachedToWindow())
                    target.setImageBitmap(bitmap);
            });
        });
    }
    void prefetch(String origin, String path) {
        if (valid(path) && memory.get(key(origin,path)) == null) request(origin,path);
    }
    private CompletableFuture<Bitmap> request(String origin, String path) {
        String identity = key(origin,path);
        if (temporarilyUnavailable(identity)) return CompletableFuture.completedFuture(null);
        CompletableFuture<Bitmap> job = inFlight.computeIfAbsent(identity,
            k -> CompletableFuture.supplyAsync(() -> decodeAndFetch(origin,path,identity),io));
        job.whenComplete((result,error) -> {
            inFlight.remove(identity,job);
            if (error != null || result == null) markUnavailable(identity);
            else retryAfter.remove(identity);
        });
        return job;
    }
    private Bitmap decodeAndFetch(String origin, String path, String identity) {
        File folder = new File(context.getCacheDir(),"nightwell-covers-v1");
        File saved = new File(folder,digest(identity)+".image");
        try {
            if (saved.isFile() && saved.length() <= 5 * 1024 * 1024 &&
                System.currentTimeMillis()-saved.lastModified() < 45L*24*60*60*1000) {
                Bitmap bitmap = decode(java.nio.file.Files.readAllBytes(saved.toPath()));
                if (bitmap != null) { memory.put(identity,bitmap); return bitmap; }
            }
            URL url = new URL(new URL(origin),path);
            if (!ServerAddress.sameOrigin(origin,url.toString())) return null;
            HttpURLConnection c = (HttpURLConnection)url.openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(8000);c.setReadTimeout(12000);
            c.setRequestProperty("Cookie",NativeAPI.cookie(context,origin));
            byte[] bytes;
            try {
                if (c.getResponseCode()!=200 || c.getContentLengthLong()>5*1024*1024) return null;
                String type=c.getContentType();
                if (type!=null&&!type.toLowerCase(java.util.Locale.ROOT).startsWith("image/"))return null;
                bytes=NativeAPI.read(c.getInputStream(),5*1024*1024);
            } finally { c.disconnect(); }
            Bitmap bitmap=decode(bytes);
            if (bitmap==null)return null;
            memory.put(identity,bitmap);
            if (folder.exists() || folder.mkdirs()) {
                File tmp = new File(folder,digest(identity)+"."+java.util.UUID.randomUUID()+".tmp");
                try (FileOutputStream out=new FileOutputStream(tmp)) {out.write(bytes);}
                if (!tmp.renameTo(saved)) tmp.delete();
                if (++savedCount%20==0) prune(folder);
            }
            return bitmap;
        } catch (Exception ignored) {
            try {
                if (saved.isFile()&&saved.length()<=5*1024*1024) {
                    Bitmap bitmap=decode(java.nio.file.Files.readAllBytes(saved.toPath()));
                    if(bitmap!=null)memory.put(identity,bitmap);
                    return bitmap;
                }
            } catch (Exception ignoredToo) {}
            return null;
        }
    }
    private static Bitmap decode(byte[] data) {
        BitmapFactory.Options options=new BitmapFactory.Options();
        options.inJustDecodeBounds=true;
        BitmapFactory.decodeByteArray(data,0,data.length,options);
        if (options.outWidth<=0||options.outHeight<=0)return null;
        int largest=Math.max(options.outWidth,options.outHeight),sample=1;
        while(largest/sample>900)sample*=2;
        options.inJustDecodeBounds=false;
        options.inSampleSize=sample;
        return BitmapFactory.decodeByteArray(data,0,data.length,options);
    }
    private static String digest(String value) {
        try {
            byte[] bytes=MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder result=new StringBuilder();
            for (byte b:bytes) result.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
            return result.toString();
        } catch(Exception ignored){return Integer.toHexString(value.hashCode());}
    }
    private static void prune(File folder) {
        File[] files=folder.listFiles((dir,name)->name.endsWith(".image"));
        if(files==null||files.length<120)return;
        Arrays.sort(files,Comparator.comparingLong(File::lastModified));
        for(int i=0;i<files.length-100;i++)files[i].delete();
    }
    /** Load public HTTPS artwork without attaching the Nightwell session cookie. */
    void loadArtist(ImageView target, String imageUrl) {
        if (imageUrl == null || imageUrl.length() > 2048 || !imageUrl.startsWith("https://")) {
            target.setTag(null);
            target.setImageDrawable(null);
            return;
        }
        String identity = "artist|" + imageUrl;
        if(identity.equals(target.getTag())&&target.getDrawable()!=null)return;
        if(!identity.equals(target.getTag()))target.setImageDrawable(null);
        target.setTag(identity);
        Bitmap cached = memory.get(identity);
        if (cached != null) {
            target.setImageBitmap(cached);
            return;
        }
        if (temporarilyUnavailable(identity)) return;
        CompletableFuture<Bitmap> job = inFlight.computeIfAbsent(identity,
            key -> CompletableFuture.supplyAsync(() -> fetchArtistImage(imageUrl), io));
        job.whenComplete((bitmap, error) -> {
            inFlight.remove(identity, job);
            if (bitmap == null || error != null) {
                markUnavailable(identity);
                return;
            }
            retryAfter.remove(identity);
            target.post(() -> {
                if (identity.equals(target.getTag()) && target.isAttachedToWindow())
                    target.setImageBitmap(bitmap);
            });
        });
    }
    private Bitmap fetchArtistImage(String address) {
        HttpURLConnection connection = null;
        try {
            URL url = new URL(address);
            if (!"https".equalsIgnoreCase(url.getProtocol()) || url.getUserInfo() != null) return null;
            connection = (HttpURLConnection)url.openConnection();
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(6000);
            connection.setReadTimeout(8000);
            if (connection.getResponseCode() != 200 ||
                    connection.getContentLengthLong() > 5 * 1024 * 1024) return null;
            String type = connection.getContentType();
            if (type == null || !type.toLowerCase(java.util.Locale.ROOT).startsWith("image/")) return null;
            Bitmap bitmap = decode(NativeAPI.read(connection.getInputStream(), 5 * 1024 * 1024));
            if (bitmap != null) memory.put("artist|" + address, bitmap);
            return bitmap;
        } catch (Exception ignored) { return null; }
        finally { if (connection != null) connection.disconnect(); }
    }
    void close() { io.shutdownNow(); inFlight.clear(); retryAfter.clear(); memory.evictAll(); }
}
