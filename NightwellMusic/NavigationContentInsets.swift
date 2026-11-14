import SwiftUI

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
