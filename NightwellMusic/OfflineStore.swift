import Foundation
import CryptoKit

/// Device-only files, separated by server and account. No arbitrary file paths.
enum OfflineStore {
    static let limit = 32 * 1024 * 1024
    private static let lock = NSRecursiveLock()
    private static func valid(_ s: String) -> Bool { !s.isEmpty && s.count <= 80 && s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }
    private static func storageRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Offline", isDirectory: true)
    }
    private static func allTracks() throws -> [[String: Any]] {
        let root = try storageRoot()
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var tracks: [[String: Any]] = []
        for dir in dirs where dir.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
                      let data = try? Data(contentsOf: file), var item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = item["id"] as? String, valid(id),
                      FileManager.default.fileExists(atPath: dir.appendingPathComponent(id + ".m4a").path) else { continue }
                item["_offline"] = true; item["_offline_account"] = "local_" + dir.lastPathComponent
                tracks.append(item)
            }
        }
        return tracks
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
        return FileManager.default.fileExists(atPath: audio.path) && FileManager.default.fileExists(atPath: meta.path) ? audio : nil
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
        let staging = dir.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: file, to: staging)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: target) }
        try metadata.write(to: dir.appendingPathComponent(track.id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func operation(_ body: [String: Any], origin: URL) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let op = body["op"] as? String else { throw URLError(.badURL) }
        if op == "listAll" { return ["tracks": try allTracks()] }
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
        if op == "remove" { try? FileManager.default.removeItem(at: meta); try? FileManager.default.removeItem(at: target); return ["ok": true] }
        guard op == "save", let encoded = body["audio"] as? String, encoded.count <= limit * 4 / 3 + 4,
              let bytes = Data(base64Encoded: encoded), bytes.count > 256, bytes.count <= limit,
              String(data: bytes.subdata(in: 4..<8), encoding: .ascii) == "ftyp",
              var track = body["track"] as? [String: Any], track["id"] as? String == id else { throw URLError(.cannotDecodeContentData) }
        track["_offline"] = true; track["_offline_account"] = account; track["offline_bytes"] = bytes.count
        let metadata = try JSONSerialization.data(withJSONObject: track)
        guard metadata.count <= 2 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        try bytes.write(to: target, options: .atomic); try metadata.write(to: meta, options: .atomic)
        return ["ok": true, "size": bytes.count]
    }
}

