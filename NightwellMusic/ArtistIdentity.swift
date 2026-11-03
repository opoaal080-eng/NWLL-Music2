import Foundation

/// A profile is based on track metadata, not on the SoundCloud upload account.
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

    private static func lead(_ input: String) -> String {
        let withoutFeature = input.replacingOccurrences(
            of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#,
            with: "", options: .regularExpression)
        return (withoutFeature.components(separatedBy: ",").first ?? withoutFeature)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Some uploaders put the actual performer in 'Performer - Song'.
    static func fromTitle(_ title: String) -> String? {
        for separator in [" - ", " – ", " — "] {
            guard let range = title.range(of: separator) else { continue }
            let before = String(title[..<range.lowerBound])
            let after = String(title[range.upperBound...])
            let candidate = lead(before)
            if usable(candidate), after.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                return candidate
            }
        }
        return nil
    }

    static func selection(for track: Track) -> ArtistSelection? {
        if let name = fromTitle(track.title) {
            return ArtistSelection(name: name, seed: track, titleDerived: true)
        }
        let name = lead(track.artist)
        guard usable(name) else { return nil }
        return ArtistSelection(name: name, seed: track, titleDerived: false)
    }

    static func belongs(_ track: Track, to artist: ArtistSelection) -> Bool {
        if track.id == artist.seed.id { return true }
        if let titleArtist = fromTitle(track.title) {
            return key(titleArtist) == artist.id
        }
        // Without an explicit name in the title, SoundCloud's artist field may
        // actually be the uploader. Never group their uploads by that field.
        guard !isCloudUpload(track) else { return false }
        return key(lead(track.artist)) == artist.id && usable(track.artist)
    }

    static func unique(_ tracks: [Track], for artist: ArtistSelection) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { belongs($0, to: artist) && seen.insert($0.id).inserted }
    }
}
