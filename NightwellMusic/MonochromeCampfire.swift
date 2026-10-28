import SwiftUI

/// A monochrome campfire behind the mini-player, driven by decoded playback
/// frequency bands. The canvas never records sound or requests microphone access.
private struct CampfireEnergy {
    var bass = 0.0
    var middle = 0.0
    var treble = 0.0
    var beat = 0.0

    mutating func update(_ incoming: [Double], elapsed: Double) {
        let dt = min(0.1, max(0, elapsed.isFinite ? elapsed : 0))
        func band(_ index: Int) -> Double {
            guard incoming.indices.contains(index), incoming[index].isFinite else { return 0 }
            return min(1, max(0, incoming[index]))
        }
        // iOS aura spectrum order: voice, lows, mids, highs.
        let low = max(band(1), band(0) * 0.30)
        let mid = max(band(2), band(0) * 0.35)
        let high = band(3)
        let previousBass = bass
        func follow(_ value: inout Double, target: Double) {
            let tau = target > value ? 0.075 : 0.36
            value += (target - value) * (1 - exp(-dt / tau))
        }
        follow(&bass, target: low)
        follow(&middle, target: mid)
        follow(&treble, target: high)
        // A short-lived transient creates a flare, but steady bass still moves
        // the tongues. An audio silence must not generate fake beats.
        let attack = max(0, bass - previousBass)
        beat = max(beat * exp(-dt / 0.22), min(1, attack * 2.8))
    }
}

