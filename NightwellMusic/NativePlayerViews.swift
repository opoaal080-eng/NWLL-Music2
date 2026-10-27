import SwiftUI
import Combine
import AVKit
import AVFoundation

struct SeasonBackground: View {
    @ObservedObject private var premium = PremiumFeatureState.shared
    var body: some View {
        GeometryReader { box in
            Image(box.size.width > box.size.height ? "SeasonLandscape" : "SeasonPortrait").resizable().scaledToFill().frame(width: box.size.width, height: box.size.height).clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.2), Color(red: 0.06, green: 0.025, blue: 0.1).opacity(0.48)], startPoint: .top, endPoint: .bottom))
            .overlay(premium.allowed ? themeColor.opacity(0.45) : Color.clear)
        }.ignoresSafeArea().allowsHitTesting(false)
    }
    private var themeColor: Color { switch premium.preferences.theme { case "aurora": return Color(red: 0.04, green: 0.4, blue: 0.28); case "ocean": return Color(red: 0.03, green: 0.22, blue: 0.5); case "sunset": return Color(red: 0.5, green: 0.12, blue: 0.16); default: return .clear } }
}
struct RibbonScene: View {
    @ObservedObject private var premium = PremiumFeatureState.shared
    let playing: Bool
    let flash: Int
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var pulse = 0.0
    // Balanced crossed-beam choreography matching the reference.
    @State private var targets: [CGPoint] = [
        CGPoint(x: 0.76, y: 0.76), CGPoint(x: 0.24, y: 0.76),
        CGPoint(x: 0.88, y: 0.60), CGPoint(x: 0.12, y: 0.60),
        CGPoint(x: 0.76, y: 0.40), CGPoint(x: 0.24, y: 0.40),
        CGPoint(x: 0.90, y: 0.28), CGPoint(x: 0.10, y: 0.28)
    ]
    @State private var lamps = [Double](repeating: 0, count: 8)
    @State private var energy = 0.0
    @State private var frameDate = Date()
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            draw(context: context, size: size, date: frameDate)
        }
        
        .task(id: scene == .active && playing && !reduced) { @MainActor in
            pulse = 0
            energy = 0
            guard scene == .active, playing, !reduced else { return }
            // A fresh frame loop starts on every foreground entry and view appearance.
            // Cancellation stops it when this scene is hidden or the app is inactive.
            // Continuous, multi-band music response with adaptive gain and independent lamp envelopes.
            var adaptive = [Double](repeating: 0.07, count: 4)
            var envelopes = [Double](repeating: 0, count: 8)
            var previousBands = [Double](repeating: 0, count: 4)
            var lastMove = ProcessInfo.processInfo.systemUptime
            var beatBaseline = 0.04
            var previousRhythm = 0.0
            var lastBeat = -10.0
            var beatPeriod = 0.52
            var motionSpeed = 1.0
            var lastAudioSignal = ProcessInfo.processInfo.systemUptime
            var standbyGlow = 0.0
            var desired = targets
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = min(0.1, max(0, now - previous))
                previous = now
                let p = premium.preferences
                let incoming = NativePlayer.shared.auraLevels()
                let choices = [p.aura_voice, p.aura_low, p.aura_mid, p.aura_high]
                let enabled = premium.allowed ? choices : [true, true, true, true]
                let gain = premium.allowed ? max(0.1, p.ribbon_intensity) : 1.0
                var levels = [Double](repeating: 0, count: 4)
                for index in 0..<4 {
                    let sample = index < incoming.count && enabled[index] && incoming[index].isFinite
                        ? max(0, min(1, incoming[index])) : 0
                    // Slowly follow track loudness so quieter songs still illuminate the scene.
                    let follow = 1 - exp(-elapsed / (sample > adaptive[index] ? 1.8 : 7.0))
                    adaptive[index] += (sample - adaptive[index]) * follow
                    let normalized = sample / max(0.045, adaptive[index] * 1.65)
                    levels[index] = min(1, max(0, normalized * gain))
                }
                let overall = levels.reduce(0, +) / 4
                // Audio taps can temporarily stop reporting levels during an otherwise active track.
                // Keep a subtle live stage instead of allowing every light to disappear.
                let hasAudioSignal = incoming.contains { $0.isFinite && $0 > 0.003 }
                if hasAudioSignal { lastAudioSignal = now }
                let signalMissing = now - lastAudioSignal > 0.70
                let standbyTarget = signalMissing ? 0.24 : 0.0
                standbyGlow += (standbyTarget - standbyGlow) * (1 - exp(-elapsed / 0.85))
                // Estimate tempo from low/mid-band transients, not from a fixed animation timer.
                let rhythm = levels[1] * 0.62 + levels[2] * 0.28 + levels[0] * 0.10
                beatBaseline += (rhythm - beatBaseline) * (1 - exp(-elapsed / 0.65))
                let onset = rhythm - previousRhythm
                previousRhythm = rhythm
                if rhythm > 0.10 && onset > 0.055 && rhythm > beatBaseline * 1.12 &&
                    now - lastBeat > 0.22 {
                    let interval = now - lastBeat
                    if interval >= 0.22 && interval <= 1.5 {
                        // Smooth noisy intervals to avoid sudden jumps in stage-light movement.
                        beatPeriod += (interval - beatPeriod) * 0.28
                    }
                    lastBeat = now
                    desired = (0..<8).map { index in
                        let left = index % 2 == 0
                        let row = index / 2
                        let baseX = [0.76, 0.88, 0.76, 0.90][row]
                        let baseY = [0.76, 0.60, 0.40, 0.28][row]
                        let offset = Double.random(in: -0.14...0.14)
                        return CGPoint(x: max(0.12, min(0.88, (left ? baseX : 1 - baseX) + offset)),
                                       y: max(0.20, min(0.85, baseY + Double.random(in: -0.10...0.10)))
                    }
                    lastMove = now
                }
                let rate = min(2.7, max(0.55, 0.52 / beatPeriod))
                let manualSpeed = premium.allowed ? max(0.2, p.ribbon_speed) : 1.0
                let requestedSpeed = manualSpeed * rate * (0.72 + min(0.7, overall))
                motionSpeed += (requestedSpeed - motionSpeed) * (1 - exp(-elapsed / 0.30))
                // For sustained passages without detected beats, move at a tempo-scaled interval.
                if (overall > 0.018 || standbyGlow > 0.04) && now - lastMove > max(0.22, beatPeriod * 1.35) {
                    lastMove = now
                    desired = (0..<8).map { index in
                        let left = index % 2 == 0
                        let row = index / 2
                        let baseX = [0.76, 0.88, 0.76, 0.90][row]
                        let baseY = [0.76, 0.60, 0.40, 0.28][row]
                        let offset = Double.random(in: -0.14...0.14)
                        return CGPoint(x: max(0.12, min(0.88, (left ? baseX : 1 - baseX) + offset)),
                                       y: max(0.20, min(0.85, baseY + Double.random(in: -0.10...0.10)))
                    }
                }
                let blend = 1 - exp(-elapsed * 3.4 * motionSpeed)
                var nextLamps = lamps
                for index in 0..<8 {
                    let bandIndex = [1, 0, 2, 3, 1, 2, 0, 3][index]
                    let band = levels[bandIndex]
                    let attack = max(0, band - previousBands[bandIndex])
                    let target = min(1, max(standbyGlow, band * 0.84 + overall * 0.27 + attack * 0.38))
                    let response = 1 - exp(-elapsed / (target > envelopes[index] ? 0.055 : 0.42))
                    envelopes[index] += (target - envelopes[index]) * response
                    nextLamps[index] = envelopes[index]
                }
                previousBands = levels
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    energy = overall
                    pulse = nextLamps.max() ?? 0
                    lamps = nextLamps
                    targets = zip(targets, desired).map { old, next in
                        CGPoint(x: old.x + (next.x - old.x) * blend,
                                y: old.y + (next.y - old.y) * blend)
                    }
                    // Force Canvas redraw even when sampled audio changes without SwiftUI notifications.
                    frameDate = frameDate.addingTimeInterval(max(elapsed, 0.001))
                }
                do { try await Task.sleep(nanoseconds: 16_666_667) }
                catch { return }
            }
        }
        .allowsHitTesting(false)
    }
    private func draw(context: GraphicsContext, size: CGSize, date: Date) {
        guard playing, !reduced, pulse > 0.001, size.width > 1 && size.height > 1 else { return }
        let w = Double(size.width), h = Double(size.height)
        let intensity = playing ? energy : 0.0
        let ice = Color.white
        for light in 0..<8 {
            let brightness = lamps[light]
            guard brightness > 0.001 else { continue }
            let left = light % 2 == 0
            let row = Double(light / 2)
            let source = CGPoint(x: left ? w * 0.035 : w * 0.965, y: h * (0.14 + row * 0.22))
            let target = CGPoint(x: w * targets[light].x, y: h * targets[light].y)
            let dx = target.x - source.x, dy = target.y - source.y
            let length = max(1, hypot(dx, dy))
            let end = CGPoint(x: source.x + dx / length * h * 0.92, y: source.y + dy / length * h * 0.92)
            // Layered volumetric cone: feathered edges, dense central shaft and drifting haze.
            let perpendicular = CGPoint(x: -dy / length, y: dx / length)
            let time = date.timeIntervalSinceReferenceDate
            let baseWidth = 22.0 + intensity * 17.0
            for layer in 0..<8 {
                let fraction = Double(layer) / 7.0
                let halfWidth = baseWidth * (2.5 - fraction * 2.25)
                let opacity = min(0.38, (0.022 + fraction * 0.028) * brightness)
                let offset = sin(time * 0.38 + Double(light) * 2.3 + fraction * 5.0) * h * 0.004
                let tip = CGPoint(x: end.x + perpendicular.x * offset, y: end.y + perpendicular.y * offset)
                var shaft = Path()
                shaft.move(to: source)
                shaft.addLine(to: CGPoint(x: tip.x + perpendicular.x * halfWidth,
                                         y: tip.y + perpendicular.y * halfWidth))
                shaft.addLine(to: CGPoint(x: tip.x - perpendicular.x * halfWidth,
                                         y: tip.y - perpendicular.y * halfWidth))
                shaft.closeSubpath()
                // A narrow inner shaft gives each beam a realistic focused hotspot.
                if layer == 7 {
                    var core = Path()
                    let narrow = max(1.5, halfWidth * 0.19)
                    core.move(to: source)
                    core.addLine(to: CGPoint(x: tip.x + perpendicular.x * narrow, y: tip.y + perpendicular.y * narrow))
                    core.addLine(to: CGPoint(x: tip.x - perpendicular.x * narrow, y: tip.y - perpendicular.y * narrow))
                    core.closeSubpath()
                    context.fill(core, with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.24 * brightness), .white.opacity(0.11 * brightness), .clear]),
                        startPoint: source, endPoint: tip
                    ))
                }
                context.fill(shaft, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(opacity * 0.85), location: 0),
                        .init(color: ice.opacity(opacity), location: 0.26),
                        .init(color: ice.opacity(opacity * 0.58), location: 0.72),
                        .init(color: .clear, location: 1)
                    ]), startPoint: source, endPoint: tip
                ))
            }
            // Delicate atmospheric wisps, positioned deterministically to avoid flicker.
            for particle in 0..<9 {
                let distance = 0.16 + Double(particle) * 0.079
                let drift = sin(time * 0.55 + Double(particle) * 1.89 + Double(light)) * 10
                let center = CGPoint(x: source.x + dx / length * h * 0.8 * distance + perpendicular.x * drift,
                                     y: source.y + dy / length * h * 0.8 * distance + perpendicular.y * drift)
                let radius = 18.0 + distance * 35
                let haze = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: haze), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.06 * brightness), .clear]),
                    center: center, startRadius: 0, endRadius: radius
                ))
            }
            let halo = CGRect(x: source.x - 14, y: source.y - 14, width: 28, height: 28)
            context.fill(Path(ellipseIn: halo), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.98 * brightness),
                                  ice.opacity(0.55 * brightness), .clear]),
                center: source, startRadius: 0, endRadius: 14
            ))
        }
    }
}

