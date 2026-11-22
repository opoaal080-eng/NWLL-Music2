import Foundation

/// Keeps one horizontal drag reversible even when the finger drifts vertically.
struct TrackSwipeInteraction {
    private(set) var isTracking = false

    mutating func update(translationX: Double, translationY: Double,
                         width: Double, gap: Double,
                         canPrevious: Bool, canNext: Bool) -> Double? {
        guard translationX.isFinite, translationY.isFinite,
              width.isFinite, width > 0, gap.isFinite, gap >= 0,
              (width + gap).isFinite else {
            reset()
            return nil
        }
        if !isTracking {
            guard abs(translationX) > abs(translationY) * 1.12 else { return nil }
            isTracking = true
        }

        // Once recognized, every position belongs to this drag, including zero
        // and the opposite direction. Rechecking the angle would strand a card
        // when the finger returns toward its origin with some vertical drift.
        let limit = width + gap
        let raw = max(-limit, min(limit, translationX))
        let available = translationX < 0 ? canNext : canPrevious
        return available ? raw : raw * 0.16
    }

    mutating func finish(translationX: Double, predictedX: Double, width: Double,
                         canPrevious: Bool, canNext: Bool) -> Int? {
        defer { reset() }
        guard isTracking, translationX.isFinite, predictedX.isFinite,
              width.isFinite, width > 0 else { return nil }

        let direction = translationX < 0 ? 1 : -1
        guard direction > 0 ? canNext : canPrevious else { return nil }
        let distance = abs(translationX)
        let threshold = max(48, width * 0.24)
        let deliberateFlick = distance > max(25, width * 0.10) &&
            abs(predictedX) > width * 0.53 &&
            (translationX < 0) == (predictedX < 0)
        guard distance >= threshold || deliberateFlick else { return nil }
        return direction
    }

    mutating func reset() {
        isTracking = false
    }
}
