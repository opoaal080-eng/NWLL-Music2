import SwiftUI
import UIKit
import QuartzCore
import UniformTypeIdentifiers

@main struct NightwellMusicApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @StateObject private var store = MusicStore()
    @AppStorage(NightwellAppearance.storageKey) private var themeID = NightwellAppearance.standard.rawValue
    @AppStorage("nw-first-run-completed-v1") private var firstRunCompleted = false
    var body: some Scene {
        WindowGroup {
            Group {
                if firstRunCompleted { NativeRoot() }
                else { NightwellFirstLaunch { firstRunCompleted = true } }
            }
            .environmentObject(store)
            .environment(\.nightwellAppearance, NightwellAppearance(rawValue: themeID) ?? .standard)
            .preferredColorScheme(.dark)
            .modifier(NightwellStudioIntro())
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
            .nightwellThemeChrome(radius)
    }
}

// iOS 26+ system Liquid Glass, with a translucent fallback on older versions.
extension View {
    @ViewBuilder func nightwellLiquidGlass(_ radius: CGFloat = 30) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
                .nightwellThemeChrome(radius)
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
    var style: UIBlurEffect.Style = .systemUltraThinMaterialDark
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        view.backgroundColor = .clear
        view.contentView.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        guard context.coordinator.intensity != intensity || context.coordinator.style != style else { return }
        let coordinator = context.coordinator
        coordinator.intensity = intensity
        coordinator.style = style
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            coordinator.apply(to: view)
        }
    }
    final class Coordinator {
        var intensity: CGFloat = -1
        var style: UIBlurEffect.Style = .systemUltraThinMaterialDark
        private var animator: UIViewPropertyAnimator?
        func apply(to view: UIVisualEffectView) {
            animator?.stopAnimation(true)
            let effect = UIBlurEffect(style: style)
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
    @Environment(\.nightwellAppearance) private var appearance
    var radius: CGFloat = 30
    var intensity: CGFloat = 1
    var body: some View {
        NativeBackdropBlur(intensity: intensity)
            .overlay(
                LinearGradient(
                    colors: appearance == .vice
                        ? [NightwellAppearance.pink.opacity(0.18),
                           NightwellAppearance.cyan.opacity(0.09),
                           NightwellAppearance.pink.opacity(0.05)]
                        : [Color.white.opacity(0.06), nightwellViolet.opacity(0.12), pumpkin.opacity(0.04)],
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
            .nightwellThemeChrome(radius)
    }
}

struct NightwellPopup<Content: View>: View {
    @Environment(\.nightwellAppearance) private var appearance
    let title: String
    var maxHeight: CGFloat = 600
    var dimsBackground = true
    var centered = false
    var transparentSettings = false
    var handlesBackGesture = true
    let close: () -> Void
    let content: Content
    init(title: String, maxHeight: CGFloat = 560, dimsBackground: Bool = true, centered: Bool = false, transparentSettings: Bool = false, handlesBackGesture: Bool = true, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.maxHeight = maxHeight
        self.dimsBackground = dimsBackground
        self.centered = centered
        self.transparentSettings = transparentSettings
        self.handlesBackGesture = handlesBackGesture
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
                    .background {
                        if appearance == .vice { NightwellViceBackdrop() }
                    }
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
        .nightwellEdgeBack(enabled: handlesBackGesture, onBack: close)
    }
}


private enum StableNavigationAction {
    case screen(MusicStore.Screen)
    case backgroundOnly, premium, accountAccess, transfer, settings, waveSettings, support, together, profile, authentication
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
                        if signedIn { entry("Устройства и семья", icon: "person.2", action: .accountAccess) }
                        Divider().overlay(.white.opacity(0.16)).padding(.vertical, 6)
                    }
                    if showsMainNavigation || opensAdditional {
                        entry("Слушать вместе", icon: "person.2.wave.2", action: .together)
                        if signedIn {
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
        .nightwellEdgeBack { dismiss() }
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
    @Environment(\.nightwellAppearance) private var appearance
    @EnvironmentObject var store: MusicStore
    @State private var feature: PremiumFeatureView.Kind?
    @State private var settings = false
    @State private var navigationMenuPresented = false
    @State private var initialSessionLoaded = false
    @State private var profilePresented = false
    @State private var widgetSetupPresented = false
    @State private var widgetLinkSetupPresented = false
    @State private var widgetIncomingCode: String?
    @State private var dailyPlaylistsPresented = false
    @State private var profileSigningOut = false
    @State private var pendingNavigation: StableNavigationAction?
    @State private var waveSettingsPresented = false
    @State private var supportPresented = false
    @State private var premiumPresented = false
    @State private var accountAccessPresented = false
    @State private var profileAccessPresented = false
    @State private var profilePremiumPresented = false
    @State private var profileStatisticsPresented = false
    @State private var libraryMenuStartsAdditional = false
    @State private var transferPresented = false
    @State private var togetherPresented = false
    @StateObject private var togetherSession = NightwellTogetherSession()
    @State private var favoriteSort = "recent"
    @StateObject private var librarySession = LibraryNavigationSession<MusicStore.Screen>(overview: .library)
    @AppStorage(NavigationLayout.storageKey) private var navigationLayout = NavigationLayout.belowPlayer
    @AppStorage("nw-ambient-lyrics") private var showHomeLyrics = true
    @State private var libraryScrollCollapsed: [String: Bool] = [:]
    @StateObject private var artworkPalette = NightwellArtworkPalette()
    @State private var remoteHomeCollapsed = false
    @AppStorage("nw-vice-nights-intro-viewed-v1") private var viceIntroViewed = false
    @AppStorage("nw-vice-nights-intro-acknowledged-v1") private var viceIntroAcknowledged = false
    @State private var viceIntroCollapsed = false
    @State private var openThemesDirectly = false
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
    @State private var searchScrollCollapsed = false
    @State private var searchRevealRequest = 0
    // Direction only belongs to user-initiated screen navigation. Playback,
    // library refreshes and scroll-position restoration must not animate it.
    @State private var screenTransitionDirection: CGFloat = 1
    @State private var screenBackHistory: [MusicStore.Screen] = []
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ViewBuilder private var mainScene: some View {
        GeometryReader { viewport in
            let landscape = viewport.size.width > viewport.size.height * 1.12 &&
                viewport.size.height < 650
            let bottomInset = dockContentInset(landscape: landscape) + viewport.safeAreaInsets.bottom + 12
            ZStack {
            // Standard stays visually identical to the previous version.
            if appearance == .vice {
                // Keep tropical artwork only on the three top-level tabs.
                // Favorites, playlists, offline, sheets and background-only
                // use the clean color-only Vice Nights backdrop.
                if !backgroundOnly &&
                    (store.screen == .home || store.screen == .search || store.screen == .library) {
                    NightwellViceScenicBackdrop().ignoresSafeArea()
                } else {
                    NightwellViceBackdrop().ignoresSafeArea()
                }
            } else {
                LinearGradient(
                    colors: [Color(red: 0.055, green: 0.062, blue: 0.074), Color(white: 0.025), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            if !backgroundOnly && appearance == .standard {
                // Keep one backdrop alive while the app changes tabs, pauses,
                // buffers audio, and restores a session after launch.
                RibbonScene(playing: store.clock.playing, flash: store.likeFlash,
                            active: store.screen == .home && !settings && !fullPlayer && selectedPlaylist == nil && !navigationMenuPresented && !profilePresented)
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
                    if !landscape && !isLibraryScreen &&
                        !(store.screen == .search && searchScrollCollapsed) &&
                        !viceIntroAcknowledged && !viceIntroViewed && !viceIntroCollapsed {
                        viceIntroBanner
                            .padding(.horizontal, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
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

    private var viceIntroBanner: some View {
        Button(action: openViceThemes) {
            HStack(spacing: 11) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NightwellAppearance.pink)
                    .frame(width: 36, height: 36)
                    .background(NightwellAppearance.pink.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Новая тема: Vice Nights")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Неоновый стиль GTA VI · Настроить")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.67))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(NightwellAppearance.pink.opacity(0.28), lineWidth: 0.9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Новая тема Vice Nights. Открыть темы")
    }

    private func openViceThemes() {
        // Both the banner and its compact button permanently acknowledge it.
        viceIntroAcknowledged = true
        viceIntroViewed = true
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) {
            viceIntroCollapsed = true
            openThemesDirectly = true
            settings = true
        }
    }

    private var viceIntroCompactButton: some View {
        Button(action: openViceThemes) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(NightwellAppearance.pink)
                .frame(width: 42, height: 44)
                .frostedGlass(22, bordered: false, intensity: 0.20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Новая тема Vice Nights. Открыть настройки темы")
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    private func dockContentInset(landscape: Bool) -> CGFloat {
        if navigationLayout.showsTabs { return landscape ? 102 : 118 }
        return landscape ? 54 : 70
    }

    private func playerDock(landscape: Bool) -> some View {
        VStack(spacing: navigationLayout.showsTabs ? (landscape ? 2 : 4) : 0) {
            MiniPlayer(clock: store.clock, open: { fullPlayer = true },
                       compactHeight: landscape, active: !fullPlayer && !settings && selectedPlaylist == nil && !profilePresented)
                .padding(.horizontal, landscape ? 18 : 16)
                .overlay(alignment: .bottom) {
                    if store.screen == .home && !landscape && showHomeLyrics {
                        HomeLyricLine(model: store.lyrics, clock: store.clock, active: !fullPlayer && !settings && selectedPlaylist == nil && !profilePresented)
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
            // Apply native backdrop blur at full strength, without a separate
            // translucent surface. Keep the controls in the sharp foreground layer.
            NativeBackdropBlur(intensity: 1, style: .regular)
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
                NightwellPopup(title: "", maxHeight: 554, dimsBackground: false, centered: true, transparentSettings: true, handlesBackGesture: false, close: { settings = false }) {
                    NativeSettings(close: {
                        settings = false
                        openThemesDirectly = false
                    }, startOnThemes: openThemesDirectly)
                }
            } else if let playlist = selectedPlaylist {
                NightwellPopup(title: "", maxHeight: 900, dimsBackground: false, centered: true, transparentSettings: true, close: { selectedPlaylist = nil }) {
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
        .tint(appearance.accent)
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
            PremiumFeatureView(kind: kind)
                .environmentObject(store)
                .nightwellEdgeBack { feature = nil }
        }
        .sheet(isPresented: $dailyPlaylistsPresented) {
            DailyPublicPlaylistsScreen(store: store, togetherSession: togetherSession)
                .nightwellEdgeBack { dailyPlaylistsPresented = false }
        }
        .fullScreenCover(isPresented: $profilePresented) {
            NavigationStack {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ProfileSettingsView()
                            .environmentObject(store)
                        if store.account != nil {
                            Button {
                                profileAccessPresented = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.2")
                                    Text("Устройства и семья")
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
                                widgetSetupPresented = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "square.grid.2x2")
                                    Text("Виджеты")
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
                        if favoritePremium.hasVerifiedPremium(for: store.account?.id) {
                            Button {
                                // Validate again at tap time in case Premium has expired
                                // while the profile remained on screen.
                                guard favoritePremium.hasVerifiedPremium(for: store.account?.id) else { return }
                                profileStatisticsPresented = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "chart.bar")
                                    Text("Статистика")
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
                // Keep the full-screen profile title centred independently
                // of the Done button. Native navigation bars truncate glass
                // toolbar controls on narrow iPhones and iOS 27.
                .safeAreaInset(edge: .top, spacing: 0) {
                    ZStack {
                        Text("Профиль")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        HStack {
                            Spacer(minLength: 0)
                            Button { profilePresented = false } label: {
                                Text("Готово")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 88, height: 44)
                                    .nightwellMonochromeGlass(radius: 22)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Закрыть профиль")
                        }
                    }
                    .frame(height:54)
                    .padding(.horizontal,18)
                    .padding(.vertical,7)
                    .background(.black.opacity(0.16))
                }
                .background { NightwellMonochromeGlassBackground() }
                .toolbar(.hidden, for: .navigationBar)
            }
            .preferredColorScheme(.dark)
            .nightwellEdgeBack { profilePresented = false }
            .sheet(isPresented: $profilePremiumPresented, onDismiss: {
                Task { await favoritePremium.refresh(store) }
            }) {
                PremiumView(api: store.api)
                    .nightwellEdgeBack { profilePremiumPresented = false }
            }
            .sheet(isPresented: $profileStatisticsPresented) {
                PremiumFeatureView(kind: .statistics).environmentObject(store)
                    .nightwellEdgeBack { profileStatisticsPresented = false }
            }
            .fullScreenCover(isPresented: $profileAccessPresented) {
                AccountAccessView(api: store.api, accountID: store.account?.id)
                    .nightwellEdgeBack { profileAccessPresented = false }
            }
            .sheet(isPresented: $widgetSetupPresented) {
                NWWidgetSetupView(api: store.api, initialCode: widgetIncomingCode)
                    .environmentObject(store)
                    .nightwellEdgeBack { widgetSetupPresented = false }
            }
        }
        .fullScreenCover(isPresented: $accountAccessPresented) {
            AccountAccessView(api: store.api, accountID: store.account?.id)
                .nightwellEdgeBack { accountAccessPresented = false }
        }
        .sheet(isPresented: $widgetLinkSetupPresented) {
            NWWidgetSetupView(api: store.api, initialCode: widgetIncomingCode)
                .environmentObject(store)
                .nightwellEdgeBack { widgetLinkSetupPresented = false }
        }
        .sheet(isPresented: $premiumPresented, onDismiss: {
            Task { await favoritePremium.refresh(store) }
        }) {
            PremiumView(api: store.api)
                .nightwellEdgeBack { premiumPresented = false }
        }
        .sheet(isPresented: $togetherPresented) {
            NightwellTogetherSheet(session: togetherSession, store: store)
                .nightwellEdgeBack { togetherPresented = false }
        }
    }

    var body: some View {
        navigationSheetsScene
        // Show the new theme only once in expanded form per installation.
        // The compact paintpalette remains until the user visits Themes.
        .task {
            guard !viceIntroAcknowledged, !viceIntroViewed else { return }
            do { try await Task.sleep(nanoseconds: 8_000_000_000) }
            catch { return }
            guard !viceIntroAcknowledged else { return }
            viceIntroViewed = true
            withAnimation(reducedMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82)) {
                viceIntroCollapsed = true
            }
        }
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
        // Native-style leading-edge Back: interactive, reversible, and only
        // on navigable screens. The full player owns horizontal track swipes.
        .nightwellEdgeBack(enabled: canEdgeNavigateBack,
                           excludedBottom: navigationLayout.showsTabs ? 152 : 88) {
            returnFromEdge()
        }
        .onChange(of: appearance) { _, _ in
            // Theme changes are published even when music is paused.
            // All WidgetKit families get a refresh after server confirmation.
            NWWidgetServerPublisher.shared.update(
                track: store.clock.current,
                playing: store.clock.playing,
                account: store.account?.id, api: store.api,
                origin: store.origin, force: true)
            // Reload happens only after the server confirms the new theme.
            // An earlier reload could render the previous palette and cause
            // WidgetKit to coalesce the subsequent correct refresh.
        }
        .onChange(of: store.screen) { oldScreen, newScreen in
            if isLibraryScreen && librarySession.lastVisited != newScreen { librarySession.remember(newScreen) }
            if oldScreen == .search { store.leaveSearch(); searchScrollCollapsed = false }
            if newScreen == .search { store.scheduleSearch() }
        }
        .onOpenURL { url in
            if openWidgetURL(url) {
                // Widget navigation handled
            } else if let code = NightwellTogetherSession.invitationCode(from: url.absoluteString, origin: store.origin) {
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
            // Fire immediately when the player changes tracks, rather than
            // relying on the next periodic playback tick. If the app is still
            // executing in the background, WidgetKit can receive a reload
            // as soon as the server acknowledges this song.
            NWWidgetServerPublisher.shared.update(
                track: store.clock.current,
                playing: store.clock.playing,
                account: store.account?.id,
                api: store.api,
                origin: store.origin)
            if let expected = sharedLinkID, id.lowercased() == expected.lowercased() {
                sharedLinkID = nil
                fullPlayer = true
            }
        }
        .onChange(of: store.clock.playing) { _, _ in
            NWWidgetServerPublisher.shared.update(
                track: store.clock.current,
                playing: store.clock.playing,
                account: store.account?.id,
                api: store.api,
                origin: store.origin)
        }
        .fullScreenCover(isPresented: $fullPlayer) { FullPlayer(clock: store.clock).environmentObject(togetherSession) }
        .sheet(item: $selectedArtist) { artist in
            ArtistProfileView(name: artist.name, togetherSession: togetherSession)
                .environmentObject(store)
                .nightwellEdgeBack { selectedArtist = nil }
        }

        .sheet(isPresented: $transferPresented) {
            NightwellNativeTransfer()
                .environmentObject(store)
                .nightwellEdgeBack { transferPresented = false }
        }
        .sheet(isPresented: $showShare) {
            if let shareText {
                ShareSheet(items: [shareText])
                    .nightwellEdgeBack { showShare = false }
            }
        }
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
        case .premium: premiumPresented = true
        case .accountAccess: accountAccessPresented = true
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
    private func openWidgetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "nightwell",
              url.host?.lowercased() == "open" else { return false }
        switch url.path.lowercased() {
        case "/home": navigate(to: .home)
        case "/likes": navigate(to: .likes)
        case "/search": navigate(to: .search)
        case "/offline": navigate(to: .offline)
        case "/widget-setup":
            if let supplied = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value {
                let challenge = supplied.uppercased().filter { $0.isHexDigit }
                if challenge.count == 16 {
                    widgetIncomingCode = stride(from: 0, to: 16, by: 4)
                        .map { start in
                            let from = challenge.index(challenge.startIndex, offsetBy: start)
                            let to = challenge.index(from, offsetBy: 4)
                            return String(challenge[from..<to])
                        }.joined(separator: "-")
                    // Copy for convenience, but the connection form is
                    // already prefilled even if clipboard access is disabled.
                    UIPasteboard.general.string = widgetIncomingCode
                }
            }
            if profilePresented {
                widgetSetupPresented = true
            } else {
                widgetLinkSetupPresented = true
            }
        case "/player":
            if store.clock.current != nil { fullPlayer = true }
            else { navigate(to: .home) }
        default: return false
        }
        return true
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

    private func navigationDepth(_ screen: MusicStore.Screen) -> Int {
        switch screen {
        case .home: return 0
        case .search: return 1
        case .library: return 2
        case .likes, .playlists, .offline: return 3
        }
    }

    private var screenChangeTransition: AnyTransition {
        if reducedMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: screenTransitionDirection * 26)),
            removal: .opacity.combined(with: .offset(x: -screenTransitionDirection * 14))
        )
    }

    private var canEdgeNavigateBack: Bool {
        // Popup sheets and full-screen presentations handle their own Back
        // gestures. Never steal a horizontal swipe from either music player.
        guard !fullPlayer && !settings && !waveSettingsPresented &&
              !supportPresented && !store.authPresented &&
              selectedPlaylist == nil && !navigationMenuPresented &&
              !profilePresented && !accountAccessPresented &&
              !premiumPresented && !togetherPresented else { return false }
        return backgroundOnly || store.screen != .home
    }

    private func returnFromEdge() {
        if backgroundOnly {
            backgroundOnly = false
            return
        }
        if store.screen == .likes || store.screen == .playlists || store.screen == .offline {
            navigate(to: .library, recordHistory: false)
            return
        }
        // Back follows real navigation history, instead of always jumping
        // straight to Home (the previous gesture did that from every tab).
        while let last = screenBackHistory.popLast() {
            if last != store.screen {
                navigate(to: last, recordHistory: false)
                return
            }
        }
        if store.screen != .home { navigate(to: .home, recordHistory: false) }
    }

    private func navigate(to screen: MusicStore.Screen, recordHistory: Bool = true) {
        guard store.screen != screen else { return }
        if recordHistory {
            if screenBackHistory.last == screen {
                screenBackHistory.removeLast()
            } else {
                screenBackHistory.append(store.screen)
                if screenBackHistory.count > 20 { screenBackHistory.removeFirst() }
            }
        }
        let oldDepth = navigationDepth(store.screen)
        let newDepth = navigationDepth(screen)
        // Keep back navigation moving in the opposite direction. Avoid
        // springing the entire layout and reinitialising large music lists.
        screenTransitionDirection = newDepth < oldDepth ? -1 : 1
        let animation: Animation? = reducedMotion ? nil : .easeInOut(duration: 0.23)
        withTransaction(Transaction(animation: animation)) {
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
            if !viceIntroAcknowledged && (viceIntroViewed || viceIntroCollapsed || landscape) {
                viceIntroCompactButton
            }
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
            .scaleEffect(selected && !reducedMotion ? 1.055 : 1)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.2), value: selected)
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
            if !viceIntroAcknowledged && (viceIntroViewed || viceIntroCollapsed || landscape) {
                viceIntroCompactButton
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
            if !viceIntroAcknowledged &&
                (viceIntroViewed || viceIntroCollapsed || landscape) &&
                compactCollectionTitle == nil {
                viceIntroCompactButton
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
    // Use monochrome SF Symbols until the playlist model exposes real artwork.
    private func playlistIcon(for name: String) -> String {
        let lowercased = name.lowercased()
        if lowercased.contains("нрав") || lowercased.contains("любим") ||
           lowercased.contains("favorite") || lowercased.contains("liked") {
            return "heart"
        }
        if lowercased.contains("перенос") || lowercased.contains("import") {
            return "arrow.left.arrow.right"
        }
        if lowercased.contains("новогод") || lowercased.contains("зимн") ||
           lowercased.contains("winter") || lowercased.contains("christmas") {
            return "snowflake"
        }
        return "music.note.list"
    }

    private func content(bottomContentInset: CGFloat) -> some View {
        // Animate the screen content only: the mini-player and tab bar stay
        // in place, so audio and artwork updates never jolt the whole layout.
        // Views from the outgoing screen are released after the brief fade.
        ZStack(alignment: .top) {
            screenContent(for: store.screen, bottomContentInset: bottomContentInset)
                .id(store.screen)
                .transition(screenChangeTransition)
        }
        .clipped()
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
                VStack(alignment: .leading, spacing: 18) {
                    collectionScrollMarker

                    // Match the opened-playlist layout, but display the actual
                    // gradient heart from the library instead of a cover mosaic.
                    HStack(alignment: .center, spacing: 16) {
                        NightwellFavoriteHeartArtwork(width: 104, height: 108)
                            .frame(width: 126, height: 130)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Избранное")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text(favoritesCountLabel(store.likes.count))
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white.opacity(0.60))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 14)

                    HStack(spacing: 10) {
                        Button {
                            guard let first = tracks.first else { return }
                            store.play(first, in: tracks)
                        } label: {
                            Label("Слушать", systemImage: "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                        .background(
                            appearance == .vice ? NightwellAppearance.gold : Color.white,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .disabled(tracks.isEmpty)
                        .opacity(tracks.isEmpty ? 0.55 : 1)

                        Button {
                            Task { await store.rhythm(around: tracks) }
                        } label: {
                            Label("Твой ритм", systemImage: "waveform.path")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(
                            appearance == .vice ? NightwellAppearance.pink.opacity(0.28) : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .disabled(tracks.isEmpty || store.loading)
                        .opacity(tracks.isEmpty ? 0.55 : 1)
                    }

                    HStack(spacing: 6) {
                        Text("ТРЕКИ")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.74))
                        Text("\(tracks.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                            .monospacedDigit()
                            .padding(.leading, 4)
                        Spacer()
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
                                .frame(width: 42, height: 42)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Сортировка избранного")

                        Menu {
                            if !tracks.isEmpty && tracks.allSatisfy({ store.isDownloaded($0) }) {
                                Button("Удалить загрузки", systemImage: "trash", role: .destructive) {
                                    Task { for track in tracks { await store.removeDownload(track) } }
                                }
                            } else {
                                Button("Скачать всё", systemImage: "arrow.down.to.line") {
                                    Task { await store.download(tracks) }
                                }
                            }
                            Button("Поделиться", systemImage: "square.and.arrow.up") {
                                Task {
                                    shareText = await store.share(kind: "likes", title: "Избранное", tracks: tracks)
                                    showShare = shareText != nil
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18))
                                .frame(width: 42, height: 42)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Действия с избранным")
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 4)

                    TrackList(tracks: tracks, embedded: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
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
                LazyVStack(alignment: .leading, spacing: 16) {
                    collectionScrollMarker

                    HStack(spacing: 12) {
                        Text("Плейлисты")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        Button { createPlaylist = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.075),
                                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(.white.opacity(0.11), lineWidth: 0.8)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Новый плейлист")
                    }
                    .padding(.top, 6)

                    HStack(spacing: 10) {
                        Text("Мои плейлисты")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(store.playlists.count)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.47))
                    }
                    .padding(.top, 7)

                    LazyVStack(spacing: 8) {
                        ForEach(store.playlists) { playlist in
                            HStack(spacing: 0) {
                                Button { selectedPlaylist = playlist } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: playlistIcon(for: playlist.name))
                                            .font(.system(size: 19, weight: .regular))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .frame(width: 44, height: 44)
                                            .background {
                                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                                    .fill(LinearGradient(
                                                        colors: [.white.opacity(0.14), .white.opacity(0.045)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                            }
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
                                            }
                                            .overlay {
                                                PlaylistDownloadRing(playlistID: playlist.id)
                                            }
                                            .accessibilityHidden(true)
                                        Text(playlist.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Открыть плейлист \(playlist.name)")

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
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 19, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.78))
                                        .frame(width: 44, height: 60)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Действия с плейлистом \(playlist.name)")
                            }
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .background {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [.white.opacity(0.075), .white.opacity(0.032)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.8)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    private func favoritesCountLabel(_ count: Int) -> String {
        let word: String
        if (11...14).contains(count % 100) { word = "треков" }
        else if count % 10 == 1 { word = "трек" }
        else if (2...4).contains(count % 10) { word = "трека" }
        else { word = "треков" }
        return "\(count) \(word)"
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
    @Environment(\.nightwellAppearance) private var appearance
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
    @State private var showPlaylistTrackActions = false
    var body: some View {
        HStack(spacing: 0) {
            // One large hit target so tapping the thumbnail, title, artist,
            // playback indicator, or empty area starts the song.
            Button {
                if let onPlay { onPlay() }
                else { store.play(track, in: queue) }
            } label: {
                HStack(spacing: 12) {
                    Cover(track: track, origin: store.origin, pixelWidth: libraryPreview ? 224 : 160,
                          cornerRadius: libraryPreview ? 8 : 12)
                        .frame(width: libraryPreview ? 56 : 46, height: libraryPreview ? 56 : 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(libraryPreview ? .body.weight(.medium) : .subheadline.weight(.semibold))
                            .lineLimit(libraryPreview ? 1 : 2)
                        Text(track.artist).font(libraryPreview ? .subheadline : .caption).foregroundStyle(.secondary)
                            .lineLimit(libraryPreview ? 1 : 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if store.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 20, height: 20)
                            .accessibilityLabel("Скачан, доступен офлайн")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: libraryPreview ? 56 : 54, alignment: .leading)
                .padding(.leading, libraryPreview ? 0 : 12)
                .padding(.vertical, libraryPreview ? 8 : 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Воспроизвести " + track.title)
            Group {
                if playlist != nil {
                    Button { showPlaylistTrackActions = true } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: libraryPreview ? 72 : 70)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
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
                } else if store.downloadProgress(track.id) != nil {
                    TrackDownloadMenuProgress(progress: store.downloadProgressPresentation, trackID: track.id)
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

                }
            }
            .padding(.trailing, 5)
            .accessibilityLabel("Действия с треком " + track.title)
        }
        .padding(.horizontal, libraryPreview ? 8 : 0)
        .background(
            appearance == .vice
                ? (status.id == track.id
                    ? NightwellAppearance.pink.opacity(0.13)
                    : (libraryPreview ? Color.clear
                        : Color(red: 0.18, green: 0.075, blue: 0.28).opacity(0.78)))
                : (status.id == track.id
                    ? Color.white.opacity(0.065)
                    : (libraryPreview ? Color.clear : Color.white.opacity(0.035))),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .nightwellThemeChrome(18)
        .overlay {
            if status.id == track.id {
                PlayingTrackOutline(playing: status.playing, tint: appearance.progressTint,
                                    secondaryTint: appearance == .vice ? appearance.accent : appearance.progressTint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(status.id == track.id ? (status.playing ? "Сейчас играет" : "На паузе") : "")
        .confirmationDialog("Выбери исполнителя", isPresented: $showArtistChoices, titleVisibility: .visible) {
            ForEach(ArtistNames.split(track.artist), id: \.self) { name in
                Button(name) { selectedArtist = ArtistSelection(name: name) }
            }
        }
        .sheet(item: $selectedArtist) { artist in
            ArtistProfileView(name: artist.name, togetherSession: togetherSession)
                .environmentObject(store)
                .nightwellEdgeBack { selectedArtist = nil }
        }
        .sheet(isPresented: $showPlaylistTrackActions) {
            if let playlist {
                NightwellPlaylistTrackSheet(track: track, playlist: playlist) { artist in
                    selectedArtist = ArtistSelection(name: artist)
                }
                .environmentObject(store)
                .environmentObject(togetherSession)
            }
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
    @Environment(\.nightwellAppearance) private var appearance
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
                NightwellThemedBackground {
                    LinearGradient(colors: [Color(red: 0.075, green: 0.065, blue: 0.105),
                                            Color(white: 0.025), .black],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }.ignoresSafeArea()
            }
            .navigationTitle("Исполнитель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance == .vice ? Color(red: 0.12, green: 0.055, blue: 0.19) : Color(white: 0.035), for: .navigationBar)
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
        .tint(appearance.accent)
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

/// A single, unmodified artwork layer with one rounded mask.
/// The former blurred second layer was visible outside the radius and
/// produced coloured triangular corner wedges on top of the player backdrop.
struct CoverArtworkSurface: View {
    let image: UIImage
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: max(0, cornerRadius),
                                            style: .continuous))
        }
    }
}

struct Cover: View {
    let track: Track?
    let origin: URL
    var pixelWidth = 160
    var cornerRadius: CGFloat = 0
    @State private var artwork: UIImage?
    @State private var loadedArtworkKey = ""

    private var coverURL: URL? {
        track.flatMap { CoverImagePipeline.coverURL(for: $0, origin: origin) }
    }
    private var artworkKey: String {
        [track?.id ?? "", track?._offline_account ?? "",
         track?._offline == true ? "offline" : "online",
         coverURL?.absoluteString ?? "", String(pixelWidth)].joined(separator: "|")
    }

    var body: some View {
        GeometryReader { box in
            ZStack {
                if let artwork, loadedArtworkKey == artworkKey {
                    CoverArtworkSurface(image: artwork, cornerRadius: cornerRadius)
                        .frame(width: box.size.width, height: box.size.height)
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius,
                                                style: .continuous))
                }
            }
            .frame(width: box.size.width, height: box.size.height)
            .clipped()
        }
        .task(id: artworkKey) {
            let requested = artworkKey
            if loadedArtworkKey != requested { artwork = nil; loadedArtworkKey = "" }
            var image: UIImage?
            if let track, track._offline == true {
                let owner = track._offline_account ?? "device"
                image = await Task.detached(priority: .utility) {
                    OfflineStore.cover(origin: origin, account: owner, id: track.id)
                }.value
            }
            if image == nil, let coverURL {
                image = await CoverImagePipeline.shared.image(for: coverURL,
                                                              maxPixel: pixelWidth)
            }
            guard !Task.isCancelled else { return }
            // Display the original decoded artwork. The previous corner-repair
            // algorithm modified faces and other deliberately dark regions.
            // Rounded geometry is handled only by CoverArtworkSurface.
            artwork = image
            loadedArtworkKey = image == nil ? "" : requested
            if let image, let track {
                NativePlayer.shared.acceptDisplayedArtwork(image, trackID: track.id, origin: origin)
            }
        }
    }
}
// Animate on Core Animation's render server, not on the SwiftUI row.
// The light moves a fixed distance along the perimeter (including corners).
private struct PlayingTrackOutline: UIViewRepresentable {
    let playing: Bool
    let tint: Color
    let secondaryTint: Color
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced

    func makeUIView(context: Context) -> TrackLightView {
        let view = TrackLightView()
        view.configure(playing: playing, animate: playing && !reduced && scene == .active,
                       primary: UIColor(tint), secondary: UIColor(secondaryTint))
        return view
    }

    func updateUIView(_ view: TrackLightView, context: Context) {
        view.configure(playing: playing, animate: playing && !reduced && scene == .active,
                       primary: UIColor(tint), secondary: UIColor(secondaryTint))
    }

    static func dismantleUIView(_ view: TrackLightView, coordinator: ()) {
        view.stopMotion()
    }

    final class TrackLightView: UIView {
        private let base = CAShapeLayer()
        private let trails = (0..<8).map { _ in CAShapeLayer() }
        private let motionKey = "nightwell.track.perimeter"
        private var playing = false
        private var animate = false
        private var primary = UIColor.white
        private var secondary = UIColor.white
        private var laidOutSize = CGSize.zero
        private var dirty = true

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            layer.addSublayer(base)
            for shape in trails {
                shape.fillColor = nil
                shape.lineCap = .round
                layer.addSublayer(shape)
            }
            base.fillColor = nil
        }
        required init?(coder: NSCoder) { nil }

        func configure(playing: Bool, animate: Bool, primary: UIColor, secondary: UIColor) {
            guard self.playing != playing || self.animate != animate ||
                    !self.primary.isEqual(primary) || !self.secondary.isEqual(secondary) else { return }
            self.playing = playing
            self.animate = animate
            self.primary = primary
            self.secondary = secondary
            dirty = true
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopMotion() }
            else { dirty = true; setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard dirty || laidOutSize != bounds.size else { return }
            dirty = false
            laidOutSize = bounds.size
            rebuild()
        }

        func stopMotion() {
            for shape in trails { shape.removeAnimation(forKey: motionKey) }
            dirty = true
        }

        private func rebuild() {
            stopMotion()
            dirty = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            let rect = CGRect(origin: .zero, size: bounds.size).insetBy(dx: 2.5, dy: 2.5)
            guard rect.width > 2, rect.height > 2 else {
                base.path = nil
                for shape in trails { shape.path = nil }
                return
            }
            let radius = min(15.5, min(rect.width, rect.height) / 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
            let perimeter = 2 * (rect.width + rect.height - 4 * radius) + 2 * CGFloat.pi * radius

            base.frame = CGRect(origin: .zero, size: bounds.size)
            base.path = path
            base.strokeColor = primary.withAlphaComponent(playing ? 0.10 : 0.20).cgColor
            base.lineWidth = 0.8

            // Overlapping, progressively brighter rounded strokes give a soft
            // tail and a luminous head, with no realtime Gaussian blur.
            let widths: [CGFloat] = [4.8, 2.8, 1.6, 1.1]
            let lengths: [CGFloat] = [0.23, 0.18, 0.12, 0.065]
            let opacity: [CGFloat] = [0.09, 0.22, 0.52, 0.94]
            let now = CACurrentMediaTime()
            for (index, shape) in trails.enumerated() {
                let side = index / 4
                let detail = index % 4
                let color = side == 0 ? primary : secondary
                let dash = perimeter * lengths[detail]
                // Keep each shorter stroke near the moving head.
                let offset = perimeter * (CGFloat(side) * 0.5 + lengths[0] - lengths[detail])
                shape.frame = CGRect(origin: .zero, size: bounds.size)
                shape.path = path
                shape.lineWidth = widths[detail]
                shape.strokeColor = color.withAlphaComponent(opacity[detail]).cgColor
                shape.lineDashPattern = [NSNumber(value: Double(dash)),
                                         NSNumber(value: Double(perimeter - dash))]
                shape.lineDashPhase = -offset
                shape.isHidden = !playing
                guard playing, animate, window != nil else { continue }

                // A full revolution returns to the same dash pattern, so the
                // repeat boundary has no jump. No wall-clock SwiftUI state.
                let motion = CABasicAnimation(keyPath: "lineDashPhase")
                motion.fromValue = Double(-offset)
                motion.toValue = Double(-offset - perimeter)
                motion.duration = 4.2
                motion.repeatCount = .infinity
                motion.timingFunction = CAMediaTimingFunction(name: .linear)
                motion.beginTime = shape.convertTime(now, from: nil)
                shape.add(motion, forKey: motionKey)
            }
        }
    }
}

private struct TrackDownloadMenuProgress: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var progress: DownloadProgressPresentation
    let trackID: String
    var body: some View {
        Text("Скачивание \(Int((store.downloadProgress(trackID) ?? 0) * 100))%")
    }
}

// A thin, determinate download ring around the playlist artwork. Keep
// the symbol visible and avoid decoding cached playlists on each byte update.
private struct PlaylistDownloadRing: View {
    @EnvironmentObject private var store: MusicStore
    let playlistID: String
    @State private var trackIDs: [String] = []

    var body: some View {
        PlaylistDownloadRingContent(progress: store.downloadProgressPresentation, trackIDs: trackIDs)
        .allowsHitTesting(false)
        // Refresh cache only when jobs start or finish, not on every progress tick.
        .task(id: store.pendingDownloadKeys) {
            trackIDs = (store.cachedPlaylistTracks(playlistID) ?? []).map(\.id)
        }
    }
}

private struct PlaylistDownloadRingContent: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var progress: DownloadProgressPresentation
    let trackIDs: [String]
    var body: some View {
        if let fraction = store.playlistDownloadProgress(trackIDs: trackIDs) {
            ZStack {
                Circle().stroke(.white.opacity(0.20), lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(3)
            .animation(.easeOut(duration: 0.2), value: fraction)
        }
    }
}

private struct PlaylistDownloadProgressView: View {
    @Environment(\.nightwellAppearance) private var appearance
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var progress: DownloadProgressPresentation
    let tracks: [Track]
    var body: some View {
        if let fraction = store.playlistDownloadProgress(tracks) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Скачивание плейлиста").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                }.foregroundStyle(.white.opacity(0.65))
                ProgressView(value: fraction).tint(appearance.progressTint)
            }.padding(.horizontal, 4)
        }
    }
}

struct PlaylistScreen: View {
    @Environment(\.nightwellAppearance) private var appearance
    @EnvironmentObject private var store: MusicStore
    let close: () -> Void
    let playlist: Playlist
    // Daily collections already contain their tracks in the daily feed.
    // Opening them should use that snapshot instead of requesting a regular
    // playlist URL, which does not exist until the collection is saved.
    let previewTracks: [Track]?
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    init(close: @escaping () -> Void, playlist: Playlist, previewTracks: [Track]? = nil) {
        self.close = close
        self.playlist = playlist
        self.previewTracks = previewTracks
        self._tracks = State(initialValue: previewTracks ?? [])
    }

    private var allDownloaded: Bool {
        !tracks.isEmpty && tracks.allSatisfy { store.isDownloaded($0) }
    }

    private var trackCountLabel: String {
        let count = tracks.count
        let word: String
        if (11...14).contains(count % 100) { word = "треков" }
        else if count % 10 == 1 { word = "трек" }
        else if (2...4).contains(count % 10) { word = "трека" }
        else { word = "треков" }
        return "\(count) \(word)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("ПЛЕЙЛИСТ")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(appearance == .vice
                                     ? NightwellAppearance.cyan.opacity(0.88)
                                     : .white.opacity(0.55))
                Spacer()
                Button { Task { await toggleDownloads() } } label: {
                    Image(systemName: allDownloaded ? "checkmark.circle.fill" : "arrow.down.to.line")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 42, height: 42)
                        .background(appearance == .vice
                                    ? NightwellAppearance.pink.opacity(0.24)
                                    : Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)
                .accessibilityLabel(allDownloaded ? "Удалить загрузки плейлиста" : "Скачать плейлист")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(appearance == .vice
                                    ? NightwellAppearance.pink.opacity(0.24)
                                    : Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть плейлист")
            }
            .padding(.horizontal, 21)
            .padding(.top, 14)
            .padding(.bottom, 13)

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 17) {
                        playlistArtwork
                        VStack(alignment: .leading, spacing: 8) {
                            Text(playlist.name)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(trackCountLabel)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 8)

                    HStack(spacing: 10) {
                        Button {
                            guard let first = tracks.first else { return }
                            store.play(first, in: tracks)
                        } label: {
                            Label("Слушать", systemImage: "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.black)
                        .background(
                            appearance == .vice ? NightwellAppearance.gold : Color.white,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .disabled(tracks.isEmpty)
                        .opacity(tracks.isEmpty ? 0.55 : 1)

                        Button {
                            let selected = playlist
                            let dailyTracks = previewTracks
                            close()
                            if let dailyTracks {
                                Task { await store.rhythm(around: dailyTracks) }
                            } else {
                                Task { await store.rhythm(around: selected) }
                            }
                        } label: {
                            Label("Твой ритм", systemImage: "waveform.path")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(
                            appearance == .vice
                                ? NightwellAppearance.pink.opacity(0.28)
                                : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .nightwellThemeChrome(18)
                    }

                    PlaylistDownloadProgressView(progress: store.downloadProgressPresentation, tracks: tracks)

                    HStack(alignment: .firstTextBaseline) {
                        Text("ТРЕКИ")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.74))
                        Spacer()
                        Text("\(tracks.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 3)

                    if tracks.isEmpty {
                        VStack(spacing: 12) {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                                Text("Загружаем треки")
                            } else {
                                Image(systemName: loadFailed ? "wifi.exclamationmark" : "music.note.list")
                                    .font(.system(size: 26))
                                Text(loadFailed ? "Не удалось загрузить треки" : "В плейлисте пока нет треков")
                                if loadFailed {
                                    Button("Попробовать ещё") {
                                        Task { await refreshPlaylist() }
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                }
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.60))
                        .frame(maxWidth: .infinity, minHeight: 130)
                    } else {
                        TrackList(tracks: tracks, playlist: previewTracks == nil ? playlist : nil, embedded: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(.white)
        .tint(appearance.progressTint)
        .background {
            // The theme must be drawn inside the playlist, above the popup's
            // dark glass layer, rather than behind it.
            NightwellThemedBackground {
                Color(white: 0.065)
            }
            .ignoresSafeArea()
        }
        .task(id: playlist.id) { await refreshPlaylist() }
    }

    private var playlistArtwork: some View {
        Group {
            if tracks.count >= 2 {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)],
                    spacing: 2
                ) {
                    ForEach(0..<4, id: \.self) { index in
                        Group {
                            if tracks.indices.contains(index) {
                                Cover(track: tracks[index], origin: store.origin, pixelWidth: 224)
                            } else {
                                Rectangle().fill(.white.opacity(0.08))
                            }
                        }
                        .frame(width: 57, height: 57)
                        .clipped()
                    }
                }
            } else if let first = tracks.first {
                Cover(track: first, origin: store.origin, pixelWidth: 300)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.24), Color(white: 0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note.list")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: 116, height: 116)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous),
                   style: FillStyle(antialiased: true))
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .accessibilityHidden(true)
    }

    private func toggleDownloads() async {
        guard !tracks.isEmpty else { return }
        if allDownloaded {
            for track in tracks { await store.removeDownload(track) }
        } else {
            await store.download(tracks.filter { !store.isDownloaded($0) })
        }
    }

    private func refreshPlaylist() async {
        if let previewTracks {
            // The daily playlist is a read-only snapshot, not a stored user
            // playlist. Never try /api/playlists/<daily-id>/tracks here.
            tracks = previewTracks
            isLoading = false
            loadFailed = false
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-smoke-playlist") {
            tracks = [
                Track(id: "preview-one", title: "Музыка этой ночи", artist: "Nightwell Music"),
                Track(id: "preview-two", title: "Твой тёмный ритм", artist: "Nightwell Music")
            ]
            return
        }
        #endif
        // Show the device snapshot immediately; networking must not blank it.
        let cached = store.cachedPlaylistTracks(playlist.id)
        if let cached { tracks = cached }
        isLoading = cached == nil
        loadFailed = false
        do {
            let fresh = try await store.playlistTracks(playlist.id)
            guard !Task.isCancelled else { return }
            tracks = fresh
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = cached == nil
            if cached == nil { store.error = error.localizedDescription }
        }
        isLoading = false
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}



struct NightwellNativeTransfer: View {
    @Environment(\.nightwellAppearance) private var appearance
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
            .background {
                NightwellThemedBackground { Color(red: 0.045, green: 0.045, blue: 0.052) }
                    .ignoresSafeArea()
            }
            .tint(appearance.accent)
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
