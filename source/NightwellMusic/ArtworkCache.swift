import Foundation
import UIKit

/// One bounded memory/disk cache for artwork used throughout the native UI.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private let images = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        images.totalCostLimit = 36 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 24 * 1024 * 1024,
                                   diskCapacity: 140 * 1024 * 1024,
                                   diskPath: "nightwell-artwork-v1")
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpCookieStorage = .shared
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config)
    }

    func image(_ url: URL) async -> UIImage? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let key = url.absoluteString
        if let cached = images.object(forKey: key as NSString) { return cached }
        if let pending = inFlight[key] { return await pending.value }
        let task = Task { [session] () -> UIImage? in
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            do {
                let (data, response) = try await session.data(for: request)
                guard data.count > 0, data.count <= 5 * 1024 * 1024,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      (http.mimeType ?? "").lowercased().hasPrefix("image/") else { return nil }
                return UIImage(data: data)
            } catch { return nil }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            let cost = min(8 * 1024 * 1024, Int(result.size.width * result.size.height * 4))
            images.setObject(result, forKey: key as NSString, cost: max(1, cost))
        }
        return result
    }

    func prefetch(_ urls: [URL]) async {
        for url in urls.prefix(3) {
            if Task.isCancelled { return }
            _ = await image(url)
        }
    }
}
