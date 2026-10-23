package fun.nightwell.music;
import org.junit.Test;
import org.json.JSONArray;
import static org.junit.Assert.*;
public class TransferPreparationTest {
 @Test public void csvQuotesAndDuplicates() throws Exception {
  JSONArray rows=TransferPreparation.parse("artist,title\r\nArtist,\"Song, part 1\"\r\nArtist,\"Song, part 1\"\r\n");
  assertEquals(1,rows.length());assertEquals("Song, part 1",rows.getJSONObject(0).getString("title"));
 }
 @Test public void structuredExportAndDuration() throws Exception {
  JSONArray rows=TransferPreparation.parse("{\"tracks\":[{\"track\":{\"name\":\"Song\",\"artists\":[{\"name\":\"Artist\"}],\"duration_ms\":180000}}]}");
  assertEquals(180,rows.getJSONObject(0).getDouble("duration"),.001);
 }
 @Test public void txtAndUnicodeDuplicates() throws Exception {
  assertEquals(1,TransferPreparation.parse("Ёлка — Трек\nЕлка - Трек").length());
 }
 @Test(expected=Exception.class) public void malformedRowRejected() throws Exception { TransferPreparation.parse("artist,title\nArtist"); }
}
