import XCTest
@testable import NightwellMusic

final class TrackSwipeInteractionTests: XCTestCase {
    private let widths: [Double] = [180, 300, 700]

    private func update(_ swipe: inout TrackSwipeInteraction, x: Double,
                        y: Double = 0, width: Double,
                        previous: Bool = true, next: Bool = true) -> Double? {
        swipe.update(translationX: x, translationY: y, width: width, gap: 12,
                     canPrevious: previous, canNext: next)
    }

    private func finish(_ swipe: inout TrackSwipeInteraction, x: Double,
                        predicted: Double = 0, width: Double,
                        previous: Bool = true, next: Bool = true) -> Int? {
        swipe.finish(translationX: x, predictedX: predicted, width: width,
                     canPrevious: previous, canNext: next)
    }

    func testReturningToOriginTracksBeforeReleaseAndNeverAdvances() {
        for width in widths {
            var swipe = TrackSwipeInteraction()
            XCTAssertEqual(update(&swipe, x: -width * 0.6, y: 20, width: width), -width * 0.6)
            XCTAssertEqual(update(&swipe, x: -20, y: 40, width: width), -20)
            XCTAssertEqual(update(&swipe, x: 0, y: 40, width: width), 0)
            XCTAssertTrue(swipe.isTracking)
            XCTAssertNil(finish(&swipe, x: 0, predicted: -width * 3, width: width))
            XCTAssertFalse(swipe.isTracking)
        }
    }

    func testCrossingOriginImmediatelyTracksTheOtherDirection() {
        for width in widths {
            var swipe = TrackSwipeInteraction()
            _ = update(&swipe, x: -width * 0.6, width: width)
            XCTAssertEqual(update(&swipe, x: 18, y: 80, width: width), 18)
            XCTAssertEqual(update(&swipe, x: width * 0.5, y: width, width: width), width * 0.5)
            XCTAssertEqual(finish(&swipe, x: width * 0.5, width: width), -1)
            XCTAssertFalse(swipe.isTracking)
            XCTAssertNil(finish(&swipe, x: width * 0.5, width: width))
        }
    }

    func testDistanceThresholdCommitsOnceInEitherDirection() {
        for width in widths {
            for sign in [-1.0, 1.0] {
                var swipe = TrackSwipeInteraction()
                let threshold = max(48, width * 0.24)
                _ = update(&swipe, x: sign * (threshold - 1), width: width)
                XCTAssertNil(finish(&swipe, x: sign * (threshold - 1), width: width))
                _ = update(&swipe, x: sign * threshold, width: width)
                XCTAssertEqual(finish(&swipe, x: sign * threshold, width: width), sign < 0 ? 1 : -1)
                XCTAssertFalse(swipe.isTracking)
            }
        }
    }

    func testFlickRequiresEnoughTravelAndMatchingProjection() {
        for width in widths {
            for sign in [-1.0, 1.0] {
                var swipe = TrackSwipeInteraction()
                let travel = sign * width * 0.15
                _ = update(&swipe, x: travel, width: width)
                XCTAssertEqual(finish(&swipe, x: travel, predicted: sign * width, width: width), sign < 0 ? 1 : -1)
                _ = update(&swipe, x: travel, width: width)
                XCTAssertNil(finish(&swipe, x: travel, predicted: -sign * width, width: width))
                _ = update(&swipe, x: sign * 20, width: width)
                XCTAssertNil(finish(&swipe, x: sign * 20, predicted: sign * width, width: width))
            }
        }
    }

    func testQueueEdgesResistClampAndAllowReversal() {
        for width in widths {
            for gap in [8.0, 16.0] {
                var swipe = TrackSwipeInteraction()
                let limit = width + gap
                let resisted = swipe.update(translationX: -width * 3, translationY: 0,
                                             width: width, gap: gap,
                                             canPrevious: true, canNext: false)
                XCTAssertEqual(resisted, -limit * 0.16)
                XCTAssertEqual(update(&swipe, x: 20, y: 80, width: width, next: false), 20)
                XCTAssertEqual(swipe.update(translationX: width * 3, translationY: 0,
                                            width: width, gap: gap,
                                            canPrevious: true, canNext: false), limit)
                XCTAssertNil(finish(&swipe, x: -width, predicted: -width, width: width, next: false))
                XCTAssertEqual(swipe.update(translationX: width * 3, translationY: 0,
                                            width: width, gap: gap,
                                            canPrevious: false, canNext: true), limit * 0.16)
                XCTAssertNil(finish(&swipe, x: width, predicted: width, width: width, previous: false))
            }
        }
    }

    func testVerticalMotionDoesNotAcquireHorizontalIntent() {
        var swipe = TrackSwipeInteraction()
        XCTAssertNil(update(&swipe, x: 12, y: 30, width: 300))
        XCTAssertNil(update(&swipe, x: 40, y: 80, width: 300))
        XCTAssertFalse(swipe.isTracking)
        XCTAssertNil(finish(&swipe, x: 150, predicted: 300, width: 300))
        XCTAssertEqual(update(&swipe, x: -40, y: 10, width: 300), -40)
        XCTAssertTrue(swipe.isTracking)
    }

    func testCancellationClearsIntentBeforeTheNextGesture() {
        var swipe = TrackSwipeInteraction()
        _ = update(&swipe, x: -120, width: 300)
        swipe.reset()
        XCTAssertFalse(swipe.isTracking)
        XCTAssertNil(update(&swipe, x: 10, y: 40, width: 300))
        XCTAssertNil(finish(&swipe, x: -150, predicted: -300, width: 300))
        XCTAssertEqual(update(&swipe, x: 100, width: 300), 100)
        XCTAssertEqual(finish(&swipe, x: 100, width: 300), -1)
        XCTAssertFalse(swipe.isTracking)
    }

    func testInvalidInputsCancelTrackingAndCannotAdvance() {
        let invalidUpdates: [(Double, Double, Double, Double)] = [
            (.nan, 0, 300, 12), (.infinity, 0, 300, 12),
            (40, .nan, 300, 12), (40, .infinity, 300, 12),
            (40, 0, 0, 12), (40, 0, -1, 12),
            (40, 0, .nan, 12), (40, 0, .infinity, 12),
            (40, 0, 300, -1), (40, 0, 300, .infinity),
            (40, 0, 300, .nan), (40, 0, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        ]
        for (x, y, width, gap) in invalidUpdates {
            var swipe = TrackSwipeInteraction()
            _ = update(&swipe, x: -120, width: 300)
            XCTAssertNil(swipe.update(translationX: x, translationY: y, width: width,
                                      gap: gap, canPrevious: true, canNext: true))
            XCTAssertFalse(swipe.isTracking)
            XCTAssertNil(finish(&swipe, x: -150, predicted: -300, width: 300))
        }
        let invalidFinishes: [(Double, Double, Double)] = [
            (.nan, -300, 300), (-150, .nan, 300),
            (-.infinity, -300, 300), (-150, -.infinity, 300),
            (-150, -300, 0), (-150, -300, -1),
            (-150, -300, .nan), (-150, -300, .infinity)
        ]
        for (x, predicted, width) in invalidFinishes {
            var swipe = TrackSwipeInteraction()
            _ = update(&swipe, x: -120, width: 300)
            XCTAssertNil(finish(&swipe, x: x, predicted: predicted, width: width))
            XCTAssertFalse(swipe.isTracking)
        }
    }
}
