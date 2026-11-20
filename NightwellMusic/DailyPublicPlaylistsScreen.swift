import SwiftUI

/// Daily selections load here, without changing the personal playlist list.
struct DailyPublicPlaylistsScreen: View {
    @Environment(\.nightwellAppearance) private var appearance
    @ObservedObject var store: MusicStore
    @ObservedObject var togetherSession: NightwellTogetherSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DailyPublicPlaylistsView(store: store, togetherSession: togetherSession)
                    .padding(20)
            }
            .background { NightwellMonochromeGlassBackground() }
            .navigationTitle("Подборки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(appearance.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
