// Keep system playback presentation outside the active app. An inactive app
// includes Control Center and the Lock Screen, where transport controls belong.
// This policy changes metadata publication, never the audio transport itself.
struct NowPlayingVisibility {
    enum Action: Equatable {
        case hide
        case hidden
        case restore
        case update

        var isPresented: Bool { self == .restore || self == .update }
    }

    private var wasPresented: Bool?

    mutating func update(applicationIsActive: Bool, hasTrack: Bool) -> Action {
        let presented = !applicationIsActive && hasTrack
        defer { wasPresented = presented }
        if presented { return wasPresented == true ? .update : .restore }
        return wasPresented == false ? .hidden : .hide
    }
}
