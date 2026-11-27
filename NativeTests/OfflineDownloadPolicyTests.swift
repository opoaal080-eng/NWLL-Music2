import XCTest
@testable import NightwellMusic

final class OfflineDownloadPolicyTests: XCTestCase {
    func testRetryDelayIsBounded() {
        XCTAssertEqual(OfflineDownloadPolicy.delay(attempt: 1, retryAfter: 0, preparing: true), 3)
        XCTAssertEqual(OfflineDownloadPolicy.delay(attempt: 7, retryAfter: 0, preparing: false), 60)
        XCTAssertEqual(OfflineDownloadPolicy.delay(attempt: 2, retryAfter: 15, preparing: false), 15)
        XCTAssertEqual(OfflineDownloadPolicy.delay(attempt: 5, retryAfter: 900, preparing: false), 300)
        XCTAssertEqual(OfflineDownloadPolicy.delay(attempt: 1, retryAfter: .infinity, preparing: false), 5)
    }
    func testStallTimeout() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(OfflineDownloadPolicy.stalled(since: start, now: start.addingTimeInterval(89)))
        XCTAssertTrue(OfflineDownloadPolicy.stalled(since: start, now: start.addingTimeInterval(90)))
    }
}
