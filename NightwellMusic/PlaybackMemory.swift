import Foundation
import Combine
import CryptoKit
import UIKit

struct PlaybackMemory: Codable {
    var id: String
    var tracks: [Track]
    var position: Double
    var repeatMode: Int
    var shuffle: Bool
    var wave: Bool
    var queuedIDs: [String]? = nil
    var savedAt: Date? = nil

    private struct PositionCheckpoint: Codable {
        let id: String
        let position: Double
        let savedAt: Date
    }
    private static func positionKey(_ origin: URL, _ account: String) -> String {
        key(origin, account) + ".position"
    }

    static func key(_ origin: URL, _ account: String) -> String {
        "native.resume." + SHA256.hash(data: Data((origin.absoluteString + "|" + account).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ origin: URL, _ account: String) -> PlaybackMemory? {
        guard let bytes = UserDefaults.standard.data(forKey: key(origin, account)),
              var saved = try? JSONDecoder().decode(Self.self, from: bytes) else { return nil }
        if let data = UserDefaults.standard.data(forKey: positionKey(origin, account)),
           let latest = try? JSONDecoder().decode(PositionCheckpoint.self, from: data),
           latest.id == saved.id, latest.position.isFinite,
           latest.savedAt > (saved.savedAt ?? .distantPast),
           Date().timeIntervalSince(latest.savedAt) < 14 * 24 * 3600 {
            saved.position = max(0, latest.position)
        }
        return saved
    }
    func save(_ origin: URL, _ account: String) {
        guard !id.isEmpty, !tracks.isEmpty else { return }
        var latest = self
        latest.savedAt = Date()
        guard let bytes = try? JSONEncoder().encode(latest) else { return }
        UserDefaults.standard.set(bytes, forKey: Self.key(origin, account))
    }
    static func savePosition(id: String, position: Double, origin: URL, account: String) {
        guard !id.isEmpty, position.isFinite else { return }
        let latest = PositionCheckpoint(id: id, position: max(0, position), savedAt: Date())
        guard let data = try? JSONEncoder().encode(latest) else { return }
        UserDefaults.standard.set(data, forKey: positionKey(origin, account))
    }
}

/// Persistent lyric archive. Application Support is not purgeable like Caches.
/// A server- and track-scoped key keeps different catalogues separate.
actor LyricsDisk {
    static let shared = LyricsDisk()

    private struct Entry: Codable {
        let saved: Date
        let lyrics: Lyrics
    }
    private var recent: [String: Lyrics] = [:]
    private var timedRefreshAttempts: [String: Date] = [:]
    private let maxEntryBytes = 1_000_000

    private func key(_ origin: URL, _ id: String) -> String {
        SHA256.hash(data: Data((origin.absoluteString + id).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ origin: URL, _ id: String,
                      directory: FileManager.SearchPathDirectory) throws -> URL {
        let root = try FileManager.default.url(
            for: directory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("NativeLyrics", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(key(origin, id) + ".json")
    }

    private func read(_ file: URL) -> Lyrics? {
        guard let data = try? Data(contentsOf: file),
              data.count <= maxEntryBytes,
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        let lyrics = entry.lyrics
        guard lyrics.status == "instrumental" ||
              (lyrics.status == "found" &&
               (!(lyrics.plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                !(lyrics.lines?.isEmpty ?? true))) else { return nil }
        return lyrics
    }

    func get(_ origin: URL, _ id: String) -> Lyrics? {
        let cacheKey = key(origin, id)
        if let text = recent[cacheKey] { return text }
        if let path = try? file(origin, id, directory: .applicationSupportDirectory),
           let text = read(path) {
            recent[cacheKey] = text
            return text
        }
        // Import previously cached text from old versions, including records
        // older than the former 30-day expiry.
        if let legacy = try? file(origin, id, directory: .cachesDirectory),
           let text = read(legacy) {
            set(text, origin, id)
            return text
        }
        return nil
    }

    // Plain lyrics can be shown immediately while a richer, timed version
    // is fetched in the background. Throttle unsuccessful upgrades per track.
    func shouldRefreshTiming(_ origin: URL, _ id: String) -> Bool {
        let cacheKey = key(origin, id)
        let now = Date()
        guard now.timeIntervalSince(timedRefreshAttempts[cacheKey] ?? .distantPast) > 6 * 3600 else {
            return false
        }
        timedRefreshAttempts[cacheKey] = now
        return true
    }

    func set(_ lyrics: Lyrics, _ origin: URL, _ id: String) {
        guard lyrics.status == "found" || lyrics.status == "instrumental" else { return }
        var archived = lyrics
        if archived.status == "found" {
            // Keep both plain and synced representations when a server update
            // includes only one of them. Timed rows supply a plain fallback.
            let old = recent[key(origin, id)] ??
                (try? file(origin, id, directory: .applicationSupportDirectory)).flatMap(read)
            if archived.plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                archived.plain = old?.plain
            }
            // Never downgrade line timestamps or word-level timings when
            // the server later returns only plain or less precise lyrics.
            if let oldLines = old?.lines, !oldLines.isEmpty {
                let oldWords = oldLines.reduce(0) { $0 + ($1.words?.count ?? 0) }
                let newWords = archived.lines?.reduce(0) {
                    $0 + ($1.words?.count ?? 0)
                } ?? 0
                if (archived.lines?.isEmpty ?? true) || (oldWords > 0 && newWords == 0) {
                    archived.lines = oldLines
                }
            }
            if !(archived.lines?.isEmpty ?? true) { archived.synced = true }
            if archived.plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
               let rows = archived.lines, !rows.isEmpty {
                archived.plain = rows.map(\.text).joined(separator: "\n")
            }
            guard !(archived.plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                  !(archived.lines?.isEmpty ?? true) else { return }
        }
        guard let destination = try? file(origin, id, directory: .applicationSupportDirectory),
              let bytes = try? JSONEncoder().encode(Entry(saved: Date(), lyrics: archived)),
              bytes.count <= maxEntryBytes else { return }
        do {
            try bytes.write(to: destination, options: [
                .atomic, .completeFileProtectionUntilFirstUserAuthentication
            ])
            recent[key(origin, id)] = archived
            if recent.count > 180 {
                recent.removeAll(keepingCapacity: true)
                recent[key(origin, id)] = archived
            }
        } catch {
            // A protected-data write may fail before first device unlock.
        }
    }
}

@MainActor final class NativeLyrics: ObservableObject {
    @Published var value: Lyrics?
    @Published var trackID = ""
    private var task: Task<Void, Never>?
    private let cacheEnabled: Bool
    private let sleep: (Double) async throws -> Void
    init(cacheEnabled: Bool = true, sleep: @escaping (Double) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }) {
        self.cacheEnabled = cacheEnabled; self.sleep = sleep
    }
    func select(_ track: Track?, api: any LyricsService, origin: URL, online: Bool) {
        let sameSong = track != nil && track?.id == trackID
        task?.cancel()
        if !sameSong { value = nil }
        trackID = track?.id ?? ""
        guard let track else { return }
        task = Task {
            // Persisted text survives app restarts and is available offline.
            // The complete Lyrics Codable payload includes line timecodes and
            // the optional per-word start/end timestamps.
            var cached = cacheEnabled ? await LyricsDisk.shared.get(origin, track.id) : nil
            guard !Task.isCancelled, trackID == track.id else { return }
            if let embedded = track._offline_lyrics,
               embedded.status == "found" || embedded.status == "instrumental" {
                if cacheEnabled {
                    await LyricsDisk.shared.set(embedded, origin, track.id)
                    cached = await LyricsDisk.shared.get(origin, track.id) ?? embedded
                } else {
                    cached = embedded
                }
            }
            guard !Task.isCancelled, trackID == track.id else { return }
            if let cached { value = cached }
            let hasTiming = !(cached?.lines?.isEmpty ?? true)
            if hasTiming || cached?.status == "instrumental" { return }
            guard online, !track.id.hasPrefix("local_") else {
                if cached == nil {
                    value = Lyrics(status: "not_found", message: "Текст не сохранён на устройстве")
                }
                return
            }
            if cached != nil && cacheEnabled {
                let shouldRefresh = await LyricsDisk.shared.shouldRefreshTiming(origin, track.id)
                if !shouldRefresh { return }
            }
            do {
                for _ in 0..<20 {
                    let result = try await api.fetchLyrics(track.id)
                    guard !Task.isCancelled, trackID == track.id else { return }
                    if result.searching || result.status == "unavailable" {
                        if cached == nil { value = result }
                        try await sleep(max(2, min(60, result.retry_after ?? 3)))
                        continue
                    }
                    if result.status == "found" || result.status == "instrumental" {
                        if cacheEnabled {
                            await LyricsDisk.shared.set(result, origin, track.id)
                            let merged = await LyricsDisk.shared.get(origin, track.id)
                            guard !Task.isCancelled, trackID == track.id else { return }
                            value = merged ?? result
                        } else {
                            value = result
                        }
                    } else if cached == nil {
                        value = result
                    }
                    return
                }
            } catch is CancellationError {} catch {
                // A failed refresh must never replace existing saved lyrics.
                if cached == nil && !Task.isCancelled && trackID == track.id {
                    value = Lyrics(status: "error", message: "Не удалось загрузить текст. Повтори позже.")
                }
            }
        }
    }
    func preload(_ tracks: [Track], api: MusicAPI, origin: URL) async {
        for track in tracks.prefix(3) where !track.id.hasPrefix("local_") {
            let cached = await LyricsDisk.shared.get(origin, track.id)
            if cached?.status == "instrumental" || !(cached?.lines?.isEmpty ?? true) {
                continue
            }
            if cached != nil {
                let shouldRefresh = await LyricsDisk.shared.shouldRefreshTiming(origin, track.id)
                if !shouldRefresh { continue }
            }
            if let result: Lyrics = try? await api.request("/api/lyrics/" + track.id) {
                await LyricsDisk.shared.set(result, origin, track.id)
            }
        }
    }
}
