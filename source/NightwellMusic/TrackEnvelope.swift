import AVFoundation

// Decodes a file as data. It never creates a player, engine, audio session or tap.
struct TrackEnvelope: Codable {
    let framesPerSecond: Double
    let duration: Double
    let levels: [Float]

    var valid: Bool {
        framesPerSecond.isFinite && framesPerSecond > 0 && framesPerSecond <= 30 &&
        duration.isFinite && duration > 0 && duration <= 1800 && !levels.isEmpty &&
        levels.count <= 54001 && levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
    func level(at seconds: Double, playing: Bool) -> Double {
        guard playing, seconds.isFinite, seconds >= 0, seconds < duration, !levels.isEmpty else { return 0 }
        let position = seconds * framesPerSecond
        let index = min(levels.count - 1, Int(position))
        let next = min(levels.count - 1, index + 1)
        let fraction = position - floor(position)
        return Double(levels[index]) * (1 - fraction) + Double(levels[next]) * fraction
    }
    static func analyse(_ url: URL, cancelled: () -> Bool = { false }) throws -> TrackEnvelope {
        if cancelled() { throw CancellationError() }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat, rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        guard rate.isFinite, rate >= 8000, rate <= 192000,
              duration.isFinite, duration > 0, duration <= 1800,
              format.channelCount > 0, format.channelCount <= 8,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw URLError(.cannotDecodeContentData) }
        let window = max(1, Int((rate / 20).rounded()))
        let lowAlpha = 1 - exp(-2 * .pi * 220 / rate), dcAlpha = 1 - exp(-2 * .pi * 30 / rate)
        var low = 0.0, dc = 0.0, sum = 0.0, bassSum = 0.0, frames = 0
        var levels: [Float] = []
        levels.reserveCapacity(Int(duration * 21) + 1)
        func appendWindow() {
            guard frames > 0 else { return }
            levels.append(Float(min(1, sqrt(sum / Double(frames)) * 0.7 + sqrt(bassSum / Double(frames)) * 3.8)))
            sum = 0; bassSum = 0; frames = 0
        }
        while file.framePosition < file.length {
            if cancelled() { throw CancellationError() }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                var mono = 0.0, power = 0.0
                for channel in 0..<Int(format.channelCount) {
                    let raw = Double(channels[channel][frame]), sample = raw.isFinite ? raw : 0
                    mono += sample; power += sample * sample
                }
                mono /= Double(format.channelCount); power /= Double(format.channelCount)
                dc += dcAlpha * (mono - dc); low += lowAlpha * (mono - dc - low)
                sum += power; bassSum += low * low; frames += 1
                if frames == window { appendWindow() }
            }
        }
        appendWindow()
        if cancelled() { throw CancellationError() }
        let result = TrackEnvelope(framesPerSecond: rate / Double(window), duration: duration, levels: levels)
        guard result.valid else { throw URLError(.cannotDecodeContentData) }
        return result
    }
}
