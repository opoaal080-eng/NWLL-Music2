import Foundation
import SwiftUI

struct WaveSettings: Codable, Equatable {
    static let keys = ["character", "mood", "language"]
    static let titles = ["Характер", "Настроение", "Язык"]
    static let values = [["balanced", "discover", "favorites"], ["any", "energetic", "calm", "happy", "sad"], ["any", "ru", "foreign", "instrumental"]]
    static let labels = [["На мой вкус", "Открытия", "Избранное"], ["Любое", "Бодрое", "Спокойное", "Весёлое", "Грустное"], ["Любой", "Русский", "Иностранный", "Без слов"]]
    var character = "balanced"
    var mood = "any"
    var language = "any"
    init(_ raw: [String: Any] = [:]) {
        for index in Self.keys.indices {
            if let value = raw[Self.keys[index]] as? String, Self.values[index].contains(value) { self[index] = value }
        }
    }
    subscript(index: Int) -> String {
        get { index == 0 ? character : index == 1 ? mood : language }
        set { if index == 0 { character = newValue } else if index == 1 { mood = newValue } else { language = newValue } }
    }
    var dictionary: [String: String] { ["character": character, "mood": mood, "language": language] }
    var query: String { "&character=" + character + "&mood=" + mood + "&language=" + language }
    static func key(_ origin: URL, _ account: String) -> String { "wave-settings|" + origin.absoluteString + "|" + account }
    static func read(_ origin: URL, _ account: String) -> Self { Self(UserDefaults.standard.dictionary(forKey: key(origin, account)) ?? [:]) }
    func save(_ origin: URL, _ account: String) { UserDefaults.standard.set(dictionary, forKey: Self.key(origin, account)) }
}

struct WaveOptionsResponse: Decodable { let version: Int }
struct NativeWaveSettingsView: View {
    @EnvironmentObject var store: MusicStore
    let close: () -> Void
    @State private var draft = WaveSettings()
    @State private var applying = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Выбери, что хочется услышать сейчас").foregroundStyle(nightwellText.opacity(0.7))
                    ForEach(0..<3, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(WaveSettings.titles[section]).font(.headline)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(WaveSettings.values[section].indices, id: \.self) { option in
                                    let selected = draft[section] == WaveSettings.values[section][option]
                                    Button { draft[section] = WaveSettings.values[section][option] } label: {
                                        HStack(spacing: 5) {
                                            if selected { Image(systemName: "checkmark") }
                                            Text(WaveSettings.labels[section][option]).font(.system(size: 14, weight: .medium))
                                        }.frame(maxWidth: .infinity, minHeight: 40)
                                            .foregroundStyle(selected ? pumpkin : nightwellText)
                                            .background(Color(red: 0.075, green: 0.045, blue: 0.12).opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
                                            .nightwellLiquidGlass(18)
                                            .background(selected ? pumpkin.opacity(0.15) : Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 18))
                                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? pumpkin.opacity(0.80) : Color.white.opacity(0.28), lineWidth: 1))
                                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                        }
                    }
                    Text("Настроение и язык определяются по описанию треков и могут совпадать не точно.").font(.footnote).foregroundStyle(nightwellText.opacity(0.6))
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(pumpkin) }
                    Button {
                        applying = true
                        Task {
                            do { try await store.applyWaveSettings(draft); close() }
                            catch { message = error.localizedDescription }
                            applying = false
                        }
                    } label: {
                        HStack { if applying { ProgressView().tint(pumpkin) }; Text("Применить") }.frame(maxWidth: .infinity).padding(16).nightwellLiquidGlass(26)
                    }.disabled(applying || store.loading)
                }.padding(18)
            }.background(Color.clear)
                .navigationTitle("Настроить подборку").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Сбросить") { draft = WaveSettings() }.disabled(applying) }
                    ToolbarItem(placement: .topBarTrailing) { Button { close() } label: { Image(systemName: "xmark").fontWeight(.semibold) }.disabled(applying) }
                }.tint(pumpkin)
        }
        .onAppear { draft = WaveSettings.read(store.origin, store.account?.id ?? "device") }
        .background(Color.clear)
        .nightwellLiquidGlass(32)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}
