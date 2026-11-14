#if DEBUG
import XCTest
import SwiftUI
import UIKit
import Combine
@testable import NightwellMusic

@MainActor private final class SearchPresentationState: ObservableObject {
    @Published var collapsed = false
    @Published var revealRequest = 0
}

private struct SearchPresentationHarness: View {
    @ObservedObject var state: SearchPresentationState

    var body: some View {
        NightwellSearchScreen(collapsed: $state.collapsed,
                              revealRequest: state.revealRequest,
                              openArtist: { _ in })
    }
}

@MainActor final class SearchPresentationTests: XCTestCase {
    private func descendants<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func verticalScrollViews(in view: UIView) -> [UIScrollView] {
        descendants(of: UIScrollView.self, in: view).filter {
            // Ignore the text field's own horizontal scrolling internals.
            $0.bounds.height > 100 &&
                ($0.alwaysBounceVertical || $0.contentSize.height > $0.bounds.height + 1)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testSearchUsesOneScrollAndRevealsTheOriginalFocusedField() async throws {
        let store = MusicStore()
        store.screen = .search
        // No cover URLs or remote sources: rendering these rows needs no network.
        store.results = (0..<60).map {
            Track(id: "search_presentation_\($0)", title: "Fixture song \($0)", artist: "Fixture artist")
        }
        store.searchArtistSuggestions = []
        XCTAssertTrue(store.query.isEmpty)
        let state = SearchPresentationState()
        let session = NightwellTogetherSession()
        let screen = SearchPresentationHarness(state: state)
            .environmentObject(store)
            .environmentObject(session)
        let hosting = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            hosting.view.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
        }
        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        let rendered = try await waitUntil {
            hosting.view.layoutIfNeeded()
            return !self.verticalScrollViews(in: hosting.view).isEmpty &&
                !self.descendants(of: UITextField.self, in: hosting.view).isEmpty
        }
        XCTAssertTrue(rendered, "The fixture must render a scrollable search and its text field")
        let scrollViews = verticalScrollViews(in: hosting.view)
        XCTAssertEqual(scrollViews.count, 1, "Search controls and track results must share one vertical scroll")
        guard scrollViews.count == 1 else { return }
        let scroll = scrollViews[0]
        let field = try XCTUnwrap(descendants(of: UITextField.self, in: hosting.view).first)
        XCTAssertFalse(state.collapsed)
        XCTAssertFalse(field.isFirstResponder, "Opening search must not request the keyboard")

        // Move the entire title and search pill outside the viewport.
        scroll.setContentOffset(CGPoint(x: 0, y: 240 - scroll.adjustedContentInset.top), animated: false)
        let collapsed = try await waitUntil { state.collapsed }
        XCTAssertTrue(collapsed, "Scrolling past the search pill must activate the compact header")

        state.revealRequest += 1
        let revealed = try await waitUntil {
            !state.collapsed && field.isFirstResponder &&
                abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) < 2
        }
        XCTAssertTrue(revealed, "Reveal must return to the top and focus the actual UIKit text field")
        XCTAssertTrue(descendants(of: UITextField.self, in: hosting.view).first === field,
                      "Collapsing and revealing must preserve text field identity")
        XCTAssertTrue(store.query.isEmpty)
    }
}
#endif
