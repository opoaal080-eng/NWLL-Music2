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
    private let session: URLSession

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
        configuration.timeoutIntervalForRequest = 18
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL, maxPixel: Int = 160) async -> UIImage? {
        let dimension = min(1200, max(96, maxPixel))
        let key = "\(url.absoluteString)#\(dimension)"
        if let hit = decoded.object(forKey: key as NSString) { return hit }
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
        }
        return result
    }

    private func data(for url: URL) async -> Data? {
        let key = url.absoluteString
        if let hit = compressed.object(forKey: key as NSString) { return hit as Data }
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
        }
        return result
    }

    /// Warm only the first few tracks; all later rows load on demand.
    func prefetch(_ urls: [URL], maxPixel: Int = 160) async {
        // Low-priority prefetch avoids a large burst of downloads when opening a
        // playlist. The actor shares results with visible covers.
        for url in urls.prefix(6) {
            if Task.isCancelled { return }
            _ = await image(for: url, maxPixel: maxPixel)
        }
    }
}
