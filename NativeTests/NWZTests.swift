import XCTest
import AVFoundation
import CryptoKit
import Compression
@testable import NightwellMusic

final class NWZTests: XCTestCase {
    private func legacyFixture(_ data: Data, to url: URL) throws {
        var header = NWZ.magic
        header.append(NWZ.number(data.count))
        let count = (data.count + NWZ.block - 1) / NWZ.block
        header.append(NWZ.number(count))
        var index = Data(), payload = Data()
        for i in 0..<count {
            let chunk = data.subdata(in: (i * NWZ.block)..<min(data.count, (i+1) * NWZ.block))
            var compressed = Data(count: chunk.count)
            let capacity = compressed.count
            let size = compressed.withUnsafeMutableBytes { dst in
                chunk.withUnsafeBytes { src in
                    compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, chunk.count, nil, COMPRESSION_LZFSE)
                }
            }
            let useCompressed = size > 0 && size < chunk.count
            let stored = useCompressed ? Data(compressed.prefix(size)) : chunk
            index.append(NWZ.number(stored.count))
            index.append(NWZ.number(useCompressed ? 1 : 0))
            index.append(contentsOf: SHA256.hash(data: chunk))
            payload.append(stored)
        }
        header.append(index); header.append(payload)
        try header.write(to: url)
    }
    func testRoundTripAndRandomRanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.m4a")
        let archive = directory.appendingPathComponent("source.nwz")
        let data = Data((0..<(NWZ.block * 2 + 123)).map { UInt8($0 % 19) })
        try data.write(to: input)
        try legacyFixture(data, to: archive)
        let reader = try NWZ.Reader(archive)
        XCTAssertEqual(try NWZ.originalLength(archive), data.count)
        XCTAssertEqual(reader.length, data.count)
        XCTAssertEqual(try reader.range(NWZ.block - 31, count: 600), data.subdata(in: (NWZ.block - 31)..<(NWZ.block + 569)))
        XCTAssertEqual(try reader.range(0, count: data.count), data)
        XCTAssertEqual(try reader.range(data.count, count: 0), Data())
        XCTAssertThrowsError(try reader.range(data.count, count: 1))
        let decoded = try NWZ.compatibilityFile(archive)
        defer { try? FileManager.default.removeItem(at: decoded) }
        XCTAssertEqual(try Data(contentsOf: decoded), data)
        // Damage the final chunk digest deterministically, even if a codec
        // ignores padding bits at the end of its compressed payload.
        let handle = try FileHandle(forUpdating: archive)
        let digestOffset = UInt64(12 + 2 * NWZ.entrySize + 8)
        try handle.seek(toOffset: digestOffset)
        let byte = try NWZ.read(handle, 1)[0]
        try handle.seek(toOffset: digestOffset)
        try handle.write(contentsOf: Data([byte ^ 0xff]))
        try handle.close()
        let broken = try NWZ.Reader(archive)
        XCTAssertThrowsError(try broken.chunk(2))
    }
    func testM4AAssetPlaybackThroughResourceLoader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("audio.m4a")
        let archive = directory.appendingPathComponent("audio.nwz")
        func makeAudio() throws {
            let file = try AVAudioFile(forWriting: source,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100))
            buffer.frameLength = 44100
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<44100 { channel[i] = Float(sin(Double(i) * 440 * 2 * .pi / 44100)) * 0.2 }
            try file.write(from: buffer)
        }
        try makeAudio()
        // Add a valid MP4 free atom to ensure the test fixture benefits from
        // archival compression irrespective of the AAC encoder implementation.
        let h = try FileHandle(forWritingTo: source)
        _ = try h.seekToEnd()
        try h.write(contentsOf: Data([0, 4, 0, 0, 102, 114, 101, 101]))
        try h.write(contentsOf: Data(count: 262144 - 8))
        try h.close()
        try legacyFixture(Data(contentsOf: source), to: archive)
        let asset = NWZResourceLoader.asset(archive, cookies: [])
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(output.copyNextSampleBuffer())
        reader.cancelReading()
    }
    func testInvalidHeader() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0xff, count: 128).write(to: file)
        XCTAssertThrowsError(try NWZ.Reader(file))
        XCTAssertThrowsError(try NWZ.originalLength(file))
    }
}
