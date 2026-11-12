import Foundation

/// Shared, deterministic metadata features used by retrieval, rules and the trained ranker.
/// Titles are identities, not semantic descriptions: related meanings are not matches.
enum TransferText {
    private static let russian: [Character: String] = {
        let a = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
        let b = ["a","b","v","g","d","e","e","zh","z","i","y","k","l","m","n","o","p","r","s","t","u","f","h","ts","ch","sh","sch","","y","","e","yu","ya"]
        return Dictionary(uniqueKeysWithValues: zip(a, b))
    }()
    private static let lookalikes: [Character: Character] = ["а":"a","е":"e","о":"o","р":"p","с":"c","у":"y","х":"x","к":"k","м":"m","т":"t","в":"b","н":"h"]
    static func replace(_ value: String, _ pattern: String, _ replacement: String = " ") -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    static func key(_ value: String) -> String {
        let text = value.precomposedStringWithCompatibilityMapping.lowercased()
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { part -> String in
            let chars = Array(part)
            let latin = chars.filter { $0.isASCII && $0.isLetter }.count
            let cyrillic = chars.filter { russian[$0] != nil }.count
            return chars.map { c -> String in
                if latin > cyrillic, cyrillic <= 2, let visual = lookalikes[c] { return String(visual) }
                return russian[c] ?? String(c)
            }.joined()
        }.joined(separator: " ")
        return words.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func compact(_ value: String) -> String { value.replacingOccurrences(of: " ", with: "") }
    static func phonetic(_ value: String) -> String {
        var s = value
        for (a,b) in [("shch","sch"),("kh","h"),("yo","e"),("ye","e"),("iy","i"),("ii","i")] { s = s.replacingOccurrences(of: a, with: b) }
        return s
    }
    static func isrc(_ value: String?) -> String? {
        guard let value else { return nil }
        let code = replace(value.uppercased(), #"[\s-]"#, "")
        return code.range(of: #"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"#, options: .regularExpression) == nil ? nil : code
    }
    static func cleanTitle(_ title: String) -> String {
        var value = replace(title, #"(?i)[\(\[【](?![^\)\]】]*\b(?:remix|ремикс|live|acoustic|instrumental|cover|karaoke|sped|slowed|reverb|remaster))[^\)\]】]*(?:official|music\s+video|audio|lyrics?|visuali[sz]er|официальн|видеоклип|текст\s+песни|320\s*k?bps|hq|hd|4k)[^\)\]】]*[\)\]】]"#)
        value = replace(value, #"(?i)\s+(?:[-–—|:]\s*)?(?:official\s+(?:music\s+)?(?:audio|video)|official|lyrics?\s+video|visuali[sz]er|официальн\w*\s+клип|320\s*k?bps|hq|hd|4k)\s*$"#)
        // Featuring belongs to artist credits; it does not change the song title.
        value = replace(value, #"(?i)\s*[\(\[]?\b(?:feat\.?|ft\.?|featuring|при\s+участии)\s+[^\)\]]+[\)\]]?"#)
        return replace(value, #"\s+"#).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:")))
    }
    static func artists(_ credit: String) -> [String] {
        let separated = replace(credit, #"(?i)\s+(?:feat\.?|ft\.?|featuring|with|x|и)\s+|\s*[,&;/+]\s*"#, "\n")
        var seen = Set<String>()
        return separated.components(separatedBy: .newlines).map(key).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    static func primaryArtist(_ credit: String) -> String {
        let separated = replace(credit, #"(?i)\s+(?:feat\.?|ft\.?|featuring|with|x|и)\s+|\s*[,&;/+]\s*"#, "\n")
        return separated.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? credit
    }
    static func grams(_ s: String) -> Set<String> {
        let chars = Array(compact(s).prefix(96))
        guard chars.count >= 3 else { return chars.isEmpty ? [] : [String(chars)] }
        return Set((0..<(chars.count - 2)).map { String(chars[$0...($0 + 2)]) })
    }
    static func similarity(_ left: String, _ right: String) -> Double {
        if left == right { return left.isEmpty ? 0 : 1 }
        let a = Array(left.prefix(180)), b = Array(right.prefix(180))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count), before = previous
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(row[j - 1] + 1, previous[j] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { row[j] = min(row[j], before[j - 2] + 1) }
            }
            before = previous; previous = row
        }
        return max(0, 1 - Double(previous[b.count]) / Double(max(a.count, b.count)))
    }
    static func tokenSimilarity(_ left: String, _ right: String) -> Double {
        let a = left.split(separator: " ").map(String.init), b = right.split(separator: " ").map(String.init)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        func recall(_ x: [String], _ y: [String]) -> Double {
            x.reduce(0) { sum, word in sum + (y.map { similarity(word, $0) }.max() ?? 0) } / Double(x.count)
        }
        return min(recall(a,b), recall(b,a))
    }
    static func dice(_ a: String, _ b: String) -> Double {
        let x = grams(a), y = grams(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }
    struct Title: Sendable {
        let core: String
        let versions: Set<String>
        let detail: String
    }
    static func title(_ raw: String) -> Title {
        let cleaned = cleanTitle(raw)
        let marker = #"(?i)\b(remix|ремикс|live|concert|концерт\w*|acoustic|акуст\w*|instrumental|инструментал|karaoke|караоке|cover|кавер|sped\s*up|speed\s*up|nightcore|slowed|замедлен\w*|reverb|remaster\w*|ремастер\w*|radio\s+edit|extended|clean\s+version|demo|демо)\b"#
        let tags = #"[\(\[]([^\)\]]+)[\)\]]|(?:\s+[-–—|:]\s+)([^\n]+)$"#
        let regex = try! NSRegularExpression(pattern: tags)
        var sections: [String] = [], core = cleaned
        for match in regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)).reversed() {
            guard let range = Range(match.range, in: cleaned) else { continue }
            let section = String(cleaned[range])
            if section.range(of: marker, options: .regularExpression) != nil {
                sections.append(section)
                if let r = Range(match.range, in: core) { core.removeSubrange(r) }
            }
        }
        // A trailing version label is common without brackets. Do not classify
        // natural titles such as "Live Forever" or "Cover Me" as versions.
        let trailing = #"(?i)\s+(remix|ремикс|live|acoustic|instrumental|karaoke|cover|sped\s*up|nightcore|slowed(?:\s*[+&]\s*reverb)?|remaster(?:ed)?(?:\s+\d{4})?|radio\s+edit|extended|demo)\s*$"#
        if let r = core.range(of: trailing, options: .regularExpression), !core[..<r.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
            sections.append(String(core[r])); core.removeSubrange(r)
        }
        var versions = Set<String>(), details: [String] = []
        for section in sections {
            let s = key(section)
            let mappings: [(String,String)] = [("remix|remiks","remix"),("live|concert|kontsert","live"),("acoustic|akust","acoustic"),("instrumental","instrumental"),("karaoke","karaoke"),("cover|kaver","cover"),("sped|speed|nightcore","sped"),("slowed|zamedlen","slowed"),("reverb","reverb"),("remaster","remaster"),("radio edit","radio"),("extended","extended"),("clean version","clean"),("demo","demo")]
            for (pattern,name) in mappings where s.range(of: #"\b(?:"# + pattern + #")\w*\b"#, options: .regularExpression) != nil { versions.insert(name) }
            if s.contains("remix") || s.contains("remiks") {
                let detail = replace(s, #"\b(?:remix|remiks|version|versiya|mix|official|audio|video|hq|hd)\b|\b\d{4}\b"#).trimmingCharacters(in: .whitespaces)
                if !detail.isEmpty { details.append(detail) }
            }
        }
        return Title(core: key(core), versions: versions, detail: details.sorted().joined(separator: " "))
    }
}

struct TransferMetadata: Sendable {
    struct Variant: Sendable {
        let title: TransferText.Title
        let artist: String
        let credits: [String]
        let embedded: Bool
    }
    let id: String
    let rawTitle: String
    let rawArtist: String
    let duration: Double?
    let isrc: String?
    let variants: [Variant]
    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        rawTitle = row["title"] as? String ?? ""
        rawArtist = row["artist"] as? String ?? ""
        let seconds = (row["duration"] as? NSNumber)?.doubleValue
        duration = seconds.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? $0 : nil }
        isrc = TransferText.isrc(row["isrc"] as? String)
        var pairs: [(String,String,Bool)] = [(rawTitle,rawArtist,false)]
        for field in ["performer","artist_credit","metadata_artist"] {
            if let credit = row[field] as? String, !credit.isEmpty { pairs.append((rawTitle,credit,false)) }
        }
        for divider in [" - "," — "," – "," | "," : "] {
            if let r = rawTitle.range(of: divider) {
                let a = String(rawTitle[..<r.lowerBound]), b = String(rawTitle[r.upperBound...])
                if !a.isEmpty, !b.isEmpty { pairs.append((b,a,true)); pairs.append((a,b,true)) }
                break
            }
        }
        var seen = Set<String>()
        variants = pairs.compactMap { title,artist,embedded in
            let t = TransferText.title(title), a = TransferText.key(artist)
            guard !t.core.isEmpty, !a.isEmpty, a != TransferText.key("Исполнитель не указан"),
                  seen.insert(t.core + "|" + a + "|" + t.versions.sorted().joined()).inserted else { return nil }
            return Variant(title: t, artist: a, credits: TransferText.artists(artist), embedded: embedded)
        }
    }
}

enum TransferSimilarity {
    struct Pair {
        let features: [Double]
        let versionConflict: Bool
        let durationConflict: Bool
        let isrcConflict: Bool
        var title: Double { features[0] }
        var artist: Double { features[4] }
        var exact: Bool { features[9] == 1 && features[10] == 1 && features[12] == 1 }
        var heuristic: Double { 0.64 * title + 0.30 * artist + 0.06 * (features[8] == 1 ? features[7] : 0.8) }
    }
    /// Stable feature order is also consumed by scripts/train-transfer-model.py.
    static func compare(_ query: TransferMetadata, _ candidate: TransferMetadata) -> Pair? {
        var best: Pair?
        for a in query.variants {
            for b in candidate.variants {
                let compact = TransferText.similarity(TransferText.compact(a.title.core), TransferText.compact(b.title.core))
                let edit = TransferText.similarity(a.title.core,b.title.core)
                let token = TransferText.tokenSimilarity(a.title.core,b.title.core)
                let titleScore = max(edit, compact, token * 0.99)
                let artistFull = max(TransferText.similarity(a.artist,b.artist), TransferText.tokenSimilarity(a.artist,b.artist))
                var artistScore = artistFull, artistExact = a.artist == b.artist, primary = 0.0
                for (i,x) in a.credits.enumerated() {
                    for (j,y) in b.credits.enumerated() {
                        let value = max(TransferText.similarity(x,y), TransferText.similarity(TransferText.phonetic(x),TransferText.phonetic(y)) * 0.99)
                        if i == 0 || j == 0 { artistScore = max(artistScore,value) }
                        if x == y, i == 0 || j == 0 { artistExact = true }
                        if i == 0, j == 0 { primary = value }
                    }
                }
                let hardA = a.title.versions.subtracting(["remaster"]), hardB = b.title.versions.subtracting(["remaster"])
                var versionConflict = hardA != hardB
                if !a.title.detail.isEmpty, !b.title.detail.isEmpty,
                   TransferText.similarity(a.title.detail,b.title.detail) < 0.92 { versionConflict = true }
                let durationKnown = query.duration != nil && candidate.duration != nil
                let delta = abs((query.duration ?? 0) - (candidate.duration ?? 0))
                let durationScore = durationKnown ? max(0,1 - delta / max(12,(query.duration ?? 0) * 0.08)) : 0.5
                let durationConflict = durationKnown && delta > max(15,(query.duration ?? 0) * 0.12)
                let f: [Double] = [titleScore,compact,token,TransferText.dice(a.title.core,b.title.core),
                    artistScore,artistFull,TransferText.tokenSimilarity(a.artist,b.artist),durationScore,
                    durationKnown ? 1 : 0, a.title.core == b.title.core || TransferText.compact(a.title.core) == TransferText.compact(b.title.core) ? 1 : 0,
                    artistExact ? 1 : 0,primary,a.title.versions == b.title.versions && !versionConflict ? 1 : 0,
                    b.embedded ? 1 : 0,query.isrc != nil && query.isrc == candidate.isrc ? 1 : 0,
                    min(1,Double(TransferText.compact(a.title.core).count) / 16)]
                let pair = Pair(features:f,versionConflict:versionConflict,durationConflict:durationConflict,
                    isrcConflict:query.isrc != nil && candidate.isrc != nil && query.isrc != candidate.isrc)
                // A mismatched version must not hide a valid explicit Artist - Title variant.
                let rank = pair.heuristic - (versionConflict ? 1 : 0)
                let previous = best.map { $0.heuristic - ($0.versionConflict ? 1 : 0) } ?? -Double.infinity
                if rank > previous { best = pair }
            }
        }
        return best
    }
    static func sameRecording(_ a: TransferMetadata, _ b: TransferMetadata) -> Bool {
        if let x = a.isrc, let y = b.isrc { return x == y }
        guard let pair = compare(a,b), !pair.versionConflict, !pair.isrcConflict,
              pair.features[9] == 1, pair.features[10] == 1 else { return false }
        if let x = a.duration, let y = b.duration { return abs(x-y) <= max(3,min(x,y)*0.02) }
        return true
    }
}
