import SwiftUI
import UniformTypeIdentifiers

@main struct NightwellMusicApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @StateObject private var store = MusicStore()
    var body: some Scene { WindowGroup { NativeRoot().environmentObject(store).preferredColorScheme(.dark) } }
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
let pumpkin = Color(red: 1, green: 0.72, blue: 0.43)
let nightwellViolet = Color(red: 0.19, green: 0.10, blue: 0.29)
let nightwellText = Color(red: 0.94, green: 0.88, blue: 0.97)
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

struct NativeRoot: View {
    @EnvironmentObject var store: MusicStore
    @State private var feature: PremiumFeatureView.Kind?
    @State private var settings = false
    @State private var waveSettingsPresented = false
    @State private var supportPresented = false
    @State private var premiumPresented = false
    @State private var transferPresented = false
    @State private var favoriteSort = "recent"
    @ObservedObject private var favoritePremium = PremiumFeatureState.shared
    @State private var fullPlayer = false
    @State private var sharedLinkID: String?
    @State private var backgroundOnly = false
    @State private var importFiles = false
    @State private var selectedPlaylist: Playlist?
    @State private var playlistName = ""
    @State private var createPlaylist = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var launching = true
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        ZStack {
            SeasonBackground()
            NativeFogLayer(active: !fullPlayer)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if !backgroundOnly && store.screen == .home {
                RibbonScene(playing: store.clock.playing, flash: store.likeFlash)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if backgroundOnly { BackgroundOnlyScene(clock: store.clock, lyrics: store.lyrics, flash: store.likeFlash) }
            if backgroundOnly {
                VStack { HStack { Button { backgroundOnly = false } label: { Image(systemName: "xmark").padding().glass() }; Spacer() }; Spacer() }.padding()
            } else {
                VStack(spacing: 18) {
                    header
                    content
                    MiniPlayer(clock: store.clock, open: { fullPlayer = true })
                        .padding(.horizontal, 16)
                        .padding(.bottom, 0)
                        .overlay(alignment: .bottom) {
                            if store.screen == .home {
                                HomeLyricLine(model: store.lyrics, clock: store.clock)
                                    .frame(height: 60)
                                    .padding(.horizontal, 24)
                                    .offset(y: -85)
                            }
                        }
                }
            }
        }
        .overlay {
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
                NightwellPopup(title: "", maxHeight: 610, close: { selectedPlaylist = nil }) {
                    PlaylistScreen(close: { selectedPlaylist = nil }, playlist: playlist)
                        .id(playlist.id)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: settings)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: store.authPresented)
        .tint(pumpkin)
        .sheet(isPresented: $premiumPresented) { PremiumView(api: store.api) }
        .overlay { if launching { NativeLaunch().transition(.opacity) } }
        .task { try? await Task.sleep(nanoseconds: reducedMotion ? 150_000_000 : 1_200_000_000); withAnimation(.easeOut(duration: 0.3)) { launching = false } }
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
        .simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { gesture in
            if gesture.startLocation.x < 24 && gesture.translation.width > 90 && abs(gesture.translation.height) < 60 { store.screen = .home }
        })
        .onChange(of: store.screen) { _ in if store.screen != .search { store.leaveSearch() } }
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
        
