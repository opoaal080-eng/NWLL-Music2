import Foundation
import Compression
import CryptoKit
import AVFoundation
import UniformTypeIdentifiers
import ObjectiveC

// NWZ1: fixed 256 KiB chunks, a bounded index, independent codecs and SHA256
// per chunk. All sizes are little endian. No transcoding or PCM conversion.
enum NWZ {
    enum Mode: String, CaseIterable, Identifiable {
        case fast, balanced, maximum
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fast: return "Быстро"
            case .balanced: return "Баланс"
            case .maximum: return "Максимум"
            }
        }
    }
    static let enabledKey = "nw-nwz-enabled"
    static let modeKey = "nw-nwz-mode"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var selectedMode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .balanced }
    // Encoding is CPU-intensive, especially LZMA. Serialize every encoder
    // (download and manual optimizer) without blocking readers or the UI.
    private static let encoder = NSLock()
    static let block = 256 * 1024
    static let maximum = 128 * 1024 * 1024
    static let magic = Data([78, 87, 90, 49])
    static let entrySize = 40
    static var invalid: URLError { URLError(.cannotDecodeContentData) }
    static func number(_ n: Int) -> Data {
        let v = UInt32(n)
        return Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
                     UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)])
    }
    static func integer(_ d: Data, _ i: Int) -> Int {
        Int(d[i]) | (Int(d[i+1]) << 8) | (Int(d[i+2]) << 16) | (Int(d[i+3]) << 24)
    }
    static func read(_ handle: FileHandle, _ count: Int) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw invalid }
        return data
    }
    static func algorithm(_ code: Int) -> compression_algorithm? {
        switch code {
        case 1: return COMPRESSION_LZFSE
        case 2: return COMPRESSION_ZLIB
        case 3: return COMPRESSION_LZMA
        default: return nil
        }
    }
    static func encode(_ data: Data, _ code: Int) -> Data? {
        guard let algorithm = algorithm(code), !data.isEmpty else { return nil }
        var output = Data(count: data.count)
        let capacity = output.count
        let n = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
            }
        }
        return n > 0 && n < data.count ? Data(output.prefix(n)) : nil
    }
    static func decode(_ data: Data, code: Int, size: Int) throws -> Data {
        if code == 0 {
            guard data.count == size else { throw invalid }
            return data
        }
        guard let algorithm = algorithm(code), !data.isEmpty, size > 0, size <= block else { throw invalid }
        var result = Data(count: size + 1)
        let capacity = result.count
        let n = result.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
            }
        }
        guard n == size else { throw invalid }
        return Data(result.prefix(size))
    }
    static var permitted: Bool {
        let info = ProcessInfo.processInfo
        return !info.isLowPowerModeEnabled && info.thermalState != .serious && info.thermalState != .critical
    }
    // The caller owns the unique staging output and keeps the original until
    // verification and installation succeed. Never keep a larger archive.
    static func pack(_ source: URL, into destination: URL, respectPower: Bool = true,
                     mode: Mode = .balanced, cancelled: () -> Bool = { false }) throws -> Bool {
        let length = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard length > 256, length <= maximum, !cancelled(), !respectPower || permitted else { return false }
        while !encoder.try() {
            guard !cancelled(), !respectPower || permitted else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { encoder.unlock() }
        guard !cancelled(), !respectPower || permitted else { return false }
        let count = (length + block - 1) / block
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw invalid }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var index = Data()
        var header = magic; header.append(number(length)); header.append(number(count))
        try output.write(contentsOf: header)
        try output.write(contentsOf: Data(count: count * entrySize))
        for i in 0..<count {
            guard !cancelled(), !respectPower || permitted else { return false }
            let raw = try read(input, min(block, length - i * block))
            var best = raw
            var method = 0
            for code in (mode == .fast ? [1] : [1, 2, 3]) {
                guard !cancelled(), !respectPower || permitted else { return false }
                // Avoid costly LZMA on clearly incompressible audio blocks,
                // but sample the first two even if the fast codecs found none.
                if mode == .balanced && code == 3 && i >= 2 && best.count > raw.count - raw.count / 100 { continue }
                if let candidate = encode(raw, code), candidate.count < best.count {
                    best = candidate; method = code
                }
            }
            // The disk read-back below checks every block against its original
            // and SHA256; a second decode here only doubles the work.
            index.append(number(best.count)); index.append(number(method))
            index.append(contentsOf: SHA256.hash(data: raw))
            try output.write(contentsOf: best)
            if respectPower && i % 8 == 7 { Thread.sleep(forTimeInterval: 0.005) }
        }
        let archived = try output.offset()
        guard archived < UInt64(length), UInt64(length) - archived >= UInt64(512) else { return false }
        try output.seek(toOffset: 12)
        try output.write(contentsOf: index)
        try output.synchronize()
        // Verify bytes read back from disk, not only the encoder output.
        let reader = try Reader(destination)
        try input.seek(toOffset: 0)
        for i in 0..<count {
            guard !cancelled(), !respectPower || permitted else { return false }
            let original = try read(input, min(block, length - i * block))
            guard try reader.chunk(i) == original else { throw invalid }
        }
        return true
    }

    // Statistics only need the 12-byte header. Playback still verifies the
    // full bounded index and each decoded block with SHA256.
    static func originalLength(_ url: URL) throws -> Int {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let header = try read(input, 12)
        guard header.prefix(4) == magic else { throw invalid }
        let length = integer(header, 4), count = integer(header, 8)
        guard length > 256, length <= maximum,
              count == (length + block - 1) / block,
              fileSize > UInt64(12 + count * entrySize) else { throw invalid }
        return length
    }

    final class Reader {
        private struct Entry { let offset: UInt64; let size: Int; let codec: Int; let digest: Data }
        let length: Int
        private let entries: [Entry]
        private let handle: FileHandle
        private var cached: [Int: Data] = [:]
        private var order: [Int] = []
        init(_ url: URL) throws {
            let input = try FileHandle(forReadingFrom: url)
            do {
                let fileSize = try input.seekToEnd()
                try input.seek(toOffset: 0)
                let header = try NWZ.read(input, 12)
                guard header.prefix(4) == NWZ.magic else { throw NWZ.invalid }
                let length = NWZ.integer(header, 4), count = NWZ.integer(header, 8)
                guard length > 256, length <= NWZ.maximum, count == (length + NWZ.block - 1) / NWZ.block else { throw NWZ.invalid }
                let index = try NWZ.read(input, count * NWZ.entrySize)
                var offset = UInt64(12 + index.count), entries: [Entry] = []
                for i in 0..<count {
                    let p = i * NWZ.entrySize
                    let size = NWZ.integer(index, p), code = NWZ.integer(index, p + 4)
                    let plain = min(NWZ.block, length - i * NWZ.block)
                    guard size > 0, size <= plain, (code == 0 && size == plain) ||
                            (NWZ.algorithm(code) != nil && size < plain),
                          offset + UInt64(size) <= fileSize else { throw NWZ.invalid }
                    entries.append(Entry(offset: offset, size: size, codec: code,
                                         digest: index.subdata(in: (p+8)..<(p+40))))
                    offset += UInt64(size)
                }
                guard offset == fileSize else { throw NWZ.invalid }
                self.length = length; self.entries = entries; self.handle = input
            } catch { try? input.close(); throw error }
        }
        deinit { try? handle.close() }
        // A reader belongs to a single serial queue; only four chunks stay hot.
        func chunk(_ i: Int) throws -> Data {
            guard entries.indices.contains(i) else { throw NWZ.invalid }
            if let hit = cached[i] { order.removeAll { $0 == i }; order.append(i); return hit }
            let e = entries[i]
            try handle.seek(toOffset: e.offset)
            let data = try NWZ.decode(NWZ.read(handle, e.size), code: e.codec,
                                      size: min(NWZ.block, length - i * NWZ.block))
            guard Data(SHA256.hash(data: data)) == e.digest else { throw NWZ.invalid }
            cached[i] = data; order.append(i)
            if order.count > 4 { cached.removeValue(forKey: order.removeFirst()) }
            return data
        }
        func range(_ offset: Int, count: Int) throws -> Data {
            guard offset >= 0, offset <= length, count >= 0, count <= length - offset else { throw NWZ.invalid }
            var cursor = offset, result = Data()
            while cursor < offset + count {
                let part = try chunk(cursor / NWZ.block), start = cursor % NWZ.block
                let n = min(part.count - start, offset + count - cursor)
                result.append(part.subdata(in: start..<(start+n))); cursor += n
            }
            return result
        }
    }

    // AVAudioFile has no resource-loader API. Only EQ and legacy envelope
    // analysis use this protected transient compatibility file, off the UI thread.
    static func compatibilityFile(_ url: URL, cancelled: () -> Bool = { false }) throws -> URL {
        let reader = try Reader(url)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("nwz-" + UUID().uuidString + ".m4a")
        guard FileManager.default.createFile(atPath: target.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw invalid }
        do {
            let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
            for i in 0..<((reader.length + block - 1) / block) {
                if cancelled() { throw URLError(.cancelled) }
                try output.write(contentsOf: reader.chunk(i))
            }
            return target
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
}

// AVFoundation asks for original M4A byte ranges, not a complete file.
// Delegate is retained by the asset; a serial queue owns its reader.
final class NWZResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static var association: UInt8 = 0
    private let file: URL
    private var reader: NWZ.Reader?
    private let queue = DispatchQueue(label: "fun.nightwell.nwz.reader", qos: .userInitiated)
    private init(_ file: URL) { self.file = file }
    static func compressed(_ url: URL) -> Bool { url.isFileURL && url.pathExtension == "nwz" }
    static func assetURL(_ url: URL) -> URL {
        guard compressed(url) else { return url }
        var parts = URLComponents()
        parts.scheme = "nightwell-nwz"; parts.host = "offline"
        parts.path = url.path + ".m4a"
        return parts.url ?? url
    }
    static func asset(_ url: URL, cookies: [HTTPCookie]) -> AVURLAsset {
        guard compressed(url) else { return AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies]) }
        let asset = AVURLAsset(url: assetURL(url))
        let loader = NWZResourceLoader(url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        objc_setAssociatedObject(asset, &association, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            if reader == nil { reader = try NWZ.Reader(file) }
            guard let reader else { throw NWZ.invalid }
            if let info = request.contentInformationRequest {
                info.contentType = UTType.mpeg4Audio.identifier
                info.contentLength = Int64(reader.length)
                info.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                let start = max(data.requestedOffset, data.currentOffset)
                guard start >= 0, start <= Int64(reader.length),
                      data.requestedOffset >= 0, data.requestedOffset <= Int64(reader.length),
                      data.requestedLength >= 0 else { throw NWZ.invalid }
                let end = data.requestsAllDataToEndOfResource ? reader.length :
                    Int(data.requestedOffset) + min(data.requestedLength, reader.length - Int(data.requestedOffset))
                var offset = Int(start)
                while offset < end {
                    if request.isCancelled { return true }
                    let n = min(NWZ.block, end - offset)
                    data.respond(with: try reader.range(offset, count: n)); offset += n
                }
            }
            request.finishLoading()
        } catch { if !request.isCancelled { request.finishLoading(with: error) } }
        return true
    }
}
