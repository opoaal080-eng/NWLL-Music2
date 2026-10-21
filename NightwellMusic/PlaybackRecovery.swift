import Foundation

// Owned by the main queue, like NativePlayer. A token also invalidates callbacks
// that have already been submitted to the queue when playback is cancelled.
final class PlaybackRecovery {
    private let delays: [TimeInterval]
    private let enqueue: (TimeInterval, @escaping () -> Void) -> Void
    private var token = UUID()
    private(set) var attempts = 0
    private(set) var pending = false

    init(delays: [TimeInterval] = [1, 2, 4],
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
            if value.domain == NSURLErrorDomain {
                return [NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                        NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                        NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet].contains(value.code)
            }
            next = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
