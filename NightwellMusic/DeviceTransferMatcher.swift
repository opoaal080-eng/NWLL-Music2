import Foundation

/// CPU-heavy import matching runs only on the user's device. No per-track
/// /api/tracks?q=... calls and no background matching job on the music server.
enum DeviceTransferMatcher {
    private struct Entry {
        let id: String
        let title: String
        let artist: String
        let duration: Double?
        let normalizedTitle: String
        let normalizedArtist: String
        let variants: [(String, String)]
    }

    private static let versionWords: Set<String> = [
        "remix", "ремикс", "live", "concert", "концерт",
        "acoustic", "акустика", "instrumental", "караоке", "karaoke",
        "sped", "slowed", "cover", "кавер", "remaster", "remastered",
        "extended", "reverb", "edit"
    ]
    private static let letters: [Character: String] = {
        let russian = Array("абвгдежзийклмнопрстуфхцчшщыэюя")
        let latin = ["a","b","v","g","d","e","zh","z","i","y","k","l",
                     "m","n","o","p","r","s","t","u","f","h","ts","ch",
                     "sh","sch","y","e","yu","ya"]
        return Dictionary(uniqueKeysWithValues: zip(russian, latin))
    }()
    private static func key(_ raw: String) -> String {
        let text = raw.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(
                of: #"\b(?:official\s+(?:music\s+)?(?:video|audio)|lyrics?\s+video|official|lyrics?|hq|hd|4k)\b"#,
                with: " ", options: .regularExpression)
        let stripped = text.replacingOccurrences(of: #"[^\p{L}\p{N}]+|\b[ъь]\b"#,
                                                     with: " ", options: .regularExpression)
        return stripped.split(whereSeparator: { $0.isWhitespace })
            .map { word in String(word).map { letters[$0] ?? String($0) }.joined() }
            .joined(separator: " ")
    }
    private static func versions(_ s: String) -> Set<String> {
        Set(s.split(separator: " ").map(String.init)).intersection(versionWords)
    }
    private static func closeness(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let x = Array(a), y = Array(b)
        guard x.count <= 140 && y.count <= 140 else { return 0 }
        var previous = Array(0...y.count)
        for i in x.indices {
            var current = [i + 1] + [Int](repeating: 0, count: y.count)
            for j in y.indices {
                current[j + 1] = min(previous[j + 1] + 1,
                                     current[j] + 1,
                                     previous[j] + (x[i] == y[j] ? 0 : 1))
            }
            previous = current
        }
        let edit = 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
        let left = Set(a.split(separator: " "))
        let right = Set(b.split(separator: " "))
        let overlap = left.isEmpty || right.isEmpty ? 0 :
            Double(left.intersection(right).count) / Double(max(left.count, right.count))
        return max(edit, overlap)
    }

    private static func score(title: String, artist: String,
                              duration: Double?, candidate: Entry, mode: String) -> Double? {
        if let duration, duration > 0, let other = candidate.duration, other > 0,
           abs(duration - other) > max(14, duration * 0.13) { return nil }
        let limits: (Double,Double,Double)
        switch mode {
        case "safe": limits = (0.95,0.90,0.93)
        case "wide": limits = (0.85,0.80,0.85)
        default: limits = (0.89,0.85,0.89)
        }
        var best = 0.0
        for (candidateTitle, candidateArtist) in candidate.variants {
            if versions(title) != versions(candidateTitle) { continue }
            let ts = closeness(title,candidateTitle)
            let ars = closeness(artist,candidateArtist)
            let total = 0.65 * ts + 0.35 * ars
            if ts >= limits.0 && ars >= limits.1 && total >= limits.2 {
                best = max(best,total)
            }
        }
        return best > 0 ? best : nil
    }

    /// Input is prepared by TransferPreparation. Catalog is serialized once,
    /// then processed on a background executor, keeping SwiftUI responsive.
    static func match(prepared: String, catalogJSON: Data,
                      mode: String = "balanced") throws -> [[String: Any]] {
        guard let originals = try JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [[String:Any]],
              let catalog = try JSONSerialization.jsonObject(with: catalogJSON) as? [[String:Any]] else {
            throw TransferPreparation.fail("Неверный формат списка для переноса")
        }
        var entries: [Entry] = []
        var byTitle: [String:[Int]] = [:]
        var byArtist: [String:[Int]] = [:]
        for value in catalog.prefix(200_000) {
            guard let id = value["id"] as? String,
                  id.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
                  let rawTitle = value["title"] as? String,
                  let rawArtist = value["artist"] as? String else { continue }
            let title = key(rawTitle), artist = key(rawArtist)
            guard !title.isEmpty else { continue }
            var variants: [(String,String)] = [(title,artist)]
            for divider in [" - ", " — ", " – ", " | ", " : "] {
                if let range = rawTitle.range(of: divider) {
                    let left = key(String(rawTitle[..<range.lowerBound]))
                    let right = key(String(rawTitle[range.upperBound...]))
                    if !left.isEmpty && !right.isEmpty {
                        variants.append((right,left))
                        variants.append((left,right))
                    }
                    break
                }
            }
            let entry = Entry(id:id,title:rawTitle,artist:rawArtist,
                              duration:value["duration"] as? Double,
                              normalizedTitle:title,normalizedArtist:artist,
                              variants:variants)
            let pos = entries.count
            entries.append(entry)
            for (candidateTitle,candidateArtist) in variants {
                byTitle[candidateTitle,default:[]].append(pos)
                byArtist[candidateArtist,default:[]].append(pos)
            }
        }
        var results: [[String: Any]] = []
        for item in originals {
            guard let title = item["title"] as? String,
                  let artist = item["artist"] as? String else { continue }
            let titleKey = key(title), artistKey = key(artist)
            var possible = Set(byTitle[titleKey] ?? [])
            possible.formUnion((byArtist[artistKey] ?? []).prefix(250))
            // The title, rather than a generic uploader, determines whether
            // an item belongs in the candidate pool.
            let candidates = possible.sorted().prefix(500)
            var ranked: [(Double,Int)] = []
            for index in candidates {
                if let value = score(title:titleKey,artist:artistKey,
                                     duration:item["duration"] as? Double,
                                     candidate:entries[index],mode:mode) {
                    ranked.append((value,index))
                }
            }
            ranked.sort { $0.0 > $1.0 }
            var output = item
            if let best = ranked.first,
               ranked.count < 2 || best.0 >= 0.999 || best.0 - ranked[1].0 >= 0.025 {
                let winner = entries[best.1]
                output["track_id"] = winner.id
                output["found_title"] = winner.title
                output["found_artist"] = winner.artist
                output["reason"] = ""
            } else {
                output["track_id"] = NSNull()
                output["reason"] = ranked.isEmpty
                    ? "Не найдено надёжного совпадения в каталоге"
                    : "Несколько похожих версий, нужна ручная проверка"
            }
            results.append(output)
        }
        return results
    }
}
