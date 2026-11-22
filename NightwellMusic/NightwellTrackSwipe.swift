import SwiftUI

/// A reversible, finger-tracking page transition for both Nightwell players.
/// A short swipe always snaps back; only a deliberate swipe commits playback.
struct NightwellTrackSwipeCarousel<Content: View>: View {
    let clock: PlaybackClock
    @ObservedObject private var presentation: PlaybackPresentation
    var gap: CGFloat = 12
    let onStep: (Int) -> Void
    let content: (Track?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    @State private var committing = false
    @State private var swipeID = UUID()
    @State private var interaction = TrackSwipeInteraction()
    @State private var gestureID = UUID()
    @State private var ignoreCurrentTouch = false
    @GestureState private var fingerDown = false

    init(clock: PlaybackClock, gap: CGFloat = 12,
         onStep: @escaping (Int) -> Void,
         @ViewBuilder content: @escaping (Track?) -> Content) {
        self.clock = clock
        _presentation = ObservedObject(wrappedValue: clock.presentation)
        self.gap = gap
        self.onStep = onStep
        self.content = content
    }

    private var previous: Track? {
        guard let index = clock.displayIndex, index > 0 else { return nil }
        return clock.queue[index - 1]
    }

    private var following: Track? {
        guard let index = clock.displayIndex, index + 1 < clock.queue.count else { return nil }
        return clock.queue[index + 1]
    }

    var body: some View {
        GeometryReader { viewport in
            let width = max(1, viewport.size.width)
            ZStack {
                if let previous {
                    page(previous, width: width)
                        .offset(x: dragOffset - width - gap)
                        .opacity(dragOffset > 0 ? enteringCoverOpacity(width: width) : 0)
                        .accessibilityHidden(true)
                }
                page(clock.displayCurrent, width: width)
                    .offset(x: dragOffset)
                if let following {
                    page(following, width: width)
                        .offset(x: dragOffset + width + gap)
                        .opacity(dragOffset < 0 ? enteringCoverOpacity(width: width) : 0)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
            // The incoming cover dissolves in at the viewport edge instead of
            // being sliced by the rectangular clipping boundary.
            .mask(featheredViewportMask(width: width))
            .contentShape(Rectangle())
            .highPriorityGesture(horizontalSwipe(width: width))
        }
        .onChange(of: clock.displayID) { _ in
            // A remote change, prepared-next handoff or manual button skips
            // any unfinished gesture so the carousel can never get stranded.
            if !committing {
                ignoreCurrentTouch = fingerDown
                interaction.reset()
                moveWithoutAnimation(to: 0)
            }
        }
        .onChange(of: fingerDown) { _, down in
            guard !down else { return }
            let finishedGesture = gestureID
            DispatchQueue.main.async {
                guard !fingerDown, gestureID == finishedGesture else { return }
                ignoreCurrentTouch = false
                guard !committing, interaction.isTracking else { return }
                interaction.reset()
                cancelDrag()
            }
        }
        .onDisappear {
            guard !committing else { return }
            interaction.reset()
            ignoreCurrentTouch = false
            moveWithoutAnimation(to: 0)
        }
        .accessibilityHint("Проведи влево или вправо, чтобы выбрать соседний трек")
    }

    private func enteringCoverOpacity(width: CGFloat) -> Double {
        // The finger controls both translation and reveal, including reversal.
        // An entering cover is already fully visible before it reaches centre.
        min(1, Double(abs(dragOffset) / max(1, width * 0.27)))
    }

    private func featheredViewportMask(width: CGFloat) -> some View {
        // At rest the active cover stays completely opaque. Feathering only
        // grows while dragging, keeping artwork crisp between gestures.
        let reveal = min(1, Double(abs(dragOffset) / max(1, width * 0.22)))
        let edgeOpacity = 1 - reveal
        return LinearGradient(stops: [
            .init(color: .white.opacity(edgeOpacity), location: 0),
            .init(color: .white, location: 0.075),
            .init(color: .white, location: 0.925),
            .init(color: .white.opacity(edgeOpacity), location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    private func page(_ track: Track?, width: CGFloat) -> some View {
        content(track)
            .frame(width: width, height: nil)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private func horizontalSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($fingerDown) { _, down, _ in down = true }
            .onChanged { value in
                guard !committing, !ignoreCurrentTouch else { return }
                let wasTracking = interaction.isTracking
                guard let offset = interaction.update(
                    translationX: Double(value.translation.width),
                    translationY: Double(value.translation.height),
                    width: Double(width), gap: Double(gap),
                    canPrevious: previous != nil, canNext: following != nil) else {
                    if wasTracking && !interaction.isTracking { moveWithoutAnimation(to: 0) }
                    return
                }
                if !wasTracking { gestureID = UUID() }
                moveWithoutAnimation(to: CGFloat(offset))
            }
            .onEnded { value in
                guard !committing else { return }
                guard !ignoreCurrentTouch else {
                    ignoreCurrentTouch = false
                    interaction.reset()
                    cancelDrag()
                    return
                }
                guard let direction = interaction.finish(
                    translationX: Double(value.translation.width),
                    predictedX: Double(value.predictedEndTranslation.width),
                    width: Double(width), canPrevious: previous != nil,
                    canNext: following != nil) else {
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

    private func moveWithoutAnimation(to offset: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { dragOffset = offset }
    }

    private func cancelDrag() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.10) :
                      .interactiveSpring(response: 0.30, dampingFraction: 0.80)) {
            dragOffset = 0
        }
    }
}


/// Commit the exact artwork that was under the finger. Queue stepping with
/// shuffle enabled could otherwise play a different track than the preview.
enum NightwellSwipePlayback {
    @MainActor static func playAdjacent(_ direction: Int, clock: PlaybackClock) {
        let index = clock.displayIndex
        guard let index, clock.queue.indices.contains(index + direction) else { return }
        _ = NativePlayer.shared.playQueueTrackNow(trackID: clock.queue[index + direction].id)
    }
}
