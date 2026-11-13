import Foundation

/// Relevance first; personal-library entries win only between equal matches.
enum NightwellLibrarySearchOrder {
    static func matching(_ track: Track, query: String) -> Bool {
        NightwellSearch.Query(query).score(title:track.title,artist:track.artist) > 0
    }
    static func ordered(_ tracks: [Track], query: String,
                        priorityIDs: Set<String>, limit: Int = 140) -> [Track] {
        NightwellSearch.ordered(tracks,query:query,priorityIDs:priorityIDs,limit:limit,
            id: { $0.id },title: { $0.title },artist: { $0.artist })
    }
}

/// Local similarity model driven by performers, albums and overlapping title
/// tokens. It never decodes audio or runs an LLM on the Nightwell server.
enum NightwellSeededRhythm {
    static func artists(_ seeds: [Track], limit: Int = 4) -> [String] {
        var counts: [String: (name: String, count: Int, first: Int)] = [:]
        for (i,t) in seeds.prefix(400).enumerated() {
            let k = RecommendationOrder.key(t.artist)
            if k.isEmpty || k == "unknown" { continue }
            if let value = counts[k] {
                counts[k] = (value.name, value.count + 1, value.first)
            } else { counts[k] = (t.artist, 1, i) }
        }
        return counts.values.sorted {
            $0.count == $1.count ? $0.first < $1.first : $0.count > $1.count
        }.prefix(max(1,limit)).map(\.name)
    }

    static func ranked(candidates: [Track], seeds: [Track],
                       hidden: Set<String> = [], blockedArtists: Set<String> = [],
                       limit: Int = 110) -> [Track] {
        guard !seeds.isEmpty else { return [] }
        let seedIDs = Set(seeds.map(\.id))
        let seedArtists = Set(seeds.map { RecommendationOrder.key($0.artist) })
        let seedAlbums = Set(seeds.compactMap { $0.album }.map(RecommendationOrder.key).filter { !$0.isEmpty })
        let rawTokens = seeds.prefix(40).flatMap {
            ($0.title + " " + $0.artist).split(whereSeparator: {
                !$0.isLetter && !$0.isNumber
            }).map { RecommendationOrder.key(String($0)) }
        }
        let tokens = Set(rawTokens.filter { $0.count >= 4 })
        let taste = RecommendationOrder.tasteWeights()
        var ids = Set<String>(), recordings = Set<String>()
        var ranked: [(track: Track, score: Double, order: Int, artist: String)] = []
        ranked.reserveCapacity(min(400, candidates.count))
        let orderedCandidates = candidates.enumerated().sorted {
            let a = RecommendationOrder.sourcePriority($0.element.source)
            let b = RecommendationOrder.sourcePriority($1.element.source)
            return a == b ? $0.offset < $1.offset : a < b
        }
        for (i,track) in orderedCandidates {
            let artist = RecommendationOrder.key(track.artist)
            let title = RecommendationOrder.key(track.title)
            guard !seedIDs.contains(track.id), !hidden.contains(track.id),
                  !blockedArtists.contains(artist) else { continue }
            let album = track.album.map(RecommendationOrder.key) ?? ""
            let sameArtist = !artist.isEmpty && seedArtists.contains(artist)
            let sameAlbum = !album.isEmpty && seedAlbums.contains(album)
            let words = (track.title + " " + track.artist).split(whereSeparator: {
                !$0.isLetter && !$0.isNumber
            }).map { RecommendationOrder.key(String($0)) }
            let overlap = words.filter { tokens.contains($0) }.count
            let score = (sameArtist ? 7.0 : 0) + (sameAlbum ? 4.5 : 0)
                + min(3.0, Double(overlap) * 0.65)
                + max(-1.2, min(1.0, (taste[artist] ?? 0) * 0.35))
            // Title tokens alone are weak, but permit discovery from unrelated
            // performers without filling the mix with arbitrary tracks.
            guard score >= 0.7, ids.insert(track.id).inserted,
                  recordings.insert(artist + ":" + title).inserted else { continue }
            ranked.append((track, score, i, artist))
        }
        ranked.sort {
            let a = RecommendationOrder.sourcePriority($0.track.source)
            let b = RecommendationOrder.sourcePriority($1.track.source)
            if a != b { return a < b }
            return $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score
        }
        var selected: [Track] = [], picked = Set<String>()
        var artistCount: [String:Int] = [:]
        for entry in ranked {
            if selected.count >= limit { break }
            if !entry.artist.isEmpty && artistCount[entry.artist, default:0] >= 5 {
                continue
            }
            if picked.insert(entry.track.id).inserted {
                selected.append(entry.track)
                artistCount[entry.artist, default:0] += 1
            }
        }
        // Permit a larger number of one artist if the user explicitly picked a
        // one-artist playlist and no useful alternatives are available.
        if selected.count < min(8,limit) {
            for entry in ranked where selected.count < limit {
                if picked.insert(entry.track.id).inserted { selected.append(entry.track) }
            }
        }
        return selected.enumerated().sorted {
            let a = RecommendationOrder.sourcePriority($0.element.source)
            let b = RecommendationOrder.sourcePriority($1.element.source)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}
