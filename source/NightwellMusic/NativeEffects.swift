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
    @State private var fullscreen = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var line: String {
        guard enabled, clock.playing, model.value?.synced == true else { return "" }
        return model.value?.lines?.last(where: { $0.time <= clock.position })?.text ?? ""
    }
    var body: some View {
        Group {
            if !line.isEmpty {
                Button { fullscreen = true } label: {
                    TimelineView(.animation(minimumInterval: 0.1, paused: reduced || !clock.playing)) { timeline in
                    Text(line).font(.system(size: fontSize, weight: .bold, design: .rounded)).tracking(-0.4).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.72).frame(maxWidth: .infinity)
                        .opacity(reduced ? 1 : 0.88 + 0.12 * sin(timeline.date.timeIntervalSinceReferenceDate * 1.6))
                        .foregroundStyle(LinearGradient(stops: [
                            .init(color: nightwellText.opacity(0.85), location: 0),
                            .init(color: .white, location: max(0, min(1, 0.5 + 0.48 * sin(timeline.date.timeIntervalSinceReferenceDate * 0.65)))),
                            .init(color: Color(red: 0.75, green: 0.62, blue: 0.88), location: 1)
                        ], startPoint: .leading, endPoint: .trailing))
                        .shadow(color: nightwellText.opacity(0.22), radius: 9).shadow(color: nightwellViolet.opacity(0.72), radius: 19).id(line)
                        .transition(.opacity.combined(with: .offset(y: reduced ? 0 : 10)))
                    }
                }.buttonStyle(.plain).animation(reduced ? nil : .easeInOut(duration: 0.35), value: line)
            }
        }.sheet(isPresented: $fullscreen) {
            NavigationStack { ZStack { SeasonBackground(); SharedLyricsPanel(model: model, clock: clock).padding() }.navigationTitle("Текст песни").toolbar { Button("Закрыть") { fullscreen = false } } }
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
