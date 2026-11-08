import SwiftUI

/// Timing is line-based for legacy LRC lyrics. Word emphasis is interpolated
/// across each line, and therefore never claims word-level source timing.
struct NightwellKineticLyricLine: View {
    let text: String
    let start: Double
    let end: Double
    let position: Double
    let active: Bool
    let enabled: Bool
    let chorus: Bool

    private var words: [String] {
        text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    }

    private var highlightedWord: Int {
        guard active, enabled, !words.isEmpty else { return -1 }
        let duration = max(0.4, end - start)
        let progress = min(0.999, max(0, (position - start) / duration))
        return min(words.count - 1, Int(progress * Double(words.count)))
    }

    private var lineText: Text {
        guard enabled, active, highlightedWord >= 0 else {
            return Text(text).foregroundColor(active ? .white : .white.opacity(0.40))
        }
        return words.enumerated().reduce(Text("")) { result, entry in
            let word = entry.element + (entry.offset == words.count - 1 ? "" : " ")
            let hasPassed = entry.offset <= highlightedWord
            let isCurrent = entry.offset == highlightedWord
            return result + Text(word)
                .foregroundColor(hasPassed ? .white : .white.opacity(0.43))
                .font(.system(size: isCurrent ? (chorus ? 35 : 33) : 30,
                              weight: isCurrent ? .heavy : .bold, design: .rounded))
        }
    }

    var body: some View {
        lineText
            .font(.system(size: active ? 31 : 26, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .scaleEffect(enabled && active ? (chorus ? 1.045 : 1.025) : 1)
            .shadow(color: enabled && active ? .white.opacity(chorus ? 0.36 : 0.22) : .clear,
                    radius: enabled && active ? (chorus ? 16 : 10) : 0)
            .animation(.easeInOut(duration: 0.30), value: active)
            .animation(.easeInOut(duration: 0.22), value: highlightedWord)
            .accessibilityLabel(text)
    }
}

/// Static album images, no extra video or audio rendering.
struct NightwellQueueDeck: View {
    let queue: [Track]
    let currentIndex: Int
    let origin: URL

    private var upcoming: [Track] {
        Array(queue.dropFirst(max(0, currentIndex + 1)).prefix(3))
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                ForEach(Array(upcoming.enumerated()).reversed(), id: \.offset) { item in
                    let rank = item.offset
                    let track = item.element
                    VStack(spacing: 0) {
                        Cover(track: track, origin: origin, pixelWidth: 520)
                            .scaledToFill()
                            .frame(width: 222, height: 145)
                            .clipped()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                            Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .frame(width: 222, height: 202)
                    .background(.black, in: RoundedRectangle(cornerRadius: 19))
                    .clipShape(RoundedRectangle(cornerRadius: 19))
                    .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                    .scaleEffect(1 - CGFloat(rank) * 0.065)
                    .rotation3DEffect(.degrees(Double(rank) * -5), axis: (x: 0, y: 1, z: 0))
                    .offset(x: CGFloat(rank) * 13, y: CGFloat(rank) * 16)
                    .zIndex(Double(3 - rank))
                    .onLongPressGesture {
                        NativePlayer.shared.playNextFromQueue(at: currentIndex + 1 + rank)
                    }
                    .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                        guard rank == 0, upcoming.count > 1 else { return }
                        let next = currentIndex + 1
                        if value.translation.width < -55 {
                            NativePlayer.shared.moveUpcomingTrack(from: next + 1, to: next)
                        } else if value.translation.width > 55 {
                            NativePlayer.shared.moveUpcomingTrack(from: next, to: next + 1)
                        }
                    })
                }
            }
            .frame(height: 235)
            Text("Свайп по первой обложке меняет порядок · удержание ставит следующей")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .contain)
    }
}
