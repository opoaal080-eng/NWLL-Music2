import SwiftUI
import UniformTypeIdentifiers

@main struct NightwellMusicApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @StateObject private var store = MusicStore()
    @AppStorage("nw-first-run-completed-v1") private var firstRunCompleted = false
    var body: some Scene {
        WindowGroup {
            Group {
                if firstRunCompleted { NativeRoot() }
                else { NightwellFirstLaunch { firstRunCompleted = true } }
            }
            .environmentObject(store).preferredColorScheme(.dark)
        }
    }
}
enum DeepLink {
    static func trackID(from url: URL) -> String? {
        let host = url.host?.lowercased()
        guard (url.scheme == "https" && host == "music.nightwell.fun")
            || (url.scheme == "nightwell" && host == "track") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let id: String?
        if url.scheme == "nightwell" { id = parts.count == 1 ? parts[0] : nil }
        else { id = parts.count == 2 && parts[0] == "track" ? parts[1] : nil }
        guard let id, id.count == 32, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return id
    }
}
enum ServerAddress {
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool { a.scheme == "https" && b.scheme == "https" && a.host == b.host && (a.port ?? 443) == (b.port ?? 443) && b.user == nil && b.password == nil }
    static func validated(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme == "https", let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        parts.path = "/"; return parts.url
    }
}
let pumpkin = Color.white
let nightwellViolet = Color(red: 0.075, green: 0.075, blue: 0.085)
let nightwellText = Color.white
extension View {
    func glass(_ radius: CGFloat = 30) -> some View {
        self
            .padding(.horizontal, 0)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), pumpkin.opacity(0.12), nightwellViolet.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
                    LinearGradient(colors: [Color.white.opacity(0.45), pumpkin.opacity(0.30), nightwellText.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// iOS 26+ system Liquid Glass, with a translucent fallback on older versions.
extension View {
    @ViewBuilder func nightwellLiquidGlass(_ radius: CGFloat = 30) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.glass(radius)
        }
        #else
        self.glass(radius)
        #endif
    }
}
// Shared with the mini-player: only the background is translucent.
struct NativeBackdropBlur: UIViewRepresentable {
    var intensity: CGFloat = 1
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        guard context.coordinator.intensity != intensity else { return }
        let coordinator = context.coordinator
        coordinator.intensity = intensity
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            coordinator.apply(to: view)
        }
    }
    final class Coordinator {
        var intensity: CGFloat = -1
        private var animator: UIViewPropertyAnimator?
        func apply(to view: UIVisualEffectView) {
            animator?.stopAnimation(true)
            let effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            guard intensity < 1 else { view.effect = effect; animator = nil; return }
            view.effect = nil
            let animation = UIViewPropertyAnimator(duration: 1, curve: .linear) { view.effect = effect }
            animation.pausesOnCompletion = true
            animation.fractionComplete = min(1, max(0, intensity))
            animator = animation
        }
        deinit { animator?.stopAnimation(true) }
    }
}
struct FrostedSurface: View {
    var radius: CGFloat = 30
    var intensity: CGFloat = 1
    var body: some View {
        NativeBackdropBlur(intensity: intensity)
            .overlay(
                LinearGradient(
                    colors: [Color.white.opacity(0.06), nightwellViolet.opacity(0.12), pumpkin.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func frostedGlass(_ radius: CGFloat = 30, bordered: Bool = true, intensity: CGFloat = 1) -> some View {
        self
            .background { FrostedSurface(radius: radius, intensity: intensity) }
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
                        LinearGradient(colors: [.white.opacity(0.36), pumpkin.opacity(0.28), .white.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct NightwellPopup<Content: View>: View {
    let title: String
    var maxHeight: CGFloat = 600
    var dimsBackground = true
    var centered = false
    var transparentSettings = false
    let close: () -> Void
    let content: Content
    init(title: String, maxHeight: CGFloat = 560, dimsBackground: Bool = true, centered: Bool = false, transparentSettings: Bool = false, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.maxHeight = maxHeight
        self.dimsBackground = dimsBackground
        self.centered = centered
        self.transparentSettings = transparentSettings
        self.close = close
        self.content = content()
    }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: centered ? .center : .bottom) {
                Color.black.opacity(dimsBackground ? 0.18 : 0.001).ignoresSafeArea()
                    .onTapGesture(perform: close)
                content
                    .frame(width: max(0, proxy.size.width - 40))
                    .frame(height: min(maxHeight, proxy.size.height * 0.88))
                    .frostedGlass(32, bordered: !transparentSettings, intensity: transparentSettings ? 0.28 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .overlay {
                        if !transparentSettings {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .stroke(.white.opacity(0.16), lineWidth: 1)
                        }
                    }
                    .shadow(color: nightwellViolet.opacity(transparentSettings ? 0 : 0.55), radius: 34, y: 14)
                    .padding(.bottom, centered ? 0 : 20)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .zIndex(100)
    }
}


private enum StableNavigationAction {
    case screen(MusicStore.Screen)
    case backgroundOnly, statistics, premium, transfer, settings, waveSettings, support, authentication
}

/// An independently presented, stable scroll view. Playback updates cannot
/// re-create the menu or send it back to its first item.
private struct StableNavigationSheet: View {
    let status: String
    let signedIn: Bool
    let select: (StableNavigationAction) -> Void
    @Environment(\.dismiss) private var dismiss

    private func choose(_ action: StableNavigationAction) {
        // Parent will dismiss and deliver the navigation event in onDismiss.
        select(action)
    }
    private func entry(_ title: String, icon: String, action: StableNavigationAction) -> some View {
        Button { choose(action) } label: {
            HStack(spacing: 15) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 25)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.35))
            }
            .foregroundStyle(.white)
            .frame(minHeight: 48)
            .padding(.horizontal, 16)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Меню").font(.system(size: 24, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 42, height: 42)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .accessibilityLabel("Закрыть меню")
            }
            .padding(.horizontal, 20).padding(.top, 24)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Label("Nightwell · " + status, systemImage: status == "Онлайн" ? "wifi" :
                          status == "Загрузка…" ? "arrow.triangle.2.circlepath" : "wifi.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(status == "Онлайн" ? .green :
                                         status == "Ограничен" ? .orange : .white.opacity(0.65))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                    if !signedIn {
                        entry("Войти", icon: "person.crop.circle", action: .authentication)
                        entry("Главная", icon: "house", action: .screen(.home))
                        entry("Настройки", icon: "gearshape", action: .settings)
                    } else {
                        entry("Главная", icon: "house", action: .screen(.home))
                        entry("Избранное", icon: "heart", action: .screen(.likes))
                        entry("Плейлисты", icon: "music.note.list", action: .screen(.playlists))
                        entry("Офлайн", icon: "arrow.down.to.line", action: .screen(.offline))
                        Divider().overlay(.white.opacity(0.16)).padding(.vertical, 6)
                        entry("Моя статистика", icon: "chart.bar", action: .statistics)
                        entry("Nightwell Premium", icon: "star", action: .premium)
                        entry("Настройки", icon: "gearshape", action: .settings)
                        entry("Обращения и поддержка", icon: "envelope", action: .support)
                        entry("Выйти", icon: "rectangle.portrait.and.arrow.right", action: .authentication)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(430), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(red: 0.055, green: 0.055, blue: 0.065))
    }
}

private struct CollectionScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NightwellLibraryScrollTracker: ViewModifier {
    @Binding var collapsed: Bool

    // iOS 18+: read the real UIScrollView geometry. A zero-height
    // GeometryReader/PreferenceKey alone can stay at 0 on recent SwiftUI.
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                // Preserve the compact heading until the large one has fully
                // returned. Hysteresis avoids alternating headers at the top.
                if collapsed {
                    if offset <= 0.5 { collapsed = false }
                } else if offset >= 12 {
                    collapsed = true
                }
            }
        } else {
            content.onPreferenceChange(CollectionScrollOffsetKey.self) { value in
                if collapsed {
                    if value >= -0.5 { collapsed = false }
                } else if value <= -12 {
                    collapsed = true
                }
            }
        }
    }
}

struct NativeRoot: View {
    @EnvironmentObject var store: MusicStore
    @State private var feature: PremiumFeatureView.Kind?
    @State private var settings = false
    @State private var navigationMenuPresented = false
    @State private var pendingNavigation: StableNavigationAction?
    @State private var waveSettingsPresented = false
    @State private var supportPresented = false
    @State private var premiumPresented = false
    @State private var transferPresented = false
    @State private var favoriteSort = "recent"
    @State private var collectionScrolled = false
    @StateObject private var artworkPalette = NightwellArtworkPalette()
    @State private var remoteHomeCollapsed = false
    @ObservedObject private var favoritePremium = PremiumFeatureState.shared
    @State private var fullPlayer = false
    @State private var selectedArtist: ArtistSelection?
    @State private var sharedLinkID: String?
    @State private var backgroundOnly = false
    @State private var importFiles = false
    @State private var selectedPlaylist: Playlist?
    @State private var playlistName = ""
    @State private var createPlaylist = false
    @State private var shareText: String?
    @State private var showShare = false
    @State private var launching = true
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ViewBuilder private var mainScene: some View {
        GeometryReader { viewport in
            let landscape = viewport.size.width > viewport.size.height * 1.12 &&
                viewport.size.height < 650
            ZStack {
            // Shared monochrome background for Home, Search, Favorites, Playlists and Offline.
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.062, blue: 0.074), Color(white: 0.025), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            if !backgroundOnly {
                // Keep one backdrop alive while the app changes tabs, pauses,
                // buffers audio, and restores a session after launch.
                RibbonScene(playing: store.clock.playing, flash: store.likeFlash)
                    .ignoresSafeArea()
                    .opacity(store.screen == .home ? 1.0 : 0.18)
                    .allowsHitTesting(false)
            }
            if backgroundOnly { BackgroundOnlyScene(clock: store.clock, lyrics: store.lyrics, flash: store.likeFlash) }
            if backgroundOnly {
                VStack { HStack { Button { backgroundOnly = false } label: { Image(systemName: "xmark").padding().glass() }; Spacer() }; Spacer() }.padding()
            } else {
                VStack(spacing: landscape ? 7 : 18) {
                    header
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.connectionStatus == "Онлайн" ? Color.green :
                                  store.connectionStatus == "Ограничен" ? Color.orange : Color.gray)
                            .frame(width: 6, height: 6)
                        Text("Nightwell · \(store.connectionStatus)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer()
                    }
                    .accessibilityLabel("Подключение Nightwell: \(store.connectionStatus)")
                    .padding(.horizontal, 22)
                    if store.hasRemotePlayback && compactCollectionTitle == nil && !(store.screen == .home && remoteHomeCollapsed) {
                        Button {
                            Task { await store.continuePlaybackHere() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "iphone.and.arrow.forward")
                                Text("Музыка играет на другом устройстве · Продолжить здесь")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                        }
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    content
                    MiniPlayer(clock: store.clock, open: { fullPlayer = true })
                        .padding(.horizontal, 16)
                        .padding(.bottom, landscape ? 4 : 18)
                        .overlay(alignment: .bottom) {
                            if store.screen == .home && !landscape {
                                HomeLyricLine(model: store.lyrics, clock: store.clock)
                                    .saturation(0)
                                    .frame(height: 60)
                                    .padding(.horizontal, 24)
                                    .offset(y: -85)
                            }
                        }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        }
    }

    @ViewBuilder private var modalScene: some View {
            if store.authPresented {
                NightwellPopup(title: "", close: { store.authPresented = false }) {
                    AuthSheet(close: { store.authPresented = false })
                }
            } else if supportPresented {
                NightwellPopup(title: "", maxHeight: 618, dimsBackground: false, centered: true, close: { supportPresented = false }) {
                    NativeSupportView(close: { supportPresented = false })
                        .environmentObject(store)
                }
            } else if waveSettingsPresented {
                NightwellPopup(title: "", maxHeight: 554, dimsBackground: false, centered: true, close: { waveSettingsPresented = false }) {
                    NativeWaveSettingsView(close: { waveSettingsPresented = false })
                        .environmentObject(store)
                }
            } else if settings {
                NightwellPopup(title: "", maxHeight: 554, dimsBackground: false, centered: true, transparentSettings: true, close: { settings = false }) {
                    NativeSettings(close: { settings = false })
                }
            } else if let playlist = selectedPlaylist {
                NightwellPopup(title: "", maxHeight: 618, dimsBackground: false, centered: true, transparentSettings: true, close: { selectedPlaylist = nil }) {
                    PlaylistScreen(close: { selectedPlaylist = nil }, playlist: playlist)
                        .id(playlist.id)
                }
            }
    }

    var body: some View {
        mainScene
            .environmentObject(artworkPalette)
            .overlay { modalScene }
            .task(id: store.clock.current?.id) {
                await artworkPalette.refresh(track: store.clock.current, origin: store.origin)
            }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: settings)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: store.authPresented)
        .tint(pumpkin)
        .sheet(isPresented: $navigationMenuPresented, onDismiss: {
            guard let destination = pendingNavigation else { return }
            pendingNavigation = nil
            openNavigation(destination)
        }) {
            StableNavigationSheet(status: store.connectionStatus, signedIn: store.account != nil) { action in
                pendingNavigation = action
                navigationMenuPresented = false
            }
            .environmentObject(store)
        }
        .sheet(item: $feature) { kind in
            PremiumFeatureView(kind: kind).environmentObject(store)
        }
        .sheet(isPresented: $premiumPresented) { PremiumView(api: store.api) }
        .overlay { if launching { MonochromeNightwellLaunch().transition(.opacity) } }
        .task { try? await Task.sleep(nanoseconds: reducedMotion ? 150_000_000 : 1_200_000_000); withAnimation(.easeOut(duration: 0.3)) { launching = false } }
        // Async task is cancelled automatically if the offer disappears or
        // the user changes screens. No timers survive when the Home page closes.
        .task(id: store.hasRemotePlayback && store.screen == .home) {
            guard store.hasRemotePlayback, store.screen == .home else {
                remoteHomeCollapsed = false
                return
            }
            remoteHomeCollapsed = false
            do { try await Task.sleep(nanoseconds: 8_000_000_000) }
            catch { return }
            guard !Task.isCancelled, store.hasRemotePlayback, store.screen == .home else { return }
            withAnimation(reducedMotion ? nil : .spring(response: 0.48, dampingFraction: 0.82)) {
                remoteHomeCollapsed = true
            }
        }
        .animation(reducedMotion ? nil : .spring(response: 0.48, dampingFraction: 0.82),
                   value: remoteHomeCollapsed)
        .onChange(of: store.account?.id) { _ in Task { await store.refreshProfile() } }
        .task { await store.start()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-focus") { backgroundOnly = true }
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-settings") { settings = true }
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-wave-settings") { waveSettingsPresented = true }
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-support") { supportPresented = true }
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-premium") { premiumPresented = true }
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-statistics") { feature = .statistics }
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-auth") { store.authPresented = true }
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-playlist") { selectedPlaylist = Playlist(id: "native-preview", name: "Твоя ночная подборка") }
            #endif
        }
        .animation(reducedMotion ? nil : .easeInOut(duration: 0.22), value: store.screen)
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
            let dx = gesture.translation.width
            let dy = gesture.translation.height
            if gesture.startLocation.x < 24 && dx > 90 && abs(dy) < 60 {
                store.screen = .home
            }
        })
        .onChange(of: store.screen) { _ in
            collectionScrolled = false
            if store.screen != .search { store.leaveSearch() }
        }
        .onOpenURL { openSharedURL($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { openSharedURL(url) }
        }
        .onChange(of: store.clock.id) { id in
            if let expected = sharedLinkID, id.lowercased() == expected.lowercased() {
                sharedLinkID = nil
                fullPlayer = true
            }
        }
        .fullScreenCover(isPresented: $fullPlayer) { FullPlayer(clock: store.clock) }
        .sheet(item: $selectedArtist) { artist in
            ArtistProfileView(name: artist.name).environmentObject(store)
        }
        
        .sheet(isPresented: $transferPresented) { NightwellNativeTransfer().environmentObject(store) }
        .sheet(isPresented: $showShare) { if let shareText { ShareSheet(items: [shareText]) } }
        .fileImporter(isPresented: $importFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await store.importFiles(urls) } }
        }
        .alert("Новый плейлист", isPresented: $createPlaylist) { TextField("Название", text: $playlistName); Button("Создать") { Task { await store.createPlaylist(playlistName); playlistName = "" } }; Button("Отмена", role: .cancel) {} }
        .alert("Nightwell Music", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("Понятно") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func openNavigation(_ action: StableNavigationAction) {
        switch action {
        case .screen(let screen): store.screen = screen
        case .backgroundOnly: backgroundOnly = true
        case .statistics: feature = .statistics
        case .premium: premiumPresented = true
        case .transfer: transferPresented = true
        case .settings: settings = true
        case .waveSettings: waveSettingsPresented = true
        case .support: supportPresented = true
        case .authentication:
            if store.account == nil { store.authPresented = true }
            else { Task { await store.logout() } }
        }
    }
    private func openSharedURL(_ url: URL) {
        guard let id = DeepLink.trackID(from: url) else { return }
        sharedLinkID = id
        Task {
            await store.openSharedTrack(id)
            if store.clock.id.lowercased() == id.lowercased() {
                sharedLinkID = nil
                fullPlayer = true
            }
        }
    }
    private var compactCollectionTitle: String? {
        guard collectionScrolled else { return nil }
        switch store.screen {
        case .likes: return "Избранное"
        case .playlists: return "Плейлисты"
        case .offline: return "Офлайн"
        default: return nil
        }
    }

    private var collectionScrollMarker: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: CollectionScrollOffsetKey.self,
                value: geometry.frame(in: .named("nightwell-library-scroll")).minY
            )
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }

    private func updateCollectionScroll(_ y: CGFloat) {
        guard store.screen == .likes || store.screen == .playlists || store.screen == .offline else { return }
        let compact = y < -12
        if collectionScrolled != compact {
            withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.18)) {
                collectionScrolled = compact
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) {
                    store.screen = .home
                }
            } label: {
                HStack(spacing: 9) {
                    Text("N")
                        .font(.system(size: 29, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.20), lineWidth: 0.8))
                    if compactCollectionTitle == nil {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Nightwell").font(.system(size: 25, weight: .bold))
                            Text("M U S I C").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(nightwellText)
            .accessibilityLabel("На главную")
            Spacer()
            Button { if store.screen == .search { store.screen = .home } else { store.screen = .search } } label: { Image(systemName: store.screen == .search ? "xmark" : "magnifyingglass").font(.system(size: 19, weight: .medium)).foregroundStyle(.white).frame(width: 44, height: 44).frostedGlass(22, bordered: false, intensity: 0.20) }.accessibilityLabel(store.screen == .search ? "Закрыть поиск" : "Поиск")
            // On Home the full resume banner becomes a small action next to Search
            // after eight seconds; scrolling collections hide the banner so the title stays clear.
            if store.hasRemotePlayback && store.screen == .home && remoteHomeCollapsed {
                Button {
                    Task { await store.continuePlaybackHere() }
                } label: {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 44)
                        .frostedGlass(22, bordered: false, intensity: 0.20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Продолжить музыку с другого устройства")
                .transition(.asymmetric(insertion: .scale(scale: 0.68, anchor: .trailing).combined(with: .opacity),
                                        removal: .opacity))
            }
            Button { navigationMenuPresented = true } label: {
                Group {
                    if let avatar=store.profileAvatar {
                        Image(uiImage:avatar).resizable().scaledToFill()
                    } else {
                        Image(systemName:"person.crop.circle")
                            .font(.system(size:19,weight:.medium))
                    }
                }
                    .clipShape(Circle())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .frostedGlass(22, bordered: false, intensity: 0.20)
            }
            .accessibilityLabel("Меню")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .overlay(alignment: .center) {
            if let title = compactCollectionTitle {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 108)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
    private var favoriteTracks: [Track] {
        let entries = store.favoriteDisplayTracks
        if favoriteSort == "title" && favoritePremium.allowed {
            return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        if favoriteSort == "artist" && favoritePremium.allowed {
            return entries.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        }
        // The catalogue order is unrelated to the time a song was liked.
        // The saved per-account favorite order is newest first.
        let ranks = Dictionary(uniqueKeysWithValues:
            store.favoriteOrder.enumerated().map { ($0.element, $0.offset) })
        return entries.sorted { left, right in
            let a = ranks[left.id] ?? Int.max
            let b = ranks[right.id] ?? Int.max
            if a != b { return a < b }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }
    @ViewBuilder private var content: some View {
        switch store.screen {
        case .home:
            NativeHome(configureWave: { waveSettingsPresented = true }, clock: store.clock)
        case .search:
            VStack(alignment: .leading, spacing: 14) {
                Text("Поиск").font(.largeTitle.bold())
                HStack { Image(systemName: "magnifyingglass"); TextField("Трек или исполнитель", text: $store.query).textInputAutocapitalization(.never).autocorrectionDisabled().onChange(of: store.query) { _ in store.scheduleSearch() }; if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") } } }.padding(14)
                    .background { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial).opacity(0.48) }
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.28), lineWidth: 1))
                if !store.searchMessage.isEmpty { Text(store.searchMessage).font(.caption).foregroundStyle(.secondary) }
                // Prepared off the UI thread. Never rescan the whole catalogue while typing.
                let combinedArtists = store.searchArtistSuggestions
                if !combinedArtists.isEmpty {
                    Text("Исполнители").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9) {
                            ForEach(combinedArtists) { artist in
                                Button { selectedArtist = ArtistSelection(name: artist.name) } label: {
                                    HStack(spacing: 8) {
                                        ArtistPortrait(name: artist.name, imageURL: artist.image_url, size: 30)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(artist.name).font(.system(size: 13, weight: .medium))
                                            if let count = artist.track_count {
                                                Text("\(count) треков").font(.system(size: 10)).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.white.opacity(0.09), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                // Owned results are ranked first in the same list, without
                // blocking input while remote providers are still searching.
                TrackList(tracks: store.results)
            }.padding(.horizontal, 20)
        case .likes:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    collectionScrollMarker
                    HStack(alignment: .center, spacing: 8) {
                        collectionHeading("Избранное", tracks: favoriteTracks, kind: "likes")
                        Spacer(minLength: 0)
                        Menu {
                            Button("Недавно добавленные", systemImage: favoriteSort == "recent" ? "checkmark" : "clock") {
                                favoriteSort = "recent"
                            }
                            if favoritePremium.allowed {
                                Button("По названию") { favoriteSort = "title" }
                                Button("По исполнителю") { favoriteSort = "artist" }
                            } else {
                                Button("Другие виды сортировки · Premium") { premiumPresented = true }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 16))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Сортировка избранного")
                    }
                    TrackList(tracks: favoriteTracks, embedded: true)
                }
                .padding(.horizontal, 20)
            }
            .coordinateSpace(name: "nightwell-library-scroll")
            .modifier(NightwellLibraryScrollTracker(collapsed: $collectionScrolled))
            .scrollDismissesKeyboard(.interactively)
        case .playlists:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    collectionScrollMarker
                    HStack {
                        Text("Плейлисты").font(.largeTitle.bold())
                        Spacer()
                        Button { createPlaylist = true } label: {
                            Image(systemName: "plus").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Новый плейлист")
                    }
                    Button("Умные плейлисты · Premium") { feature = .smart }
                    DailyPublicPlaylistsView(store: store)
                    LazyVStack(spacing: 12) {
                        ForEach(store.playlists) { playlist in
                            HStack {
                                Button { selectedPlaylist = playlist } label: {
                                    Text(playlist.name)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 16)
                                }
                                Menu {
                                    Button("Твой ритм по плейлисту", systemImage: "waveform.path") {
                                        selectedPlaylist = nil
                                        Task { await store.rhythm(around: playlist) }
                                    }
                                    Button("Скачать", systemImage: "arrow.down.to.line") {
                                        Task {
                                            do { await store.download(try await store.playlistTracks(playlist.id)) }
                                            catch { store.error = error.localizedDescription }
                                        }
                                    }
                                    Button("Поделиться", systemImage: "square.and.arrow.up") {
                                        Task {
                                            shareText = await store.share(
                                                kind: "playlist", playlist: playlist.id, title: playlist.name)
                                            showShare = shareText != nil
                                        }
                                    }
                                    Button("Удалить", role: .destructive) {
                                        Task { await store.deletePlaylist(playlist.id) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                }
                            }
                            .padding(.horizontal, 18)
                            .glass()
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .coordinateSpace(name: "nightwell-library-scroll")
            .modifier(NightwellLibraryScrollTracker(collapsed: $collectionScrolled))
            .scrollDismissesKeyboard(.interactively)
        case .offline:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    collectionScrollMarker
                    HStack {
                        Text("Офлайн").font(.largeTitle.bold())
                        Spacer()
                        Button { importFiles = true } label: { Label("Файлы", systemImage: "folder") }
                    }
                    Text("Музыка на этом устройстве, доступная без интернета")
                        .font(.caption).foregroundStyle(.secondary)
                    if !store.damagedOffline.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Не удалось открыть файлы: \(store.damagedOffline.count)")
                                .font(.subheadline.weight(.semibold))
                            Text("Название и обложка сохранились, но сами аудиофайлы повреждены или отсутствуют.")
                                .font(.caption).foregroundStyle(.secondary)
                            if store.damagedOffline.contains(where: { !$0.id.hasPrefix("local_") }) {
                                Button {
                                    Task { await store.repairDamagedDownloads() }
                                } label: {
                                    Label("Скачать эти треки повторно", systemImage: "arrow.clockwise")
                                }
                                .disabled(store.downloading)
                            }
                            if store.damagedOffline.contains(where: { $0.id.hasPrefix("local_") }) {
                                Text("Аудиофайлы, добавленные вручную, нужно повторно импортировать через «Файлы».")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }
                    TrackList(tracks: store.offline, embedded: true)
                }
                .padding(.horizontal, 20)
            }
            .coordinateSpace(name: "nightwell-library-scroll")
            .modifier(NightwellLibraryScrollTracker(collapsed: $collectionScrolled))
            .scrollDismissesKeyboard(.interactively)
        }
    }
    private func collectionHeading(_ title: String, tracks: [Track], kind: String) -> some View {
        HStack { Text(title).font(.largeTitle.bold()); Spacer(); Menu {
            if !tracks.isEmpty && tracks.allSatisfy({ store.isDownloaded($0) }) {
                Button("Удалить загрузки", systemImage: "trash", role: .destructive) {
                    Task { for track in tracks { await store.removeDownload(track) } }
                }
            } else {
                Button("Скачать всё", systemImage: "arrow.down.to.line") { Task { await store.download(tracks) } }
            }
            Button("Поделиться", systemImage: "square.and.arrow.up") { Task { shareText = await store.share(kind: kind, title: title, tracks: tracks); showShare = shareText != nil } }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).glass() } }
    }
}

struct TrackList: View {
    @EnvironmentObject var store: MusicStore
    let tracks: [Track]
    var playlist: Playlist? = nil
    var embedded = false

    private var rows: some View {
        LazyVStack(spacing: 6) {
            if tracks.isEmpty {
                Text(store.account == nil && store.screen != .offline
                     ? "Войди в аккаунт или открой офлайн-файлы"
                     : "Здесь пока нет треков")
                    .foregroundStyle(.secondary)
                    .padding(.top, 30)
            }
            ForEach(tracks) { track in
                NativeTrackRow(track: track, queue: tracks, status: store.clock.status, playlist: playlist)
            }
        }
    }

    @ViewBuilder var body: some View {
        Group {
            if embedded {
                rows
            } else {
                ScrollView { rows }
                    .scrollDismissesKeyboard(.interactively)
            }
        }
        .task(id: tracks.prefix(6).map { $0.id }.joined(separator: "|")) {
            let urls = tracks.prefix(6).compactMap {
                CoverImagePipeline.coverURL(for: $0, origin: store.origin)
            }
            await CoverImagePipeline.shared.prefetch(urls)
        }
    }
}
struct NativeTrackRow: View {
    @EnvironmentObject var store: MusicStore
    let track: Track
    let queue: [Track]
    @ObservedObject var status: TrackStatus
    var playlist: Playlist?
    @State private var selectedArtist: ArtistSelection?
    @State private var showArtistChoices = false
    var body: some View {
        HStack(spacing: 0) {
            // One large hit target so tapping the thumbnail, title, artist,
            // playback indicator, or empty area starts the song.
            Button { store.play(track, in: queue) } label: {
                HStack(spacing: 12) {
                    Cover(track: track, origin: store.origin)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if status.id == track.id {
                        PlayingIndicator(playing: status.playing)
                            .frame(width: 20, height: 20)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Воспроизвести " + track.title)
            Menu {
                if ArtistAttribution.isKnown(track.artist) {
                    let names = ArtistNames.split(track.artist)
                    if names.count == 1, let name = names.first {
                        Button("Открыть исполнителя", systemImage: "person.crop.circle") {
                            selectedArtist = ArtistSelection(name: name)
                        }
                    } else if names.count > 1 {
                        Menu("Исполнители") {
                            ForEach(names, id: \.self) { name in
                                Button(name) { selectedArtist = ArtistSelection(name: name) }
                            }
                        }
                    }
                }
                Button(store.likes.contains(track.id) ? "Убрать из избранного" : "В избранное", systemImage: store.likes.contains(track.id) ? "heart.fill" : "heart") { Task { await store.like(track) } }
                if store.isDownloaded(track) {
                    Button("Удалить загрузку", systemImage: "trash", role: .destructive) { Task { await store.removeDownload(track) } }
                } else if let fraction = store.downloadProgress(track.id) {
                    Text("Скачивание \(Int(fraction * 100))%")
                } else {
                    Button("Скачать", systemImage: "arrow.down.to.line") { Task { await store.download([track]) } }
                }
                ShareLink(item: store.origin.appendingPathComponent("track/" + track.id)) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                Button(store.isRecommendationHidden(track) ? "Вернуть в рекомендации" : "Не рекомендовать", systemImage: "hand.thumbsdown") {
                    store.toggleRecommendationHidden(track)
                }
                if !track.artist.isEmpty {
                    Button(store.isArtistHidden(track) ? "Вернуть исполнителя" : "Не рекомендовать исполнителя", systemImage: "person.crop.circle.badge.xmark") {
                        store.toggleArtistHidden(track)
                    }
                }
                Menu("Добавить в плейлист") { ForEach(store.playlists) { p in Button(p.name) { Task { await store.add(track, playlist: p) } } } }
                if let playlist { Button("Убрать из плейлиста", role: .destructive) { Task { await store.add(track, playlist: playlist, remove: true) } } }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 70)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 5)
            .accessibilityLabel("Действия с треком " + track.title)
        }
        .background(status.id == track.id ? pumpkin.opacity(0.12) : .white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 18))
        .confirmationDialog("Выбери исполнителя", isPresented: $showArtistChoices, titleVisibility: .visible) {
            ForEach(ArtistNames.split(track.artist), id: \.self) { name in
                Button(name) { selectedArtist = ArtistSelection(name: name) }
            }
        }
        .sheet(item: $selectedArtist) { artist in
            ArtistProfileView(name: artist.name).environmentObject(store)
        }
    }
}

struct ArtistSelection: Identifiable {
    let name: String
    var id: String { ArtistNames.normalized(name) }
}

enum ArtistNames {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func split(_ raw: String) -> [String] {
        guard ArtistAttribution.isKnown(raw) else { return [] }
        var prepared = raw.replacingOccurrences(
            of: #"(?i)\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+"#,
            with: ", ", options: .regularExpression)
        prepared = prepared.replacingOccurrences(
            of: #"(?i)\s+(?:feat\.?|ft\.?|featuring|&|×|x)\s+"#,
            with: ", ", options: .regularExpression)
        prepared = prepared.replacingOccurrences(of: #"[)\]]"#, with: "", options: .regularExpression)
        var seen = Set<String>()
        return Array(prepared.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
            .prefix(8))
    }

    static func matches(query: String, tracks: [Track]) -> [String] {
        let needle = normalized(query)
        guard needle.count >= 2 else { return [] }
        var seen = Set<String>()
        var matches: [String] = []
        for track in tracks {
            for artist in split(track.artist) where normalized(artist).contains(needle) {
                if seen.insert(normalized(artist)).inserted { matches.append(artist) }
            }
        }
        return Array(matches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(8))
    }

    static func track(_ track: Track, includes name: String) -> Bool {
        let key = normalized(name)
        return split(track.artist).contains { normalized($0) == key }
    }
}

struct ArtistPortrait: View {
    let name: String
    let imageURL: String?
    var size: CGFloat = 94
    @State private var portrait: UIImage?

    private var validURL: URL? {
        guard let imageURL, let url = URL(string: imageURL),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.12))
            if let portrait {
                Image(uiImage: portrait).resizable().scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: validURL?.absoluteString ?? "") {
            portrait = nil
            guard let validURL else { return }
            let picture = await CoverImagePipeline.shared.image(for: validURL, maxPixel: Int(size * 3))
            if !Task.isCancelled { portrait = picture }
        }
    }
}

struct ArtistProfileView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var message = ""
    @State private var profileImageURL: String?
    @State private var totalTracks: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ArtistPortrait(name: name, imageURL: profileImageURL, size: 94)
                    .accessibilityLabel("Исполнитель " + name)
                Text(name).font(.title2.bold()).multilineTextAlignment(.center)
                if loading { ProgressView("Ищем треки…").tint(.white) }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                if !tracks.isEmpty {
                    HStack {
                        Text("Треки").font(.headline)
                        Spacer()
                        Text("\(totalTracks ?? tracks.count)").foregroundStyle(.secondary)
                    }
                    TrackList(tracks: tracks)
                } else if !loading {
                    ContentUnavailableView("Треки не найдены", systemImage: "music.note",
                                           description: Text("Попробуй поискать исполнителя позже."))
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Исполнитель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: name) { await load() }
    }

    @MainActor private func load() async {
        loading = true
        message = ""
        profileImageURL = store.artistResults.first {
            ArtistNames.normalized($0.name) == ArtistNames.normalized(name)
        }?.image_url
        totalTracks = nil
        var combined = (store.catalog + store.results).filter { ArtistNames.track($0, includes: name) }
        tracks = unique(combined)
        let encoded = name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""

        if store.account != nil {
            do {
                let profile: ArtistDirectoryProfile = try await store.api.request(
                    "/api/artists/profile?name=" + encoded, timeout: 12)
                guard !Task.isCancelled else { return }
                let confirmed = profile.tracks.filter { ArtistNames.track($0, includes: name) }
                if !confirmed.isEmpty {
                    profileImageURL = profile.artist.image_url ?? profileImageURL
                    totalTracks = profile.total
                    combined += confirmed
                    tracks = unique(combined)
                    loading = false
                    return
                }
                // An older server may have indexed the uploader instead of performer.
                // Do not trust its avatar/artist count; continue with title-aware search.
            } catch {
                // Older servers keep the legacy search working.
            }
        }

        for _ in 0..<4 {
            if Task.isCancelled { return }
            do {
                let response: TrackResult = try await store.api.request("/api/tracks?q=" + encoded, timeout: 12)
                guard !Task.isCancelled else { return }
                combined += response.tracks.filter { ArtistNames.track($0, includes: name) }
                tracks = unique(combined)
                if response.search_pending != true { break }
                let delay = max(1.0, min(3.0, response.search_retry_after ?? 1.5))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch is CancellationError { return }
              catch {
                if tracks.isEmpty { message = "Не удалось загрузить каталог: " + error.localizedDescription }
                break
            }
        }
        loading = false
    }

    private func unique(_ items: [Track]) -> [Track] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

struct Cover: View {
    let track: Track?
    let origin: URL
    var pixelWidth = 160
    @State private var artwork: UIImage?

    private var coverURL: URL? {
        track.flatMap { CoverImagePipeline.coverURL(for: $0, origin: origin) }
    }
    var body: some View {
        ZStack {
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .clipped()
        .task(id: "\(coverURL?.absoluteString ?? "")#\(pixelWidth)") {
            artwork = nil
            guard let coverURL else { return }
            let image = await CoverImagePipeline.shared.image(for: coverURL, maxPixel: pixelWidth)
            guard !Task.isCancelled else { return }
            artwork = image
        }
    }
}
struct PlayingIndicator: View {
    let playing: Bool
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !playing || reduced || scene != .active)) { context in
            HStack(alignment: .center, spacing: 2) { ForEach(0..<4) { i in Capsule().fill(pumpkin).frame(width: 3, height: playing ? CGFloat(5 + 13 * abs(sin(context.date.timeIntervalSinceReferenceDate * 5 + Double(i)))) : 5) } }
        }.accessibilityLabel(playing ? "Сейчас играет" : "На паузе")
    }
}
struct PlaylistScreen: View {
    @EnvironmentObject var store: MusicStore
    let close: () -> Void
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(playlist.name)
                    .font(.title2.bold())
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { Task {
                    if tracks.allSatisfy({ store.isDownloaded($0) }) {
                        for track in tracks { await store.removeDownload(track) }
                    } else { await store.download(tracks.filter { !store.isDownloaded($0) }) }
                } } label: {
                    Image(systemName: (!tracks.isEmpty && tracks.allSatisfy({ store.isDownloaded($0) })) ? "trash" : "arrow.down.to.line").frame(width: 42, height: 42).frostedGlass(20, bordered: false, intensity: 0.55)
                }.accessibilityLabel(tracks.allSatisfy { store.isDownloaded($0) } ? "Удалить загрузку плейлиста" : "Скачать плейлист")
                Menu {
                    Button("Твой ритм по плейлисту", systemImage: "waveform.path") {
                        let currentPlaylist = playlist
                        close()
                        Task { await store.rhythm(around: currentPlaylist) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 42, height: 42)
                        .frostedGlass(20, bordered: false, intensity: 0.55)
                }
                .accessibilityLabel("Действия с плейлистом")
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 42, height: 42).frostedGlass(20, bordered: false, intensity: 0.55)
                }.accessibilityLabel("Закрыть плейлист")
            }
            .padding(.top, 18)
            let activeFractions = tracks.compactMap { store.downloadProgress($0.id) }
            if !activeFractions.isEmpty {
                let fraction = activeFractions.reduce(0, +) / Double(activeFractions.count)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Скачивание · \\(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: fraction).tint(pumpkin)
                }
            }
            Text("Треки плейлиста · \\(tracks.count)")
                .font(.caption).foregroundStyle(.secondary)
            TrackList(tracks: tracks, playlist: playlist)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .tint(pumpkin)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-playlist") {
                tracks = [Track(id: "preview-one", title: "Музыка этой ночи", artist: "Nightwell Music"), Track(id: "preview-two", title: "Твой тёмный ритм", artist: "Nightwell Music")]
                return
            }
            #endif
            // Render the device copy first, then refresh asynchronously.
            // A slow network must never leave an already-visited playlist empty.
            let cached = store.cachedPlaylistTracks(playlist.id)
            if let cached { tracks = cached }
            do {
                let fresh = try await store.playlistTracks(playlist.id)
                guard !Task.isCancelled else { return }
                tracks = fresh
            } catch {
                if cached == nil { store.error = error.localizedDescription }
            }
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}



