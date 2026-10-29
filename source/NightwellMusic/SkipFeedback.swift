import Foundation

/// Two early skips within seven days put a track on a 48-hour recommendation cooldown.
enum SkipFeedback {
    struct Event: Codable { var count: Int; var time: TimeInterval }
    static let week: TimeInterval = 7 * 86400
    static let cooldown: TimeInterval = 48 * 3600
    static func next(_ previous: Event?, now: TimeInterval) -> Event {
        guard let previous, now >= previous.time, now - previous.time < week
        else { return Event(count: 1, time: now) }
        return Event(count: min(20, previous.count + 1), time: now)
    }
    static func blocked(_ event: Event, now: TimeInterval) -> Bool {
        event.count >= 2 && now >= event.time && now - event.time < cooldown
    }
    private static func storage(_ origin: URL, _ account: String) -> String {
        "nw-skip-feedback|" + origin.absoluteString + "|" + account
    }
    private static func read(_ key: String) -> [String: Event] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode([String: Event].self, from: data) else { return [:] }
        return value
    }
    static func recentIDs(origin: URL, account: String, now: TimeInterval = Date().timeIntervalSince1970) -> Set<String> {
        Set(read(storage(origin, account)).compactMap { id, event in blocked(event, now: now) ? id : nil })
    }
    static func record(_ id: String, origin: URL, account: String, now: TimeInterval = Date().timeIntervalSince1970) {
        guard !id.isEmpty, id.count <= 80, !account.isEmpty, account != "device" else { return }
        let key = storage(origin, account)
        var events = read(key).filter { now >= $0.value.time && now - $0.value.time < week }
        events[id] = next(events[id], now: now)
        if events.count > 200 {
            events = Dictionary(uniqueKeysWithValues: events.sorted { $0.value.time > $1.value.time }
                .prefix(200).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(events) { UserDefaults.standard.set(data, forKey: key) }
    }
}
