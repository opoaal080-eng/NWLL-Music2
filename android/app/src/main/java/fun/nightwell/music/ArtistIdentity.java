package fun.nightwell.music;

import org.json.JSONObject;
import java.text.Normalizer;
import java.util.Locale;
import java.util.Set;
import java.util.HashSet;

/** Resolve performers independently of the account which uploaded a track. */
final class ArtistIdentity {
    private ArtistIdentity() {}

    private static final Set<String> GENERIC = new HashSet<>(java.util.Arrays.asList(
        "unknown", "unknown artist", "various", "various artists", "artist",
        "soundcloud", "music", "new music", "type beat", "beats", "official music",
        "no copyright music", "lyrics", "playlist", "radio", "mixes",
        "неизвестный исполнитель", "исполнитель", "музыка", "плейлист",
        "на этом устройстве", "nightwell music"
    ));

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

    private static String lead(String value) {
        String clean = value.replaceAll("(?i)\\s+(?:feat\\.?|ft\\.?|featuring)\\s+.*$", "");
        return clean.split(",", 2)[0].trim();
    }

    static String fromTitle(JSONObject track) {
        String title = track.optString("title", "");
        for (String separator : new String[] {" - ", " – ", " — "}) {
            int cut = title.indexOf(separator);
            if (cut < 0) continue;
            String result = lead(title.substring(0, cut));
            String song = title.substring(cut + separator.length()).trim();
            if (usable(result) && song.length() >= 2) return result;
        }
        return "";
    }

    static String name(JSONObject track) {
        if (track == null) return "";
        String titleArtist = fromTitle(track);
        if (!titleArtist.isEmpty()) return titleArtist;
        String metadata = lead(track.optString("artist", ""));
        return usable(metadata) ? metadata : "";
    }

    static boolean isCloud(JSONObject track) {
        return track.optString("source", "").toLowerCase(Locale.ROOT).contains("soundcloud")
            || track.optString("source_url", "").toLowerCase(Locale.ROOT).contains("soundcloud.com");
    }

    static boolean belongs(JSONObject track, JSONObject seed, String artist) {
        if (track == null || seed == null || artist.isEmpty()) return false;
        String trackID = track.optString("id", "");
        if (!trackID.isEmpty() && trackID.equals(seed.optString("id", ""))) return true;
        String inTitle = fromTitle(track);
        if (!inTitle.isEmpty()) return key(inTitle).equals(key(artist));
        // An uploader name is not proof of authorship.
        return !isCloud(track) && usable(track.optString("artist", ""))
            && key(lead(track.optString("artist", ""))).equals(key(artist));
    }
}
