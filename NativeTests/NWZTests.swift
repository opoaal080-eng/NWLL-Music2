import XCTest
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
        // Damage the final payload byte; decoding must fail, not return audio.
        let handle = try FileHandle(forUpdating: archive)
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end - 1)
        let byte = try NWZ.read(handle, 1)[0]
        try handle.seek(toOffset: end - 1)
        try handle.write(contentsOf: Data([byte ^ 0xff]))
        try handle.close()
        let broken = try NWZ.Reader(archive)
        XCTAssertThrowsError(try broken.chunk(2))
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
