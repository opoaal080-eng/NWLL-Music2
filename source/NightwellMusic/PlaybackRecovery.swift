import Foundation

// Owned by the main queue, like NativePlayer. A token also invalidates callbacks
// that have already been submitted to the queue when playback is cancelled.
final class PlaybackRecovery {
    private let delays: [TimeInterval]
    private let enqueue: (TimeInterval, @escaping () -> Void) -> Void
    private var token = UUID()
    private(set) var attempts = 0
    private(set) var pending = false

    init(delays: [TimeInterval] = [0.8, 2, 5, 12, 25, 45],
         enqueue: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.delays = delays; self.enqueue = enqueue
    }

    @discardableResult func schedule(_ action: @escaping () -> Void) -> Bool {
        if pending { return true }
        guard attempts < delays.count else { return false }
        let delay = delays[attempts]
        attempts += 1; pending = true
        let expected = token
        enqueue(delay) { [weak self] in
            guard let self, self.token == expected, self.pending else { return }
            self.pending = false; action()
        }
        return true
    }

    func cancel(resetBudget: Bool = false) {
        token = UUID(); pending = false
        if resetBudget { attempts = 0 }
    }

    static func isTransient(_ error: Error?) -> Bool {
        guard let error else { return false }
        var next: NSError? = error as NSError
        for _ in 0..<8 {
            guard let value = next else { break }
            if value.domain == NSURLErrorDomain &&
                [NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed].contains(value.code) {
                return true
            }
            // A signed HLS URL can expire while the song itself remains available.
            // Only retry bounded HTTP failures; never rewrite the track as deleted.
            if let response = value.userInfo["NSURLErrorFailingURLResponseErrorKey"] as? HTTPURLResponse {
                let status = response.statusCode
                if status == 403 || status == 404 || status == 408 || status == 425 ||
                   status == 429 || (500...599).contains(status) { return true }
            }
            if value.domain == NSURLErrorDomain && value.code == NSURLErrorBadServerResponse {
                return true
            }
            // AVFoundation may wrap a transient network failure in another
            // NSError. Continue looking even if an outer URL error is not retryable.
            next = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
