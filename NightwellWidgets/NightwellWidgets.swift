
import SwiftUI
import WidgetKit
import AppIntents
import Security
import CryptoKit

private struct NWEntry: TimelineEntry {
    let date: Date
    let snapshot: NWWidgetState
    let cover: Data?
}
private struct NWProvider: TimelineProvider {
    func placeholder(in context: Context) -> NWEntry {
        NWEntry(date: .now, snapshot: NWWidgetState(trackID: "preview",
            title: "Пульс ночи", artist: "Nightwell Music",
            playing: true, coverID: nil, updated: .now), cover: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (NWEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NWEntry>) -> Void) {
        // WidgetKit may delay refreshes, but request a reasonable fallback
        // when the app cannot actively notify the extension.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(300))))
    }
    private func current() -> NWEntry {
        let data = NWWidgetStorage.read()
        return NWEntry(date: .now, snapshot: data, cover: NWWidgetStorage.cover(for: data))
    }
}
// Unlike App Group storage, widget pairing works even when the installed
// app and extension cannot share a container. A single-use code is exchanged
// for a revocable, high-entropy token kept only by the widget extension.
struct NWPairWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Nightwell Music"
    static var description = IntentDescription("Введи код из Профиль → Виджеты.")

    @Parameter(title: "Код привязки", default: "")
    var code: String
}

private enum NWPairTokenKeychain {
    private static let service = "fun.nightwell.music.widget.pairing.v1"
    private static func account(_ code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func query(_ code: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(code)]
    }
    static func read(_ code: String) -> String? {
        var query = query(code)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    static func store(_ token: String, for code: String) -> Bool {
        var item = query(code)
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    static func remove(_ code: String) { SecItemDelete(query(code) as CFDictionary) }
}

private struct NWPairResponse: Decodable { let token: String }
private struct NWRemoteState: Decodable {
    let track_id: String
    let title: String
    let artist: String
    let playing: Bool
    let has_cover: Bool
}

private enum NWWidgetRemote {
    private static let origin = URL(string: "https://music.nightwell.fun")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    static func load(code: String) async -> NWEntry {
        let normalized = code.uppercased().filter { $0.isHexDigit }
        guard normalized.count == 16 else {
            return message("Подключи виджет", "Введи код из профиля Nightwell Music")
        }
        var token = NWPairTokenKeychain.read(normalized)
        do {
            if token == nil {
                var request = URLRequest(url: origin.appendingPathComponent("api/widgets/pair"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["code": normalized])
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return message("Нет соединения", "Сервер пока недоступен")
                }
                if http.statusCode == 404 {
                    return message("Нужен серверный модуль", "Виджеты ещё не включены на сервере")
                }
                guard http.statusCode == 200,
                      let result = try? JSONDecoder().decode(NWPairResponse.self, from: data) else {
                    if http.statusCode == 401 || http.statusCode == 400 {
                        return message("Код истёк", "Создай новый код в профиле")
                    }
                    return message("Ошибка подключения", "Проверь сервер и повтори попытку")
                }
                guard NWPairTokenKeychain.store(result.token, for: normalized) else {
                    return message("Ошибка сохранения", "Не удалось сохранить ключ виджета")
                }
                token = result.token
            }

            guard let token else { return message("Ошибка привязки", "Повтори попытку") }
            var request = URLRequest(url: origin.appendingPathComponent("api/widgets/state"))
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return message("Нет соединения", "Повтори позже")
            }
            if http.statusCode == 401 {
                NWPairTokenKeychain.remove(normalized)
                return message("Привязка отозвана", "Создай новый код в профиле")
            }
            guard http.statusCode == 200,
                  let model = try? JSONDecoder().decode(NWRemoteState.self, from: data) else {
                return message("Сервер недоступен", "Повторная проверка позже")
            }

            let state = NWWidgetState(trackID: model.track_id,
                                     title: model.title.isEmpty ? "Твой ритм" : model.title,
                                     artist: model.artist.isEmpty ? "Nightwell Music" : model.artist,
                                     playing: model.playing,
                                     coverID: model.has_cover ? model.track_id : nil,
                                     updated: .now)
            var cover: Data?
            if model.has_cover {
                var coverRequest = URLRequest(url: origin.appendingPathComponent("api/widgets/cover"))
                coverRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                if let (bytes, imageResponse) = try? await session.data(for: coverRequest),
                   (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                   bytes.count < 240_000, UIImage(data: bytes) != nil {
                    cover = bytes
                }
            }
            return NWEntry(date: .now, snapshot: state, cover: cover)
        } catch {
            return message("Нет соединения", "Последняя музыка появится после обновления")
        }
    }

    static func message(_ title: String, _ subtitle: String) -> NWEntry {
        NWEntry(date: .now, snapshot: NWWidgetState(trackID: "", title: title,
                artist: subtitle, playing: false, coverID: nil, updated: .now), cover: nil)
    }
}

// Only a timeline may consume a single-use pairing code. Concurrent
// timeline requests for the same code share one network operation.
private actor NWWidgetLoadCoordinator {
    static let shared = NWWidgetLoadCoordinator()
    private var pending: [String: Task<NWEntry, Never>] = [:]

    func load(_ code: String) async -> NWEntry {
        if let task = pending[code] { return await task.value }
        let task = Task { await NWWidgetRemote.load(code: code) }
        pending[code] = task
        let entry = await task.value
        pending[code] = nil
        return entry
    }
}

private struct NWRemoteProvider: AppIntentTimelineProvider {
    private func setupEntry() -> NWEntry {
        // If the signed installation does support App Groups, the widget
        // can show a genuine local track even without a server pairing code.
        if NWWidgetStorage.isAvailable {
            let state = NWWidgetStorage.read()
            if !state.trackID.isEmpty {
                return NWEntry(date: .now, snapshot: state,
                               cover: NWWidgetStorage.cover(for: state))
            }
        }
        return NWWidgetRemote.message("Подключи виджет", "Код в профиле → Виджеты")
    }

    func placeholder(in context: Context) -> NWEntry {
        // Placeholders may appear outside the gallery. Never suggest that a
        // fictional track is playing on the user's device.
        NWWidgetRemote.message("Сейчас играет", "Nightwell Music")
    }
    func snapshot(for configuration: NWPairWidgetIntent, in context: Context) async -> NWEntry {
        if context.isPreview { return placeholder(in: context) }
        let code = configuration.code.uppercased().filter { $0.isHexDigit }
        guard code.count == 16 else { return setupEntry() }
        // Do not exchange a one-time code while the configuration UI asks
        // for a snapshot. The first live timeline will do the pairing.
        return NWWidgetRemote.message("Подключаем виджет", "Синхронизация с аккаунтом")
    }
    func timeline(for configuration: NWPairWidgetIntent, in context: Context) async -> Timeline<NWEntry> {
        let code = configuration.code.uppercased().filter { $0.isHexDigit }
        let entry: NWEntry
        if context.isPreview {
            entry = placeholder(in: context)
        } else if code.count != 16 {
            entry = setupEntry()
        } else {
            entry = await NWWidgetLoadCoordinator.shared.load(code)
        }
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300)))
    }
}

