package fun.nightwell.music;

import java.text.Normalizer;
import java.util.*;
import java.util.function.Function;

/** Preserves server relevance while reducing repeat recordings and artist streaks. */
final class RecommendationOrder {
    static String key(String value) {
        if (value == null) return "";
        return Normalizer.normalize(value.toLowerCase(Locale.ROOT), Normalizer.Form.NFD)
            .replaceAll("\\p{M}", "").replaceAll("[^\\p{L}\\p{N}]", "");
    }
    private static final String[] ALTERNATIVE_VERSIONS = {
        "remix", "live", "cover", "slowed", "spedup", "nightcore",
        "karaoke", "instrumental", "acoustic", "radioedit"
    };
    static int searchScore(String query, String title, String artist) {
        String wanted = key(query), name = key(title), performer = key(artist);
        if (wanted.isEmpty()) return 0;
        String combined = key(title + " " + artist);
        int score = 0;
        if (name.equals(wanted)) score += 160;
        else if (name.startsWith(wanted)) score += 95;
        else if (name.contains(wanted)) score += 65;
        if (performer.equals(wanted)) score += 85;
        else if (performer.startsWith(wanted)) score += 40;
        if (combined.contains(wanted)) score += 35;
        String[] terms = query.trim().split("\\s+");
        boolean allTerms = true;
        for (String term : terms) if (!key(term).isEmpty() && !combined.contains(key(term))) allTerms = false;
        if (allTerms) score += 40;
        for (String variant : ALTERNATIVE_VERSIONS) {
            if (name.contains(variant) && !wanted.contains(variant)) score -= 35;
        }
        return score;
    }
    static <T> List<T> rankSearch(List<T> input, String query, Function<T,String> title, Function<T,String> artist) {
        List<T> ranked = new ArrayList<>(input);
        Map<T,Integer> indexes = new IdentityHashMap<>();
        for (int i = 0; i < input.size(); i++) indexes.put(input.get(i), i);
        ranked.sort((a,b) -> {
            int aScore = searchScore(query,title.apply(a),artist.apply(a));
            int bScore = searchScore(query,title.apply(b),artist.apply(b));
            return aScore == bScore ? Integer.compare(indexes.get(a),indexes.get(b)) : Integer.compare(bScore,aScore);
        });
        return ranked;
    }
    static <T> List<T> arrange(List<T> input, Set<String> recent, String current,
        Function<T,String> id, Function<T,String> title, Function<T,String> artist) {
        return arrange(input, recent, Collections.emptySet(), current, id, title, artist);
    }
    static <T> List<T> arrange(List<T> input, Set<String> recent, Set<String> hidden, String current,
        Function<T,String> id, Function<T,String> title, Function<T,String> artist) {
        List<T> pool = new ArrayList<>(), result = new ArrayList<>();
        Map<T,Integer> rank = new IdentityHashMap<>();
        Set<String> ids = new HashSet<>(), recordings = new HashSet<>();
        Map<String,Integer> counts = new HashMap<>();
        String previous = "";
        for (int i = 0; i < Math.min(200,input.size()); i++) {
            T item = input.get(i);
            String identity = id.apply(item), name = key(title.apply(item)), performer = key(artist.apply(item));
            if (identity.equals(current) || hidden.contains(identity) || !ids.add(identity)
                || (!name.isEmpty() && !performer.isEmpty() && !recordings.add(performer + ":" + name))) continue;
            pool.add(item); rank.put(item,i);
        }
        while (!pool.isEmpty()) {
            int best = 0; double maximum = -Double.MAX_VALUE;
            for (int i = 0; i < pool.size(); i++) {
                T item = pool.get(i);
                String performer = key(artist.apply(item));
                double score = 1.0/(1+rank.get(item)*.12) - (recent.contains(id.apply(item))?2.5:0)
                    - (performer.isEmpty()?0:counts.getOrDefault(performer,0)*.19
                    + (performer.equals(previous)?.85:0));
                if (score > maximum) { maximum = score; best = i; }
            }
            T item = pool.remove(best);
            String performer = key(artist.apply(item));
            result.add(item);
            if (!performer.isEmpty()) counts.put(performer,counts.getOrDefault(performer,0)+1);
            previous = performer;
        }
        return result;
    }
}
