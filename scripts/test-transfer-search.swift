import Foundation

private actor Stub {
    enum Behavior { case pending, snapshots, retry, variant, unavailable, cancel }
    let behavior: Behavior
    var calls=0
    var queries:[String]=[]
    init(_ behavior:Behavior) { self.behavior=behavior }
    func fetch(_ query:String) throws -> TransferSearchSession.Page {
        calls += 1; queries.append(query)
        let exact=#"[{"id":"found","title":"Лунная дорожка","artist":"Северный берег","duration":204}]"#
        switch behavior {
        case .pending: return .init(catalogJSON:Data((calls<5 ? "[]" : exact).utf8),pending:calls<5,retryAfter:0)
        case .snapshots: return .init(catalogJSON:Data((calls==1 ? exact : "[]").utf8),pending:calls==1,retryAfter:.infinity)
        case .retry:
            if calls==1 { throw URLError(.timedOut) }
            return .init(catalogJSON:Data(exact.utf8),pending:false,retryAfter:nil)
        case .variant: return .init(catalogJSON:Data((query=="Лунная дорожка" ? exact : "[]").utf8),pending:false,retryAfter:nil)
        case .unavailable, .cancel: return .init(catalogJSON:Data("[]".utf8),pending:true,retryAfter:nil)
        }
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
        let cancelled=Stub(.cancel), cancelSession=TransferSearchSession { try await cancelled.fetch($0) }
        do {
            _ = try await TransferRemoteSearch.match(prepared:input,mode:"wide",neural:true,session:cancelSession,pause:{ _ in throw CancellationError() })
            preconditionFailure("Cancellation swallowed")
        } catch is CancellationError {}
        let cancelledCalls=await cancelled.calls
        precondition(cancelledCalls==1)
        precondition(TransferRemoteSearch.delay(.nan).isFinite)
        precondition(TransferRemoteSearch.delay(-10)==1 && TransferRemoteSearch.delay(20)==4)
        print("Transfer network: delayed providers, partial snapshots, retries, query variants, completed cache, pending limits and cancellation passed")
    }
}
