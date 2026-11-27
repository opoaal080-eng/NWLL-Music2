import Foundation
import CryptoKit
import AVFoundation
import UIKit

/// Device-only files, separated by server and account. No arbitrary file paths.
enum OfflineStore {
    // Long mixes and lossless songs may exceed 32 MB. Copy files on disk
    // rather than bringing whole audio files into Swift process memory.
    static let limit = 128 * 1024 * 1024
    private static let lock = NSRecursiveLock()
    // Decode only once per unchanged file. A saved title/cover is not proof
    // that the server returned a complete and decodable audio recording.
    private static var validated: [String: (bytes: Int, changed: Date?, playable: Bool)] = [:]

    private static func playableAudio(_ url: URL, expectedBytes: Int? = nil) -> Bool {
        guard let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              attrs.isRegularFile == true,
              let bytes = attrs.fileSize, bytes > 256, bytes <= limit,
              expectedBytes == nil || expectedBytes == bytes else { return false }
        if let hit = validated[url.path], hit.bytes == bytes, hit.changed == attrs.contentModificationDate {
            return hit.playable
        }
        let good: Bool
        if let handle = try? FileHandle(forReadingFrom: url) {
            let header = (try? handle.read(upToCount: 12)) ?? Data()
            try? handle.close()
            if header.count >= 8, String(data: header[4..<8], encoding: .ascii) == "ftyp",
               let audio = try? AVAudioFile(forReading: url),
               audio.length > 0, audio.processingFormat.channelCount > 0 {
                good = true
            } else {
                good = false
            }
        } else {
            good = false
        }
        validated[url.path] = (bytes: bytes, changed: attrs.contentModificationDate, playable: good)
        return good
    }

    // Caller holds lock. Legacy files remain valid, and archives expose the
    // original byte length to existing offline metadata.
    private static func storedAudio(_ raw: URL, expectedBytes: Int? = nil) -> URL? {
        if playableAudio(raw, expectedBytes: expectedBytes) { return raw }
        let archive = raw.deletingPathExtension().appendingPathExtension("nwz")
        guard let attrs = try? archive.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              attrs.isRegularFile == true, let bytes = attrs.fileSize, bytes > 256, bytes <= limit,
              let reader = try? NWZ.Reader(archive),
              expectedBytes == nil || reader.length == expectedBytes else { return nil }
        if let hit = validated[archive.path], hit.bytes == bytes, hit.changed == attrs.contentModificationDate {
            return hit.playable ? archive : nil
        }
        let head = try? reader.range(0, count: 12)
        let good = head.map { String(data: $0.subdata(in: 4..<8), encoding: .ascii) == "ftyp" } ?? false
        validated[archive.path] = (bytes: bytes, changed: attrs.contentModificationDate, playable: good)
        return good ? archive : nil
    }

