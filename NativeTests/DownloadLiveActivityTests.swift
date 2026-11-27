import XCTest
@testable import NightwellMusic

final class DownloadLiveActivityTests: XCTestCase {
    func testProgressDoesNotFinishBeforeFileSave() {
        let active = NWDownloadActivityAttributes.ContentState(active: true, total: 1, saved: 0, failed: 0, pendingFraction: 0.999)
        XCTAssertEqual(active.percent, 99)
        let done = NWDownloadActivityAttributes.ContentState(active: false, total: 1, saved: 1, failed: 0, pendingFraction: 0)
        XCTAssertEqual(done.percent, 100)
    }

    func testPlaylistProgressAndFailures() {
        let active = NWDownloadActivityAttributes.ContentState(active: true, total: 4, saved: 1, failed: 1, pendingFraction: 0.5)
        XCTAssertEqual(active.completed, 2)
        XCTAssertEqual(active.percent, 62)
        let done = NWDownloadActivityAttributes.ContentState(active: false, total: 4, saved: 3, failed: 1, pendingFraction: 0)
        XCTAssertEqual(done.saved, 3)
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(done.percent, 100)
        XCTAssertEqual(active.islandTitle, "Скачивание")
        XCTAssertEqual(active.compactCount, "2/4")
        XCTAssertEqual(done.islandTitle, "Есть ошибки")
        XCTAssertEqual(done.resultLabel, "Ошибок: 1")
        XCTAssertEqual(done.symbol, "exclamationmark.circle.fill")
    }
}
