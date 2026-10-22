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
            HStack(spacing: 8) {
                Button("Сбросить") { draft = WaveSettings() }
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(pumpkin)
                    .frame(width: 109, height: 42)
                    .nightwellLiquidGlass(20)
                    .disabled(applying)
                Spacer(minLength: 4)
                Text("Настроить подборку")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(pumpkin)
                        .frame(width: 40, height: 40)
                        .nightwellLiquidGlass(20)
                }
                .disabled(applying)
            }
            Text("Выбери, что хочется услышать сейчас")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 2)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<3, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(WaveSettings.titles[section])
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                                ForEach(WaveSettings.values[section].indices, id: \.self) { option in
                                    let selected = draft[section] == WaveSettings.values[section][option]
                                    Button {
                                        draft[section] = WaveSettings.values[section][option]
                                    } label: {
                                        HStack(spacing: 8) {
                                            if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)) }
                                            Text(WaveSettings.labels[section][option])
                                                .font(.system(size: 15, weight: .medium))
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .foregroundStyle(selected ? pumpkin : .white.opacity(0.92))
                                        .background(selected ? pumpkin.opacity(0.08) : Color.clear)
                                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected ? pumpkin.opacity(0.9) : Color.white.opacity(0.20), lineWidth: 1.2))
                                    }
                                    .buttonStyle(.plain)
                                    .nightwellLiquidGlass(22)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                        }
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(pumpkin)
                    }
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
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(pumpkin)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .nightwellLiquidGlass(28)
            .padding(.horizontal, 0)
            .padding(.bottom, 6)
            .disabled(applying || store.loading)
            .background(Color.clear)
                }
            }

        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .onAppear { draft = WaveSettings.read(store.origin, store.account?.id ?? "device") }

    }
}
