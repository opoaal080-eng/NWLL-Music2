package fun.nightwell.music;

import org.json.JSONObject;
import java.text.Normalizer;
import java.util.Locale;
import java.util.Set;
import java.util.HashSet;
import java.util.List;
import java.util.ArrayList;

/** Only explicit artist metadata/title credits establish a performer. */
final class ArtistIdentity {
    private ArtistIdentity() {}

    private static final Set<String> GENERIC = new HashSet<>(java.util.Arrays.asList(
        "unknown", "unknown artist", "various", "various artists", "artist",
        "soundcloud", "music", "new music", "type beat", "beats", "official music",
        "no copyright music", "lyrics", "playlist", "radio", "mixes",
        "неизвестный исполнитель", "исполнитель", "музыка", "плейлист",
        "на этом устройстве", "nightwell music"));

    static String key(String value) {
        if (value == null) return "";
        String normalized = Normalizer.normalize(value.toLowerCase(Locale.ROOT).trim(), Normalizer.Form.NFD)
            .replaceAll("\\p{M}+", "");
        return normalized.replaceAll("[^\\p{L}\\p{N}]+", " ").trim().replaceAll(" +", " ");
    }

    static boolean usable(String value) {
        String name = key(value);
        if (name.length() < 2 || name.length() > 65 || GENERIC.contains(name)) return false;
        for (String generic : new String[] {
            "type beat", "lyrics video", "music channel", "музыкальный канал",
            "топ трек", "подборка трек", "sped up", "slowed reverb"
        }) if (name.contains(generic)) return false;
        return true;
    }

    static List<String> credited(String raw) {
        String clean = (raw==null?"":raw)
            .replaceAll("(?i)\\s*[\\[(]?\\s*(?:feat\\.?|ft\\.?|featuring)\\s+", ", ")
            .replaceAll("(?i)\\s+(?:x|&)\\s+", ", ")
            .replaceAll("[\\[\\]()]", "");
        List<String> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for(String fragment:clean.split(",")) {
            String name = fragment.trim();
            if(usable(name) && seen.add(key(name)))result.add(name);
        }
        return result;
    }

    static String fromTitle(JSONObject track) {
        String title = track==null?"":track.optString("title","");
        for (String separator : new String[] {" - ", " – ", " — "}) {
            int cut = title.indexOf(separator);
            if (cut < 0) continue;
            List<String> names = credited(title.substring(0,cut));
            String song = title.substring(cut+separator.length()).trim();
            if(!names.isEmpty() && song.length()>=2)return names.get(0);
        }
        return "";
    }

    private static String[] parts(JSONObject track) {
        String title=track.optString("title","");
        for(String sep:new String[]{" - "," – "," — "}) {
            int i=title.indexOf(sep);
            if(i>=0 && title.substring(i+sep.length()).trim().length()>=2)
                return new String[]{title.substring(0,i),title.substring(i+sep.length())};
        }
        return null;
    }

    private static List<String> featured(String name) {
        java.util.regex.Matcher match = java.util.regex.Pattern.compile(
            "(?i)(?:feat\\.?|ft\\.?|featuring)\\s+([^\\])\\n]+)").matcher(name);
        if(!match.find())return java.util.Collections.emptyList();
        String value=match.group(1);
        for(String sep:new String[]{" - "," – "," — "}) {
            int at=value.indexOf(sep);
            if(at>=0)value=value.substring(0,at);
        }
        return credited(value);
    }

    static List<String> names(JSONObject track) {
        if(track==null)return java.util.Collections.emptyList();
        List<String> all=new ArrayList<>();
        String metadata=track.optString("artist_name","");
        String[] titleParts=parts(track);
        if(!credited(metadata).isEmpty())all.addAll(credited(metadata));
        else if(titleParts!=null)all.addAll(credited(titleParts[0]));
        else if(!isCloud(track))all.addAll(credited(track.optString("artist","")));
        all.addAll(featured(titleParts==null?track.optString("title",""):titleParts[1]));
        List<String> unique=new ArrayList<>();
        Set<String> seen=new HashSet<>();
        for(String name:all)if(seen.add(key(name)))unique.add(name);
        return unique;
    }

    static String name(JSONObject track) {
        List<String> all=names(track);
        return all.isEmpty()?"":all.get(0);
    }

    static boolean isCloud(JSONObject track) {
        return track.optString("source", "").toLowerCase(Locale.ROOT).contains("soundcloud")
            || track.optString("source_url", "").toLowerCase(Locale.ROOT).contains("soundcloud.com");
    }

    static boolean belongs(JSONObject track, JSONObject seed, String artist) {
        if(track==null||seed==null||artist.isEmpty())return false;
        if(track.optString("id","").equals(seed.optString("id","")))return true;
        for(String name:names(track))if(key(name).equals(key(artist)))return true;
        return false;
    }
}