struct NightwellNativeTransfer: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingFile = false
    @State private var name = "Перенос музыки"
    @FocusState private var nameFieldFocused: Bool
    @State private var contents = ""
    @State private var selectedFilename = ""
    @State private var mode = "wide"
    @State private var etaStage = ""
    @State private var etaStart = Date()
    @State private var etaProgress = 0
    @State private var etaText = ""
    @State private var saving = false
    @State private var job: ImportJob?
    @State private var errorText = ""
    @State private var busy = false
    @State private var history: [ImportJob] = []
    @State private var historyExpanded = false
    @State private var historyError = ""
    @State private var observingJobID: String?
    private let activeStates: Set<String> = ["reading", "matching", "saving"]
    struct ImportJob: Decodable {
        struct MatchedItem: Decodable {
            let title: String
            let artist: String
            let track_id: String?
            let reason: String?
        }
        let id: String
        let state: String
        let total: Int
        let progress: Int
        let matched: Int
        let saved: Int
        let message: String?
        let name: String?
        let items: [MatchedItem]?
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Перенести музыку").font(.largeTitle.bold())
                    Text("Поиск и сопоставление треков выполняются на устройстве. Сервер только сохраняет готовый плейлист. Ненайденные треки можно посмотреть и экспортировать.")
                        .foregroundStyle(.secondary)
                    TextField("Название плейлиста", text: $name).focused($nameFieldFocused).submitLabel(.done).onSubmit { nameFieldFocused = false }.padding(14).nightwellLiquidGlass(18)
                    Picker("Режим поиска", selection: $mode) {
                        Text("Точный").tag("safe")
                        Text("Умный").tag("balanced")
                        Text("Максимальный").tag("wide")
                    }.pickerStyle(.segmented)
                    Text(mode == "safe" ? "Точный: оригинальная запись, строгое совпадение названия, исполнителя и длительности." : mode == "balanced" ? "Умный: разные варианты написания и поиск исполнителя в названии или поле артиста. Сомнительные записи отсекаются." : "Максимальный: больше поисковых запросов и вариантов названий. Неподтверждённые совпадения требуют проверки.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { showingFile = true } label: { Label(selectedFilename.isEmpty ? "Выбрать JSON, CSV или TXT" : selectedFilename, systemImage: "doc.badge.plus").frame(maxWidth: .infinity).padding(16) }
                        .nightwellLiquidGlass(20)
                    Button(busy ? "Обрабатываем…" : "Найти треки") { Task { await start() } }
                        .buttonStyle(.borderedProminent).tint(Color(white: 0.24)).foregroundStyle(.white).disabled(contents.isEmpty || busy)
                    if let job {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(job.message ?? "Поиск").font(.headline)
                            ProgressView(value: Double(job.progress), total: Double(max(1, job.total)))
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(job.progress) / \(job.total)").font(.title3.bold()).monospacedDigit()
                                    Text("Проверено").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(job.matched)").font(.title3.bold()).foregroundStyle(pumpkin).monospacedDigit()
                                    Text("Найдено").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(job.total > 0 ? "Обработано \(Int(Double(job.progress) / Double(job.total) * 100))% списка" : "Подготовка поиска")
                                .font(.caption).foregroundStyle(.secondary)
                            if !etaText.isEmpty { Text(etaText).font(.caption).foregroundStyle(.secondary) }
                            let missing = (job.items ?? []).filter { $0.track_id == nil }
                            if !missing.isEmpty {
                                DisclosureGroup("Не найдено: \(missing.count)") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(missing.enumerated()), id: \.offset) { _, entry in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.artist + " — " + entry.title)
                                                    .font(.subheadline)
                                                if let reason = entry.reason, !reason.isEmpty {
                                                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        ShareLink(item: missing.map { $0.artist + " — " + $0.title }.joined(separator: "\n")) {
                                            Label("Поделиться списком ненайденных", systemImage: "square.and.arrow.up")
                                        }
                                        .font(.subheadline.weight(.medium))
                                    }.padding(.top, 8)
                                }.tint(.white)
                            }
                            if (job.state == "ready" || job.state == "error") && job.matched > 0 {
                                Button(saving ? "Добавляем…" : "Добавить") { Task { await commit() } }.buttonStyle(.borderedProminent).tint(Color(white: 0.24)).foregroundStyle(.white).disabled(saving)
                            }
                            if activeStates.contains(job.state) {
                                Button("Остановить") { Task { await cancel() } }.tint(.white)
                            }
                        }.padding(18).nightwellLiquidGlass(24)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) { historyExpanded.toggle() }
                            } label: {
                                HStack {
                                    Text("История переносов").font(.headline)
                                    Spacer()
                                    Text("\(history.filter { !activeStates.contains($0.state) }.count)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { Task { await refreshHistory() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }.accessibilityLabel("Обновить переносы")
                        }
                        if historyExpanded {
                            if !historyError.isEmpty {
                                Text(historyError).font(.caption).foregroundStyle(.white)
                            }
                            let previous = history.filter { !activeStates.contains($0.state) && $0.id != job?.id }
                            if previous.isEmpty { Text("История пуста").font(.caption).foregroundStyle(.secondary) }
                            ForEach(previous, id: \.id) { entry in
                                Button { job = entry; etaText = ""; etaStage = "" } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(entry.name ?? "Перенос музыки").font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(statusName(entry.state)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        ProgressView(value: Double(entry.progress), total: Double(max(1, entry.total)))
                                        Text("Проверено \(entry.progress)/\(entry.total) · Найдено \(entry.matched)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(12).nightwellLiquidGlass(18)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !errorText.isEmpty { Text(errorText).foregroundStyle(.white).font(.caption) }

                }.padding(20)
            }
            .background(Color(red: 0.045, green: 0.045, blue: 0.052))
            .task { await refreshHistory(); if let current = history.first(where: { activeStates.contains($0.state) }) { job = current; await poll(current.id) } }
            .navigationTitle("Перенос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } }; ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Скрыть клавиатуру") { nameFieldFocused = false } } }
            .sheet(isPresented: $showingFile) {
                NightwellImportFilePicker { result in
                    switch result {
                    case .success(let url):
                        do {
                            let data = try Data(contentsOf: url)
                            guard data.count <= 1024 * 1024 else { errorText = "Размер файла больше 1 МБ"; return }
                            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
                                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                errorText = "Файл пустой или имеет неподдерживаемую кодировку"; return
                            }
                            contents = text
                            selectedFilename = url.lastPathComponent
                            errorText = ""
                        } catch { errorText = "Ошибка чтения файла: " + error.localizedDescription }
                    case .failure(let error):
                        errorText = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
        }.preferredColorScheme(.dark)
    }
    private func updateETA(_ job: ImportJob) {
        let progress = job.state == "saving" ? job.saved : job.progress
        let total = job.state == "saving" ? job.matched : job.total
        if etaStage != job.state || progress < etaProgress { etaStage = job.state; etaStart = Date(); etaProgress = progress }
        guard job.state == "matching" || job.state == "saving" else { etaText = ""; return }
        let elapsed = Date().timeIntervalSince(etaStart), delta = progress - etaProgress
        guard delta >= 2, elapsed >= 3 else { etaText = "Оцениваем оставшееся время…"; return }
        let seconds = max(1, elapsed / Double(delta) * Double(max(0, total - progress)))
        etaText = seconds < 60 ? "Осталось примерно меньше минуты" : "Осталось примерно \(Int(ceil(seconds / 60))) мин"
    }
    private func statusName(_ status: String) -> String {
        switch status {
        case "reading": return "Чтение"
        case "matching": return "Поиск"
        case "saving": return "Сохранение"
        case "ready": return "Найдено"
        case "done": return "Готово"
        case "cancelled": return "Отменено"
        case "error": return "Ошибка"
        default: return status
        }
    }
    private func refreshHistory() async {
        struct Response: Decodable { let jobs: [ImportJob] }
        do {
            let response: Response = try await store.api.request("api/imports")
            history = response.jobs
            historyError = ""
        } catch { historyError = "Не удалось загрузить историю: " + error.localizedDescription }
    }
    private func start() async {
        busy = true; defer { busy = false }
        do {
            let raw = contents
            var catalog = store.catalog
            if catalog.isEmpty {
                await store.refresh()
                catalog = store.catalog
            }
            guard !catalog.isEmpty else {
                throw APIError(message: "Каталог ещё не загружен. Проверь подключение и повтори перенос.")
            }
            let selectedMode = mode
            let matching = try await Task.detached(priority: .userInitiated) { () throws -> [[String: Any]] in
                let prepared = try TransferPreparation.prepare(raw)
                let localIndex = try JSONEncoder().encode(catalog)
                return try DeviceTransferMatcher.match(
                    prepared: prepared, catalogJSON: localIndex, mode: selectedMode)
            }.value
            etaStage = ""
            let result: ImportJob = try await store.api.request("api/imports/client", method: "POST",
                body: ["provider":"yandex","name":name,"items":matching,"mode":mode])
            job = result; errorText = ""; await refreshHistory(); await poll(result.id)
        } catch {
            errorText = error.localizedDescription
            await refreshHistory()
            if let current = history.first(where: { activeStates.contains($0.state) }) {
                job = current
                await poll(current.id)
            }
        }
    }
    private func poll(_ id: String) async {
        guard observingJobID != id else { return }
        observingJobID = id
        defer { if observingJobID == id { observingJobID = nil } }
        while !Task.isCancelled && observingJobID == id {
            do {
                let next: ImportJob = try await store.api.request("api/imports/" + id)
                if job?.id == id { job = next; updateETA(next) }
                if next.state == "done" { await store.refresh() }
                if !activeStates.contains(next.state) { await refreshHistory(); return }
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch { errorText = error.localizedDescription; return }
        }
    }
    private func commit() async {
        guard let job, !saving else { return }
        saving = true; defer { saving = false }
        do { let next: ImportJob = try await store.api.request("api/imports/" + job.id + "/commit",method:"POST",body:[:]); self.job = next; await refreshHistory(); await poll(job.id) }
        catch { errorText = error.localizedDescription }
    }
    private func cancel() async {
        guard let job else { return }
        do { let next: ImportJob = try await store.api.request("api/imports/" + job.id + "/cancel",method:"POST",body:[:]); self.job = next; await refreshHistory() }
        catch { errorText = error.localizedDescription }
    }
}

private struct NightwellImportFilePicker: UIViewControllerRepresentable {
    let completion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            guard ["json", "csv", "txt"].contains(url.pathExtension.lowercased()) else {
                completion(.failure(NSError(domain: "NightwellImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Поддерживаются JSON, CSV и TXT"])))
                return
            }
            completion(.success(url))
        }
    }
}




