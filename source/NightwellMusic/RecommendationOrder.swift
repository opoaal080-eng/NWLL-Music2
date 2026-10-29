import Foundation

/// Keeps server relevance, but reduces repeated recordings, artist streaks and unwanted tracks.
enum RecommendationOrder {
    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static let alternativeVersions = ["remix", "live", "cover", "slowed", "spedup", "nightcore", "karaoke", "instrumental", "acoustic", "radioedit"]

    static func searchScore(query: String, title: String, artist: String) -> Int {
        let wanted = key(query), name = key(title), performer = key(artist)
        guard !wanted.isEmpty else { return 0 }
        let combined = key(title + " " + artist)
        var score = 0
        if name == wanted { score += 160 }
        else if name.hasPrefix(wanted) { score += 95 }
        else if name.contains(wanted) { score += 65 }
        if performer == wanted { score += 85 }
        else if performer.hasPrefix(wanted) { score += 40 }
        if combined.contains(wanted) { score += 35 }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { key(String($0)) }.filter { !$0.isEmpty }
        if !terms.isEmpty && terms.allSatisfy({ combined.contains($0) }) { score += 40 }
        for variant in alternativeVersions where name.contains(variant) && !wanted.contains(variant) {
            score -= 35
        }
        return score
    }

    static func rankSearch<T>(_ values: [T], query: String, title: (T) -> String, artist: (T) -> String) -> [T] {
        values.enumerated().sorted { left, right in
            let a = searchScore(query: query, title: title(left.element), artist: artist(left.element))
            let b = searchScore(query: query, title: title(right.element), artist: artist(right.element))
            return a == b ? left.offset < right.offset : a > b
        }.map(\.element)
    }

    static func arrange<T>(_ values: [T], recent: Set<String> = [], hidden: Set<String> = [], current: String = "", identity: (T) -> String, title: (T) -> String, artist: (T) -> String) -> [T] {
        var ids = Set<String>(), recordings = Set<String>()
        var pool = values.prefix(200).enumerated().filter { _, value in
            let id = identity(value), name = key(title(value)), performer = key(artist(value))
            guard id != current, !hidden.contains(id), ids.insert(id).inserted else { return false }
            return name.isEmpty || performer.isEmpty || recordings.insert(performer + ":" + name).inserted
        }.map { (rank: $0.offset, value: $0.element) }
        var result: [T] = [], counts: [String: Int] = [:], previous = ""
        while !pool.isEmpty {
            func score(_ candidate: (rank: Int, value: T)) -> Double {
                let performer = key(artist(candidate.value))
                return 1 / (1 + Double(candidate.rank) * 0.12) - (recent.contains(identity(candidate.value)) ? 2.5 : 0)
                    - (performer.isEmpty ? 0 : Double(counts[performer, default: 0]) * 0.19 + (performer == previous ? 0.85 : 0))
            }
            var best = 0
            for index in pool.indices.dropFirst() { if score(pool[index]) > score(pool[best]) { best = index } }
            let next = pool.remove(at: best).value, performer = key(artist(next))
            result.append(next)
            if !performer.isEmpty { counts[performer, default: 0] += 1 }
            previous = performer
        }
        return result
    }
}
