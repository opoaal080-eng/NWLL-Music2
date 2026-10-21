import SwiftUI
import Combine

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
    @State private var flashDate = Date.distantPast
    @State private var energy = 0.0
    @State private var frameDate = Date()
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            draw(context: context, size: size, date: frameDate)
        }
        .onChange(of: flash) { _ in flashDate = frameDate }
        .task(id: scene == .active && !reduced) { @MainActor in
            guard scene == .active, !reduced else { return }
            // A fresh frame loop starts on every foreground entry and view appearance.
            // Cancellation stops it when this scene is hidden or the app is inactive.
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = min(0.1, max(0, now - previous))
                previous = now
                let p = premium.preferences
                let bands = NativePlayer.shared.auraLevels()
                let choices = [p.aura_voice, p.aura_low, p.aura_mid, p.aura_high]
                let enabled = premium.allowed ? choices : [true, true, true, true]
                let selected = zip(bands, enabled).compactMap { value, active in active && value.isFinite ? value : nil }
                let raw = selected.isEmpty ? 0 : selected.reduce(0, +) / Double(selected.count)
                let level = min(1, max(0, raw * (premium.allowed ? p.ribbon_intensity : 1)))
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    energy += (level - energy) * (level > energy ? 0.55 : 0.2)
                    // Do not jump through the time spent in the background.
                    frameDate = frameDate.addingTimeInterval(elapsed * (premium.allowed ? premium.preferences.ribbon_speed : 1))
                }
                do { try await Task.sleep(nanoseconds: 33_333_333) }
                catch { return }
            }
        }
        .allowsHitTesting(false)
    }
    private func auraColor(_ phase: Double) -> Color {
        let palette: [(Double, Double, Double)] = [
            (135, 87, 255), (239, 98, 193), (255, 153, 92), (91, 189, 255)
        ]
        let wrapped = (phase.truncatingRemainder(dividingBy: 4) + 4).truncatingRemainder(dividingBy: 4)
        let index = Int(wrapped)
        let fraction = wrapped - Double(index)
        let blend = fraction * fraction * (3 - 2 * fraction)
        let a = palette[index], b = palette[(index + 1) % 4]
        return Color(red: (a.0 + (b.0 - a.0) * blend) / 255,
                     green: (a.1 + (b.1 - a.1) * blend) / 255,
                     blue: (a.2 + (b.2 - a.2) * blend) / 255)
    }
    private func draw(context: GraphicsContext, size: CGSize, date: Date) {
        let t = reduced ? 0 : date.timeIntervalSinceReferenceDate * 0.24
        let burst = max(0, 1 - date.timeIntervalSince(flashDate) / 0.7)
        guard size.width > 1 && size.height > 1 else { return }
        let w = Double(size.width), h = Double(size.height)
        // Three streams emerge from the center and carry their waves beyond the top and sides.
        let cx = w * 0.5, cy = h * 0.54
        for side in 0..<3 {
            let dx = side == 0 ? -w * 0.72 : side == 1 ? w * 0.72 : 0
            let dy = side == 2 ? -h * 0.78 : -h * 0.36
            let length = hypot(dx, dy)
            for band in (0..<18).reversed() {
                let lane = (Double(band) - 8.5) / 17
                var path = Path()
                for step in 0...64 {
                    let u = Double(step) / 64
                    let spread = sin(u * .pi * 0.5)
                    let bend = (sin(u * 9 - t + lane * 3) * (0.045 + energy * 0.045)
                        + lane * 0.26) * min(w, h) * spread
                    let x = cx + dx * u - dy / length * bend
                    let y = cy + dy * u + dx / length * bend
                    let p = CGPoint(x: x, y: y)
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let opacity = min(0.52, (0.11 + energy * 0.20 + burst * 0.12) * (1 - abs(lane) * 0.9))
                let hue = t * 0.4 + Double(side) * 0.8
                let gradient = Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.08),
                    .init(color: auraColor(hue).opacity(opacity), location: 0.3),
                    .init(color: auraColor(hue + 0.6).opacity(opacity), location: 0.68),
                    .init(color: auraColor(hue + 1.2).opacity(opacity), location: 1)
                ])
                context.stroke(path, with: .linearGradient(gradient,
                    startPoint: CGPoint(x: cx, y: cy), endPoint: CGPoint(x: cx + dx, y: cy + dy)),
                               style: StrokeStyle(lineWidth: 8 + Double(band) * 0.68 + energy * 16, lineCap: .round))
            }
        }
    }
}
struct NativeHome: View {
    @State private var waveSettingsPresented = false
    @State private var suppressMixTapUntil = Date.distantPast
    @EnvironmentObject var store: MusicStore
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { box in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("HALLOWEEN EDITION")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(3.4)
                        .foregroundStyle(pumpkin.opacity(0.9))
                    VStack(alignment: .leading, spacing: -2) {
                        Text("Твой")
                        Text("тёмный ритм")
                    }
                    .font(.system(size: min(48, box.size.width * 0.125), weight: .bold))
                    .tracking(-1.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(LinearGradient(colors: [.white, nightwellText, pumpkin.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: nightwellViolet.opacity(0.55), radius: 13)
                }
                .padding(.top, 18)

                VStack(spacing: 24) {
                    Button {
                        if clock.current == nil { Task { await store.wave() } }
                        else { clock.toggle() }
                    } label: {
                        Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(pumpkin)
                            .frame(width: 112, height: 112)
                            .shadow(color: pumpkin.opacity(0.28), radius: 24)
                    }
                    .accessibilityLabel(clock.playing ? "Пауза" : "Воспроизвести")
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        Button { if Date() >= suppressMixTapUntil { Task { await store.wave() } } } label: {
                            HStack(spacing: 7) {
                                if store.loading { ProgressView().tint(pumpkin) }
                                Text(store.loading ? "Подбираем…" : "Новая подборка")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(pumpkin)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .frostedGlass(22)
                        }
                        .disabled(store.loading)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            suppressMixTapUntil = Date().addingTimeInterval(1)
                            waveSettingsPresented = true
                        })
                        .accessibilityHint("Удерживай, чтобы настроить подборку")
                        .accessibilityAction(named: "Настроить подборку") { waveSettingsPresented = true }


                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, max(70, box.size.height * 0.16))
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay {
            if waveSettingsPresented {
                NightwellPopup(title: "", maxHeight: 560, dimsBackground: false, close: { waveSettingsPresented = false }) {
                    NativeWaveSettingsView(close: { waveSettingsPresented = false })
                        .environmentObject(store)
                }
            }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-wave-settings") { waveSettingsPresented = true }
            #endif
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
                        Cover(track: clock.current, origin: store.origin).frame(width: compact ? 44 : 48, height: compact ? 44 : 48).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                        Button { Task { await store.like(track) } } label: { Image(systemName: store.likes.contains(track.id) ? "heart.fill" : "heart").font(.system(size: 16)).foregroundStyle(pumpkin).frame(width: compact ? 26 : 29, height: 44) }.accessibilityLabel("Избранное")
                    }
                    Button { changeTrack(-1) } label: { Image(systemName: "backward.end").font(.system(size: 15)).frame(width: compact ? 24 : 28, height: 44) }.accessibilityLabel("Предыдущий трек")
                    Button { clock.toggle() } label: { Image(systemName: clock.playing ? "pause" : "play.fill").font(.system(size: 17, weight: .light)).frame(width: compact ? 44 : 48, height: compact ? 44 : 48).background(Circle().fill(Color.black.opacity(0.16))).overlay(Circle().stroke(pumpkin.opacity(0.95), lineWidth: 1.5)) }.accessibilityLabel(clock.playing ? "Пауза" : "Воспроизвести")
                    Button { changeTrack(1) } label: { Image(systemName: "forward.end").font(.system(size: 15)).frame(width: compact ? 24 : 28, height: 44) }.accessibilityLabel("Следующий трек")
                }.buttonStyle(.plain)
            }.foregroundStyle(.white) .padding(.horizontal, 14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.ultraThinMaterial).opacity(0.23)
                    LinearGradient(colors: [pumpkin.opacity(0.055), Color.purple.opacity(0.01)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: box.size.width * min(1, max(0, clock.duration > 0 ? clock.position / clock.duration : 0)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.34), pumpkin.opacity(0.34), .white.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1))
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .shadow(color: pumpkin.opacity(glow ? 0.4 : 0), radius: 18)
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
                Capsule().fill(LinearGradient(colors: [pumpkin.opacity(0.65), pumpkin], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * fraction, height: dragging ? 6 : 4)
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.95), pumpkin], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.7))
                    .shadow(color: pumpkin.opacity(dragging ? 0.55 : 0.18), radius: dragging ? 12 : 4)
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

