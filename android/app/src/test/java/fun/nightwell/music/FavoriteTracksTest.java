package fun.nightwell.music;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import java.util.HashSet;
import java.util.Set;
import static org.junit.Assert.*;

public final class FavoriteTracksTest {
    private static JSONObject track(String id,String title) throws Exception {
        return new JSONObject().put("id",id).put("title",title)
            .put("artist","Nightwell Artist").put("cover_url","/api/covers/"+id);
    }

    @Test public void likedSearchTrackVisibleOutsidePartialCatalog() throws Exception {
        FavoriteTracks index=new FavoriteTracks();
        Set<String> likes=new HashSet<>();
        JSONObject searched=track("audius_music_44","Трек, найденный через поиск");
        likes.add(searched.getString("id"));
        index.remember(searched);
        index.promote(searched.getString("id"));

        JSONArray visible=index.visible(likes,
            new JSONArray().put(track("unrelated","Другой трек")),
            new JSONArray(),new JSONArray());
        assertEquals(1,visible.length());
        assertEquals("Трек, найденный через поиск",visible.getJSONObject(0).getString("title"));
        assertFalse(visible.getJSONObject(0).optBoolean("_favoriteMissing"));
    }

    @Test public void favoritesPersistAcrossProcessAndCatalogRefresh() throws Exception {
        FavoriteTracks before=new FavoriteTracks();
        before.remember(track("cloud_777","Любимая песня"));
        before.promote("cloud_777");
        FavoriteTracks after=new FavoriteTracks();
        after.restore(before.snapshot(1200));
        Set<String> liked=new HashSet<>();
        liked.add("cloud_777");
        after.reconcile(liked,new JSONArray().put("cloud_777"),null);
        JSONArray visible=after.visible(liked,new JSONArray(),new JSONArray(),null);
        assertEquals(1,visible.length());
        assertEquals("Любимая песня",visible.getJSONObject(0).getString("title"));
    }

    @Test public void newFavoriteAppearsFirstAndDuplicatesAreDeduplicated() throws Exception {
        FavoriteTracks index=new FavoriteTracks();
        Set<String> likes=new HashSet<>();
        likes.add("old");likes.add("new");
        index.remember(track("old","Старая"));
        index.remember(track("new","Новая"));
        index.reconcile(likes,new JSONArray().put("old").put("new").put("old"),"new");

        JSONArray displayed=index.visible(likes,new JSONArray().put(track("old","Старая")),
            new JSONArray().put(track("old","Старая")),new JSONArray());
        assertEquals(2,displayed.length());
        assertEquals("new",displayed.getJSONObject(0).getString("id"));
        assertEquals("old",displayed.getJSONObject(1).getString("id"));
    }

    @Test public void missingMetadataRemainsVisibleInsteadOfVanishing() throws Exception {
        FavoriteTracks index=new FavoriteTracks();
        Set<String> likes=new HashSet<>();
        likes.add("external_1234");
        index.reconcile(likes,new JSONArray().put("external_1234"),null);
        JSONArray displayed=index.visible(likes,new JSONArray(),new JSONArray(),null);
        assertEquals(1,displayed.length());
        assertTrue(displayed.getJSONObject(0).optBoolean("_favoriteMissing"));
        assertEquals("external_1234",displayed.getJSONObject(0).getString("id"));
    }

    @Test public void removalClearsTrackAndStopsDisplay() throws Exception {
        FavoriteTracks index=new FavoriteTracks();
        Set<String> likes=new HashSet<>();
        likes.add("track_xyz");
        index.remember(track("track_xyz","Сохранённый"));
        index.promote("track_xyz");
        likes.remove("track_xyz");
        index.remove("track_xyz");
        index.reconcile(likes,new JSONArray(),null);
        assertEquals(0,index.visible(likes,new JSONArray(),new JSONArray(),null).length());
        assertEquals(0,index.snapshot(10).getJSONArray("tracks").length());
    }
}