// Quiet decorative stars are independent of the audio engine and playback state.
private struct HomeSparkles: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                guard size.width > 1, size.height > 1 else { return }
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<36 {
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
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { box in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Твой ритм")
                        .font(.system(size: min(48, box.size.width * 0.125), weight: .bold))
                        .tracking(-1.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(.white)
                    Text("Музыка под твоё настроение")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.top, 18)

                VStack(spacing: 24) {
                    Button {
                        if clock.current == nil { Task { await store.wave() } }
                        else { clock.toggle() }
                    } label: {
                        Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 31, weight: .light))
                            .foregroundStyle(Color.white)
                            .frame(width: 88, height: 88)
                            .nightwellLiquidGlass(44)
                            .shadow(color: Color.white.opacity(0.28), radius: 24)
                    }
                    .accessibilityLabel(clock.playing ? "Пауза" : "Воспроизвести")
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        Button { if Date() >= suppressMixTapUntil { Task { await store.wave() } } } label: {
                            HStack(spacing: 7) {
                                if store.loading { ProgressView().tint(Color.white) }
                                Text(store.loading ? "Подбираем…" : "Новая подборка")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .frostedGlass(22, bordered: false, intensity: 0.20)
                        }
                        .disabled(store.loading)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            suppressMixTapUntil = Date().addingTimeInterval(1)
                            configureWave()
                        })
                        .accessibilityHint("Удерживай, чтобы настроить подборку")
                        .accessibilityAction(named: "Настроить подборку") { configureWave() }


                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, max(70, box.size.height * 0.16))
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { HomeSparkles() }
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var store: MusicStore
    @ObservedObject var clock: PlaybackClock
    let open: () -> Void
    @State private var glow = false
    @State private var slideDirection: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        GeometryReader { box in
            let compact = box.size.width < 350
            HStack(spacing: compact ? 8 : 12) {
                Button(action: open) {
                    HStack(spacing: 7) {
                        Cover(track: clock.current, origin: store.origin).frame(width: compact ? 42 : 42, height: compact ? 42 : 42).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clock.current?.title ?? "Выбери трек").font(.system(size: compact ? 12 : 14, weight: .semibold)).lineLimit(1)
                            Text(clock.current?.artist ?? "Nightwell Music").font(.system(size: compact ? 10 : 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(clock.id)
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
                    if let track = clock.current {
                        Button { Task { await store.like(track) } } label: { Image(systemName: store.likes.contains(track.id) ? "heart.fill" : "heart").font(.system(size: 19)).foregroundStyle(Color.white).frame(width: compact ? 26 : 29, height: 44) }.accessibilityLabel("Избранное")
                    }
                    Button { changeTrack(-1) } label: { Image(systemName: "backward.end").font(.system(size: 15)).frame(width: compact ? 24 : 28, height: 44) }.accessibilityLabel("Предыдущий трек")
                    Button { clock.toggle() } label: { Image(systemName: clock.playing ? "pause" : "play.fill").font(.system(size: 17, weight: .light)).frame(width: compact ? 42 : 42, height: compact ? 42 : 42).background(Circle().fill(Color.black.opacity(0.16))).overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1.5)) }.accessibilityLabel(clock.playing ? "Пауза" : "Воспроизвести")
                    Button { changeTrack(1) } label: { Image(systemName: "forward.end").font(.system(size: 15)).frame(width: compact ? 24 : 28, height: 44) }.accessibilityLabel("Следующий трек")
                }.buttonStyle(.plain)
            }.foregroundStyle(.white) .padding(.horizontal, 14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.ultraThinMaterial).opacity(0.23)
                    LinearGradient(colors: [Color.white.opacity(0.055), Color.purple.opacity(0.01)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: box.size.width * min(1, max(0, clock.duration > 0 ? clock.position / clock.duration : 0)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.34), Color.white.opacity(0.34), .white.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1))
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .shadow(color: Color.white.opacity(glow ? 0.4 : 0), radius: 18)
        }.frame(height: 68)
        .animation(reduced ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: clock.id)
        .task(id: clock.id) { guard !reduced else { return }; glow = true; try? await Task.sleep(nanoseconds: 80_000_000); guard !Task.isCancelled else { return }; withAnimation(.easeOut(duration: 0.9)) { glow = false } }
        // Swipe wins over the artwork/title tap, so it never opens the full player.
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
                Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.65), Color.white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * fraction, height: dragging ? 6 : 4)
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.95), Color.white], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.7))
                    .shadow(color: Color.white.opacity(dragging ? 0.55 : 0.18), radius: dragging ? 12 : 4)
                    .scaleEffect(dragging ? 1.22 : 1)
                    .offset(x: width * fraction - 9)
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
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let original = UIImage(data: data) else { return }
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

