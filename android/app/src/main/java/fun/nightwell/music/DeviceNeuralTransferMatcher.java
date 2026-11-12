package fun.nightwell.music;


import java.util.concurrent.CancellationException;
import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONException;
import java.util.*;
import java.util.function.BooleanSupplier;

/**
 * Optional fully on-device neural ranker for imported playlists.
 * A tiny 8 -> 10 -> 1 neural network learns from the fetched catalogue.
 * The default DeviceTransferMatcher remains the faster, battery-friendly option.
 */
final class DeviceNeuralTransferMatcher {
    private static final Set<String> VERSIONS=new HashSet<>(Arrays.asList(
        "live","remix","remiks","concert","acoustic","akustika","instrumental",
        "karaoke","cover","kaver","remaster","remastered","sped","slowed","edit","reverb"));

    private static final class Candidate {
        final String id,rawTitle,rawArtist,title,artist;
        final double duration;
        Candidate(JSONObject item){
            id=item.optString("id");rawTitle=item.optString("title");rawArtist=item.optString("artist");
            title=DeviceTransferMatcher.normalize(rawTitle);
            artist=DeviceTransferMatcher.normalize(rawArtist);
            duration=item.optDouble("duration",0);
        }
    }
    private static String[] words(String text){return text.isEmpty()?new String[0]:text.split(" ");}
    private static Set<String> tokens(String value){return new HashSet<>(Arrays.asList(words(value)));}
    private static Set<String> version(String value){Set<String> all=tokens(value);all.retainAll(VERSIONS);return all;}
    private static double overlap(String a,String b){
        Set<String> left=tokens(a),right=tokens(b);
        if(left.isEmpty()||right.isEmpty())return 0;
        int size=Math.max(left.size(),right.size());
        left.retainAll(right);
        return (double)left.size()/size;
    }
    private static double similarity(String a,String b){
        if(a.equals(b))return 1;
        if(a.isEmpty()||b.isEmpty()||a.length()>140||b.length()>140)return 0;
        int[] old=new int[b.length()+1];
        for(int j=0;j<old.length;j++)old[j]=j;
        for(int i=1;i<=a.length();i++){
            int[] now=new int[b.length()+1];now[0]=i;
            for(int j=1;j<=b.length();j++){
                now[j]=Math.min(Math.min(old[j]+1,now[j-1]+1),old[j-1]+(a.charAt(i-1)==b.charAt(j-1)?0:1));
            }
            old=now;
        }
        return Math.max(0,1.0-(double)old[b.length()]/Math.max(a.length(),b.length()));
    }
    private static double[] vector(String title,String artist,double duration,Candidate candidate){
        double dt=duration>0&&candidate.duration>0?
            Math.max(0,1-Math.abs(duration-candidate.duration)/Math.max(14,duration*.13)):1;
        return new double[]{
            similarity(title,candidate.title),
            similarity(artist,candidate.artist),
            overlap(title,candidate.title),
            overlap(artist,candidate.artist),
            dt,version(title).equals(version(candidate.title))?1:0,
            title.equals(candidate.title)?1:0,artist.equals(candidate.artist)?1:0
        };
    }
    private static final class Network {
        final double[][] w=new double[10][8];
        final double[] hBias=new double[10],out=new double[10];
        double outBias;
        Network(){
            Random rng=new Random(89411);
            for(int j=0;j<10;j++){
                for(int i=0;i<8;i++)w[j][i]=(rng.nextDouble()-.5)*.6;
                out[j]=(rng.nextDouble()-.5)*.6;
            }
        }
        static double sigmoid(double x){return 1.0/(1.0+Math.exp(-Math.max(-30,Math.min(30,x))));}
        double predict(double[] x){
            double sum=outBias;
            for(int j=0;j<10;j++){
                double weighted=hBias[j];
                for(int i=0;i<8;i++)weighted+=w[j][i]*x[i];
                sum+=out[j]*Math.tanh(weighted);
            }
            return sigmoid(sum);
        }
        void learn(double[] x,double target){
            double[] hidden=new double[10],old=out.clone();
            double sum=outBias;
            for(int j=0;j<10;j++){
                double weighted=hBias[j];
                for(int i=0;i<8;i++)weighted+=w[j][i]*x[i];
                hidden[j]=Math.tanh(weighted);sum+=out[j]*hidden[j];
            }
            double delta=sigmoid(sum)-target;
            for(int j=0;j<10;j++){
                out[j]-=.055*delta*hidden[j];
                double back=delta*old[j]*(1-hidden[j]*hidden[j]);
                for(int i=0;i<8;i++)w[j][i]-=.055*back*x[i];
                hBias[j]-=.055*back;
            }
            outBias-=.055*delta;
        }
    }
    private static void put(Map<String,ArrayList<Integer>> index,String key,int position){
        if(key.isEmpty())return;
        ArrayList<Integer> list=index.get(key);
        if(list==null){list=new ArrayList<>();index.put(key,list);}
        if(list.size()<350)list.add(position);
    }
    private static void include(Set<Integer> destination,List<Integer> items,int max){
        if(items==null)return;
        for(int i=0;i<Math.min(max,items.size());i++)destination.add(items.get(i));
    }

