package fun.nightwell.music;

import org.junit.Test;
import java.util.*;
import static org.junit.Assert.*;

public class RecommendationOrderTest {
    private static class Song {
        final String id, title, artist;
        Song(String id, String title, String artist) { this.id=id; this.title=title; this.artist=artist; }
    }
    @Test public void originalBeatsUnrequestedRemixButRemixCanBeRequested() {
        List<Song> candidates=Arrays.asList(
            new Song("remix","Night Song Remix","Artist"),
            new Song("original","Night Song","Artist"),
            new Song("live","Night Song Live","Artist")
        );
        assertEquals("original",RecommendationOrder.rankSearch(candidates,"Night Song",s->s.title,s->s.artist).get(0).id);
        assertEquals("remix",RecommendationOrder.rankSearch(candidates,"Night Song Remix",s->s.title,s->s.artist).get(0).id);
        List<Song> filtered=RecommendationOrder.arrange(candidates,Collections.emptySet(),Collections.singleton("original"),"",s->s.id,s->s.title,s->s.artist);
        assertEquals(2,filtered.size());
        assertFalse(filtered.stream().anyMatch(s->s.id.equals("original")));
        List<Song> withoutArtist=RecommendationOrder.arrange(candidates,Collections.emptySet(),
            Collections.emptySet(),Collections.singleton("artist"),"",s->s.id,s->s.title,s->s.artist);
        assertTrue(withoutArtist.isEmpty());
    }
}
