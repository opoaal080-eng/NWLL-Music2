import Foundation

/// Keeps server relevance, but reduces repeated recordings, artist streaks and unwanted tracks.
enum RecommendationOrder {

    /// Tiny on-device preference model. No neural inference, GPU or training server.
    /// Weights are learned once per listening session and capped to avoid feedback loops.
    static func tasteWeights() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: "nw-artist-taste-v1") as? [String: Double] ?? [:]
    }
    static func preferredArtists() -> [String] {
        UserDefaults.standard.stringArray(forKey: "nw-preferred-artists-v1") ?? []
    }
    static func seedTaste(artists: [String], mood: String) {
        let names = Array(Set(artists.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted().prefix(20)
        UserDefaults.standard.set(Array(names), forKey: "nw-preferred-artists-v1")
        UserDefaults.standard.set(mood, forKey: "nw-initial-mood-v1")
        var weights = tasteWeights()
        for name in names { weights[key(name)] = max(weights[key(name)] ?? 0, 1.9) }
        UserDefaults.standard.set(weights, forKey: "nw-artist-taste-v1")
    }
    static func learn(session: String, artist: String, seconds: Double, skipped: Bool) {
        let performer = key(artist)
        guard !session.isEmpty, !performer.isEmpty, seconds.isFinite else { return }
        let increment = skipped && seconds < 30 ? -0.95 : seconds >= 60 ? 0.45 : seconds >= 30 ? 0.24 : 0
        guard increment != 0 else { return }
        let prefs = UserDefaults.standard
        var reported = prefs.stringArray(forKey: "nw-taste-learning-sessions-v1") ?? []
        guard !reported.contains(session) else { return }
        reported.append(session)
        prefs.set(Array(reported.suffix(160)), forKey: "nw-taste-learning-sessions-v1")
        var weights = tasteWeights()
        weights[performer] = min(3, max(-2, (weights[performer] ?? 0) * 0.995 + increment))
        // Keep the stored profile small even on phones used for years.
        if weights.count > 120 { weights = Dictionary(uniqueKeysWithValues: weights.sorted { abs($0.value) > abs($1.value) }.prefix(100).map { ($0.key, $0.value) }) }
        prefs.set(weights, forKey: "nw-artist-taste-v1")
    }
    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static let alternativeVersions = ["remix", "live", "cover", "slowed", "spedup", "nightcore", "karaoke", "instrumental", "acoustic", "radioedit",
        "ремикс", "лайв", "кавер", "концерт", "караоке", "акустика", "минус", "инструментал", "замедленная", "ускоренная"]

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

    static func presentedSearchResults<T>(current: [T], incoming: [T], pending: Bool) -> [T] {
        // A pending provider's empty response is not a completed "no results".
        pending && incoming.isEmpty ? current : incoming
    }

    static func arrange<T>(_ values: [T], recent: Set<String> = [], hidden: Set<String> = [], hiddenArtists: Set<String> = [], current: String = "", identity: (T) -> String, title: (T) -> String, artist: (T) -> String) -> [T] {
        let taste = tasteWeights()
        var ids = Set<String>(), recordings = Set<String>()
        // Normalize artist names once per candidate, not on every comparison.
        // With 200 tracks the old O(n²) ranking repeatedly folded thousands of strings.
        var pool: [(rank: Int, value: T, id: String, performer: String)] = []
        pool.reserveCapacity(min(200, values.count))
        for (rank, value) in values.prefix(200).enumerated() {
            let id = identity(value), name = key(title(value)), performer = key(artist(value))
            guard id != current, !hidden.contains(id), !hiddenArtists.contains(performer),
                  ids.insert(id).inserted else { continue }
            guard name.isEmpty || performer.isEmpty || recordings.insert(performer + ":" + name).inserted else { continue }
            pool.append((rank: rank, value: value, id: id, performer: performer))
        }
        var result: [T] = [], counts: [String: Int] = [:], previous = ""
        result.reserveCapacity(pool.count)
        while !pool.isEmpty {
            func score(_ candidate: (rank: Int, value: T, id: String, performer: String)) -> Double {
                let performer = candidate.performer
                return 1 / (1 + Double(candidate.rank) * 0.12) + min(0.95, max(-0.85, (taste[performer] ?? 0) * 0.29)) - (recent.contains(candidate.id) ? 2.5 : 0)
                    - (performer.isEmpty ? 0 : Double(counts[performer, default: 0]) * 0.19 + (performer == previous ? 0.85 : 0))
            }
            var best = 0
            for index in pool.indices.dropFirst() { if score(pool[index]) > score(pool[best]) { best = index } }
            let next = pool.remove(at: best)
            result.append(next.value)
            if !next.performer.isEmpty { counts[next.performer, default: 0] += 1 }
            previous = next.performer
        }
        return result
    }
}
