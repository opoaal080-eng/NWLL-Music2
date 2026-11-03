import SwiftUI

/// A Spotify-style artist surface using only facts that Nightwell actually knows.
struct ArtistPage: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let artist: ArtistSelection

    @State private var tracks: [Track] = []
    @State private var loading = false
    @State private var message = ""
    @State private var following = false
    @State private var showPlayer = false

    private var hero: Track { tracks.first ?? artist.seed }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 12) {
                            Button {
                                following = store.toggleFollowingArtist(artist.name)
                            } label: {
                                Text(following ? "Вы подписаны ✓" : "Подписаться")
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 22).frame(height: 42)
                                    .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
                            }
                            .accessibilityLabel(following ? "Отписаться от исполнителя" : "Подписаться на исполнителя")
                            Spacer()
                            Button {
                                guard !tracks.isEmpty else { return }
                                store.play(tracks[0], in: tracks)
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.title2).foregroundStyle(.black)
                                    .frame(width: 58, height: 58)
                                    .background(Color.white, in: Circle())
                            }
                            .disabled(tracks.isEmpty)
                        }
                        Text(artist.titleDerived
                             ? "Исполнитель определён по названию записи. Профиль не подтверждён."
                             : "Имя взято из метаданных. Загрузчик может не быть исполнителем.")
                            .font(.caption).foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Треки исполнителя").font(.system(size: 26, weight: .bold))
                        if tracks.isEmpty && !loading {
                            Text("Пока нет треков, которые удалось уверенно связать с этим исполнителем.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            HStack(alignment: .center, spacing: 12) {
                                Text("\(index + 1)").font(.subheadline).foregroundStyle(.secondary)
                                    .frame(width: 22)
                                Cover(track: track, origin: store.origin)
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Button { store.play(track, in: tracks) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(track.title).font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(store.clock.id == track.id ? Color.white : Color.white.opacity(0.95))
                                            .lineLimit(1)
                                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if store.clock.id == track.id {
                                    PlayingIndicator(playing: store.clock.playing).frame(width: 20, height: 20)
                                }
                                Menu {
                                    Button(store.likes.contains(track.id) ? "Убрать из избранного" : "В избранное",
                                           systemImage: "heart") { Task { await store.like(track) } }
                                    Button("Скачать", systemImage: "arrow.down.to.line") {
                                        Task { await store.download([track]) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 34, height: 44)
                                }
                            }
                            .frame(minHeight: 66)
                        }
                        if loading { ProgressView("Ищем треки…").tint(.white).foregroundStyle(.secondary) }
                        if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20).padding(.bottom, 28)
                }
            }
            .scrollIndicators(.hidden)
            if store.clock.current != nil {
                MiniPlayer(clock: store.clock, open: { showPlayer = true })
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .tint(.white)
        .fullScreenCover(isPresented: $showPlayer) { FullPlayer(clock: store.clock).environmentObject(store) }
        .task(id: artist.id) { await loadTracks() }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            bannerImage
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.18), .black],
                                   startPoint: .top, endPoint: .bottom)
                }
            Text(artist.name)
                .font(.system(size: artist.name.count > 17 ? 43 : 57, weight: .black))
                .minimumScaleFactor(0.55)
                .lineLimit(2)
                .padding(.horizontal, 22).padding(.bottom, 16)
                .shadow(color: .black.opacity(0.5), radius: 8)
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Color.black.opacity(0.65), in: Circle())
            }
            .padding(.leading, 22).padding(.top, 16)
            .accessibilityLabel("Назад")
        }
    }

    @ViewBuilder private var bannerImage: some View {
        if let raw = artist.seed.artist_image_url,
           let url = URL(string: raw, relativeTo: store.origin),
           url.scheme == "https" {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Cover(track: hero, origin: store.origin, pixelWidth: 1000)
                }
            }
        } else {
            Cover(track: hero, origin: store.origin, pixelWidth: 1000)
        }
    }

    @MainActor private func loadTracks() async {
        following = store.isFollowingArtist(artist.name)
        let local = [artist.seed] + store.catalog + store.results + store.clock.queue + store.offline
        tracks = ArtistIdentity.unique(local, for: artist)
        guard store.account != nil else { return }
        loading = true
        defer { loading = false }
        let encoded = artist.name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        do {
            for _ in 0..<6 {
                try Task.checkCancellation()
                let response: TrackResult = try await store.api.request("/api/tracks?q=" + encoded, timeout: 16)
                try Task.checkCancellation()
                tracks = ArtistIdentity.unique(tracks + response.tracks, for: artist)
                if response.search_pending != true { return }
                try await Task.sleep(nanoseconds: UInt64(max(1.5, min(8, response.search_retry_after ?? 2)) * 1_000_000_000))
            }
            message = "Поиск ещё идёт, показаны уже найденные записи."
        } catch is CancellationError {
        } catch {
            message = "Не удалось загрузить остальные треки. Доступные записи показаны выше."
        }
    }
}
