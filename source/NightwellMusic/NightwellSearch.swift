import Foundation

/// Search is permissive about typography, but ranks literal recording identities
/// ahead of ownership, partial words and approximate matches.
enum NightwellSearch {
    struct Query: Sendable {
        let text: String
        let compact: String
        let tokens: [String]
        let title: TransferText.Title
        init(_ raw: String) {
            text = TransferText.key(raw)
            compact = TransferText.compact(text)
            tokens = text.split(separator: " ").map(String.init)
            title = TransferText.title(raw)
        }
        func score(title rawTitle: String, artist rawArtist: String) -> Int {
            guard !compact.isEmpty else { return 0 }
            let name = TransferText.key(rawTitle), artist = TransferText.key(rawArtist)
            let n = TransferText.compact(name), a = TransferText.compact(artist)
            if compact == n || compact == a + n || compact == n + a { return 10_000 }
            let cleaned = TransferText.title(rawTitle)
            let core = TransferText.compact(cleaned.core)
            let wanted = TransferText.compact(title.core)
            let versionPenalty = cleaned.versions.subtracting(title.versions).subtracting(["remaster"]).isEmpty ? 0 : 2200
            if wanted == core || wanted == a + core || wanted == core + a {
                return 9500 - versionPenalty
            }
            if compact == a { return 8500 }
            let combined = name + " " + artist
            if !tokens.isEmpty && tokens.allSatisfy({ combined.contains($0) }) {
                return 7500 - versionPenalty
            }
            if n.hasPrefix(compact) { return 6800 - versionPenalty }
            if n.contains(compact) || a.contains(compact) { return 6000 - versionPenalty }
            // Cheap trigrams reject unrelated catalogue entries before edit distance.
            // Very short queries deliberately do not use fuzzy matching.
            guard compact.count >= 5 else { return 0 }
            let dice = max(TransferText.dice(text,name), TransferText.dice(text,artist))
            guard dice >= 0.32 else { return 0 }
            let similarity = max(TransferText.similarity(compact,n), TransferText.similarity(compact,a))
            if similarity >= 0.74 { return 3000 + Int(similarity * 1000) - versionPenalty }
            return 0
        }
    }

    static func ordered<T>(_ values: [T], query: String, priorityIDs: Set<String> = [],
                           limit: Int = 140, localOnly: Bool = false,
                           id: (T) -> String, title: (T) -> String, artist: (T) -> String) -> [T] {
        let wanted = Query(query)
        var seen = Set<String>()
        // Compute each expensive score once, never inside the sort comparator.
        var ranked: [(value:T,score:Int,owned:Bool,offset:Int)] = []
        for (offset,value) in values.enumerated() {
            if offset % 64 == 0 && Task.isCancelled { return [] }
            let identity = id(value)
            guard seen.insert(identity).inserted else { continue }
            let score = wanted.score(title:title(value),artist:artist(value))
            if !localOnly || score > 0 { ranked.append((value,score,priorityIDs.contains(identity),offset)) }
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.owned != $1.owned { return $0.owned }
            return $0.offset < $1.offset
        }.prefix(max(0,limit)).map(\.value)
    }

    /// Keep source snapshots and spelling variants in one result pool.
    /// New metadata replaces old metadata without moving an existing identity.
    struct Pool<T> {
        private var values: [String:T] = [:]
        private var ids: [String] = []
        var all: [T] { ids.compactMap { values[$0] } }
        mutating func merge(_ incoming: [T], id: (T) -> String) {
            for value in incoming {
                let key = id(value)
                if values[key] == nil { ids.append(key) }
                values[key] = value
            }
        }
    }

    static func queries(_ raw: String) -> [String] {
        let literal = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = literal.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        var candidates = [literal, plain, TransferText.cleanTitle(plain), TransferText.key(plain)]
        for divider in [" - "," — "," – "] {
            if let range = literal.range(of:divider) {
                candidates.append(String(literal[range.upperBound...]))
                break
            }
        }
        let words = plain.split(separator:" ").map(String.init).filter { $0.count >= 4 }
        if words.count >= 2 {
            // If a misspelled word makes the provider's AND query empty, search
            // the other distinctive words and rank the union against the full input.
            candidates.append(words.suffix(2).joined(separator:" "))
            candidates.append(words.last!)
            candidates.append(words.first!)
        }
        var seen = Set<String>()
        return candidates.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter {
            $0.count >= 2 && seen.insert($0.lowercased()).inserted
        }.prefix(6).map { $0 }
    }
}
