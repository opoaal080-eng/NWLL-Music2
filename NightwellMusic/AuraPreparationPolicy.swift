import Foundation

// Retry transient export/decoding failures without repeatedly downloading every frame.
struct AuraPreparationPolicy {
    private(set) var attempts = 0
    private var retryAt = 0.0
    func canBegin(now: TimeInterval) -> Bool { attempts < 3 && now >= retryAt }
    mutating func begin(now: TimeInterval) -> Bool {
        guard canBegin(now: now) else { return false }
        attempts += 1
        return true
    }
    mutating func failed(now: TimeInterval) {
        retryAt = now + (attempts == 1 ? 5 : 20)
    }
}

// The export endpoint can return different audio containers. The decoder remains
// the final validator; HTML/JSON error bodies must never be treated as audio.
enum AuraAudioContainer {
    static func fileExtension(_ header: Data) -> String? {
        let bytes = Array(header)
        func tag(_ start: Int, _ length: Int) -> String {
            guard bytes.count >= start + length else { return "" }
            return String(bytes: bytes[start..<(start + length)], encoding: .ascii) ?? ""
        }
        if tag(4, 4) == "ftyp" { return "m4a" }
        if tag(0, 4) == "RIFF", tag(8, 4) == "WAVE" { return "wav" }
        if tag(0, 4) == "FORM", ["AIFF", "AIFC"].contains(tag(8, 4)) { return "aiff" }
        if tag(0, 4) == "caff" { return "caf" }
        if tag(0, 4) == "fLaC" { return "flac" }
        if tag(0, 3) == "ID3" { return "mp3" }
        if bytes.count >= 2, bytes[0] == 0xff {
            if bytes[1] & 0xf6 == 0xf0 { return "aac" }
            if bytes[1] & 0xe0 == 0xe0, bytes[1] & 0x06 != 0 { return "mp3" }
        }
        return nil
    }
}
