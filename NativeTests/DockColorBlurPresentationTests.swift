#if DEBUG
import XCTest
import SwiftUI
import UIKit
import Metal
@testable import NightwellMusic

private struct DockColorBlurFixture: View {
    private var stripes: some View {
        Canvas { context, _ in
            for index in 0..<4 {
                let color = index.isMultiple(of: 2)
                    ? Color(.sRGB, red: 1, green: 0, blue: 0)
                    : Color(.sRGB, red: 0, green: 0, blue: 1)
                context.fill(
                    Path(CGRect(x: CGFloat(index) * 40, y: 0, width: 40, height: 256)),
                    with: .color(color.opacity(0.6))
                )
            }
        }
        .frame(width: 160, height: 256)
    }

    var body: some View {
        HStack(spacing: 0) {
            stripes
            stripes.nightwellDockColorBlur()
        }
        // The 40pt offset catches confusing the leaf's local Y with global Y.
        .padding(.top, 40)
        .frame(width: 320, height: 320, alignment: .topLeading)
        .environment(\.nightwellDockBlurRegion,
                     CGRect(x: 0, y: 120, width: 320, height: 200))
        .ignoresSafeArea()
    }
}

@MainActor final class DockColorBlurPresentationTests: XCTestCase {
    private struct Pixel {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> Pixel {
        let image = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let alpha = Double(bytes[3]) / 255
        let divisor = max(Double(bytes[3]), 1)
        return Pixel(red: Double(bytes[0]) / divisor,
                     green: Double(bytes[1]) / divisor,
                     blue: Double(bytes[2]) / divisor,
                     alpha: alpha)
    }

    private func render(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    func testDockBlursOriginalChromaOnlyBelowItsGlobalBoundary() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("This presentation test needs a Metal-capable iOS renderer")
        }
        let hosting = UIHostingController(rootView: DockColorBlurFixture())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        window.backgroundColor = .clear
        window.rootViewController = hosting
        hosting.view.backgroundColor = .clear
        hosting.view.isOpaque = false
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        // Capture the displayed SwiftUI/Metal effect, rather than recreating
        // its math on the CPU. Allow the first Metal pipeline to finish; a
        // missing or broken shader still fails the assertions after 2 seconds.
        let deadline = Date().addingTimeInterval(2)
        var image = render(hosting.view)
        while try (pixel(image, x: 76, y: 224).alpha < 0.5 ||
                   pixel(image, x: 236, y: 224).red < 0.15) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            hosting.view.layoutIfNeeded()
            image = render(hosting.view)
        }

        let reference = try pixel(image, x: 76, y: 224)
        XCTAssertEqual(reference.blue, 1, accuracy: 0.03)
        XCTAssertEqual(reference.alpha, 0.6, accuracy: 0.03)

        let above = try pixel(image, x: 236, y: 112)
        XCTAssertEqual(above.red, reference.red, accuracy: 0.02)
        XCTAssertEqual(above.green, reference.green, accuracy: 0.02)
        XCTAssertEqual(above.blue, reference.blue, accuracy: 0.02)
        XCTAssertEqual(above.alpha, reference.alpha, accuracy: 0.02)

        let beforeSeam = try pixel(image, x: 236, y: 119)
        let afterSeam = try pixel(image, x: 236, y: 120)
        XCTAssertEqual(beforeSeam.red, afterSeam.red, accuracy: 0.02)
        XCTAssertEqual(beforeSeam.blue, afterSeam.blue, accuracy: 0.02)

        // This is halfway through the *global* transition. Omitting the
        // fixture's 40pt global origin would leave this pixel unblurred.
        let transition = try pixel(image, x: 236, y: 152)
        XCTAssertGreaterThan(transition.red, reference.red + 0.08)

        let blurred = try pixel(image, x: 236, y: 224)
        XCTAssertGreaterThan(blurred.red, reference.red + 0.15)
        XCTAssertGreaterThan(blurred.blue, 0.3)
        XCTAssertLessThan(blurred.green, 0.03, "Blur must not add a gray or white wash")
        XCTAssertGreaterThan(max(blurred.red, blurred.blue), 0.5)
        // Both samples are farther than the 24pt kernel from leaf edges.
        XCTAssertEqual(blurred.alpha, reference.alpha, accuracy: 0.02)
    }
}
#endif
