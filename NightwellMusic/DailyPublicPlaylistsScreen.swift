import SwiftUI

/// Daily selections load here, without changing the personal playlist list.
struct DailyPublicPlaylistsScreen: View {
    @ObservedObject var store: MusicStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DailyPublicPlaylistsView(store: store)
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
        .tint(.white)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