struct FullPlayer: View {
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
            SeasonBackground()
            VStack(spacing: 20) {
                HStack { Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 46, height: 46).nightwellLiquidGlass(24) }; Spacer(); VStack(spacing: 5) { Text("HALLOWEEN EDITION").font(.caption2).tracking(3).foregroundStyle(pumpkin); Text("Играет сейчас").font(.headline) }; Spacer(); tools }
                GeometryReader { box in
                    if showLyrics {
                        SharedLyricsPanel(model: store.lyrics, clock: clock)
                            .id(clock.id)
                            .background { GeometryReader { proxy in Color.clear.preference(key: PlayerLyricsFramePreference.self, value: proxy.frame(in: .global)) } }
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.22)) { showLyrics = false } }
                    } else {
                        Cover(track: clock.current, origin: store.origin)
                            .frame(width: min(box.size.width, box.size.height), height: min(box.size.width, box.size.height))
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
                HStack { VStack(alignment: .leading, spacing: 8) { Text(clock.current?.title ?? "Выбери трек").font(.title2.bold()).lineLimit(2); Text(clock.current?.artist ?? "").font(.body).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if let track = clock.current { Button { Task { await store.like(track) } } label: { Image(systemName: store.likes.contains(track.id) ? "heart.fill" : "heart").font(.title).foregroundStyle(pumpkin) } } }
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        GlassSlider(value: Binding(get: { seeking ? scrub : min(clock.position, clock.duration) }, set: { scrub = $0 }), range: 0...clock.duration, accessibilityStep: 5, label: "Позиция трека", valueText: formatTime(seeking ? scrub : clock.position)) { editing in if editing { scrub = clock.position; seeking = true } else { NativePlayer.shared.seek(scrub); seeking = false } }
                        HStack { Text(formatTime(seeking ? scrub : clock.position)); Spacer(); Text(formatTime(clock.duration)) }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Button { shuffle.toggle(); NativePlayer.shared.modes(repeatMode: repeatMode, shuffle: shuffle) } label: { Image(systemName: "shuffle").foregroundStyle(shuffle ? pumpkin : .secondary) }; Spacer()
                        Button { NativePlayer.shared.step(-1) } label: { Image(systemName: "backward.end") }; Spacer()
                        Button { clock.toggle() } label: { Image(systemName: clock.playing ? "pause" : "play.fill").font(.system(size: 27)).frame(width: 74, height: 74).overlay(Circle().stroke(pumpkin, lineWidth: 1)) }; Spacer()
                        Button { NativePlayer.shared.step(1) } label: { Image(systemName: "forward.end") }; Spacer()
                        Button { repeatMode = (repeatMode + 1) % 3; NativePlayer.shared.modes(repeatMode: repeatMode, shuffle: shuffle) } label: { Image(systemName: repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(repeatMode > 0 ? pumpkin : .secondary) }
                    }.font(.title2)
                    Divider()
                    Button { showQueue = true } label: { HStack { Image(systemName: "list.bullet"); Text("Дальше в очереди"); Spacer(); Text(String(clock.queue.count)).foregroundStyle(.secondary) } }.font(.subheadline)
                }.padding(22).nightwellLiquidGlass(32)
                if !clock.failure.isEmpty { Text(clock.failure).font(.caption).foregroundStyle(pumpkin) }
            }.padding(.horizontal, 22).padding(.vertical, 12)
        }.overlay { NativeFogLayer(active: !showQueue) }.tint(pumpkin)
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
        } label: { Image(systemName: "ellipsis").frame(width: 46, height: 46).nightwellLiquidGlass(24) }
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
                        Text("ТВОЯ МУЗЫКА").font(.system(size: 9, weight: .semibold)).tracking(3).foregroundStyle(pumpkin)
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
                                            .tracking(2).foregroundStyle(pumpkin).padding(.horizontal, 12)
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
        }.tint(pumpkin).foregroundStyle(nightwellText)
    }
}

