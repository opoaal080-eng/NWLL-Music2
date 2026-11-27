import XCTest
import AVFoundation
@testable import NightwellMusic

final class NWZTests: XCTestCase {
    func testRoundTripAndRandomRanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.m4a")
        let archive = directory.appendingPathComponent("source.nwz")
        let data = Data((0..<(NWZ.block * 2 + 123)).map { UInt8($0 % 19) })
        try data.write(to: input)
        XCTAssertTrue(try NWZ.pack(input, into: archive, respectPower: false))
        let reader = try NWZ.Reader(archive)
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
        XCTAssertTrue(try NWZ.pack(source, into: archive, respectPower: false))
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
    func testAllCompressionModesAreLossless() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.m4a")
        let original = Data((0..<(NWZ.block + 123)).map { UInt8($0 % 251) })
        try original.write(to: input)
        for mode in NWZ.Mode.allCases {
            let target = root.appendingPathComponent(mode.rawValue + ".nwz")
            XCTAssertTrue(try NWZ.pack(input, into: target, respectPower: false, mode: mode))
            XCTAssertEqual(try NWZ.Reader(target).range(0, count: original.count), original)
        }
        let cancelled = root.appendingPathComponent("cancelled.nwz")
        XCTAssertFalse(try NWZ.pack(input, into: cancelled, respectPower: false, mode: .maximum, cancelled: { true }))
    }

    func testInvalidHeader() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0xff, count: 128).write(to: file)
        XCTAssertThrowsError(try NWZ.Reader(file))
    }
    func testIncompressibleFileIsNotInstalled() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = input.appendingPathExtension("nwz")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        var rng = SystemRandomNumberGenerator()
        let data = Data((0..<65536).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try data.write(to: input)
        XCTAssertFalse(try NWZ.pack(input, into: output, respectPower: false))
    }
}
