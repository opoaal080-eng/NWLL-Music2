import SwiftUI
import UIKit
import CoreGraphics

/// Transparent fronds cut from the actual bundled Vice Nights image.
/// Created once and downsampled to keep scrolling and playback responsive.
private enum NightwellPalmFoliage {
    static let images: [UIImage] = {
        guard let original = UIImage(named: "ViceSunset")?.cgImage else { return [] }
        let width = min(520, original.width)
        let height = max(1, Int((Double(original.height) * Double(width) / Double(original.width)).rounded()))
        let stride = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let rendered: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: stride,
                                          space: colorSpace, bitmapInfo: info) else { return false }
            context.interpolationQuality = .high
            context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        return (0..<3).compactMap { section -> UIImage? in
            var data = [UInt8](repeating: 0, count: pixels.count)
            for y in 0..<height {
                let ny = Double(y) / Double(height)
                for x in 0..<width {
                    let nx = Double(x) / Double(width)
                    let region = nx < 0.55 ? 0 : (ny < 0.56 ? 1 : 2)
                    if region != section { continue }
                    let i = (y * width + x) * 4
                    let red = Double(pixels[i]), green = Double(pixels[i + 1]), blue = Double(pixels[i + 2])
                    // Sunset sky is luminous, silhouetted foliage is dark blue-violet.
                    let amount = min(1, max(0, (70 - red) / 25))
                        * min(1, max(0, (48 - green) / 18))
                        * min(1, max(0, (100 - blue) / 28))
                    let opacity = Int((225 * amount).rounded())
                    if opacity == 0 { continue }
                    data[i] = UInt8(Int(pixels[i]) * opacity / 255)
                    data[i + 1] = UInt8(Int(pixels[i + 1]) * opacity / 255)
                    data[i + 2] = UInt8(Int(pixels[i + 2]) * opacity / 255)
                    data[i + 3] = UInt8(opacity)
                }
            }
            let output: CGImage? = data.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: stride,
                                              space: colorSpace, bitmapInfo: info) else { return nil }
                return context.makeImage()
            }
            return output.map { UIImage(cgImage: $0) }
        }
    }()
}

/// Sub-degree swaying of three independently moving groups of palm leaves.
/// The sky image remains fixed, the full player retains its cover-colour ambient.
struct NightwellPalmSwayBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            if !reduceMotion && !NightwellPalmFoliage.images.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                        paused: scenePhase != .active)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<NightwellPalmFoliage.images.count, id: \.self) { index in
                            let periods = [5.9, 6.7, 7.9]
                            let amplitudes = [0.75, -0.85, 0.65]
                            let anchors = [UnitPoint(x: 0, y: 0.42),
                                           UnitPoint(x: 1, y: 0.20),
                                           UnitPoint(x: 1, y: 0.90)]
                            let phase = seconds * 2 * Double.pi / periods[index] + Double(index) * 1.7
                            Image(uiImage: NightwellPalmFoliage.images[index])
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .rotationEffect(.degrees(sin(phase) * amplitudes[index]),
                                                anchor: anchors[index])
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