struct FullPlayer: View {
    @State private var artworkTextColors: [Color] = [.white, .white]
    @EnvironmentObject var store: MusicStore
    @ObservedObject var clock: PlaybackClock
    @Environment(\.dismiss) private var dismiss
    @State private var lyricsFrame = CGRect.zero
    @State private var showLyrics = false
    @State private var feature: PremiumFeatureView.Kind?
    @State private var showQueue = false
    @State private var seeking = false
    @State private var scrub = 0.0
    @State private var repeatMode = 0
    @State private var shuffle = false
    var body: some View {
        ZStack {
            // Neutral home-style backdrop instead of the seasonal Halloween illustration.
            Color.black.ignoresSafeArea()
            ArtworkColorBackground(url: clock.current?.cover_url.flatMap { URL(string: $0, relativeTo: store.origin) })
                .ignoresSafeArea()
                .allowsHitTesting(false)
            HomeSparkles()
                .ignoresSafeArea()
            VStack(spacing: 14) {
                HStack { Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44).nightwellLiquidGlass(24) }; Spacer(); NightwellAudioOutputControl(); Spacer(); tools }
                GeometryReader { box in
                    if showLyrics {
                        SharedLyricsPanel(model: store.lyrics, clock: clock)
                            .id(clock.id)
                            .background { GeometryReader { proxy in Color.clear.preference(key: PlayerLyricsFramePreference.self, value: proxy.frame(in: .global)) } }
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.22)) { showLyrics = false } }
                    } else {
                        Cover(track: clock.current, origin: store.origin)
                            .frame(width: min(box.size.width, box.size.height) * 0.9, height: min(box.size.width, box.size.height) * 0.9)
                            .clipShape(RoundedRectangle(cornerRadius: 26))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.22)) { showLyrics = true } }
                            .gesture(DragGesture(minimumDistance: 18).onEnded { value in
                                let dx = value.translation.width
                                if abs(dx) > 52 && abs(dx) > abs(value.translation.height) * 1.15 {
                                    NativePlayer.shared.step(dx < 0 ? 1 : -1)
                                }
                            })
                    }
                }
                HStack { VStack(alignment: .leading, spacing: 8) { Text(clock.current?.title ?? "Выбери трек").font(.system(size: 20, weight: .bold)).lineLimit(2); Text(clock.current?.artist ?? "").font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if let track = clock.current { Button { Task { await store.like(track) } } label: { Image(systemName: store.likes.contains(track.id) ? "heart.fill" : "heart").font(.system(size: 20)).foregroundStyle(store.likes.contains(track.id) ? Color.white : .white).frame(width: 44, height: 44).nightwellLiquidGlass(24) } } }
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        GlassSlider(value: Binding(get: { seeking ? scrub : min(clock.position, clock.duration) }, set: { scrub = $0 }), range: 0...clock.duration, accessibilityStep: 5, label: "Позиция трека", valueText: formatTime(seeking ? scrub : clock.position)) { editing in if editing { scrub = clock.position; seeking = true } else { NativePlayer.shared.seek(scrub); seeking = false } }
                        HStack { Text(formatTime(seeking ? scrub : clock.position)); Spacer(); Text("−" + formatTime(max(0, clock.duration - (seeking ? scrub : clock.position)))) }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Button { shuffle.toggle(); NativePlayer.shared.modes(repeatMode: repeatMode, shuffle: shuffle) } label: { Image(systemName: "shuffle").foregroundStyle(shuffle ? Color.white : .secondary) }; Spacer()
                        Button { NativePlayer.shared.step(-1) } label: { Image(systemName: "backward.end") }; Spacer()
                        Button { clock.toggle() } label: { Image(systemName: clock.playing ? "pause" : "play.fill").font(.system(size: 25)).frame(width: 68, height: 68).nightwellLiquidGlass(34) }; Spacer()
                        Button { NativePlayer.shared.step(1) } label: { Image(systemName: "forward.end") }; Spacer()
                        Button { repeatMode = (repeatMode + 1) % 3; NativePlayer.shared.modes(repeatMode: repeatMode, shuffle: shuffle) } label: { Image(systemName: repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(repeatMode > 0 ? Color.white : .secondary) }
                    }.font(.system(size: 20))
                }
                HStack {
                    Button { withAnimation { showLyrics.toggle() } } label: { Image(systemName: "text.bubble").frame(maxWidth: .infinity, minHeight: 50) }.accessibilityLabel("Текст песни")
                    Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(maxWidth: .infinity, minHeight: 50) }.accessibilityLabel("Очередь")
                    Button { feature = .sound } label: { Image(systemName: "slider.vertical.3").frame(maxWidth: .infinity, minHeight: 50) }.accessibilityLabel("Эквалайзер")
                }.font(.system(size: 20)).nightwellLiquidGlass(32)
                if !clock.failure.isEmpty { Text(clock.failure).font(.caption).foregroundStyle(Color.white) }
            }.padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 4)
        }.tint(Color.white)
        .environment(\.lyricsPalette, artworkTextColors)
        .onPreferenceChange(ArtworkPaletteKey.self) { colors in
            artworkTextColors = colors.isEmpty ? [.white, .white] : colors
        }
        .onPreferenceChange(PlayerLyricsFramePreference.self) { lyricsFrame = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
            // Keep scrubbing, horizontal track changes and lyric scrolling independent.
            guard !seeking, !showQueue else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            guard dy > 95, dy > abs(dx) * 1.45 else { return }
            // A swipe beginning in synchronized lyrics belongs to the lyrics scroller.
            if showLyrics && lyricsFrame.contains(value.startLocation) { return }
            withAnimation(.easeOut(duration: 0.24)) { dismiss() }
        })
        .onAppear {
            let modes = NativePlayer.shared.snapshot(includeQueue: false)
            repeatMode = modes["repeat"] as? Int ?? 0; shuffle = modes["shuffle"] as? Bool ?? false
            if store.lyrics.value == nil || store.lyrics.value?.status == "error" || store.lyrics.value?.status == "unavailable" {
                store.lyrics.select(clock.current, api: store.api, origin: store.origin, online: store.account != nil)
            }
        }
        .sheet(item: $feature) { PremiumFeatureView(kind: $0).environmentObject(store) }
        .sheet(isPresented: $showQueue) {
            PlaybackQueue(clock: clock)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
        }
    }
    private var tools: some View {
        Menu {
            Button("Эквалайзер", systemImage: "slider.vertical.3") { feature = .sound }
            Button(showLyrics ? "Обложка" : "Текст песни", systemImage: "text.alignleft") { showLyrics.toggle() }
            if let track = clock.current {
                Button("Скачать", systemImage: "arrow.down.to.line") { Task { await store.download([track]) } }
                ShareLink(item: store.origin.appendingPathComponent("track/" + track.id)) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                Menu("Добавить в плейлист") { ForEach(store.playlists) { p in Button(p.name) { Task { await store.add(track, playlist: p) } } } }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).nightwellLiquidGlass(24) }
    }
}
func formatTime(_ seconds: Double) -> String { let value = seconds.isFinite ? max(0, Int(seconds)) : 0; return String(format: "%d:%02d", value / 60, value % 60) }

