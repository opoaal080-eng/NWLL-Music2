import Foundation

enum FavoriteMutationPolicy {
    static func membership(server: [String], pending: [String: Bool]) -> Set<String> {
        var result = Set(server)
        for (id, desired) in pending {
            if desired { result.insert(id) } else { result.remove(id) }
        }
        return result
    }

    static func order(server: [String], membership: Set<String>, local: [String]) -> [String] {
        let serverSet = Set(server)
        var seen = Set<String>()
        let localOnly = local.filter { membership.contains($0) && !serverSet.contains($0) && seen.insert($0).inserted }
        let canonical = server.filter { membership.contains($0) && seen.insert($0).inserted }
        return localOnly + canonical + membership.subtracting(seen).sorted()
    }
}
