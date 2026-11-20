import SwiftUI
import UIKit

/// Track actions used inside a playlist. Unlike a context Menu, the system
/// sheet does not float over the row that the listener is trying to use.
struct NightwellPlaylistTrackSheet: View {
    @Environment(\.nightwellAppearance) private var appearance
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var togetherSession: NightwellTogetherSession
    @Environment(\.dismiss) private var dismiss

    let track: Track
    let playlist: Playlist
    let openArtist: (String) -> Void

    @State private var choosingPlaylist = false
    @State private var choosingArtist = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.36))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)
            HStack(spacing: 12) {
                Cover(track: track, origin: store.origin, pixelWidth: 200)
                    .frame(width: 55, height: 55)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Закрыть действия с треком")
            }
            .padding(.horizontal, 21)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    actionGroup {
                        row("Играть следующим", "text.line.first.and.arrowtriangle.forward") {
                            enqueue(next: true)
                        }
                        row("Добавить в очередь", "text.badge.plus") {
                            enqueue(next: false)
                        }
                        if togetherSession.joined {
                            row("Добавить в совместное прослушивание", "person.2.wave.2") {
                                Task { await togetherSession.add(trackID: track.id, store: store) }
                                dismiss()
                            }
                        }
                    }
                    actionGroup {
                        row(store.likes.contains(track.id) ? "Убрать из избранного" : "В избранное",
                            store.likes.contains(track.id) ? "heart.fill" : "heart") {
                            Task { await store.like(track) }
                            dismiss()
                        }
                        row(store.isDownloaded(track) ? "Удалить загрузку" : "Скачать",
                            store.isDownloaded(track) ? "trash" : "arrow.down.to.line") {
                            Task {
                                if store.isDownloaded(track) { await store.removeDownload(track) }
                                else { await store.download([track]) }
                            }
                            dismiss()
                        }
                        ShareLink(item: store.origin.appendingPathComponent("track/" + track.id)) {
                            actionLabel("Поделиться", "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                    }
                    actionGroup {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                choosingPlaylist.toggle()
                                choosingArtist = false
                            }
                        } label: {
                            actionLabel("Добавить в другой плейлист",
                                        choosingPlaylist ? "chevron.up" : "text.badge.plus")
                        }
                        .buttonStyle(.plain)
                        if choosingPlaylist {
                            if store.playlists.isEmpty {
                                Text("Плейлистов пока нет")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.64))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 17)
                                    .padding(.bottom, 10)
                            }
                            ForEach(store.playlists) { list in
                                row(list.name, "plus") {
                                    Task { await store.add(track, playlist: list) }
                                    dismiss()
                                }
                                .padding(.leading, 15)
                            }
                        }
                        if ArtistAttribution.isKnown(track.artist) {
                            Button {
                                let names = ArtistNames.split(track.artist)
                                if names.count == 1, let name = names.first {
                                    showArtist(name)
                                } else {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        choosingArtist.toggle()
                                        choosingPlaylist = false
                                    }
                                }
                            } label: { actionLabel("Исполнитель", "person.crop.circle") }
                            .buttonStyle(.plain)
                            if choosingArtist {
                                ForEach(ArtistNames.split(track.artist), id: \.self) { name in
                                    row(name, "person") { showArtist(name) }
                                        .padding(.leading, 15)
                                }
                            }
                        }
                    }
                    actionGroup {
                        row(store.isRecommendationHidden(track) ? "Вернуть в рекомендации" : "Не рекомендовать",
                            "hand.thumbsdown") {
                            store.toggleRecommendationHidden(track)
                            dismiss()
                        }
                        if !track.artist.isEmpty {
                            row(store.isArtistHidden(track) ? "Вернуть исполнителя" : "Не рекомендовать исполнителя",
                                "person.crop.circle.badge.xmark") {
                                store.toggleArtistHidden(track)
                                dismiss()
                            }
                        }
                        row("Убрать из плейлиста", "trash", destructive: true) {
                            Task { await store.add(track, playlist: playlist, remove: true) }
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            NightwellThemedBackground {
                LinearGradient(
                    colors: [Color(white: 0.12), Color(white: 0.06), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        }
        .tint(appearance.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(30)
        .presentationBackground(.clear)
        .nightwellEdgeBack { dismiss() }
    }

    private func actionGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(.white.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.7))
    }

    private func row(_ title: String, _ symbol: String, destructive: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, symbol, destructive: destructive)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ symbol: String, destructive: Bool = false) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 25)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            Spacer(minLength: 4)
        }
        .foregroundStyle(destructive ? Color(red: 1, green: 0.49, blue: 0.54) : .white)
        .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
        .padding(.horizontal, 17)
        .contentShape(Rectangle())
    }

    private func enqueue(next: Bool) {
        if store.enqueue(track, next: next) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        dismiss()
    }

    private func showArtist(_ name: String) {
        dismiss()
        // Dismiss the menu before opening another sheet from the parent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            openArtist(name)
        }
    }
}
