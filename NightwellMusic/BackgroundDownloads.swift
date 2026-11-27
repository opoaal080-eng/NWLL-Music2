import Foundation
import UIKit
import Network
import os

/// URLSession owns the transfers, not a View or an unstructured foreground Task.
/// Persist the entire playlist, but submit only a bounded number of jobs.
/// A slow provider or retry must not monopolize every connection.
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
        // Optional for migration of the existing persisted v1 queue.
        var order: Int?
        var retryAt: Date?
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
        var activity: NWDownloadActivityAttributes.ContentState? = nil
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
    private var retiredTaskIDs = Set<Int>()
    private var lastByteAt: [String: Date] = [:]
    private var lastBytes: [String: Int64] = [:]
    private var failures: [String: String] = [:]
    private var connected = true
    private var foreground = false
    private var watchdog: DispatchSourceTimer?
    private let network = NWPathMonitor()
    private let logger = Logger(subsystem: "fun.nightwell.music", category: "OfflineDownloads")
    private var eventCompletion: (() -> Void)?
    private var session: URLSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let storedSession { return storedSession }
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = OfflineDownloadPolicy.parallelism
        config.timeoutIntervalForRequest = 45
        // A single transfer cannot occupy a slot for days. Pending jobs
        // remain durable and are independently scheduled after a failure.
        config.timeoutIntervalForResource = 300
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.httpCookieStorage = .shared
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        let created = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        storedSession = created
        return created
    }
    private var file: URL? {
        guard let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return root.appendingPathComponent("native-downloads.json")
    }
    private override init() {
        super.init()
        if let file, let bytes = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: bytes) { state = saved }
        cacheProgress()
        network.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.connected = path.status == .satisfied
            if self.connected && !self.reconciling { self.fillSlots() }
        }
        network.start(queue: preparationQueue)
        let timer = DispatchSource.makeTimerSource(queue: preparationQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.checkStalledTasks() }
        watchdog = timer
        timer.resume()
    }
    func setForeground(_ value: Bool) {
        preparationQueue.async {
            self.lock.lock(); defer { self.lock.unlock() }
            self.foreground = value
            if value { self.reconcile() }
        }
    }
    var progress: Progress {
        progressLock.lock(); defer { progressLock.unlock() }
        return cachedProgress
    }
    // Called during initialization or while holding the state lock. Construct
    // the snapshot before taking the short, independent UI-read lock.
    private func cacheProgress() {
        var next: Progress
        if !state.jobs.isEmpty {
            let done = state.added + state.skipped + state.failed
            let delayed = state.jobs.values.filter { ($0.retryAt ?? .distantPast) > Date() }.count
            let suffix = !connected ? " · нет сети" : (delayed > 0 ? " · повтор: \(delayed)" : "")
            next = Progress(active: true, message: "Загрузка \(done) / \(state.total)" + suffix, fractions: fractions,
                            pendingKeys: Set(state.jobs.keys), completedKeys: completedKeys)
        } else {
            next = Progress(active: false, message: state.total == 0 ? "" : "Скачано: \(state.added) · уже сохранено: \(state.skipped) · ошибок: \(state.failed)" + (failures.values.sorted().first.map { " · " + $0 } ?? ""), fractions: [:],
                            pendingKeys: [], completedKeys: completedKeys)
        }
        next.activity = NWDownloadActivityAttributes.ContentState(
            active: !state.jobs.isEmpty, total: state.total, saved: state.added + state.skipped,
            failed: state.failed,
            pendingFraction: fractions.values.reduce(0, +))
        progressLock.lock()
        cachedProgress = next
        progressLock.unlock()
    }
    // Construct the persistent URLSession as soon as iOS relaunches the app
    // for background download events. The system, not SwiftUI, owns transfers.
    func prepareForSystemEvents() { _ = session; reconnect() }
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
        let knownTasks = activeTaskIDs
        lock.unlock()
        session.getAllTasks { tasks in
            self.lock.lock(); defer { self.lock.unlock() }
            let liveIDs = Set(tasks.map(\.taskIdentifier))
            for (key, id) in knownTasks where !liveIDs.contains(id) && self.activeTaskIDs[key] == id {
                self.retiredTaskIDs.insert(id)
                self.activeTaskIDs.removeValue(forKey: key)
            }
            // Recover the previous app's daemon queue. Keep the oldest few
            // tasks, retire the rest without losing their persisted jobs.
            for task in tasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
                guard let key = task.taskDescription, self.state.jobs[key] != nil,
                      !self.retiredTaskIDs.contains(task.taskIdentifier) else {
                    task.cancel(); continue
                }
                if let active = self.activeTaskIDs[key] {
                    if active != task.taskIdentifier {
                        self.retiredTaskIDs.insert(task.taskIdentifier); task.cancel()
                    }
                } else if self.activeTaskIDs.count < OfflineDownloadPolicy.parallelism {
                    self.activeTaskIDs[key] = task.taskIdentifier
                    self.lastByteAt[key] = Date()
                    self.lastBytes[key] = task.countOfBytesReceived
                } else {
                    self.retiredTaskIDs.insert(task.taskIdentifier); task.cancel()
                }
            }
            self.reconciling = false
            self.fillSlots()
            self.publish()
        }
    }

    // Caller holds lock. Schedule ready jobs first, and only one delayed
    // retry if no ready jobs exist so iOS can wake us even in background.
    private func fillSlots() {
        guard !reconciling, connected else { return }
        let now = Date()
        let waiting = state.jobs.values.filter { activeTaskIDs[$0.key] == nil }.sorted {
            let a = $0.retryAt ?? .distantPast, b = $1.retryAt ?? .distantPast
            if (a <= now) != (b <= now) { return a <= now }
            if a > now && b > now && a != b { return a < b }
            if $0.attempts != $1.attempts { return $0.attempts < $1.attempts }
            return ($0.order ?? Int.max, $0.key) < ($1.order ?? Int.max, $1.key)
        }
        var slots = OfflineDownloadPolicy.parallelism - activeTaskIDs.count
        guard slots > 0 else { return }
        for job in waiting where slots > 0 && (job.retryAt ?? .distantPast) <= now {
            submit(job)
            slots -= 1
        }
        if activeTaskIDs.isEmpty, let first = waiting.first,
           (first.retryAt ?? .distantPast) > now {
            submit(first)
        }
    }

    private func checkStalledTasks() {
        lock.lock()
        let shouldCheck = foreground && connected && !reconciling && !state.jobs.isEmpty
        lock.unlock()
        guard shouldCheck else { return }
        session.getAllTasks { tasks in
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.foreground, self.connected, !self.reconciling else { return }
            let now = Date()
            let existing = Set(tasks.map(\.taskIdentifier))
            for (key, id) in Array(self.activeTaskIDs) where !existing.contains(id) {
                self.retiredTaskIDs.insert(id)
                self.activeTaskIDs.removeValue(forKey: key)
            }
            for task in tasks {
                guard let key = task.taskDescription,
                      self.activeTaskIDs[key] == task.taskIdentifier,
                      task.state == .running, let job = self.state.jobs[key],
                      (job.retryAt ?? .distantPast) <= now else { continue }
                let bytes = task.countOfBytesReceived
                if bytes > (self.lastBytes[key] ?? 0) {
                    self.lastBytes[key] = bytes; self.lastByteAt[key] = now
                }
                guard OfflineDownloadPolicy.stalled(since: self.lastByteAt[key] ?? now, now: now) else { continue }
                if !self.scheduleRetry(task, reason: "Нет данных от сервера") {
                    self.finish(task, success: false, reason: "Нет данных от сервера")
                }
                task.cancel()
            }
            self.fillSlots()
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
        if state.jobs.isEmpty {
            state = State(); completedKeys.removeAll(); fractions.removeAll()
            lastProgressNotification.removeAll(); failures.removeAll()
        }
        var seen = Set<String>()
        for track in tracks {
            // A stale _offline flag must not block repair of a corrupt download.
            // Imported local files have no remote source and cannot be re-downloaded.
            guard !track.id.hasPrefix("local_"),
                  track.id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { continue }
            let key = origin.absoluteString + "|" + account + "|" + track.id
            guard seen.insert(key).inserted, state.jobs[key] == nil,
                  !completedKeys.contains(key) else { continue }
            state.total += 1
            if OfflineStore.audio(origin: origin, account: account, id: track.id) != nil { state.skipped += 1; completedKeys.insert(key); continue }
            let job = Job(key: key, origin: origin, account: account, track: track,
                          order: state.total)
            state.jobs[key] = job
        }
        // Persist the complete batch once before any task resumes: a system
        // wake-up can recover every submitted job without repeated full writes.
        persist()
        fillSlots()
        publish()
    }
    private func submit(_ job: Job) {
        // Retries are a new transfer; do not carry over 100% from a preparation response.
        fractions.removeValue(forKey: job.key)
        lastProgressNotification.removeValue(forKey: job.key)
        var request = URLRequest(url: job.origin.appendingPathComponent("api/offline-export/" + job.track.id))
        request.url = URL(string: "api/offline-export/" + job.track.id + "?download=true&wait=true", relativeTo: job.origin)
        request.timeoutInterval = 45
        if let credential = try? AccountDeviceVault.read(origin: job.origin, account: job.account) {
            request.setValue(credential.device_token, forHTTPHeaderField: "X-NW-Device-Token")
        }
        if let cookies = HTTPCookieStorage.shared.cookies(for: job.origin), !cookies.isEmpty {
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = job.key
        activeTaskIDs[job.key] = task.taskIdentifier
        if let retryAt = job.retryAt, retryAt > Date() { task.earliestBeginDate = retryAt }
        lastByteAt[job.key] = max(Date(), job.retryAt ?? .distantPast)
        lastBytes[job.key] = 0
        task.resume()
    }
    private func persist() {
        if let file, let data = try? JSONEncoder().encode(state) {
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
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                    if let snapshot = self.progress.activity {
                        NWDownloadLiveActivity.shared.receive(snapshot)
                    }
                }
            }
        }
    }
    private func finish(_ task: URLSessionTask, success: Bool, reason: String = "Не удалось загрузить файл") {
        lock.lock(); defer { lock.unlock() }
        guard let key = task.taskDescription, ownsTask(task, key: key),
              state.jobs.removeValue(forKey: key) != nil else { return }
        activeTaskIDs.removeValue(forKey: key)
        retiredTaskIDs.insert(task.taskIdentifier)
        lastByteAt.removeValue(forKey: key); lastBytes.removeValue(forKey: key)
        fractions.removeValue(forKey: key)
        lastProgressNotification.removeValue(forKey: key)
        if success {
            state.added += 1; completedKeys.insert(key); failures.removeValue(forKey: key)
        } else {
            state.failed += 1; failures[key] = reason
            logger.error("Download failed: \(reason, privacy: .public)")
        }
        persist(); fillSlots(); publish()
    }
    // A stale completion from a cancelled/retried transfer must not remove
    // its replacement job. On system relaunch adopt the first live callback.
    private func ownsTask(_ task: URLSessionTask, key: String) -> Bool {
        guard !retiredTaskIDs.contains(task.taskIdentifier) else { return false }
        if let active = activeTaskIDs[key] { return active == task.taskIdentifier }
        guard state.jobs[key] != nil else { return false }
        activeTaskIDs[key] = task.taskIdentifier
        return true
    }

    // Retry temporary server errors instead of silently dropping the track.
    // Permanent errors (401/403/404) still fail promptly.
    @discardableResult
    private func scheduleRetry(_ task: URLSessionTask, retryAfter: TimeInterval = 0,
                               reason: String = "Временная ошибка", preparing: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let key = task.taskDescription, ownsTask(task, key: key),
              var job = state.jobs[key], job.attempts < OfflineDownloadPolicy.maximumRetries else { return false }
        job.attempts += 1
        let delay = OfflineDownloadPolicy.delay(attempt: job.attempts, retryAfter: retryAfter, preparing: preparing)
        job.retryAt = Date().addingTimeInterval(delay)
        state.jobs[key] = job
        retiredTaskIDs.insert(task.taskIdentifier)
        activeTaskIDs.removeValue(forKey: key)
        lastByteAt.removeValue(forKey: key); lastBytes.removeValue(forKey: key)
        fractions.removeValue(forKey: key); lastProgressNotification.removeValue(forKey: key)
        logger.notice("Download retry \(job.attempts): \(reason, privacy: .public), delay \(delay)s")
        persist()
        fillSlots()
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
            waiting = ["loading", "pending", "processing", "preparing", "queued"].contains(status.lowercased())
        }
        let retryable = [408, 425, 429, 500, 502, 503, 504].contains(statusCode)
        if waiting || retryable {
            let retryAfter = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
            if scheduleRetry(downloadTask, retryAfter: retryAfter,
                             reason: waiting ? "Сервер готовит аудио" : "HTTP \(statusCode)", preparing: waiting) { return }
        }
        guard statusCode == 200, !waiting else {
            finish(downloadTask, success: false, reason: waiting ? "Сервер не подготовил аудио" : "HTTP \(statusCode)")
            return
        }
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
               job.attempts < 3, scheduleRetry(downloadTask, reason: "Неполный аудиофайл") { return }
            finish(downloadTask, success: false, reason: "Ошибка сохранения аудио")
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
        return scheduleRetry(task, reason: "Сеть: \(code.rawValue)")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if !retryTransientFailure(task, error: error) {
            finish(task, success: false, reason: "Сеть: \((error as NSError).code)")
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > OfflineStore.limit || totalBytesExpectedToWrite > OfflineStore.limit { downloadTask.cancel(); return }
        guard let key = downloadTask.taskDescription else { return }
        lock.lock()
        guard state.jobs[key] != nil, ownsTask(downloadTask, key: key) else { lock.unlock(); return }
        if totalBytesWritten > (lastBytes[key] ?? 0) {
            lastByteAt[key] = Date(); lastBytes[key] = totalBytesWritten
        }
        guard totalBytesExpectedToWrite > 0 else { lock.unlock(); return }
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
        Task { @MainActor in
            if let snapshot = self.progress.activity {
                await NWDownloadLiveActivity.shared.flush(snapshot)
            }
            completion?()
        }
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
    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundDownloads.shared.setForeground(true)
    }
    func applicationWillResignActive(_ application: UIApplication) {
        BackgroundDownloads.shared.setForeground(false)
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.identifier else { completionHandler(); return }
        BackgroundDownloads.shared.handleEvents(completionHandler)
    }
}