struct PlaybackQueue: View {
    @EnvironmentObject var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var clock: PlaybackClock

    private var currentIndex: Int { clock.queue.firstIndex { $0.id == clock.id } ?? -1 }
    var body: some View {
        ZStack {
            SeasonBackground().blur(radius: 22)
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ТВОЯ МУЗЫКА").font(.system(size: 9, weight: .semibold)).tracking(3).foregroundStyle(Color.white)
                        Text("Очередь").font(.system(size: 23, weight: .bold))
                    }
                    Spacer()
                    Text("\(clock.queue.count)").font(.subheadline.monospacedDigit())
                        .padding(10).nightwellLiquidGlass(20)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 42, height: 42).nightwellLiquidGlass(24)
                    }.accessibilityLabel("Закрыть очередь")
                }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if clock.queue.isEmpty {
                                Text("Выбери трек — здесь появится твоя музыка")
                                    .foregroundStyle(.secondary).padding(.vertical, 40)
                            }
                            ForEach(Array(clock.queue.enumerated()), id: \.offset) { index, track in
                                VStack(alignment: .leading, spacing: 8) {
                                    if index == currentIndex {
                                        Text("СЕЙЧАС ИГРАЕТ").font(.system(size: 9, weight: .semibold))
                                            .tracking(2).foregroundStyle(Color.white).padding(.horizontal, 12)
                                    } else if index == currentIndex + 1 {
                                        Text("ДАЛЬШЕ").font(.system(size: 9, weight: .semibold))
                                            .tracking(2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
                                    }
                                    NativeTrackRow(track: track, queue: clock.queue, status: clock.status, playlist: nil)
                                }.id(index)
                            }
                        }.padding(12)
                    }
                    .nightwellLiquidGlass(28)
                    .onAppear { if currentIndex >= 0 { reader.scrollTo(currentIndex, anchor: .top) } }
                }
            }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 18)
        }.tint(Color.white).foregroundStyle(nightwellText)
    }
}

