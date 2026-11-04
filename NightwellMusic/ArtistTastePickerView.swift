import SwiftUI

private struct WaveArtistSuggestion: Identifiable, Decodable {
    let name: String
    let track_count: Int?
    var id: String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}
private struct WaveArtistSuggestions: Decodable {
    let artists: [WaveArtistSuggestion]
}

/// Shared by first-login onboarding and the existing Wave settings menu.
struct ArtistTastePickerView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let firstRun: Bool

    @State private var selected: [String] = []
    @State private var query = ""
    @State private var suggestions: [WaveArtistSuggestion] = []
    @State private var loading = false
    @State private var saving = false
    @State private var message = ""

    private var nameToAdd: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func selectedContains(_ name: String) -> Bool {
        selected.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
    private func toggle(_ name: String) {
        if let index = selected.firstIndex(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            selected.remove(at: index)
        } else if selected.count < 20 {
            selected.append(name)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(firstRun ? "Настрой свою музыку" : "Любимые исполнители")
                        .font(.largeTitle.bold())
                    Text(firstRun
                         ? "Выбери артистов, которых любишь. Nightwell будет чаще добавлять их песни в подборку."
                         : "Обнови свой музыкальный вкус. Настройки сохраняются на аккаунте и работают на других устройствах.")
                        .font(.subheadline).foregroundStyle(.secondary)

                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Поиск исполнителя", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(15)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))

                    HStack {
                        Text("Выбрано: \(selected.count)/20").font(.headline)
                        Spacer()
                        if loading { ProgressView().tint(.white) }
                    }
                    if !selected.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118))], spacing: 8) {
                            ForEach(selected, id: \.self) { name in
                                Button { toggle(name) } label: {
                                    Label(name, systemImage: "checkmark")
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12).padding(.vertical, 11)
                                        .background(Color.white.opacity(0.16), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    Text(query.isEmpty ? "Предлагаем послушать" : "Исполнители")
                        .font(.title3.bold())
                    if !nameToAdd.isEmpty && nameToAdd.count >= 2 && !selectedContains(nameToAdd) {
                        Button {
                            toggle(nameToAdd)
                            query = ""
                        } label: {
                            Label("Добавить «\(nameToAdd)»", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).disabled(selected.count >= 20)
                    }
                    if suggestions.isEmpty && !loading {
                        Text("Попробуй ввести имя исполнителя.").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(suggestions) { artist in
                            Button { toggle(artist.name) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "music.mic")
                                        .frame(width: 38, height: 38)
                                        .background(.white.opacity(0.09), in: Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(artist.name).font(.subheadline.weight(.semibold))
                                        if let count = artist.track_count {
                                            Text("\(count) треков в каталоге")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: selectedContains(artist.name) ? "checkmark.circle.fill" : "plus.circle")
                                        .font(.title3)
                                }
                                .padding(10)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
                            }
                            .buttonStyle(.plain)
                            .disabled(!selectedContains(artist.name) && selected.count >= 20)
                        }
                    }
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.white)
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if saving { ProgressView().tint(.black) }
                            Text("Сохранить выбор").font(.headline)
                            Spacer()
                        }
                        .frame(minHeight: 52)
                        .foregroundStyle(.black)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .disabled(selected.isEmpty || saving)
                    .opacity(selected.isEmpty || saving ? 0.45 : 1)
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Музыкальный вкус")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(firstRun ? "Позже" : "Закрыть") {
                        if firstRun { store.dismissTasteSetup() }
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            selected = store.tasteArtists
            await updateSuggestions()
        }
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            await updateSuggestions()
        }
    }

    @MainActor private func updateSuggestions() async {
        loading = true
        defer { loading = false }
        let encoded = nameToAdd.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        do {
            let response: WaveArtistSuggestions = try await store.api.request(
                "/api/wave-artists/suggestions?q=" + encoded + "&limit=30", timeout: 14)
            guard !Task.isCancelled else { return }
            suggestions = response.artists
        } catch {
            if !Task.isCancelled { suggestions = [] }
        }
    }
    @MainActor private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await store.saveMusicTaste(selected)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