    static JSONArray match(JSONArray prepared,JSONArray catalog,String mode,
                           BooleanSupplier cancelled)throws JSONException{
        if(cancelled.getAsBoolean())throw new CancellationException();
        JSONArray matched=DeviceTransferMatcher.match(prepared,catalog,mode);
        boolean unresolved=false;
        for(int i=0;i<matched.length();i++){
            JSONObject item=matched.optJSONObject(i);
            if(item!=null&&item.isNull("track_id")){unresolved=true;break;}
        }
        if(!unresolved)return matched;

        ArrayList<Candidate> pool=new ArrayList<>();
        HashMap<String,ArrayList<Integer>> byTitle=new HashMap<>(),byArtist=new HashMap<>();
        for(int i=0;i<Math.min(catalog.length(),80000);i++){
            if((i&1023)==0&&cancelled.getAsBoolean())throw new CancellationException();
            JSONObject raw=catalog.optJSONObject(i);
            if(raw==null)continue;
            Candidate candidate=new Candidate(raw);
            if(!candidate.id.matches("[A-Za-z0-9_-]{1,100}")||candidate.title.isEmpty()||candidate.artist.isEmpty())continue;
            int position=pool.size();pool.add(candidate);
            put(byTitle,candidate.title,position);
            put(byArtist,candidate.artist,position);
            String[] words=words(candidate.title);
            for(int k=0;k<Math.min(words.length,6);k++)if(words[k].length()>=4)put(byTitle,words[k],position);
        }
        if(pool.size()<2)return matched;

        Network network=new Network();
        int count=Math.min(pool.size(),800);
        for(int round=0;round<4;round++){
            if(cancelled.getAsBoolean())throw new CancellationException();
            for(int i=0;i<count;i++){
                if((i&63)==0&&cancelled.getAsBoolean())throw new CancellationException();
                Candidate candidate=pool.get(i),other=pool.get((i+17)%count);
                network.learn(vector(candidate.title,candidate.artist,candidate.duration,candidate),1);
                network.learn(vector(candidate.title,candidate.artist,candidate.duration,other),0);
                network.learn(vector(candidate.title,other.artist,candidate.duration,candidate),0);
            }
        }

        for(int i=0;i<matched.length();i++){
            if(cancelled.getAsBoolean())throw new CancellationException();
            JSONObject row=matched.optJSONObject(i);
            if(row==null||!row.isNull("track_id"))continue;
            String title=DeviceTransferMatcher.normalize(row.optString("title"));
            String artist=DeviceTransferMatcher.normalize(row.optString("artist"));
            double duration=row.optDouble("duration",0);
            LinkedHashSet<Integer> possible=new LinkedHashSet<>();
            include(possible,byTitle.get(title),350);
            include(possible,byArtist.get(artist),160);
            String[] parts=words(title);
            for(int k=0;k<Math.min(parts.length,4);k++){
                if(parts[k].length()>=4)include(possible,byTitle.get(parts[k]),120);
            }
            Candidate best=null;double highest=0,runner=0;
            int checked=0;
            for(int position:possible){
                if(++checked>260)break;
                Candidate candidate=pool.get(position);
                double[] x=vector(title,artist,duration,candidate);
                double minTitle=mode.equals("safe")?.90:mode.equals("wide")?.76:.82;
                double minArtist=mode.equals("safe")?.87:mode.equals("wide")?.68:.78;
                if(x[0]<minTitle||x[1]<minArtist||x[5]!=1)continue;
                if(duration>0&&candidate.duration>0&&Math.abs(duration-candidate.duration)>Math.max(14,duration*.13))continue;
                double confidence=.39*x[0]+.22*x[1]+.24*network.predict(x)+.15*x[2];
                if(confidence>highest){runner=highest;highest=confidence;best=candidate;}
                else if(confidence>runner)runner=confidence;
            }
            double minimum=mode.equals("safe")?.92:mode.equals("wide")?.82:.87;
            if(best==null||highest<minimum||(runner>0&&highest<.985&&highest-runner<.025))continue;
            row.put("track_id",best.id);
            row.put("found_title",best.rawTitle);
            row.put("found_artist",best.rawArtist);
            row.put("reason","");
        }
        return matched;
    }
}
