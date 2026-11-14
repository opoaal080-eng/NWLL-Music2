import SwiftUI
import Combine
import AVKit
import AVFoundation
import UniformTypeIdentifiers

struct SeasonBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.065), Color(white: 0.015), .black],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea().allowsHitTesting(false)
    }
}
// Keep the gradient mounted throughout startup, buffering, pause and resume.
// Never multiply absolute time by audio energy or the play state: that causes
// huge phase jumps whenever the audio meter or the transport state changes.
struct RibbonScene: View {
    @EnvironmentObject private var palette: NightwellArtworkPalette
    let playing: Bool
    let flash: Int
    var active = true
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("nw-ambient-animate-when-paused") private var animatePaused = true
    @AppStorage("nw-ambient-audio-sensitivity") private var sensitivity = 4.0
    @State private var frozenTime = Date().timeIntervalSinceReferenceDate

    var body: some View {
        TimelineView(.animation(minimumInterval: playing ? 1.0 / 30.0 : 1.0 / 15.0,
                                paused: scene != .active || reduceMotion || !active || (!playing && !animatePaused))) { tick in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                guard size.width > 1, size.height > 1 else { return }
                let t = reduceMotion || !active || (!playing && !animatePaused)
                    ? frozenTime : tick.date.timeIntervalSinceReferenceDate
                let colors = palette.at(ProcessInfo.processInfo.systemUptime)
                let values = playing ? NativePlayer.shared.auraLevels() : []
                let valid = values.filter { $0.isFinite }.map { min(1, max(0, $0)) }
                let level = valid.reduce(0, +) / Double(max(1, valid.count))
                let gain = sensitivity.isFinite ? min(4, max(0.5, sensitivity)) : 4.0
                // A wider dynamic range reacts to quiet notes and bass hits
                // without pushing ordinary music permanently to full brightness.
                let energy = playing ? min(1, pow(level, 0.56) * gain * 0.50) : 0.0
                draw(context: context, size: size, colors: colors, time: t, energy: energy)
            }
        }
        .onChange(of: playing) { value in
            if !value { frozenTime = Date().timeIntervalSinceReferenceDate }
        }
        .onChange(of: animatePaused) { value in
            if !value { frozenTime = Date().timeIntervalSinceReferenceDate }
        }
        .onChange(of: active) { value in
            if !value { frozenTime = Date().timeIntervalSinceReferenceDate }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(context: GraphicsContext, size: CGSize,
                      colors: NightwellArtworkColors, time: Double, energy: Double) {
        let w = Double(size.width), h = Double(size.height), scale = max(w, h)
        let primary = colors.primary.color, secondary = colors.secondary.color

        // The dark base is always painted, including the first frame and silence.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [.init(red: 0.047, green: 0.037, blue: 0.055),
                              .init(red: 0.018, green: 0.020, blue: 0.030)]),
            startPoint: .zero, endPoint: CGPoint(x: w, y: h)))

        // Fixed angular velocity prevents audio spikes from teleporting the blobs.
        // Energy only influences their opacity a little, never their time/position.
        let phase = time.truncatingRemainder(dividingBy: 100_000) * 0.085
        for index in 0..<4 {
            let k = Double(index)
            let x = w * (0.23 + 0.17 * k + 0.115 * sin(phase + k * 1.8))
            let y = h * (0.22 + 0.17 * k + 0.115 * cos(phase * 0.76 + k))
            let center = CGPoint(x: x, y: y)
            let radius = scale * (index == 0 ? 0.72 : 0.61)
            let tint = index.isMultiple(of: 2) ? primary : secondary
            // More pronounced audio response; movement remains time-based
            // so individual audio peaks cannot teleport the gradient.
            let opacity = 0.29 + energy * 0.105
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                 width: radius * 2, height: radius * 2)),
                         with: .radialGradient(
                            Gradient(colors: [tint.opacity(opacity),
                                              tint.opacity(opacity * 0.42),
                                              tint.opacity(opacity * 0.11), .clear]),
                            center: center, startRadius: 0, endRadius: radius))
        }
    }
}

