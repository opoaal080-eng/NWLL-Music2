import XCTest
import Combine
@testable import NightwellMusic

@MainActor final class FavoritePresentationTests: XCTestCase {
    private func track(_ id: String, _ title: String) -> Track {
        Track(id: id, title: title, artist: "Artist")
    }

    func testFavoritesKeepSavedOrderAndSourcePrecedenceWithoutMissingMetadata() throws {
        let defaults = UserDefaults.standard
        let previousAccount = defaults.object(forKey: "native.account")
        let previousServer = defaults.object(forKey: "nightwell.server")
        let owner = "favorite_test_" + UUID().uuidString
        let origin = "https://music.nightwell.fun/"
        let sessionKey = "nw-session-v1-music.nightwell.fun-" + owner
        let orderKey = "nw-favorites-order-v1|" + origin + "|" + owner
        let detailKey = "nw-favorite-tracks-v2|" + origin + "|" + owner
        defer {
            defaults.set(previousAccount, forKey: "native.account")
            defaults.set(previousServer, forKey: "nightwell.server")
            for key in [sessionKey, orderKey, detailKey] { defaults.removeObject(forKey: key) }
        }
        defaults.set(origin, forKey: "nightwell.server")
        defaults.set(try JSONSerialization.data(withJSONObject: ["id": owner, "email": "test@example.org"]),
                     forKey: "native.account")
        defaults.set(["missing", "c", "c", "stale"], forKey: orderKey)
        let snapshot: [String: Any] = [
            "savedAt": Date().timeIntervalSinceReferenceDate,
            "tracks": [], "likes": ["c", "a", "missing"],
            "playlists": [], "wave": []
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: snapshot), forKey: sessionKey)
        let store = MusicStore()
        store.catalog = [track("c", "catalogue"), track("unliked", "not a favorite")]
        store.results = [track("c", "search duplicate"), track("a", "search"), track("a", "later duplicate")]
        store.clock.queue = [track("a", "queue duplicate"), track("b", "queue")]
        store.offline = [track("b", "offline duplicate"), track("z", "offline")]
        // Favorites discovered after the stored chronology use deterministic
        // ID order. A missing metadata record must not hide subsequent tracks.
        store.likes.formUnion(["z", "b"])
        let displayed = store.favoriteDisplayTracks
        XCTAssertEqual(displayed.map(\.id), ["c", "a", "b", "z"])
        XCTAssertEqual(displayed.map(\.title), ["catalogue", "search", "queue", "offline"])
        store.likes = []
        XCTAssertTrue(store.favoriteDisplayTracks.isEmpty)
    }

    func testLeavingInactiveSearchDoesNotPublishRedundantLibraryChanges() {
        let store = MusicStore()
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        store.leaveSearch()
        store.leaveSearch()
        XCTAssertEqual(changes, 0, "Changing library sections must not republish an already empty search state")
    }

    func testDownloadMembershipUpdatesWhenOfflineSnapshotChanges() {
        let store = MusicStore()
        let first = track("first_download", "First")
        let second = track("second_download", "Second")
        store.offline = [first]
        XCTAssertTrue(store.isDownloaded(first))
        XCTAssertFalse(store.isDownloaded(second))
        store.offline = [second]
        XCTAssertFalse(store.isDownloaded(first))
        XCTAssertTrue(store.isDownloaded(second))
        store.offline = []
        XCTAssertFalse(store.isDownloaded(second))
    }
}
