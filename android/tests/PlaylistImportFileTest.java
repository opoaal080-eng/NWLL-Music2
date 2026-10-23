package fun.nightwell.music;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
public final class PlaylistImportFileTest {
    static void require(boolean value) { if(!value)throw new AssertionError(); }
    static void rejects(byte[] bytes) throws Exception {
        try { PlaylistImportFile.read(new ByteArrayInputStream(bytes)); throw new AssertionError("Accepted invalid document"); }
        catch(IOException expected) {}
    }
    public static void main(String[] args) throws Exception {
        for(String text:new String[]{"Исполнитель — Песня", "artist,title\nArtist,Song", "{\"tracks\":[\"Песня\"]}"}) {
            require(PlaylistImportFile.read(new ByteArrayInputStream(text.getBytes(StandardCharsets.UTF_8))).equals(text));
            require(PlaylistImportFile.read(new ByteArrayInputStream(("\ufeff"+text).getBytes(StandardCharsets.UTF_8))).equals(text));
            require(PlaylistImportFile.read(new ByteArrayInputStream(("\ufeff"+text).getBytes(StandardCharsets.UTF_16LE))).equals(text));
            require(PlaylistImportFile.read(new ByteArrayInputStream(("\ufeff"+text).getBytes(StandardCharsets.UTF_16BE))).equals(text));
        }
        rejects(new byte[0]); rejects(" \n\t".getBytes()); rejects(new byte[]{0,1,2}); rejects(new byte[]{(byte)0xff,12,13});
        byte[] large=new byte[PlaylistImportFile.LIMIT+1]; Arrays.fill(large,(byte)'a'); rejects(large);
        require(PlaylistImportFile.read(new ByteArrayInputStream(Arrays.copyOf(large,PlaylistImportFile.LIMIT))).length()==PlaylistImportFile.LIMIT);
        byte[] expansion=("\ufeff"+"曲".repeat(400000)).getBytes(StandardCharsets.UTF_16LE); rejects(expansion);
        try { PlaylistImportFile.read(null); throw new AssertionError(); } catch(IOException expected) {}
        System.out.println("Playlist import: JSON/CSV/TXT, BOM, UTF-16, limits and invalid input passed");
    }
}
