import Foundation
import UIKit

/// Legacy callers share the same downloader as track rows and the native player.
/// Keeping a second URLSession used to duplicate transfers and decoding.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private init() {}

    func image(_ url: URL) async -> UIImage? {
        await CoverImagePipeline.shared.image(for: url, maxPixel: 512)
    }

    func prefetch(_ urls: [URL]) async {
        await CoverImagePipeline.shared.prefetch(Array(urls.prefix(3)), maxPixel: 512)
    }
}
