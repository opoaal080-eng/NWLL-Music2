import Foundation

/// Data shared between Nightwell Music and its isolated WidgetKit extension.
/// The file contains no login credentials or access tokens.
struct NWWidgetState: Codable {
    let trackID: String
    let title: String
    let artist: String
    let playing: Bool
    let coverID: String?
    let updated: Date

    static var empty: NWWidgetState {
        NWWidgetState(trackID: "", title: "Твой ритм",
                      artist: "Nightwell Music", playing: false,
                      coverID: nil, updated: .now)
    }

    // When signing strips the App Group entitlement, the widget must explain
    // why it cannot see the playing song instead of showing a fake pause.
    static var unavailable: NWWidgetState {
        NWWidgetState(trackID: "", title: "Нет синхронизации",
                      artist: "Нужна подпись с App Group", playing: false,
                      coverID: nil, updated: .now)
    }
}

enum NWWidgetStorage {
    // Prefer the project App Group. A distribution pipeline may also stamp a
    // public shared-group identifier into both Info.plists. We test every
    // candidate through Foundation's supported App Group API, never guessing
    // that the app has permission to access an unverified container.
    static let group = "group.fun.nightwell.music"
    private static let key = "nw-widget-player-v1"
    private static let filename = "nightwell-widget-player.json"
    private static let artworkFilename = "widget-cover-original-v2.jpg"

    private static let resolvedContainer: (name: String, url: URL)? = {
        let info = Bundle.main.infoDictionary ?? [:]
        let declared = [info["NWSharedAppGroup"] as? String,
                        info["AppGroupIdentifier"] as? String].compactMap { $0 }
        let additional = info["AppGroupIdentifiers"] as? [String] ?? []
        var candidates: [String] = []
        for name in [group] + declared + additional {
            guard name.hasPrefix("group."), !candidates.contains(name) else { continue }
            candidates.append(name)
        }
        for name in candidates {
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: name
            ) {
                return (name: name, url: url)
            }
        }
        return nil
    }()

    static var sharedRoot: URL? { resolvedContainer?.url }
    static var sharedGroup: String? { resolvedContainer?.name }
    static var isAvailable: Bool { resolvedContainer != nil }

    static func read() -> NWWidgetState {
        guard let root = sharedRoot else { return .unavailable }

        // Reading an atomic snapshot file avoids stale cross-process defaults
        // caches. Older installs can still read their previous UserDefaults data.
        if let data = try? Data(contentsOf: root.appendingPathComponent(filename)),
           let value = try? JSONDecoder().decode(NWWidgetState.self, from: data) {
            return value
        }
        if let name = sharedGroup,
           let data = UserDefaults(suiteName: name)?.data(forKey: key),
           let value = try? JSONDecoder().decode(NWWidgetState.self, from: data) {
            return value
        }
        return .empty
    }

    @discardableResult
    static func write(_ state: NWWidgetState) -> Bool {
        // A successful write to ordinary UserDefaults is not proof that the
        // widget can access it. Require the actual shared App Group container.
        guard let root = sharedRoot,
              let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try data.write(to: root.appendingPathComponent(filename),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if let name = sharedGroup {
                UserDefaults(suiteName: name)?.set(data, forKey: key)
            }
            return true
        } catch {
            NSLog("Nightwell widgets: shared snapshot write failed: %@", String(describing: error))
            return false
        }
    }

    @discardableResult
    static func saveCover(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 2_000_000,
              let root = sharedRoot else { return false }
        do {
            try bytes.write(to: root.appendingPathComponent(artworkFilename),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // Remove the cover created by the former destructive artwork
            // normalizer. The widget never reuses that file after upgrading.
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("widget-cover.jpg"))
            return true
        } catch { return false }
    }

    static func cover(for state: NWWidgetState) -> Data? {
        guard !state.trackID.isEmpty, state.coverID == state.trackID,
              let root = sharedRoot else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent(artworkFilename),
                         options: .mappedIfSafe)
    }
}
