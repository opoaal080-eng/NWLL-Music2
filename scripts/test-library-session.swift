import Foundation

@main struct LibrarySessionTests {
    private enum Page: Hashable { case overview, favorites, playlists, offline }

    static func main() {
        var session = LibrarySessionState<Page>(overview: .overview)
        precondition(session.lastVisited == .overview)
        precondition(session.scrollPosition(for: .favorites) == nil)
        precondition(session.revision(for: .favorites) == 0)

        session.remember(.favorites)
        let favoritesRevision = session.revision(for: .favorites)
        precondition(session.saveScrollPosition("favorite_42", for: .favorites, revision: favoritesRevision))
        // Leaving for another main tab does not change the remembered library
        // destination. Returning restores that page and its own anchor.
        precondition(session.lastVisited == .favorites)
        precondition(session.scrollPosition(for: .favorites) == "favorite_42")
        session.remember(.playlists)
        precondition(session.saveScrollPosition("playlist_7", for: .playlists, revision: 0))
        session.remember(.favorites)
        precondition(session.scrollPosition(for: .favorites) == "favorite_42")

        // Explicit Back is a visit to the overview, not an invitation to
        // redirect immediately into the previously opened subsection.
        session.remember(.overview)
        precondition(session.lastVisited == .overview)
        precondition(session.scrollPosition(for: .favorites) == "favorite_42")
        let relaunched = LibrarySessionState<Page>(overview: .overview)
        precondition(relaunched.lastVisited == .overview)
        precondition(relaunched.scrollPosition(for: .favorites) == nil)
        precondition(relaunched.scrollPosition(for: .playlists) == nil)
        precondition(relaunched.revision(for: .favorites) == 0)

        session.remember(.favorites)
        session.resetScroll(for: .favorites)
        let sortedRevision = session.revision(for: .favorites)
        precondition(sortedRevision == favoritesRevision + 1)
        precondition(session.lastVisited == .favorites)
        precondition(session.scrollPosition(for: .favorites) == nil, "Sorting must start at the top")
        precondition(!session.saveScrollPosition("favorite_42", for: .favorites, revision: favoritesRevision),
                     "The disappearing pre-sort ScrollView must not restore the old anchor")
        precondition(!session.saveScrollPosition(nil, for: .favorites, revision: favoritesRevision),
                     "Stale nil callbacks must also be rejected")
        precondition(session.scrollPosition(for: .favorites) == nil)
        precondition(session.scrollPosition(for: .playlists) == "playlist_7")
        precondition(session.revision(for: .playlists) == 0)
        precondition(session.saveScrollPosition("sorted_first", for: .favorites, revision: sortedRevision))
        precondition(session.scrollPosition(for: .favorites) == "sorted_first")
        session.resetScroll(for: .favorites)
        precondition(session.revision(for: .favorites) == sortedRevision + 1)
        precondition(!session.saveScrollPosition("sorted_first", for: .favorites, revision: sortedRevision))
        precondition(session.saveScrollPosition(nil, for: .favorites,
                                              revision: session.revision(for: .favorites)))
        precondition(session.scrollPosition(for: .favorites) == nil)
        precondition(session.saveScrollPosition("offline_3", for: .offline, revision: 0))
        precondition(session.scrollPosition(for: .playlists) == "playlist_7")
        print("Library session: child/overview restoration, relaunch reset, sort-to-top and stale callback rejection passed")
    }
}
