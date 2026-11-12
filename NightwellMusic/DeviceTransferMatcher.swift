import Foundation

enum DeviceTransferMatcher {
    typealias Ranker = ([Double]) -> Double

    static func match(prepared: String, catalogJSON: Data, mode: String = "balanced",
                      ranker: Ranker? = nil) throws -> [[String: Any]] {
        guard let originals = try JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [[String: Any]],
              let catalog = try JSONSerialization.jsonObject(with: catalogJSON) as? [[String: Any]] else {
            throw TransferPreparation.fail("Неверный формат списка для переноса")
        }
        var entries: [TransferMetadata] = []
        var byTitle: [String: [Int]] = [:], byArtist: [String: [Int]] = [:]
        var byISRC: [String: [Int]] = [:], byGram: [String: [Int]] = [:]
        var seenIDs = Set<String>()
        for (offset,row) in catalog.prefix(100_000).enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            let entry = TransferMetadata(row)
            guard !entry.variants.isEmpty,
                  entry.id.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
                  seenIDs.insert(entry.id).inserted else { continue }
            let n = entries.count; entries.append(entry)
            if let isrc = entry.isrc { byISRC[isrc,default:[]].append(n) }
            var grams = Set<String>(), titles = Set<String>(), artists = Set<String>()
            for v in entry.variants {
                titles.insert(v.title.core)
                artists.formUnion(v.credits)
                grams.formUnion(TransferText.grams(v.title.core).map { "t:" + $0 })
                grams.formUnion(TransferText.grams(v.artist).map { "a:" + $0 })
            }
            for title in titles { byTitle[title,default:[]].append(n) }
            for artist in artists { byArtist[artist,default:[]].append(n) }
            for gram in grams where byGram[gram,default:[]].count < 2000 { byGram[gram,default:[]].append(n) }
        }
        var results: [[String: Any]] = []
        for original in originals {
            try Task.checkCancellation()
            let query = TransferMetadata(original)
            var output = original
            output["track_id"] = NSNull()
            output.removeValue(forKey: "found_title"); output.removeValue(forKey: "found_artist")
            output.removeValue(forKey: "match_score"); output.removeValue(forKey: "match_method")
            var votes: [Int: Double] = [:], exactCandidates = Set<Int>()
            for variant in query.variants {
                exactCandidates.formUnion(byTitle[variant.title.core] ?? [])
                for credit in variant.credits {
                    for n in byArtist[credit] ?? [] { votes[n,default:0] += 3 }
                }
                for gram in TransferText.grams(variant.title.core) {
                    let hits = byGram["t:" + gram] ?? []
                    let weight = 3.0 / log2(Double(hits.count) + 2)
                    for n in hits { votes[n,default:0] += weight }
                }
                for gram in TransferText.grams(variant.artist) {
                    let hits = byGram["a:" + gram] ?? []
                    let weight = 1.0 / log2(Double(hits.count) + 2)
                    for n in hits { votes[n,default:0] += weight }
                }
            }
            // Exact identities are resolved before any recall/candidate limit.
            var exact: [(Int, String)] = []
            if let isrc = query.isrc {
                for n in byISRC[isrc] ?? [] {
                    if let pair = TransferSimilarity.compare(query,entries[n]), !pair.durationConflict, !pair.versionConflict {
                        exact.append((n,"isrc"))
                    }
                }
            }
            if exact.isEmpty {
                for n in exactCandidates.sorted() {
                    if let pair = TransferSimilarity.compare(query,entries[n]), pair.exact,
                       !pair.durationConflict, !pair.versionConflict, !pair.isrcConflict { exact.append((n,"exact")) }
                }
            }
            if !exact.isEmpty {
                exact.sort { a,b in
                    let da = query.duration.flatMap { q in entries[a.0].duration.map { abs(q-$0) } } ?? 0
                    let db = query.duration.flatMap { q in entries[b.0].duration.map { abs(q-$0) } } ?? 0
                    return da != db ? da < db : entries[a.0].id < entries[b.0].id
                }
                let winner = exact[0]
                assign(&output, entries[winner.0], score:1, method:winner.1)
                results.append(output); continue
            }
            for n in exactCandidates { votes[n,default:0] += 20 }
            if entries.count <= 500 { for n in entries.indices { votes[n,default:0] += 1 } }
            let candidates = votes.sorted { $0.value == $1.value ? entries[$0.key].id < entries[$1.key].id : $0.value > $1.value }.prefix(900)
            var ranked: [(score:Double,index:Int,method:String)] = []
            for (offset,hit) in candidates.enumerated() {
                if offset.isMultiple(of:32) { try Task.checkCancellation() }
                let n = hit.key
                guard let pair = TransferSimilarity.compare(query,entries[n]),
                      !pair.versionConflict, !pair.durationConflict, !pair.isrcConflict else { continue }
                if mode == "safe", pair.features[12] != 1 { continue }
                let limits: (Double,Double,Double) = mode == "safe" ? (0.96,0.94,0.96) : mode == "wide" ? (0.85,0.81,0.87) : (0.90,0.87,0.91)
                var score = pair.heuristic, method = "metadata"
                var accepts = pair.title >= limits.0 && pair.artist >= limits.1 && score >= limits.2
                if let ranker {
                    let p = ranker(pair.features)
                    let titleFloor = mode == "safe" ? 0.94 : mode == "wide" ? 0.70 : 0.79
                    let artistFloor = mode == "safe" ? 0.93 : mode == "wide" ? 0.72 : 0.82
                    let threshold = mode == "safe" ? 0.985 : mode == "wide" ? 0.92 : 0.96
                    let strongEvidence = pair.title >= 0.86 || (pair.features[8] == 1 && pair.features[7] >= 0.65 && pair.artist >= 0.93)
                    let shortTitleOK = pair.features[15] >= 0.32 || pair.features[9] == 1
                    if p >= threshold, pair.title >= titleFloor, pair.artist >= artistFloor, strongEvidence, shortTitleOK {
                        accepts = true; score = max(score,0.55 * pair.heuristic + 0.45 * p); method = "neural"
                    }
                }
                if accepts { ranked.append((score,n,method)) }
            }
            ranked.sort { $0.score == $1.score ? entries[$0.index].id < entries[$1.index].id : $0.score > $1.score }
            if let first = ranked.first {
                let contender = ranked.dropFirst().first { !TransferSimilarity.sameRecording(entries[first.index],entries[$0.index]) }
                let ambiguous = contender.map { first.score - $0.score < (mode == "safe" ? 0.045 : 0.025) } ?? false
                if ambiguous {
                    output["reason"] = "Несколько разных записей похожи на исходную, нужна проверка"
                } else {
                    assign(&output, entries[first.index], score:first.score, method:first.method)
                }
            } else {
                output["reason"] = "Не найдено надёжного совпадения по названию, исполнителю и версии"
            }
            results.append(output)
        }
        return results
    }
    private static func assign(_ output: inout [String: Any], _ entry: TransferMetadata, score: Double, method: String) {
        output["track_id"] = entry.id; output["found_title"] = entry.rawTitle
        output["found_artist"] = entry.rawArtist; output["reason"] = ""
        output["match_score"] = score; output["match_method"] = method
    }
}
