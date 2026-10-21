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
    static func key(_ origin: URL, _ account: String) -> String {
        "native.resume." + SHA256.hash(data: Data((origin.absoluteString + "|" + account).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ origin: URL, _ account: String) -> PlaybackMemory? {
        guard let bytes = UserDefaults.standard.data(forKey: key(origin, account)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }
    func save(_ origin: URL, _ account: String) {
        guard !id.isEmpty, !tracks.isEmpty, let bytes = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(bytes, forKey: Self.key(origin, account))
    }
}

actor LyricsDisk {
    static let shared = LyricsDisk()
    struct Entry: Codable { let saved: Date; let lyrics: Lyrics }
    private func url(_ origin: URL, _ id: String) throws -> URL {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("NativeLyrics")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data((origin.absoluteString + id).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }
    func get(_ origin: URL, _ id: String) -> Lyrics? {
        guard let file = try? url(origin, id), let bytes = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: bytes), Date().timeIntervalSince(entry.saved) < (entry.lyrics.lookup_complete == false ? 3600 : 30 * 86400) else { return nil }
        return entry.lyrics
    }
    func set(_ lyrics: Lyrics, _ origin: URL, _ id: String) {
        guard lyrics.status == "found" || lyrics.status == "instrumental", let file = try? url(origin, id), let bytes = try? JSONEncoder().encode(Entry(saved: Date(), lyrics: lyrics)) else { return }
        try? bytes.write(to: file, options: .atomic)
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
        task?.cancel(); value = nil; trackID = track?.id ?? ""
        guard let track else { return }
        task = Task {
            if let embedded = track._offline_lyrics, embedded.status == "found" || embedded.status == "instrumental" {
                value = embedded; if cacheEnabled { await LyricsDisk.shared.set(embedded, origin, track.id) }; return
            }
            if cacheEnabled, let cached = await LyricsDisk.shared.get(origin, track.id) { if !Task.isCancelled { value = cached }; return }
            guard online, !track.id.hasPrefix("local_") else { value = Lyrics(status: "not_found", message: "Текст не сохранён на устройстве"); return }
            do {
                for _ in 0..<20 {
                    let result = try await api.fetchLyrics(track.id)
                    guard !Task.isCancelled else { return }; value = result
                    if !result.searching && result.status != "unavailable" { if cacheEnabled { await LyricsDisk.shared.set(result, origin, track.id) }; return }
                    try await sleep(max(2, min(60, result.retry_after ?? 3)))
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { value = Lyrics(status: "error", message: "Не удалось загрузить текст. Повтори позже.") } }
        }
    }
    func preload(_ tracks: [Track], api: MusicAPI, origin: URL) async {
        for track in tracks.prefix(3) where track._offline != true {
            if await LyricsDisk.shared.get(origin, track.id) != nil { continue }
            if let result: Lyrics = try? await api.request("/api/lyrics/" + track.id) { await LyricsDisk.shared.set(result, origin, track.id) }
        }
    }
}
