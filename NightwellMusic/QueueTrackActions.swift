import SwiftUI
import UIKit

/// Shared actions for every track menu. Enqueueing never starts a new source
/// playlist, so the current song and the rest of the mix stay intact.
struct QueueTrackActions: View {
    @EnvironmentObject var store: MusicStore
    let track: Track

    var body: some View {
        Button("Играть следующим", systemImage: "text.line.first.and.arrowtriangle.forward") {
            enqueue(next: true)
        }
        Button("Добавить в очередь", systemImage: "text.badge.plus") {
            enqueue(next: false)
        }
    }

    private func enqueue(next: Bool) {
        if store.enqueue(track, next: next) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
