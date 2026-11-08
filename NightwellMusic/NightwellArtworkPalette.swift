import Foundation
import SwiftUI
import UIKit
import CoreGraphics

// A small color model avoids publishing full cover images on every player tick.
struct NightwellRGB: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color {
        Color(red: max(0, min(1, r)), green: max(0, min(1, g)), blue: max(0, min(1, b)))
    }
    func mixed(with other: NightwellRGB, fraction t: Double) -> NightwellRGB {
        let a = max(0, min(1, t))
        return NightwellRGB(r: r + (other.r - r) * a,
                            g: g + (other.g - g) * a,
                            b: b + (other.b - b) * a)
    }
}
struct NightwellArtworkColors: Codable, Equatable {
    var primary: NightwellRGB
    var secondary: NightwellRGB
    static let fallback = NightwellArtworkColors(
        primary: .init(r: 0.48, g: 0.24, b: 0.53),
        secondary: .init(r: 0.19, g: 0.38, b: 0.54)
    )
    func mixed(with other: NightwellArtworkColors, fraction: Double) -> NightwellArtworkColors {
        .init(primary: primary.mixed(with: other.primary, fraction: fraction),
              secondary: secondary.mixed(with: other.secondary, fraction: fraction))
    }
}

@MainActor
final class NightwellArtworkPalette: ObservableObject {
    @Published private(set) var colors: NightwellArtworkColors
    private var previous: NightwellArtworkColors
    private var transitionBegan: TimeInterval = 0
    private var requestedTrackID = ""
    private static let cacheKey = "nw-last-artwork-palette-v1"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode(NightwellArtworkColors.self, from: $0) }
        colors = stored ?? .fallback
        previous = colors
    }

    func at(_ time: TimeInterval) -> NightwellArtworkColors {
        guard transitionBegan > 0 else { return colors }
        let progress = max(0, min(1, (time - transitionBegan) / 1.25))
        let eased = progress * progress * (3 - 2 * progress)
        return previous.mixed(with: colors, fraction: eased)
    }

    func refresh(track: Track?, origin: URL) async {
        guard let track else { return } // Retain the last cover while no song is selected.
        guard track.id != requestedTrackID else { return }
        requestedTrackID = track.id
        guard let url = CoverImagePipeline.coverURL(for: track, origin: origin) else { return }
        guard let artwork = await CoverImagePipeline.shared.image(for: url, maxPixel: 128),
              !Task.isCancelled, requestedTrackID == track.id else { return }
        let palette = Self.extract(from: artwork) ?? .fallback
        guard !Task.isCancelled, requestedTrackID == track.id else { return }
        let now = ProcessInfo.processInfo.systemUptime
        previous = at(now)
        transitionBegan = now
        colors = palette
        if let data = try? JSONEncoder().encode(palette) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    // Read a 32x32 thumbnail, not the full-resolution artwork.
    private static func extract(from image: UIImage) -> NightwellArtworkColors? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let valid: Bool = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard valid else { return nil }

        struct Bucket {
            var score = 0.0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }
        var bins = [Bucket](repeating: Bucket(), count: 24)
        for i in 0..<(side * side) {
            let k = i * 4
            let a = Double(pixels[k + 3]) / 255.0
            guard a > 0.7 else { continue }
            let r = Double(pixels[k]) / 255.0
            let g = Double(pixels[k + 1]) / 255.0
            let b = Double(pixels[k + 2]) / 255.0
            let top = max(r, max(g, b)), low = min(r, min(g, b))
            let delta = top - low
            guard top > 0.15, top < 0.98, delta > 0.10 else { continue }
            let saturation = delta / max(top, 0.001)
            guard saturation > 0.18 else { continue }
            var hue: Double
            if top == r { hue = (g - b) / delta }
            else if top == g { hue = 2 + (b - r) / delta }
            else { hue = 4 + (r - g) / delta }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let index = min(23, max(0, Int(hue * 24)))
            let weight = (0.35 + saturation * 1.7) * (0.55 + top * 0.45)
            bins[index].score += weight
            bins[index].red += r * weight
            bins[index].green += g * weight
            bins[index].blue += b * weight
        }
        let ranked = bins.indices.sorted { bins[$0].score > bins[$1].score }
        guard let first = ranked.first, bins[first].score > 0 else { return nil }
        func color(_ i: Int) -> NightwellRGB {
            let bin = bins[i], norm = max(0.0001, bin.score)
            let red = bin.red / norm, green = bin.green / norm, blue = bin.blue / norm
            // Keep artwork hue but give low-saturation covers some visible depth.
            let peak = max(red, max(green, blue))
            let boost = min(1.18, 0.92 / max(0.3, peak))
            return .init(r: min(1, red * boost), g: min(1, green * boost), b: min(1, blue * boost))
        }
        let second = ranked.first {
            let distance = min(abs($0 - first), 24 - abs($0 - first))
            return distance >= 2 && bins[$0].score >= bins[first].score * 0.055
        } ?? first
        let primary = color(first)
        let secondary = second == first
            ? NightwellRGB(r: min(1, primary.r * 0.64 + 0.14),
                           g: min(1, primary.g * 0.69 + 0.11),
                           b: min(1, primary.b * 0.77 + 0.11))
            : color(second)
        return NightwellArtworkColors(primary: primary, secondary: secondary)
    }
}
