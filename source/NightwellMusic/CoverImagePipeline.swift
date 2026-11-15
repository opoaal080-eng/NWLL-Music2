import SwiftUI
import UIKit
import ImageIO

/// Shared, bounded artwork loading. Consumers leaving search rows release their
/// work; a slow/failed cover cannot occupy a connection indefinitely.
actor CoverImagePipeline {
    static let shared = CoverImagePipeline()

    private struct Pending<Value> {
        let id = UUID()
        let task: Task<Value?, Never>
        var consumers: Set<UUID>
    }
    private let decoded = NSCache<NSString, UIImage>()
    private let compressed = NSCache<NSString, NSData>()
    private var pendingData: [String: Pending<Data>] = [:]
    private var pendingImages: [String: Pending<UIImage>] = [:]
    private var failures: [String: Date] = [:]
    private let session: URLSession

    private init() {
        decoded.totalCostLimit = 48 * 1024 * 1024
        decoded.countLimit = 180
        compressed.totalCostLimit = 28 * 1024 * 1024
        compressed.countLimit = 100
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 28 * 1024 * 1024,
            diskCapacity: 160 * 1024 * 1024, diskPath: "nightwell-cover-thumbnails")
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpMaximumConnectionsPerHost = 5
        configuration.timeoutIntervalForRequest = 8
        // The request timeout only bounds idle time. A trickling response needs
        // a separate total transfer limit, otherwise it can last for minutes.
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    static func coverURL(for track: Track, origin: URL) -> URL? {
        let raw = track.cover_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path: String
        if !raw.isEmpty { path = raw }
        else if track.is_remote == true || track.source?.lowercased().contains("soundcloud") == true {
            path = "/api/covers/" + track.id
        } else { return nil }
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }

    func image(for url: URL, maxPixel: Int = 160) async -> UIImage? {
        guard !Task.isCancelled, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil else { return nil }
        let dimension = min(1200, max(96, maxPixel))
        let key = "\(url.absoluteString)#\(dimension)", consumer = UUID()
        if let hit = decoded.object(forKey: key as NSString) { return hit }
        let entry: Pending<UIImage>
        if var current = pendingImages[key] {
            current.consumers.insert(consumer); pendingImages[key] = current; entry = current
        } else {
            let task = Task<UIImage?, Never>(priority: .userInitiated) {
                guard let bytes = await self.data(for: url), !Task.isCancelled else { return nil }
                return await Task.detached(priority: .utility) {
                    guard !Task.isCancelled,
                          let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: dimension,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                    else { return nil }
                    return UIImage(cgImage: thumbnail)
                }.value
            }
            entry = Pending(task: task, consumers: [consumer]); pendingImages[key] = entry
        }
        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { await self.releaseImage(key, entryID: entry.id, consumer: consumer) }
        }
        if pendingImages[key]?.id == entry.id {
            pendingImages[key] = nil
            if let result, let cgImage = result.cgImage {
                decoded.setObject(result, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            }
        }
        return Task.isCancelled ? nil : result
    }

    private func releaseImage(_ key: String, entryID: UUID, consumer: UUID) {
        guard var entry = pendingImages[key], entry.id == entryID else { return }
        entry.consumers.remove(consumer)
        if entry.consumers.isEmpty {
            pendingImages[key] = nil; entry.task.cancel()
        } else { pendingImages[key] = entry }
    }

    private func data(for url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let key = url.absoluteString, consumer = UUID()
        if let hit = compressed.object(forKey: key as NSString) { return hit as Data }
        if let until = failures[key], until > Date() { return nil }
        let entry: Pending<Data>
        if var current = pendingData[key] {
            current.consumers.insert(consumer); pendingData[key] = current; entry = current
        } else {
            let task = Task<Data?, Never>(priority: .userInitiated) { [session] in
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .returnCacheDataElseLoad
                    request.timeoutInterval = 8
                    // Only authenticate artwork hosted on our configured Nightwell origin.
                    // Never forward this private header to an external cover/CDN URL.
                    let configured = UserDefaults.standard.string(forKey: "nightwell.server") ?? "https://music.nightwell.fun/"
                    if let origin = ServerAddress.validated(configured),
                       url.host == origin.host, url.port == origin.port,
                       let data = UserDefaults.standard.data(forKey: "native.account"),
                       let account = try? JSONDecoder().decode(Account.self, from: data),
                       let credential = try? AccountDeviceVault.read(origin: origin, account: account.id) {
                        request.setValue(credential.device_token, forHTTPHeaderField: "X-NW-Device-Token")
                    }
                    let (bytes, response) = try await session.data(for: request)
                    guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode), !bytes.isEmpty,
                          bytes.count <= 8 * 1024 * 1024 else { return nil }
                    return bytes
                } catch { return nil }
            }
            entry = Pending(task: task, consumers: [consumer]); pendingData[key] = entry
        }
        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { await self.releaseData(key, entryID: entry.id, consumer: consumer) }
        }
        if pendingData[key]?.id == entry.id {
            pendingData[key] = nil
            if let result {
                failures[key] = nil
                compressed.setObject(result as NSData, forKey: key as NSString, cost: result.count)
            } else if !entry.task.isCancelled {
                // Brief negative caching collapses repeated failing rows without
                // permanently hiding artwork after login/network recovery.
                if failures.count >= 128 { failures = failures.filter { $0.value > Date() } }
                if failures.count >= 128 { failures.removeAll(keepingCapacity: true) }
                failures[key] = Date().addingTimeInterval(3)
            }
        }
        return Task.isCancelled ? nil : result
    }

    private func releaseData(_ key: String, entryID: UUID, consumer: UUID) {
        guard var entry = pendingData[key], entry.id == entryID else { return }
        entry.consumers.remove(consumer)
        if entry.consumers.isEmpty {
            pendingData[key] = nil; entry.task.cancel()
        } else { pendingData[key] = entry }
    }

    func prefetch(_ urls: [URL], maxPixel: Int = 160) async {
        var seen = Set<URL>()
        let candidates = urls.prefix(6).filter { seen.insert($0).inserted }
        for start in stride(from: 0, to: candidates.count, by: 2) {
            if Task.isCancelled { return }
            let groupURLs = Array(candidates[start..<min(start + 2, candidates.count)])
            await withTaskGroup(of: Void.self) { group in
                for url in groupURLs {
                    group.addTask(priority: .utility) { _ = await self.image(for: url, maxPixel: maxPixel) }
                }
            }
        }
    }
}
