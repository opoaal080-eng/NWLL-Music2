import Foundation
import UIKit

// Bounded handoff from every real Cover view to Now Playing. A row can
// finish loading long before the listener selects it.
enum DisplayedSystemArtwork {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    static func key(origin: URL, id: String, cover: String?) -> String {
        let raw = cover?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = URL(string: raw, relativeTo: origin)?.absoluteURL.absoluteString ?? raw
        // Hash data URLs too, rather than retaining a large base64 key.
        return root + "|" + id + "|" + String(normalized.hashValue)
    }
    static func matches(origin: URL, id: String, first: String?, second: String?) -> Bool {
        let a = first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let b = second?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return a.isEmpty || b.isEmpty || key(origin: origin, id: id, cover: a) == key(origin: origin, id: id, cover: b)
    }
    static func image(origin: URL, id: String, cover: String?) -> UIImage? {
        images.object(forKey: key(origin: origin, id: id, cover: cover) as NSString)
    }
    static func store(_ image: UIImage, origin: URL, id: String, cover: String?) {
        guard !id.isEmpty, let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return }
        let k = key(origin: origin, id: id, cover: cover) as NSString
        if let old = images.object(forKey: k)?.cgImage,
           max(old.width, old.height) >= max(cg.width, cg.height) { return }
        images.setObject(image, forKey: k, cost: cg.bytesPerRow * cg.height)
    }
}

// Rasterize with correct UIImage orientation, bounded dimensions and
// an ordinary RGB pixel format accepted by both system player APIs.
enum SystemArtworkEncoding {
    static func raster(_ image: UIImage, maxPixel: CGFloat = 512) -> UIImage? {
        let width = image.size.width, height = image.size.height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              maxPixel.isFinite, maxPixel > 0 else { return nil }
        let scale = min(maxPixel / max(width, height), max(1, image.scale))
        let size = CGSize(width: max(1, (width * scale).rounded()),
                          height: max(1, (height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    static func data(_ image: UIImage) -> Data? {
        if let normalized = raster(image) {
            if let bytes = normalized.jpegData(compressionQuality: 0.88), !bytes.isEmpty { return bytes }
            if let bytes = normalized.pngData(), !bytes.isEmpty { return bytes }
        }
        return nil
    }
}
