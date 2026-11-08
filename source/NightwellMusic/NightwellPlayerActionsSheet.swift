import SwiftUI

/// A frozen snapshot is made on tap. Unlike the former inline menu, this
/// screen observes neither PlaybackClock (rapid progress updates) nor
/// MusicStore (background sync/network updates).
struct NightwellPlayerActionSnapshot: Identifiable {
    let id = UUID()
    let track: Track?
    let clipURL: URL?
    let playlists: [Playlist]
    let recommendationHidden: Bool
    let shareBaseURL: URL
    let lyricsVisible: Bool
}

struct NightwellPlayerActionsSheet: View {
    let snapshot: NightwellPlayerActionSnapshot
    let onClose: () -> Void
    let onEqualizer: () -> Void
    let onLyrics: () -> Void
    let onClip: (URL, Track) -> Void
    let onHide: (Track) -> Void
    let onDownload: (Track) -> Void
    let onAddPlaylist: (Track, Playlist) -> Void
    let onQuality: (String) -> Void

    @AppStorage("nw-audio-quality") private var audioQuality = "auto"
    @AppStorage("nw-animated-album-artwork") private var animatedArtwork = true

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Menu {
                        quality("Авто", value: "auto")
                        quality("Низкое", value: "low")
                        quality("Среднее", value: "medium")
                        quality("Высокое", value: "high")
                    } label: {
                        Label("Качество звука", systemImage: "waveform")
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    Button(action: onEqualizer) {
                        Label("Эквалайзер", systemImage: "slider.vertical.3")
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    Button(action: onLyrics) {
                        Label(snapshot.lyricsVisible ? "Обложка" : "Текст песни",
                              systemImage: "text.alignleft")
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    Button {
                        animatedArtwork.toggle()
                        onClose()
                    } label: {
                        Label(animatedArtwork ? "Отключить анимацию обложки" : "Включить анимацию обложки",
                              systemImage: "livephoto")
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    if let track = snapshot.track {
                        if let url = snapshot.clipURL {
                            Button { onClip(url, track) } label: {
                                Label("Клип", systemImage: "play.rectangle")
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            }
                        }
                        Button { onHide(track) } label: {
                            Label(snapshot.recommendationHidden ? "Вернуть в рекомендации" : "Не рекомендовать",
                                  systemImage: "hand.thumbsdown")
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        }
                        Button { onDownload(track) } label: {
                            Label("Скачать", systemImage: "arrow.down.to.line")
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        }
                        ShareLink(item: snapshot.shareBaseURL.appendingPathComponent("track/" + track.id)) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        }
                        Menu {
                            ForEach(snapshot.playlists) { list in
                                Button(list.name) { onAddPlaylist(track, list) }
                            }
                        } label: {
                            Label("Добавить в плейлист", systemImage: "text.badge.plus")
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(22)
            }
            .navigationTitle("Действия с треком")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово", action: onClose)
                }
            }
        }
        .tint(.white)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.10))
    }

    private func quality(_ title: String, value: String) -> some View {
        Button {
            audioQuality = value
            onQuality(value)
        } label: {
            if audioQuality == value || (value == "low" && audioQuality == "economy") {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
