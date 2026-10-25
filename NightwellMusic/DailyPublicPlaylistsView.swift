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
}
struct DailyPublicPlaylistsView: View {
    @ObservedObject var store: MusicStore
    @State private var playlists: [DailyPublicPlaylist] = []
    @State private var loading = false
    @State private var message = ""
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
                Button {
                    guard let track = playlist.tracks.first else { return }
                    store.play(track, queue: playlist.tracks)
                } label: {
                    HStack {
                        Image(systemName: "waveform")
                        VStack(alignment: .leading) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.count) треков · Слушать").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                    }.padding(14).glass()
                }
            }
        }
        .task { await reload() }
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