// Quiet decorative stars are independent of the audio engine and playback state.
private struct HomeSparkles: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                guard size.width > 1, size.height > 1 else { return }
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<28 {
                    let seed = Double(index)
                    let x = (sin(seed * 91.71 + 1.9) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let y = (sin(seed * 37.43 + 7.1) * 12573.1341).truncatingRemainder(dividingBy: 1)
                    let px = CGFloat(x < 0 ? x + 1 : x) * size.width
                    let py = CGFloat(y < 0 ? y + 1 : y) * size.height
                    let phase = seed * 1.618
                    let shimmer = reduceMotion ? 0.55 : 0.5 + 0.5 * sin(time * (0.7 + seed.truncatingRemainder(dividingBy: 5) * 0.14) + phase)
                    let alpha = 0.09 + shimmer * 0.37
                    let radius = CGFloat(0.55 + shimmer * 0.65)
                    let point = CGPoint(x: px, y: py)
                    let bounds = CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: bounds), with: .color(.white.opacity(alpha)))
                    if index % 7 == 0 {
                        let glow = CGRect(x: px - 4, y: py - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: glow), with: .radialGradient(
                            Gradient(colors: [.white.opacity(alpha * 0.25), .clear]),
                            center: point, startRadius: 0, endRadius: 4
                        ))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct NativeHome: View {
    let configureWave: () -> Void
    @State private var suppressMixTapUntil = Date.distantPast
    @EnvironmentObject var store: MusicStore
    @Environment(\.nightwellBottomContentInset) private var bottomContentInset
    private let clock: PlaybackClock
    @ObservedObject private var status: TrackStatus

    init(configureWave: @escaping () -> Void, clock: PlaybackClock) {
        self.configureWave = configureWave
        self.clock = clock
        _status = ObservedObject(wrappedValue: clock.status)
    }

    private func homeTitle(_ compact: Bool) -> some View {
        Text("Твой ритм")
            .font(.system(size: compact ? 29 : 44, weight: .bold))
            .tracking(-1.2)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }

    private func playButton(_ compact: Bool) -> some View {
        Button {
            if clock.current == nil { Task { await store.wave() } }
            else { clock.toggle() }
        } label: {
            Image(systemName: status.playing ? "pause.fill" : "play.fill")
                .font(.system(size: compact ? 25 : 31, weight: .light))
                .foregroundStyle(.white)
                .frame(width: compact ? 68 : 88, height: compact ? 68 : 88)
                .frostedGlass(compact ? 34 : 44, bordered: false, intensity: 0.20)
                .contentShape(Circle())
        }
        .accessibilityLabel(status.playing ? "Пауза" : "Воспроизвести")
        .buttonStyle(.plain)
    }

    private func waveButton(_ compact: Bool) -> some View {
        Button {
            if Date() >= suppressMixTapUntil { Task { await store.wave() } }
        } label: {
            HStack(spacing: 7) {
                if store.loading { ProgressView().tint(.white) }
                Text(store.loading ? "Подбираем…" : "Новая подборка")
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 18)
            .frame(height: compact ? 34 : 40)
            .frostedGlass(22, bordered: false, intensity: 0.20)
        }
        .disabled(store.loading)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            suppressMixTapUntil = Date().addingTimeInterval(1)
            configureWave()
        })
        .buttonStyle(.plain)
        .accessibilityHint("Удерживай, чтобы настроить подборку")
        .accessibilityAction(named: "Настроить подборку") { configureWave() }
    }

    var body: some View {
        GeometryReader { box in
            let controlsHeight = max(0, box.size.height - bottomContentInset)
            let landscape = box.size.width > controlsHeight * 1.12 &&
                controlsHeight < 450
            Group {
                if landscape {
                    // iPhone landscape: controls on the left, karaoke on the
                    // right. Nothing is layered over the playback button.
                    HStack(alignment: .center, spacing: 18) {
                        VStack(spacing: 13) {
                            homeTitle(true)
                            waveButton(true)
                        }
                        .frame(maxWidth: .infinity)
                        playButton(true)
                        HomeLyricLine(model: store.lyrics, clock: clock, fontSize: 20)
                            .frame(maxWidth: .infinity, minHeight: 70)
                    }
                    .padding(.horizontal, 18)
                } else {
                    VStack(spacing: 22) {
                        homeTitle(false)
                        playButton(false)
                        waveButton(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, max(24, controlsHeight * 0.07))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomContentInset)
            .background { HomeSparkles() }
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var store: MusicStore
    @ObservedObject var clock: PlaybackClock
    let open: () -> Void
    var compactHeight = false
    @State private var glow = false
    @State private var slideDirection: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        GeometryReader { box in
            let compact = box.size.width < 350 || compactHeight
            HStack(spacing: compact ? 8 : 12) {
                Button(action: open) {
                    HStack(spacing: 7) {
                        Cover(track: clock.displayCurrent, origin: store.origin)
                            .frame(width: compactHeight ? 34 : 42, height: compactHeight ? 34 : 42).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clock.displayCurrent?.title ?? "Выбери трек").font(.system(size: compact ? 12 : 14, weight: .semibold)).lineLimit(1)
                            Text(clock.displayCurrent?.artist ?? "Nightwell Music").font(.system(size: compact ? 10 : 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(clock.displayID)
                    .transition(.asymmetric(
                        insertion: .offset(x: 45 * slideDirection).combined(with: .opacity),
                        removal: .offset(x: -45 * slideDirection).combined(with: .opacity)
                    ))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .highPriorityGesture(DragGesture(minimumDistance: 18).onEnded { value in
                    if abs(value.translation.width) > 48 && abs(value.translation.width) > abs(value.translation.height) * 1.2 {
                        changeTrack(value.translation.width < 0 ? 1 : -1)
                    }
                })
                HStack(spacing: compact ? 2 : 5) {
                    if let track = clock.displayCurrent {
                        Button { Task { await store.like(track) } } label: { Image(systemName: store.likes.contains(track.id) ? "heart.fill" : "heart").font(.system(size: 19)).foregroundStyle(Color.white).frame(width: compact ? 26 : 29, height: 44) }.accessibilityLabel("Избранное")
                    }
                    Button { changeTrack(-1) } label: { Image(systemName: "backward.end").font(.system(size: 15)).frame(width: compact ? 24 : 28, height: 44) }.accessibilityLabel("Предыдущий трек")
                    Button { clock.toggle() } label: {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.16))
                                .frame(width: 40, height: 40)
                            // Track stays subtle. The white arc shows the actual
                            // listening position, starting at 12 o'clock.
                            Circle()
                                .stroke(Color.white.opacity(0.22), lineWidth: 2.2)
                                .frame(width: 44, height: 44)
                            // During initial buffering this same ring shows
                            // loaded audio; once audible it shows play position.
                            Circle()
                                .trim(from: 0, to: clock.preparing ? CGFloat(clock.bufferFraction) : playbackFraction)
                                .stroke(Color.white.opacity(0.96),
                                        style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 44, height: 44)
                            if clock.preparing && clock.bufferFraction < 0.01 {
                                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduced)) { time in
                                    let phase = time.date.timeIntervalSinceReferenceDate
                                        .truncatingRemainder(dividingBy: 1.4) / 1.4
                                    Circle()
                                        .trim(from: 0, to: 0.22)
                                        .stroke(.white.opacity(0.92),
                                                style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
                                        .rotationEffect(.degrees(phase * 360 - 90))
                                        .frame(width: 44, height: 44)
                                }
                                .allowsHitTesting(false)
                            }
                            Image(systemName: clock.playing ? "pause" : "play.fill")
                                .font(.system(size: 17, weight: .light))
                        }
                        .frame(width: compactHeight ? 42 : 48, height: compactHeight ? 42 : 48)
                    }
                    .accessibilityLabel(clock.playing ? "Пауза" : "Воспроизвести")
                    .accessibilityValue(clock.preparing
                        ? (clock.bufferFraction > 0
                           ? "Загружено \(Int((clock.bufferFraction * 100).rounded()))%"
                           : "Подготовка аудио")
                        : (clock.duration > 0
                           ? "\(Int((playbackFraction * 100).rounded()))% трека"
                           : "Прогресс неизвестен"))
                    Button { changeTrack(1) } label: { Image(systemName: "forward.end").font(.system(size: 15)).frame(width: compact ? 24 : 28, height: 44) }.accessibilityLabel("Следующий трек")
                }.buttonStyle(.plain)
            }.foregroundStyle(.white) .padding(.horizontal, 14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.23)
            }
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.34), Color.white.opacity(0.34), .white.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1))
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .shadow(color: Color.white.opacity(glow ? 0.4 : 0), radius: 18)
        }.frame(height: compactHeight ? 54 : 68)
        .animation(reduced ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: clock.id)
        .task(id: clock.id) { guard !reduced else { return }; glow = true; try? await Task.sleep(nanoseconds: 80_000_000); guard !Task.isCancelled else { return }; withAnimation(.easeOut(duration: 0.9)) { glow = false } }
        // Swipe wins over the artwork/title tap, so it never opens the full player.
    }
    private var playbackFraction: CGFloat {
        // Protect against unknown duration, invalid stream timestamps and
        // seeking overshoot. @ObservedObject updates the ring on every tick.
        guard clock.displayDuration.isFinite, clock.displayPosition.isFinite,
              clock.displayDuration > 0 else { return 0 }
        return CGFloat(min(1, max(0, clock.displayPosition / clock.displayDuration)))
    }

    private func changeTrack(_ step: Int) {
        slideDirection = step < 0 ? -1 : 1
        NativePlayer.shared.step(step)
    }
}


struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var accessibilityStep: Double = 1
    let label: String
    let valueText: String
    // Optional backing layer on the same track as the playhead. Other sliders
    // keep their existing appearance with the default 0 fraction.
    var bufferedFraction: CGFloat = 0
    var preparing: Bool = false
    // Keep settings sliders unchanged, but use an unobtrusive handle on the player.
    var knobDiameter: CGFloat = 18
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    private var fraction: CGFloat {
        guard range.upperBound > range.lowerBound, value.isFinite else { return 0 }
        return CGFloat(min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }
    private func update(_ x: CGFloat, width: CGFloat) {
        let unit = Double(min(1, max(0, (x - 11) / max(1, width - 22))))
        let raw = range.lowerBound + unit * (range.upperBound - range.lowerBound)
        let rounded = step > 0 ? range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step : raw
        value = min(range.upperBound, max(range.lowerBound, rounded))
    }
    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - 22)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.13)).frame(height: dragging ? 6 : 4)
                // Actual AVPlayer cached audio, drawn BEHIND the white
                // playback progress on exactly the same horizontal track.
                if bufferedFraction > 0 {
                    Capsule()
                        .fill(.white.opacity(0.36))
                        .frame(width: width * min(1, max(0, bufferedFraction)),
                               height: dragging ? 6 : 4)
                } else if preparing {
                    // The server cannot always report how much of the first
                    // audio is ready. Show movement rather than a fake percent.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducedMotion)) { time in
                        let phase = time.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.45) / 1.45
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.clear, .white.opacity(0.48), .clear],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: min(94, width * 0.38), height: 4)
                            .offset(x: -94 + (width + 188) * CGFloat(phase))
                            .frame(width: width, height: 4, alignment: .leading)
                            .clipped()
                    }
                    .allowsHitTesting(false)
                }
                Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.65), Color.white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * fraction, height: dragging ? 6 : 4)
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.95), Color.white], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: knobDiameter, height: knobDiameter)
                    .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 0.5))
                    .shadow(color: Color.white.opacity(dragging ? 0.35 : 0.12), radius: dragging ? 5 : 2)
                    .scaleEffect(dragging ? 1.15 : 1)
                    .offset(x: width * fraction - knobDiameter / 2)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !dragging { dragging = true; onEditingChanged(true) }
                    update(gesture.location.x, width: proxy.size.width)
                }
                .onEnded { gesture in
                    update(gesture.location.x, width: proxy.size.width)
                    dragging = false
                    onEditingChanged(false)
                })
        }
        .frame(height: 40)
        .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: dragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(range.upperBound, value + accessibilityStep)
            case .decrement: value = max(range.lowerBound, value - accessibilityStep)
            @unknown default: break
            }
            onEditingChanged(false)
        }
        .onDisappear { if dragging { dragging = false; onEditingChanged(false) } }
    }
}

// System-managed AirPlay and Bluetooth output selector.
// AVRoutePickerView owns the system route selection UI. Expand its native button
// to cover the complete capsule so tapping the device name works too.
private final class ExpandedAudioRoutePicker: AVRoutePickerView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for case let button as UIButton in subviews {
            button.frame = bounds
        }
    }
}

private struct NightwellAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = ExpandedAudioRoutePicker(frame: .zero)
        picker.prioritizesVideoDevices = false
        // Keep the real UIKit picker fully interactive; only its icon is hidden.
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.backgroundColor = .clear
        picker.isUserInteractionEnabled = true
        return picker
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct NightwellAudioOutputControl: View {
    @State private var output = Self.currentOutput()
    private static func currentOutput() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "iPhone"
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "airplayaudio").font(.caption2)
            Text(output)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Image(systemName: "chevron.down").font(.system(size: 9))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .nightwellLiquidGlass(19)
        .frame(minHeight: 44)
        .overlay {
            NightwellAudioRoutePicker()
                .contentShape(Capsule())
                .accessibilityLabel("Устройство вывода: \(output). Изменить")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            output = Self.currentOutput()
        }
        .onAppear { output = Self.currentOutput() }
    }
}

// Reduce the artwork to a small colour grid before enlarging it, so details
// disappear while colours keep their positions from the original image.
private struct ArtworkPaletteKey: PreferenceKey {
    static var defaultValue: [Color] = []
    static func reduce(value: inout [Color], nextValue: () -> [Color]) { value = nextValue() }
}
private struct LyricsPaletteKey: EnvironmentKey {
    static let defaultValue: [Color] = [.white, .white]
}
private extension EnvironmentValues {
    var lyricsPalette: [Color] {
        get { self[LyricsPaletteKey.self] }
        set { self[LyricsPaletteKey.self] = newValue }
    }
}

private struct ArtworkColorBackground: View {
    let url: URL?
    @State private var palette: UIImage?
    @State private var textColors: [Color] = []

    var body: some View {
        GeometryReader { geometry in
            if let palette {
                Image(uiImage: palette)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .blur(radius: 30, opaque: true)
                    .overlay(Color.black.opacity(0.35))
                    .clipped()
            } else {
                Color.clear
            }
        }
        .preference(key: ArtworkPaletteKey.self, value: textColors)
        .task(id: url) {
            textColors = []
            palette = nil
            guard let url else { return }
            do {
                guard let original = await CoverImagePipeline.shared.image(for: url, maxPixel: 128),
                      !Task.isCancelled else { return }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6), format: format)
                let colors = renderer.image { _ in
                    original.draw(in: CGRect(x: 0, y: 0, width: 6, height: 6))
                }
                guard !Task.isCancelled else { return }
                palette = colors
                if let cgImage = original.cgImage {
                    var pixels = [UInt8](repeating: 0, count: 12)
                    pixels.withUnsafeMutableBytes { buffer in
                        if let context = CGContext(data: buffer.baseAddress, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            context.interpolationQuality = .high
                            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 3, height: 1))
                        }
                    }
                    textColors = (0..<3).map { index in
                        let offset = index * 4
                        return Color(red: 0.55 + Double(pixels[offset]) / 255 * 0.45,
                                     green: 0.55 + Double(pixels[offset + 1]) / 255 * 0.45,
                                     blue: 0.55 + Double(pixels[offset + 2]) / 255 * 0.45)
                    }
                }
            } catch { }
        }
    }
}

private struct NightwellPresentedClip: Identifiable {
    let id = UUID()
    let url: URL
    let trackTitle: String
}

struct FullPlayer: View {
    @EnvironmentObject private var togetherSession: NightwellTogetherSession
    @State private var artworkTextColors: [Color] = [.white, .white]
    @EnvironmentObject var store: MusicStore
    @ObservedObject var clock: PlaybackClock
    @Environment(\.dismiss) private var dismiss
    @State private var lyricsFrame = CGRect.zero
    @State private var showLyrics = false
    @State private var nativeMenuSnapshot: NightwellPlayerActionSnapshot?
    @State private var availableClipURL: URL?
    @State private var availableClipTrackID = ""
    @State private var presentedClip: NightwellPresentedClip?
    @State private var clipSearchNotice = false
    @State private var feature: PremiumFeatureView.Kind?
    @State private var showQueue = false
    @State private var selectedArtist: ArtistSelection?
    @State private var showArtistChoices = false
    @State private var seeking = false
    @State private var scrub = 0.0
    @State private var repeatMode = 0
    @State private var shuffleMode = 0
    @AppStorage("nw-cover-style") private var coverStyle = "classic"
    var body: some View {
        playerFinal
    }

    private var playerFinal: some View {
        playerSearchAndUpdates
        .confirmationDialog("Выбери исполнителя", isPresented: $showArtistChoices, titleVisibility: .visible) {
            ForEach(ArtistNames.split(clock.displayCurrent?.artist ?? ""), id: \.self) { name in
                Button(name) { selectedArtist = ArtistSelection(name: name) }
            }
        }
        .sheet(item: $selectedArtist) { artist in
            ArtistProfileView(name: artist.name).environmentObject(store)
        }
        .sheet(isPresented: $showQueue) {
            PlaybackQueue(clock: clock)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
        }
    }

    // Grouping unrelated SwiftUI onChange chains in one expression makes
    // Swift 6's constraint solver hit its type-check timeout. Keep short
    // subtrees, with simple precomputed keys for the collection observers.
    private var clipLookupKey: String {
        let selected = clock.displayCurrent
        return store.origin.absoluteString + "|" + (selected?.id ?? "") + "|"
            + (selected?.title ?? "") + "|" + (selected?.artist ?? "")
            + "|" + (store.account?.id ?? "")
    }

    private var playlistRevision: String {
        store.playlists.map(\.id).joined(separator: "|")
    }

    private var offlineRevision: String {
        store.offline.map(\.id).sorted().joined(separator: "|")
    }