        .sheet(isPresented: $transferPresented) { NightwellNativeTransfer().environmentObject(store) }
        .sheet(isPresented: $showShare) { if let shareURL { ShareSheet(items: [shareURL]) } }
        .fileImporter(isPresented: $importFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await store.importFiles(urls) } }
        }
        .alert("Новый плейлист", isPresented: $createPlaylist) { TextField("Название", text: $playlistName); Button("Создать") { Task { await store.createPlaylist(playlistName); playlistName = "" } }; Button("Отмена", role: .cancel) {} }
        .alert("Nightwell Music", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("Понятно") { store.error = nil } } message: { Text(store.error ?? "") }
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
    private var header: some View {
        HStack {
            Button {
                withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) {
                    store.screen = .home
                }
            } label: {
                HStack(spacing: 9) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Nightwell").font(.system(size: 25, weight: .bold))
                        Text("M U S I C").font(.caption).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(nightwellText)
            .accessibilityLabel("На главную")
            Spacer()
            Button { if store.screen == .search { store.screen = .home } else { store.screen = .search } } label: { Image(systemName: store.screen == .search ? "xmark" : "magnifyingglass").font(.system(size: 19, weight: .medium)).foregroundStyle(pumpkin).frame(width: 44, height: 44).frostedGlass(22) }.accessibilityLabel(store.screen == .search ? "Закрыть поиск" : "Поиск")
            Menu {
                ForEach(MusicStore.Screen.allCases, id: \.self) { screen in Button(screen.rawValue) { store.screen = screen } }
                Divider()
                Button("Только фон", systemImage: "sparkles") { withAnimation(.easeInOut(duration: 0.22)) { backgroundOnly = true } }
                Button("Моя статистика", systemImage: "chart.bar") { feature = .statistics }
                Button("Nightwell Premium", systemImage: "star") { premiumPresented = true }
                Button("Перенести музыку", systemImage: "square.and.arrow.down") { transferPresented = true }
                Button("Настройки", systemImage: "gearshape") { settings = true }
                Button("Настройка подборки", systemImage: "slider.horizontal.3") { waveSettingsPresented = true }
                Button("Обращения и поддержка", systemImage: "envelope") { supportPresented = true }
                Button(store.account == nil ? "Войти" : "Выйти", systemImage: "person") { if store.account == nil { store.authPresented = true } else { Task { await store.logout() } } }
            } label: { Image(systemName: "line.3.horizontal").font(.system(size: 19, weight: .medium)).foregroundStyle(pumpkin).frame(width: 44, height: 44).frostedGlass(22) }.accessibilityLabel("Меню").sheet(item: $feature) { PremiumFeatureView(kind: $0).environmentObject(store) }
        }.padding(.horizontal, 20).padding(.top, 8)
    }
    private var favoriteTracks: [Track] {
        let entries = store.catalog.filter { store.likes.contains($0.id) }
        guard favoritePremium.allowed else { return entries }
        if favoriteSort == "title" { return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        if favoriteSort == "artist" { return entries.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending } }
        return entries
    }
    @ViewBuilder private var content: some View {
        switch store.screen {
        case .home:
            NativeHome(configureWave: { waveSettingsPresented = true }, clock: store.clock)
        case .search:
            VStack(alignment: .leading, spacing: 14) {
                Text("Поиск").font(.largeTitle.bold())
                HStack { Image(systemName: "magnifyingglass"); TextField("Трек или исполнитель", text: $store.query).textInputAutocapitalization(.never).autocorrectionDisabled().onChange(of: store.query) { _ in store.search() }; if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") } } }.padding(14)
                    .background { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial).opacity(0.48) }
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.28), lineWidth: 1))
                if !store.searchMessage.isEmpty { Text(store.searchMessage).font(.caption).foregroundStyle(.secondary) }
                TrackList(tracks: store.results)
            }.padding(.horizontal, 20)
        case .likes:
            VStack(alignment: .leading) { HStack { collectionHeading("Избранное", tracks: favoriteTracks, kind: "likes"); Spacer(); Menu { if favoritePremium.allowed { Button("Недавние") { favoriteSort = "recent" }; Button("По названию") { favoriteSort = "title" }; Button("По исполнителю") { favoriteSort = "artist" } } else { Button("Оформить Premium") { premiumPresented = true } } } label: { Label("Сортировка · Premium", systemImage: "arrow.up.arrow.down").font(.caption) } }; TrackList(tracks: favoriteTracks) }.padding(.horizontal, 20)
        case .playlists:
            VStack(alignment: .leading, spacing: 16) {
                Button("Умные плейлисты · Premium") { feature = .smart }
                HStack { Text("Плейлисты").font(.largeTitle.bold()); Spacer(); Button { createPlaylist = true } label: { Image(systemName: "plus") } }
                ScrollView { LazyVStack(spacing: 12) { ForEach(store.playlists) { p in
                    HStack { Button { selectedPlaylist = p } label: { Text(p.name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16) }; Menu {
                        Button("Скачать", systemImage: "arrow.down.to.line") { Task { do { await store.download(try await store.playlistTracks(p.id)) } catch { store.error = error.localizedDescription } } }
                        Button("Поделиться", systemImage: "square.and.arrow.up") { Task { shareURL = await store.share(kind: "playlist", playlist: p.id); showShare = shareURL != nil } }
                        Button("Удалить", role: .destructive) { Task { await store.deletePlaylist(p.id) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    }.padding(.horizontal, 18).glass()
                } } }
            }.padding(.horizontal, 20)
        case .offline:
            VStack(alignment: .leading, spacing: 16) { HStack { Text("Офлайн").font(.largeTitle.bold()); Spacer(); Button { importFiles = true } label: { Label("Файлы", systemImage: "folder") } }; Text("Музыка на этом устройстве — без входа").font(.caption).foregroundStyle(.secondary); TrackList(tracks: store.offline) }.padding(.horizontal, 20)
        }
    }
    private func collectionHeading(_ title: String, tracks: [Track], kind: String) -> some View {
        HStack { Text(title).font(.largeTitle.bold()); Spacer(); Menu {
            Button("Скачать всё", systemImage: "arrow.down.to.line") { Task { await store.download(tracks) } }
            Button("Поделиться", systemImage: "square.and.arrow.up") { Task { shareURL = await store.share(kind: kind); showShare = shareURL != nil } }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).glass() } }
    }
}

