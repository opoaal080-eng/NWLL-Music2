import Foundation

@MainActor final class Gate {
    var waiting: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiting = $0 } }
    func open() { waiting?.resume(); waiting = nil }
}
@main struct RefreshChecks {
    @MainActor static func main() async {
        let gate = Gate()
        var events: [String] = []
        let load = Task {
            await LibraryRefreshCoordinator.load(tracks: {
                await gate.wait()
                events.append("tracks")
            }, likes: { events.append("likes") }, playlists: { events.append("playlists") })
        }
        for _ in 0..<10000 {
            if gate.waiting != nil && events.count == 2 { break }
            await Task.yield()
        }
        precondition(Set(events) == Set(["likes", "playlists"]), "Fast responses must publish while catalogue is still blocked")
        gate.open()
        await load.value
        precondition(events.last == "tracks")

        let coordinator = LibraryRefreshCoordinator(), blocked = Gate()
        var calls = 0
        let first = Task { await coordinator.run { calls += 1; await blocked.wait() } }
        while blocked.waiting == nil { await Task.yield() }
        let second = Task { await coordinator.run { calls += 1 } }
        for _ in 0..<100 { await Task.yield() }
        precondition(calls == 1, "Concurrent refreshes must share one operation")
        blocked.open()
        await first.value; await second.value
        precondition(calls == 1)
        await coordinator.run { calls += 1 }
        precondition(calls == 2, "Completed work must allow a fresh update")
        print("Progressive loading and refresh deduplication passed")
    }
}
