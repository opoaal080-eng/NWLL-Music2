import SwiftUI
import UIKit

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

/// Album covers in a 3D stack. The ordinary list is a separate display mode.
struct NightwellQueueDeck: View {
    let queue: [Track]
    let currentIndex: Int
    let origin: URL

    @State private var position = 0
    @State private var notice: String?
    @State private var highlightedID: String?
    @State private var noticeRevision = 0

    private var firstUpcoming: Int { max(0, currentIndex + 1) }
    private var totalUpcoming: Int { max(0, queue.count - firstUpcoming) }
    // A swipe advances one cover; every song in the queue remains reachable.
    private var safePosition: Int { min(max(0, position), max(0, totalUpcoming - 1)) }
    private var pageStart: Int { firstUpcoming + safePosition }

    private func browse(_ direction: Int) {
        let target = min(max(0, safePosition + direction), max(0, totalUpcoming - 1))
        guard target != safePosition else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            position = target
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private var upcoming: [(offset: Int, element: Track)] {
        Array(queue.enumerated().dropFirst(pageStart).prefix(3))
    }

    private func feedback(_ message: String, for id: String?, success: Bool = true) {
        noticeRevision += 1
        let ticket = noticeRevision
        withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
            highlightedID = id
            notice = message
        }
        if success {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) {
            guard ticket == noticeRevision else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                notice = nil
                highlightedID = nil
            }
        }
    }

    private func playNow(at index: Int, track: Track) {
        NativePlayer.shared.playQueueTrackNow(at: index)
        feedback("Воспроизводим сейчас", for: track.id)
    }

    private func queueNext(at index: Int, track: Track) {
        guard index > currentIndex + 1 else {
            feedback("Уже следующий в очереди", for: track.id, success: false)
            return
        }
        NativePlayer.shared.playNextFromQueue(at: index)
        position = 0
        feedback("Следующий в очереди ✓", for: track.id)
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ForEach(Array(upcoming.reversed()), id: \.offset) { item in
                    let rank = item.offset - pageStart
                    let track = item.element
                    VStack(spacing: 0) {
                        Cover(track: track, origin: origin, pixelWidth: 520)
                            .scaledToFill()
                            .frame(width: 222, height: 145)
                            .clipped()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                            Text(track.artist).font(.system(size: 11))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .frame(width: 222, height: 202)
                    .background(.black, in: RoundedRectangle(cornerRadius: 19))
                    .clipShape(RoundedRectangle(cornerRadius: 19))
                    .overlay(
                        RoundedRectangle(cornerRadius: 19)
                            .stroke(highlightedID == track.id ? Color.white : .white.opacity(0.15),
                                    lineWidth: highlightedID == track.id ? 2.5 : 1)
                    )
                    .shadow(color: highlightedID == track.id ? .white.opacity(0.22) : .black.opacity(0.45),
                            radius: highlightedID == track.id ? 20 : 14, y: 8)
                    .scaleEffect((1 - CGFloat(rank) * 0.065) *
                                 (highlightedID == track.id ? 1.055 : 1))
                    .rotation3DEffect(.degrees(Double(rank) * -5),
                                      axis: (x: 0, y: 1, z: 0))
                    .offset(x: CGFloat(rank) * 13, y: CGFloat(rank) * 16)
                    .zIndex(Double(3 - rank))
                    .contentShape(RoundedRectangle(cornerRadius: 19))
                    // Exclusive recognition prevents a completed hold from also playing.
                    .gesture(
                        LongPressGesture(minimumDuration: 0.55)
                            .exclusively(before: TapGesture())
                            .onEnded { result in
                                switch result {
                                case .first(true): queueNext(at: item.offset, track: track)
                                case .second: playNow(at: item.offset, track: track)
                                default: break
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24).onEnded { value in
                            guard rank == 0, abs(value.translation.width) > 48,
                                  abs(value.translation.width) > abs(value.translation.height) else { return }
                            browse(value.translation.width < 0 ? 1 : -1)
                        }
                    )
                    .accessibilityLabel("\(track.title), \(track.artist)")
                    .accessibilityHint("Нажми, чтобы воспроизвести. Удерживай, чтобы поставить следующей.")
                }
            }
            .frame(height: 235)

            if totalUpcoming > 1 {
                HStack(spacing: 16) {
                    Button { browse(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 36)
                    }
                    .disabled(safePosition == 0)
                    Text("\(safePosition + 1) из \(totalUpcoming)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                    Button { browse(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 36)
                    }
                    .disabled(safePosition >= totalUpcoming - 1)
                }
                .foregroundStyle(.white)
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Text("Тап: играть сейчас · удержание: следующая · свайп: листать очередь")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: currentIndex) { _ in position = 0 }
    }
}
