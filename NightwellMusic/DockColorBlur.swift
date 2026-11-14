import SwiftUI

private struct NightwellDockBlurRegionKey: EnvironmentKey {
    static let defaultValue = CGRect.null
}

extension EnvironmentValues {
    /// Global coordinates of the dock's source-blur region, including its top
    /// transition and the bottom safe area. A null region disables the effect.
    var nightwellDockBlurRegion: CGRect {
        get { self[NightwellDockBlurRegionKey.self] }
        set { self[NightwellDockBlurRegionKey.self] = newValue }
    }
}

private struct NightwellDockColorBlur: ViewModifier {
    @Environment(\.nightwellDockBlurRegion) private var region

    private static let radius: CGFloat = 24
    private static let fadeHeight: CGFloat = 64

    func body(content: Content) -> some View {
        let blurRegion = region
        let radius = Self.radius
        let fadeHeight = Self.fadeHeight
        return content.visualEffect { effect, geometry in
            let frame = geometry.frame(in: .global)
            let validFrame = !frame.isNull && !frame.isEmpty &&
                frame.minX.isFinite && frame.minY.isFinite &&
                frame.maxX.isFinite && frame.maxY.isFinite
            let validRegion = !blurRegion.isNull && !blurRegion.isEmpty &&
                blurRegion.minX.isFinite && blurRegion.minY.isFinite &&
                blurRegion.maxX.isFinite && blurRegion.maxY.isFinite
            let enabled = validFrame && validRegion && frame.intersects(blurRegion)

            return effect.layerEffect(
                ShaderLibrary.nightwellDockColorBlur(
                    .float2(Float(validFrame ? frame.minX : 0), Float(validFrame ? frame.minY : 0)),
                    .float(Float(enabled ? blurRegion.minY : 0)),
                    .float(Float(fadeHeight)),
                    .float(Float(radius))
                ),
                maxSampleOffset: CGSize(width: radius, height: radius),
                isEnabled: enabled
            )
        }
    }
}

extension View {
    /// Blur the original SwiftUI pixels as they move under the player dock.
    /// Apply to SwiftUI leaves, never an ancestor of a UIViewRepresentable.
    func nightwellDockColorBlur() -> some View {
        modifier(NightwellDockColorBlur())
    }
}