    private var playerSearchAndUpdates: some View {
        playerClipUpdates
            .onChange(of: coverStyle) { _ in refreshNativeMenu() }
            .onChange(of: togetherSession.joined) { _ in refreshNativeMenu() }
    }

    private var playerClipUpdates: some View {
        playerClipAlerts
            .task(id: clipLookupKey) {
                availableClipURL = nil
                availableClipTrackID = ""
                guard let selected = clock.displayCurrent else { return }
                let result = NightwellClipAvailabilityCache.shared.cachedClip(
                    track: selected, origin: store.origin)
                guard !Task.isCancelled, clock.displayCurrent?.id == selected.id else { return }
                availableClipTrackID = selected.id
                availableClipURL = result
                refreshNativeMenu()
            }
            .onChange(of: availableClipURL) { _ in refreshNativeMenu() }
    }

    private var playerClipAlerts: some View {
        playerLibraryUpdates
            .alert("Клип", isPresented: $clipSearchNotice) {
                Button("ОК", role: .cancel) { }
            } message: {
                Text("Подходящий клип пока не найден или поиск временно недоступен. Попробуй позже.")
            }
    }

    private var playerLibraryUpdates: some View {
        playerPlaybackUpdates
            .onChange(of: playlistRevision) { _ in refreshNativeMenu() }
            .onChange(of: offlineRevision) { _ in refreshNativeMenu() }
    }

    private var playerPlaybackUpdates: some View {
        playerWithSheets
            .onChange(of: clock.displayCurrent?.id) { _ in refreshNativeMenu() }
            .onChange(of: store.likes) { _ in refreshNativeMenu() }
    }

    private var playerWithSheets: some View {
        playerLifecycle
        .sheet(item: $feature) { PremiumFeatureView(kind: $0).environmentObject(store) }
        .sheet(item: $presentedClip) { clip in
            NightwellClipScreen(clipURL: clip.url, title: clip.trackTitle, origin: store.origin)
        }
    }

    private var playerLifecycle: some View {
        playerGesture
        .onAppear {
            refreshNativeMenu()
            let modes = NativePlayer.shared.snapshot(includeQueue: false)
            repeatMode = modes["repeat"] as? Int ?? 0
            shuffleMode = modes["shuffleMode"] as? Int ?? ((modes["shuffle"] as? Bool ?? false) ? 1 : 0)
            if store.lyrics.value == nil || store.lyrics.value?.status == "error" || store.lyrics.value?.status == "unavailable" {
                store.lyrics.select(clock.displayCurrent, api: store.api, origin: store.origin, online: store.account != nil)
            }
        }
    }

