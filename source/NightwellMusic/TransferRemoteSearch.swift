import Foundation

/// One import owns one bounded cache, so results never leak between accounts.
/// Only completed responses are cached; an empty pending page is never final.
actor TransferSearchSession {
    struct Page: Sendable {
        let catalogJSON: Data
        let pending: Bool
        let retryAfter: Double?
    }
    typealias Fetch = @Sendable (String) async throws -> Page
    private let fetch: Fetch
    private var complete: [String: Page] = [:]
    private var order: [String] = []
    private var bytes = 0
    init(fetch: @escaping Fetch) { self.fetch = fetch }
    func page(_ query: String) async throws -> Page {
        try Task.checkCancellation()
        let key = query.folding(options: [.caseInsensitive,.widthInsensitive],locale: Locale(identifier:"en_US_POSIX"))
        if let cached = complete[key] { return cached }
        let response = try await fetch(query)
        try Task.checkCancellation()
        if !response.pending, response.catalogJSON.count <= 1_000_000 {
            if let old = complete[key] { bytes -= old.catalogJSON.count; order.removeAll { $0 == key } }
            complete[key] = response; order.append(key); bytes += response.catalogJSON.count
            while bytes > 8_000_000 || order.count > 64 {
                let oldest = order.removeFirst()
                bytes -= complete.removeValue(forKey: oldest)?.catalogJSON.count ?? 0
            }
        }
        return response
    }
}

enum TransferRemoteSearch {
    typealias Pause = @Sendable (Double) async throws -> Void
    typealias ProviderFetch = @Sendable (String, String) async throws -> TransferSearchSession.Page
    struct Providers: Sendable {
        let soundcloud: TransferSearchSession
        let audius: TransferSearchSession
    }
    static func providers(fetch: @escaping ProviderFetch) -> Providers {
        Providers(soundcloud: TransferSearchSession { try await fetch("soundcloud", $0) },
                  audius: TransferSearchSession { try await fetch("audius", $0) })
    }
    /// Source caches belong to the import; recording validation belongs to one
    /// original track. A nonempty page alone never decides whether to fall back.
    static func providerSession(prepared: String, mode: String, neural: Bool,
                                providers: Providers) -> TransferSearchSession {
        let selection = TransferProviderSelection(prepared: prepared, mode: mode,
                                                   neural: neural, providers: providers)
        return TransferSearchSession { try await selection.page($0) }
    }
    static func delay(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 1.5 }
        return max(1,min(4,value))
    }
    /// Called inside the import's three-worker task group. The complete response
    /// and union of search variants are ranked on the background executor.
    static func match(prepared: String, mode: String, neural: Bool,
                      session: TransferSearchSession,
                      pause: Pause = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async throws -> Data {
        guard let originals = try JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [[String: Any]],
              let original = originals.first,
              let title = original["title"] as? String, let artist = original["artist"] as? String else {
            throw TransferPreparation.fail("Неверная запись для поиска")
        }
        let queries = TransferPreparation.searchQueries(title:title,artist:artist,mode:mode)
        var catalog: [String: [String: Any]] = [:]
        var order: [String] = [], last = original
        var pendingQueries = Set<String>(), failedQueries = Set<String>()
        var completedQueries = Set<String>()
        var calls = 0
        let started = Date()
        func rank() throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: order.compactMap { catalog[$0] })
            let rows = try neural
                ? DeviceNeuralTransferMatcher.match(prepared:prepared,catalogJSON:data,mode:mode)
                : DeviceTransferMatcher.match(prepared:prepared,catalogJSON:data,mode:mode)
            return rows.first ?? original
        }
        search: for query in queries {
            var attempts = 0
            while attempts < 7 {
                try Task.checkCancellation()
                if calls >= 24 || Date().timeIntervalSince(started) >= 75 { break search }
                calls += 1; attempts += 1
                do {
                    let page = try await session.page(query)
                    let rows = try JSONSerialization.jsonObject(with: page.catalogJSON) as? [[String: Any]] ?? []
                    // Pending snapshots may contain only the newest provider's
                    // tracks. Merge them instead of discarding earlier candidates.
                    for row in rows.prefix(1000) {
                        guard let id = row["id"] as? String else { continue }
                        if catalog[id] != nil { catalog[id] = row }
                        else if order.count < 2000 { order.append(id); catalog[id] = row }
                    }
                    failedQueries.remove(query)
                    if page.pending { pendingQueries.insert(query) }
                    else { pendingQueries.remove(query) }
                    if !page.pending {
                        completedQueries.insert(query)
                        last = try rank()
                        let method = last["match_method"] as? String
                        // Fuzzy matches are reviewed against the combined search
                        // pool. Exact identities can finish a track early.
                        if method == "exact" || method == "isrc" {
                            return try JSONSerialization.data(withJSONObject:last)
                        }
                        break
                    }
                    if attempts < 7 { try await pause(delay(page.retryAfter)) }
                } catch is CancellationError { throw CancellationError() }
                  catch {
                    try Task.checkCancellation()
                    failedQueries.insert(query)
                    // A transient failure gets one bounded retry for this query.
                    if attempts == 1 { try await pause(1.5); continue }
                    break
                }
            }
        }
        try Task.checkCancellation()
        last = try rank()
        let method = last["match_method"] as? String
        let incomplete = completedQueries.count < queries.count
        // Fuzzy candidates require the combined pool to rule out competing
        // recordings. A pending provider or failed query can still return a
        // closer match, so leave this entry available for the explicit retry.
        if incomplete, method != "exact", method != "isrc" {
            last["track_id"] = NSNull()
            for field in ["found_title", "found_artist", "match_score", "match_method"] {
                last.removeValue(forKey: field)
            }
        }
        if last["track_id"] as? String == nil {
            if !pendingQueries.isEmpty {
                last["reason"] = "Источники ещё ищут этот трек. Нажми «Повторить ненайденные»"
            } else if !failedQueries.isEmpty || incomplete {
                last["reason"] = "Часть поисковых запросов не завершилась. Можно повторить ненайденные"
            }
        }
        return try JSONSerialization.data(withJSONObject:last)
    }
}

