import SwiftUI

/// Interactive leading-edge Back for screens that use a custom Nightwell
/// navigation state instead of a UINavigationController push stack.
/// Native NavigationStack pushes retain their normal iOS interactive pop.
private struct NightwellLeadingEdgeBack: ViewModifier {
    let enabled: Bool
    let excludedBottom: CGFloat
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displacement: CGFloat = 0
    @State private var viewWidth: CGFloat = 390
    @State private var viewHeight: CGFloat = 844
    @State private var completing = false

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
            .offset(x: enabled ? displacement : 0)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        guard enabled, !completing,
                              value.startLocation.x <= 28,
                              value.startLocation.y < viewHeight - excludedBottom else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard dx > 0, dx > abs(dy) * 1.2 else { return }
                        withTransaction(Transaction(animation: nil)) {
                            displacement = min(viewWidth * 0.90, dx)
                        }
                    }
                    .onEnded { value in
                        guard enabled, !completing,
                              value.startLocation.x <= 28,
                              value.startLocation.y < viewHeight - excludedBottom else {
                            reset()
                            return
                        }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        let projected = value.predictedEndTranslation.width
                        guard dx > 0, dx > abs(dy) * 1.2 else {
                            reset()
                            return
                        }
                        let shouldReturn = dx > min(105, viewWidth * 0.30) ||
                            (dx > 35 && projected > viewWidth * 0.55)
                        guard shouldReturn else {
                            reset()
                            return
                        }
                        completing = true
                        withAnimation(reduceMotion ? .easeOut(duration: 0.10) :
                                      .interactiveSpring(response: 0.24, dampingFraction: 0.87)) {
                            displacement = min(viewWidth, 430)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.10 : 0.23)) {
                            onBack()
                            withTransaction(Transaction(animation: nil)) { displacement = 0 }
                            completing = false
                        }
                    }
            )
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { reset() }
            }
    }

    private func reset() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.10) :
                      .interactiveSpring(response: 0.31, dampingFraction: 0.85)) {
            displacement = 0
        }
    }
}

extension View {
    /// A reversible iOS-style back swipe starting from the left screen edge.
    /// Never attach to FullPlayer; its horizontal swipes select music instead.
    func nightwellEdgeBack(enabled: Bool = true,
                           excludedBottom: CGFloat = 0,
                           onBack: @escaping () -> Void) -> some View {
        modifier(NightwellLeadingEdgeBack(enabled: enabled,
                                          excludedBottom: excludedBottom,
                                          onBack: onBack))
    }
}
