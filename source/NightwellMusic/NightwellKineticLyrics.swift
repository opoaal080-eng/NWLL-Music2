import SwiftUI
import UIKit

/// Timing is line-based for legacy LRC lyrics. Word emphasis is interpolated
/// across each line, and therefore never claims word-level source timing.
struct NightwellKineticLyricLine: View, Equatable {
    let text: String
    let start: Double
    let end: Double
    let position: Double
    let active: Bool
    let enabled: Bool
    let chorus: Bool
    let timedWords: [Lyrics.Line.Word]?
    // Home and full lyrics share timing but use different typography.
    var fontSize: CGFloat = 28

    private var exactWords: [Lyrics.Line.Word]? {
        guard let words = timedWords, !words.isEmpty,
              words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) ==
                text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var previous = -1.0
        for word in words {
            guard let time = word.seconds, time.isFinite,
                  time >= start - 0.25, time < end + 0.5,
                  time >= previous else { return nil }
            previous = time
        }
        return words
    }

    private var pieces: [String] {
        if let exactWords { return exactWords.map(\.text) }
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        return parts.enumerated().map { index, word in
            String(word) + (index < parts.count - 1 ? " " : "")
        }
    }

    private static func weight(_ text: String) -> Double {
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let vowels = scalars.filter {
            "aeiouyAEIOUYаеёиоуыэюяАЕЁИОУЫЭЮЯ".unicodeScalars.contains($0)
        }.count
        let punctuation = text.contains(where: { ",.!?:;".contains($0) }) ? 0.20 : 0.0
        return 0.55 + Double(min(letters, 16)) * 0.16 + Double(min(vowels, 8)) * 0.18 + punctuation
    }

    private var highlightedWord: Int {
        guard active, enabled else { return -1 }
        if let exactWords {
            return exactWords.lastIndex { ($0.seconds ?? .infinity) <= position } ?? -1
        }
        let segments = pieces
        guard !segments.isEmpty else { return -1 }
        // Legacy LRC only has a timestamp per line: this is a weighted
        // estimate, not a claim of precise word synchronization.
        let weights = segments.map(Self.weight)
        let sum = weights.reduce(0, +)
        let interval = max(0.3, end - start)
        let singingWindow = min(interval, max(1.1, Double(segments.count) * 1.45))
        let fraction = max(0, min(0.99999, (position - start) / singingWindow))
        var accumulated = 0.0
        for index in segments.indices {
            accumulated += weights[index] / max(0.01, sum)
            if fraction < accumulated { return index }
        }
        return segments.count - 1
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.start == rhs.start && lhs.end == rhs.end &&
        lhs.active == rhs.active && lhs.enabled == rhs.enabled &&
        lhs.chorus == rhs.chorus && lhs.timedWords == rhs.timedWords &&
        lhs.fontSize == rhs.fontSize &&
        lhs.highlightedWord == rhs.highlightedWord
    }

    private var lineText: Text {
        let index = highlightedWord
        return pieces.enumerated().reduce(Text("")) { result, entry in
            let hasPassed = active && enabled && entry.offset <= index
            let opacity = active ? (enabled ? (hasPassed ? 1.0 : 0.55) : 1.0) : 0.40
            return result + Text(entry.element).foregroundColor(.white.opacity(opacity))
        }
    }

    var body: some View {
        lineText
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .shadow(color: active && enabled ? .white.opacity(chorus ? 0.29 : 0.19) : .clear,
                    radius: active && enabled ? (chorus ? 12 : 8) : 0)
            .animation(.easeInOut(duration: 0.17), value: highlightedWord)
            .accessibilityLabel(text)
    }
}

/// A compact, balanced cover stack inspired by the Nightwell glass queue design.
/// Browsing never reorders playback. Only a deliberate hold changes what is next.
struct NightwellQueueDeck: View {
    let queue: [Track]
    let currentIndex: Int
    let origin: URL
    // Layout follows the sheet's actual detent height.
    let compact: Bool
    let availableHeight: CGFloat

    // Reserve space for the header, controls and the pinned compact hint.
    // A medium sheet must never crop the bottom of the deck or its footer.
    private var deckHeight: CGFloat {
        compact ? min(240, max(156, availableHeight - 214)) : 354
    }

    // -1 means follow the first upcoming track until the user browses.
    @State private var position = -1
    @State private var notice: String?
    @State private var highlightedID: String?
    @State private var noticeRevision = 0

    private var safePosition: Int {
        guard !queue.isEmpty else { return 0 }
        let requested = position < 0 ? max(0, currentIndex + 1) : position
        return min(max(0, requested), queue.count - 1)
    }
    private var windowStart: Int { safePosition }
    private var upcoming: [(offset: Int, element: Track)] {
        Array(queue.enumerated().dropFirst(windowStart).prefix(3))
    }
    private func section(for index: Int) -> String {
        index < currentIndex ? "РАНЕЕ" : index == currentIndex ? "СЕЙЧАС ИГРАЕТ" : "ДАЛЕЕ"
    }

