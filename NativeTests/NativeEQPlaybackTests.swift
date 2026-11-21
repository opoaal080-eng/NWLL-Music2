import XCTest
import AVFoundation
@testable import NightwellMusic

final class NativeEQPlaybackTests: XCTestCase {
    @MainActor
    func testPauseStopsRenderingAndResumeContinuesTheScheduledFile() async throws {
        let playback = NativeEQPlayback()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            playback.stop()
            try? FileManager.default.removeItem(at: fileURL)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        input.frameLength = 96000
        let samples = try XCTUnwrap(input.floatChannelData)
        for frame in 0..<96000 {
            // The louder segment proves resume reaches later file contents.
            let amplitude = frame < 24000 ? 0.02 : 0.1
            let sample = Float(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48000))
            samples[0][frame] = sample
            samples[1][frame] = sample
        }
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            try file.write(from: input)
        }
        try playback.load(fileURL, temporary: false, position: 0.25, playing: false)
        try playback.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        func renderSegment() throws -> Double {
            var frames = 0
            var energy = 0.0
            for _ in 0..<100 {
                if frames == 12000 { break }
                let status = try playback.engine.renderOffline(
                    AVAudioFrameCount(min(1024, 12000 - frames)), to: output)
                guard status == .success else { continue }
                let channel = try XCTUnwrap(output.floatChannelData)[0]
                for frame in 0..<Int(output.frameLength) {
                    energy += Double(channel[frame]) * Double(channel[frame])
                }
                frames += Int(output.frameLength)
            }
            XCTAssertEqual(frames, 12000, "The scheduled file must produce the complete audio segment")
            return sqrt(energy / Double(max(1, frames)))
        }
        try playback.play()
        let beforePause = try renderSegment()
        let pausedPosition = playback.position
        XCTAssertGreaterThan(pausedPosition, 0.45)
        XCTAssertGreaterThan(beforePause, 0.005)

        playback.pause()
        XCTAssertFalse(playback.engine.isRunning)
        XCTAssertFalse(playback.playing)
        XCTAssertTrue(playback.ready)
        XCTAssertEqual(playback.position, pausedPosition, accuracy: 1.0 / 48000)
        playback.pause()
        XCTAssertEqual(playback.position, pausedPosition, accuracy: 1.0 / 48000)

        try playback.play()
        XCTAssertTrue(playback.engine.isRunning)
        let afterResume = try renderSegment()
        XCTAssertGreaterThan(playback.position, pausedPosition + 0.2)
        XCTAssertGreaterThan(afterResume, beforePause * 3,
                             "Resume must continue into the louder segment instead of replaying earlier audio")

        playback.pause()
        try playback.seek(0.1, playing: false)
        XCTAssertEqual(playback.position, 0.1, accuracy: 1.0 / 48000)
        XCTAssertFalse(playback.engine.isRunning)
        try playback.rebuild(playing: false)
        XCTAssertEqual(playback.position, 0.1, accuracy: 1.0 / 48000)
        XCTAssertFalse(playback.playing)
        try playback.play()
        let afterPausedSeek = try renderSegment()
        XCTAssertGreaterThan(playback.position, 0.3)
        XCTAssertGreaterThan(afterPausedSeek, 0.005)
        XCTAssertLessThan(afterPausedSeek, afterResume / 3,
                          "A paused seek and rebuild must resume from the new quiet segment")
        playback.stop()
        XCTAssertFalse(playback.ready)
        XCTAssertEqual(playback.position, 0)
    }

    // Render the real AVAudioUnitEQ graph, not a duplicate filter implementation.
    private func render(_ frequency: Double, bands: [Double], expiry: Double, amplitude: Double = 0.1) throws -> (Double, Double, Double) {
        let playback = NativeEQPlayback()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        input.frameLength = 48000
        let samples = try XCTUnwrap(input.floatChannelData)
        for i in 0..<48000 {
            samples[0][i] = Float(amplitude * sin(2 * .pi * frequency * Double(i) / 48000))
            samples[1][i] = 0
        }
        let engine = playback.engine
        playback.connect(format: format)
        playback.set(bands, until: expiry)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        defer { playback.stop() }
        try engine.start()
        playback.node.scheduleBuffer(input)
        playback.node.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var sum = 0.0, silent = 0.0, peak = 0.0, count = 0, frames = 0
        for _ in 0..<100 {
            if frames >= 48000 { break }
            let status = try engine.renderOffline(AVAudioFrameCount(min(1024, 48000 - frames)), to: output)
            guard status == .success else { continue }
            let channels = try XCTUnwrap(output.floatChannelData)
            for i in 0..<Int(output.frameLength) where frames + i > 12000 {
                sum += Double(channels[0][i] * channels[0][i])
                XCTAssertTrue(channels[0][i].isFinite)
                peak = max(peak, abs(Double(channels[0][i])))
                silent = max(silent, abs(Double(channels[1][i])))
                count += 1
            }
            frames += Int(output.frameLength)
        }
        XCTAssertEqual(frames, 48000)
        return (sqrt(sum / Double(max(1, count))), silent, peak)
    }
    func testAudibleEngineBassResponseAndStereoIsolation() throws {
        let expiry = Date().timeIntervalSince1970 + 60
        let bass = try render(60, bands: [6,0,0,0,0], expiry: expiry)
        let mid = try render(1000, bands: [6,0,0,0,0], expiry: expiry)
        XCTAssertGreaterThan(bass.0, mid.0 * 1.7)
        XCTAssertLessThan(bass.1, 0.000001)
    }
    func testExpiryRestoresNeutralEngine() throws {
        let neutral = try render(1000, bands: [0,0,0,0,0], expiry: 0)
        let expired = try render(1000, bands: [6,6,6,6,6], expiry: 0)
        XCTAssertEqual(neutral.0, expired.0, accuracy: 0.000001)
        XCTAssertGreaterThan(neutral.0, 0.06)
    }
    func testEveryBandBoostsAndCutsItsOwnFrequency() throws {
        let expiry = Date().timeIntervalSince1970 + 60
        for (index, frequency) in [60.0,250,1000,4000,12000].enumerated() {
            let neutral = try render(frequency, bands: [0,0,0,0,0], expiry: expiry).0
            var bands = [0.0,0,0,0,0]
            bands[index] = 6
            let boosted = try render(frequency, bands: bands, expiry: expiry).0
            bands[index] = -6
            let cut = try render(frequency, bands: bands, expiry: expiry).0
            XCTAssertEqual(20 * log10(boosted / neutral), 6, accuracy: 0.6, "Boost at \(frequency) Hz")
            XCTAssertEqual(20 * log10(cut / neutral), -6, accuracy: 0.6, "Cut at \(frequency) Hz")
        }
    }
    func testBassBoostDoesNotTurnDownUnrelatedFrequencies() throws {
        let expiry = Date().timeIntervalSince1970 + 60
        let neutral = try render(1000, bands: [0,0,0,0,0], expiry: expiry).0
        let changed = try render(1000, bands: [6,0,0,0,0], expiry: expiry).0
        // Regression: the old global preamp turned down this unrelated tone by 6 dB.
        XCTAssertEqual(20 * log10(changed / neutral), 0, accuracy: 0.5)
    }
    func testLimiterContainsBoostedPeaks() throws {
        let output = try render(1000, bands: [6,6,6,6,6], expiry: Date().timeIntervalSince1970 + 60, amplitude: 0.9)
        print("Boosted limiter output RMS=\(output.0), peak=\(output.2)")
        XCTAssertLessThanOrEqual(output.2, 1.001)
        XCTAssertGreaterThan(output.0, 0.4)
    }
}
