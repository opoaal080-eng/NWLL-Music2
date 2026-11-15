import Foundation

enum RequestRetry {
    /// Bounds an entire cooperative network operation, including read retries.
    /// URLRequest.timeoutInterval alone only measures idle time between bytes.
    static func withDeadline<T: Sendable>(seconds: TimeInterval,
                                        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds.isFinite, seconds > 0 else { throw URLError(.timedOut) }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(min(seconds, 3600) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    struct HTTPFailure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    static func transient(_ error: Error) -> Bool {
        if let response = error as? HTTPFailure {
            return [408, 500, 502, 503, 504].contains(response.status)
        }
        guard let network = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(network.code)
    }

    // Retry reads only: a payment, login or other mutation may already have succeeded.
    // Bound recovery attempts to avoid keeping the loading indicator up indefinitely.
    static func run<T>(readOnly: Bool,
                       pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 500_000_000) },
                       operation: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let result = try await operation()
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                guard readOnly, attempt < 2, transient(error) else { throw error }
                try await pause()
            }
        }
        throw CancellationError() // Unreachable: the final attempt returns or throws.
    }
}
