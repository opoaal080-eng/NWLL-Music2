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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Button("Сбросить") { draft = WaveSettings() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(pumpkin)
                    .padding(.horizontal, 20)
                    .frame(height: 54)
                    .nightwellLiquidGlass(27)
                    .disabled(applying)
                Spacer()
                Text("Настроить подборку")
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(pumpkin)
                        .frame(width: 54, height: 54)
                        .nightwellLiquidGlass(27)
                }
                .disabled(applying)
            }
            Text("Выбери, что хочется услышать сейчас")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 2)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(0..<3, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(WaveSettings.titles[section])
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(WaveSettings.values[section].indices, id: \.self) { option in
                                    let selected = draft[section] == WaveSettings.values[section][option]
                                    Button {
                                        draft[section] = WaveSettings.values[section][option]
                                    } label: {
                                        HStack(spacing: 8) {
                                            if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)) }
                                            Text(WaveSettings.labels[section][option])
                                                .font(.system(size: 16, weight: .medium))
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 58)
                                        .foregroundStyle(selected ? pumpkin : .white.opacity(0.92))
                                        .background(selected ? pumpkin.opacity(0.08) : Color.clear)
                                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(selected ? pumpkin.opacity(0.9) : Color.white.opacity(0.20), lineWidth: 1.2))
                                    }
                                    .buttonStyle(.plain)
                                    .nightwellLiquidGlass(26)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                        }
                    }

                    Text("Настроение и язык определяются по описанию треков и могут совпадать не точно.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(pumpkin)
                    }
                }
            }

            HStack { Spacer() }
        }
        .padding(20)
        .background(Color.clear)
        .onAppear { draft = WaveSettings.read(store.origin, store.account?.id ?? "device") }
        .safeAreaInset(edge: .bottom) {
            Button {
                applying = true
                Task {
                    do { try await store.applyWaveSettings(draft); close() }
                    catch { message = error.localizedDescription }
                    applying = false
                }
            } label: {
                HStack(spacing: 10) {
                    if applying { ProgressView().tint(pumpkin) }
                    Text("Готово")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundStyle(pumpkin)
                .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.plain)
            .nightwellLiquidGlass(28)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .disabled(applying || store.loading)
            .background(Color.clear)
        }
    }
}