private struct PlayerLyricsFramePreference: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct LyricsView: View {
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
                                    .foregroundStyle(index == active ? nightwellText : Color.white.opacity(0.27))
                                    .shadow(color: index == active ? nightwellText.opacity(0.32) : .clear, radius: 8)
                                    .shadow(color: index == active ? nightwellViolet : .clear, radius: 22)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .id(index)
                            }
                        } else {
                            Text(lyrics.plain ?? lyrics.message ?? (lyrics.searching ? "Ищем текст…" : "Текст пока не найден"))
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(nightwellText)
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
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var register = false
    @State private var busy = false
    @State private var failure = ""

    var body: some View {
        ZStack {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 9) {
                                Image("BrandLogo").resizable().scaledToFit().frame(width: 56, height: 56)
                                Text(register ? "Создать аккаунт" : "С возвращением")
                                    .font(.system(size: 26, weight: .bold))
                                Text(register ? "Создай аккаунт Nightwell Music" : "Твоя музыка снова рядом")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { close() } label: {
                                Image(systemName: "xmark").font(.headline)
                                    .frame(width: 42, height: 42).glass(21)
                            }
                        }
                        VStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Email").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                TextField("name@example.com", text: $email)
                                    .keyboardType(.emailAddress)
                                    .textContentType(.username)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .padding(15)
                                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Пароль").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                SecureField("Пароль", text: $password)
                                    .textContentType(register ? .newPassword : .password)
                                    .padding(15)
                                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 25))
                        if !failure.isEmpty {
                            Text(failure).font(.subheadline).foregroundStyle(.orange)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                        }
                        Button {
                            guard !busy else { return }
                            busy = true
                            Task {
                                let ok = await store.authenticate(email: email, password: password, register: register)
                                busy = false
                                if ok { close() }
                                else { failure = store.error ?? "Не удалось войти"; store.error = nil }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if busy { ProgressView().tint(.black) }
                                Text(register ? "Создать аккаунт" : "Войти")
                                    .font(.headline)
                                Spacer()
                            }
                            .frame(height: 48)
                            .foregroundStyle(Color.black)
                            .background(pumpkin, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .disabled(busy || email.isEmpty || password.isEmpty)
                        .opacity(busy || email.isEmpty || password.isEmpty ? 0.5 : 1)
                        Button(register ? "Уже есть аккаунт? Войти" : "Нет аккаунта? Создать") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                register.toggle()
                                failure = ""
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(pumpkin)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                }
        }
        .tint(pumpkin)
    }
}

