import XCTest
import Combine
@testable import NightwellMusic

@MainActor
final class LibraryNavigationSessionTests: XCTestCase {
    private enum Page: Hashable { case library, likes, playlists }

    func testScrollingRestoresLatestAnchorWithoutInvalidatingRoot() async {
        let session = LibraryNavigationSession<Page>(overview: .library)
        var updates = 0
        let subscription = session.objectWillChange.sink { updates += 1 }
        for index in 0..<1000 {
            XCTAssertTrue(session.saveScrollPosition("track-\(index)", for: .likes, revision: 0))
        }
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(session.scrollPosition(for: .likes), "track-999")
        session.remember(.playlists)
        session.remember(.likes)
        XCTAssertEqual(updates, 2)
        XCTAssertEqual(session.scrollPosition(for: .likes), "track-999")
        withExtendedLifetime(subscription) {}
    }

    func testSortingInvalidatesRootAndRejectsOldScrollCallbacks() async {
        let session = LibraryNavigationSession<Page>(overview: .library)
        var updates = 0
        let subscription = session.objectWillChange.sink { updates += 1 }
        XCTAssertTrue(session.saveScrollPosition("old", for: .likes, revision: 0))
        session.resetScroll(for: .likes)
        XCTAssertEqual(updates, 1)
        XCTAssertNil(session.scrollPosition(for: .likes))
        XCTAssertFalse(session.saveScrollPosition("old", for: .likes, revision: 0))
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(session.saveScrollPosition("new", for: .likes, revision: 1))
        XCTAssertEqual(session.scrollPosition(for: .likes), "new")
        XCTAssertEqual(updates, 1)
        withExtendedLifetime(subscription) {}
    }
}