    private var playerGesture: some View {
        playerBase
        .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
            // Keep scrubbing, horizontal track changes and lyric scrolling independent.
            // When lyrics are visible all vertical gestures belong to
            // the lyrics view. Only the explicit chevron can close the player.
            guard !showLyrics, !seeking, !showQueue else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            guard dy > 95, dy > abs(dx) * 1.45 else { return }
            // A swipe beginning in synchronized lyrics belongs to the lyrics scroller.
            if showLyrics && lyricsFrame.contains(value.startLocation) { return }
            withAnimation(.easeOut(duration: 0.24)) { dismiss() }
        })
    }

    private var playerBase: some View {
        ZStack {
            playerBackdrop
            playerControls
        }.tint(Color.white)
        .environment(\.lyricsPalette, artworkTextColors)
        .onPreferenceChange(ArtworkPaletteKey.self) { colors in
            artworkTextColors = colors.isEmpty ? [.white, .white] : colors
        }
        .onPreferenceChange(PlayerLyricsFramePreference.self) { lyricsFrame = $0 }
    }

    @ViewBuilder private var playerBackdrop: some View {
            // Neutral home-style backdrop instead of the seasonal Halloween illustration.
            Color.black.ignoresSafeArea()
            if !showLyrics {
                ArtworkColorBackground(
                    url: clock.displayCurrent?.cover_url.flatMap {
                        URL(string: $0, relativeTo: store.origin)
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Immersive style keeps the full-height artwork behind the
                // controls. Classic style draws a rounded square in its slot.
                if coverStyle != "classic" {
                GeometryReader { screen in
                    let coverSide = max(screen.size.width, screen.size.height + 76)
                    NightwellAnimatedCover(
                        track: clock.displayCurrent,
                        origin: store.origin,
                        side: coverSide
                    )
                    .position(x: screen.size.width / 2, y: screen.size.height / 2)
                    .frame(width: screen.size.width, height: screen.size.height)
                    .clipped()
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.16), location: 0),
                            .init(color: .clear, location: 0.27),
                            .init(color: .clear, location: 0.53),
                            .init(color: .black.opacity(0.20), location: 0.72),
                            .init(color: .black.opacity(0.77), location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                }
            } else {
                LinearGradient(colors: [Color(white: 0.085), Color(white: 0.025), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if showLyrics { HomeSparkles().ignoresSafeArea() }
    }

    private var playerControls: some View {
        GeometryReader { viewport in
            let landscape = viewport.size.width > viewport.size.height * 1.12 &&
                viewport.size.height < 650
            if landscape {
                VStack(spacing: 6) {
                    playerHeader(compact: true)
                    HStack(alignment: .center, spacing: 12) {
                        artworkInteraction
                            .frame(width: min(viewport.size.width * 0.34, 220))
                        // Avoid stacking a full-height cover over transport
                        // controls on iPhones with short landscape viewports.
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 8) {
                                playerTrackDetails(compact: true)
                                playerTransport(compact: true)
                                playerQuickActions(compact: true)
                                playerError
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.leading, max(18, viewport.safeAreaInsets.leading + 10))
                .padding(.trailing, max(18, viewport.safeAreaInsets.trailing + 10))
                .padding(.top, 14)
                .padding(.bottom, 8)
            } else {
                VStack(spacing: 14) {
                    playerHeader(compact: false)
                    artworkInteraction
                    playerTrackDetails(compact: false)
                    playerTransport(compact: false)
                    playerQuickActions(compact: false)
                    playerError
                }
                .padding(.horizontal, 26)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder private func playerHeader(compact: Bool) -> some View {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: compact ? 38 : 44, height: compact ? 38 : 44)
                            .nightwellLiquidGlass(compact ? 20 : 24)
                    }
                    Spacer()
                    NightwellAudioOutputControl()
                        .scaleEffect(compact ? 0.86 : 1)
                    Spacer()
                    tools.scaleEffect(compact ? 0.86 : 1)
                }
    }

    @ViewBuilder private var artworkInteraction: some View {
                GeometryReader { box in
                    if showLyrics {
                        SharedLyricsPanel(model: store.lyrics, clock: clock)
                            .id(clock.id)
                            .background { GeometryReader { proxy in Color.clear.preference(key: PlayerLyricsFramePreference.self, value: proxy.frame(in: .global)) } }

                    } else {
                        Group {
                            if coverStyle == "classic" ||
                                (box.size.width > box.size.height && box.size.height < 500) {
                                let side = min(box.size.width, box.size.height) * 0.96
                                Cover(track: clock.displayCurrent, origin: store.origin, pixelWidth: 1024)
                                    .frame(width: side, height: side)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    .shadow(color: .black.opacity(0.38), radius: 22, y: 12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                // Immersive artwork is already behind controls.
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 18).onEnded { value in
                            let dx = value.translation.width
                            if abs(dx) > 52 && abs(dx) > abs(value.translation.height) * 1.15 {
                                NativePlayer.shared.step(dx < 0 ? 1 : -1)
                            }
                        })
                    }
                }
    }

    @ViewBuilder private func playerTrackDetails(compact: Bool) -> some View {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                        Text(clock.displayCurrent?.title ?? "Выбери трек").font(.system(size: compact ? 17 : 20, weight: .bold)).lineLimit(2)
                        Button {
                            let artists = ArtistNames.split(clock.displayCurrent?.artist ?? "")
                            if artists.count > 1 { showArtistChoices = true }
                            else if let name = artists.first { selectedArtist = ArtistSelection(name: name) }
                        } label: {
                            HStack(spacing: 5) {
                                Text(clock.displayCurrent?.artist ?? "").lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Открыть исполнителя")
                        .disabled(!ArtistAttribution.isKnown(clock.displayCurrent?.artist ?? ""))
                        if !store.audioQualityNotice.isEmpty {
                            Text(store.audioQualityNotice)
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    if let track = clock.displayCurrent {
                        Button { store.toggleRecommendationHidden(track) } label: {
                            Image(systemName: store.isRecommendationHidden(track) ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .font(.system(size: compact ? 16 : 19))
                                .foregroundStyle(store.isRecommendationHidden(track) ? Color.white : Color.white.opacity(0.65))
                                .frame(width: compact ? 38 : 44, height: compact ? 38 : 44).nightwellLiquidGlass(compact ? 19 : 22)
                        }
                        .accessibilityLabel(store.isRecommendationHidden(track) ? "Вернуть в рекомендации" : "Не рекомендовать")
                        Button { Task { await store.like(track) } } label: {
                            Image(systemName: store.likes.contains(track.id) ? "heart.fill" : "heart")
                                .font(.system(size: compact ? 17 : 20)).foregroundStyle(Color.white)
                                .frame(width: compact ? 38 : 44, height: compact ? 38 : 44).nightwellLiquidGlass(compact ? 19 : 22)
                        }
                        .accessibilityLabel(store.likes.contains(track.id) ? "Убрать из избранного" : "В избранное")
                    }
                }
    }

    @ViewBuilder private func playerTransport(compact: Bool) -> some View {
                VStack(spacing: compact ? 10 : 16) {
                    VStack(spacing: compact ? 5 : 8) {
                        GlassSlider(value: Binding(get: { seeking ? scrub : min(clock.displayPosition, clock.displayDuration) }, set: { scrub = $0 }), range: 0...clock.displayDuration, accessibilityStep: 5, label: "Позиция трека", valueText: formatTime(seeking ? scrub : clock.displayPosition), bufferedFraction: CGFloat(clock.bufferFraction), preparing: clock.preparing, knobDiameter: 8) { editing in if editing { scrub = clock.displayPosition; seeking = true } else { NativePlayer.shared.seek(scrub); seeking = false } }
                            // The former stream is still audible during handoff.
                            // Disable scrubbing to avoid seeking the wrong track.
                            .allowsHitTesting(clock.displayID == clock.id)
                        HStack { Text(formatTime(seeking ? scrub : clock.displayPosition)); Spacer(); Text("−" + formatTime(max(0, clock.displayDuration - (seeking ? scrub : clock.displayPosition)))) }.font(compact ? .caption2 : .caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Button {
                            shuffleMode = (shuffleMode + 1) % 3
                            NativePlayer.shared.setShuffleMode(shuffleMode)
                        } label: {
                            Image(systemName: shuffleMode == 2 ? "shuffle.circle.fill" : "shuffle")
                                .foregroundStyle(shuffleMode == 0 ? Color.secondary : Color.white)
                        }
                        .accessibilityLabel(["Перемешивание выключено", "Обычное перемешивание", "Умное перемешивание"][shuffleMode]); Spacer()
                        Button { NativePlayer.shared.step(-1) } label: { Image(systemName: "backward.end") }; Spacer()
                        Button { clock.toggle() } label: { Image(systemName: clock.playing ? "pause" : "play.fill") .font(.system(size: compact ? 21 : 25)).frame(width: compact ? 54 : 68, height: compact ? 54 : 68).frostedGlass(compact ? 27 : 34, bordered: false, intensity: 0.20) }; Spacer()
                        Button { NativePlayer.shared.step(1) } label: { Image(systemName: "forward.end") }; Spacer()
                        Button { repeatMode = (repeatMode + 1) % 3; NativePlayer.shared.modes(repeatMode: repeatMode, shuffle: shuffleMode != 0) } label: { Image(systemName: repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(repeatMode > 0 ? Color.white : .secondary) }
                    }.font(.system(size: compact ? 17 : 20))
                }
    }

    @ViewBuilder private func playerQuickActions(compact: Bool) -> some View {
                HStack {
                    Button { withAnimation { showLyrics.toggle() } } label: { Image(systemName: "text.bubble").frame(maxWidth: .infinity, minHeight: compact ? 38 : 50) }.accessibilityLabel("Текст песни")
                    Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(maxWidth: .infinity, minHeight: compact ? 38 : 50) }.accessibilityLabel("Очередь")
                    Button { feature = .sound } label: { Image(systemName: "slider.vertical.3").frame(maxWidth: .infinity, minHeight: compact ? 38 : 50) }.accessibilityLabel("Эквалайзер")
                }.font(.system(size: compact ? 17 : 20)).nightwellLiquidGlass(compact ? 25 : 32)
    }

    @ViewBuilder private var playerError: some View {
                if !clock.failure.isEmpty { Text(clock.failure).font(.caption).foregroundStyle(Color.white) }
    }
    private func refreshNativeMenu() {
        let selected = clock.displayCurrent
        nativeMenuSnapshot = NightwellPlayerActionSnapshot(
            track: selected,
            clipURL: availableClipTrackID == selected?.id ? availableClipURL : nil,
            playlists: store.playlists,
            recommendationHidden: selected.map { store.isRecommendationHidden($0) } ?? false,
            shareBaseURL: store.origin,
            lyricsVisible: showLyrics,
            coverStyle: coverStyle,
            downloaded: selected.map { store.isDownloaded($0) } ?? false,
            togetherJoined: togetherSession.joined
        )
    }

    private var tools: some View {
        NightwellPlayerNativeMenu(
            snapshot: nativeMenuSnapshot,
            onEqualizer: { feature = .sound },
            onSeededRhythm: { track in
                Task { await store.rhythm(around: track) }
            },
            onLyrics: {
                withAnimation { showLyrics.toggle() }
                refreshNativeMenu()
            },
            onClip: { url, track in
                if let url {
                    NativePlayer.shared.pause()
                    presentedClip = NightwellPresentedClip(url: url, trackTitle: track.title)
                } else {
                    Task {
                        let found = await NightwellClipAvailabilityCache.shared.lookup(
                            track: track, api: store.api, origin: store.origin,
                            accountID: store.account?.id, forceRefresh: true)
                        guard clock.displayCurrent?.id == track.id else { return }
                        guard let found else {
                            clipSearchNotice = true
                            return
                        }
                        availableClipTrackID = track.id
                        availableClipURL = found
                        refreshNativeMenu()
                        NativePlayer.shared.pause()
                        presentedClip = NightwellPresentedClip(url: found, trackTitle: track.title)
                    }
                }
            },
            onHide: { track in
                store.toggleRecommendationHidden(track)
                refreshNativeMenu()
            },
            onDownload: { track in
                Task {
                    if store.isDownloaded(track) {
                        await store.removeDownload(track)
                    } else {
                        await store.download([track])
                    }
                    refreshNativeMenu()
                }
            },
            onEnqueue: { track, next in
                if store.enqueue(track, next: next) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            },
            onAddTogether: { track in
                guard togetherSession.joined else { return }
                Task { await togetherSession.add(trackID: track.id, store: store) }
            },
            onAddPlaylist: { track, list in
                Task { await store.add(track, playlist: list) }
            },
            onQuality: { _ in
                store.audioQualityNotice = "Качество изменится со следующего трека"
                Task { await store.checkAudioQualitySupport() }
            },
            onAnimationChanged: {
                refreshNativeMenu()
            }
        )
        .frame(width: 44, height: 44)
        .nightwellLiquidGlass(24)
        .accessibilityLabel("Действия с треком")
    }
}
func formatTime(_ seconds: Double) -> String { let value = seconds.isFinite ? max(0, Int(seconds)) : 0; return String(format: "%d:%02d", value / 60, value % 60) }

struct PlaybackQueue: View {
    @EnvironmentObject var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var clock: PlaybackClock
    @AppStorage("nw-depth-queue") private var depthQueue = true

    private var currentIndex: Int { clock.queue.firstIndex { $0.id == clock.id } ?? -1 }

    var body: some View {
        GeometryReader { viewport in
            let compact = viewport.size.height < 570
            ZStack {
            // Unified black-and-white gradient across the queue sheet.
            // No separate gray slab behind the album deck.
            LinearGradient(
                stops: [
                    .init(color: Color(white: 0.16), location: 0),
                    .init(color: Color(white: 0.085), location: 0.36),
                    .init(color: Color(white: 0.025), location: 0.76),
                    .init(color: .black, location: 1)
                ],
                startPoint: .topTrailing, endPoint: .bottomLeading
            )
            .ignoresSafeArea()

            VStack(spacing: compact ? 10 : 22) {
                HStack(alignment: .center, spacing: compact ? 8 : 12) {
                    VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                        Text("ТВОЯ МУЗЫКА")
                            .font(.system(size: compact ? 9 : 10, weight: .semibold))
                            .tracking(compact ? 1.6 : 3.2)
                            .foregroundStyle(Color.white.opacity(0.78))
                        Text("Очередь")
                            .font(.system(size: compact ? 28 : 32, weight: .bold))
                            .tracking(-0.7)
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 4)
                    Text("\(clock.queue.count)")
                        .font(.system(size: compact ? 14 : 17, weight: .medium))
                        .monospacedDigit()
                        .frame(width: compact ? 44 : 54, height: compact ? 44 : 54)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.16)))
                        .accessibilityLabel("В очереди \(clock.queue.count) треков")
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: compact ? 44 : 54, height: compact ? 44 : 54)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.16)))
                    }
                    .accessibilityLabel("Закрыть очередь")
                }

                ScrollViewReader { reader in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: compact ? 4 : 10) {
                            if depthQueue {
                                if !clock.queue.isEmpty {
                                    NightwellQueueDeck(
                                        queue: clock.queue,
                                        currentIndex: currentIndex,
                                        origin: store.origin,
                                        compact: compact,
                                        availableHeight: viewport.size.height
                                    )
                                    .padding(.top, compact ? 8 : 20)
                                    .padding(.bottom, compact ? 8 : 24)
                                } else {
                                    Text("Следующих треков пока нет")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 42)
                                }
                            } else {
                                LazyVStack(spacing: 8) {
                                    if clock.queue.isEmpty {
                                        Text("Выбери трек, и здесь появится твоя музыка")
                                            .foregroundStyle(.secondary)
                                            .padding(.vertical, 40)
                                    }
                                    ForEach(Array(clock.queue.enumerated()), id: \.offset) { index, track in
                                        VStack(alignment: .leading, spacing: 8) {
                                            if index == currentIndex {
                                                Text("СЕЙЧАС ИГРАЕТ")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .tracking(2)
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 12)
                                            } else if index == currentIndex + 1 {
                                                Text("ДАЛЬШЕ")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .tracking(2)
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 12)
                                                    .padding(.top, 8)
                                            }
                                            HStack(spacing: 8) {
                                                NativeTrackRow(
                                                    track: track, queue: clock.queue,
                                                    status: clock.status, playlist: nil,
                                                    onPlay: { NativePlayer.shared.playQueueTrackNow(trackID: track.id) }
                                                )
                                                if index > currentIndex + 1 && currentIndex >= 0 {
                                                    Button {
                                                        NativePlayer.shared.playNextFromQueue(at: index)
                                                    } label: {
                                                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                                            .frame(width: 42, height: 42)
                                                            .nightwellLiquidGlass(18)
                                                    }
                                                    .accessibilityLabel("Играть следующим")
                                                }
                                            }
                                            .onLongPressGesture {
                                                if index > currentIndex + 1 {
                                                    NativePlayer.shared.playNextFromQueue(at: index)
                                                }
                                            }
                                        }
                                        .id(index)
                                    }
                                }
                                .padding(.top, 12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, compact ? 8 : 12)
                        .padding(.bottom, compact ? 4 : 18)
                    }
                    .onAppear {
                        if !depthQueue && currentIndex >= 0 {
                            reader.scrollTo(currentIndex, anchor: .top)
                        }
                    }
                }

                // Keep the compact instructions below the scrolling queue,
                // within the sheet's safe area. They must not be clipped
                // by the scroll viewport on the medium detent.
                if compact && depthQueue && !clock.queue.isEmpty {
                    Text("Тап: играть · удержание: следующим\nСвайп: листать очередь")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                        .accessibilityLabel("Тап: играть сейчас. Удержание: следующим. Свайп: листать очередь.")
                }
            }
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.top, compact ? 18 : 30)
            .padding(.bottom, compact ? 12 : 18)
        }
        .tint(.white)
        .foregroundStyle(nightwellText)
        }
    }
}

