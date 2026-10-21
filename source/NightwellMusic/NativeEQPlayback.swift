import AVFoundation
import AudioToolbox

// Main-thread owner. The audible file is rendered through EQ on every route.
// AVPlayer remains the streaming fallback while the bounded export is prepared.
final class NativeEQPlayback {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let equalizer = AVAudioUnitEQ(numberOfBands: 5)
    let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0))
    private var file: AVAudioFile?
    private var temporary: URL?
    private var offset = 0.0
    private var scheduled = UUID()
    private var expiry = 0.0
    private var values = [Double](repeating: 0, count: 5)
    private var appliedBands: [Double] = []
    private var appliedRate = 0.0
    var onEnd: (() -> Void)?
    var ready: Bool { file != nil }
    var playing: Bool { node.isPlaying && engine.isRunning }
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }
    var position: Double {
        guard let file else { return offset }
        guard let time = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: time) else { return offset }
        return min(Double(file.length) / file.processingFormat.sampleRate,
                   offset + Double(playerTime.sampleTime) / playerTime.sampleRate)
    }
    init() {
        engine.attach(node)
        engine.attach(equalizer)
        engine.attach(limiter)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        // Use the unit's normal look-ahead window. A 1 ms attack overreacts
        // to a sustained, heavily boosted signal and audibly pumps its level.
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.012, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.024, 0)
    }
    func set(_ values: [Double], until: Double) {
        self.values = values.count == 5 ? values.map { $0.isFinite ? min(6, max(-6, $0)) : 0 } : [0,0,0,0,0]
        expiry = until
        apply()
    }
    func apply() {
        let bands = Date().timeIntervalSince1970 < expiry ? values : [0,0,0,0,0]
        let rate = file?.processingFormat.sampleRate ?? 44100
        guard bands != appliedBands || rate != appliedRate else { return }
        appliedBands = bands; appliedRate = rate
        for (index, frequency) in [60.0,250,1000,4000,12000].enumerated() {
            let band = equalizer.bands[index]
            band.filterType = .parametric
            band.frequency = Float(min(frequency, rate * 0.45))
            band.bandwidth = 2
            band.gain = Float(bands[index])
            band.bypass = false
        }
        // Frequency controls must not also turn down the whole track. Peaks
        // above full scale are handled after EQ by the limiter, only as needed.
        equalizer.globalGain = 0
    }
    func load(_ url: URL, temporary: Bool, position: Double, playing: Bool) throws {
        stop()
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0, input.processingFormat.sampleRate > 0 else { throw URLError(.cannotDecodeContentData) }
        file = input
        self.temporary = temporary ? url : nil
        connect(format: input.processingFormat)
        appliedBands = []
        apply()
        do { try seek(position, playing: playing) } catch { stop(); throw error }
    }
    func connect(format: AVAudioFormat) {
        engine.connect(node, to: equalizer, format: format)
        engine.connect(equalizer, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
    }
    func seek(_ seconds: Double, playing: Bool) throws {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let frame = min(file.length - 1, max(0, AVAudioFramePosition(max(0, seconds) * rate)))
        scheduled = UUID()
        let expected = scheduled
        node.stop()
        offset = Double(frame) / rate
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduled == expected else { return }
                self.onEnd?()
            }
        }
        if playing { try play() }
    }
    func play() throws {
        guard ready else { return }
        if !engine.isRunning { engine.prepare(); try engine.start() }
        node.play()
    }
    func pause() { node.pause() }
    func rebuild(playing: Bool) throws {
        let current = position
        engine.stop()
        try seek(current, playing: playing)
    }
    func stop() {
        scheduled = UUID()
        node.stop(); engine.stop(); file = nil; offset = 0
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
    }
}