    private func browse(_ direction: Int) {
        let target = min(max(0, safePosition + direction), max(0, queue.count - 1))
        guard target != safePosition else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            position = target
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func feedback(_ message: String, for id: String?, success: Bool = true) {
        noticeRevision += 1
        let revision = noticeRevision
        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
            notice = message
            highlightedID = id
        }
        if success {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard revision == noticeRevision else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                notice = nil
                highlightedID = nil
            }
        }
    }

    private func playNow(at index: Int, track: Track) {
        let accepted = NativePlayer.shared.playQueueTrackNow(trackID: track.id)
        if accepted {
            // Playback can still be buffering. Do not claim the song is
            // already audible just because the tap gesture was recognized.
            feedback("Запускаем выбранный трек", for: track.id)
        } else {
            feedback("Не удалось запустить трек", for: track.id, success: false)
        }
    }

    private func queueNext(at index: Int, track: Track) {
        guard index > currentIndex + 1 else {
            feedback("Уже следующий в очереди", for: track.id, success: false)
            return
        }
        NativePlayer.shared.playNextFromQueue(at: index)
        position = -1
        feedback("Следующий в очереди ✓", for: track.id)
    }

    private func albumCard(
        _ track: Track, at absoluteIndex: Int, depth: Int, width: CGFloat
    ) -> some View {
        let height = width * (compact ? 0.78 : 0.82)
        let selected = highlightedID == track.id
        return VStack(spacing: 0) {
            Cover(track: track, origin: origin, pixelWidth: compact ? 600 : 680)
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
                .overlay(alignment: .topLeading) {
                    Text(section(for: absoluteIndex))
                        .font(.system(size: compact ? 8 : 10, weight: .bold))
                        .tracking(compact ? 0.8 : 1.1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 9 : 12)
                        .padding(.vertical, compact ? 5 : 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(compact ? 9 : 14)
                }
            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                Text(track.title)
                    .font(.system(size: compact ? 15 : 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: compact ? 12 : 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(width: width - (compact ? 28 : 32), height: compact ? 58 : 74, alignment: .leading)
            .padding(.horizontal, compact ? 14 : 16)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.075), Color(white: 0.022)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .frame(width: width, height: height + (compact ? 58 : 74))
        .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: compact ? 17 : 22))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 17 : 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 17 : 22, style: .continuous)
                .strokeBorder(
                    selected ? Color.white.opacity(0.90) : Color.white.opacity(0.19),
                    lineWidth: selected ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(0.48), radius: compact ? 10 : 18, y: compact ? 5 : 10)
        .scaleEffect((1 - CGFloat(depth) * 0.048) * (selected ? 1.035 : 1))
        .rotationEffect(.degrees(Double(depth) * 1.3))
        .offset(x: CGFloat(depth) * (compact ? 9 : 15), y: CGFloat(depth) * (compact ? 7 : 13))
        .zIndex(Double(3 - depth))
        .contentShape(RoundedRectangle(cornerRadius: compact ? 17 : 22))
        .gesture(
            LongPressGesture(minimumDuration: 0.55)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first(true):
                        queueNext(at: absoluteIndex, track: track)
                    case .second:
                        playNow(at: absoluteIndex, track: track)
                    default:
                        break
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 22).onEnded { gesture in
                guard depth == 0,
                      abs(gesture.translation.width) > 48,
                      abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                browse(gesture.translation.width < 0 ? 1 : -1)
            }
        )
        .accessibilityLabel("\(track.title), \(track.artist)")
        .accessibilityHint("Нажми, чтобы слушать сейчас. Удерживай, чтобы поставить следующим.")
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let cardWidth = compact
                    ? min(240, max(130, min(geometry.size.width - 50,
                                            (geometry.size.height - 60) / 0.78)))
                    : min(max(190, geometry.size.width - 78), 310)
                ZStack {
                    ForEach(Array(upcoming.reversed()), id: \.offset) { item in
                        albumCard(item.element,
                                  at: item.offset,
                                  depth: item.offset - windowStart,
                                  width: cardWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: deckHeight)

            if queue.count > 1 {
                HStack(spacing: compact ? 12 : 20) {
                    Button { browse(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: compact ? 15 : 18, weight: .medium))
                            .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
                    }
                    .disabled(safePosition == 0)
                    .opacity(safePosition == 0 ? 0.35 : 1)

                    Text("\(safePosition + 1) из \(queue.count)")
                        .font(.system(size: compact ? 12 : 14, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: compact ? 72 : 84)

                    Button { browse(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: compact ? 15 : 18, weight: .medium))
                            .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
                    }
                    .disabled(safePosition >= queue.count - 1)
                    .opacity(safePosition >= queue.count - 1 ? 0.35 : 1)
                }
                .foregroundStyle(Color.white.opacity(0.90))
                .padding(.top, compact ? 0 : 4)
                .accessibilityElement(children: .contain)
            }

            ZStack {
                if let notice {
                    Text(notice)
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 10 : 14)
                        .padding(.vertical, compact ? 4 : 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .frame(height: compact ? 18 : 42)

            // On medium detents the two-line hint lives outside the scroll
            // viewport, so it remains fully visible even as cards are browsed.
            if !compact {
                Text("Тап: играть сейчас · удержание: следующая\nСвайп: листать всю очередь")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.53))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .onChange(of: currentIndex) { _ in position = -1 }
    }
}