struct TrackList: View {
    @EnvironmentObject var store: MusicStore
    let tracks: [Track]
    var playlist: Playlist? = nil
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if tracks.isEmpty { Text(store.account == nil && store.screen != .offline ? "Войди в аккаунт или открой офлайн-файлы" : "Здесь пока нет треков").foregroundStyle(.secondary).padding(.top, 30) }
                ForEach(tracks) { track in NativeTrackRow(track: track, queue: tracks, status: store.clock.status, playlist: playlist) }
            }
        }.scrollDismissesKeyboard(.interactively)
    }
}
struct NativeTrackRow: View {
    @EnvironmentObject var store: MusicStore
    let track: Track
    let queue: [Track]
    @ObservedObject var status: TrackStatus
    var playlist: Playlist?
    var body: some View {
        HStack(spacing: 12) {
            Button { store.play(track, in: queue) } label: {
                HStack(spacing: 12) {
                    Cover(track: track, origin: store.origin).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(2); Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer(minLength: 0)
                    if status.id == track.id { PlayingIndicator(playing: status.playing).frame(width: 20, height: 20) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button(store.likes.contains(track.id) ? "Убрать из избранного" : "В избранное", systemImage: store.likes.contains(track.id) ? "heart.fill" : "heart") { Task { await store.like(track) } }
                Button("Скачать", systemImage: "arrow.down.to.line") { Task { await store.download([track]) } }
                ShareLink(item: store.origin.appendingPathComponent("track/" + track.id)) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                Menu("Добавить в плейлист") { ForEach(store.playlists) { p in Button(p.name) { Task { await store.add(track, playlist: p) } } } }
                if let playlist { Button("Убрать из плейлиста", role: .destructive) { Task { await store.add(track, playlist: playlist, remove: true) } } }
            } label: { Image(systemName: "ellipsis").frame(width: 34, height: 44) }
        }.padding(12).background(status.id == track.id ? pumpkin.opacity(0.12) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
}
struct Cover: View {
    let track: Track?
    let origin: URL
    var body: some View {
        AsyncImage(url: track?.cover_url.flatMap { URL(string: $0, relativeTo: origin) }) { image in image.resizable().scaledToFill() } placeholder: { ZStack { Color.purple.opacity(0.2); Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.7)) } }.clipped()
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
        ZStack {
            VStack(spacing: 18) {
                HStack {
                    Button { close() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).glass(24) }
                    Spacer()
                    Button { Task { await store.download(tracks) } } label: { Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44).glass(24) }
                }
                HStack { Text(playlist.name).font(.largeTitle.bold()); Spacer() }
                TrackList(tracks: tracks, playlist: playlist)
            }.padding(.horizontal, 20).padding(.top, 12)
        }.tint(pumpkin).task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-smoke-playlist") {
                tracks = [Track(id: "preview-one", title: "Музыка этой ночи", artist: "Nightwell Music"), Track(id: "preview-two", title: "Твой тёмный ритм", artist: "Nightwell Music")]
                return
            }
            #endif
            do { tracks = try await store.playlistTracks(playlist.id) } catch { store.error = error.localizedDescription }
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}



