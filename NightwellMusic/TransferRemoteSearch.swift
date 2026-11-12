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
                    for row in rows.prefix(500) {
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
