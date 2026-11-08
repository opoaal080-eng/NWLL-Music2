package fun.nightwell.music;
import org.junit.Test;
import org.json.JSONArray;
import static org.junit.Assert.*;
public class DeviceTransferMatcherTest {
 @Test public void matchesCompositeUploaderAndReportsMissing() throws Exception {
  JSONArray source=new JSONArray("[{\"title\":\"Звезда\",\"artist\":\"Кино\",\"duration\":180},{\"title\":\"Неведомая\",\"artist\":\"Кино\"}]");
  JSONArray catalog=new JSONArray("[{\"id\":\"one\",\"title\":\"Кино - Звезда (Official Audio)\",\"artist\":\"Uploader\",\"duration\":180}]");
  JSONArray out=DeviceTransferMatcher.match(source,catalog,"wide");
  assertEquals("one",out.getJSONObject(0).getString("track_id"));
  assertTrue(out.getJSONObject(1).isNull("track_id"));
  assertTrue(out.getJSONObject(1).getString("reason").length()>0);
 }
 @Test public void rejectsWrongVersionAndDuration() throws Exception {
  JSONArray source=new JSONArray("[{\"title\":\"Song\",\"artist\":\"Artist\",\"duration\":180}]");
  JSONArray catalog=new JSONArray("[{\"id\":\"two\",\"title\":\"Song remix\",\"artist\":\"Artist\",\"duration\":180},{\"id\":\"three\",\"title\":\"Song\",\"artist\":\"Artist\",\"duration\":40}]");
  assertTrue(DeviceTransferMatcher.match(source,catalog,"wide").getJSONObject(0).isNull("track_id"));
 }
}
