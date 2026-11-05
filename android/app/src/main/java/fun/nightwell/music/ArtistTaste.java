package fun.nightwell.music;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Small, bounded online ranking model. No TensorFlow, network calls or GPU. */
final class ArtistTaste {
    private static final String PREFS = "nw-artist-taste-v1";
    private static final Map<String,Double> weights = new HashMap<>();
    private static boolean loaded;
    private ArtistTaste() {}
    static synchronized void load(Context context) {
        if(loaded) return;
        loaded = true;
        try {
            JSONObject value = new JSONObject(context.getSharedPreferences(PREFS,0).getString("weights","{}"));
            for(java.util.Iterator<String> it=value.keys();it.hasNext();) {
                String key=it.next();
                double weight=value.optDouble(key,0);
                if(Double.isFinite(weight)) weights.put(key,Math.max(-2,Math.min(3,weight)));
            }
        } catch(Exception ignored) {}
    }
    static synchronized void seed(Context context, java.util.Set<String> artists, String mood) {
        load(context);
        List<String> originals = new ArrayList<>();
        for(String artist:artists) {
            if(artist==null||artist.trim().isEmpty())continue;
            originals.add(artist.trim());
            weights.put(RecommendationOrder.key(artist),Math.max(1.9,weights.getOrDefault(RecommendationOrder.key(artist),0.0)));
            if(originals.size() >= 20)break;
        }
        Collections.sort(originals);
        context.getSharedPreferences(PREFS,0).edit()
            .putString("selected",new JSONArray(originals).toString())
            .putString("mood",mood)
            .apply();
        WaveSettings wave=WaveSettings.read(context,"https://music.nightwell.fun/","device");
        for(int i=0;i<WaveSettings.VALUES[1].length;i++)
            if(WaveSettings.VALUES[1][i].equals(mood)) wave.selected[1]=i;
        wave.save(context,"https://music.nightwell.fun/","device");
        save(context);
    }
    static synchronized double weight(String artist) {
        return weights.getOrDefault(RecommendationOrder.key(artist),0.0);
    }
    static synchronized String selectedArtists(Context context) {
        try {
            JSONArray names=new JSONArray(context.getSharedPreferences(PREFS,0).getString("selected","[]"));
            ArrayList<String> artists=new ArrayList<>();
            for(int i=0;i<Math.min(20,names.length());i++) artists.add(names.optString(i));
            return android.text.TextUtils.join(",",artists);
        } catch(Exception ignored){return "";}
    }
    static synchronized void learn(Context context,String session,String artist,double seconds,boolean skipped) {
        load(context);
        String key=RecommendationOrder.key(artist);
        if(session==null||session.isEmpty()||key.isEmpty()||!Double.isFinite(seconds))return;
        double delta=skipped&&seconds<30 ? -0.95 : seconds>=60 ? 0.45 : seconds>=30 ? 0.24 : 0;
        if(delta==0)return;
        SharedPreferences prefs=context.getSharedPreferences(PREFS,0);
        try {
            JSONArray sessions=new JSONArray(prefs.getString("sessions","[]"));
            for(int i=0;i<sessions.length();i++)if(session.equals(sessions.optString(i)))return;
            JSONArray recent=new JSONArray();
            for(int i=Math.max(0,sessions.length()-158);i<sessions.length();i++)recent.put(sessions.optString(i));
            recent.put(session);
            prefs.edit().putString("sessions",recent.toString()).apply();
        }catch(Exception ignored){}
        weights.put(key,Math.max(-2,Math.min(3,weights.getOrDefault(key,0.0)*.995+delta)));
        if(weights.size()>120){
            List<Map.Entry<String,Double>> candidates=new ArrayList<>(weights.entrySet());
            candidates.sort((a,b)->Double.compare(Math.abs(b.getValue()),Math.abs(a.getValue())));
            weights.clear();
            for(int i=0;i<Math.min(100,candidates.size());i++)weights.put(candidates.get(i).getKey(),candidates.get(i).getValue());
        }
        save(context);
    }
    private static void save(Context context) {
        JSONObject json=new JSONObject();
        for(Map.Entry<String,Double> item:weights.entrySet())try{json.put(item.getKey(),item.getValue());}catch(Exception ignored){}
        context.getSharedPreferences(PREFS,0).edit().putString("weights",json.toString()).apply();
    }
}
