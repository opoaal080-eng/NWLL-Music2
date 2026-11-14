import SwiftUI

/// The library's entry screen uses the already prepared favorites snapshot.
/// A preview changes only what is displayed, never the playback queue.
struct LibraryOverview: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject private var premium = PremiumFeatureState.shared
    @Environment(\.nightwellBottomContentInset) private var bottomContentInset
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let favorites: [Track]
    let scrollPosition: Binding<String?>
    let openFavorites: () -> Void
    let openPlaylists: () -> Void
    let openOffline: () -> Void
    let openDailyPlaylists: () -> Void
    let openSmartPlaylists: () -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12),
              count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private var favoritesLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                favoritesEntry
                    .id("library-favorites")

                ForEach(favorites.prefix(3)) { track in
                    NativeTrackRow(track: track, queue: favorites,
                                   status: store.clock.status, playlist: nil,
                                   libraryPreview: true)
                        .id("library-track-" + track.id)
                }

                Text("Ещё в медиатеке")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 24)
                    .id("library-sections")

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    libraryTile("Плейлисты", icon: "music.note.list",
                                detail: countText(store.playlists.count,
                                                  one: "плейлист", few: "плейлиста", many: "плейлистов"),
                                action: openPlaylists)
                        .id("library-playlists")
                    libraryTile("Офлайн", icon: "arrow.down.to.line",
                                detail: countText(store.offline.count), action: openOffline)
                        .id("library-offline")
                    libraryTile("Подборки дня", icon: "sparkles",
                                detail: "Для тебя", action: openDailyPlaylists)
                        .id("library-daily")
                    libraryTile("Умные плейлисты", icon: "waveform.path",
                                detail: (premium.allowed || !premium.entitlementVerified) ? "Для тебя" : "Premium", action: openSmartPlaylists)
                        .id("library-smart")
                }
                .scrollTargetLayout()
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
        .scrollPosition(id: scrollPosition, anchor: .top)
        .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
        .contentMargins(.bottom, bottomContentInset, for: .scrollIndicators)
        .scrollDismissesKeyboard(.interactively)
    }

    private var favoritesEntry: some View {
        Button(action: openFavorites) {
            favoritesLayout {
                Image(systemName: "heart.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(LinearGradient(
                        colors: [Color(red: 0.92, green: 0.79, blue: 1),
                                 Color(red: 0.73, green: 0.48, blue: 0.96),
                                 Color(red: 0.42, green: 0.27, blue: 0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 84)
                    .rotationEffect(.degrees(-8))
                    .shadow(color: .purple.opacity(0.18), radius: 16, y: 8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Избранное")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(countText(store.likes.count))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Избранное")
        .accessibilityValue(countText(store.likes.count))
        .accessibilityHint("Открывает все треки в избранном")
    }

    private func libraryTile(_ title: String, icon: String, detail: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }

    private func countText(_ count: Int, one: String = "трек",
                           few: String = "трека", many: String = "треков") -> String {
        let ending = count % 100
        let word = (11...14).contains(ending) ? many
            : count % 10 == 1 ? one : (2...4).contains(count % 10) ? few : many
        return "\(count) \(word)"
    }
}
