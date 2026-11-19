import SwiftUI

/// A reversible, finger-tracking page transition for both Nightwell players.
/// A short swipe always snaps back; only a deliberate swipe commits playback.
struct NightwellTrackSwipeCarousel<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    var gap: CGFloat = 12
    let onStep: (Int) -> Void
    let content: (Track?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    @State private var committing = false
    @State private var swipeID = UUID()

    init(clock: PlaybackClock, gap: CGFloat = 12,
         onStep: @escaping (Int) -> Void,
         @ViewBuilder content: @escaping (Track?) -> Content) {
        self.clock = clock
        self.gap = gap
        self.onStep = onStep
        self.content = content
    }

    private var currentIndex: Int? {
        clock.queue.firstIndex(where: { $0.id == clock.displayID })
            ?? clock.queue.firstIndex(where: { $0.id == clock.id })
    }

    private var previous: Track? {
        guard let index = currentIndex, index > 0 else { return nil }
        return clock.queue[index - 1]
    }

    private var following: Track? {
        guard let index = currentIndex, index + 1 < clock.queue.count else { return nil }
        return clock.queue[index + 1]
    }

    var body: some View {
        GeometryReader { viewport in
            let width = max(1, viewport.size.width)
            ZStack {
                if let previous {
                    page(previous, width: width)
                        .offset(x: dragOffset - width - gap)
                        .accessibilityHidden(true)
                }
                page(clock.displayCurrent, width: width)
                    .offset(x: dragOffset)
                if let following {
                    page(following, width: width)
                        .offset(x: dragOffset + width + gap)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
            .contentShape(Rectangle())
            .highPriorityGesture(horizontalSwipe(width: width))
        }
        .onChange(of: clock.displayID) { _ in
            // A remote change, prepared-next handoff or manual button skips
            // any unfinished gesture so the carousel can never get stranded.
            if !committing {
                withTransaction(Transaction(animation: nil)) { dragOffset = 0 }
            }
        }
        .accessibilityHint("Проведи влево или вправо, чтобы выбрать соседний трек")
    }

    private func page(_ track: Track?, width: CGFloat) -> some View {
        content(track)
            .frame(width: width, height: nil)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private func horizontalSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !committing else { return }
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.12 else { return }
                let available = dx < 0 ? following != nil : previous != nil
                // A resisted edge feels natural while avoiding an invalid skip.
                let raw = max(-width - gap, min(width + gap, dx))
                let offset = available ? raw : raw * 0.16
                withTransaction(Transaction(animation: nil)) { dragOffset = offset }
            }
            .onEnded { value in
                guard !committing else { return }
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.12 else {
                    cancelDrag()
                    return
                }
                let direction = dx < 0 ? 1 : -1
                guard direction > 0 ? following != nil : previous != nil else {
                    cancelDrag()
                    return
                }
                let threshold = max(48, width * 0.24)
                let projected = value.predictedEndTranslation.width
                let committed = abs(dx) >= threshold ||
                    (abs(dx) > max(25, width * 0.10) && abs(projected) > width * 0.53 &&
                     (dx < 0) == (projected < 0))
                guard committed else {
                    cancelDrag()
                    return
                }
                committing = true
                let token = UUID()
                swipeID = token
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) :
                              .interactiveSpring(response: 0.25, dampingFraction: 0.90)) {
                    dragOffset = CGFloat(-direction) * (width + gap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.13 : 0.24)) {
                    guard token == swipeID else { return }
                    // Commit the audio change only after the visual card reaches
                    // its target. Releasing early never touches the player.
                    onStep(direction)
                    withTransaction(Transaction(animation: nil)) { dragOffset = 0 }
                    committing = false
                }
            }
    }

    private func cancelDrag() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.10) :
                      .interactiveSpring(response: 0.30, dampingFraction: 0.80)) {
            dragOffset = 0
        }
    }
}
