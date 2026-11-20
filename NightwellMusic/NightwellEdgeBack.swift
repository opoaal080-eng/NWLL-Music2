import SwiftUI

/// Recognize an iOS-style leading-edge Back swipe without drawing a floating
/// arrow or moving the entire scene. Native NavigationStack interactive
/// pops keep their own system behavior.
private struct NightwellLeadingEdgeBack: ViewModifier {
    let enabled: Bool
    let excludedBottom: CGFloat
    let onBack: () -> Void

    @State private var viewWidth: CGFloat = 390
    @State private var viewHeight: CGFloat = 844

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            viewWidth = max(1, proxy.size.width)
                            viewHeight = max(1, proxy.size.height)
                        }
                        .onChange(of: proxy.size) { _, newSize in
                            viewWidth = max(1, newSize.width)
                            viewHeight = max(1, newSize.height)
                        }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onEnded { value in
                        guard enabled,
                              value.startLocation.x <= 28,
                              value.startLocation.y < viewHeight - excludedBottom else { return }

                        let dx = value.translation.width
                        let dy = value.translation.height
                        let projected = value.predictedEndTranslation.width
                        guard dx > 0, dx > abs(dy) * 1.2 else { return }

                        let shouldReturn = dx > min(105, viewWidth * 0.30) ||
                            (dx > 35 && projected > viewWidth * 0.55)
                        guard shouldReturn else { return }

                        // Navigate directly when the user completes the gesture.
                        // Keep the whole scene in place to avoid a black flash.
                        onBack()
                    }
            )
    }
}

extension View {
    /// Reversible left-edge Back without any extra UI affordance.
    /// Do not attach to FullPlayer: horizontal swipes select tracks there.
    func nightwellEdgeBack(enabled: Bool = true,
                           excludedBottom: CGFloat = 0,
                           onBack: @escaping () -> Void) -> some View {
        modifier(NightwellLeadingEdgeBack(enabled: enabled,
                                          excludedBottom: excludedBottom,
                                          onBack: onBack))
    }
}
