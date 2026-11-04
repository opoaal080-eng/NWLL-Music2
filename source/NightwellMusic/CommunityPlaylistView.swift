import SwiftUI

/// A snapshot of an explicitly published playlist. Unlike a private playlist,
/// its tracks come from the public community endpoint, not the owner's library.
struct CommunityPlaylistView: View {
    @EnvironmentObject var store: MusicStore
    let playlist: CommunityPlaylist
    let close: () -> Void

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name).font(.title2.bold()).lineLimit(2)
                    Text("Плейлист сообщества · \(playlist.author)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 42, height: 42)
                        .frostedGlass(20, bordered: false, intensity: 0.55)
                }
                .accessibilityLabel("Закрыть плейлист")
            }.padding(.top, 18)

            HStack(spacing: 10) {
                Button {
                    if let first = tracks.first { store.play(first, in: tracks) }
                } label: {
                    Label("Слушать", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12).glass()
                }.disabled(tracks.isEmpty)

                Button {
                    Task {
                        guard !saving else { return }
                        saving = true
                        let successful = await store.saveCommunityPlaylist(playlist.id)
                        saved = successful
                        if successful { message = "Добавлено в твои плейлисты" }
                        saving = false
                    }
                } label: {
                    Label(saved ? "Сохранено" : "Сохранить", systemImage: saved ? "checkmark" : "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12).glass()
                }
                .disabled(saved || saving || tracks.isEmpty)
            }.buttonStyle(.plain)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Загружаем плейлист…") }
            Text("Треки · \(tracks.count)")
                .font(.caption).foregroundStyle(.secondary)
            TrackList(tracks: tracks)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .task(id: playlist.id) {
            loading = true
            defer { loading = false }
            do {
                let response: CommunityPlaylistDetail = try await store.api.request(
                    "/api/community-playlists/" + playlist.id, timeout: 12)
                tracks = response.playlist.tracks ?? []
            } catch {
                message = "Плейлист недоступен: " + error.localizedDescription
            }
        }
    }
}
