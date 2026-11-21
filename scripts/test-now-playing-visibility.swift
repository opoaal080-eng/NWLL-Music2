// swiftc NightwellMusic/NowPlayingVisibility.swift scripts/test-now-playing-visibility.swift -o /tmp/test-now-playing
@main
struct NowPlayingVisibilityRegression {
    static func main() {
        // First playback begins in the app. Repeated timer/artwork/playhead
        // updates must not bring system presentation back into the foreground.
        var visibility = NowPlayingVisibility()
        precondition(visibility.update(applicationIsActive: true, hasTrack: false) == .hide)
        for _ in 0..<20 {
            precondition(visibility.update(applicationIsActive: true, hasTrack: true) == .hidden)
        }
        // Opening Control Center, locking, or leaving the app must publish
        // immediately, even if a paused track's ID and position are unchanged.
        precondition(visibility.update(applicationIsActive: false, hasTrack: true) == .restore)
        precondition(visibility.update(applicationIsActive: false, hasTrack: true) == .update)
        precondition(visibility.update(applicationIsActive: true, hasTrack: true) == .hide)
        precondition(visibility.update(applicationIsActive: false, hasTrack: true) == .restore)
        // Stop/logout while hidden must not restore a stale media item.
        precondition(visibility.update(applicationIsActive: true, hasTrack: true) == .hide)
        precondition(visibility.update(applicationIsActive: true, hasTrack: false) == .hidden)
        precondition(visibility.update(applicationIsActive: false, hasTrack: false) == .hidden)
        // Background restoration on app launch and stopping in the background.
        var backgroundLaunch = NowPlayingVisibility()
        precondition(backgroundLaunch.update(applicationIsActive: false, hasTrack: true) == .restore)
        precondition(backgroundLaunch.update(applicationIsActive: false, hasTrack: false) == .hide)
        precondition(!NowPlayingVisibility.Action.hidden.isPresented)
        precondition(!NowPlayingVisibility.Action.hide.isPresented)
        precondition(NowPlayingVisibility.Action.restore.isPresented)
        precondition(NowPlayingVisibility.Action.update.isPresented)
        print("Now Playing visibility lifecycle regressions passed")
    }
}
