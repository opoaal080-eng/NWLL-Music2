import Foundation

/// Sampling belongs to the small progress controls, never the shared playback
/// clock: a smooth playhead must not rebuild artwork, lists or player menus.
enum PlaybackProgressPresentation {
    static func position(displayPosition: Double, duration: Double,
                         playing: Bool, displayMatchesPlayback: Bool,
                         livePosition: () -> Double) -> Double {
        // Incoming metadata can lead the audible item during a handoff. Its
        // timeline must stay at zero until that same item owns the playhead.
        guard displayMatchesPlayback else { return 0 }
        let upperBound = duration.isFinite && duration > 0 ? duration : 1
        let fallback = displayPosition.isFinite
            ? min(upperBound, max(0, displayPosition)) : 0
        // Paused position is the transport's frozen snapshot, including EQ.
        guard playing else { return fallback }
        let live = livePosition()
        guard live.isFinite, live >= 0 else { return fallback }
        return min(upperBound, live)
    }

    static func fraction(position: Double, duration: Double) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
}
