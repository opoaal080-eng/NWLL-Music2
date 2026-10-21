import AVFoundation

enum AudioOutputPolicy {
    // Wireless routes use AVPlayer's unmodified output path. The visualizer is
    // optional and must not keep an audio-processing tap in that render chain.
    static func usesAudioTap(_ outputs: [AVAudioSession.Port]) -> Bool {
        guard !outputs.isEmpty else { return false }
        let wireless: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay]
        return !outputs.contains(where: wireless.contains)
    }
}
