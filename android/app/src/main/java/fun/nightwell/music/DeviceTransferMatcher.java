package fun.nightwell.music;

import org.json.*;
import java.util.*;
import java.text.Normalizer;

/** Bounded, CPU-local matching. One catalog fetch; no per-song search on the music host. */
final class DeviceTransferMatcher {
    private static final Set<String> VERSION = new HashSet<>(Arrays.asList(
        "remix","remiks","live","concert","kontsert","acoustic","akustika",
        "instrumental","karaoke","sped","slowed","cover","kaver",
        "remaster","remastered","extended","edit","reverb"));
    private static final String RU = "абвгдежзийклмнопрстуфхцчшщыэюя";
    private static final String[] LAT = {"a","b","v","g","d","e","zh","z","i","y","k",
        "l","m","n","o","p","r","s","t","u","f","h","ts","ch","sh","sch","y","e","yu","ya"};

    static String normalize(String raw) {
        if(raw==null)return "";
        String value=Normalizer.normalize(raw,Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)
            .replace('ё','е').replaceAll("(?i)\\b(?:official\\s+(?:music\\s+)?(?:video|audio)|lyrics?\\s+video|official|lyrics?|hq|hd|4k)\\b"," ")
            .replaceAll("[^\\p{L}\\p{N}]+"," ").trim();
        StringBuilder result=new StringBuilder();
        for(char c:value.toCharArray()){
            int index=RU.indexOf(c);
            result.append(index>=0?LAT[index]:c);
        }
        return result.toString().replaceAll("\\s+"," ").trim();
    }

    private static Set<String> versions(String value){
        Set<String> result=new HashSet<>();
        for(String s:value.split(" "))if(VERSION.contains(s))result.add(s);
        return result;
    }

    private static double similar(String a,String b) {
        if(a.equals(b))return 1;
        if(a.isEmpty()||b.isEmpty()||a.length()>160||b.length()>160)return 0;
        int[] previous=new int[b.length()+1];
        for(int j=0;j<previous.length;j++)previous[j]=j;
        for(int i=1;i<=a.length();i++){
            int[] current=new int[b.length()+1];current[0]=i;
            for(int j=1;j<=b.length();j++)
                current[j]=Math.min(Math.min(previous[j]+1,current[j-1]+1),
                                   previous[j-1]+(a.charAt(i-1)==b.charAt(j-1)?0:1));
            previous=current;
        }
        double edit=1-(double)previous[b.length()]/Math.max(a.length(),b.length());
        Set<String> left=new HashSet<>(Arrays.asList(a.split(" ")));
        Set<String> right=new HashSet<>(Arrays.asList(b.split(" ")));
        left.retainAll(right);
        double overlap=(double)left.size()/Math.max(a.split(" ").length,b.split(" ").length);
        return Math.max(edit,overlap);
    }

    private static final class Candidate {
        String id,title,artist;double duration;
        final ArrayList<String[]> variants=new ArrayList<>();
        Candidate(JSONObject item) {
            id=item.optString("id");title=item.optString("title");artist=item.optString("artist");
            duration=item.optDouble("duration",0);
            variants.add(new String[]{normalize(title),normalize(artist)});
            for(String delim:new String[]{" - "," — "," – "," | "," : "}){
                int cut=title.indexOf(delim);
                if(cut>0){
                    String left=normalize(title.substring(0,cut));
                    String right=normalize(title.substring(cut+delim.length()));
                    if(!left.isEmpty()&&!right.isEmpty()){
                        variants.add(new String[]{right,left});
                        variants.add(new String[]{left,right});
                    }
                    break;
                }
            }
        }
    }
    private static void insert(Map<String,ArrayList<Integer>> map,String key,int index){
        if(key.isEmpty())return;
        ArrayList<Integer> target=map.computeIfAbsent(key,k->new ArrayList<>());
        if(target.size()<1000)target.add(index);
    }
    private static double score(String title,String artist,double duration,Candidate c,String mode){
        if(duration>0&&c.duration>0&&Math.abs(duration-c.duration)>Math.max(14,duration*.13))return 0;
        double minTitle=mode.equals("safe")?.95:mode.equals("wide")?.85:.89;
        double minArtist=mode.equals("safe")?.90:mode.equals("wide")?.80:.85;
        double minScore=mode.equals("safe")?.93:mode.equals("wide")?.85:.89;
        double max=0;
        for(String[] pair:c.variants){
            if(!versions(title).equals(versions(pair[0])))continue;
            double ts=similar(title,pair[0]),as=similar(artist,pair[1]),overall=.65*ts+.35*as;
            if(ts>=minTitle&&as>=minArtist&&overall>=minScore)max=Math.max(max,overall);
        }
        return max;
    }

