#if DEBUG
import XCTest
import SwiftUI
import UIKit
@testable import NightwellMusic

@MainActor final class ArtistProfilePresentationTests: XCTestCase {
    func testArtistSheetRendersTrackWithoutAnAmbientTogetherSession() async throws {
        let store = MusicStore()
        let session = NightwellTogetherSession()
        let track = Track(id: "artist_profile_fixture", title: "Fixture song", artist: "Fixture artist")
        let appeared = expectation(description: "Artist profile appeared")
        let profile = ArtistProfileView(name: track.artist, togetherSession: session, previewTracks: [track])
            // Deliberately provide only the store as a presenter would. The
            // profile must inject its explicit session before rendering rows.
            .environmentObject(store)
            .onAppear { appeared.fulfill() }
        let hosting = UIHostingController(rootView: profile)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        await fulfillment(of: [appeared], timeout: 2)
        hosting.view.layoutIfNeeded()
        let renderedSize = hosting.sizeThatFits(in: window.bounds.size)
        XCTAssertGreaterThan(renderedSize.height, 0)
        XCTAssertFalse(hosting.view.subviews.isEmpty)
    }
}
#endif