private struct NightwellNativeTransfer: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingFile = false
    @State private var name = "Перенос музыки"
    @State private var contents = ""
    @State private var mode = "balanced"
    @State private var job: ImportJob?
    @State private var errorText = ""
    @State private var busy = false
    struct ImportJob: Decodable {
        let id: String
        let state: String
        let total: Int
        let progress: Int
        let matched: Int
        let saved: Int
        let message: String?
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Перенести музыку").font(.largeTitle.bold())
                    Text("Поиск выполняется на сервере, файл читается на устройстве.").foregroundStyle(.secondary)
                    TextField("Название плейлиста", text: $name).padding(14).nightwellLiquidGlass(18)
                    Picker("Режим поиска", selection: $mode) {
                        Text("Точный").tag("safe")
                        Text("Умный").tag("balanced")
                        Text("Максимальный").tag("wide")
                    }.pickerStyle(.segmented)
                    Button { showingFile = true } label: { Label(contents.isEmpty ? "Выбрать JSON, CSV или TXT" : "Файл выбран", systemImage: "doc.badge.plus").frame(maxWidth: .infinity).padding(16) }
                        .nightwellLiquidGlass(20)
                    if let job {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(job.message ?? "Поиск").font(.headline)
                            ProgressView(value: Double(job.progress), total: Double(max(1, job.total)))
                            Text("Проверено: \(job.progress) / \(job.total) · Найдено: \(job.matched)").font(.caption).foregroundStyle(.secondary)
                            if job.state == "ready" || job.state == "error" {
                                Button("Добавить найденные треки") { Task { await commit() } }.buttonStyle(.borderedProminent)
                            }
                            if ["reading","matching","saving"].contains(job.state) {
                                Button("Остановить") { Task { await cancel() } }.tint(.orange)
                            }
                        }.padding(18).nightwellLiquidGlass(24)
                    }
                    if !errorText.isEmpty { Text(errorText).foregroundStyle(.orange).font(.caption) }
                    Button(busy ? "Обрабатываем…" : "Найти треки") { Task { await start() } }
                        .buttonStyle(.borderedProminent).disabled(contents.isEmpty || busy)
                }.padding(20)
            }
            .background(Color(red: 0.07, green: 0.04, blue: 0.12))
            .navigationTitle("Перенос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
            .fileImporter(isPresented: $showingFile, allowedContentTypes: [.json,.commaSeparatedText,.plainText]) { result in
                switch result {
                case .success(let url):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do { let data = try Data(contentsOf: url); guard data.count <= 1024*1024 else { errorText = "Файл больше 1 МБ"; return }; contents = String(data: data, encoding: .utf8) ?? ""; errorText = contents.isEmpty ? "Не удалось прочитать UTF-8" : "" }
                    catch { errorText = error.localizedDescription }
                case .failure(let failure): errorText = failure.localizedDescription
                }
            }
        }.preferredColorScheme(.dark)
    }
    private func start() async {
        busy = true; defer { busy = false }
        do {
            let result: ImportJob = try await store.api.request("api/imports", method: "POST", body: ["provider":"yandex","name":name,"url":"","text":contents,"mode":mode])
            job = result; errorText = ""; await poll(result.id)
        } catch { errorText = error.localizedDescription }
    }
    private func poll(_ id: String) async {
        while !Task.isCancelled {
            do {
                let next: ImportJob = try await store.api.request("api/imports/" + id)
                job = next
                if !["reading","matching","saving"].contains(next.state) { return }
                try await Task.sleep(nanoseconds: 1_800_000_000)
            } catch { errorText = error.localizedDescription; return }
        }
    }
    private func commit() async {
        guard let job else { return }
        do { let next: ImportJob = try await store.api.request("api/imports/" + job.id + "/commit",method:"POST",body:[:]); self.job = next; await poll(job.id) }
        catch { errorText = error.localizedDescription }
    }
    private func cancel() async {
        guard let job else { return }
        do { let next: ImportJob = try await store.api.request("api/imports/" + job.id + "/cancel",method:"POST",body:[:]); self.job = next }
        catch { errorText = error.localizedDescription }
    }
}
