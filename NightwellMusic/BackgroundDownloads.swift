import Foundation
import UIKit

/// URLSession owns the transfers, not a View or an unstructured foreground Task.
/// All jobs are submitted before returning from a user action, so iOS can run the
/// whole playlist without waking the UI to schedule every next track.
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloads()
    static let identifier = "fun.nightwell.music.offline.downloads.v1"
    static let changed = Notification.Name("native.downloads.changed")
    struct Job: Codable {
        let key: String
        let origin: URL
        let account: String
        let track: Track
        var attempts: Int = 0
    }
    struct State: Codable {
        var jobs: [String: Job] = [:]
        var total = 0, added = 0, skipped = 0, failed = 0
    }
    struct Progress {
        let active: Bool
        let message: String
        let fractions: [String: Double]
        let pendingKeys: Set<String>
        let completedKeys: Set<String>
    }
    private let lock = NSRecursiveLock()
    private let preparationQueue = DispatchQueue(label: "fun.nightwell.offline.preparation", qos: .utility)
    // UI progress reads never wait for job persistence, filesystem validation,
    // or task submission while the state lock is held on a worker queue.
    private let progressLock = NSLock()
    private var cachedProgress = Progress(active: false, message: "", fractions: [:],
        pendingKeys: [], completedKeys: [])
    private let eventLock = NSLock()
    private let sessionLock = NSLock()
    private var storedSession: URLSession?
    private var state = State()
    private var fractions: [String: Double] = [:]
    private var completedKeys = Set<String>()
    private var lastProgressNotification: [String: Date] = [:]
    private var reconciling = false
    private var activeTaskIDs: [String: Int] = [:]
    private var notificationPending = false
    private var eventCompletion: (() -> Void)?
    private var session: URLSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let storedSession { return storedSession }
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 70
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpCookieStorage = .shared
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        let created = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        storedSession = created
        return created
    }
    private var file: URL {
        let root = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return root.appendingPathComponent("native-downloads.json")
    }
    private override init() {
        super.init()
        if let bytes = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: bytes) { state = saved }
        cacheProgress()
    }
    var progress: Progress {
        progressLock.lock(); defer { progressLock.unlock() }
        return cachedProgress
    }
    // Called during initialization or while holding the state lock. Construct
    // the snapshot before taking the short, independent UI-read lock.
    private func cacheProgress() {
        let next: Progress
        if !state.jobs.isEmpty {
            let done = state.added + state.skipped + state.failed
            next = Progress(active: true, message: "Загрузка \(done) / \(state.total)", fractions: fractions,
                            pendingKeys: Set(state.jobs.keys), completedKeys: completedKeys)
        } else {
            next = Progress(active: false, message: state.total == 0 ? "" : "Скачано: \(state.added) · уже сохранено: \(state.skipped) · ошибок: \(state.failed)", fractions: [:],
                            pendingKeys: [], completedKeys: completedKeys)
        }
        progressLock.lock()
        cachedProgress = next
        progressLock.unlock()
    }
    // Construct the persistent URLSession as soon as iOS relaunches the app
    // for background download events. The system, not SwiftUI, owns transfers.
    func prepareForSystemEvents() { _ = session }
    func handleEvents(_ completion: @escaping () -> Void) {
        eventLock.lock(); eventCompletion = completion; eventLock.unlock()
        prepareForSystemEvents()
    }
    // Reconcile on launch and when the user returns to the app. A one-time
    // ready flag left orphaned jobs stuck forever if a system task disappeared.
    func reconnect() {
        preparationQueue.async { self.reconcile() }
    }
    private func reconcile() {
        lock.lock()
        guard !reconciling else { lock.unlock(); return }
        reconciling = true
        // Snapshot first: jobs added while getAllTasks is running have already
        // been submitted by enqueue() and must not be duplicated.
        let recovering = Array(state.jobs.values)
        let knownTasks = activeTaskIDs
        lock.unlock()
        session.getAllTasks { tasks in
            self.lock.lock(); defer { self.lock.unlock() }
            let liveIDs = Set(tasks.map(\.taskIdentifier))
            // Forget an ID only if no newer task was submitted during this
            // asynchronous enumeration. Missing daemon jobs can then recover.
            for (key, id) in knownTasks where !liveIDs.contains(id) && self.activeTaskIDs[key] == id {
                self.activeTaskIDs.removeValue(forKey: key)
            }
            for task in tasks {
                guard let key = task.taskDescription, self.state.jobs[key] != nil else {
                    task.cancel(); continue
                }
                if let active = self.activeTaskIDs[key], active != task.taskIdentifier {
                    task.cancel()
                } else {
                    self.activeTaskIDs[key] = task.taskIdentifier
                }
            }
            for job in recovering where self.state.jobs[job.key] != nil && self.activeTaskIDs[job.key] == nil {
                // Read the latest persisted attempt, not the stale snapshot.
                if let latest = self.state.jobs[job.key] { self.submit(latest) }
            }
            self.reconciling = false
            self.publish()
        }
    }
    func enqueue(_ tracks: [Track], origin: URL, account: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            preparationQueue.async {
                self.enqueueJobs(tracks, origin: origin, account: account)
                continuation.resume()
            }
        }
    }
    private func enqueueJobs(_ tracks: [Track], origin: URL, account: String) {
        lock.lock(); defer { lock.unlock() }
        reconcile()
        if state.jobs.isEmpty { state = State(); completedKeys.removeAll(); fractions.removeAll(); lastProgressNotification.removeAll() }
        var pending: [Job] = []
        for track in tracks {
            // A stale _offline flag must not block repair of a corrupt download.
            // Imported local files have no remote source and cannot be re-downloaded.
            guard !track.id.hasPrefix("local_"),
                  track.id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { continue }
            let key = origin.absoluteString + "|" + account + "|" + track.id
            guard state.jobs[key] == nil else { continue }
            state.total += 1
            if OfflineStore.audio(origin: origin, account: account, id: track.id) != nil { state.skipped += 1; completedKeys.insert(key); continue }
            let job = Job(key: key, origin: origin, account: account, track: track)
            state.jobs[key] = job
            pending.append(job)
        }
        // Persist the complete batch once before any task resumes: a system
        // wake-up can recover every submitted job without repeated full writes.
        persist()
        for job in pending { submit(job) }
        publish()
    }
    private func submit(_ job: Job, retryAfter: TimeInterval = 0) {
        // Retries are a new transfer; do not carry over 100% from a preparation response.
        fractions.removeValue(forKey: job.key)
        lastProgressNotification.removeValue(forKey: job.key)
        var request = URLRequest(url: job.origin.appendingPathComponent("api/offline-export/" + job.track.id))
        request.url = URL(string: "api/offline-export/" + job.track.id + "?download=true&wait=true", relativeTo: job.origin)
        request.timeoutInterval = 70
        if let credential = try? AccountDeviceVault.read(origin: job.origin, account: job.account) {
            request.setValue(credential.device_token, forHTTPHeaderField: "X-NW-Device-Token")
        }
        if let cookies = HTTPCookieStorage.shared.cookies(for: job.origin), !cookies.isEmpty {
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = job.key
        activeTaskIDs[job.key] = task.taskIdentifier
        if job.attempts > 0 {
            // Back off when the server is preparing a file, rate-limiting, or
            // temporarily unavailable. This is persisted through app restarts.
            let delay = min(180.0, 3.0 * pow(1.7, Double(min(job.attempts, 14))))
            task.earliestBeginDate = Date().addingTimeInterval(max(delay, retryAfter))
        }
        task.resume()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var mutable = file; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? mutable.setResourceValues(values)
        }
    }
    private func publish() {
        cacheProgress()
        // Coalesce all byte updates across concurrent jobs into one UI event.
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            self.preparationQueue.async {
                self.lock.lock(); self.notificationPending = false; self.lock.unlock()
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
            }
        }
    }
    private func finish(_ task: URLSessionTask, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let key = task.taskDescription, ownsTask(task, key: key),
              state.jobs.removeValue(forKey: key) != nil else { return }
        activeTaskIDs.removeValue(forKey: key)
        fractions.removeValue(forKey: key)
        lastProgressNotification.removeValue(forKey: key)
        if success { state.added += 1; completedKeys.insert(key) } else { state.failed += 1 }
        persist(); publish()
    }
    // A stale completion from a cancelled/retried transfer must not remove
    // its replacement job. On system relaunch adopt the first live callback.
    private func ownsTask(_ task: URLSessionTask, key: String) -> Bool {
        if let active = activeTaskIDs[key] { return active == task.taskIdentifier }
        guard state.jobs[key] != nil else { return false }
        activeTaskIDs[key] = task.taskIdentifier
        return true
    }

    // Retry temporary server errors instead of silently dropping the track.
    // Permanent errors (401/403/404) still fail promptly.
    @discardableResult
    private func scheduleRetry(_ task: URLSessionTask, retryAfter: TimeInterval = 0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let key = task.taskDescription, ownsTask(task, key: key),
              var job = state.jobs[key], job.attempts < 24 else { return false }
        job.attempts += 1
        state.jobs[key] = job
        persist()
        submit(job, retryAfter: retryAfter)
        publish()
        return true
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let job = downloadTask.taskDescription.flatMap { key in
            ownsTask(downloadTask, key: key) ? state.jobs[key] : nil
        }
        lock.unlock()
        guard let job, let http = downloadTask.response as? HTTPURLResponse else {
            finish(downloadTask, success: false); return
        }
        let statusCode = http.statusCode
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var waiting = statusCode == 202
        // Some server versions return "loading" or "pending" while they
        // prepare an offline file. Don't mistake that JSON for an audio error.
        if statusCode == 200, size < 65536,
           let bytes = try? Data(contentsOf: location),
           let status = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["status"] as? String {
            waiting = ["loading", "pending", "processing"].contains(status.lowercased())
        }
        let retryable = [408, 425, 429, 500, 502, 503, 504].contains(statusCode)
        if waiting || retryable {
            let retryAfter = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
            if scheduleRetry(downloadTask, retryAfter: min(max(0, retryAfter), 900)) { return }
        }
        guard statusCode == 200, !waiting else { finish(downloadTask, success: false); return }
        do {
            try OfflineStore.saveDownloadedFile(location, track: job.track, origin: job.origin, account: job.account)
            // Keep cover art permanently with audio. Fetching it after the
            // network is lost is unreliable, so download it while this export
            // session still has connectivity. The player never waits for art.
            let saved = job
            Task.detached(priority: .utility) {
                await OfflineArtworkArchive.shared.saveIfNeeded(
                    saved.track, origin: saved.origin, account: saved.account)
            }
            finish(downloadTask, success: true)
        } catch {
            // A truncated export can return 200. Retry a limited number of
            // times, but do not loop on disk-full or other local I/O errors.
            if (error as? URLError)?.code == .cannotDecodeContentData,
               job.attempts < 3, scheduleRetry(downloadTask) { return }
            finish(downloadTask, success: false)
        }
    }
    // A connection may drop while the iPhone is locked or switches networks.
    // Recover transient failures without asking a suspended SwiftUI view to
    // schedule the next attempt. Jobs remain persisted until truly finished.
    private func retryTransientFailure(_ task: URLSessionTask, error: Error) -> Bool {
        guard let code = (error as? URLError)?.code,
              [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet,
               .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
               .backgroundSessionWasDisconnected].contains(code) else { return false }
        return scheduleRetry(task)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if !retryTransientFailure(task, error: error) { finish(task, success: false) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > OfflineStore.limit || totalBytesExpectedToWrite > OfflineStore.limit { downloadTask.cancel(); return }
        guard let key = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        guard state.jobs[key] != nil, ownsTask(downloadTask, key: key) else { lock.unlock(); return }
        // Fraction is derived from actual transfer bytes. Saving the file is still
        // pending at 100% transferred, so only mark a track complete in finish().
        let value = min(0.999, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        let previous = fractions[key] ?? 0
        if value - previous >= 0.001 || (value >= 0.999 && previous < 0.999) {
            fractions[key] = value
            let now = Date()
            if value >= 0.999 || now.timeIntervalSince(lastProgressNotification[key] ?? .distantPast) >= 0.2 {
                lastProgressNotification[key] = now
                publish()
            }
        }
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Offline exports must remain on our HTTPS origin; never forward session cookies to a media CDN.
        lock.lock(); let origin = task.taskDescription.flatMap { state.jobs[$0]?.origin }; lock.unlock()
        completionHandler(origin.flatMap { base in request.url.map { ServerAddress.sameOrigin(base, $0) } } == true ? request : nil)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventLock.lock(); let completion = eventCompletion; eventCompletion = nil; eventLock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}

// Hold just the brief Premium check and background-session enqueue, not the
// actual download. File transfer continues in iOS's out-of-process daemon.
final class OfflineDownloadPreparation {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Nightwell: prepare offline downloads") { [weak self] in
            self?.end()
        }
    }
    func end() {
        lock.lock()
        let task = identifier
        identifier = .invalid
        lock.unlock()
        guard task != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundDownloads.shared.prepareForSystemEvents()
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.identifier else { completionHandler(); return }
        BackgroundDownloads.shared.handleEvents(completionHandler)
    }
}
