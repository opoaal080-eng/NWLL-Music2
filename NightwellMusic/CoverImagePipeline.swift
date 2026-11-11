import SwiftUI
import UIKit
import ImageIO

/// One artwork downloader shared by track rows, mini player, full player and
/// backdrop. Deduplicates concurrent requests, caches bytes and decodes thumbnails
/// off the main thread so opening a list never decodes full resolution JPEGs.
actor CoverImagePipeline {
    static let shared = CoverImagePipeline()

    private let decoded = NSCache<NSString, UIImage>()
    private let compressed = NSCache<NSString, NSData>()
    private var pendingData: [String: Task<Data?, Never>] = [:]
    private var pendingImages: [String: Task<UIImage?, Never>] = [:]
    // Bad/unavailable provider artwork can otherwise be re-requested by
    // every row in a recycled list, even while the network is struggling.
    private var retryAfter: [String: Date] = [:]
    private let session: URLSession

    private func skipTemporarily(_ url: String) -> Bool {
        guard let deadline = retryAfter[url] else { return false }
        if deadline > Date() { return true }
        retryAfter.removeValue(forKey: url)
        return false
    }

    private func markUnavailable(_ url: String) {
        retryAfter[url] = Date().addingTimeInterval(8)
        if retryAfter.count > 256 {
            let now = Date()
            retryAfter = retryAfter.filter { $0.value > now }
            if retryAfter.count > 256 {
                for key in Array(retryAfter.keys.prefix(retryAfter.count - 192)) {
                    retryAfter.removeValue(forKey: key)
                }
            }
        }
    }

    private init() {
        decoded.totalCostLimit = 48 * 1024 * 1024
        decoded.countLimit = 180
        compressed.totalCostLimit = 28 * 1024 * 1024
        compressed.countLimit = 100

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 28 * 1024 * 1024,
            diskCapacity: 160 * 1024 * 1024,
            diskPath: "nightwell-cover-thumbnails"
        )
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpMaximumConnectionsPerHost = 5
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
    }

    /// Resolve the same server/CDN cover used by the lock-screen player.
    /// Provider tracks sometimes have no cover_url but do have /api/covers/id.
    static func coverURL(for track: Track, origin: URL) -> URL? {
        let raw = track.cover_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path: String
        if !raw.isEmpty {
            path = raw
        } else if track.is_remote == true || track.source?.lowercased().contains("soundcloud") == true {
            path = "/api/covers/" + track.id
        } else {
            return nil
        }
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }

    func image(for url: URL, maxPixel: Int = 160) async -> UIImage? {
        let dimension = min(1200, max(96, maxPixel))
        let key = "\(url.absoluteString)#\(dimension)"
        if let hit = decoded.object(forKey: key as NSString) { return hit }
        if skipTemporarily(url.absoluteString) { return nil }
        if let inFlight = pendingImages[key] { return await inFlight.value }

        let task = Task<UIImage?, Never>(priority: .userInitiated) {
            guard let bytes = await self.data(for: url), !bytes.isEmpty else { return nil }
            // ImageIO's thumbnail creation handles orientation without decoding
            // the original multi-megapixel cover into a main-thread UIImage.
            return await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
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
        pendingImages[key] = task
        let result = await task.value
        pendingImages[key] = nil
        if let result, let cgImage = result.cgImage {
            decoded.setObject(result, forKey: key as NSString,
                              cost: cgImage.bytesPerRow * cgImage.height)
            retryAfter.removeValue(forKey: url.absoluteString)
        } else if result == nil && !Task.isCancelled {
            markUnavailable(url.absoluteString)
        }
        return result
    }

    private func data(for url: URL) async -> Data? {
        let key = url.absoluteString
        if let hit = compressed.object(forKey: key as NSString) { return hit as Data }
        if skipTemporarily(key) { return nil }
        if let inFlight = pendingData[key] { return await inFlight.value }
        let task = Task<Data?, Never>(priority: .userInitiated) {
            do {
                var request = URLRequest(url: url)
                // Cover URLs are content-addressed; reuse downloaded images even
                // when the API serves conservative cache headers.
                request.cachePolicy = .returnCacheDataElseLoad
                let (bytes, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      bytes.count > 0, bytes.count <= 8 * 1024 * 1024 else { return nil }
                return bytes
            } catch {
                return nil
            }
        }
        pendingData[key] = task
        let result = await task.value
        pendingData[key] = nil
        if let result {
            compressed.setObject(result as NSData, forKey: key as NSString, cost: result.count)
            retryAfter.removeValue(forKey: key)
        } else {
            markUnavailable(key)
        }
        return result
    }

    /// Warm small groups without serially waiting for each remote cover.
    /// Limit concurrent speculative requests to leave bandwidth for audio.
    func prefetch(_ urls: [URL], maxPixel: Int = 160) async {
        var seen = Set<URL>()
        let candidates = urls.prefix(6).filter { seen.insert($0).inserted }
        for start in stride(from: 0, to: candidates.count, by: 2) {
            if Task.isCancelled { return }
            let groupURLs = Array(candidates[start..<min(start + 2, candidates.count)])
            await withTaskGroup(of: Void.self) { group in
                for url in groupURLs {
                    group.addTask(priority: .utility) {
                        _ = await self.image(for: url, maxPixel: maxPixel)
                    }
                }
            }
        }
    }
}
