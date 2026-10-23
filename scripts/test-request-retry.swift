import Foundation
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
        print("Read retry, transient HTTP failures, bounded attempts, mutation safety and cancellation passed")
    }
}