    private static func valid(_ s: String) -> Bool { !s.isEmpty && s.count <= 80 && s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }
    private static func storageRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Offline", isDirectory: true)
    }
    private static func allTracks() throws -> (tracks: [[String: Any]], damaged: [[String: Any]]) {
        let root = try storageRoot()
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return ([], []) }
        var tracks: [[String: Any]] = [], damaged: [[String: Any]] = []
        for dir in dirs where dir.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
                      let data = try? Data(contentsOf: file), var item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = item["id"] as? String, valid(id) else { continue }
                if storedAudio(dir.appendingPathComponent(id + ".m4a"),
                    expectedBytes: (item["offline_bytes"] as? NSNumber)?.intValue) != nil {
                    item["_offline"] = true
                    item["_offline_account"] = "local_" + dir.lastPathComponent
                    tracks.append(item)
                } else {
                    // Preserve metadata so the user can retry the download, but
                    // never present artwork as if it were a playable audio file.
                    damaged.append(item)
                }
            }
        }
        return (tracks, damaged)
    }
    private static func directory(_ origin: URL, _ account: String) throws -> URL {
        guard valid(account) else { throw URLError(.badURL) }
        let scope = account.range(of: "^local_[a-f0-9]{64}$", options: .regularExpression) != nil ? String(account.dropFirst(6)) : SHA256.hash(data: Data((origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        let base = try storageRoot().appendingPathComponent(scope, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var mutable = base; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? mutable.setResourceValues(values)
        return base
    }
    static func audio(origin: URL, account: String, id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard valid(id), let dir = try? directory(origin, account) else { return nil }
        let audio = dir.appendingPathComponent(id + ".m4a"), meta = dir.appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: meta.path) else { return nil }
        let expected = (try? Data(contentsOf: meta))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["offline_bytes"] as? NSNumber)?.intValue }
        return storedAudio(audio, expectedBytes: expected)
    }
    // Offline artwork belongs beside the downloaded recording, not in the
    // purgeable URL cache. Both the player and iOS Now Playing use this file.
    static func cover(origin: URL, account: String, id: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard valid(id), let dir = try? directory(origin, account) else { return nil }
        // Discard pre-v2 artwork because earlier builds destructively modified
        // its pixels. Keep the audio and metadata, only artwork is re-fetched.
        let legacy = dir.appendingPathComponent(id + ".cover.jpg")
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
        let path = dir.appendingPathComponent(id + ".cover-original-v2.jpg")
        guard let length = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              length > 0, length <= 3 * 1024 * 1024,
              let data = try? Data(contentsOf: path, options: .mappedIfSafe) else { return nil }
        return UIImage(data: data)
    }

    static func saveCover(_ image: UIImage, origin: URL, account: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard valid(id), let directory = try? directory(origin, account),
              let data = image.jpegData(compressionQuality: 0.83),
              !data.isEmpty, data.count <= 3 * 1024 * 1024 else {
            throw URLError(.cannotDecodeContentData)
        }
        let file = directory.appendingPathComponent(id + ".cover-original-v2.jpg")
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // A successful new download removes the old corrupted derivative.
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(id + ".cover.jpg"))
        var mutable = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    /// Called directly from the download delegate while the system temporary file exists.
    /// Copy on disk instead of allocating base64 versions of an entire track in memory.
    static func saveDownloadedFile(_ file: URL, track: Track, origin: URL, account: String) throws {
        guard valid(track.id) else { throw URLError(.badURL) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 256, size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count >= 8, String(data: header[4..<8], encoding: .ascii) == "ftyp" else { throw URLError(.cannotDecodeContentData) }
        let dir = try directory(origin, account), target = dir.appendingPathComponent(track.id + ".m4a")
        var item = track.dictionary
        item["_offline"] = true; item["_offline_account"] = account; item["offline_bytes"] = size
        let metadata = try JSONSerialization.data(withJSONObject: item)
        let staging = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: file, to: staging)
        lock.lock()
        let validStaging = playableAudio(staging, expectedBytes: size)
        validated.removeValue(forKey: staging.path)
        lock.unlock()
        guard validStaging else { throw URLError(.cannotDecodeContentData) }
        // Compression can be slow on hard-to-compress AAC. Do not hold the
        // shared offline-store lock while encoding or verifying.
        let archiveStage = dir.appendingPathComponent(UUID().uuidString + ".nwz")
        defer { try? FileManager.default.removeItem(at: archiveStage) }
        let mode = NWZ.selectedMode
        let packed = NWZ.enabled && (try? NWZ.pack(staging, into: archiveStage, mode: mode,
            cancelled: { !NWZ.enabled })) == true
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: target) }
        try metadata.write(to: dir.appendingPathComponent(track.id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        validated.removeValue(forKey: target.path)
        let archive = target.deletingPathExtension().appendingPathExtension("nwz")
        validated.removeValue(forKey: archive.path)
        try? FileManager.default.removeItem(at: archive)
        if packed && NWZ.enabled {
            // If installation fails or is interrupted, the original M4A
            // remains a valid download. Never delete it before archive commit.
            do {
                try FileManager.default.moveItem(at: archiveStage, to: archive)
                try FileManager.default.removeItem(at: target)
            } catch { /* retain the playable original or verified archive */ }
        }
    }
    // All device downloads, including imported/local-account tracks. These
    // figures count audio file lengths, not covers, caches or APFS allocation.
    struct CompressionStats: Equatable {
        var original: Int64 = 0
        var stored: Int64 = 0
        var packed = 0
        var plain = 0
        var damaged = 0
        var saved: Int64 { max(0, original - stored) }
    }
    private struct CompressionRecord {
        let raw: URL
        let expected: Int?
    }
    private static func compressionRecords() -> [CompressionRecord] {
        guard let root = try? storageRoot(),
              let dirs = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var records: [CompressionRecord] = []
        for dir in dirs where dir.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
                      let data = try? Data(contentsOf: file),
                      let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = meta["id"] as? String, valid(id), file.deletingPathExtension().lastPathComponent == id else { continue }
                records.append(CompressionRecord(raw: dir.appendingPathComponent(id + ".m4a"),
                    expected: (meta["offline_bytes"] as? NSNumber)?.intValue))
            }
        }
        return records
    }
    private static func byteSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    static func compressionStats() -> CompressionStats {
        lock.lock(); defer { lock.unlock() }
        var stats = CompressionStats()
        for record in compressionRecords() {
            let raw = record.raw, archive = raw.deletingPathExtension().appendingPathExtension("nwz")
            let rawSize = byteSize(raw), archiveSize = byteSize(archive)
            stats.stored += rawSize + archiveSize
            if rawSize > 256 && (record.expected == nil || Int64(record.expected!) == rawSize) {
                stats.original += rawSize; stats.plain += 1
            } else if archiveSize > 0, let reader = try? NWZ.Reader(archive),
                      record.expected == nil || reader.length == record.expected {
                stats.original += Int64(reader.length); stats.packed += 1
            } else {
                stats.original += Int64(record.expected ?? Int(rawSize + archiveSize))
                stats.damaged += 1
            }
        }
        return stats
    }
    static func compressionCandidates() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return compressionRecords().filter {
            byteSize($0.raw) > 256 && byteSize($0.raw.deletingPathExtension().appendingPathExtension("nwz")) == 0
        }.map(\.raw)
    }

    struct PreparedCompression {
        fileprivate let raw: URL
        fileprivate let stage: URL
        fileprivate let identity: String
        fileprivate let metaIdentity: String
        fileprivate let original: Int64
    }
    private static func identity(_ file: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file.path),
              let inode = a[.systemFileNumber] as? NSNumber,
              let size = a[.size] as? NSNumber,
              let date = a[.modificationDate] as? Date else { return nil }
        return "\(inode)|\(size)|\(date.timeIntervalSinceReferenceDate)"
    }
    static func prepareCompression(_ raw: URL, mode: NWZ.Mode,
                                   cancelled: () -> Bool) throws -> PreparedCompression? {
        let meta = raw.deletingPathExtension().appendingPathExtension("json")
        let archive = raw.deletingPathExtension().appendingPathExtension("nwz")
        lock.lock()
        let stamp = identity(raw), metaStamp = identity(meta), size = byteSize(raw)
        let eligible = byteSize(archive) == 0 && playableAudio(raw)
        lock.unlock()
        guard eligible, let stamp, let metaStamp, !cancelled(), NWZ.permitted else { return nil }
        let stage = raw.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".nwz")
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: stage) } }
        guard try NWZ.pack(raw, into: stage, mode: mode, cancelled: cancelled) else { return nil }
        keep = true
        return PreparedCompression(raw: raw, stage: stage, identity: stamp,
                                   metaIdentity: metaStamp, original: size)
    }
    static func discardCompression(_ prepared: PreparedCompression) {
        try? FileManager.default.removeItem(at: prepared.stage)
    }
    // Called on main after checking the player's current and prepared track.
    // A concurrent deletion or replacement invalidates the snapshot; never
    // recreate a deleted download or replace newer audio.
    @discardableResult
    static func installCompression(_ prepared: PreparedCompression) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let raw = prepared.raw
        let meta = raw.deletingPathExtension().appendingPathExtension("json")
        let archive = raw.deletingPathExtension().appendingPathExtension("nwz")
        guard NWZ.enabled, NWZ.permitted,
              identity(raw) == prepared.identity, identity(meta) == prepared.metaIdentity,
              !FileManager.default.fileExists(atPath: archive.path) else { return 0 }
        let size = byteSize(prepared.stage)
        guard size > 0, size < prepared.original else { return 0 }
        try FileManager.default.moveItem(at: prepared.stage, to: archive)
        do { try FileManager.default.removeItem(at: raw) }
        catch {
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
        validated.removeValue(forKey: raw.path)
        validated.removeValue(forKey: archive.path)
        return prepared.original - size
    }

    static func importLocalFile(_ file: URL, id: String, title: String,
                                duration: Double, origin: URL) throws {
        guard valid(id) else { throw URLError(.badURL) }
        let track = Track(id: id, title: title, artist: "На этом устройстве",
                          duration: duration.isFinite ? max(0, duration) : 0,
                          _offline: true, _offline_account: "device")
        // Uses an on-disk copy and validation. No Data(contentsOf:) or Base64.
        try saveDownloadedFile(file, track: track, origin: origin, account: "device")
    }

    static func operation(_ body: [String: Any], origin: URL) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let op = body["op"] as? String else { throw URLError(.badURL) }
        if op == "listAll" {
            let scan = try allTracks()
            return ["tracks": scan.tracks, "damaged": scan.damaged]
        }
        let account = body["account"] as? String ?? "device"
        let dir = try directory(origin, account)
        if op == "list" {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let tracks = files.filter { $0.pathExtension == "json" }.compactMap { file -> [String: Any]? in
                guard let data = try? Data(contentsOf: file), let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = item["id"] as? String, audio(origin: origin, account: account, id: id) != nil else { return nil }; return item
            }
            return ["tracks": tracks]
        }
        guard let id = body["id"] as? String, valid(id) else { throw URLError(.badURL) }
        let target = dir.appendingPathComponent(id + ".m4a"), meta = dir.appendingPathComponent(id + ".json")
        if op == "remove" {
            try? FileManager.default.removeItem(at: meta)
            try? FileManager.default.removeItem(at: target)
            let archive = target.deletingPathExtension().appendingPathExtension("nwz")
            try? FileManager.default.removeItem(at: archive)
            validated.removeValue(forKey: archive.path)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".cover-original-v2.jpg"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".cover.jpg"))
            validated.removeValue(forKey: target.path)
            return ["ok": true]
        }
        guard op == "save", let encoded = body["audio"] as? String, encoded.count <= limit * 4 / 3 + 4,
              let bytes = Data(base64Encoded: encoded), bytes.count > 256, bytes.count <= limit,
              String(data: bytes.subdata(in: 4..<8), encoding: .ascii) == "ftyp",
              var track = body["track"] as? [String: Any], track["id"] as? String == id else { throw URLError(.cannotDecodeContentData) }
        track["_offline"] = true; track["_offline_account"] = account; track["offline_bytes"] = bytes.count
        let metadata = try JSONSerialization.data(withJSONObject: track)
        guard metadata.count <= 2 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let staging = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: staging) }
        try bytes.write(to: staging, options: .atomic)
        guard playableAudio(staging, expectedBytes: bytes.count) else {
            throw URLError(.cannotDecodeContentData)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: target) }
        try metadata.write(to: meta, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        validated.removeValue(forKey: target.path)
        let oldArchive = target.deletingPathExtension().appendingPathExtension("nwz")
        try? FileManager.default.removeItem(at: oldArchive)
        validated.removeValue(forKey: oldArchive.path)
        // The legacy bridge used to bypass compression entirely. Queue the
        // same safe conversion used by the manual optimizer, after unlocking.
        if NWZ.enabled {
            let candidate = target
            DispatchQueue.global(qos: .utility).async {
                guard NWZ.enabled, NWZ.permitted else { return }
                // Avoid racing an active player: installation is on main and
                // refuses the current or already-prepared track.
                let prepared = try? prepareCompression(candidate, mode: NWZ.selectedMode,
                    cancelled: { !NWZ.enabled })
                guard let prepared else { return }
                DispatchQueue.main.async {
                    defer { discardCompression(prepared) }
                    guard NWZ.enabled,
                          !NativePlayer.shared.protectedOfflineIDs.contains(id) else { return }
                    _ = try? installCompression(prepared)
                }
            }
        }
        return ["ok": true, "size": bytes.count]
    }
}