private struct NightwellWidgetSurface: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.065, green: 0.052, blue: 0.095)
                RadialGradient(
                    colors: [Color(red: 0.50, green: 0.17, blue: 0.47).opacity(0.40), .clear],
                    center: .topTrailing, startRadius: 8,
                    endRadius: max(geometry.size.width, geometry.size.height)
                )
                LinearGradient(colors: [.clear, .black.opacity(0.28)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

private struct NWArtwork: View {
    let data: Data?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.25, green: 0.21, blue: 0.52),
                            Color(red: 0.77, green: 0.26, blue: 0.54),
                            Color(red: 0.16, green: 0.12, blue: 0.32)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Circle()
                        .fill(Color(red: 1.0, green: 0.67, blue: 0.59).opacity(0.40))
                        .frame(width: geometry.size.width * 0.5)
                        .blur(radius: geometry.size.width * 0.08)
                        .offset(x: geometry.size.width * 0.16,
                                y: -geometry.size.height * 0.16)
                    Text("N")
                        .font(.system(size: min(geometry.size.width * 0.52, 56),
                                      weight: .black, design: .rounded))
                        .shadow(color: .black.opacity(0.3), radius: 9)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct NWPlayerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NWEntry

    @ViewBuilder var body: some View {
        // Public setup / loading text can be shown immediately. Genuine
        // listening history retains the system's privacy redaction.
        if entry.snapshot.trackID.isEmpty {
            playerContent.unredacted()
        } else {
            playerContent
        }
    }

    private var playerContent: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)
                    Text("N").font(.system(size: 25, weight: .black, design: .rounded))
                }.padding(3)
            case .accessoryRectangular:
                HStack(spacing: 7) {
                    Image(systemName: entry.snapshot.playing ? "waveform" : "music.note")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.snapshot.title)
                            .font(.caption.weight(.bold)).lineLimit(1)
                        Text(entry.snapshot.artist).font(.caption2).lineLimit(1)
                    }
                }
            case .systemMedium:
                HStack(spacing: 14) {
                    NWArtwork(data: entry.cover).frame(width: 115, height: 115)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NIGHTWELL MUSIC")
                            .font(.system(size: 10, weight: .bold)).tracking(1.1)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 1)
                        Text(entry.snapshot.title).font(.system(size: 19, weight: .bold)).lineLimit(2)
                        Text(entry.snapshot.artist).font(.subheadline)
                            .lineLimit(entry.snapshot.trackID.isEmpty ? 2 : 1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer(minLength: 1)
                        Image(systemName: entry.snapshot.trackID.isEmpty ? "music.note" :
                          (entry.snapshot.playing ? "waveform" : "pause.fill"))
                            .foregroundStyle(.white.opacity(0.7))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(16)
            case .systemLarge:
                VStack(alignment: .leading, spacing: 11) {
                    Text("NIGHTWELL").font(.system(size: 15, weight: .black)).tracking(2)
                    GeometryReader { proxy in
                        NWArtwork(data: entry.cover)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    Text(entry.snapshot.title).font(.title3.bold()).lineLimit(1)
                    Text(entry.snapshot.artist).font(.subheadline).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.65))
                }.padding(18)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text("N").font(.system(size: 18, weight: .black, design: .rounded))
                    Spacer(minLength: 0)
                    NWArtwork(data: entry.cover).frame(width: 58, height: 58)
                    Text(entry.snapshot.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                    Text(entry.snapshot.artist).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.65))
                }.padding(15)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { NightwellWidgetSurface() }
        .widgetURL(URL(string: entry.snapshot.trackID.isEmpty
            ? "nightwell://open/widget-setup"
            : "nightwell://open/player"))
    }
}