private struct PlayerLyricsFramePreference: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct LyricsView: View {
    @Environment(\.lyricsPalette) private var artworkColors
    private var artworkGradient: LinearGradient { LinearGradient(colors: artworkColors, startPoint: .leading, endPoint: .trailing) }
    let lyrics: Lyrics?
    let position: Double
    @State private var resumeFollowingAt = Date.distantPast
    @State private var followingPlayback = true
    var active: Int { (lyrics?.lines ?? []).lastIndex { $0.time <= position } ?? -1 }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: true) {
                VStack(alignment: .center, spacing: 25) {
                    if let lyrics {
                        if lyrics.synced == true, let lines = lyrics.lines {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line.text)
                                    .font(.system(size: index == active ? 32 : 26, weight: .bold, design: .rounded))
                                    .foregroundStyle(artworkGradient)
                                    .opacity(index == active ? 1 : 0.4)
                                    .shadow(color: index == active ? nightwellText.opacity(0.32) : .clear, radius: 8)
                                    .shadow(color: index == active ? nightwellViolet : .clear, radius: 22)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .id(index)
                            }
                        } else {
                            Text(lyrics.plain ?? lyrics.message ?? (lyrics.searching ? "Ищем текст…" : "Текст пока не найден"))
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(artworkGradient)
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
    let close: () -> Void
    @EnvironmentObject var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nw-transition-seconds") private var transition = 1.5
    @AppStorage("nw-ambient-lyrics") private var ambientLyrics = true
    private var buildCaption: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let number = info["CFBundleVersion"] as? String ?? ""
        let revision = String((info["NWSourceCommit"] as? String ?? "local").prefix(7))
        return "Nightwell Music \(version) (\(number)) · \(revision)"
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Настройки").font(.system(size: 28, weight: .bold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.white).frame(width: 42, height: 42).background(.white.opacity(0.05), in: Circle())
                }.accessibilityLabel("Закрыть настройки")
            }.padding(.top, 12)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Темы и ленты · Premium") { feature = .appearance }
                            .sheet(item: $feature) { PremiumFeatureView(kind: $0).environmentObject(store) }
                        Label("Оформление", systemImage: "paintbrush").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.white)
                        Toggle("Текст вместе с лентами", isOn: $ambientLyrics)
                            .onChange(of: ambientLyrics) { enabled in
                                if enabled { store.lyrics.select(store.clock.current, api: store.api, origin: store.origin, online: store.account != nil) }
                            }
                        Text("Строки с таймкодами появляются во время песни.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.43))
                    }.padding(16).frame(maxWidth: .infinity, minHeight: 160, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Воспроизведение", systemImage: "waveform").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.white)
                        HStack { Text("Переход между треками"); Spacer(minLength: 4); Text(transition == 0 ? "Выкл." : String(format: "%.1f с", transition)).foregroundStyle(Color.white) }
                        GlassSlider(value: $transition, range: 0...5, step: 0.1, accessibilityStep: 0.1, label: "Переход между треками", valueText: String(format: "%.1f с", transition))
                            .padding(.vertical, 2)
                            .onChange(of: transition) { NativePlayer.shared.transitionDuration($0) }
                        Text("Плавное затухание и нарастание громкости.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.43))
                    }.padding(16).frame(maxWidth: .infinity, minHeight: 166, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    Text(buildCaption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity)
                }.padding(.vertical, 2)
            }
        }.font(.system(size: 17)).padding(20).tint(Color.white)

    }
}







