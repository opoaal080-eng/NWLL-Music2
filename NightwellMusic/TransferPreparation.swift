import Foundation

// Pure metadata work, invoked off the main actor before sending the job.
enum TransferPreparation {
    static func key(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func fail(_ message: String) -> NSError {
        NSError(domain: "NightwellImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func prepare(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard text.utf8.count <= 1024 * 1024 else { throw fail("Максимальный размер 1 МБ") }
        var tracks: [[String: Any]] = []
        func append(_ title: String, _ artist: String, _ duration: Double? = nil, _ isrc: String? = nil) throws {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines), artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !artist.isEmpty, title.count <= 300, artist.count <= 300 else { throw fail("Проверь название и исполнителя трека") }
            var row: [String: Any] = ["title": title, "artist": artist]
            if let duration, duration.isFinite, duration > 0, duration < 86400 { row["duration"] = duration }
            if let isrc {
                let code = isrc.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if code.range(of: #"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"#, options: .regularExpression) != nil { row["isrc"] = code }
            }
            tracks.append(row)
            guard tracks.count <= 1000 else { throw fail("Раздели список на части до 1000 треков") }
        }
        if text.hasPrefix("[") || text.hasPrefix("{") {
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
            let document = value as? [String: Any]
            guard let rows = (value as? [[String: Any]])
                ?? (document?["tracks"] as? [[String: Any]])
                ?? (document?["items"] as? [[String: Any]])
                ?? (document?["audios"] as? [[String: Any]])
                ?? ((document?["playlist"] as? [String: Any])?["tracks"] as? [[String: Any]])
                ?? ((document?["response"] as? [String: Any])?["items"] as? [[String: Any]]) else { throw fail("В JSON нужен массив tracks, items или audios") }
            for source in rows {
                let row = source["track"] as? [String: Any]
                    ?? source["audio"] as? [String: Any]
                    ?? source["song"] as? [String: Any] ?? source
                let artists = row["artist"] ?? row["artists"] ?? row["performer"] ?? row["artist_name"] ?? row["artistName"]
                let artist: String
                if let list = artists as? [Any] { artist = list.compactMap { ($0 as? String) ?? ($0 as? [String: Any])?["name"] as? String }.joined(separator: ", ") }
                else { artist = (artists as? String) ?? (artists as? [String: Any])?["name"] as? String ?? "" }
                let duration = (row["duration"] as? NSNumber)?.doubleValue
                    ?? ((row["duration_ms"] ?? row["durationMs"]) as? NSNumber).map { $0.doubleValue / 1000 }
                var title = (row["title"] ?? row["name"]) as? String ?? ""
                if let version = row["version"] as? String, !key(version).isEmpty, !key(title).contains(key(version)) {
                    title += " (" + version.trimmingCharacters(in: .whitespacesAndNewlines) + ")"
                }
                let isrc = (row["isrc"] as? String)
                    ?? (row["external_ids"] as? [String: Any])?["isrc"] as? String
                    ?? (row["externalIds"] as? [String: Any])?["isrc"] as? String
                try append(title, artist, duration, isrc)
            }
        } else {
            var parsed = false
            for delimiter in [Character("\t"), Character(";"), Character(",")] {
                let table = csv(text, delimiter: delimiter)
                guard let first = table.first else { continue }
                let keys = first.map { key($0).replacingOccurrences(of: " ", with: "") }
                guard let ti = keys.firstIndex(where: { ["title","track","trackname","song","songname","название","названиетрека","трек"].contains($0) }),
                      let ai = keys.firstIndex(where: { ["artist","artists","artistname","artistnames","исполнитель","исполнители"].contains($0) }) else { continue }
                for row in table.dropFirst() where !row.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard row.count > max(ti, ai) else { throw fail("Неполная строка CSV") }
                    let isrcIndex = keys.firstIndex(of: "isrc")
                    let durationIndex = keys.firstIndex(where: { ["duration","durationms","длительность"].contains($0) })
                    let durationValue = durationIndex.flatMap { $0 < row.count ? Double(row[$0]) : nil }
                    let seconds = durationIndex.map { keys[$0] == "durationms" } == true ? durationValue.map { $0 / 1000 } : durationValue
                    try append(row[ti], row[ai], seconds,
                               isrcIndex.flatMap { $0 < row.count ? row[$0] : nil })
                }
                parsed = true; break
            }
            if !parsed {
                for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let range = line.range(of: "\\s+[—–-]\\s+|\\t", options: .regularExpression) else { throw fail("Нужен формат «Исполнитель — Название» или CSV с заголовком") }
                    try append(String(line[range.upperBound...]), String(line[..<range.lowerBound]))
                }
            }
        }
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert(key($0["artist"] as? String ?? "") + "\n" + key($0["title"] as? String ?? "")).inserted }
        guard !unique.isEmpty else { throw fail("В списке нет треков") }
        return String(decoding: try JSONSerialization.data(withJSONObject: unique), as: UTF8.self)
    }
    /// Try the original query first, then remove uploader decorations and
    /// featuring credits. This is metadata search, not access to source audio.
    static func searchQueries(title: String, artist: String) -> [String] {
        let cleaned = title
            .replacingOccurrences(of: #"(?i)\([^)]*(?:official|video|audio|lyrics?|visualizer)[^)]*\)"#,
                                  with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:feat\.?|ft\.?|featuring)\s+.+$"#,
                                  with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:official|music video|lyrics? video|visualizer|audio)\b"#,
                                  with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var queries: [String] = []
        var seen = Set<String>()
        for query in [artist + " " + title, artist + " " + cleaned, cleaned, title] {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, seen.insert(key(text)).inserted {
                queries.append(text)
            }
            if queries.count == 3 { break }
        }
        return queries
    }
    private static func csv(_ text: String, delimiter: Character) -> [[String]] {
        let chars = Array(text); var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append(c); i += 1 }
                else { quoted.toggle() }
            } else if !quoted && (c == delimiter || c == "\n" || c == "\r" || c == "\r\n") {
                row.append(field); field = ""
                if c != delimiter { rows.append(row); row = []; if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 } }
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { return [] }
        row.append(field); rows.append(row); return rows
    }
}