private struct NWShortcut: View {
    let label: String
    let symbol: String
    let destination: String
    var body: some View {
        Link(destination: URL(string: "nightwell://open/" + destination)!) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 16)
                Text(label).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .padding(10).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.white)
    }
}
private struct NWQuickWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 9) {
                    Text("N").font(.system(size: 38, weight: .black, design: .rounded))
                    Spacer()
                    Text("Твой ритм").font(.headline)
                    Text("Открыть Nightwell Music")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }.padding(15).widgetURL(URL(string: "nightwell://open/home"))
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    Text("NIGHTWELL").font(.system(size: 14, weight: .black)).tracking(1.5)
                    HStack(spacing: 8) {
                        VStack(spacing: 8) {
                            NWShortcut(label: "Избранное", symbol: "heart.fill", destination: "likes")
                            NWShortcut(label: "Поиск", symbol: "magnifyingglass", destination: "search")
                        }
                        VStack(spacing: 8) {
                            NWShortcut(label: "Твой ритм", symbol: "waveform", destination: "home")
                            NWShortcut(label: "Офлайн", symbol: "arrow.down.circle", destination: "offline")
                        }
                    }
                }.padding(15)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { NightwellWidgetSurface() }
        .unredacted()
    }
}
private struct NWNowPlaying: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "nightwell.nowplaying", intent: NWPairWidgetIntent.self, provider: NWRemoteProvider()) { entry in
            NWPlayerWidgetView(entry: entry)
        }
        .configurationDisplayName("Сейчас играет")
        .description("Текущий трек и обложка. Для синхронизации введи код из профиля Nightwell Music в настройках виджета.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular])
    }
}
private struct NWQuickAccess: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "nightwell.quickaccess", provider: NWProvider()) { _ in
            NWQuickWidgetView()
        }
        .configurationDisplayName("Быстрый доступ")
        .description("Поиск, избранное, офлайн и главный экран.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
@main struct NightwellWidgets: WidgetBundle {
    var body: some Widget {
        NWNowPlaying()
        NWQuickAccess()
    }
}