private struct PlayerLyricsFramePreference: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct NightwellSyncedLyricsRows: View {
    let lines: [Lyrics.Line]
    let position: Double
    let active: Int
    let kinetic: Bool
    let onSeek: (Int, Double) -> Void

    private var repetitionCounts: [String: Int] {
        Dictionary(
            lines.map { ($0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), 1) },
            uniquingKeysWith: +
        )
    }

    var body: some View {
        let counts = repetitionCounts
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Button {
                onSeek(index, line.time)
            } label: {
                NightwellKineticLyricLine(
                    text: line.text,
                    start: line.time,
                    end: index + 1 < lines.count ? lines[index + 1].time : line.time + 4,
                    position: position,
                    active: index == active,
                    enabled: kinetic,
                    chorus: (counts[line.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? 0) >= 2,
                    timedWords: line.words
                )
                .equatable()
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Перейти к строке: " + line.text)
            .id(index)
        }
    }
}

struct LyricsView: View {
    @Environment(\.lyricsPalette) private var artworkColors
    private var artworkGradient: LinearGradient { LinearGradient(colors: artworkColors, startPoint: .leading, endPoint: .trailing) }
    let lyrics: Lyrics?
    let position: Double
    @State private var resumeFollowingAt = Date.distantPast
    @State private var followingPlayback = true
    // A lightweight position poll runs only while the lyrics view is mounted.
    // The regular 500ms player refresh remains unchanged for every other screen.
    @State private var lyricPosition: Double?
    @AppStorage("nw-kinetic-lyrics") private var kineticLyrics = true
    private var currentLyricPosition: Double { lyricPosition ?? position }
    var active: Int { (lyrics?.lines ?? []).lastIndex { $0.time <= currentLyricPosition } ?? -1 }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .center, spacing: 25) {
                    if let lyrics {
                        if lyrics.synced == true, let lines = lyrics.lines {
                            NightwellSyncedLyricsRows(
                                lines: lines,
                                position: currentLyricPosition,
                                active: active,
                                kinetic: kineticLyrics
                            ) { index, time in
                                NativePlayer.shared.seek(max(0, time))
                                followingPlayback = true
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    reader.scrollTo(index, anchor: .center)
                                }
                            }
                        } else {
                            Text(lyrics.plain ?? lyrics.message ?? (lyrics.searching ? "Ищем текст…" : "Текст пока не найден"))
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(10)
                        }
                        Text(lyrics.source ?? "").font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView("Ищем текст…") }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    followingPlayback = false
                    resumeFollowingAt = Date().addingTimeInterval(8)
                }
                .onEnded { _ in
                    followingPlayback = false
                    resumeFollowingAt = Date().addingTimeInterval(8)
                })
            .task(id: resumeFollowingAt) {
                guard resumeFollowingAt > Date() else { return }
                let delay = max(0, resumeFollowingAt.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                followingPlayback = true
            }
            .task {
                // Separate lightweight lyric clock avoids accelerating the
                // whole player UI, artwork, networking and background timers.
                while !Task.isCancelled {
                    let live = NativePlayer.shared.lyricPlaybackPosition()
                    if live.isFinite && live >= 0,
                       lyricPosition == nil || abs(live - (lyricPosition ?? 0)) >= 0.035 {
                        lyricPosition = live
                    }
                    try? await Task.sleep(nanoseconds: 160_000_000)
                }
            }
            .onAppear { if active >= 0 { DispatchQueue.main.async { reader.scrollTo(active, anchor: .center) } } }
            .onChange(of: followingPlayback) { following in
                guard following, active >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.4)) { reader.scrollTo(active, anchor: .center) }
            }
            .onChange(of: active) { next in
                guard next >= 0, followingPlayback else { return }
                withAnimation(.easeInOut(duration: 0.3)) { reader.scrollTo(next, anchor: .center) }
            }
        }
    }
}