/// Migrates artwork for recordings downloaded before covers were persisted.
/// Work is sequential and low priority so playback and the cover CDN stay fast.
actor OfflineArtworkArchive {
    static let shared = OfflineArtworkArchive()

    private var attempted: [String: Date] = [:]
    private var inFlight = Set<String>()

    func backfill(_ tracks: [Track], origin: URL) async {
        for track in tracks where track._offline == true {
            if Task.isCancelled { return }
            let owner = track._offline_account ?? "device"
            await saveIfNeeded(track, origin: origin, account: owner)
        }
    }

    func saveIfNeeded(_ track: Track, origin: URL, account: String) async {
        let key = origin.absoluteString + "|" + account + "|" + track.id
        guard !inFlight.contains(key),
              Date().timeIntervalSince(attempted[key] ?? .distantPast) >= 300
        else { return }
        if OfflineStore.cover(origin: origin, account: account, id: track.id) != nil {
            attempted[key] = .now
            return
        }
        inFlight.insert(key)
        attempted[key] = .now
        defer { inFlight.remove(key) }
        // Imported/embedded artwork is also independent of the network.
        var image: UIImage?
        if let raw = track.cover_url, raw.hasPrefix("data:image/"),
           let comma = raw.firstIndex(of: ","),
           let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])),
           data.count < 2 * 1024 * 1024 {
            image = UIImage(data: data)
        }
        if image == nil,
           let url = CoverImagePipeline.coverURL(for: track, origin: origin) {
            image = await CoverImagePipeline.shared.image(for: url, maxPixel: 512)
        }
        // A stale external CDN URL may be unavailable when the user
        // downloads the track. Try Nightwell's same-origin cover endpoint.
        if image == nil, !track.id.hasPrefix("local_"),
           track.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
           let fallback = URL(string: "api/covers/" + track.id, relativeTo: origin) {
            image = await CoverImagePipeline.shared.image(for: fallback, maxPixel: 512)
        }
        guard let image, !Task.isCancelled else { return }
        // Archive exactly the artwork returned by the cover pipeline.
        // Do not process corner colours or copy pixels into the image.
        try? OfflineStore.saveCover(image, origin: origin,
                                    account: account, id: track.id)
    }
}
