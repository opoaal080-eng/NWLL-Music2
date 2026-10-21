package fun.nightwell.music;
import java.util.*;
import java.util.function.Function;
import java.text.Normalizer;

/** Preserve server relevance while reducing repeated recordings and artist streaks. */
final class RecommendationOrder {
    static String key(String value){return Normalizer.normalize(value.toLowerCase(Locale.ROOT),Normalizer.Form.NFD).replaceAll("\\p{M}","").replaceAll("[^\\p{L}\\p{N}]","");}
    static <T> List<T> arrange(List<T> input,Set<String> recent,String current,Function<T,String> id,Function<T,String> title,Function<T,String> artist){
        List<T> pool=new ArrayList<>(),result=new ArrayList<>();Map<T,Integer> rank=new IdentityHashMap<>();Set<String> ids=new HashSet<>(),recordings=new HashSet<>();Map<String,Integer> counts=new HashMap<>();String previous="";
        for(int i=0;i<Math.min(200,input.size());i++){T item=input.get(i);String identity=id.apply(item),name=key(title.apply(item)),performer=key(artist.apply(item));if(identity.equals(current)||!ids.add(identity)||(!name.isEmpty()&&!performer.isEmpty()&&!recordings.add(performer+":"+name)))continue;pool.add(item);rank.put(item,i);}
        while(!pool.isEmpty()){
            int best=0;double maximum=-Double.MAX_VALUE;
            for(int i=0;i<pool.size();i++){T item=pool.get(i);String performer=key(artist.apply(item));double score=1.0/(1+rank.get(item)*.12)-(recent.contains(id.apply(item))?2.5:0)-(performer.isEmpty()?0:counts.getOrDefault(performer,0)*.19+(performer.equals(previous)?.85:0));if(score>maximum){maximum=score;best=i;}}
            T item=pool.remove(best);String performer=key(artist.apply(item));result.add(item);if(!performer.isEmpty())counts.put(performer,counts.getOrDefault(performer,0)+1);previous=performer;
        }
        return result;
    }
}
