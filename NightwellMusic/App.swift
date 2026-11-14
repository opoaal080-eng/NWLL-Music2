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
                    .frame(width: min(
                        max(0, proxy.size.width - (proxy.size.width > proxy.size.height ? 28 : 40)),
                        proxy.size.width > proxy.size.height ? 760 : 600
                    ))
                    .frame(height: min(
                        maxHeight,
                        proxy.size.height * (proxy.size.width > proxy.size.height ? 0.94 : 0.88)
                    ))
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
    case backgroundOnly, statistics, premium, transfer, settings, waveSettings, support, together, profile, authentication
}

/// An independently presented, stable scroll view. Playback updates cannot
/// re-create the menu or send it back to its first item.
/// A stable two-level sheet for profile, settings and additional tools.
/// Main screens use the bottom navigation or this menu, as customized.
private struct StableNavigationSheet: View {
    let status: String
    let signedIn: Bool
    let libraryScreen: MusicStore.Screen
    let showsMainNavigation: Bool
    let opensAdditional: Bool
    let showsPremiumEntry: Bool
    let select: (StableNavigationAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MusicStore
    private var connectionMessage: String {
        switch status {
        case "Онлайн": return "API доступен. Подключено"
        case "Ограничен": return "API ограничен. Подключение нестабильно"
        case "Оффлайн": return "API недоступен. Нет подключения"
        default: return "Проверка API. Подключаемся"
        }
    }

    private func choose(_ action: StableNavigationAction) {
        // Parent dismisses this sheet and presents the destination afterward.
        select(action)
    }

    private func rowContent(_ title: String, icon: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 25)
            Text(title).font(.system(size: 16, weight: .medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
        }
        .foregroundStyle(.white)
        .frame(minHeight: 49)
        .padding(.horizontal, 16)
        .nightwellMonochromeGlass(radius: 19)
    }

    private func entry(_ title: String, icon: String, action: StableNavigationAction) -> some View {
        Button { choose(action) } label: { rowContent(title, icon: icon) }
            .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Group {
                    if status == "Загрузка…" || status == "Проверка…" {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Color(red: 0.25, green: 0.60, blue: 1.0))
                            .scaleEffect(0.78)
                    } else {
                        Image(systemName: status == "Онлайн" ? "wifi" :
                              status == "Ограничен" ? "wifi.exclamationmark" : "wifi.slash")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(status == "Онлайн" ? Color.green :
                                             status == "Ограничен" ? Color.orange : Color.gray)
                    }
                }
                .frame(width: 24, height: 28)
                Text(connectionMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Подключение Nightwell: " + connectionMessage)
            .padding(.horizontal, 20).padding(.top, 24)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if showsMainNavigation {
                        entry("Главная", icon: "house", action: .screen(.home))
                        entry("Поиск", icon: "magnifyingglass", action: .screen(.search))
                        entry("Медиатека", icon: "square.stack", action: .screen(libraryScreen))
                        if showsPremiumEntry {
                            entry("Nightwell Premium", icon: "star", action: .premium)
                        }
                        entry("Настройки", icon: "gearshape", action: .settings)
                        Divider().overlay(.white.opacity(0.16)).padding(.vertical, 6)
                    }
                    if showsMainNavigation || opensAdditional {
                        entry("Слушать вместе", icon: "person.2.wave.2", action: .together)
                        if signedIn {
                            entry("Моя статистика", icon: "chart.bar", action: .statistics)
                            entry("Перенос плейлистов", icon: "square.and.arrow.down", action: .transfer)
                        }
                        entry("Обращения и поддержка", icon: "envelope", action: .support)
                    }
                    if showsMainNavigation || !opensAdditional {
                        Divider().overlay(.white.opacity(0.16)).padding(.vertical, 6)
                        entry(signedIn ? "Профиль" : "Войти", icon: "person.crop.circle",
                              action: signedIn ? .profile : .authentication)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .background { NightwellMonochromeGlassBackground() }
        .tint(.white)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(430), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
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
    @State private var initialSessionLoaded = false
    @State private var profilePresented = false
    @State private var dailyPlaylistsPresented = false
    @State private var profileSigningOut = false
    @State private var pendingNavigation: StableNavigationAction?
    @State private var waveSettingsPresented = false
    @State private var supportPresented = false
    @State private var premiumPresented = false
    @State private var profilePremiumPresented = false
    @State private var libraryMenuStartsAdditional = false
    @State private var transferPresented = false
    @State private var togetherPresented = false
    @StateObject private var togetherSession = NightwellTogetherSession()
    @State private var favoriteSort = "recent"
    @State private var librarySession = LibrarySessionState<MusicStore.Screen>(overview: .library)
    @AppStorage(NavigationLayout.storageKey) private var navigationLayout = NavigationLayout.belowPlayer
    @AppStorage("nw-ambient-lyrics") private var showHomeLyrics = true
    @State private var libraryScrollCollapsed: [String: Bool] = [:]
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
    @State private var searchScrollCollapsed = false
    @State private var searchRevealRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ViewBuilder private var mainScene: some View {
        GeometryReader { viewport in
            let landscape = viewport.size.width > viewport.size.height * 1.12 &&
                viewport.size.height < 650
            let bottomInset = dockContentInset(landscape: landscape) + viewport.safeAreaInsets.bottom + 12
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
                RibbonScene(playing: store.clock.playing, flash: store.likeFlash,
                            active: store.screen == .home)
                    .ignoresSafeArea()
                    .opacity(store.screen == .home ? 1.0 : 0.18)
                    .allowsHitTesting(false)
            }
            if backgroundOnly { BackgroundOnlyScene(clock: store.clock, lyrics: store.lyrics, flash: store.likeFlash) }
            if backgroundOnly {
                VStack { HStack { Button { backgroundOnly = false } label: { Image(systemName: "xmark").padding().glass() }; Spacer() }; Spacer() }.padding()
            } else {
                HStack(alignment: .top, spacing: 0) {
                VStack(spacing: landscape ? 6 : 18) {
                    if isLibraryScreen {
                        libraryHeader(landscape: landscape)
                    } else if store.screen == .search && searchScrollCollapsed {
                        compactSearchHeader(landscape: landscape)
                    } else {
                        header(landscape: landscape)
                    }
                    if !landscape && !isLibraryScreen && !(store.screen == .search && searchScrollCollapsed) && store.hasRemotePlayback && !remoteHomeCollapsed {
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
                    content(bottomContentInset: bottomInset)
                        .environment(\.nightwellBottomContentInset, bottomInset)
                        .overlay(alignment: .bottom) {
                            playerDock(landscape: landscape)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        }
    }

    private func dockContentInset(landscape: Bool) -> CGFloat {
        if navigationLayout.showsTabs { return landscape ? 102 : 118 }
        return landscape ? 54 : 70
    }

    private func playerDock(landscape: Bool) -> some View {
        VStack(spacing: navigationLayout.showsTabs ? (landscape ? 2 : 4) : 0) {
            MiniPlayer(clock: store.clock, open: { fullPlayer = true },
                       compactHeight: landscape)
                .padding(.horizontal, landscape ? 18 : 16)
                .overlay(alignment: .bottom) {
                    if store.screen == .home && !landscape && showHomeLyrics {
                        HomeLyricLine(model: store.lyrics, clock: store.clock)
                            .saturation(0)
                            .frame(height: 60)
                            .padding(.horizontal, 24)
                            .offset(y: -85)
                    }
                }
                .overlay(alignment: .top) {
                    if !store.queueNotice.isEmpty {
                        Text(store.queueNotice)
                            .font(.system(size: 13, weight: .medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.horizontal, 20)
                            .offset(y: -52)
                            .allowsHitTesting(false)
                    }
                }
            if navigationLayout.showsTabs {
                bottomNavigation(landscape: landscape)
            }
        }
        .background {
            // Blur only the scrolling content behind the dock. The controls
            // stay sharp, and the upper edge blends into the same screen.
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.6)
                .mask {
                    LinearGradient(gradient: NavigationDockAppearance.blurFade,
                                   startPoint: .top, endPoint: .bottom)
                }
                .padding(.top, -32)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
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

    private var artworkRefreshKey: String {
        store.origin.absoluteString + "|" + (store.clock.current?.id ?? "")
    }

    // Keep the large root view-builder simple for the Swift type checker.
    private var artworkScene: some View {
        mainScene
            .overlay { modalScene }
            // Apply these to the entire composite, including the playlist
            // overlay. NativeTrackRow inside PlaylistScreen requires the
            // Together session; injecting only into mainScene crashes SwiftUI.
            .environmentObject(artworkPalette)
            .environmentObject(togetherSession)
            .task(id: artworkRefreshKey) {
                await artworkPalette.refresh(track: store.clock.current, origin: store.origin)
            }
    }

    private var navigationSheetsScene: some View {
        artworkScene
        .task(id: store.account?.id) {
            await favoritePremium.refresh(store)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: settings)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: store.authPresented)
        .tint(pumpkin)
        .sheet(isPresented: $navigationMenuPresented, onDismiss: {
            guard let destination = pendingNavigation else { return }
            pendingNavigation = nil
            openNavigation(destination)
        }) {
            StableNavigationSheet(status: store.connectionStatus, signedIn: store.account != nil,
                                  libraryScreen: libraryDestination,
                                  showsMainNavigation: !navigationLayout.showsTabs,
                                  opensAdditional: libraryMenuStartsAdditional,
                                  showsPremiumEntry: initialSessionLoaded && favoritePremium.shouldOfferPremium(for: store.account?.id)) { action in
                pendingNavigation = action
                navigationMenuPresented = false
            }
            .environmentObject(store)
        }
        .sheet(item: $feature) { kind in
            PremiumFeatureView(kind: kind).environmentObject(store)
        }
        .sheet(isPresented: $dailyPlaylistsPresented) {
            DailyPublicPlaylistsScreen(store: store)
        }
        .sheet(isPresented: $profilePresented) {
            NavigationStack {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ProfileSettingsView()
                            .environmentObject(store)
                        if store.account != nil && favoritePremium.allowed {
                            Button {
                                profilePremiumPresented = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "star.fill")
                                    Text("Nightwell Premium · Подписка активна")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 13)
                                .frame(maxWidth: .infinity)
                                .nightwellMonochromeGlass(radius: 19)
                            }
                            .buttonStyle(.plain)
                        }
                        if store.account != nil {
                            Button {
                                guard !profileSigningOut else { return }
                                profileSigningOut = true
                                Task {
                                    await store.logout()
                                    profileSigningOut = false
                                    // Keep the profile open on a network error
                                    // so the existing Nightwell error remains visible.
                                    if store.account == nil {
                                        profilePresented = false
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                    Text("Выйти из аккаунта")
                                    Spacer()
                                    if profileSigningOut {
                                        ProgressView().tint(.white)
                                    }
                                }
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .nightwellMonochromeGlass(radius: 19)
                            }
                            .buttonStyle(.plain)
                            .disabled(profileSigningOut)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
                .background { NightwellMonochromeGlassBackground() }
                .navigationTitle("Профиль")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { profilePresented = false } label: {
                            Text("Готово")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 9)
                                .nightwellMonochromeGlass(radius: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $profilePremiumPresented, onDismiss: {
                Task { await favoritePremium.refresh(store) }
            }) { PremiumView(api: store.api) }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.clear)
        }
        .sheet(isPresented: $premiumPresented, onDismiss: {
            Task { await favoritePremium.refresh(store) }
        }) { PremiumView(api: store.api) }
        .sheet(isPresented: $togetherPresented) {
            NightwellTogetherSheet(session: togetherSession, store: store)
        }
    }

    var body: some View {
        navigationSheetsScene
        .overlay { if launching { MonochromeNightwellLaunch().transition(.opacity) } }
        .task { try? await Task.sleep(nanoseconds: reducedMotion ? 150_000_000 : 1_200_000_000); withAnimation(.easeOut(duration: 0.3)) { launching = false } }
        // Collapse the remote-playback banner once per remote session, not
        // once per Home visit. Switching tabs must never expand it again.
        // Only losing remote playback resets the banner for the next session.
        .task(id: store.hasRemotePlayback) {
            guard store.hasRemotePlayback else {
                remoteHomeCollapsed = false
                return
            }
            remoteHomeCollapsed = false
            do { try await Task.sleep(nanoseconds: 8_000_000_000) }
            catch { return }
            guard !Task.isCancelled, store.hasRemotePlayback else { return }
            withAnimation(reducedMotion ? nil : .spring(response: 0.48, dampingFraction: 0.82)) {
                remoteHomeCollapsed = true
            }
        }
        .animation(reducedMotion ? nil : .spring(response: 0.48, dampingFraction: 0.82),
                   value: remoteHomeCollapsed)
        .onChange(of: store.account?.id) { _ in
            togetherSession.clearLocalRoom()
            Task { await store.refreshProfile() }
        }
        .task { await store.start()
            initialSessionLoaded = true
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
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
            let dx = gesture.translation.width
            let dy = gesture.translation.height
            if gesture.startLocation.x < 24 && dx > 90 && abs(dy) < 60 {
                navigate(to: .home)
            }
        })
        .onChange(of: store.screen) { oldScreen, newScreen in
            if isLibraryScreen && librarySession.lastVisited != newScreen { librarySession.remember(newScreen) }
            if oldScreen == .search { store.leaveSearch(); searchScrollCollapsed = false }
            if newScreen == .search { store.scheduleSearch() }
        }
        .onOpenURL { url in
            if let code = NightwellTogetherSession.invitationCode(from: url.absoluteString, origin: store.origin) {
                togetherPresented = true
                Task { await togetherSession.join(code, store: store) }
            } else {
                openSharedURL(url)
            }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { openSharedURL(url) }
        }
        .onChange(of: store.clock.id) { id in
            if let expected = sharedLinkID, id.lowercased() == expected.lowercased() {
                sharedLinkID = nil
                fullPlayer = true
            }
        }
        .fullScreenCover(isPresented: $fullPlayer) { FullPlayer(clock: store.clock).environmentObject(togetherSession) }
        .sheet(item: $selectedArtist) { artist in
            ArtistProfileView(name: artist.name, togetherSession: togetherSession).environmentObject(store)
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
        case .screen(let screen): navigate(to: screen)
        case .backgroundOnly: backgroundOnly = true
        case .statistics: feature = .statistics
        case .premium: premiumPresented = true
        case .transfer: transferPresented = true
        case .settings: settings = true
        case .profile: profilePresented = true
        case .waveSettings: waveSettingsPresented = true
        case .support: supportPresented = true
        case .together: togetherPresented = true
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
    private let libraryScreens: [MusicStore.Screen] = [.library, .likes, .playlists, .offline]

    private var isLibraryScreen: Bool { libraryScreens.contains(store.screen) }

    private var libraryDestination: MusicStore.Screen {
        isLibraryScreen ? .library : librarySession.lastVisited
    }

    private var collectionScrolled: Bool {
        libraryScrollCollapsed[store.screen.rawValue] ?? false
    }

    private func libraryScrollBinding(for screen: MusicStore.Screen) -> Binding<Bool> {
        let revision = librarySession.revision(for: screen)
        return Binding(get: { libraryScrollCollapsed[screen.rawValue] ?? false }, set: { collapsed in
            guard store.screen == screen, revision == librarySession.revision(for: screen) else { return }
            if libraryScrollCollapsed[screen.rawValue] != collapsed {
                libraryScrollCollapsed[screen.rawValue] = collapsed
            }
        })
    }

    private func libraryScrollPosition(for screen: MusicStore.Screen) -> Binding<String?> {
        let revision = librarySession.revision(for: screen)
        return Binding(get: { librarySession.scrollPosition(for: screen) }, set: { position in
            // Ignore removal callbacks and stale views from before a sort.
            guard store.screen == screen, revision == librarySession.revision(for: screen) else { return }
            if librarySession.scrollPosition(for: screen) != position {
                librarySession.saveScrollPosition(position, for: screen, revision: revision)
            }
        })
    }

    private func changeFavoriteSort(_ sort: String) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            librarySession.resetScroll(for: .likes)
            libraryScrollCollapsed[MusicStore.Screen.likes.rawValue] = false
            favoriteSort = sort
        }
    }

    private func navigate(to screen: MusicStore.Screen) {
        guard store.screen != screen else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if libraryScreens.contains(screen) { librarySession.remember(screen) }
            store.screen = screen
        }
    }

    private func libraryHeader(landscape: Bool) -> some View {
        HStack(spacing: 2) {
            if store.screen != .library {
                Button { navigate(to: .library) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Назад в медиатеку")
            }
            Button { settings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Настройки")
            Spacer()
            Button {
                libraryMenuStartsAdditional = navigationLayout.showsTabs
                navigationMenuPresented = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 23, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Дополнительно")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .overlay {
            if store.screen == .library || compactCollectionTitle != nil {
                Text(store.screen == .library ? "Медиатека" : store.screen.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 100)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, landscape ? 4 : 8)
    }

    private func bottomNavigation(landscape: Bool) -> some View {
        HStack(spacing: 0) {
            navigationTab("Главная", icon: "house", selected: store.screen == .home,
                          landscape: landscape) { navigate(to: .home) }
            navigationTab("Поиск", icon: "magnifyingglass", selected: store.screen == .search,
                          landscape: landscape) { navigate(to: .search) }
            navigationTab("Медиатека", icon: "square.stack", selected: isLibraryScreen,
                          landscape: landscape) { navigate(to: libraryDestination) }
            if initialSessionLoaded && favoritePremium.shouldOfferPremium(for: store.account?.id) {
                navigationTab("Premium", icon: "star", selected: false,
                              landscape: landscape) { premiumPresented = true }
            }
        }
        .padding(.horizontal, landscape ? 18 : 8)
        .padding(.bottom, landscape ? 2 : 0)
    }

    private func navigationTab(_ title: String, icon: String, selected: Bool,
                               landscape: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if landscape {
                    HStack(spacing: 7) {
                        Image(systemName: selected && icon != "magnifyingglass" ? icon + ".fill" : icon)
                            .font(.system(size: 16, weight: selected ? .semibold : .regular))
                        Text(title).font(.system(size: 12, weight: .medium))
                    }
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: selected && icon != "magnifyingglass" ? icon + ".fill" : icon)
                            .font(.system(size: 18, weight: selected ? .semibold : .regular))
                        Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    }
                }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.46))
            .frame(maxWidth: .infinity, minHeight: 44,
                   alignment: landscape ? .center : .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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

    // The colored mark is the actual dot in the lowercase i glyph, not
    // another circle drawn above the wordmark.
    private var connectionBrandName: AttributedString {
        let name = NSMutableAttributedString(string: "Nı\u{0307}ghtwell")
        let color: UIColor
        switch store.connectionStatus {
        case "Онлайн": color = .systemGreen
        case "Ограничен": color = .systemOrange
        case "Оффлайн": color = .systemGray
        default: color = .systemBlue
        }
        name.addAttribute(.foregroundColor, value: color, range: NSRange(location: 2, length: 1))
        return AttributedString(name)
    }

    private func compactSearchHeader(landscape: Bool) -> some View {
        HStack(spacing: 8) {
            Button { navigate(to: .home) } label: {
                Text("N").font(.system(size: 25, weight: .black, design: .rounded))
                    .frame(width: 38, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("На главную")
            Button { searchRevealRequest += 1 } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                    Text(store.query.isEmpty ? "Поиск" : store.query)
                        .font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40)
                .frostedGlass(20, bordered: false, intensity: 0.20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Развернуть поиск")
            .accessibilityValue(store.query)
            if !navigationLayout.showsTabs {
                Button { libraryMenuStartsAdditional = false; navigationMenuPresented = true } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 18, weight: .medium))
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Открыть меню навигации")
            }
            Button {
                if store.account == nil { store.authPresented = true }
                else { profilePresented = true }
            } label: {
                Group {
                    if let avatar = store.profileAvatar {
                        Image(uiImage: avatar).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle").font(.system(size: 19, weight: .medium))
                    }
                }
                .frame(width: 40, height: 40).clipShape(Circle())
                .frostedGlass(20, bordered: false, intensity: 0.20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.account == nil ? "Войти в аккаунт" : "Открыть профиль")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.top, landscape ? 14 : 8)
        .transition(.opacity)
    }

    private func header(landscape: Bool) -> some View {
        HStack(spacing: landscape ? 5 : 7) {
            Button {
                navigate(to: .home)
            } label: {
                HStack(spacing: 9) {
                    Text("N")
                        .font(.system(size: 29, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.20), lineWidth: 0.8))
                    // Keep only the N icon when scrolling Favorites, Playlists or Offline.
                    if compactCollectionTitle == nil {
                        if landscape {
                            (Text(connectionBrandName) + Text(" Music"))
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(connectionBrandName).font(.system(size: 25, weight: .bold))
                                Text("M U S I C").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(nightwellText)
            .accessibilityLabel("На главную")
            Spacer()
            if !navigationLayout.showsTabs {
                Button { navigate(to: store.screen == .search ? .home : .search) } label: {
                    Image(systemName: store.screen == .search ? "xmark" : "magnifyingglass")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .frostedGlass(22, bordered: false, intensity: 0.20)
                }
                .accessibilityLabel(store.screen == .search ? "Закрыть поиск" : "Поиск")
                Button {
                    libraryMenuStartsAdditional = false
                    navigationMenuPresented = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .frostedGlass(22, bordered: false, intensity: 0.20)
                }
                .accessibilityLabel("Открыть меню навигации")
            }
            // Hide the compact handoff button while a collection is scrolled.
            if store.hasRemotePlayback && (remoteHomeCollapsed || landscape) && compactCollectionTitle == nil {
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
            // Keep the existing avatar menu for profile and additional tools.
            if !navigationMenuPresented {
                Button {
                    if store.account == nil { store.authPresented = true }
                    else { profilePresented = true }
                } label: {
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
                .buttonStyle(.plain)
                .accessibilityLabel(store.account == nil ? "Войти в аккаунт" : "Открыть профиль")
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.72, anchor: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.72, anchor: .trailing).combined(with: .opacity)
                ))
            }
        }
        .animation(reducedMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
                   value: navigationMenuPresented)
        .animation(reducedMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
                   value: collectionScrolled)
        .padding(.horizontal, landscape ? 20 : 20)
        .padding(.top, landscape ? 14 : 8)
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
        // The store already presents the known chronology in order. Only
        // records absent from that chronology need the title fallback sort.
        let orderedIDs = Set(store.favoriteOrder)
        guard let firstUnordered = entries.firstIndex(where: { !orderedIDs.contains($0.id) }) else { return entries }
        return Array(entries[..<firstUnordered]) + entries[firstUnordered...].sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    private func content(bottomContentInset: CGFloat) -> some View {
        // Inactive lists must release their layout, subscriptions and cover
        // tasks. Keep only small scroll anchors, never three invisible trees.
        screenContent(for: store.screen, bottomContentInset: bottomContentInset)
            .id(store.screen)
            .ignoresSafeArea(.container, edges: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func screenContent(for screen: MusicStore.Screen, bottomContentInset: CGFloat) -> some View {
        switch screen {
        case .home:
            NativeHome(configureWave: { waveSettingsPresented = true }, clock: store.clock)
        case .library:
            LibraryOverview(favorites: favoriteTracks, scrollPosition: libraryScrollPosition(for: .library),
                            openFavorites: { navigate(to: .likes) },
                            openPlaylists: { navigate(to: .playlists) },
                            openOffline: { navigate(to: .offline) },
                            openDailyPlaylists: { dailyPlaylistsPresented = true },
                            openSmartPlaylists: { feature = .smart })
        case .search:
            NightwellSearchScreen(collapsed: $searchScrollCollapsed, revealRequest: searchRevealRequest) { name in
                selectedArtist = ArtistSelection(name: name)
            }
        case .likes:
            let tracks = favoriteTracks
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    collectionScrollMarker
                    HStack(alignment: .center, spacing: 8) {
                        collectionHeading("Избранное", tracks: tracks, kind: "likes")
                        Spacer(minLength: 0)
                        Menu {
                            Button("Недавно добавленные", systemImage: favoriteSort == "recent" ? "checkmark" : "clock") {
                                changeFavoriteSort("recent")
                            }
                            if favoritePremium.allowed {
                                Button("По названию") { changeFavoriteSort("title") }
                                Button("По исполнителю") { changeFavoriteSort("artist") }
                            } else if favoritePremium.entitlementVerified {
                                Button("Другие виды сортировки · Premium") { premiumPresented = true }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 16))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Сортировка избранного")
                    }
                    TrackList(tracks: tracks, embedded: true)
                }
                .padding(.horizontal, 20)
            }
            .coordinateSpace(name: "nightwell-library-scroll")
            .modifier(NightwellLibraryScrollTracker(collapsed: libraryScrollBinding(for: .likes)))
            .scrollPosition(id: libraryScrollPosition(for: .likes), anchor: .top)
            .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
            .contentMargins(.bottom, bottomContentInset, for: .scrollIndicators)
            .scrollDismissesKeyboard(.interactively)
            .id(librarySession.revision(for: .likes))
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
                    Button((favoritePremium.allowed || !favoritePremium.entitlementVerified) ? "Умные плейлисты" : "Умные плейлисты · Premium") { feature = .smart }
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
                            .id(playlist.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .padding(.horizontal, 20)
            }
            .coordinateSpace(name: "nightwell-library-scroll")
            .modifier(NightwellLibraryScrollTracker(collapsed: libraryScrollBinding(for: .playlists)))
            .scrollPosition(id: libraryScrollPosition(for: .playlists), anchor: .top)
            .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
            .contentMargins(.bottom, bottomContentInset, for: .scrollIndicators)
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
            .modifier(NightwellLibraryScrollTracker(collapsed: libraryScrollBinding(for: .offline)))
            .scrollPosition(id: libraryScrollPosition(for: .offline), anchor: .top)
            .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
            .contentMargins(.bottom, bottomContentInset, for: .scrollIndicators)
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
    @Environment(\.nightwellBottomContentInset) private var bottomContentInset
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
                    .id(track.id)
            }
        }
        .scrollTargetLayout()
    }

    @ViewBuilder var body: some View {
        Group {
            if embedded {
                rows
            } else {
                ScrollView { rows }
                    .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
                    .contentMargins(.bottom, bottomContentInset, for: .scrollIndicators)
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
    @EnvironmentObject private var togetherSession: NightwellTogetherSession
    let track: Track
    let queue: [Track]
    @ObservedObject var status: TrackStatus
    var playlist: Playlist?
    var onPlay: (() -> Void)? = nil
    var libraryPreview = false
    @State private var selectedArtist: ArtistSelection?
    @State private var showArtistChoices = false
    var body: some View {
        HStack(spacing: 0) {
            // One large hit target so tapping the thumbnail, title, artist,
            // playback indicator, or empty area starts the song.
            Button {
                if let onPlay { onPlay() }
                else { store.play(track, in: queue) }
            } label: {
                HStack(spacing: 12) {
                    Cover(track: track, origin: store.origin, pixelWidth: libraryPreview ? 224 : 160)
                        .frame(width: libraryPreview ? 56 : 46, height: libraryPreview ? 56 : 46)
                        .clipShape(RoundedRectangle(cornerRadius: libraryPreview ? 8 : 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(libraryPreview ? .body.weight(.medium) : .subheadline.weight(.semibold))
                            .lineLimit(libraryPreview ? 1 : 2)
                        Text(track.artist).font(libraryPreview ? .subheadline : .caption).foregroundStyle(.secondary)
                            .lineLimit(libraryPreview ? 1 : 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if status.id == track.id {
                        PlayingIndicator(playing: status.playing)
                            .frame(width: 20, height: 20)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: libraryPreview ? 56 : 54, alignment: .leading)
                .padding(.leading, libraryPreview ? 0 : 12)
                .padding(.vertical, libraryPreview ? 8 : 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Воспроизвести " + track.title)
            Menu {
                QueueTrackActions(track: track)
                if togetherSession.joined {
                    Button("Добавить в совместное прослушивание", systemImage: "person.2.wave.2") {
                        Task { await togetherSession.add(trackID: track.id, store: store) }
                    }
                }
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
                    .frame(width: 44, height: libraryPreview ? 72 : 70)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 5)
            .accessibilityLabel("Действия с треком " + track.title)
        }
        .padding(.horizontal, libraryPreview ? 8 : 0)
        .background(status.id == track.id ? pumpkin.opacity(0.12) : libraryPreview ? .clear : .white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 18))
        .confirmationDialog("Выбери исполнителя", isPresented: $showArtistChoices, titleVisibility: .visible) {
            ForEach(ArtistNames.split(track.artist), id: \.self) { name in
                Button(name) { selectedArtist = ArtistSelection(name: name) }
            }
        }
        .sheet(item: $selectedArtist) { artist in
            ArtistProfileView(name: artist.name, togetherSession: togetherSession).environmentObject(store)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let name: String
    private let togetherSession: NightwellTogetherSession
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var message = ""
    @State private var profileImageURL: String?
    @State private var totalTracks: Int?
    @State private var reloadRevision = 0

    init(name: String, togetherSession: NightwellTogetherSession) {
        self.name = name
        self.togetherSession = togetherSession
    }

    #if DEBUG
    private var usesPreviewTracks = false

    init(name: String, togetherSession: NightwellTogetherSession, previewTracks: [Track]) {
        self.name = name
        self.togetherSession = togetherSession
        self.usesPreviewTracks = true
        _tracks = State(initialValue: previewTracks)
        _loading = State(initialValue: false)
    }
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 14) {
                        ArtistPortrait(name: name, imageURL: profileImageURL, size: 108)
                            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                            .accessibilityLabel("Исполнитель " + name)
                        VStack(spacing: 6) {
                            Text(name)
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            if !tracks.isEmpty || totalTracks != nil {
                                Text(trackCountText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.58))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    if !tracks.isEmpty {
                        playbackActions
                    }

                    if loading {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(tracks.isEmpty ? "Ищем треки…" : "Обновляем каталог…")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                    }

                    if !message.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(message, systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Повторить загрузку") { reloadRevision += 1 }
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                                .disabled(loading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                    }

                    if !tracks.isEmpty {
                        HStack {
                            Text("Треки").font(.title3.bold())
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Text("\(tracks.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        TrackList(tracks: tracks, embedded: true)
                    } else if !loading && message.isEmpty {
                        ContentUnavailableView("Треки не найдены", systemImage: "music.note",
                                               description: Text("Попробуй открыть исполнителя позже."))
                            .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background {
                LinearGradient(colors: [Color(red: 0.075, green: 0.065, blue: 0.105),
                                        Color(white: 0.025), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            .navigationTitle("Исполнитель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(white: 0.035), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.065), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть исполнителя")
                }
            }
        }
        // Presentation modifiers outside NativeRoot's artworkScene do not
        // inherit its session. Every track row needs the same active instance.
        .environmentObject(togetherSession)
        .environment(\.nightwellBottomContentInset, 0)
        .preferredColorScheme(.dark)
        .tint(.white)
        .task(id: "\(name)|\(reloadRevision)") {
            #if DEBUG
            if usesPreviewTracks { return }
            #endif
            await load()
        }
    }

    private var playbackActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button { playAll(shuffled: false) } label: {
                Label("Слушать всё", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.black)
            }
            Button { playAll(shuffled: true) } label: {
                Label("Перемешать", systemImage: "shuffle")
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
    }

    private var trackCountText: String {
        let count = max(tracks.count, totalTracks ?? 0)
        let ending = count % 100
        let word = (11...14).contains(ending) ? "треков"
            : count % 10 == 1 ? "трек" : (2...4).contains(count % 10) ? "трека" : "треков"
        return "\(count) \(word)"
    }

    private func playAll(shuffled: Bool) {
        let queue = shuffled ? tracks.shuffled() : tracks
        guard let first = queue.first else { return }
        store.play(first, in: queue, wave: false)
    }

    @MainActor private func load() async {
        loading = true
        message = ""
        profileImageURL = store.artistResults.first {
            ArtistNames.normalized($0.name) == ArtistNames.normalized(name)
        }?.image_url
        totalTracks = nil
        var combined = (tracks + store.catalog + store.results).filter { ArtistNames.track($0, includes: name) }
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
                message = tracks.isEmpty ? "Не удалось загрузить каталог: " + error.localizedDescription
                    : "Не удалось обновить каталог. Загруженные треки доступны."
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
    @State private var loadedArtworkURL: URL?

    private var coverURL: URL? {
        track.flatMap { CoverImagePipeline.coverURL(for: $0, origin: origin) }
    }
    var body: some View {
        GeometryReader { box in
            ZStack {
                Color.white.opacity(0.08)
                if let artwork, loadedArtworkURL == coverURL {
                    Image(uiImage: artwork).resizable().scaledToFill()
                        .frame(width: box.size.width, height: box.size.height)
                        .clipped()
                } else {
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: box.size.width, height: box.size.height)
            .clipped()
        }
        .task(id: "\(coverURL?.absoluteString ?? "")#\(pixelWidth)") {
            guard let coverURL else { artwork = nil; loadedArtworkURL = nil; return }
            if loadedArtworkURL != coverURL { artwork = nil; loadedArtworkURL = nil }
            let image = await CoverImagePipeline.shared.image(for: coverURL, maxPixel: pixelWidth)
            guard !Task.isCancelled else { return }
            artwork = image
            loadedArtworkURL = image == nil ? nil : coverURL
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
    @State private var transferMethod = "neural"
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
    @State private var transferTask: Task<Void, Never>?
    @State private var matchedItems: [[String: Any]] = []
    @State private var matchingJobID: String?
    @State private var draftPlaylistID: String?
    @State private var alreadySavedIDs: Set<String> = []
    private let activeStates: Set<String> = ["reading", "matching", "saving"]
    struct ImportJob: Codable {
        struct MatchedItem: Codable {
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
                    Text("Обработка плейлиста проходит на iPhone, сервер выполняет только поиск треков и обычное сохранение плейлиста. Ненайденные треки можно экспортировать.")
                        .foregroundStyle(.secondary)
                    TextField("Название плейлиста", text: $name).focused($nameFieldFocused).submitLabel(.done).onSubmit { nameFieldFocused = false }.padding(14).nightwellLiquidGlass(18)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Способ переноса").font(.subheadline.weight(.semibold))
                        Picker("Способ переноса", selection: $transferMethod) {
                            Text("Обычный").tag("fast")
                            Text("С нейросетью").tag("neural")
                        }
                        .pickerStyle(.segmented)
                        .disabled(busy || saving)
                        if transferMethod == "neural" {
                            Label("Находит записи с опечатками, разным написанием имён и лишними приписками. Проверяет исполнителя, версию и длительность трека.", systemImage: "sparkles")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Быстрый локальный поиск совпадений. Меньше расходует заряд.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Точность совпадения", selection: $mode) {
                        Text("Точный").tag("safe")
                        Text("Умный").tag("balanced")
                        Text("Максимальный").tag("wide")
                    }.pickerStyle(.segmented).disabled(busy || saving)
                    Text(mode == "safe" ? "Точный: оригинальная запись, строгое совпадение названия, исполнителя и длительности." : mode == "balanced" ? "Умный: разные варианты написания и поиск исполнителя в названии или поле артиста. Сомнительные записи отсекаются." : "Максимальный: больше поисковых запросов и вариантов названий. Неподтверждённые совпадения требуют проверки.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { showingFile = true } label: { Label(selectedFilename.isEmpty ? "Выбрать JSON, CSV или TXT" : selectedFilename, systemImage: "doc.badge.plus").frame(maxWidth: .infinity).padding(16) }
                        .nightwellLiquidGlass(20)
                        .disabled(busy || saving)
                    Button(busy ? "Обрабатываем…" : "Найти треки") {
                        transferTask?.cancel()
                        transferTask = Task { await start() }
                    }
                        .buttonStyle(.borderedProminent).tint(Color(white: 0.24)).foregroundStyle(.white).disabled(contents.isEmpty || busy || saving)
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
                                        if !activeStates.contains(job.state), job.id == matchingJobID {
                                            Button {
                                                transferTask?.cancel()
                                                transferTask = Task { await start(retryMissing:true) }
                                            } label: {
                                                Label("Повторить ненайденные", systemImage:"arrow.clockwise")
                                            }.disabled(busy || saving)
                                        }
                                        ShareLink(item: missing.map { $0.artist + " — " + $0.title }.joined(separator: "\n")) {
                                            Label("Поделиться списком ненайденных", systemImage: "square.and.arrow.up")
                                        }
                                        .font(.subheadline.weight(.medium))
                                    }.padding(.top, 8)
                                }.tint(.white)
                            }
                            if (job.state == "ready" || job.state == "error") && job.matched > 0 && job.id == matchingJobID {
                                Button(saving ? "Добавляем…" : "Добавить") {
                                    transferTask = Task { await commit() }
                                }.buttonStyle(.borderedProminent).tint(Color(white: 0.24)).foregroundStyle(.white).disabled(busy || saving)
                            }
                            if activeStates.contains(job.state) {
                                Button("Остановить") { cancel() }.tint(.white)
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
                                }.buttonStyle(.plain).disabled(busy || saving)
                            }
                        }
                    }
                    if !errorText.isEmpty { Text(errorText).foregroundStyle(.white).font(.caption) }

                }.padding(20)
            }
            .background(Color(red: 0.045, green: 0.045, blue: 0.052))
             .task { await refreshHistory() }
             .onDisappear { transferTask?.cancel() }
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
    private var historyKey: String {
        "nw-transfer-local-history-v2|" + store.origin.absoluteString + "|" + (store.account?.id ?? "")
    }
    private func refreshHistory() async {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let saved = try? JSONDecoder().decode([ImportJob].self, from: data) else {
            history = []; historyError = ""; return
        }
        history = saved
        historyError = ""
    }
    private func remember(_ entry: ImportJob) {
        let summary = ImportJob(id: entry.id, state: entry.state, total: entry.total,
                                progress: entry.progress, matched: entry.matched, saved: entry.saved,
                                message: entry.message, name: entry.name, items: nil)
        history.removeAll { $0.id == entry.id }
        history.insert(summary, at: 0)
        history = Array(history.prefix(10))
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
    private func currentJob(state: String, progress: Int, total: Int, matched: Int,
                            saved: Int = 0, message: String, items: [ImportJob.MatchedItem]? = nil) -> ImportJob {
        ImportJob(id: job?.id ?? UUID().uuidString, state: state, total: total, progress: progress,
                  matched: matched, saved: saved, message: message, name: name, items: items ?? job?.items)
    }
    private func start(retryMissing: Bool = false) async {
        guard !busy, !saving else { return }
        if retryMissing {
            guard job?.id == matchingJobID, !matchedItems.isEmpty else { return }
        }
        busy = true
        defer { busy = false }
        errorText = ""
        if !retryMissing {
            job = nil; matchingJobID = nil; matchedItems = []; draftPlaylistID = nil; alreadySavedIDs = []
        }
        do {
            let selectedMode = mode
            let useNeuralMatching = transferMethod == "neural"
            var matching: [[String: Any]]
            if retryMissing {
                matching = matchedItems
            } else {
                let raw = contents
                job = currentJob(state:"reading",progress:0,total:0,matched:0,message:"Читаем список треков")
                matchingJobID = job?.id
                let prepared = try await Task.detached(priority:.userInitiated) {
                    try TransferPreparation.prepare(raw)
                }.value
                try Task.checkCancellation()
                let originals = try JSONSerialization.jsonObject(with:Data(prepared.utf8)) as? [[String:Any]] ?? []
                // The home catalogue is only a partial snapshot. Include known
                // favorites and cached playlists, and allow an empty snapshot:
                // the remote search is still able to find the imported tracks.
                var local = store.catalog + store.favoriteDisplayTracks + store.results
                for playlist in store.playlists { local += store.cachedPlaylistTracks(playlist.id) ?? [] }
                var seen = Set<String>()
                local = local.filter { seen.insert($0.id).inserted }
                let localCatalog = try JSONEncoder().encode(local)
                job = currentJob(state:"matching",progress:0,total:originals.count,matched:0,
                                 message:useNeuralMatching ? "Сопоставляем треки нейросетью" : "Ищем треки в медиатеке")
                let matchingTask = Task.detached(priority:.userInitiated) {
                    let rows = try useNeuralMatching
                        ? DeviceNeuralTransferMatcher.match(prepared:prepared,catalogJSON:localCatalog,mode:selectedMode)
                        : DeviceTransferMatcher.match(prepared:prepared,catalogJSON:localCatalog,mode:selectedMode)
                    return try JSONSerialization.data(withJSONObject:rows)
                }
                let data = try await withTaskCancellationHandler {
                    try await matchingTask.value
                } onCancel: { matchingTask.cancel() }
                matching = try JSONSerialization.jsonObject(with:data) as? [[String:Any]] ?? []
            }
            try Task.checkCancellation()
            matchedItems = matching
            let numberFound = matching.filter { $0["track_id"] as? String != nil }.count
            let unresolved: [(Int,String)] = try matching.enumerated().compactMap { index,row in
                guard row["track_id"] as? String == nil else { return nil }
                let data = try JSONSerialization.data(withJSONObject:[row])
                return (index,String(decoding:data,as:UTF8.self))
            }
            job = currentJob(state:"matching",progress:numberFound,total:matching.count,matched:numberFound,
                             message:"Ищем недостающие треки в источниках")
            let client = store.api
            let providers = TransferRemoteSearch.providers { provider, query in
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn:"&+=?#"))
                let encoded = query.addingPercentEncoding(withAllowedCharacters:allowed) ?? ""
                let result: TrackResult = try await client.request("/api/tracks?q=" + encoded + "&provider=" + provider,timeout:10)
                return TransferSearchSession.Page(catalogJSON:try JSONEncoder().encode(result.tracks),
                                                  pending:result.search_pending == true,retryAfter:result.search_retry_after)
            }
            for offset in stride(from:0,to:unresolved.count,by:3) {
                try Task.checkCancellation()
                let batch = Array(unresolved[offset..<min(offset+3,unresolved.count)])
                try await withThrowingTaskGroup(of:(Int,Data).self) { group in
                    for (index,original) in batch {
                        group.addTask {
                            let session = TransferRemoteSearch.providerSession(prepared:original,mode:selectedMode,
                                neural:useNeuralMatching,providers:providers)
                            let result = try await TransferRemoteSearch.match(prepared:original,mode:selectedMode,
                                neural:useNeuralMatching,session:session)
                            return (index,result)
                        }
                    }
                    for try await (index,data) in group {
                        if let result = try JSONSerialization.jsonObject(with:data) as? [String:Any] { matching[index] = result }
                        matchedItems = matching
                    }
                }
                let count = matching.filter { $0["track_id"] as? String != nil }.count
                let checked = numberFound + min(offset+3,unresolved.count)
                let items = matching.map { row in ImportJob.MatchedItem(title:row["title"] as? String ?? "",
                    artist:row["artist"] as? String ?? "",track_id:row["track_id"] as? String,reason:row["reason"] as? String) }
                job = currentJob(state:"matching",progress:checked,total:matching.count,matched:count,
                                 message:"Дополнительный поиск: \(min(offset+3,unresolved.count))/\(unresolved.count)",items:items)
                if let job { updateETA(job) }
            }
            try Task.checkCancellation()
            matchedItems = matching
            let summary = matching.map { row in ImportJob.MatchedItem(title:row["title"] as? String ?? "",
                artist:row["artist"] as? String ?? "",track_id:row["track_id"] as? String,reason:row["reason"] as? String) }
            let count = summary.filter { $0.track_id != nil }.count
            job = currentJob(state:"ready",progress:summary.count,total:summary.count,matched:count,
                             message:"Найдено \(count) из \(summary.count)",items:summary)
            etaText = ""
            if let job { remember(job) }
        } catch is CancellationError {
            errorText = "Поиск остановлен"
            let summary = matchedItems.map { row in ImportJob.MatchedItem(title:row["title"] as? String ?? "",
                artist:row["artist"] as? String ?? "",track_id:row["track_id"] as? String,reason:row["reason"] as? String) }
            let count = summary.filter { $0.track_id != nil }.count
            job = currentJob(state:"cancelled",progress:job?.progress ?? 0,total:summary.count,matched:count,
                             message:"Остановлено на устройстве",items:summary)
            if let job { remember(job) }
        } catch {
            errorText = error.localizedDescription
            if let current = job {
                job = currentJob(state:"error",progress:current.progress,total:current.total,
                                 matched:current.matched,message:error.localizedDescription)
            }
        }
    }
    private func commit() async {
        guard let current = job, current.id == matchingJobID, !busy, !saving,
              current.matched > 0, !matchedItems.isEmpty else { return }
        saving = true
        defer { saving = false }
        job = currentJob(state: "saving", progress: 0, total: current.total,
                         matched: current.matched, saved: alreadySavedIDs.count,
                         message: "Сохраняем плейлист…")
        do {
            var playlistID = draftPlaylistID
            if playlistID == nil {
                let playlist: Playlist = try await store.api.request("/api/playlists",
                    method: "POST", body: ["name": name])
                playlistID = playlist.id
                draftPlaylistID = playlist.id
            }
            guard let playlistID else { return }
            let available = matchedItems.compactMap { $0["track_id"] as? String }
            var seenIDs = Set<String>()
            let ids = available.filter { seenIDs.insert($0).inserted }
            var failures = 0
            for id in ids where !alreadySavedIDs.contains(id) {
                if Task.isCancelled { throw CancellationError() }
                do {
                    let _: OK = try await store.api.request("/api/playlists/" + playlistID + "/tracks/" + id,
                                                             method: "POST", body: [:])
                    alreadySavedIDs.insert(id)
                } catch is CancellationError { throw CancellationError() }
                catch { failures += 1 }
                if (alreadySavedIDs.count + failures).isMultiple(of: 5) {
                    job = currentJob(state: "saving", progress: ids.count, total: current.total,
                                     matched: current.matched, saved: alreadySavedIDs.count,
                                     message: "Сохраняем с iPhone: \(alreadySavedIDs.count)/\(ids.count)")
                }
            }
            let completed = alreadySavedIDs.count == ids.count
            job = currentJob(state: completed ? "done" : "error", progress: current.total,
                             total: current.total, matched: current.matched, saved: alreadySavedIDs.count,
                             message: completed ? "Плейлист готов. Добавлено \(alreadySavedIDs.count) треков." :
                                "Добавлено \(alreadySavedIDs.count). Не удалось сохранить \(failures). Нажми «Добавить» повторно.")
            if let job { remember(job) }
            await store.refresh()
        } catch {
            errorText = error.localizedDescription
            job = currentJob(state: "error", progress: current.total, total: current.total,
                             matched: current.matched, saved: alreadySavedIDs.count,
                             message: "Сохранение прервано. Можно повторить.")
        }
    }
    private func cancel() {
        transferTask?.cancel()
        errorText = "Перенос остановлен"
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
