import Foundation

@main struct AuraPreparationTests {
    static func main() {
        var policy = AuraPreparationPolicy()
        precondition(policy.begin(now: 0))
        policy.failed(now: 2)
        precondition(!policy.begin(now: 6.9))
        precondition(policy.begin(now: 7), "A failed track must be retried without switching tracks")
        policy.failed(now: 8)
        precondition(!policy.begin(now: 27.9))
        precondition(policy.begin(now: 28))
        policy.failed(now: 29)
        precondition(!policy.begin(now: 1000), "Repeated failures must not create an endless download loop")
        policy = AuraPreparationPolicy()
        precondition(policy.begin(now: 0), "A new track/resume starts a fresh attempt")
        let headers: [(Data, String)] = [
            (Data([0, 0, 0, 24]) + Data("ftypM4A ".utf8), "m4a"),
            (Data("RIFF1234WAVE".utf8), "wav"),
            (Data("FORM1234AIFF".utf8), "aiff"),
            (Data("caff12345678".utf8), "caf"),
            (Data("fLaC12345678".utf8), "flac"),
            (Data("ID3123456789".utf8), "mp3"),
            (Data([0xff, 0xfb, 0x90, 0]), "mp3"),
            (Data([0xff, 0xf1, 0x50, 0]), "aac")
        ]
        for (bytes, expected) in headers { precondition(AuraAudioContainer.fileExtension(bytes) == expected) }
        for bytes in [Data(), Data([0xff]), Data("<html>error".utf8), Data("{\"error\":1}".utf8), Data("RIFF1234AVI ".utf8)] {
            precondition(AuraAudioContainer.fileExtension(bytes) == nil)
        }
        print("Aura retries and audio container validation passed")
    }
}
