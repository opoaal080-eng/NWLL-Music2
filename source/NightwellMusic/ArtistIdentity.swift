import Foundation

/// A performer is credited by metadata or explicitly by the track title.
/// SoundCloud account names are not evidence of authorship.
struct ArtistSelection: Identifiable, Equatable {
    let name: String
    let seed: Track
    let titleDerived: Bool
    var id: String { ArtistIdentity.key(name) }
}

enum ArtistIdentity {
    static func key(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    static func isCloudUpload(_ track: Track) -> Bool {
        (track.source ?? "").localizedCaseInsensitiveContains("soundcloud") ||
        (track.source_url ?? "").localizedCaseInsensitiveContains("soundcloud.com")
    }

    private static let excluded: Set<String> = [
        "unknown", "unknown artist", "various artists", "various", "artist",
        "soundcloud", "music", "new music", "type beat", "beats", "official music",
        "no copyright music", "lyrics", "playlist", "radio", "mixes",
        "неизвестный исполнитель", "исполнитель", "музыка", "плейлист",
        "на этом устройстве", "nightwell music"
    ]

    static func usable(_ value: String) -> Bool {
        let normalized = key(value)
        guard normalized.count >= 2, normalized.count <= 65, !excluded.contains(normalized) else { return false }
        let generic = ["type beat", "lyrics video", "music channel", "музыкальный канал",
                       "топ трек", "подборка трек", "sped up", "slowed reverb"]
        return !generic.contains(where: { normalized.contains($0) })
    }

    /// "Artist A, Artist B feat. Artist C" -> three individually selectable artists.
    static func creditedNames(_ raw: String) -> [String] {
        var text = raw.replacingOccurrences(
            of: #"(?i)\s*[\[(]?\s*(?:feat\.?|ft\.?|featuring)\s+"#,
            with: ", ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\s+(?:x|&)\s+"#, with: ", ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[\[\]\(\)]"#, with: "", options: .regularExpression)
        var seen = Set<String>()
        return text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { usable($0) && seen.insert(key($0)).inserted }
    }

    private static func titleParts(_ title: String) -> (String, String)? {
        for separator in [" - ", " – ", " — "] {
            guard let range = title.range(of: separator) else { continue }
            let before = String(title[..<range.lowerBound])
            let after = String(title[range.upperBound...])
            if let first = creditedNames(before).first,
               usable(first), after.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                return (before, after)
            }
        }
        return nil
    }

    /// Explicit guest credit after the song title is valid evidence of a featuring artist.
    private static func featured(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern:
            #"(?i)(?:feat\.?|ft\.?|featuring)\s+([^\]\)\n]+)"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return [] }
        var names = String(text[range])
        for marker in [" - ", " – ", " — "] {
            if let position = names.range(of: marker) { names = String(names[..<position.lowerBound]) }
        }
        return creditedNames(names)
    }

    static func fromTitle(_ title: String) -> String? {
        guard let parts = titleParts(title) else { return nil }
        return creditedNames(parts.0).first
    }

    static func selections(for track: Track) -> [ArtistSelection] {
        var credited: [(name: String, titleDerived: Bool)] = []
        if let canonical = track.artist_name, !creditedNames(canonical).isEmpty {
            credited += creditedNames(canonical).map { ($0, false) }
        } else if let parts = titleParts(track.title) {
            credited += creditedNames(parts.0).map { ($0, true) }
        } else if !isCloudUpload(track) {
            credited += creditedNames(track.artist).map { ($0, false) }
        }
        // Only a literal featuring credit is taken from the title's song part.
        if let parts = titleParts(track.title) {
            credited += featured(in: parts.1).map { ($0, true) }
        } else {
            credited += featured(in: track.title).map { ($0, true) }
        }
        var seen = Set<String>()
        return credited.compactMap { item in
            guard seen.insert(key(item.name)).inserted else { return nil }
            return ArtistSelection(name: item.name, seed: track, titleDerived: item.titleDerived)
        }
    }

    static func selection(for track: Track) -> ArtistSelection? { selections(for: track).first }

    static func belongs(_ track: Track, to artist: ArtistSelection) -> Bool {
        if track.id == artist.seed.id { return true }
        return selections(for: track).contains(where: { $0.id == artist.id })
    }

    static func unique(_ tracks: [Track], for artist: ArtistSelection) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { belongs($0, to: artist) && seen.insert($0.id).inserted }
    }
}
