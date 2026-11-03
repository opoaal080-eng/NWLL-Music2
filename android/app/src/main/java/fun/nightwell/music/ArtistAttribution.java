package fun.nightwell.music;

import java.net.URL;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Distinguish a remote upload account from the real credited musician. */
final class ArtistAttribution {
    static final String UNKNOWN = "Исполнитель не указан";
    private static final Pattern TITLE_CREDIT =
        Pattern.compile("^\\s*(.{2,90}?)\\s+[-–—]\\s+(.{2,250}?)\\s*$", Pattern.UNICODE_CASE);
    private static final Set<String> NOT_SONGS = new HashSet<>(Arrays.asList(
        "remix", "live", "slowed", "spedup", "sped up", "nightcore", "instrumental",
        "radio edit", "official", "lyrics", "ремикс", "лайв", "кавер",
        "ускоренная", "замедленная", "инструментал"
    ));

    static final class Result {
        final String title, artist, uploader;
        final boolean attributed;
        Result(String title, String artist, String uploader, boolean attributed) {
            this.title=title;this.artist=artist;this.uploader=uploader;this.attributed=attributed;
        }
    }

    static boolean isRemote(String source,String sourceUrl,boolean remote) {
        if(remote)return true;
        if(source!=null&&source.toLowerCase(Locale.ROOT).contains("soundcloud"))return true;
        try {
            if(sourceUrl==null)return false;
            String host=new URL(sourceUrl).getHost().toLowerCase(Locale.ROOT);
            return host.equals("soundcloud.com")||host.endsWith(".soundcloud.com");
        }catch(Exception ignored){return false;}
    }

    static String[] titleCredit(String title) {
        if(title==null)return null;
        Matcher match=TITLE_CREDIT.matcher(title);
        if(!match.matches())return null;
        String name=match.group(1).trim(),song=match.group(2).trim();
        if(name.isEmpty()||song.isEmpty()||!containsLetter(name)||!containsLetter(song))return null;
        String lower=song.toLowerCase(Locale.ROOT);
        if(NOT_SONGS.contains(lower)||name.toLowerCase(Locale.ROOT).startsWith("prod.")||
                name.toLowerCase(Locale.ROOT).startsWith("produced by"))return null;
        return new String[]{name,song};
    }

    private static boolean containsLetter(String value) {
        for(int i=0;i<value.length();i++)if(Character.isLetter(value.charAt(i)))return true;
        return false;
    }

    static Result resolve(String title,String artist,String source,String sourceUrl,
                          boolean remote,String performer,String artistCredit) {
        title=title==null?"":title.trim();
        artist=artist==null?"":artist.trim();
        if(!isRemote(source,sourceUrl,remote))
            return new Result(title,artist,null,!artist.isEmpty());

        String explicit=performer!=null&&!performer.trim().isEmpty()?performer.trim():
            artistCredit!=null&&!artistCredit.trim().isEmpty()?artistCredit.trim():null;
        String[] inferred=titleCredit(title);
        if(explicit!=null&&!explicit.equals(UNKNOWN)) {
            return new Result(inferred!=null&&explicit.equalsIgnoreCase(inferred[0])?
                inferred[1]:title,explicit,artist.isEmpty()?null:artist,true);
        }
        if(inferred!=null)return new Result(inferred[1],inferred[0],
            artist.isEmpty()?null:artist,true);
        if(!artist.isEmpty()&&!artist.equals(UNKNOWN))
            return new Result(title,artist,null,true);
        return new Result(title,UNKNOWN,null,false);
    }

    static boolean isKnown(String name) {
        return name!=null&&!name.trim().isEmpty()&&!name.trim().equals(UNKNOWN);
    }

    private ArtistAttribution(){}
}
