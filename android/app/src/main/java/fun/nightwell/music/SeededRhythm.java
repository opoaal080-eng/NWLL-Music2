package fun.nightwell.music;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.*;

/** Lightweight seeded similarity: no audio fingerprinting or extra server jobs. */
final class SeededRhythm {
    private SeededRhythm(){}

    static List<String> artists(JSONArray seeds){
        Map<String,Integer> counts=new LinkedHashMap<>();
        Map<String,String> display=new LinkedHashMap<>();
        if(seeds!=null)for(int i=0;i<Math.min(400,seeds.length());i++){
            JSONObject t=seeds.optJSONObject(i);if(t==null)continue;
            String value=t.optString("artist","").trim();
            String key=RecommendationOrder.key(value);
            if(key.isEmpty())continue;
            counts.put(key,counts.getOrDefault(key,0)+1);display.putIfAbsent(key,value);
        }
        List<String> names=new ArrayList<>(counts.keySet());
        names.sort((a,b)->Integer.compare(counts.get(b),counts.get(a)));
        List<String> result=new ArrayList<>();
        for(String key:names){if(result.size()==4)break;result.add(display.get(key));}
        return result;
    }

    static JSONArray rank(JSONArray pool,JSONArray seeds,Set<String> hidden,Set<String> blocked){
        Set<String> used=new HashSet<>(),seedIDs=new HashSet<>(),seedArtists=new HashSet<>();
        Set<String> tokens=new HashSet<>();
        if(seeds!=null)for(int i=0;i<Math.min(400,seeds.length());i++){
            JSONObject track=seeds.optJSONObject(i);if(track==null)continue;
            seedIDs.add(track.optString("id"));
            seedArtists.add(RecommendationOrder.key(track.optString("artist")));
            for(String word:(track.optString("title")+" "+track.optString("artist")).split("[^\\p{L}\\p{N}]+"))
                if(word.length()>3)tokens.add(RecommendationOrder.key(word));
        }
        class Candidate{
            final JSONObject track;final double score;final String artist;
            Candidate(JSONObject t,double s,String a){track=t;score=s;artist=a;}
        }
        List<Candidate> ranked=new ArrayList<>();
        if(pool!=null)for(int i=0;i<Math.min(900,pool.length());i++){
            JSONObject t=pool.optJSONObject(i);if(t==null)continue;
            String id=t.optString("id"),artist=RecommendationOrder.key(t.optString("artist"));
            if(id.isEmpty()||seedIDs.contains(id)||hidden.contains(id)||blocked.contains(artist)||!used.add(id))continue;
            double score=seedArtists.contains(artist)&&!artist.isEmpty()?7:0;
            for(String word:(t.optString("title")+" "+t.optString("artist")).split("[^\\p{L}\\p{N}]+"))
                if(tokens.contains(RecommendationOrder.key(word)))score+=.7;
            if(score<.7)continue;
            ranked.add(new Candidate(t,score,artist));
        }
        ranked.sort((x,y)->Double.compare(y.score,x.score));
        JSONArray result=new JSONArray();
        Map<String,Integer> artistCount=new HashMap<>();
        for(Candidate candidate:ranked){
            if(result.length()>=100)break;
            if(artistCount.getOrDefault(candidate.artist,0)>=5)continue;
            result.put(candidate.track);
            artistCount.put(candidate.artist,artistCount.getOrDefault(candidate.artist,0)+1);
        }
        if(result.length()<8){
            Set<String> ids=new HashSet<>();
            for(int i=0;i<result.length();i++)ids.add(result.optJSONObject(i).optString("id"));
            for(Candidate t:ranked)if(result.length()<100&&ids.add(t.track.optString("id")))result.put(t.track);
        }
        return result;
    }
}
