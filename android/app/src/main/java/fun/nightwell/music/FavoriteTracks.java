package fun.nightwell.music;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * User-specific favorite order and track metadata.
 *
 * /api/likes returns track IDs, while /api/tracks is a partial catalog.
 * A liked result from Search, Wave or the player must therefore remain
 * displayable even when it is absent from that catalog.
 *
 * Call on the Android UI thread; persistence is owned by MainActivity.
 */
final class FavoriteTracks {
    private final ArrayList<String> order = new ArrayList<>();
    private final LinkedHashMap<String,JSONObject> details = new LinkedHashMap<>();

    void clear() {
        order.clear();
        details.clear();
    }

    private static boolean validId(String id) {
        return id!=null && !id.isEmpty();
    }

    private static boolean useful(JSONObject item) {
        return item!=null && validId(item.optString("id"))
            && !item.optBoolean("_favoriteMissing")
            && !item.optString("title").trim().isEmpty();
    }

    void remember(JSONObject item) {
        if(!useful(item))return;
        String id=item.optString("id");
        // Copy the record: later queue mutations must not alter saved metadata.
        try{
            details.put(id,new JSONObject(item.toString()));
        }catch(Exception ignored){}
    }

    void rememberLiked(JSONArray items,Set<String> likes) {
        if(items==null||likes==null)return;
        for(int i=0;i<items.length();i++){
            JSONObject item=items.optJSONObject(i);
            if(item!=null && likes.contains(item.optString("id")))
                remember(item);
        }
    }

    boolean hasMetadata(String id) {
        return validId(id) && useful(details.get(id));
    }

    int missingCount(Set<String> liked) {
        if(liked==null)return 0;
        int count=0;
        for(String id:liked)if(!hasMetadata(id))count++;
        return count;
    }

    int rememberLikedAndCount(JSONArray items,Set<String> likes) {
        if(items==null||likes==null)return 0;
        int added=0;
        for(int i=0;i<items.length();i++){
            JSONObject item=items.optJSONObject(i);
            if(item==null)continue;
            String id=item.optString("id");
            if(!likes.contains(id)||!useful(item))continue;
            boolean missing=!hasMetadata(id);
            remember(item);
            if(missing)added++;
        }
        return added;
    }

    void remove(String id) {
        if(!validId(id))return;
        order.remove(id);
        details.remove(id);
    }

    void promote(String id) {
        if(!validId(id))return;
        order.remove(id);
        order.add(0,id);
    }

    void restore(JSONObject saved) {
        clear();
        if(saved==null)return;
        JSONArray ids=saved.optJSONArray("order");
        if(ids!=null && saved.optInt("orderVersion",0)>=2){
            HashSet<String> unique=new HashSet<>();
            for(int i=0;i<ids.length();i++){
                String id=ids.optString(i);
                if(validId(id)&&unique.add(id))order.add(id);
            }
        }
        JSONArray tracks=saved.optJSONArray("tracks");
        if(tracks!=null){
            for(int i=0;i<tracks.length();i++)
                remember(tracks.optJSONObject(i));
        }
    }

    JSONArray orderIds(Set<String> liked){
        JSONArray array=new JSONArray();
        HashSet<String> seen=new HashSet<>();
        for(String id:order){
            if(liked.contains(id)&&seen.add(id))array.put(id);
        }
        ArrayList<String> extras=new ArrayList<>();
        for(String id:liked)if(seen.add(id))extras.add(id);
        Collections.sort(extras);
        for(String id:extras)array.put(id);
        return array;
    }

    JSONObject snapshot(int maxTracks) {
        JSONObject result=new JSONObject();
        JSONArray ids=new JSONArray();
        JSONArray tracks=new JSONArray();
        for(String id:order)ids.put(id);
        int count=0;
        if(maxTracks>0)for(String id:order){
            JSONObject item=details.get(id);
            if(item==null)continue;
            tracks.put(item);
            if(++count>=maxTracks)break;
        }
        try{
            result.put("order",ids);
            result.put("orderVersion",2);
            result.put("tracks",tracks);
        }catch(Exception ignored){}
        return result;
    }

    void reconcile(Set<String> liked,JSONArray serverIds,String newest) {
        if(liked==null) {clear();return;}
        ArrayList<String> updated=new ArrayList<>();
        HashSet<String> used=new HashSet<>();
        for(String id:order) {
            if(liked.contains(id)&&used.add(id))updated.add(id);
        }
        // The legacy API returns IDs in insertion order, oldest to newest.
        // Rebuild the missing local chronology after reinstall, newest first.
        if(serverIds!=null)for(int i=serverIds.length()-1;i>=0;i--){
            String id=serverIds.optString(i);
            if(liked.contains(id)&&used.add(id))updated.add(id);
        }
        ArrayList<String> missing=new ArrayList<>();
        for(String id:liked)if(used.add(id))missing.add(id);
        Collections.sort(missing);
        updated.addAll(missing);
        if(validId(newest)&&liked.contains(newest)){
            updated.remove(newest);updated.add(0,newest);
        }
        order.clear();
        order.addAll(updated);
        details.keySet().retainAll(liked);
    }

    private static void addSource(Map<String,JSONObject> byId,JSONArray items,Set<String> likes) {
        if(items==null)return;
        for(int i=0;i<items.length();i++){
            JSONObject item=items.optJSONObject(i);
            if(useful(item)&&likes.contains(item.optString("id")))
                byId.put(item.optString("id"),item);
        }
    }

    JSONArray visible(Set<String> liked,JSONArray catalog,JSONArray queue,JSONArray extras) {
        JSONArray visible=new JSONArray();
        if(liked==null||liked.isEmpty())return visible;
        Map<String,JSONObject> byId=new HashMap<>();
        for(Map.Entry<String,JSONObject> entry:details.entrySet())
            if(liked.contains(entry.getKey())&&useful(entry.getValue()))
                byId.put(entry.getKey(),entry.getValue());
        addSource(byId,catalog,liked);
        addSource(byId,queue,liked);
        addSource(byId,extras,liked);
        HashSet<String> included=new HashSet<>();
        for(String id:order) {
            if(!liked.contains(id)||!included.add(id))continue;
            visible.put(trackOrPlaceholder(id,byId.get(id)));
        }
        // IDs which arrived before a local order was restored.
        ArrayList<String> rest=new ArrayList<>();
        for(String id:liked)if(included.add(id))rest.add(id);
        Collections.sort(rest);
        for(String id:rest)visible.put(trackOrPlaceholder(id,byId.get(id)));
        return visible;
    }

    private static JSONObject trackOrPlaceholder(String id,JSONObject item) {
        if(useful(item))return item;
        JSONObject placeholder=new JSONObject();
        try{
            placeholder.put("id",id);
            placeholder.put("title","Трек из избранного");
            placeholder.put("artist","Загружаем сведения");
            placeholder.put("_favoriteMissing",true);
        }catch(Exception ignored){}
        return placeholder;
    }

    List<String> unresolved(Set<String> liked,JSONArray catalog,JSONArray queue,int count) {
        JSONArray displayed=visible(liked,catalog,queue,null);
        ArrayList<String> missing=new ArrayList<>();
        for(int i=0;i<displayed.length()&&missing.size()<count;i++){
            JSONObject item=displayed.optJSONObject(i);
            if(item!=null&&item.optBoolean("_favoriteMissing")){
                String id=item.optString("id");
                if(id.matches("[A-Za-z0-9_-]{4,160}"))missing.add(id);
            }
        }
        return missing;
    }
}
