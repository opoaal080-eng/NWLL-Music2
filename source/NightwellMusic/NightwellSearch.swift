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
            // A requested live/remix version must also outrank a studio recording.
            // Only penalizing extra tags lets an owned studio track win this tie.
            let versionMismatch = cleaned.versions.symmetricDifference(title.versions).subtracting(["remaster"])
            var versionPenalty = versionMismatch.isEmpty ? 0 : 2200
            if !title.detail.isEmpty && (cleaned.detail.isEmpty || TransferText.similarity(title.detail,cleaned.detail) < 0.92) {
                versionPenalty += 1200
            }
            if wanted == core || wanted == a + core || wanted == core + a {
                // Featured credits and promotional suffixes do not make an
                // otherwise exact recording title a weaker search result.
                return 10_000 - versionPenalty
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
            var forms = [(name,n),(artist,a)]
            if tokens.count >= 2, !n.isEmpty, !a.isEmpty {
                forms.append((artist + " " + name,a + n))
                forms.append((name + " " + artist,n + a))
            }
            let dice = forms.map { TransferText.dice(text,$0.0) }.max() ?? 0
            guard dice >= 0.32 else { return 0 }
            let similarity = forms.map { TransferText.similarity(compact,$0.1) }.max() ?? 0
            if similarity >= 0.74 { return 3000 + Int(similarity * 1000) - versionPenalty }
            return 0
        }
    }

    static func ordered<T>(_ values: [T], query: String, priorityIDs: Set<String> = [],
                           providerRanks: [String: Int] = [:],
                           limit: Int = 140, localOnly: Bool = false,
                           id: (T) -> String, title: (T) -> String, artist: (T) -> String) -> [T] {
        let wanted = Query(query)
        var seen = Set<String>()
        // Compute each expensive score once, never inside the sort comparator.
        var ranked: [(value:T,score:Int,provider:Int,owned:Bool,offset:Int)] = []
        for (offset,value) in values.enumerated() {
            if offset % 64 == 0 && Task.isCancelled { return [] }
            let identity = id(value)
            guard seen.insert(identity).inserted else { continue }
            let score = wanted.score(title:title(value),artist:artist(value))
            if !localOnly || score > 0 {
                ranked.append((value,score,providerRanks[identity] ?? Int.max,priorityIDs.contains(identity),offset))
            }
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            if $0.owned != $1.owned { return $0.owned }
            return $0.offset < $1.offset
        }.prefix(max(0,limit)).map(\.value)
    }

    /// Keep source snapshots and spelling variants in one result pool.
    /// New metadata replaces old metadata without moving an existing identity.
    struct Pool<T> {
        private var values: [String:T] = [:]
        private var ids: [String] = []
        private var providerSnapshots: [Int:[String]] = [:]
        private(set) var providerRanks: [String:Int] = [:]
        var all: [T] { ids.compactMap { values[$0] } }
        mutating func merge(_ incoming: [T], id: (T) -> String) {
            for value in incoming {
                let key = id(value)
                if values[key] == nil { ids.append(key) }
                values[key] = value
            }
        }
        /// Provider relevance resolves equal title matches before cached/local
        /// positions. The literal query takes precedence over broader variants.
        mutating func mergeProvider(_ incoming: [T], queryPriority: Int, id: (T) -> String) {
            merge(incoming,id:id)
            var seen = Set<String>()
            let fresh = incoming.map(id).filter { seen.insert($0).inserted }
            let previous = providerSnapshots[queryPriority] ?? []
            providerSnapshots[queryPriority] = fresh + previous.filter { !seen.contains($0) }
            providerRanks = [:]
            var rank = 0
            for priority in providerSnapshots.keys.sorted() {
                for key in providerSnapshots[priority] ?? [] where providerRanks[key] == nil {
                    providerRanks[key] = rank
                    rank += 1
                }
            }
        }
    }

    /// Search SoundCloud first. Audius is queried only after the primary
    /// variants finish without relevant hits, fail, or exhaust their budget.
    /// Each variant gets one request before another variant is polled again.
    struct RequestPlan {
        struct Request {
            let query: String
            let provider: String
            var path: String {
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn:"&+=?#"))
                return "/api/tracks?q=" + (query.addingPercentEncoding(withAllowedCharacters:allowed) ?? "")
                    + "&provider=" + provider
            }
            let priority: Int
            let delay: Double
        }
        private let queries: [String]
        private let maxCalls: Int
        private let primaryBudget: Int
        private var queue: [Int]
        private var calls = 0
        private var primaryCalls = 0
        private var fallback = false
        private var hasPrimaryMatch = false
        private var attempts: [Int:Int] = [:]
        private var failures: [Int:Int] = [:]
        private var readyAt: [Int:Double] = [:]
        private var completed = Set<Int>()
        var isComplete: Bool {
            let offset = fallback ? queries.count : 0
            return queries.indices.allSatisfy { completed.contains(offset + $0) }
        }

        init(queries: [String], maxCalls: Int = 18) {
            self.queries = queries
            self.maxCalls = maxCalls
            // Keep at least one request per backup variant if the primary
            // remains pending. Both stages share the same total request cap.
            self.primaryBudget = max(queries.count, maxCalls - queries.count)
            queue = Array(queries.indices)
        }
        mutating func next(now: Double) -> Request? {
            if !fallback, queue.isEmpty || primaryCalls >= primaryBudget {
                guard !hasPrimaryMatch else { return nil }
                fallback = true
                queue = queries.indices.map { queries.count + $0 }
            }
            guard calls < maxCalls, !queue.isEmpty else { return nil }
            let priority = queue.removeFirst()
            calls += 1
            if !fallback { primaryCalls += 1 }
            attempts[priority,default:0] += 1
            return Request(query:queries[priority % queries.count],provider:fallback ? "audius" : "soundcloud",
                           priority:priority,delay:max(0,(readyAt[priority] ?? now)-now))
        }
        mutating func received(_ request: Request, pending: Bool, retryAfter: Double?,
                               relevant: Bool = false, now: Double) {
            if request.provider == "soundcloud", relevant { hasPrimaryMatch = true }
            if !pending { completed.insert(request.priority); return }
            if attempts[request.priority,default:0] < 9 {
                let delay = retryAfter.flatMap { $0.isFinite ? max(1,min(4,$0)) : nil } ?? 1.5
                readyAt[request.priority] = now + delay
                queue.append(request.priority)
            }
        }
        mutating func failed(_ request: Request, now: Double) {
            failures[request.priority,default:0] += 1
            if failures[request.priority] == 1, attempts[request.priority,default:0] < 9 {
                readyAt[request.priority] = now + 1.5
                queue.append(request.priority)
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
