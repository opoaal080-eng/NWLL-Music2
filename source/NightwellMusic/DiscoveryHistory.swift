import Foundation

/// Tracks real playback for two weeks, not just the last few items of one queue.
/// Keeping titles alongside IDs prevents reposts from returning under new IDs.
enum DiscoveryHistory {
    struct Entry: Codable {
        let id: String
        let recording: String
        let playedAt: TimeInterval
    }
    static let lifetime: TimeInterval = 14 * 24 * 3600
    private static let capacity = 1600

    private static func storageKey(origin: URL, account: String) -> String {
        "nw-discovery-history-v2|" + origin.absoluteString + "|" + account
    }

    static func recording(title: String, artist: String) -> String {
        var song = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var performer = artist
        if let titleArtist = ArtistIdentity.fromTitle(song) {
            performer = titleArtist
            for separator in [" - ", " – ", " — "] {
                if let range = song.range(of: separator) {
                    song = String(song[range.upperBound...])
                    break
                }
            }
        }
        let annotations = #"\s*[\[(](?:official\s+(?:audio|video)|lyrics?|visuali[sz]er|4k|hd|music\s+video)[\])]"#
        song = song.replacingOccurrences(of: annotations, with: "", options: .regularExpression)
        return RecommendationOrder.key(performer) + "|" + RecommendationOrder.key(song)
    }

    static func entries(origin: URL, account: String, now: Date = Date()) -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey(origin: origin, account: account)),
              let value = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        let earliest = now.timeIntervalSince1970 - lifetime
        return Array(value.filter { $0.playedAt >= earliest && $0.playedAt <= now.timeIntervalSince1970 + 300 }.suffix(capacity))
    }

    static func record(id: String, title: String, artist: String, origin: URL, account: String, now: Date = Date()) {
        guard !id.isEmpty else { return }
        let signature = recording(title: title, artist: artist)
        var history = entries(origin: origin, account: account, now: now)
        history.removeAll { $0.id == id || (signature != "|" && $0.recording == signature) }
        history.append(Entry(id: id, recording: signature, playedAt: now.timeIntervalSince1970))
        if let data = try? JSONEncoder().encode(Array(history.suffix(capacity))) {
            UserDefaults.standard.set(data, forKey: storageKey(origin: origin, account: account))
        }
    }

    static func ids(origin: URL, account: String, now: Date = Date()) -> Set<String> {
        Set(entries(origin: origin, account: account, now: now).map(\.id))
    }

    static func recordings(origin: URL, account: String, now: Date = Date()) -> Set<String> {
        Set(entries(origin: origin, account: account, now: now).map(\.recording))
    }

    /// Most recent first. Server accept-list limits must not discard fresh exclusions.
    static func excludedIDs(origin: URL, account: String, limit: Int = 160, now: Date = Date()) -> [String] {
        Array(entries(origin: origin, account: account, now: now).reversed().prefix(limit).map(\.id))
    }
}
