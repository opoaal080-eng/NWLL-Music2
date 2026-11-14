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
    private var requestedTrackKey = ""
    private static let cacheKey = "nw-last-artwork-palette-v1"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode(NightwellArtworkColors.self, from: $0) }
        let initial = stored ?? .fallback
        colors = initial
        previous = initial
    }

    func at(_ time: TimeInterval) -> NightwellArtworkColors {
        guard transitionBegan > 0 else { return colors }
        let progress = max(0, min(1, (time - transitionBegan) / 1.25))
        let eased = progress * progress * (3 - 2 * progress)
        return previous.mixed(with: colors, fraction: eased)
    }

    func refresh(track: Track?, origin: URL) async {
        guard let track else { return } // Keep last palette with no active track.
        let key = origin.absoluteString + "|" + track.id
        guard key != requestedTrackKey else { return }
        requestedTrackKey = key
        guard let url = CoverImagePipeline.coverURL(for: track, origin: origin) else {
            requestedTrackKey = ""
            return
        }
        // A transient CDN failure must not permanently lock this track to
        // the previous palette. Retry only the currently selected artwork.
        for attempt in 0..<3 {
            let artwork = await CoverImagePipeline.shared.image(
                for: url, maxPixel: 192, retryFailure: attempt > 0)
            guard !Task.isCancelled, requestedTrackKey == key else { return }
            if let artwork {
                // Decode and sample cover pixels off the main actor.
                // Track changes must not block gestures or the player controls.
                let palette: NightwellArtworkColors
                if let cgImage = artwork.cgImage {
                    palette = await Task.detached(priority: .utility) {
                        Self.extract(from: cgImage) ?? .fallback
                    }.value
                } else {
                    palette = .fallback
                }
                guard !Task.isCancelled, requestedTrackKey == key else { return }
                let now = ProcessInfo.processInfo.systemUptime
                previous = at(now)
                transitionBegan = now
                colors = palette
                if let data = try? JSONEncoder().encode(palette) {
                    UserDefaults.standard.set(data, forKey: Self.cacheKey)
                }
                return
            }
            if attempt < 2 {
                do { try await Task.sleep(nanoseconds: attempt == 0 ? 1_750_000_000 : 3_500_000_000) }
                catch { return }
            }
        }
        if requestedTrackKey == key { requestedTrackKey = "" }
    }

    // A 72x72 thumbnail keeps subtle cover hues without decoding full-size art.
    // Group similar hues instead of choosing the single brightest pixel or logo.
    nonisolated private static func extract(from cgImage: CGImage) -> NightwellArtworkColors? {
        let side = 72
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let valid = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard valid else { return nil }

        struct Bucket {
            var weight = 0.0
            var r = 0.0
            var g = 0.0
            var b = 0.0

            mutating func add(r: Double, g: Double, b: Double, weight: Double) {
                self.weight += weight
                self.r += r * weight
                self.g += g * weight
                self.b += b * weight
            }
            mutating func merge(_ other: Bucket, multiplier: Double) {
                weight += other.weight * multiplier
                r += other.r * multiplier
                g += other.g * multiplier
                b += other.b * multiplier
            }
            var average: NightwellRGB {
                let total = max(weight, 0.00001)
                return .init(r: r / total, g: g / total, b: b / total)
            }
        }

        let bucketCount = 48
        var bins = [Bucket](repeating: Bucket(), count: bucketCount)
        var neutral = Bucket()

        for pixel in 0..<(side * side) {
            let k = pixel * 4
            let alpha = Double(pixels[k + 3]) / 255
            guard alpha > 0.70 else { continue }
            let r = Double(pixels[k]) / 255
            let g = Double(pixels[k + 1]) / 255
            let b = Double(pixels[k + 2]) / 255
            let high = max(r, max(g, b))
            let low = min(r, min(g, b))
            let chroma = high - low
            let saturation = high > 0 ? chroma / high : 0

            let dx = (Double(pixel % side) + 0.5) / Double(side) - 0.5
            let dy = (Double(pixel / side) + 0.5) / Double(side) - 0.5
            let centrality = 1.12 - 0.16 * min(1, hypot(dx, dy) / 0.7072)
            // Fallback for monochrome, dark and pastel covers must use their
            // actual RGB values, not an unrelated default purple palette.
            neutral.add(r: r, g: g, b: b, weight: centrality * (high > 0.06 && high < 0.96 ? 1 : 0.3))

            // Exclude logos, white type and black borders from colourful clusters.
            guard saturation > 0.13, high > 0.11, high < 0.96, chroma > 0.045 else { continue }
            var hue: Double
            if high == r { hue = (g - b) / chroma }
            else if high == g { hue = (b - r) / chroma + 2 }
            else { hue = (r - g) / chroma + 4 }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let index = min(bucketCount - 1, Int(hue * Double(bucketCount)))

            // Favour large coherent colour regions over tiny saturated highlights.
            // The original hue and RGB proportions are preserved.
            let brightnessBalance = 0.68 + 0.32 * (1 - abs(high - 0.58))
            let weight = centrality * (0.72 + 0.55 * saturation) * brightnessBalance
            bins[index].add(r: r, g: g, b: b, weight: weight)
        }
        guard neutral.weight > 0 else { return nil }

        func usableColor(_ value: NightwellRGB) -> NightwellRGB {
            let peak = max(value.r, max(value.g, value.b))
            if peak < 0.0001 { return .init(r: 0.16, g: 0.16, b: 0.16) }
            // Adjust only brightness uniformly. No fabricated shift in hue.
            let target = min(0.86, max(0.25, peak))
            let factor = target / peak
            return .init(r: min(1, value.r * factor),
                         g: min(1, value.g * factor),
                         b: min(1, value.b * factor))
        }

        func combined(_ index: Int) -> Bucket {
            var result = Bucket()
            for shift in -1...1 {
                let neighbor = (index + shift + bucketCount) % bucketCount
                result.merge(bins[neighbor], multiplier: shift == 0 ? 1 : 0.82)
            }
            return result
        }
        let clusters = (0..<bucketCount)
            .map { (index: $0, value: combined($0)) }
            .sorted { $0.value.weight > $1.value.weight }

        guard let best = clusters.first, best.value.weight > 0 else {
            let primary = usableColor(neutral.average)
            return .init(primary: primary,
                         secondary: .init(r: primary.r * 0.68,
                                          g: primary.g * 0.68,
                                          b: primary.b * 0.68))
        }

        let primary = usableColor(best.value.average)
        let alternate = clusters.first { candidate in
            let distance = min(abs(candidate.index - best.index),
                               bucketCount - abs(candidate.index - best.index))
            return distance >= 5 && candidate.value.weight >= best.value.weight * 0.16
        }
        let secondary: NightwellRGB
        if let alternate {
            secondary = usableColor(alternate.value.average)
        } else {
            // Single-colour artwork should remain single-hue rather than
            // generating an unrelated blue or purple second colour.
            secondary = .init(r: primary.r * 0.66,
                              g: primary.g * 0.66,
                              b: primary.b * 0.66)
        }
        return .init(primary: primary, secondary: secondary)
    }
}