    static JSONArray match(JSONArray rows,JSONArray catalog,String mode)throws JSONException {
        if(rows==null||catalog==null)throw new JSONException("Нет списка треков или каталога");
        ArrayList<Candidate> pool=new ArrayList<>();
        Map<String,ArrayList<Integer>> byTitle=new HashMap<>(),byArtist=new HashMap<>();
        for(int i=0;i<Math.min(catalog.length(),200000);i++){
            JSONObject item=catalog.optJSONObject(i);
            if(item==null)continue;
            Candidate c=new Candidate(item);
            if(!c.id.matches("[A-Za-z0-9_-]{1,100}")||c.title.isEmpty())continue;
            int index=pool.size();pool.add(c);
            for(String[] pair:c.variants){
                insert(byTitle,pair[0],index);
                insert(byArtist,pair[1],index);
            }
        }
        JSONArray out=new JSONArray();
        for(int i=0;i<Math.min(rows.length(),1000);i++){
            JSONObject original=rows.getJSONObject(i);
            String title=normalize(original.optString("title")),artist=normalize(original.optString("artist"));
            LinkedHashSet<Integer> possible=new LinkedHashSet<>();
            List<Integer> names=byTitle.get(title);if(names!=null)possible.addAll(names);
            List<Integer> artists=byArtist.get(artist);
            if(artists!=null)for(int j=0;j<Math.min(artists.size(),250);j++)possible.add(artists.get(j));
            // Prefer exact title+artist pairs even when a popular artist has many songs.
            for(int index:possible){
                Candidate candidate=pool.get(index);
                boolean exact=false;
                for(String[] pair:candidate.variants)if(title.equals(pair[0])&&artist.equals(pair[1])){exact=true;break;}
                if(exact){
                    double duration=original.optDouble("duration",0);
                    if(duration<=0||candidate.duration<=0||Math.abs(duration-candidate.duration)<=Math.max(14,duration*.13)){
                        JSONObject row=new JSONObject(original.toString());
                        row.put("track_id",candidate.id);
                        row.put("found_title",candidate.title);
                        row.put("found_artist",candidate.artist);
                        row.put("reason","");
                        out.put(row);
                        possible=null;
                        break;
                    }
                }
            }
            if(possible==null)continue;
            double highest=0,runnerUp=0;Candidate winner=null;
            int checked=0;
            for(int index:possible){
                if(++checked>500)break;
                Candidate c=pool.get(index);
                double grade=score(title,artist,original.optDouble("duration",0),c,mode);
                if(grade>highest){
                    runnerUp=highest;highest=grade;winner=c;
                }else if(grade>runnerUp){runnerUp=grade;}
            }
            JSONObject row=new JSONObject(original.toString());
            if(winner!=null&&(highest>=.999||highest-runnerUp>=.025)){
                row.put("track_id",winner.id);
                row.put("found_title",winner.title);
                row.put("found_artist",winner.artist);
                row.put("reason","");
            }else{
                row.put("track_id",JSONObject.NULL);
                row.put("reason",winner==null?"Не найдено надёжного совпадения в каталоге":
                    "Несколько похожих версий, нужна ручная проверка");
            }
            out.put(row);
        }
        return out;
    }
}
