import Foundation
@main struct TransferTests {
 static func rows(_ text: String) throws -> [[String: Any]] {
  try JSONSerialization.jsonObject(with: Data(TransferPreparation.prepare(text).utf8)) as! [[String: Any]]
 }
 static func main() throws {
  let csv = try rows("artist,title\r\nArtist,\"Song, part 1\"\r\nArtist,\"Song, part 1\"\r\n")
  precondition(csv.count == 1 && csv[0]["title"] as? String == "Song, part 1")
  let json = try rows("{\"tracks\":[{\"track\":{\"name\":\"Song\",\"artists\":[{\"name\":\"Artist\"}],\"duration_ms\":180000}}]}")
  precondition(json[0]["duration"] as? Double == 180)
  let versions = try rows("[{\"title\":\"Song\",\"artist\":\"Artist\"},{\"title\":\"Song\",\"artist\":\"Artist\",\"version\":\"Live\"}]")
  precondition(versions.count == 2 && versions[1]["title"] as? String == "Song (Live)")
  let labelled = try rows("[{\"title\":\"Song (Live)\",\"artist\":\"Artist\",\"version\":\"Live\"}]")
  precondition(labelled[0]["title"] as? String == "Song (Live)")
  let txt = try rows("Ёлка — Трек\nЕлка - Трек")
  precondition(txt.count == 1)
  let recordings = try rows(#"[{"title":"Song","artist":"Artist","isrc":"us-abc-24-00001"},{"title":"Song","artist":"Artist","isrc":"USABC2400002"},{"title":"Song (Official Audio)","artist":"Artist","isrc":"USABC2400001"}]"#)
  precondition(recordings.count == 2, "Distinct recording identities were lost or one ISRC was duplicated")
  precondition(recordings[0]["isrc"] as? String == "USABC2400001", "Formatted ISRC was discarded before matching")
  let codes = try rows("artist,title,isrc\nArtist,Song,US-ABC-24-00001\nArtist,Song,USABC2400002")
  precondition(codes.count == 2 && codes[0]["isrc"] as? String == "USABC2400001")
  do { _ = try rows("artist,title\nArtist"); fatalError("Malformed CSV accepted") } catch {}
  print("Transfer parsing, quotes, duplicate recording identities, ISRC normalization and duration passed")
 }
}

