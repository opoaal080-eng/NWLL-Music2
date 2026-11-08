import SwiftUI

/// The whole menu is an inexpensive overlay; it is not a system sheet and
/// does not observe the rapidly ticking music playback clock.
struct NightwellPlayerActionSnapshot: Identifiable {
    let id = UUID()
    let track: Track?
    let clipURL: URL?
    let playlists: [Playlist]
    let recommendationHidden: Bool
    let shareBaseURL: URL
    let lyricsVisible: Bool
}

struct NightwellPlayerActionsOverlay: View {
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
    @State private var qualityExpanded = false
    @State private var playlistsExpanded = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                VStack(spacing: 0) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 34, height: 4)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                    HStack {
                        Text("Действия с треком")
                            .font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.09), in: Circle())
                        }
                        .accessibilityLabel("Закрыть меню")
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 5) {
                            Button { qualityExpanded.toggle() } label: {
                                actionLabel("Качество звука", icon: "waveform")
                            }
                            if qualityExpanded {
                                ForEach(qualityChoices, id: \.value) { choice in
                                    Button {
                                        audioQuality = choice.value
                                        onQuality(choice.value)
                                        qualityExpanded = false
                                    } label: {
                                        HStack {
                                            Text(choice.title)
                                            Spacer()
                                            if audioQuality == choice.value {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                        .frame(minHeight: 40)
                                        .padding(.leading, 30)
                                    }
                                }
                                .foregroundStyle(.white.opacity(0.83))
                            }
                            Button(action: onEqualizer) {
                                actionLabel("Эквалайзер", icon: "slider.vertical.3")
                            }
                            Button(action: onLyrics) {
                                actionLabel(snapshot.lyricsVisible ? "Обложка" : "Текст песни",
                                            icon: "text.alignleft")
                            }
                            Button {
                                animatedArtwork.toggle()
                                onClose()
                            } label: {
                                actionLabel(animatedArtwork ? "Отключить анимацию обложки" : "Включить анимацию обложки",
                                            icon: "livephoto")
                            }
                            if let track = snapshot.track {
                                if let clip = snapshot.clipURL {
                                    Button { onClip(clip, track) } label: {
                                        actionLabel("Клип", icon: "play.rectangle")
                                    }
                                }
                                Button { onHide(track) } label: {
                                    actionLabel(snapshot.recommendationHidden ? "Вернуть в рекомендации" : "Не рекомендовать",
                                                icon: "hand.thumbsdown")
                                }
                                Button { onDownload(track) } label: {
                                    actionLabel("Скачать", icon: "arrow.down.to.line")
                                }
                                ShareLink(item: snapshot.shareBaseURL.appendingPathComponent("track/" + track.id)) {
                                    actionLabel("Поделиться", icon: "square.and.arrow.up")
                                }
                                Button { playlistsExpanded.toggle() } label: {
                                    actionLabel("Добавить в плейлист", icon: "text.badge.plus")
                                }
                                if playlistsExpanded {
                                    ForEach(snapshot.playlists) { list in
                                        Button { onAddPlaylist(track, list) } label: {
                                            HStack {
                                                Text(list.name).lineLimit(1)
                                                Spacer()
                                                Image(systemName: "plus")
                                            }
                                            .frame(minHeight: 40)
                                            .padding(.leading, 30)
                                        }
                                    }
                                    .foregroundStyle(.white.opacity(0.83))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: min(proxy.size.height * 0.82, 630))
                .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 26))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea(edges: .bottom)
        .tint(.white)
    }

    private var qualityChoices: [(title: String, value: String)] {
        [("Авто", "auto"), ("Низкое", "low"),
         ("Среднее", "medium"), ("Высокое", "high")]
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
    }
}
