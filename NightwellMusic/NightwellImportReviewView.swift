import SwiftUI

private struct ImportReviewItem: Decodable {
    let title: String
    let artist: String
    let track_id: String?
    let found_title: String?
    let found_artist: String?
    let reason: String?
}
private struct ImportReviewJob: Decodable {
    let id: String
    let state: String
    let total: Int
    let matched: Int
    let items: [ImportReviewItem]
}
private struct ImportReviewTrackSearch: Decodable {
    let tracks: [Track]
    let search_pending: Bool?
    let search_retry_after: Double?
}

/// Inspect every matched and missing track before the user commits an import.
struct NightwellImportReviewView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    let onRetry: () -> Void

    @State private var review: ImportReviewJob?
    @State private var mode = "all"
    @State private var busy = false
    @State private var errorText = ""
    @State private var editingIndex = -1
    @State private var searchText = ""
    @State private var searchResults: [Track] = []
    @State private var searchBusy = false
    @State private var searchNotice = ""

    private var visibleIndices: [Int] {
        guard let review else { return [] }
        return review.items.indices.filter { index in
            let found = review.items[index].track_id != nil
            return mode == "all" || (mode == "found" && found) || (mode == "missing" && !found)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if let review {
                    Text("Найдено \(review.matched) из \(review.total). Неверные версии можно заменить перед сохранением.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    Picker("Показать", selection: $mode) {
                        Text("Все").tag("all")
                        Text("Найдено").tag("found")
                        Text("Пропущено").tag("missing")
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                    List {
                        ForEach(visibleIndices, id: \.self) { index in
                            let item = review.items[index]
                            VStack(alignment: .leading, spacing: 7) {
                                Text("\(index + 1). \(item.artist) — \(item.title)")
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                if item.track_id != nil {
                                    Label((item.found_artist ?? "") + " — " + (item.found_title ?? ""), systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(.green)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Label(item.reason ?? "Не удалось найти", systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 14) {
                                    Button(item.track_id == nil ? "Найти вручную" : "Заменить") {
                                        editingIndex = index
                                        searchText = item.artist + " " + item.title
                                        searchResults = []
                                    }.font(.caption.weight(.semibold))
                                    if item.track_id != nil {
                                        Button("Не добавлять") {
                                            Task { await replace(at: index, track: nil) }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                            .padding(.vertical, 7)
                            .listRowBackground(Color.white.opacity(0.04))
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    if review.items.contains(where: { $0.track_id == nil }) {
                        Button(busy ? "Ищем…" : "Повторить поиск пропущенных") {
                            Task { await retry() }
                        }
                        .disabled(busy)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                        .buttonStyle(.plain)
                    }
                } else if busy {
                    ProgressView("Загружаем список…").tint(.white)
                    Spacer()
                } else {
                    ContentUnavailableView("Нет результатов", systemImage: "doc.text.magnifyingglass")
                }
                if !errorText.isEmpty {
                    Text(errorText).font(.caption).foregroundStyle(.white).padding(.horizontal, 16)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Проверка переноса")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        .preferredColorScheme(.dark)
        .task { await reload() }
        .sheet(isPresented: Binding(
            get: { editingIndex >= 0 },
            set: { if !$0 { editingIndex = -1 } }
        )) {
            NavigationStack {
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Исполнитель или название", text: $searchText)
                            .autocorrectionDisabled()
                        Button { Task { await search() } } label: {
                            Image(systemName: "arrow.right.circle.fill").font(.title2)
                        }
                    }.padding(13).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 14)
                    if searchBusy { ProgressView("Ищем варианты…").tint(.white) }
                    if !searchNotice.isEmpty { Text(searchNotice).font(.caption).foregroundStyle(.secondary) }
                    List(searchResults) { track in
                        Button {
                            Task { await replace(at: editingIndex, track: track) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.subheadline.weight(.semibold))
                                Text(track.artist).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.foregroundStyle(.white).listRowBackground(Color.white.opacity(0.04))
                    }.scrollContentBackground(.hidden)
                }
                .background(Color.black.ignoresSafeArea())
                .navigationTitle("Выбрать версию")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Закрыть") { editingIndex = -1 }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .task(id: searchText) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { await search() }
            }
        }
    }
    }

    @MainActor private func reload() async {
        busy = true
        defer { busy = false }
        do {
            let value: ImportReviewJob = try await store.api.request("/api/imports/" + jobID)
            review = value
            errorText = ""
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { searchResults = []; return }
        searchBusy = true
        defer { searchBusy = false }
        let encoded = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        do {
            for _ in 0..<4 {
                let response: ImportReviewTrackSearch = try await store.api.request(
                    "/api/tracks?q=" + encoded, timeout: 14)
                guard !Task.isCancelled else { return }
                searchResults = Array(response.tracks.prefix(60))
                if !searchResults.isEmpty || response.search_pending != true { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            searchNotice = searchResults.isEmpty ? "Похожих записей пока нет. Попробуй другой запрос." : ""
        } catch {
            if !Task.isCancelled { searchNotice = error.localizedDescription }
        }
    }

    @MainActor private func replace(at position: Int, track: Track?) async {
        guard position >= 0 else { return }
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["track_id": NSNull()]
        if let track {
            body = ["track_id": track.id, "q": searchText]
        }
        do {
            let _: ImportReviewJob = try await store.api.request(
                "/api/imports/" + jobID + "/items/" + String(position),
                method: "PATCH", body: body, timeout: 15)
            editingIndex = -1
            await reload()
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func retry() async {
        busy = true
        defer { busy = false }
        do {
            struct RetryStatus: Decodable { let id: String; let state: String }
            let _: RetryStatus = try await store.api.request(
                "/api/imports/" + jobID + "/retry", method: "POST",
                body: ["mode": "wide"])
            dismiss()
            onRetry()
        } catch { errorText = error.localizedDescription }
    }
}
