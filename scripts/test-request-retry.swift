import Foundation
private actor DeadlineProbe {
    private(set) var cancelled = false
    func wait() async throws -> Int {
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return 1
        } catch {
            cancelled = true
            throw error
        }
    }
}
@main struct RequestRetryTests {
    static func main() async throws {
        var calls = 0
        let value: Int = try await RequestRetry.run(readOnly: true, pause: {}) {
            calls += 1
            if calls < 3 { throw URLError(.networkConnectionLost) }
            return 42
        }
        precondition(value == 42 && calls == 3)
        for readOnly in [false, true] {
            calls = 0
            do {
                let _: Int = try await RequestRetry.run(readOnly: readOnly, pause: {}) {
                    calls += 1; throw RequestRetry.HTTPFailure(status: 503, message: "Temporary")
                }
                preconditionFailure("Failure must propagate")
            } catch { precondition(calls == (readOnly ? 3 : 1)) }
        }
        for status in [408, 500, 502, 503, 504] {
            calls = 0
            do {
                let _: Int = try await RequestRetry.run(readOnly: true, pause: {}) {
                    calls += 1; throw RequestRetry.HTTPFailure(status: status, message: "Transient")
                }
                preconditionFailure("Failure must propagate")
            } catch { precondition(calls == 3) }
        }
        for status in [400, 401, 403, 404, 409, 429] {
            calls = 0
            do {
                let _: Int = try await RequestRetry.run(readOnly: true, pause: {}) {
                    calls += 1; throw RequestRetry.HTTPFailure(status: status, message: "Rejected")
                }
                preconditionFailure("Failure must propagate")
            } catch { precondition(calls == 1) }
        }
        calls = 0
        do {
            let _: Int = try await RequestRetry.run(readOnly: true, pause: { throw CancellationError() }) {
                calls += 1; throw URLError(.timedOut)
            }
            preconditionFailure("Cancelled backoff must stop")
        } catch is CancellationError { precondition(calls == 1) }
        let immediate: Int = try await RequestRetry.withDeadline(seconds: 1) { 42 }
        precondition(immediate == 42)
        let probe = DeadlineProbe()
        do {
            let _: Int = try await RequestRetry.withDeadline(seconds: 0.03) { try await probe.wait() }
            preconditionFailure("The total deadline must cancel a slow request")
        } catch let error as URLError { precondition(error.code == .timedOut) }
        let cancelled = await probe.cancelled
        precondition(cancelled, "The losing request must be cancelled, not left downloading")
        do {
            let _: Int = try await RequestRetry.withDeadline(seconds: 0) { 42 }
            preconditionFailure("An exhausted budget must not start another request")
        } catch let error as URLError { precondition(error.code == .timedOut) }
        let parent = Task<Int, Error> {
            try await RequestRetry.withDeadline(seconds: 10) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        parent.cancel()
        do { _ = try await parent.value; preconditionFailure("Parent cancellation must propagate") }
        catch is CancellationError { }
        print("Read retry, total deadlines, child cancellation, mutation safety and bounded attempts passed")
    }
}
