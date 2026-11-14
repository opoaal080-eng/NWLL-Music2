// Navigation and scroll restoration live only for the current app session.
// A revision invalidates callbacks from an old ScrollView after a sort reset.
struct LibrarySessionState<Destination: Hashable> {
    private(set) var lastVisited: Destination
    private var positions: [Destination: String] = [:]
    private var revisions: [Destination: Int] = [:]

    init(overview: Destination) {
        lastVisited = overview
    }

    func scrollPosition(for destination: Destination) -> String? {
        positions[destination]
    }

    func revision(for destination: Destination) -> Int {
        revisions[destination] ?? 0
    }

    mutating func remember(_ destination: Destination) {
        lastVisited = destination
    }

    @discardableResult
    mutating func saveScrollPosition(_ position: String?, for destination: Destination,
                                     revision: Int) -> Bool {
        guard revision == self.revision(for: destination) else { return false }
        positions[destination] = position
        return true
    }

    mutating func resetScroll(for destination: Destination) {
        positions[destination] = nil
        revisions[destination] = revision(for: destination) + 1
    }
}
