import Foundation
import CryptoKit

// Main-queue owner. Only the current, audible track is analysed, and analysis
// never participates in the AVPlayer output path.
final class IndependentAudioMeter {
    private(set) var key = ""
    private(set) var envelope: TrackEnvelope?
    private var generation = UUID()
    private var preparation = AuraPreparationPolicy()
    private var download: EnvelopeDownload?
    private var worker: Task<Void, Never>?
    private let cache = NSCache<NSString, NSData>()
    init() { cache.totalCostLimit = 2 * 1024 * 1024; cache.countLimit = 24 }

    func cancel(keepingEnvelope: Bool = false) {
        preparation = AuraPreparationPolicy()
        generation = UUID(); download?.cancel(); download = nil; worker?.cancel(); worker = nil
        if !keepingEnvelope || envelope == nil { envelope = nil; key = "" }
    }
    func needsPreparation(for key: String) -> Bool {
        self.key != key || (envelope == nil && worker == nil && download == nil &&
            preparation.canBegin(now: ProcessInfo.processInfo.systemUptime))
    }
    func prepare(key: String, local: URL?, request: URLRequest?, origin: URL) {
        if self.key != key { cancel(); self.key = key }
        guard envelope == nil, worker == nil, download == nil,
              preparation.begin(now: ProcessInfo.processInfo.systemUptime) else { return }
        if let data = cache.object(forKey: key as NSString) as Data?,
           let value = try? JSONDecoder().decode(TrackEnvelope.self, from: data), value.valid { envelope = value; return }
        let expected = generation
        // Cache reads and decoding also run off the UI thread.
        worker = Task.detached(priority: .utility) { [weak self] in
            let cached = EnvelopeCache.read(key)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == expected else { return }
                self.worker = nil
                if let cached { self.accept(cached, key: key); return }
                if let local { self.analyse(local, temporary: false, expected: expected); return }
                guard let request else { self.failed(expected: expected); return }
                let download = EnvelopeDownload(origin: origin)
                self.download = download
                download.start(request) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.generation == expected else {
                            if case let .success(file) = result { try? FileManager.default.removeItem(at: file) }
                            return
                        }
                        self.download = nil
                        switch result {
                        case let .success(file): self.analyse(file, temporary: true, expected: expected)
                        case .failure: self.failed(expected: expected)
                        }
                    }
                }
            }
        }
    }
    private func analyse(_ file: URL, temporary: Bool, expected: UUID) {
        let currentKey = key
        worker = Task.detached(priority: .utility) { [weak self] in
            defer { if temporary { try? FileManager.default.removeItem(at: file) } }
            guard let value = try? TrackEnvelope.analyse(file, cancelled: { Task.isCancelled }), !Task.isCancelled else {
                await MainActor.run { self?.failed(expected: expected) }
                return
            }
            EnvelopeCache.write(value, key: currentKey)
            await MainActor.run {
                guard let self, self.generation == expected else { return }
                self.worker = nil; self.accept(value, key: currentKey)
            }
        }
    }
    private func failed(expected: UUID) {
        guard generation == expected else { return }
        worker = nil; download = nil
        preparation.failed(now: ProcessInfo.processInfo.systemUptime)
    }
    private func accept(_ value: TrackEnvelope, key: String) {
        envelope = value
        if let data = try? JSONEncoder().encode(value) { cache.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
    }
    func level(at seconds: Double, playing: Bool) -> Double { envelope?.level(at: seconds, playing: playing) ?? 0 }
}

private enum EnvelopeCache {
    static func directory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let root = base.appendingPathComponent("aura-envelopes-v1", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root } catch { return nil }
    }
    static func file(_ key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory()?.appendingPathComponent(digest + ".json")
    }
    static func read(_ key: String) -> TrackEnvelope? {
        guard let file = file(key), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 512 * 1024, let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(TrackEnvelope.self, from: data), value.valid else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return value
    }
    static func write(_ value: TrackEnvelope, key: String) {
        guard let file = file(key), let bytes = try? JSONEncoder().encode(value) else { return }
        try? bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard let root = directory(), let files = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let ordered = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var total = 0
        for (index, file) in ordered.enumerated() {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if index >= 64 || total > 8 * 1024 * 1024 { try? FileManager.default.removeItem(at: file) }
        }
    }
}

// Bounded, low-priority transfer on disk, separate from audio playback. Cancelling
// UI analysis closes this foreground session and never cancels the player's stream.
final class EnvelopeDownload: NSObject, URLSessionDownloadDelegate {
    private let origin: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var complete: ((Result<URL, Error>) -> Void)?
    private var finished = false
    init(origin: URL) { self.origin = origin }
    func start(_ request: URLRequest, complete: @escaping (Result<URL, Error>) -> Void) {
        self.complete = complete
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.downloadTask(with: request); self.task = task
        task.priority = URLSessionTask.lowPriority; task.resume()
    }
    func cancel() { finish(.failure(URLError(.cancelled))) }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            if case let .success(file) = result { try? FileManager.default.removeItem(at: file) }
            return
        }
        finished = true; let callback = complete; complete = nil
        let session = self.session; self.session = nil; task = nil; lock.unlock()
        session?.invalidateAndCancel(); callback?(result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
                  let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 256, size <= OfflineStore.limit else { throw URLError(.badServerResponse) }
            let input = try FileHandle(forReadingFrom: location); defer { try? input.close() }
            let header = try input.read(upToCount: 12) ?? Data()
            guard let fileExtension = AuraAudioContainer.fileExtension(header) else { throw URLError(.cannotDecodeContentData) }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("aura-" + UUID().uuidString + "." + fileExtension)
            try FileManager.default.moveItem(at: location, to: target); finish(.success(target))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > OfflineStore.limit || totalBytesExpectedToWrite > OfflineStore.limit { finish(.failure(URLError(.dataLengthExceedsMaximum))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { ServerAddress.sameOrigin(origin, $0) } == true ? request : nil)
    }
}