struct MonochromeCampfire: View {
    let playing: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var energy = CampfireEnergy()
    @State private var elapsed = 0.0

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            draw(context: context, size: size)
        }
        .task(id: scenePhase == .active && playing && !reduceMotion) { @MainActor in
            energy = CampfireEnergy()
            guard scenePhase == .active, playing, !reduceMotion else { return }
            var follower = CampfireEnergy()
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let dt = min(0.10, max(0, now - previous))
                previous = now
                follower.update(NativePlayer.shared.auraLevels(), elapsed: dt)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    energy = follower
                    elapsed += dt
                }
                do { try await Task.sleep(nanoseconds: 41_666_667) }
                catch { return }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func noise(_ value: Double) -> Double {
        let n = sin(value * 127.1 + 78.233) * 43758.5453
        return n - floor(n)
    }

    private func tongue(
        x: Double, base: Double, width: Double, height: Double,
        drift: Double, time: Double, seed: Double
    ) -> Path {
        // Uneven tapered sides and wandering tips make each tongue curl
        // independently, rather than scaling a fixed flame image.
        let sway = sin(time * 1.7 + seed * 3.1) * 0.19
                 + sin(time * 3.7 + seed * 0.9) * 0.08
        let tipX = x + drift + width * sway
        let tipY = base - height
        let curl = sin(time * 4.0 + seed * 2.4)
        var path = Path()
        path.move(to: CGPoint(x: x - width * 0.56, y: base + 3))
        path.addCurve(
            to: CGPoint(x: tipX - width * 0.20, y: tipY + height * 0.30),
            control1: CGPoint(x: x - width * 0.74, y: base - height * 0.23),
            control2: CGPoint(x: x - width * (0.08 + 0.15 * curl), y: tipY + height * 0.48)
        )
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: tipY),
            control: CGPoint(x: tipX - width * 0.35, y: tipY + height * 0.13)
        )
        path.addQuadCurve(
            to: CGPoint(x: tipX + width * 0.13, y: tipY + height * 0.29),
            control: CGPoint(x: tipX + width * 0.30, y: tipY + height * 0.08)
        )
        path.addCurve(
            to: CGPoint(x: x + width * 0.58, y: base + 3),
            control1: CGPoint(x: x + width * 0.46, y: base - height * 0.49),
            control2: CGPoint(x: x + width * 0.77, y: base - height * 0.22)
        )
        path.closeSubpath()
        return path
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let w = Double(size.width), h = Double(size.height)
        let time = reduceMotion || !playing ? 0 : elapsed
        let active = scenePhase == .active && playing && !reduceMotion
        let bass = active ? energy.bass : 0
        let middle = active ? energy.middle : 0
        let treble = active ? energy.treble : 0
        let beat = active ? energy.beat : 0
        let intensity = active ? 0.42 + bass * 0.43 + beat * 0.15 : 0.08
        let base = h * 0.98
        let center = CGPoint(x: w * 0.5, y: base - 12)

        // Low, wide bloom fades away before reaching the text at the top.
        let halo = CGRect(x: w * 0.08, y: base - h * 0.62, width: w * 0.84, height: h * 0.87)
        context.fill(Path(ellipseIn: halo), with: .radialGradient(
            Gradient(colors: [.white.opacity(intensity * 0.16), .white.opacity(intensity * 0.035), .clear]),
            center: center, startRadius: 0, endRadius: w * 0.48
        ))

        // Slow silver smoke wafts upwards with its own drift, not with beats.
        for index in 0..<9 {
            let seed = Double(index)
            let cycle = noise(seed * 9.2) + time * (0.10 + noise(seed * 8.2) * 0.08)
            let progress = cycle - floor(cycle)
            let px = w * (0.27 + noise(seed * 3.7) * 0.46)
                   + sin(time * 0.58 + seed * 2.1 + progress * 4) * w * 0.09
            let py = base - h * (0.16 + progress * 0.91)
            let radius = w * (0.075 + progress * 0.08)
            let smokeAlpha = intensity * (1 - progress) * 0.085
            let point = CGPoint(x: px, y: py)
            let oval = CGRect(x: px - radius, y: py - radius * 0.75,
                              width: radius * 2, height: radius * 1.5)
            context.fill(Path(ellipseIn: oval), with: .radialGradient(
                Gradient(colors: [.white.opacity(smokeAlpha), .clear]),
                center: point, startRadius: 0, endRadius: radius
            ))
        }

        // A campfire is made of multiple tongues with different height,
        // turbulence, life cycles and bend. Bass intensifies the height.
        for layer in 0..<2 {
            let count = layer == 0 ? 13 : 10
            for index in 0..<count {
                let seed = Double(index) + Double(layer) * 17.3
                let position = Double(index) / Double(max(1, count - 1))
                let x = w * (0.20 + position * 0.60)
                let pulse = sin(time * (2.2 + noise(seed * 7) * 2.7) + seed * 1.9)
                let flicker = sin(time * 6.1 + seed * 3.4) * 0.065
                let local = max(0.32, 0.70 + pulse * 0.17 + flicker)
                let height = h * (layer == 0 ? 0.37 : 0.30)
                           * (0.68 + noise(seed * 2.7) * 0.65)
                           * local * (0.82 + bass * 0.60 + beat * 0.28)
                let width = w * (layer == 0 ? 0.090 : 0.055)
                          * (0.70 + noise(seed * 8.3) * 0.65)
                let sway = sin(time * 1.4 + seed * 1.2) * w * 0.025
                let shape = tongue(x: x, base: base, width: width, height: height,
                                   drift: sway, time: time, seed: seed)
                let alpha = intensity * (layer == 0 ? 0.21 : 0.52)
                if layer == 0 && index.isMultiple(of: 3) {
                    var glow = context
                    glow.addFilter(.blur(radius: 10))
                    glow.fill(shape, with: .color(.white.opacity(alpha * 0.75)))
                }
                context.fill(shape, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(alpha), location: 0),
                        .init(color: .white.opacity(alpha * (layer == 0 ? 0.73 : 0.98)), location: 0.40),
                        .init(color: .white.opacity(alpha * 0.65), location: 0.76),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: CGPoint(x: x, y: base),
                    endPoint: CGPoint(x: x + sway, y: base - height)
                ))
            }
        }

        // Irregular embers, with velocity and brightness affected by treble.
        // Paused playback leaves only a dim, static ember bed.
        for index in 0..<36 {
            let seed = Double(index)
            let speed = 0.19 + noise(seed * 3.1) * 0.27 + treble * 0.10
            let cycle = noise(seed * 13.7) + time * speed
            let rise = cycle - floor(cycle)
            let origin = w * (0.26 + noise(seed * 5.5) * 0.48)
            let x = origin + sin(time * 1.5 + seed * 1.3 + rise * 5) * w * 0.065
            let y = base - h * rise * (0.67 + noise(seed * 4.8) * 0.33)
            let flicker = 0.55 + 0.45 * sin(time * 8 + seed * 1.7)
            let fade = min(1, rise * 8) * pow(1 - rise, 1.6)
            let alpha = (active ? (0.22 + treble * 0.33 + beat * 0.25) : 0.025)
                      * fade * flicker
            let radius = 0.65 + noise(seed * 2.6) * 1.4 + treble * 0.4
            let oval = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: oval), with: .color(.white.opacity(min(1, max(0, alpha)))))
        }

        // Hot ash below the translucent mini-player.
        let embers = CGRect(x: w * 0.19, y: base - 17, width: w * 0.62, height: 32)
        context.fill(Path(ellipseIn: embers), with: .radialGradient(
            Gradient(colors: [.white.opacity(intensity * 0.31), .clear]),
            center: CGPoint(x: w * 0.5, y: base), startRadius: 0, endRadius: w * 0.32
        ))
        _ = middle // kept separate for optional voice/mid-frequency accent
    }
}
