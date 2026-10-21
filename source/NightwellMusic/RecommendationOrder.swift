import Foundation

/// Rerank server candidates for variety without substituting unrelated catalogue tracks.
enum RecommendationOrder {
    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func arrange<T>(_ values: [T], recent: Set<String> = [], current: String = "", identity: (T) -> String, title: (T) -> String, artist: (T) -> String) -> [T] {
        var ids = Set<String>(), recordings = Set<String>()
        var pool = values.prefix(200).enumerated().filter { _, value in
            let id = identity(value), name = key(title(value)), performer = key(artist(value))
            guard id != current, ids.insert(id).inserted else { return false }
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
            result.append(next); if !performer.isEmpty { counts[performer, default: 0] += 1 }; previous = performer
        }
        return result
    }
}
