import XCTest
@testable import NightwellMusic
final class PremiumDSPTests: XCTestCase {
    func testNeutralAndStereoIsolation() {
        let eq = PremiumDSP(); eq.set([0,0,0,0,0], until: Date().timeIntervalSince1970 + 60); eq.prepare(rate: 48000, channels: 2)
        for i in 0..<10000 { let value = sin(Double(i) * 0.17) * 0.3; XCTAssertEqual(eq.sample(value, channel: 0), value, accuracy: 1e-9); XCTAssertEqual(eq.sample(0, channel: 1), 0, accuracy: 1e-12) }
    }
    func testBassResponseAndExpiryReset() {
        func rms(_ hz: Double) -> Double { let eq = PremiumDSP(); eq.set([6,0,0,0,0], until: Date().timeIntervalSince1970 + 60); eq.prepare(rate: 48000, channels: 1); var sum = 0.0
            for i in 0..<48000 { let value = eq.sample(0.1*sin(2 * .pi * hz * Double(i)/48000), channel: 0); if i > 24000 { sum += value * value } }; return sqrt(sum / 23999) }
        XCTAssertGreaterThan(rms(60), rms(1000)*1.7)
        let eq = PremiumDSP(); eq.set([6,6,6,6,6], until: 0); eq.prepare(rate: 44100, channels: 1); XCTAssertEqual(eq.sample(0.25, channel: 0), 0.25, accuracy: 1e-9)
    }
}
