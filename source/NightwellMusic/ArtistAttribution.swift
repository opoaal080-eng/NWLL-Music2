import Foundation

/// Remote audio services sometimes use the posting account as their artist field.
/// Only a dedicated performer credit or an explicit Artist — Song title can override it.
enum ArtistAttribution {
    static let unknown = "Исполнитель не указан"

    struct Result: Equatable {
        let title: String
        let artist: String
        let uploader: String?
        let attributed: Bool
    }

    static func isRemote(source: String?, sourceURL: String?, remote: Bool?) -> Bool {
        if remote == true { return true }
        if source?.lowercased().contains("soundcloud") == true { return true }
        guard let sourceURL, let host = URL(string: sourceURL)?.host?.lowercased() else { return false }
        return host == "soundcloud.com" || host.hasSuffix(".soundcloud.com")
    }

    static func extract(_ title: String) -> (performer: String, song: String)? {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" - ", " – ", " — "]
        guard let separator = separators.compactMap({ s -> (String, Range<String.Index>)? in
            guard let range = raw.range(of: s) else { return nil }
            return (s, range)
        }).sorted(by: { $0.1.lowerBound < $1.1.lowerBound }).first else { return nil }
        let performer = String(raw[..<separator.1.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let song = String(raw[separator.1.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...90).contains(performer.count), (2...250).contains(song.count),
              performer.rangeOfCharacter(from: .letters) != nil,
              song.rangeOfCharacter(from: .letters) != nil else { return nil }
        let invalid = ["remix", "live", "slowed", "sped up", "spedup", "nightcore",
                       "instrumental", "radio edit", "official", "lyrics",
                       "ремикс", "лайв", "ускоренная", "замедленная", "кавер", "инструментал"]
        let lower = song.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invalid.contains(lower), !performer.lowercased().hasPrefix("prod."),
              !performer.lowercased().hasPrefix("produced by") else { return nil }
        return (performer, song)
    }

    static func resolve(title: String, artist: String, source: String? = nil,
                        sourceURL: String? = nil, remote: Bool? = nil,
                        performer: String? = nil, artistCredit: String? = nil,
                        metadataArtist: String? = nil) -> Result {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteUpload = isRemote(source: source, sourceURL: sourceURL, remote: remote)
        guard remoteUpload else { return Result(title: title, artist: raw, uploader: nil, attributed: !raw.isEmpty) }

        let direct = [metadataArtist, performer, artistCredit]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != unknown }
        if let direct {
            let parsed = extract(title)
            let cleanedTitle: String
            if let parsed, parsed.performer.compare(direct, options: .caseInsensitive) == .orderedSame {
                cleanedTitle = parsed.song
            } else {
                cleanedTitle = title
            }
            return Result(title: cleanedTitle, artist: direct,
                          uploader: raw.isEmpty ? nil : raw, attributed: true)
        }
        if let parsed = extract(title) {
            return Result(title: parsed.song, artist: parsed.performer,
                          uploader: raw.isEmpty ? nil : raw, attributed: true)
        }
        return Result(title: title, artist: unknown,
                      uploader: raw.isEmpty ? nil : raw, attributed: false)
    }

    static func isKnown(_ artist: String) -> Bool {
        let cleaned = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && cleaned != unknown
    }
}