struct AuthSheet: View {
    let close: () -> Void
    @EnvironmentObject var store: MusicStore
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var register = false
    @State private var busy = false
    @State private var failure = ""

    private var verifying: Bool { store.emailChallenge != nil }
    private var cannotSubmit: Bool {
        busy || (verifying ? code.count != 6 : email.isEmpty || password.isEmpty)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Image("BrandLogo").resizable().scaledToFit().frame(width: 56, height: 56)
                        Text(verifying ? "Проверь почту" : register ? "Создать аккаунт" : "С возвращением")
                            .font(.system(size: 26, weight: .bold))
                        Text(verifying ? "Введи код из письма Nightwell Music" : register ? "Создай аккаунт Nightwell Music" : "Твоя музыка снова рядом")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 42, height: 42).glass(21)
                    }
                }
                VStack(spacing: 14) {
                    if let challenge = store.emailChallenge {
                        Text("Письмо отправлено на " + challenge.email_hint)
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Код из 6 цифр", text: $code)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.title2.monospacedDigit()).padding(15)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("email-verification-code")
                            .onChange(of: code) { _, value in
                                code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil(challenge.resend_at - context.date.timeIntervalSince1970)))
                            VStack(alignment: .leading, spacing: 10) {
                                Text(context.date.timeIntervalSince1970 < challenge.expires_at
                                     ? "Код действует 10 минут. Если письма нет, проверь спам."
                                     : "Код истёк. Начни вход заново.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button(remaining > 0 ? "Повторить через \(remaining) с" : "Отправить код ещё раз") {
                                    guard !busy else { return }
                                    busy = true
                                    Task {
                                        await store.resendEmailCode()
                                        failure = store.error ?? ""
                                        store.error = nil
                                        code = ""
                                        busy = false
                                    }
                                }.disabled(busy || remaining > 0 || context.date.timeIntervalSince1970 >= challenge.expires_at)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Email").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("name@example.com", text: $email)
                                .keyboardType(.emailAddress).textContentType(.username)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .padding(15).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Пароль").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            SecureField("Пароль", text: $password)
                                .textContentType(register ? .newPassword : .password)
                                .padding(15).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }.disabled(busy).padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 25))
                if !failure.isEmpty {
                    Text(failure).font(.subheadline).foregroundStyle(.white).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                }
                Button {
                    guard !cannotSubmit else { return }
                    busy = true
                    failure = ""
                    Task {
                        let ok: Bool
                        if verifying { ok = await store.confirmEmailCode(code) }
                        else { ok = await store.authenticate(email: email, password: password, register: register) }
                        busy = false
                        if verifying { password = "" }
                        if ok { close() }
                        else { failure = store.error ?? ""; store.error = nil }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().tint(.black) }
                        Text(verifying ? "Подтвердить код" : register ? "Создать аккаунт" : "Войти").font(.headline)
                        Spacer()
                    }.frame(height: 48).foregroundStyle(Color.black)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                }.disabled(cannotSubmit).opacity(cannotSubmit ? 0.5 : 1)
                Button(verifying ? "Изменить данные" : register ? "Уже есть аккаунт? Войти" : "Нет аккаунта? Создать") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if verifying { store.emailChallenge = nil; code = ""; password = "" }
                        else { register.toggle() }
                        failure = ""
                    }
                }.disabled(busy).font(.subheadline.weight(.semibold)).foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
            }.padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 40)
        }.tint(Color.white).onDisappear { store.emailChallenge = nil; code = ""; password = "" }
    }
}

struct NativeSettings: View {
    @State private var feature: PremiumFeatureView.Kind?
    @ObservedObject private var premium = PremiumFeatureState.shared
    let close: () -> Void
    @EnvironmentObject var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nw-transition-seconds") private var transition = 0.0
    @AppStorage("nw-stream-buffer-seconds") private var streamBufferSeconds = 0.0
    @AppStorage("nw-equal-volume") private var equalVolume = 100.0
    @AppStorage("nw-keep-current-until-ready") private var keepCurrentUntilNextReady = true
    @AppStorage("nw-ambient-lyrics") private var ambientLyrics = true
    @AppStorage("nw-ambient-animate-when-paused") private var animatePausedAmbient = true
    @AppStorage("nw-ambient-audio-sensitivity") private var ambientSensitivity = 4.0
    @AppStorage("nw-cover-style") private var coverStyle = "classic"
    @AppStorage("nw-depth-queue") private var depthQueue = true
    @AppStorage("nw-kinetic-lyrics") private var kineticLyrics = true
    @AppStorage(NavigationLayout.storageKey) private var navigationLayout = NavigationLayout.belowPlayer
    @State private var playbackDiagnostics = "Нет данных о запуске"

    private enum SettingsPage: String, CaseIterable {
        case customization = "Кастомизация"
        case playback = "Воспроизведение"
        case appearance = "Оформление"
        case about = "О приложении"

