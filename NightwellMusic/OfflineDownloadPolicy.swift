import Foundation

enum OfflineDownloadPolicy {
    static let parallelism = 4
    static let maximumRetries = 7
    static let stallTimeout: TimeInterval = 90

    static func delay(attempt: Int, retryAfter: TimeInterval, preparing: Bool) -> TimeInterval {
        let exponent = min(5, max(0, attempt - 1))
        let backoff = min(60, (preparing ? 3.0 : 5.0) * pow(2, Double(exponent)))
        // Respect valid server Retry-After up to five minutes. Delayed jobs
        // do not consume a slot while other ready jobs are available.
        let server = retryAfter.isFinite ? max(0, min(300, retryAfter)) : 0
        return max(backoff, server)
    }

    static func stalled(since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) >= stallTimeout
    }
}
