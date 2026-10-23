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
  let txt = try rows("Ёлка — Трек\nЕлка - Трек")
  precondition(txt.count == 1)
  do { _ = try rows("artist,title\nArtist"); fatalError("Malformed CSV accepted") } catch {}
  print("Transfer parsing, quotes, duplicate removal and duration passed")
 }
}
