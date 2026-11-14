import SwiftUI

enum NavigationDockAppearance {
    // A sampled smootherstep keeps both ends of the fade flat, so the blurred
    // surface appears gradually without a visible change in slope at its edge.
    static let blurFade = Gradient(stops: (0...16).map { step in
        let t = Double(step) / 16
        let opacity = t * t * t * (t * (t * 6 - 15) + 10)
        return Gradient.Stop(color: .white.opacity(opacity), location: CGFloat(t * 0.5))
    } + [Gradient.Stop(color: .white, location: 1)])
}

private struct NightwellBottomContentInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Extra scrollable space at the end, while the viewport extends behind
    /// the floating player and navigation. Modal screens retain a zero inset.
    var nightwellBottomContentInset: CGFloat {
        get { self[NightwellBottomContentInsetKey.self] }
        set { self[NightwellBottomContentInsetKey.self] = newValue }
    }
}
