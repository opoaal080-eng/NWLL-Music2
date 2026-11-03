package fun.nightwell.music;

import org.json.JSONObject;
import org.junit.Test;
import static org.junit.Assert.*;

public final class ArtistIdentityTest {
    private JSONObject track(String id, String title, String artist, String source) throws Exception {
        return new JSONObject().put("id", id).put("title", title)
            .put("artist", artist).put("source", source);
    }

    @Test public void performerInTitleOverridesUploader() throws Exception {
        JSONObject item = track("1", "Audiosoulz - Missing", "Some uploader", "soundcloud");
        assertEquals("Audiosoulz", ArtistIdentity.name(item));
    }

    @Test public void uploaderAloneDoesNotBecomeArtist() throws Exception {
        JSONObject item = track("1", "Missing", "Some uploader", "soundcloud");
        assertEquals("", ArtistIdentity.name(item));
    }

    @Test public void sameUploaderDoesNotImplySamePerformer() throws Exception {
        JSONObject seed = track("1", "Audiosoulz - Missing", "Uploader", "soundcloud");
        JSONObject unrelated = track("2", "Someone Else - Song", "Uploader", "soundcloud");
        JSONObject matching = track("3", "Audiosoulz - Dancefloor", "OtherUploader", "soundcloud");
        assertFalse(ArtistIdentity.belongs(unrelated, seed, "Audiosoulz"));
        assertTrue(ArtistIdentity.belongs(matching, seed, "Audiosoulz"));
    }

    @Test public void canonicalArtistMetadataCanOverrideCloudUploader() throws Exception {
        JSONObject seed = track("1", "Missing", "Uploader", "soundcloud")
            .put("artist_name", "Audiosoulz");
        assertEquals("Audiosoulz", ArtistIdentity.name(seed));
    }
}
