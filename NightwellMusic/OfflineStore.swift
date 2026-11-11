import Foundation
import CryptoKit
import AVFoundation

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
                if playableAudio(dir.appendingPathComponent(id + ".m4a"),
                    expectedBytes: (item["offline_bytes"] as? NSNumber)?.intValue) {
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
        return FileManager.default.fileExists(atPath: meta.path) && playableAudio(audio) ? audio : nil
    }
    /// Called directly from the download delegate while the system temporary file exists.
    /// Copy on disk instead of allocating base64 versions of an entire track in memory.
    static func saveDownloadedFile(_ file: URL, track: Track, origin: URL, account: String) throws {
        lock.lock(); defer { lock.unlock() }
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
        guard playableAudio(staging, expectedBytes: size) else {
            throw URLError(.cannotDecodeContentData)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: target) }
        try metadata.write(to: dir.appendingPathComponent(track.id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        validated.removeValue(forKey: target.path)
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
        return ["ok": true, "size": bytes.count]
    }
}

