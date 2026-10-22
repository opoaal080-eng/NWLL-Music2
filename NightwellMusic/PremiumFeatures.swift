import SwiftUI
import Combine

struct PremiumPreferences: Codable {
    var bands = [0.0,0,0,0,0]
    var presets: [String:[Double]] = [:]
    var theme = "nightwell"
    var ribbon_speed = 1.0
    var ribbon_intensity = 1.0
    var aura_voice = true
    var aura_low = true
    var aura_mid = true
    var aura_high = true
    enum CodingKeys: String, CodingKey { case bands, presets, theme, ribbon_speed, ribbon_intensity }
    init() {}
    init(from decoder: Decoder) throws {
        let x = try decoder.container(keyedBy: CodingKeys.self)
        bands = try x.decodeIfPresent([Double].self, forKey: .bands) ?? [0,0,0,0,0]
        presets = try x.decodeIfPresent([String:[Double]].self, forKey: .presets) ?? [:]
        theme = try x.decodeIfPresent(String.self, forKey: .theme) ?? "nightwell"
        ribbon_speed = try x.decodeIfPresent(Double.self, forKey: .ribbon_speed) ?? 1
        ribbon_intensity = try x.decodeIfPresent(Double.self, forKey: .ribbon_intensity) ?? 1
    }
    var dictionary: [String:Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String:Any] ?? [:] }
}
@MainActor final class PremiumFeatureState: ObservableObject {
    static let shared = PremiumFeatureState()
    static let presets: [(String,[Double])] = [("Без изменений",[0,0,0,0,0]),("Бас",[4,2,0,-1,0]),("Вокал",[-2,0,3,2,-1]),("Мягкий звук",[1,0,-1,-2,-3])]
    @Published var preferences = PremiumPreferences()
    @Published var allowed = false
    @Published var note = "Проверяем Premium…"
    private var owner: String?, until = 0.0, checked = Date.distantPast, checking = false
    private func cacheKey(_ id: String) -> String { "nw-aura-" + id }
    private func restore(_ id: String) { if let d = UserDefaults.standard.data(forKey: cacheKey(id)), let x = try? JSONDecoder().decode(PremiumPreferences.self, from: d) { preferences.theme = x.theme; preferences.ribbon_speed = x.ribbon_speed; preferences.ribbon_intensity = x.ribbon_intensity; preferences.aura_voice = UserDefaults.standard.object(forKey: cacheKey(id)+"-voice") as? Bool ?? true; preferences.aura_low = UserDefaults.standard.object(forKey: cacheKey(id)+"-low") as? Bool ?? true; preferences.aura_mid = UserDefaults.standard.object(forKey: cacheKey(id)+"-mid") as? Bool ?? true; preferences.aura_high = UserDefaults.standard.object(forKey: cacheKey(id)+"-high") as? Bool ?? true } }
    func saveAppearance(_ store: MusicStore) async { guard allowed, let id = owner, id == store.account?.id else { return }; if let d = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(d, forKey: cacheKey(id)) }; UserDefaults.standard.set(preferences.aura_voice, forKey: cacheKey(id)+"-voice")
        UserDefaults.standard.set(preferences.aura_low, forKey: cacheKey(id)+"-low")
        UserDefaults.standard.set(preferences.aura_mid, forKey: cacheKey(id)+"-mid")
        UserDefaults.standard.set(preferences.aura_high, forKey: cacheKey(id)+"-high")
        await save(store) }
    func reset() { allowed = false; until = 0; preferences = PremiumPreferences(); apply() }
    func apply() { NativePlayer.shared.setPremiumSound(allowed && Date().timeIntervalSince1970 < until ? preferences.bands : [0,0,0,0,0], until: until) }
    func tick(_ store: MusicStore) {
        if owner != store.account?.id || allowed && Date().timeIntervalSince1970 >= until { reset(); owner = store.account?.id; checked = .distantPast }
        if !checking && Date().timeIntervalSince(checked) > 300 { checked = Date(); Task { await refresh(store) } }
    }
    func refresh(_ store: MusicStore) async {
        if checking {
            while checking { do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return } }
            if owner != store.account?.id { await refresh(store) }; return
        }
        checking = true; checked = Date(); defer { checking = false }
        let account = store.account?.id; owner = account; reset()
        guard account != nil else { note = "Войдите в аккаунт. Для этой функции нужен Premium."; return }
        struct Status: Decodable { let premium: Bool; let expires_at: Double? }
        struct Response: Decodable { let preferences: PremiumPreferences }
        do {
            let state: Status = try await store.api.request("api/premium/me")
            guard store.account?.id == account else { return }
            guard state.premium, let expiry = state.expires_at, expiry > Date().timeIntervalSince1970 else { note = "Для этой функции нужен Premium. Музыку можно слушать бесплатно."; return }
            let response: Response = try await store.api.request("api/premium/preferences")
            guard store.account?.id == account else { return }
            preferences = response.preferences; restore(account!); until = expiry; allowed = true; note = "Настройки сохраняются в вашем аккаунте."; apply()
        } catch { note = "Не удалось проверить Premium. Проверьте соединение." }
    }
    func save(_ store: MusicStore) async {
        guard allowed, owner == store.account?.id, Date().timeIntervalSince1970 < until else { reset(); note = "Нужен действующий Premium."; return }
        struct Response: Decodable { let preferences: PremiumPreferences }
        let account = owner
        do { let _: Response = try await store.api.request("api/premium/preferences", method: "PUT", body: preferences.dictionary)
            // Live controls may have changed while the request was in flight.
            // A save acknowledgement must never restore an older audible curve.
            guard store.account?.id == account else { reset(); return }; apply(); note = "Настройки сохранены."
        } catch { note = error.localizedDescription }
    }
}