struct NativeSettings: View {
    @State private var feature: PremiumFeatureView.Kind?
    let close: () -> Void
    @EnvironmentObject var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nw-transition-seconds") private var transition = 0.8
    @AppStorage("nw-ambient-lyrics") private var ambientLyrics = true
    private var buildCaption: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let number = info["CFBundleVersion"] as? String ?? ""
        let revision = String((info["NWSourceCommit"] as? String ?? "local").prefix(7))
        return "Nightwell Music \(version) (\(number)) · \(revision)"
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Настройки").font(.system(size: 23, weight: .bold)); Text("Настройки сохраняются в вашем аккаунте.").font(.callout).foregroundStyle(.white.opacity(0.55)) }; Spacer(); Button("Готово") { close() }.font(.system(size: 14, weight: .semibold)).foregroundStyle(pumpkin).padding(.horizontal, 20).frame(height: 44).nightwellLiquidGlass(25) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Темы и ленты · Premium") { feature = .appearance }.sheet(item: $feature) { PremiumFeatureView(kind: $0).environmentObject(store) }
                        Label("Последние 90 дней", systemImage: "chart.bar").font(.headline).foregroundStyle(pumpkin)
                        Toggle("Текст вместе с лентами", isOn: $ambientLyrics)
                            .onChange(of: ambientLyrics) { enabled in
                                if enabled { store.lyrics.select(store.clock.current, api: store.api, origin: store.origin, online: store.account != nil) }
                            }
                        Text("Строки с таймкодами появляются во время песни.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).nightwellLiquidGlass(22)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Воспроизведение", systemImage: "waveform").font(.headline).foregroundStyle(pumpkin)
                        HStack { Text("Переход между треками"); Spacer(); Text(transition == 0 ? "Выкл." : String(format: "%.1f с", transition)).foregroundStyle(pumpkin) }
                        GlassSlider(value: $transition, range: 0...5, step: 0.1, accessibilityStep: 0.1, label: "Переход между треками", valueText: String(format: "%.1f с", transition))
                            .onChange(of: transition) { NativePlayer.shared.transitionDuration($0) }
                        Text("Плавное затухание и нарастание громкости.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).nightwellLiquidGlass(22)
                    Text(buildCaption).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }.padding(.vertical, 4)
            }
            .frame(maxHeight: 440)
        }.padding(20).tint(pumpkin)
            
    }
}



