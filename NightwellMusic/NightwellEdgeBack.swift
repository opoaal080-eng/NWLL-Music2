import SwiftUI

/// Interactive leading-edge Back for screens that use custom Nightwell
/// navigation instead of a UINavigationController push stack.
/// Keep the presented surface anchored: moving the entire app/sheet offscreen
/// used to expose the black host background before the previous view appeared.
/// Native NavigationStack pushes retain their normal iOS interactive pop.
private struct NightwellLeadingEdgeBack: ViewModifier {
    let enabled: Bool
    let excludedBottom: CGFloat
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displacement: CGFloat = 0
    @State private var viewWidth: CGFloat = 390
    @State private var viewHeight: CGFloat = 844

    private var progress: CGFloat {
        min(1, displacement / max(1, viewWidth * 0.28))
    }

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
            .overlay(alignment: .leading) {
                // Only the small affordance follows the finger. The actual
                // screen and its background never move, so there is no exposed
                // black frame before the destination is mounted.
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(Double(0.55 + progress * 0.45)))
                    .frame(width: 32, height: 58)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(x: -38 + min(38, displacement * 0.36))
                    .opacity(enabled ? Double(min(1, displacement / 36)) : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        guard enabled,
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
                        guard enabled,
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

                        // Do not finish an offscreen animation and then wait
                        // before navigating. Commit directly on release so the
                        // outgoing and incoming views can transition together.
                        withTransaction(Transaction(animation: nil)) {
                            displacement = 0
                        }
                        onBack()
                    }
            )
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled {
                    withTransaction(Transaction(animation: nil)) { displacement = 0 }
                }
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