/// Each transfer worker asks SoundCloud first and uses Audius when no valid
/// primary recording is available. Pending primary pages get seven polls, the
/// same bound as the outer query loop; provider calls remain sequential.
private actor TransferProviderSelection {
    let prepared: String
    let mode: String
    let neural: Bool
    let providers: TransferRemoteSearch.Providers
    var pendingAttempts: [String: Int] = [:]
    var primaryRows: [String: [String: Any]] = [:]
    var primaryOrder: [String] = []
    var primaryMatch: Data?
    var hasPrimaryEvidence = false
    init(prepared: String, mode: String, neural: Bool, providers: TransferRemoteSearch.Providers) {
        self.prepared = prepared; self.mode = mode; self.neural = neural; self.providers = providers
    }
    func page(_ query: String) async throws -> TransferSearchSession.Page {
        try Task.checkCancellation()
        if let primaryMatch { return .init(catalogJSON: primaryMatch, pending: false, retryAfter: nil) }
        var primary: TransferSearchSession.Page?
        do {
            let page = try await providers.soundcloud.page(query)
            primary = page
            guard let rows = try JSONSerialization.jsonObject(with: page.catalogJSON) as? [[String: Any]] else {
                throw TransferPreparation.fail("Неверный ответ поискового источника")
            }
            for row in rows.prefix(500) {
                guard let id = row["id"] as? String else { continue }
                if primaryRows[id] != nil { primaryRows[id] = row }
                else if primaryOrder.count < 2000 { primaryOrder.append(id); primaryRows[id] = row }
            }
            let data = try JSONSerialization.data(withJSONObject: primaryOrder.compactMap { primaryRows[$0] })
            let matched = try neural
                ? DeviceNeuralTransferMatcher.match(prepared: prepared, catalogJSON: data, mode: mode)
                : DeviceTransferMatcher.match(prepared: prepared, catalogJSON: data, mode: mode)
            let method = matched.first?["match_method"] as? String
            if matched.first?["match_ambiguous"] as? Bool == true {
                hasPrimaryEvidence = true
                return .init(catalogJSON: data, pending: page.pending, retryAfter: page.retryAfter)
            }
            // Exact recording identities in a partial primary snapshot are
            // already usable. Fuzzy evidence still requires completed sources.
            if matched.first?["track_id"] as? String != nil,
               !page.pending || method == "exact" || method == "isrc" {
                if method == "exact" || method == "isrc" { primaryMatch = data }
                else { hasPrimaryEvidence = true }
                return .init(catalogJSON: data, pending: false, retryAfter: nil)
            }
            // Once SoundCloud provides a viable fuzzy recording, finish its
            // remaining variants to detect competitors. Do not pretend those
            // variants completed by returning the first cached fuzzy page.
            if hasPrimaryEvidence {
                return .init(catalogJSON: data, pending: page.pending, retryAfter: page.retryAfter)
            }
            if page.pending {
                pendingAttempts[query, default: 0] += 1
                if pendingAttempts[query, default: 0] < 7 {
                    return .init(catalogJSON: data, pending: true, retryAfter: page.retryAfter)
                }
            }
        } catch is CancellationError { throw CancellationError() }
          catch {
            try Task.checkCancellation()
            if hasPrimaryEvidence {
                let data = try JSONSerialization.data(withJSONObject: primaryOrder.compactMap { primaryRows[$0] })
                return .init(catalogJSON: data, pending: true, retryAfter: nil)
            }
          }
        // An exhausted, empty, unrelated, or unavailable primary does not block
        // a completed fallback page, including a valid fuzzy recording match.
        do {
            return try await providers.audius.page(query)
        } catch is CancellationError { throw CancellationError() }
          catch {
            try Task.checkCancellation()
            if let primary {
                return .init(catalogJSON: primary.catalogJSON, pending: true, retryAfter: primary.retryAfter)
            }
            throw error
        }
    }
}
