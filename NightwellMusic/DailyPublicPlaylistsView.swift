import SwiftUI

private struct DailyPublicResponse: Codable {
    let date: String
    let playlists: [DailyPublicPlaylist]
}
private struct DailyPublicPlaylist: Codable, Identifiable {
    let id: String
    let name: String
    let count: Int
    let tracks: [Track]
    var saved: Bool?
    var saved_playlist_id: String?
}
struct DailyPublicPlaylistsView: View {
    @ObservedObject var store: MusicStore
    @ObservedObject var togetherSession: NightwellTogetherSession
    @State private var playlists: [DailyPublicPlaylist] = []
    @State private var openedPlaylistID: String?
    @State private var loading = false
    @State private var message = ""
    @State private var saving: Set<String> = []
    @State private var collectionDate = ""
    @State private var locallyUnsaved: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Подборки дня").font(.title3.bold())
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
            Text("Публичная музыка, подобранная для тебя. Обновляется раз в сутки.")
                .font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView("Загружаем подборки…") }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            ForEach(playlists) { playlist in
                HStack(spacing: 8) {
                    Button {
                        // Tapping a selection opens its detail, never starts
                        // playback. The play button inside the detail owns it.
                        openedPlaylistID = playlist.id
                    } label: {
                        HStack {
                            Image(systemName: "waveform")
                            VStack(alignment: .leading) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.count) треков").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }.padding(14)
                    }.buttonStyle(.plain)
                    Button { Task { await toggleSaved(playlist) } } label: {
                        Image(systemName: playlist.saved == true ? "heart.fill" : "heart")
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                    }
                    .disabled(saving.contains(playlist.id))
                    .accessibilityLabel(playlist.saved == true ? "Убрать подборку из плейлистов" : "Сохранить подборку в плейлисты")
                    .accessibilityHint(playlist.saved == true ? "Повторное нажатие удалит сохранённую копию подборки" : "")
                }.glass()
            }
        }
        .task(id: store.account?.id) {
            // The catalog changes once a day. Restore yesterday's successful
            // network result instantly on the same UTC day, avoiding another
            // slow request and unnecessary artwork work on every visit.
            if !restoreCachedSelection() {
                playlists = []
                await reload()
            }
        }
        .navigationDestination(item: $openedPlaylistID) { id in
            if let selection = playlists.first(where: { $0.id == id }) {
                // Push within the existing NavigationStack instead of
                // presenting a second sheet over the daily selections sheet.
                // NativeTrackRow requires both environment objects.
                PlaylistScreen(
                    close: { openedPlaylistID = nil },
                    playlist: Playlist(
                        id: "daily-" + collectionDate + "-" + selection.id,
                        name: selection.name
                    ),
                    previewTracks: selection.tracks
                )
                .environmentObject(store)
                .environmentObject(togetherSession)
                .background(Color(white: 0.065))
                .toolbar(.hidden, for: .navigationBar)
            } else {
                Text("Подборка больше недоступна")
                    .foregroundStyle(.secondary)
            }
        }
    }
    @MainActor private func toggleSaved(_ playlist: DailyPublicPlaylist) async {
        guard !saving.contains(playlist.id) else { return }
        saving.insert(playlist.id)
        defer { saving.remove(playlist.id) }

        do {
            if playlist.saved == true {
                // Delete only the concrete playlist created by the Save
                // endpoint. A daily selection is never a generic favorite
                // and must not delete a similarly named personal playlist.
                guard let savedID = playlist.saved_playlist_id, !savedID.isEmpty else {
                    message = "Не удалось определить сохранённый плейлист. Обнови подборки и попробуй снова."
                    return
                }
                let _: OK = try await store.api.request(
                    "/api/playlists/" + savedID, method: "DELETE"
                )
                if let key = savedPlaylistKey(for: playlist.id) {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                locallyUnsaved.insert(playlist.id)
                if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                    playlists[index].saved = false
                    playlists[index].saved_playlist_id = nil
                }
                message = "Лайк убран, сохранённая копия подборки удалена."
            } else {
                struct Saved: Decodable { let id: String; let name: String }
                let result: Saved = try await store.api.request(
                    "/api/daily-public-playlists/" + playlist.id + "/save",
                    method: "POST", body: ["track_ids": playlist.tracks.map(\.id)]
                )
                guard !result.id.isEmpty else {
                    message = "Сервер не вернул ID сохранённого плейлиста."
                    return
                }
                if let key = savedPlaylistKey(for: playlist.id) {
                    UserDefaults.standard.set(result.id, forKey: key)
                }
                locallyUnsaved.remove(playlist.id)
                if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                    playlists[index].saved = true
                    playlists[index].saved_playlist_id = result.id
                }
                message = "Сохранено в обычные плейлисты с датой."
            }
            saveCachedSelection()
            await store.refresh()
        } catch {
            message = (playlist.saved == true ?
                "Не удалось убрать лайк: " : "Не удалось сохранить подборку: ") +
                error.localizedDescription
        }
    }
    /// Never derive saved IDs from playlist names: a personal playlist can
    /// have the same title as a daily selection. Store the exact server ID.
    private func savedPlaylistKey(for id: String) -> String? {
        guard let account = store.account, !collectionDate.isEmpty else { return nil }
        return "nw.daily.saved." + (store.origin.host ?? "server") +
            "." + account.id + "." + collectionDate + "." + id
    }

    private var dailyCacheKey: String? {
        guard let account = store.account else { return nil }
        return "nw.daily.selection-v1." + store.origin.absoluteString + "|" + account.id
    }

    private var currentUTCDay: String {
        String(ISO8601DateFormatter().string(from: Date()).prefix(10))
    }

    @MainActor private func restoreCachedSelection() -> Bool {
        guard let key = dailyCacheKey,
              let bytes = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(DailyPublicResponse.self, from: bytes),
              snapshot.date == currentUTCDay else { return false }
        collectionDate = snapshot.date
        playlists = snapshot.playlists
        message = playlists.isEmpty ? "Подборок пока нет" : ""
        return true
    }

    @MainActor private func saveCachedSelection() {
        guard let key = dailyCacheKey, !collectionDate.isEmpty,
              let bytes = try? JSONEncoder().encode(
                  DailyPublicResponse(date: collectionDate, playlists: playlists)
              ), bytes.count < 1_500_000 else { return }
        UserDefaults.standard.set(bytes, forKey: key)
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result: DailyPublicResponse = try await store.api.request(
                "/api/daily-public-playlists", timeout: 18
            )
            if collectionDate != result.date {
                locallyUnsaved.removeAll()
            }
            collectionDate = result.date
            playlists = result.playlists.map { playlist in
                var entry = playlist
                if locallyUnsaved.contains(entry.id) {
                    // A cached daily response may still report the deleted
                    // copy as saved. Honor this session's confirmed removal.
                    entry.saved = false
                    entry.saved_playlist_id = nil
                } else if let key = savedPlaylistKey(for: entry.id),
                          let savedID = UserDefaults.standard.string(forKey: key),
                          !savedID.isEmpty, entry.saved != false {
                    // Some server versions omit saved_playlist_id on GET.
                    // Restore only the ID returned by our own successful POST.
                    entry.saved = true
                    entry.saved_playlist_id = entry.saved_playlist_id ?? savedID
                }
                return entry
            }
            message = playlists.isEmpty ? "Подборок пока нет" : ""
            saveCachedSelection()
        } catch {
            message = playlists.isEmpty
                ? "Не удалось загрузить подборки. Проверь обновление сервера."
                : "Не удалось обновить подборки. Показываем сохранённые."
        }
    }
}
