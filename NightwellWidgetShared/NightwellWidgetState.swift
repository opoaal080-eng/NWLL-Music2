
import Foundation

/// The small, credential-free snapshot shared with the WidgetKit process.
struct NWWidgetState: Codable {
    let trackID: String
    let title: String
    let artist: String
    let playing: Bool
    let coverID: String?
    let updated: Date

    static let empty = NWWidgetState(trackID: "", title: "Твой ритм",
                                    artist: "Nightwell Music", playing: false,
                                    coverID: nil, updated: Date())
}

enum NWWidgetStorage {
    static let group = "group.fun.nightwell.music"
    private static let key = "nw-widget-player-v1"

    static func read() -> NWWidgetState {
        guard let defaults = UserDefaults(suiteName: group),
              let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(NWWidgetState.self, from: data)
        else { return .empty }
        return state
    }

    static func write(_ state: NWWidgetState) -> Bool {
        guard let defaults = UserDefaults(suiteName: group),
              let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    static func saveCover(_ bytes: Data) -> Bool {
        guard bytes.count > 0, bytes.count < 2_000_000,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return false }
        do {
            try bytes.write(to: root.appendingPathComponent("widget-cover.jpg"), options: .atomic)
            return true
        } catch { return false }
    }

    static func cover(for state: NWWidgetState) -> Data? {
        guard !state.trackID.isEmpty, state.coverID == state.trackID,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent("widget-cover.jpg"))
    }
}
