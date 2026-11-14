import Foundation

private actor Stub {
    enum Behavior { case pending, snapshots, retry, variant, unavailable, cancel, fuzzyPending, fuzzyIncomplete, fuzzyComplete }
    let behavior: Behavior
    var calls=0
    var queries:[String]=[]
    init(_ behavior:Behavior) { self.behavior=behavior }
    func fetch(_ query:String) throws -> TransferSearchSession.Page {
        calls += 1; queries.append(query)
        let exact=#"[{"id":"found","title":"Лунная дорожка","artist":"Северный берег","duration":204}]"#
        let fuzzy=#"[{"id":"found","title":"Лунная доржка","artist":"Северный берег","duration":204}]"#
        switch behavior {
        case .pending: return .init(catalogJSON:Data((calls<5 ? "[]" : exact).utf8),pending:calls<5,retryAfter:0)
        case .snapshots: return .init(catalogJSON:Data((calls==1 ? exact : "[]").utf8),pending:calls==1,retryAfter:.infinity)
        case .retry:
            if calls==1 { throw URLError(.timedOut) }
            return .init(catalogJSON:Data(exact.utf8),pending:false,retryAfter:nil)
        case .variant: return .init(catalogJSON:Data((query=="Лунная дорожка" ? exact : "[]").utf8),pending:false,retryAfter:nil)
        case .unavailable, .cancel: return .init(catalogJSON:Data("[]".utf8),pending:true,retryAfter:nil)
        case .fuzzyPending: return .init(catalogJSON:Data(fuzzy.utf8),pending:true,retryAfter:nil)
        case .fuzzyIncomplete:
            if calls > 1 { throw URLError(.timedOut) }
            return .init(catalogJSON:Data(fuzzy.utf8),pending:false,retryAfter:nil)
        case .fuzzyComplete: return .init(catalogJSON:Data(fuzzy.utf8),pending:false,retryAfter:nil)
        }
    }
}
private actor ProviderStub {
    enum Behavior { case delayed, complete, wrongArtist, wrongVersion, primaryError, fuzzyPrimary, ambiguousPrimary, fuzzyFallback, pending, pendingExact, unavailable, cancel }
    let behavior: Behavior
    var calls: [String: Int] = [:]
    var order: [String] = []
    init(_ behavior: Behavior) { self.behavior = behavior }
    func fetch(_ provider: String, _ query: String) throws -> TransferSearchSession.Page {
        calls[provider, default: 0] += 1; order.append(provider)
        let exact = #"[{"id":"found","title":"Лунная дорожка","artist":"Северный берег","duration":204}]"#
        let other = #"[{"id":"other","title":"Лунная дорожка","artist":"Другой исполнитель","duration":204}]"#
        let fuzzy = #"[{"id":"fuzzy","title":"Лунная доржка","artist":"Северный берег","duration":204}]"#
        if behavior == .cancel { throw CancellationError() }
        if behavior == .unavailable { throw URLError(.timedOut) }
        if provider == "soundcloud" {
            if behavior == .pendingExact { return .init(catalogJSON:Data(exact.utf8),pending:true,retryAfter:1) }
            if behavior == .primaryError || behavior == .fuzzyFallback { throw URLError(.timedOut) }
            if behavior == .pending || (behavior == .delayed && calls[provider] == 1) {
                return .init(catalogJSON:Data("[]".utf8),pending:true,retryAfter:1)
            }
            if behavior == .wrongArtist { return .init(catalogJSON:Data(other.utf8),pending:false,retryAfter:nil) }
            if behavior == .wrongVersion {
                let live = #"[{"id":"live","title":"Лунная дорожка (Live)","artist":"Северный берег","duration":204}]"#
                return .init(catalogJSON:Data(live.utf8),pending:false,retryAfter:nil)
            }
            if behavior == .ambiguousPrimary {
                let id = calls[provider] == 1 ? "a" : "b"
                let code = calls[provider] == 1 ? "USABC2400001" : "USABC2400002"
                let data = "[{\"id\":\"\(id)\",\"title\":\"Лунная доржка\",\"artist\":\"Северный берег\",\"duration\":204,\"isrc\":\"\(code)\"}]"
                return .init(catalogJSON:Data(data.utf8),pending:false,retryAfter:nil)
            }
            return .init(catalogJSON:Data((behavior == .fuzzyPrimary ? fuzzy : exact).utf8),pending:false,retryAfter:nil)
        }
        let data = behavior == .fuzzyFallback ? fuzzy : behavior == .complete ? other : exact
        return .init(catalogJSON:Data(data.utf8),pending:false,retryAfter:nil)
    }
}
@main struct TransferSearchTests {
    static func main() async throws {
        let input=#"[{"title":"Лунная дорожка","artist":"Северный берег","duration":204}]"#
        for behavior in [Stub.Behavior.pending,.snapshots,.retry,.variant] {
            let stub=Stub(behavior), session=TransferSearchSession { try await stub.fetch($0) }
            let result=try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:session,pause:{ _ in })
            let row=try JSONSerialization.jsonObject(with:result) as! [String:Any]
            precondition(row["track_id"] as? String=="found", "Failed \(behavior): \(row)")
        }
        let pending=Stub(.unavailable), session=TransferSearchSession { try await pending.fetch($0) }
        let result=try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:session,pause:{ _ in })
        let row=try JSONSerialization.jsonObject(with:result) as! [String:Any]
        precondition(row["track_id"] is NSNull && (row["reason"] as? String)?.contains("Повторить")==true)
        let callCount=await pending.calls
        precondition(callCount<=24 && callCount>1, "Pending was cached or polling is unbounded")
        let cached=Stub(.retry), cache=TransferSearchSession { try await cached.fetch($0) }
        do { _ = try await cache.page("test");preconditionFailure("Failure cached as success") } catch {}
        _ = try await cache.page("test");_ = try await cache.page("TEST")
        let cacheCalls=await cached.calls
        precondition(cacheCalls==2,"Complete responses were not cached")
        for behavior in [Stub.Behavior.fuzzyPending, .fuzzyIncomplete, .fuzzyComplete] {
            let stub=Stub(behavior), session=TransferSearchSession { try await stub.fetch($0) }
            let result=try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:session,pause:{ _ in })
            let row=try JSONSerialization.jsonObject(with:result) as! [String:Any]
            if behavior == .fuzzyComplete {
                precondition(row["track_id"] as? String == "found", "Completed fuzzy search should remain usable: \(row)")
            } else {
                precondition(row["track_id"] is NSNull && row["match_method"] == nil,
                             "Unfinished search autoaccepted a fuzzy recording: \(row)")
                precondition((row["reason"] as? String)?.isEmpty == false)
            }
        }
        let cancelled=Stub(.cancel), cancelSession=TransferSearchSession { try await cancelled.fetch($0) }
        do {
            _ = try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:cancelSession,pause:{ _ in throw CancellationError() })
            preconditionFailure("Cancellation swallowed")
        } catch is CancellationError {}
        let cancelledCalls=await cancelled.calls
        precondition(cancelledCalls==1)
        func providerSession(_ stub: ProviderStub) -> TransferSearchSession {
            let providers = TransferRemoteSearch.providers { try await stub.fetch($0, $1) }
            return TransferRemoteSearch.providerSession(prepared:input,mode:"wide",neural:true,providers:providers)
        }
        for behavior in [ProviderStub.Behavior.complete, .delayed, .fuzzyPrimary, .pendingExact] {
            let stub = ProviderStub(behavior), session = providerSession(stub)
            let result = try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:session,pause:{_ in})
            let row = try JSONSerialization.jsonObject(with:result) as! [String:Any]
            precondition(row["track_id"] as? String == (behavior == .fuzzyPrimary ? "fuzzy" : "found"))
            let calls = await stub.calls
            precondition(calls["audius"] == nil, "Audius was requested despite a valid SoundCloud recording: \(calls)")
            if behavior == .fuzzyPrimary {
                precondition((calls["soundcloud"] ?? 0) > 1, "Fuzzy primary skipped remaining query variants")
            } else {
                precondition(calls["soundcloud"] == (behavior == .delayed ? 2 : 1), "Pending primary was abandoned or completed primary was repolled")
            }
        }
        let competing = ProviderStub(.ambiguousPrimary), competingSession = providerSession(competing)
        let competingResult = try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:competingSession,pause:{_ in})
        let competingRow = try JSONSerialization.jsonObject(with:competingResult) as! [String:Any]
        let competingCalls = await competing.calls
        precondition(competingRow["track_id"] is NSNull && (competingCalls["soundcloud"] ?? 0) > 1,
                     "Later primary variant's competing recording was hidden: \(competingRow)")
        precondition(competingCalls["audius"] == nil)
        for behavior in [ProviderStub.Behavior.wrongArtist, .wrongVersion, .primaryError, .fuzzyFallback, .pending] {
            let stub = ProviderStub(behavior), session = providerSession(stub)
            let result = try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:session,pause:{_ in})
            let row = try JSONSerialization.jsonObject(with:result) as! [String:Any]
            precondition(row["track_id"] as? String == (behavior == .fuzzyFallback ? "fuzzy" : "found"),
                         "Invalid or unavailable primary blocked valid fallback: \(row)")
            let order = await stub.order, calls = await stub.calls
            precondition(order.first == "soundcloud" && calls["audius"] != nil)
            if behavior == .pending {
                precondition(calls["soundcloud"] == 7 && calls["audius"] == 1,
                             "Pending primary was cancelled early or never reached bounded fallback: \(calls)")
            }
        }
        let providerCache = ProviderStub(.complete)
        let providers = TransferRemoteSearch.providers { try await providerCache.fetch($0, $1) }
        let first = TransferRemoteSearch.providerSession(prepared:input,mode:"wide",neural:true,providers:providers)
        _ = try await first.page("Track"); _ = try await first.page("TRACK")
        let otherInput = #"[{"title":"Лунная дорожка","artist":"Другой исполнитель","duration":204}]"#
        let second = TransferRemoteSearch.providerSession(prepared:otherInput,mode:"wide",neural:true,providers:providers)
        let page = try await second.page("Track")
        let secondRows = try JSONSerialization.jsonObject(with:page.catalogJSON) as! [[String:Any]]
        precondition(!page.pending && secondRows.first?["id"] as? String == "other",
                     "One original track's primary selection leaked into another")
        let completeCalls = await providerCache.calls
        precondition(completeCalls["soundcloud"] == 1 && completeCalls["audius"] == 1,
                     "Completed per-provider response cache was lost")
        let ambiguousSources = TransferRemoteSearch.providers { source, _ in
            let primary = #"[{"id":"sc-a","title":"Лунная дорожка","artist":"Северный берег","duration":204,"isrc":"USAAA2600001"},{"id":"sc-b","title":"Лунная дорожка","artist":"Северный берег","duration":204,"isrc":"GBBBB2600002"}]"#
            let backup = #"[{"id":"ai-third","title":"Лунная дорожка","artist":"Северный берег","duration":204,"isrc":"FRCCC2600003"}]"#
            return .init(catalogJSON:Data((source == "soundcloud" ? primary : backup).utf8),pending:false,retryAfter:nil)
        }
        let ambiguousSession = TransferRemoteSearch.providerSession(prepared:input,mode:"wide",neural:true,providers:ambiguousSources)
        let ambiguousData = try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:ambiguousSession,pause:{_ in})
        let ambiguousRow = try JSONSerialization.jsonObject(with:ambiguousData) as! [String:Any]
        precondition(ambiguousRow["track_id"] is NSNull && ambiguousRow["match_ambiguous"] as? Bool == true,
                     "An ambiguous primary pool must not be replaced by an arbitrary third backup recording")
        let noSources = ProviderStub(.unavailable), unavailable = providerSession(noSources)
        do { _ = try await unavailable.page("track"); preconditionFailure("All source failures became a completed empty page") }
        catch is URLError {}
        let stopSources = ProviderStub(.cancel), cancelledSource = providerSession(stopSources)
        do { _ = try await cancelledSource.page("track"); preconditionFailure("Provider cancellation swallowed") }
        catch is CancellationError {}
        let stopOrder = await stopSources.order
        precondition(stopOrder == ["soundcloud"], "Cancellation started another provider request")
        precondition(TransferRemoteSearch.delay(.nan).isFinite)
        precondition(TransferRemoteSearch.delay(-10)==1 && TransferRemoteSearch.delay(20)==4)
        print("Transfer network: validated SoundCloud priority, bounded pending primary, Audius fallback, independent caches, fuzzy guards and cancellation passed")
    }
}