@MainActor struct PremiumFeatureView: View {
    enum Kind: String, Identifiable { case sound = "Эквалайзер", appearance = "Оформление", smart = "Умные плейлисты", statistics = "Моя статистика"; var id: String { rawValue } }
    let kind: Kind
    init(kind: Kind) { self.kind = kind }
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var premium = PremiumFeatureState.shared
    @State private var preset = ""
    @State private var name = ""
    @State private var ruleName = ""
    @State private var ruleKind = "favorites"
    @State private var rules: [SmartRule] = []
    @State private var statistics: PremiumStatistics?
    @State private var busy = false
    @State private var soundReady = false
    @State private var soundStatus = "Запустите трек и выберите пресет."
    @State private var showPresetOptions = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                Text(premium.note).font(.footnote).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading).nightwellLiquidGlass(24)
                Group {
                    switch kind {
                    case .sound: sound
                    case .appearance: appearance
                    case .smart: smart
                    case .statistics: stats
                    }
                }.disabled(!premium.allowed || busy)
                }.padding(12)
            }.background(LinearGradient(colors: [Color(red: 0.18, green: 0.07, blue: 0.30), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing))
            .navigationTitle(kind.rawValue)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { if kind == .sound { Button { showPresetOptions = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Дополнительные настройки эквалайзера") } }
                    ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                }
                .sheet(isPresented: $showPresetOptions) { NavigationStack { ScrollView { VStack { presetOptions }.padding(20) }.navigationTitle("Настройки эквалайзера").toolbar { Button("Готово") { showPresetOptions = false } } }.presentationDetents([.medium, .large]) }
                .task(id: store.account?.id) { rules = []; statistics = nil; await premium.refresh(store); if premium.allowed { await load() } }
                .task { while !Task.isCancelled { soundReady = NativePlayer.shared.premiumSoundAvailable; soundStatus = NativePlayer.shared.premiumSoundStatus; do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return } } }
        }.clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
         .padding(.horizontal, 14)
         .preferredColorScheme(.dark).presentationBackground(.clear).presentationDetents([.fraction(0.86), .large]).presentationDragIndicator(.visible)
    }
    private var sound: some View {
        Group {
            PremiumGlassSection("Звук под вас · ±6 дБ") {
                Picker("Пресет", selection: $preset) {
                    Text("Свои настройки").tag("")
                    ForEach(PremiumFeatureState.presets, id: \.0) { Text($0.0).tag($0.0) }
                    ForEach(premium.preferences.presets.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }.onChange(of: preset) { _, value in
                    if let bands = PremiumFeatureState.presets.first(where: { $0.0 == value })?.1 ?? premium.preferences.presets[value] { premium.preferences.bands = bands; premium.apply(); Task { await premium.save(store) } }
                }
                HStack(spacing: 0) {
                    ForEach(0..<5) { i in
                        VStack(spacing: 12) {
                            Text(String(format: "%+.1f", premium.preferences.bands[i])).font(.caption.monospacedDigit())
                            Slider(value: Binding(get: { premium.preferences.bands[i] }, set: { preset = ""; premium.preferences.bands[i] = $0; premium.apply() }), in: -6...6, step: 0.5, onEditingChanged: { editing in if !editing { Task { await premium.save(store) } } })
                                .frame(width: 160).rotationEffect(.degrees(-90)).frame(width: 40, height: 180)
                                .accessibilityLabel(["60 Гц","250 Гц","1 кГц","4 кГц","12 кГц"][i])
                            Text(["60","250","1k","4k","12k"][i]).font(.caption)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 14)
                Text(soundReady ? "Эквалайзер подключён. Полосы меняют частоты, ограничитель защищает от перегрузки." : soundStatus).font(.footnote).foregroundStyle(.secondary)
            }

        }
    }
    private var presetOptions: some View {
            PremiumGlassSection("Свой пресет") {
                TextField("Название", text: $name)
                Button("Сохранить пресет") { let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, key.count <= 40, !["__proto__","constructor","prototype"].contains(key), !PremiumFeatureState.presets.contains(where: { $0.0 == key }), premium.preferences.presets[key] != nil || premium.preferences.presets.count < 8 else { premium.note = "Введите другое название. Можно сохранить до восьми пресетов."; return }
                    premium.preferences.presets[key] = premium.preferences.bands; Task { await premium.save(store) }
                }
                if premium.preferences.presets[preset] != nil { Button("Удалить свой пресет", role: .destructive) { premium.preferences.presets.removeValue(forKey: preset); preset = ""; Task { await premium.save(store) } } }
                Button("Сохранить звук") { Task { await premium.save(store) } }
            }
    }
    private var appearance: some View {
        PremiumGlassSection("Ваше оформление") {
            Picker("Фон", selection: $premium.preferences.theme) { Text("Nightwell").tag("nightwell"); Text("Северное сияние").tag("aurora"); Text("Океан").tag("ocean"); Text("Закат").tag("sunset") }
            Picker("Скорость лент", selection: $premium.preferences.ribbon_speed) { Text("Медленно").tag(0.5); Text("Обычно").tag(1.0); Text("Быстро").tag(1.5) }
            Picker("Выразительность", selection: $premium.preferences.ribbon_intensity) { Text("Мягко").tag(0.5); Text("Обычно").tag(1.0); Text("Ярко").tag(1.5) }
            Toggle("Голос", isOn: $premium.preferences.aura_voice)
            Toggle("Низкие частоты", isOn: $premium.preferences.aura_low)
            Toggle("Средние частоты", isOn: $premium.preferences.aura_mid)
            Toggle("Высокие частоты", isOn: $premium.preferences.aura_high)
            Button("Сохранить оформление") { Task { await premium.saveAppearance(store) } }
        }
    }
    private var smart: some View {
        Group {
            PremiumGlassSection("Ваши подборки") {
                Text("Состав обновляется при открытии. История учитывается за последние 90 дней.").font(.footnote)
                ForEach(rules) { rule in
                    HStack { Button(rule.name) { perform {
                        struct Response: Decodable { let tracks: [Track] }
                        let owner = store.account?.id
                        let response: Response = try await store.api.request("api/premium/smart-playlists/" + rule.id + "/tracks")
                        guard owner == store.account?.id else { return }
                        if let first = response.tracks.first { store.play(first, in: response.tracks) } else { premium.note = "Пока нет подходящих треков." }
                    } }; Spacer(); Button(role: .destructive) { perform { let _: OK = try await store.api.request("api/premium/smart-playlists/" + rule.id, method: "DELETE"); await load() } } label: { Image(systemName: "trash") }.accessibilityLabel("Удалить «" + rule.name + "»") }
                }
            }
            PremiumGlassSection("Новый умный плейлист") {
                TextField("Название", text: $ruleName)
                Picker("Состав", selection: $ruleKind) { Text("Избранное").tag("favorites"); Text("Недавно добавленные").tag("recently_added"); Text("Не слушал 14 дней").tag("long_unheard") }
                Button("Создать") { perform { struct Created: Decodable { let id: String }; let _: Created = try await store.api.request("api/premium/smart-playlists", method: "POST", body: ["name": String(ruleName.prefix(60)), "kind": ruleKind, "days": 14, "track_limit": 50]); ruleName = ""; await load() } }.disabled(ruleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private var stats: some View {
        Group {
            if let statistics {
                PremiumGlassSection("Последние 90 дней") { Text("Прослушано: \(Int(statistics.seconds / 60)) мин."); Text("Сессий: \(statistics.sessions)"); Text("Месяцы считаются по UTC.").font(.footnote) }
                PremiumGlassSection("По месяцам") { ForEach(statistics.months.indices, id: \.self) { i in Text(statistics.months[i].month + " · \(Int(statistics.months[i].seconds/60)) мин.") } }
                PremiumGlassSection("Любимые исполнители") { ForEach(statistics.artists.indices, id: \.self) { i in Text(statistics.artists[i].artist + " · \(Int(statistics.artists[i].seconds/60)) мин.") } }
                PremiumGlassSection("Любимые треки") { ForEach(statistics.tracks.indices, id: \.self) { i in Text(statistics.tracks[i].title + " · \(Int(statistics.tracks[i].seconds/60)) мин.") } }
            }
            Button("Обновить статистику") { Task { await load() } }
        }
    }
    private func perform(_ action: @escaping () async throws -> Void) { guard !busy else { return }; busy = true; Task { defer { busy = false }; do { try await action() } catch { premium.note = error.localizedDescription } } }
    private func load() async {
        let owner = store.account?.id
        do { if kind == .smart { struct Response: Decodable { let playlists: [SmartRule] }; let response: Response = try await store.api.request("api/premium/smart-playlists"); if owner == store.account?.id { rules = response.playlists } }
            if kind == .statistics { let response: PremiumStatistics = try await store.api.request("api/premium/statistics"); if owner == store.account?.id { statistics = response } }
        } catch { premium.note = error.localizedDescription }
    }
}
private struct SmartRule: Decodable, Identifiable { let id: String; let name: String }
private struct PremiumStatistics: Decodable {
    struct Month: Decodable { let month: String; let seconds: Double }
    struct Artist: Decodable { let artist: String; let seconds: Double }
    struct TrackSummary: Decodable { let title: String; let seconds: Double }
    let seconds: Double; let sessions: Int; let months: [Month]; let artists: [Artist]; let tracks: [TrackSummary]
}

private struct PremiumGlassSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(pumpkin)
            content
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .nightwellLiquidGlass(26)
    }
}
