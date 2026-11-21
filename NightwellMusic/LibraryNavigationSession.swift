import Combine

// Scroll anchors are restoration data, not changes to the root interface.
// Publishing each visible row rebuilt the full library while it was scrolling.
@MainActor
final class LibraryNavigationSession<Destination: Hashable>: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var state: LibrarySessionState<Destination>

    init(overview: Destination) {
        state = LibrarySessionState(overview: overview)
    }

    var lastVisited: Destination { state.lastVisited }

    func scrollPosition(for destination: Destination) -> String? {
        state.scrollPosition(for: destination)
    }

    func revision(for destination: Destination) -> Int {
        state.revision(for: destination)
    }

    func remember(_ destination: Destination) {
        guard destination != state.lastVisited else { return }
        objectWillChange.send()
        state.remember(destination)
    }

    @discardableResult
    func saveScrollPosition(_ position: String?, for destination: Destination,
                            revision: Int) -> Bool {
        state.saveScrollPosition(position, for: destination, revision: revision)
    }

    func resetScroll(for destination: Destination) {
        objectWillChange.send()
        state.resetScroll(for: destination)
    }
}
