import AVFoundation
import MediaToolbox

/// One PCM tap for the visualizer and optional Premium sound processing.
final class LocalAudioMeter {
    let equalizer = PremiumDSP()
    private let lock = NSLock()
    private var value = 0.0
    private var updated = 0.0
    private var format = AudioStreamBasicDescription()
    private var low = 0.0, dc = 0.0, sum = 0.0, bassSum = 0.0
    private var lowAlpha = 0.0, dcAlpha = 0.0
    private var levels = [Double](repeating: 0, count: 4)
    private var bandSums = [Double](repeating: 0, count: 4)
    private var midFilter = 0.0, highFilter = 0.0
    private var frames = 0, window = 2205
    private(set) var attached = false
    private var attachmentGeneration = UUID()

    func attach(to item: AVPlayerItem) {
        attachmentGeneration = UUID(); let generation = attachmentGeneration
        // A real audio track is required for the mix to target the playing audio.
        // Track ID 0 on iOS 27 does not reliably invoke the audio tap.
        Task {
            guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio),
                  let track = tracks.first else { return }
            await MainActor.run {
                guard self.attachmentGeneration == generation else { return }
                self.install(on: item, track: track)
            }
        }
    }
    func detach(from item: AVPlayerItem) {
        attachmentGeneration = UUID(); attached = false
        if item.audioMix != nil { item.audioMix = nil }
        lock.lock(); value = 0; updated = 0; lock.unlock()
    }
    private func install(on item: AVPlayerItem, track: AVAssetTrack?) {
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, client, storage in storage.pointee = client },
            finalize: { tap in Unmanaged<LocalAudioMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, description in
                let meter = Unmanaged<LocalAudioMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.configure(description.pointee)
            }, unprepare: { _ in },
            process: { tap, count, _, buffers, produced, flags in
                let status = MTAudioProcessingTapGetSourceAudio(tap, count, buffers, flags, nil, produced)
                guard status == noErr, produced.pointee > 0 else { return }
                let meter = Unmanaged<LocalAudioMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.consume(buffers, frames: Int(produced.pointee))
            })
        var result: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &result)
        guard status == noErr, let result = result?.takeRetainedValue() else {
            Unmanaged<LocalAudioMeter>.fromOpaque(callbacks.clientInfo!).release(); return
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = result
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        item.audioMix = mix; attached = true
    }

    private func configure(_ description: AudioStreamBasicDescription) {
        format = description
        let rate = max(1, description.mSampleRate)
        window = max(1, Int(rate / 20)); frames = 0; low = 0; dc = 0; sum = 0; bassSum = 0
        lowAlpha = 1 - exp(-2 * .pi * 220 / rate); dcAlpha = 1 - exp(-2 * .pi * 30 / rate)
    }
    private func consume(_ pointer: UnsafeMutablePointer<AudioBufferList>, frames count: Int) {
        guard format.mFormatID == kAudioFormatLinearPCM else { return }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(format.mBitsPerChannel), bytes = bits / 8
        guard (floating && bits == 32) || (!floating && bits == 16) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        equalizer.prepare(rate: format.mSampleRate, channels: Int(format.mChannelsPerFrame))
        for frame in 0..<count {
            var channelIndex = 0
            var mono = 0.0, power = 0.0, channels = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let n = Int(buffer.mNumberChannels)
                for channel in 0..<n {
                    let offset = (frame * n + channel) * bytes
                    guard offset + bytes <= Int(buffer.mDataByteSize) else { continue }
                    let raw = floating ? Double(data.load(fromByteOffset: offset, as: Float.self)) : Double(data.load(fromByteOffset: offset, as: Int16.self)) / 32768
                    let sample = equalizer.sample(raw.isFinite ? raw : 0, channel: channelIndex)
                    channelIndex += 1
                    if floating { data.storeBytes(of: Float(sample), toByteOffset: offset, as: Float.self) }
                    else { data.storeBytes(of: Int16(max(-32768, min(32767, Int(sample * 32768)))), toByteOffset: offset, as: Int16.self) }
                    mono += sample; power += sample * sample; channels += 1
                }
            }
            guard channels > 0 else { continue }
            mono /= Double(channels); power /= Double(channels)
            dc += dcAlpha * (mono - dc); low += lowAlpha * (mono - dc - low)
            midFilter += (1 - exp(-2 * .pi * 1500 / max(1, format.mSampleRate))) * (mono - midFilter)
            highFilter += (1 - exp(-2 * .pi * 4500 / max(1, format.mSampleRate))) * (mono - highFilter)
            let components = [midFilter - low * 0.5, low, midFilter - low, mono - highFilter]
            for i in 0..<4 { bandSums[i] += components[i] * components[i] }
            sum += power; bassSum += low * low; frames += 1
            if frames >= window {
                let level = min(1, sqrt(sum / Double(frames)) * 0.7 + sqrt(bassSum / Double(frames)) * 3.8)
                // Never block the audio callback while the UI reads the meter.
                if lock.try() { value = level; levels = bandSums.map { min(1, sqrt($0 / Double(max(1, frames))) * 5) }; updated = ProcessInfo.processInfo.systemUptime; lock.unlock() }
                frames = 0; sum = 0; bassSum = 0; bandSums = [0,0,0,0]
            }
        }
    }
    func frequencyLevels(playing: Bool) -> [Double] { lock.lock(); defer { lock.unlock() }; return playing && ProcessInfo.processInfo.systemUptime - updated < 2 ? levels : [0,0,0,0] }
    var processing: Bool {
        lock.lock(); defer { lock.unlock() }
        return updated > 0 && ProcessInfo.processInfo.systemUptime - updated < 2
    }
    func level(playing: Bool) -> Double {
        lock.lock(); defer { lock.unlock() }
        let age = ProcessInfo.processInfo.systemUptime - updated
        return playing && age < 1 ? value * exp(-max(0, age - 0.15) * 3) : 0
    }
}