private struct MonochromeNightwellLaunch: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.085), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            GeometryReader { geometry in
                Canvas { context, size in
                    let w = size.width, h = size.height
                    for index in 0..<6 {
                        let left = index.isMultiple(of: 2)
                        let origin = CGPoint(x: left ? 0 : w, y: h * (0.16 + CGFloat(index / 2) * 0.22))
                        let target = CGPoint(x: w * (left ? 0.69 : 0.31), y: h * 0.53)
                        let spread: CGFloat = 60
                        var beam = Path()
                        beam.move(to: origin)
                        beam.addLine(to: CGPoint(x: target.x - spread, y: target.y + 160))
                        beam.addLine(to: CGPoint(x: target.x + spread, y: target.y + 160))
                        beam.closeSubpath()
                        context.fill(beam, with: .linearGradient(
                            Gradient(colors: [.white.opacity(0.19), .white.opacity(0.06), .clear]),
                            startPoint: origin, endPoint: CGPoint(x: w / 2, y: h * 0.82)
                        ))
                    }
                }
                .blur(radius: 20)
                .allowsHitTesting(false)
            }
            VStack(spacing: 14) {
                Text("N")
                    .font(.system(size: 92, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.22), radius: 24)
                Text("NIGHTWELL")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .tracking(5)
                Text("M U S I C")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(5)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Nightwell Music")
    }
}
