import Foundation

@MainActor final class LibraryRefreshCoordinator {
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func run(_ work: @escaping @MainActor () async -> Void) async {
        if let task { await task.value; return }
        let id = UUID()
        generation = id
        let next = Task { await work() }
        task = next
        await next.value
        if generation == id { task = nil }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    static func load(tracks: @escaping @MainActor () async -> Void,
                     likes: @escaping @MainActor () async -> Void,
                     playlists: @escaping @MainActor () async -> Void) async {
        async let a: Void = tracks()
        async let b: Void = likes()
        async let c: Void = playlists()
        _ = await (a, b, c)
    }
}
