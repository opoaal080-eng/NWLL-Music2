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
    @State private var sampledPosition: Double?

    private var position: Double { sampledPosition ?? clock.position }
    private var activeLine: (line: Lyrics.Line, end: Double)? {
        guard enabled, clock.playing, model.value?.synced == true,
              let lines = model.value?.lines,
              let index = lines.lastIndex(where: { $0.time <= position }) else { return nil }
        let line = lines[index]
        if position - line.time > 4.5 && index + 1 >= lines.count { return nil }
        let end = index + 1 < lines.count ? lines[index + 1].time : line.time + 4
        if position - line.time > 4.5 { return nil }
        return (line, end)
    }

    var body: some View {
        Group {
            if let activeLine {
                Button { fullscreen = true } label: {
                    Group {
                        if kineticEnabled {
                            NightwellKineticLyricLine(
                                text: activeLine.line.text,
                                start: activeLine.line.time,
                                end: activeLine.end,
                                position: position,
                                active: true,
                                enabled: true,
                                chorus: false,
                                timedWords: activeLine.line.words,
                                fontSize: fontSize
                            )
                            .equatable()
                        } else {
                            Text(activeLine.line.text)
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
                .id(activeLine.line.time)
                .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 6)))
                .accessibilityLabel(activeLine.line.text)
            }
        }
        .animation(reduced ? nil : .easeInOut(duration: 0.22),
                   value: activeLine?.line.time)
        .task(id: clock.id) {
            // The normal UI tick is coarser than karaoke. Sample only while a
            // home lyric exists and playback is active; no audio/network work.
            while !Task.isCancelled {
                if enabled && kineticEnabled && scene == .active && clock.playing {
                    let live = NativePlayer.shared.lyricPlaybackPosition()
                    if live.isFinite && live >= 0 &&
                        (sampledPosition == nil || abs(live - (sampledPosition ?? 0)) >= 0.04) {
                        sampledPosition = live
                    }
                } else if sampledPosition != nil {
                    sampledPosition = nil
                }
                do {
                    try await Task.sleep(nanoseconds:
                        enabled && kineticEnabled && scene == .active && clock.playing
                        ? 140_000_000 : 450_000_000)
                } catch { return }
            }
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