        var icon: String {
            switch self {
            case .customization: return "slider.horizontal.3"
            case .playback: return "waveform"
            case .appearance: return "paintbrush"
            case .about: return "info.circle"
            }
        }
        var subtitle: String {
            switch self {
            case .customization: return "Вкладки, обложки, очередь, текст и фон"
            case .playback: return "Звук, буфер, громкость и офлайн"
            case .appearance: return "Ленты, темы и визуальные эффекты"
            case .about: return "Версия и сведения о сборке"
            }
        }
    }
    @State private var activePage: SettingsPage?
    private var buildCaption: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let number = info["CFBundleVersion"] as? String ?? ""
        let revision = String((info["NWSourceCommit"] as? String ?? "local").prefix(7))
        return "Nightwell Music \(version) (\(number)) · \(revision)"
    }
    @ViewBuilder
    private func pageContents(for page: SettingsPage) -> some View {
        switch page {
        case .customization:
                VStack(alignment: .leading, spacing: 12) {
                    Label("Кастомизация", systemImage: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                    HStack {
                        Text("Вкладки")
                        Spacer(minLength: 8)
                        Picker("Расположение вкладок", selection: $navigationLayout) {
                            ForEach(NavigationLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Расположение вкладок")
                    }
                    .font(.system(size: 14, weight: .medium))
                    Text(navigationLayout.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Стиль обложки в плеере")
                        .font(.system(size: 14, weight: .medium))
                    Picker("Стиль обложки", selection: $coverStyle) {
                        Text("Во весь экран").tag("immersive")
                        Text("Классическая").tag("classic")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Стиль обложки")
                    Text(coverStyle == "classic"
                        ? "Большая квадратная обложка с закруглёнными углами, как в классическом музыкальном плеере."
                        : "Обложка занимает всю высоту экрана, верх и низ плавно переходят в фон.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                    Toggle("Объёмная очередь", isOn: $depthQueue)
                    Text("Стопка обложек следующих песен. Свайпом меняй их порядок, удержанием ставь песню следующей.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Toggle("Кинетический текст песен", isOn: $kineticLyrics)
                    Text("Плавная подсветка слов и строк. Если точных таймкодов слов нет, движение рассчитывается по времени строки.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Toggle("Переливание фона на паузе", isOn: $animatePausedAmbient)
                    Text("Плавный цветной градиент продолжает двигаться, даже если музыка остановлена.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    HStack {
                        Text("Чувствительность активного фона")
                        Spacer()
                        Text(String(format: "%.2fx", ambientSensitivity))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    GlassSlider(value: $ambientSensitivity,
                                range: 0.5...4.0, step: 0.25,
                                accessibilityStep: 0.25,
                                label: "Чувствительность активного фона",
                                valueText: String(format: "%.2fx", ambientSensitivity))
                    Text("Усиливает реакцию на тихие звуки. На паузе работает только плавный градиент.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
        case .playback:
                VStack(alignment: .leading, spacing: 12) {
                    Label("Воспроизведение", systemImage: "waveform").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.white)
                    Toggle("Играть текущий трек до готовности следующего", isOn: $keepCurrentUntilNextReady)
                        .onChange(of: keepCurrentUntilNextReady) { enabled in
                            NativePlayer.shared.setKeepCurrentUntilNextReady(enabled)
                        }
                    Text("При переключении название, исполнитель и обложка меняются сразу. Пока новый трек готовится, предыдущий продолжает звучать. Если выключить, переключение прервёт его сразу.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.50))
                    Toggle("Автоматически скачивать избранное", isOn: Binding(
                        get: { store.automaticFavoritesDownload },
                        set: { store.setAutomaticFavoritesDownload($0) }
                    ))
                    .disabled(store.account == nil)
                    Text((premium.allowed || !premium.entitlementVerified)
                        ? "Новые избранные треки сохраняются для офлайна."
                        : "Новые избранные треки сохраняются для офлайна. Требуется активный Premium.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.50))
                    HStack { Text("Переход между треками"); Spacer(minLength: 4); Text(transition == 0 ? "Выкл." : String(format: "%.1f с", transition)).foregroundStyle(Color.white) }
                    GlassSlider(value: $transition, range: 0...5, step: 0.1, accessibilityStep: 0.1, label: "Переход между треками", valueText: String(format: "%.1f с", transition))
                        .padding(.vertical, 2)
                        .onChange(of: transition) { NativePlayer.shared.transitionDuration($0) }
                    Text("Плавное затухание и нарастание громкости.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.43))
                    HStack {
                        Text("Буфер потока")
                        Spacer(minLength: 4)
                        Text(streamBufferSeconds == 0 ? "Авто" : String(format: "%.0f с", streamBufferSeconds))
                            .foregroundStyle(Color.white)
                    }
                    GlassSlider(value: $streamBufferSeconds, range: 0...12, step: 4,
                                accessibilityStep: 4, label: "Буфер потока",
                                valueText: String(format: "%.0f с", streamBufferSeconds))
                        .onChange(of: streamBufferSeconds) { NativePlayer.shared.setStreamBufferDuration($0) }
                    Text("Меньше буфер: быстрее старт, но выше риск пауз на слабой сети. При обрывах выбери 8 или 12 секунд.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.43))
                    HStack {
                        Text("Одинаковая громкость")
                        Spacer()
                        Text(equalVolume == 0 ? "Выкл." : String(format: "%.0f%%", equalVolume))
                            .foregroundStyle(Color.white)
                    }
                    GlassSlider(value: $equalVolume, range: 0...100, step: 10,
                                accessibilityStep: 10, label: "Одинаковая громкость",
                                valueText: String(format: "%.0f%%", equalVolume))
                        .onChange(of: equalVolume) { NativePlayer.shared.setEqualVolume($0) }
                    Text("Мягко уменьшает громкость более громких треков. На Bluetooth выравнивание становится доступно после анализа записи.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.43))
                    Text("Диагностика: " + playbackDiagnostics)
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        .task {
                            while !Task.isCancelled {
                                playbackDiagnostics = NativePlayer.shared.startupDiagnostics
                                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                                catch { return }
                            }
                        }
                }.padding(16).frame(maxWidth: .infinity, minHeight: 166, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        case .appearance:
                VStack(alignment: .leading, spacing: 8) {
                    Button((premium.allowed || !premium.entitlementVerified) ? "Темы и ленты" : "Темы и ленты · Premium") { feature = .appearance }
                        .sheet(item: $feature) { PremiumFeatureView(kind: $0).environmentObject(store) }
                    Label("Оформление", systemImage: "paintbrush").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.white)
                    Toggle("Текст вместе с лентами", isOn: $ambientLyrics)
                        .onChange(of: ambientLyrics) { enabled in
                            if enabled { store.lyrics.select(store.clock.current, api: store.api, origin: store.origin, online: store.account != nil) }
                        }
                    Text("Строки с таймкодами появляются во время песни.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.43))
                }.padding(16).frame(maxWidth: .infinity, minHeight: 160, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        case .about:
            VStack(alignment: .leading, spacing: 12) {
                Label("О приложении", systemImage: "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                Text(buildCaption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private func categoryRow(_ page: SettingsPage) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { activePage = page }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: page.icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.rawValue)
                        .font(.system(size: 16, weight: .semibold))
                    Text(page.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .foregroundStyle(.white)
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 11) {
                if activePage != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { activePage = nil }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 38, height: 42)
                            .background(.white.opacity(0.055), in: Circle())
                    }
                    .accessibilityLabel("Назад к настройкам")
                }
                Text(activePage?.rawValue ?? "Настройки")
                    .font(.system(size: activePage == nil ? 28 : 23, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .light))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.055), in: Circle())
                }
                .accessibilityLabel("Закрыть настройки")
            }
            .padding(.top, 12)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let page = activePage {
                        pageContents(for: page)
                    } else {
                        ForEach(SettingsPage.allCases, id: \.self) { page in
                            categoryRow(page)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .id(activePage)
        }
        .font(.system(size: 17))
        .padding(20)
        .tint(.white)
    }
}







