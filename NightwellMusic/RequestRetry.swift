import Foundation

enum RequestRetry {
    struct HTTPFailure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }
    static func transient(_ error: Error) -> Bool {
        if let response = error as? HTTPFailure { return [408, 502, 503, 504].contains(response.status) }
        guard let network = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(network.code)
    }
    // Only reads may be repeated. A payment/login/write may have reached the server.
    static func run<T>(readOnly: Bool,
                       pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 350_000_000) },
                       operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        do { return try await operation() }
        catch {
            try Task.checkCancellation()
            guard readOnly, transient(error) else { throw error }
            try await pause()
            try Task.checkCancellation()
            return try await operation()
        }
    }
}
