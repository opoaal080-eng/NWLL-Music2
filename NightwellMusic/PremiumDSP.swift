import Foundation

// Peaking biquads, independent state per channel. Uses only the existing player's PCM tap.
final class PremiumDSP {
    private let lock = NSLock()
    private var requested = [Double](repeating: 0, count: 5)
    private var deadline = 0.0
    private var applied = [Double]()
    private var rate = 0.0
    private var coefficients = Array(repeating: [Double](repeating: 0, count: 5), count: 5)
    private var z1 = [[Double]](), z2 = [[Double]]()
    private var gain = 1.0
    func set(_ values: [Double], until: Double) {
        lock.lock(); requested = values.count == 5 ? values.map { $0.isFinite ? min(6, max(-6, $0)) : 0 } : [0,0,0,0,0]; deadline = until; lock.unlock()
    }
    func prepare(rate: Double, channels: Int) {
        lock.lock(); let values = Date().timeIntervalSince1970 < deadline ? requested : [0,0,0,0,0]; lock.unlock()
        guard rate > 0, channels > 0 else { return }
        guard values != applied || self.rate != rate || z1.count != channels else { return }
        applied = values; self.rate = rate
        gain = pow(10, -values.reduce(0) { $0 + max(0, $1) } / 20)
        for (i, frequency) in [60.0,250,1000,4000,12000].enumerated() {
            let a = pow(10, values[i] / 40), w = 2 * Double.pi * min(frequency, rate * 0.45) / rate
            let alpha = sin(w) / 2, c = cos(w), d = 1 + alpha / a
            coefficients[i] = [(1 + alpha*a)/d, -2*c/d, (1-alpha*a)/d, -2*c/d, (1-alpha/a)/d]
        }
        z1 = Array(repeating: [Double](repeating: 0, count: 5), count: channels); z2 = z1
    }
    func sample(_ input: Double, channel: Int) -> Double {
        guard channel < z1.count else { return input }
        var x = input * gain
        for i in 0..<5 { let c = coefficients[i]; let y = c[0]*x + z1[channel][i]; z1[channel][i] = c[1]*x - c[3]*y + z2[channel][i]; z2[channel][i] = c[2]*x - c[4]*y; x = y }
        return x.isFinite ? min(1, max(-1, x)) : 0
    }
}
