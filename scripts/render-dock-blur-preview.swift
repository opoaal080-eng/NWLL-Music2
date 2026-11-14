import AppKit
import SwiftUI

private struct DockBlurPreview: View {
    let enabled: Bool

    var body: some View {
        Canvas { context, _ in
            for stripe in 0..<4 {
                let color = stripe.isMultiple(of: 2)
                    ? Color(.sRGB, red: 1, green: 0, blue: 0)
                    : Color(.sRGB, red: 0, green: 0, blue: 1)
                context.fill(
                    Path(CGRect(x: CGFloat(stripe) * 80, y: 0, width: 80, height: 512)),
                    with: .color(color.opacity(0.72))
                )
            }
        }
        .frame(width: 320, height: 512)
        .nightwellDockColorBlur()
        .environment(\.nightwellDockBlurRegion,
                     enabled ? CGRect(x: 0, y: 192, width: 320, height: 320) : .null)
    }
}

private struct PreviewFailure: Error, CustomStringConvertible {
    let description: String
}

private struct PreviewPixel {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var log: String {
        String(format: "RGBA=(%.4f, %.4f, %.4f, %.4f)", red, green, blue, alpha)
    }
}

@main @MainActor
private struct RenderDockBlurPreview {
    private static func require(_ passes: Bool, _ message: String) throws {
        if !passes { throw PreviewFailure(description: message) }
    }

    private static func render(enabled: Bool) throws -> CGImage {
        let renderer = ImageRenderer(content: DockBlurPreview(enabled: enabled))
        renderer.scale = 1
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: 320, height: 512)
        guard let image = renderer.nsImage,
              let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PreviewFailure(description: "ImageRenderer did not produce a CGImage")
        }
        try require(raster.width == 320 && raster.height == 512,
                    "Unexpected ImageRenderer pixel dimensions: \(raster.width)x\(raster.height)")
        return raster
    }

    private static func sample(_ image: CGImage, x: Int, y: Int) throws -> PreviewPixel {
        guard let crop = image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PreviewFailure(description: "Cannot sample pixel (\(x),\(y))")
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ) else { throw PreviewFailure(description: "Cannot create sRGB sample context") }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let divisor = max(Double(bytes[3]), 1)
        return PreviewPixel(red: Double(bytes[0]) / divisor,
                            green: Double(bytes[1]) / divisor,
                            blue: Double(bytes[2]) / divisor,
                            alpha: Double(bytes[3]) / 255)
    }

    private static func save(_ image: CGImage, to url: URL) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PreviewFailure(description: "Cannot encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
        print("Wrote \(url.path)")
    }

    private static func compare(_ a: PreviewPixel, _ b: PreviewPixel) -> Bool {
        abs(a.red - b.red) < 0.035 && abs(a.green - b.green) < 0.035 &&
            abs(a.blue - b.blue) < 0.035 && abs(a.alpha - b.alpha) < 0.025
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw PreviewFailure(description: "Usage: render-dock-blur-preview OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = try render(enabled: false)
        let candidate = try render(enabled: true)
        // Always retain both images so a failing GPU render remains reviewable.
        try save(source, to: output.appendingPathComponent("source.png"))
        try save(candidate, to: output.appendingPathComponent("candidate.png"))

        let reference = try sample(source, x: 76, y: 352)
        let above = try sample(candidate, x: 76, y: 144)
        let seamBefore = try sample(candidate, x: 76, y: 191)
        let seamAfter = try sample(candidate, x: 76, y: 192)
        let earlyFade = try sample(candidate, x: 76, y: 196)
        let transition = try sample(candidate, x: 76, y: 224)
        let blurred = try sample(candidate, x: 76, y: 352)
        let fartherTransition = try sample(candidate, x: 72, y: 224)
        let fartherBlur = try sample(candidate, x: 72, y: 352)
        let flatRed = try sample(candidate, x: 40, y: 352)
        let flatBlue = try sample(candidate, x: 280, y: 352)
        for (name, pixel) in [("source boundary", reference), ("above dock", above),
                              ("before seam", seamBefore), ("after seam", seamAfter),
                              ("early fade", earlyFade),
                              ("transition", transition), ("full blur", blurred),
                              ("farther transition", fartherTransition),
                              ("farther full blur", fartherBlur),
                              ("flat red", flatRed), ("flat blue", flatBlue)] {
            print("\(name): \(pixel.log)")
        }

        try require(reference.red > 0.95 && reference.blue < 0.03 &&
                    abs(reference.alpha - 0.72) < 0.025, "Invalid source fixture")
        try require(compare(above, reference), "The shader modified pixels above the dock")
        try require(compare(seamBefore, seamAfter), "Visible discontinuity at the dock seam")
        try require(compare(earlyFade, reference) &&
                    fartherBlur.blue > fartherTransition.blue + 0.08,
                    "Blur must enter gradually rather than switch to full strength at the seam")
        try require(transition.blue > reference.blue + 0.08 &&
                    blurred.blue > reference.blue + 0.15 && blurred.red > 0.35,
                    "Actual shader blur is missing. ImageRenderer may not support layerEffect, " +
                    "or default.metallib was not loaded; an unchanged/placeholder render is a failure.")
        try require(blurred.green < 0.03 && abs(blurred.alpha - reference.alpha) < 0.025,
                    "Blur added a gray wash or changed interior alpha")
        try require(compare(flatRed, try sample(source, x: 40, y: 352)) &&
                    compare(flatBlue, try sample(source, x: 280, y: 352)),
                    "Blur changed flat saturated colors or their alpha")
        print("PASS: actual shader mixes the colored boundary, preserves the seam, chroma, and alpha.")
    }
}
