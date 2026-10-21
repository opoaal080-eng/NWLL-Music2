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
    struct Progress { let active: Bool; let message: String }
    private let lock = NSRecursiveLock()
    private var state = State()
    private var ready = false
    private var eventCompletion: (() -> Void)?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpCookieStorage = .shared
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()
    private var file: URL {
        let root = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return root.appendingPathComponent("native-downloads.json")
    }
    private override init() {
        super.init()
        if let bytes = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: bytes) { state = saved }
    }
    var progress: Progress {
        lock.lock(); defer { lock.unlock() }
        if !state.jobs.isEmpty {
            let done = state.added + state.skipped + state.failed
            return Progress(active: true, message: "Загрузка \(done) / \(state.total)")
        }
        return Progress(active: false, message: state.total == 0 ? "" : "Скачано: \(state.added) · уже сохранено: \(state.skipped) · ошибок: \(state.failed)")
    }
    func handleEvents(_ completion: @escaping () -> Void) {
        lock.lock(); eventCompletion = completion; lock.unlock()
        _ = session
    }
    func reconnect() {
        lock.lock(); defer { lock.unlock() }
        guard !ready else { return }; ready = true
        let recovering = Array(state.jobs.values)
        session.getAllTasks { tasks in
            self.lock.lock(); defer { self.lock.unlock() }
            let existing = Set(tasks.compactMap(\.taskDescription))
            // Tasks canceled by a user force-quit are absent on the next manual launch.
            for job in recovering where self.state.jobs[job.key] != nil && !existing.contains(job.key) { self.submit(job) }
            for task in tasks where task.taskDescription.flatMap({ self.state.jobs[$0] }) == nil { task.cancel() }
            self.publish()
        }
    }
    func enqueue(_ tracks: [Track], origin: URL, account: String) {
        lock.lock(); defer { lock.unlock() }
        reconnect()
        if state.jobs.isEmpty { state = State() }
        for track in tracks {
            guard track._offline != true, track.id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { continue }
            let key = origin.absoluteString + "|" + account + "|" + track.id
            guard state.jobs[key] == nil else { continue }
            state.total += 1
            if OfflineStore.audio(origin: origin, account: account, id: track.id) != nil { state.skipped += 1; continue }
            let job = Job(key: key, origin: origin, account: account, track: track)
            state.jobs[key] = job
            // Persist before resume: a system wake-up can always recover the metadata.
            persist(); submit(job)
        }
        persist(); publish()
    }
    private func submit(_ job: Job) {
        var request = URLRequest(url: job.origin.appendingPathComponent("api/offline-export/" + job.track.id))
        request.url = URL(string: "api/offline-export/" + job.track.id + "?download=true&wait=true", relativeTo: job.origin)
        request.timeoutInterval = 300
        if let cookies = HTTPCookieStorage.shared.cookies(for: job.origin), !cookies.isEmpty {
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = job.key
        if job.attempts > 0 { task.earliestBeginDate = Date().addingTimeInterval(5) }
        task.resume()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var mutable = file; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? mutable.setResourceValues(values)
        }
    }
    private func publish() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) } }
    private func finish(_ task: URLSessionTask, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let key = task.taskDescription, state.jobs.removeValue(forKey: key) != nil else { return }
        if success { state.added += 1 } else { state.failed += 1 }
        persist(); publish()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let job = downloadTask.taskDescription.flatMap { state.jobs[$0] }; lock.unlock()
        guard var job, let http = downloadTask.response as? HTTPURLResponse else { finish(downloadTask, success: false); return }
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var waiting = http.statusCode == 503
        // Compatibility with servers that still return preparation JSON for download=true.
        if http.statusCode == 200, size < 65536, let bytes = try? Data(contentsOf: location), let status = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["status"] as? String { waiting = status == "loading" || status == "pending" }
        if waiting && job.attempts < 100 {
            lock.lock(); job.attempts += 1; state.jobs[job.key] = job; persist(); submit(job); lock.unlock(); return
        }
        guard http.statusCode == 200, !waiting else { finish(downloadTask, success: false); return }
        do {
            try OfflineStore.saveDownloadedFile(location, track: job.track, origin: job.origin, account: job.account)
            finish(downloadTask, success: true)
        } catch { finish(downloadTask, success: false) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(task, success: false) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > OfflineStore.limit || totalBytesExpectedToWrite > OfflineStore.limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Offline exports must remain on our HTTPS origin; never forward session cookies to a media CDN.
        lock.lock(); let origin = task.taskDescription.flatMap { state.jobs[$0]?.origin }; lock.unlock()
        completionHandler(origin.flatMap { base in request.url.map { ServerAddress.sameOrigin(base, $0) } } == true ? request : nil)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let completion = eventCompletion; eventCompletion = nil; lock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.identifier else { completionHandler(); return }
        BackgroundDownloads.shared.handleEvents(completionHandler)
    }
}
