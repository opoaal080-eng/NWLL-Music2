import SwiftUI

struct NativeFogLayer: View {
    var active = true
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !active || scene != .active || reduced)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let t = reduced ? 0 : timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<4 {
                    let x = size.width * CGFloat(0.5 + sin(t * 0.025 + Double(index) * 2) * 0.6)
                    let y = size.height * CGFloat(0.18 + Double(index) * 0.21 + sin(t * 0.04 + Double(index)) * 0.05)
                    let rect = CGRect(x: x - size.width * 0.7, y: y - 40, width: size.width * 1.65, height: 160)
                    context.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [.purple.opacity(0.065), .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: size.width * 0.6))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct NativeLaunch: View {
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack {
            SeasonBackground().blur(radius: 14)
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                Image("BrandLogo").resizable().scaledToFit().frame(width: 90, height: 76).shadow(color: .purple.opacity(0.5), radius: 24)
                Text("Nightwell").font(.system(size: 36, weight: .bold))
                Text("M U S I C").font(.caption).tracking(4).foregroundStyle(.secondary)
                Text("HALLOWEEN EDITION").font(.caption2).tracking(3).foregroundStyle(pumpkin).padding(.top, 14)
            }.opacity(visible ? 1 : 0).scaleEffect(visible ? 1 : 0.94)
        }.allowsHitTesting(false).onAppear { withAnimation(reduced ? nil : .easeOut(duration: 0.55)) { visible = true } }
    }
}
struct SharedLyricsPanel: View {
    @ObservedObject var model: NativeLyrics
    @ObservedObject var clock: PlaybackClock
    var body: some View { LyricsView(lyrics: model.value, position: clock.position) }
}
struct HomeLyricLine: View {
    @ObservedObject var model: NativeLyrics
    @ObservedObject var clock: PlaybackClock
    var fontSize: CGFloat = 22
    @AppStorage("nw-ambient-lyrics") private var enabled = true
    @AppStorage("nw-kinetic-lyrics") private var kineticEnabled = true
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var fullscreen = false

    // The position must be re-sampled even if an AVPlayer/KVO notification is
    // missed. A view-owned TimelineView survives ordinary lyric line changes,
    // pause/buffering and portrait/landscape layout transitions.
    private func positionForFrame() -> Double {
        let fallback = clock.position.isFinite ? max(0, clock.position) : 0
        guard scene == .active, clock.playing else { return fallback }
        let live = NativePlayer.shared.lyricPlaybackPosition()
        guard live.isFinite, live >= 0 else { return fallback }
        // Some providers briefly report zero while preparing the next item.
        return live <= 0.01 && fallback > 0.5 ? fallback : live
    }

    private func activeLine(at position: Double) -> (line: Lyrics.Line, end: Double)? {
        guard enabled, model.value?.synced == true,
              let lines = model.value?.lines, !lines.isEmpty else { return nil }
        // Binary search rather than walking every timestamp six times a second.
        var lower = 0, upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].time <= position { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return nil }
        let index = lower - 1, line = lines[index]
        let end = index + 1 < lines.count
            ? max(line.time + 0.3, lines[index + 1].time)
            : line.time + 4
        // Do not erase a valid line after 4.5s. Long instrumental gaps or
        // buffering otherwise leave the Home lyric blank until a view rebuild.
        return (line, end)
    }

    @ViewBuilder private func currentLyric(at position: Double) -> some View {
        if let current = activeLine(at: position) {
            Button { fullscreen = true } label: {
                Group {
                    if kineticEnabled {
                        NightwellKineticLyricLine(
                            text: current.line.text,
                            start: current.line.time,
                            end: current.end,
                            position: position,
                            active: true,
                            enabled: true,
                            chorus: false,
                            timedWords: current.line.words,
                            fontSize: fontSize
                        )
                        .equatable()
                    } else {
                        Text(current.line.text)
                            .font(.system(size: fontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .multilineTextAlignment(.center)
                    }
                }
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(current.line.text)
            .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 6)))
            .animation(reduced ? nil : .easeInOut(duration: 0.20), value: current.line.time)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { _ in
            currentLyric(at: positionForFrame())
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $fullscreen) {
            NavigationStack {
                ZStack {
                    SeasonBackground()
                    SharedLyricsPanel(model: model, clock: clock).padding()
                }
                .navigationTitle("Текст песни")
                .toolbar { Button("Закрыть") { fullscreen = false } }
            }
        }
    }
}

struct BackgroundOnlyScene: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var lyrics: NativeLyrics
    let flash: Int
    var body: some View {
        ZStack {
            RibbonScene(playing: clock.playing, flash: flash)
                // Extend only the visual layer under the status bar and home indicator.
                .ignoresSafeArea(.container, edges: .all)
            VStack { Spacer(); HomeLyricLine(model: lyrics, clock: clock, fontSize: 38).frame(height: 190).padding(.horizontal, 24); Spacer() }
        }
    }
}
