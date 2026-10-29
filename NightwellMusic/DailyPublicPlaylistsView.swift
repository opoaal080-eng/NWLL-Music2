import SwiftUI

private struct DailyPublicResponse: Decodable {
    let date: String
    let playlists: [DailyPublicPlaylist]
}
private struct DailyPublicPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let count: Int
    let tracks: [Track]
    var saved: Bool?
    var saved_playlist_id: String?
}
struct DailyPublicPlaylistsView: View {
    @ObservedObject var store: MusicStore
    @State private var playlists: [DailyPublicPlaylist] = []
    @State private var loading = false
    @State private var message = ""
    @State private var saving: Set<String> = []
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
                        guard let track = playlist.tracks.first else { return }
                        store.play(track, in: playlist.tracks)
                    } label: {
                        HStack {
                            Image(systemName: "waveform")
                            VStack(alignment: .leading) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.count) треков · Слушать").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                        }.padding(14)
                    }.buttonStyle(.plain)
                    Button { Task { await save(playlist) } } label: {
                        Image(systemName: playlist.saved == true ? "heart.fill" : "heart")
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                    }
                    .disabled(playlist.saved == true || saving.contains(playlist.id))
                    .accessibilityLabel(playlist.saved == true ? "Сохранено в плейлисты" : "Сохранить подборку в плейлисты")
                }.glass()
            }
        }
        .task { await reload() }
    }
    @MainActor private func save(_ playlist: DailyPublicPlaylist) async {
        guard !saving.contains(playlist.id), playlist.saved != true else { return }
        saving.insert(playlist.id)
        defer { saving.remove(playlist.id) }
        do {
            struct Saved: Decodable { let id: String; let name: String }
            let _: Saved = try await store.api.request(
                "/api/daily-public-playlists/" + playlist.id + "/save",
                method: "POST", body: ["track_ids": playlist.tracks.map(\.id)])
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index].saved = true
            }
            message = "Сохранено в обычные плейлисты с датой."
            await store.refresh()
        } catch {
            message = "Не удалось сохранить подборку: " + error.localizedDescription
        }
    }
    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result: DailyPublicResponse = try await store.api.request("/api/daily-public-playlists")
            playlists = result.playlists
            message = playlists.isEmpty ? "Подборок пока нет" : ""
        } catch {
            message = "Не удалось загрузить подборки. Проверь обновление сервера."
        }
    }
}
