package fun.nightwell.music;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.*;

/** Per-account 14-day history. Keeps audio uploads with different IDs from repeating. */
final class DiscoveryHistory {
    private DiscoveryHistory() {}
    private static final long WINDOW = 14L * 24 * 60 * 60 * 1000;
    private static final int MAX = 1600;
    private static String scope(String origin, String account) {
        return origin + "|" + (account == null || account.isEmpty() ? "device" : account);
    }
    static String recording(String title, String artist) {
        String song = title == null ? "" : title.trim();
        String performer = artist == null ? "" : artist;
        JSONObject pseudo = new JSONObject();
        try { pseudo.put("title", song); } catch (Exception ignored) {}
        String fromTitle = ArtistIdentity.fromTitle(pseudo);
        if (!fromTitle.isEmpty()) {
            performer = fromTitle;
            for (String separator : new String[] {" - ", " – ", " — "}) {
                int cut = song.indexOf(separator);
                if (cut >= 0) { song = song.substring(cut + separator.length()); break; }
            }
        }
        song = song.replaceAll("(?i)\\s*[\\[(](?:official\\s+(?:audio|video)|lyrics?|visuali[sz]er|4k|hd|music\\s+video)[\\])]","").trim();
        return RecommendationOrder.key(performer) + "|" + RecommendationOrder.key(song);
    }
    private static JSONArray read(Context context, String origin, String account) {
        SharedPreferences prefs = context.getSharedPreferences("discovery-history-v2", Context.MODE_PRIVATE);
        JSONArray raw;
        try { raw = new JSONArray(prefs.getString(scope(origin,account),"[]")); }
        catch (Exception ex) { raw = new JSONArray(); }
        long now = System.currentTimeMillis();
        JSONArray retained = new JSONArray();
        for (int i = Math.max(0,raw.length() - MAX); i < raw.length(); i++) {
            JSONObject item = raw.optJSONObject(i);
            if (item == null) continue;
            long timestamp = item.optLong("at",0);
            if (timestamp >= now-WINDOW && timestamp <= now+300000) retained.put(item);
        }
        return retained;
    }
    static void remember(Context context, String origin, String account, String id, String title, String artist) {
        if (id == null || id.isEmpty()) return;
        String signature = recording(title,artist);
        JSONArray prior = read(context, origin, account), updated = new JSONArray();
        for (int i = 0; i < prior.length(); i++) {
            JSONObject entry = prior.optJSONObject(i);
            if (entry != null && !id.equals(entry.optString("id")) &&
                ("|".equals(signature) || !signature.equals(entry.optString("sig"))))
                updated.put(entry);
        }
        try {
            updated.put(new JSONObject().put("id",id).put("sig",signature).put("at",System.currentTimeMillis()));
            JSONArray output = new JSONArray();
            for (int i = Math.max(0,updated.length()-MAX); i < updated.length(); i++)
                output.put(updated.optJSONObject(i));
            context.getSharedPreferences("discovery-history-v2",Context.MODE_PRIVATE)
                .edit().putString(scope(origin,account),output.toString()).apply();
        } catch (Exception ignored) {}
    }
    static Set<String> ids(Context context,String origin,String account) {
        JSONArray list = read(context,origin,account);
        Set<String> result = new HashSet<>();
        for (int i=0; i<list.length();i++) result.add(list.optJSONObject(i).optString("id"));
        return result;
    }
    static Set<String> recordings(Context context,String origin,String account) {
        JSONArray list = read(context,origin,account);
        Set<String> result = new HashSet<>();
        for (int i=0; i<list.length();i++) result.add(list.optJSONObject(i).optString("sig"));
        return result;
    }
    static List<String> excludedIDs(Context context,String origin,String account,int maximum) {
        JSONArray history = read(context,origin,account);
        ArrayList<String> result=new ArrayList<>();
        for (int i=history.length()-1;i>=0 && result.size()<maximum;i--) {
            String id=history.optJSONObject(i).optString("id");
            if (!id.isEmpty()) result.add(id);
        }
        return result;
    }
}
