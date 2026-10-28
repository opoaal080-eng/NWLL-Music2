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

    /// A pointed, irregular flame contour: narrow curling tip, broad shared
    /// root and asymmetrical turbulence on the two edges. The tip changes its
    /// direction as it rises so no tongue resembles a rigid oval or a candle.
    private func flamePath(
        x: Double, base: Double, width: Double, height: Double,
        lean: Double, seed: Double, time: Double
    ) -> Path {
        func center(_ p: Double) -> Double {
            let current = time * (1.05 + noise(seed * 2.9) * 0.55)
            let drift = sin(current + seed * 2.6 + p * 4.5) * width * 0.40
                      + sin(current * 0.61 - seed + p * 8.4) * width * 0.14
            // Lean becomes significant only near the end of the flame.
            let curlingTip = sin(current * 1.45 + seed * 4.1) * width * 1.10
            return x + lean * p * p + drift * p + curlingTip * pow(p, 3.1)
        }
        func radius(_ p: Double, side: Double) -> Double {
            let taper = pow(max(0, 1 - p), 0.64)
            let breathing = 0.80 + 0.13 * sin(time * 3.3 + seed * 2.1 - p * 13.0)
            let ragged = 1 + 0.12 * sin(p * 13.5 + seed * 3.1 - time * 2.2 + side)
                             + 0.08 * sin(p * 24.2 + seed - time * 3.6 + side * 2.0)
            // One side may fold inward while the other fans outward.
            let lobe = 1 + 0.20 * sin(p * 7.7 + seed * 1.6 + side * 1.8 - time)
            return max(0, width * taper * breathing * ragged * lobe)
        }
        let steps = 36
        var shape = Path()
        for step in 0...steps {
            let p = Double(step) / Double(steps)
            let point = CGPoint(x: center(p) - radius(p, side: -1),
                                y: base - height * p)
            if step == 0 { shape.move(to: point) }
            else { shape.addLine(to: point) }
        }
        for step in (0...steps).reversed() {
            let p = Double(step) / Double(steps)
            shape.addLine(to: CGPoint(x: center(p) + radius(p, side: 1),
                                      y: base - height * p))
        }
        shape.closeSubpath()
        return shape
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let w = Double(size.width)
        let h = Double(size.height)
        let active = scenePhase == .active && playing && !reduceMotion
        let time = active ? elapsed : 0
        let bass = active ? energy.bass : 0
        let mids = active ? energy.middle : 0
        let treble = active ? energy.treble : 0
        let beat = active ? energy.beat : 0

        // Real fire always retains a narrow common root. The music changes
        // its turbulence and height, rather than moving an entire silhouette.
        let heat = active ? (0.54 + bass * 0.34 + mids * 0.08 + beat * 0.10) : 0.045
        let heightGain = active ? (0.84 + bass * 0.43 + beat * 0.25) : 0.13
        let base = h * 0.98
        let centerX = w * 0.5
        let hearth = CGPoint(x: centerX, y: base - 10)

        // Soft glow behind the translucent mini-player, not a bright disc.
        context.fill(Path(ellipseIn: CGRect(
            x: centerX - w * 0.41, y: base - h * 0.39,
            width: w * 0.82, height: h * 0.50
        )), with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(heat * 0.21), location: 0),
                .init(color: .white.opacity(heat * 0.075), location: 0.32),
                .init(color: .clear, location: 1)
            ]),
            center: hearth, startRadius: 0, endRadius: w * 0.43
        ))

        if active {
            // The broad backlight and core JOIN the tongues into ONE fire,
            // preventing a row of identical vertical sticks.
            let root = flamePath(
                x: centerX, base: base,
                width: w * 0.242, height: h * 0.42 * heightGain,
                lean: sin(time * 0.7) * w * 0.025,
                seed: 46.0, time: time
            )
            var soft = context
            soft.addFilter(.blur(radius: 19))
            soft.fill(root, with: .color(.white.opacity(heat * 0.21)))
            context.fill(root, with: .linearGradient(
                Gradient(colors: [.white.opacity(heat * 0.26),
                                  .white.opacity(heat * 0.19),
                                  .white.opacity(heat * 0.015)]),
                startPoint: hearth,
                endPoint: CGPoint(x: centerX, y: base - h * 0.48 * heightGain)
            ))

            // Broad tongues arc away from a common base. Differing lifetimes,
            // curls and local oscillations make their movement unpredictable.
            for index in 0..<8 {
                let seed = Double(index) + 8.4
                let distribution = (Double(index) / 7 - 0.5)
                let birthX = centerX + w * distribution * 0.34
                let highAtCenter = 1 - abs(distribution) * 0.6
                let pulse = 0.82
                          + sin(time * (1.65 + noise(seed * 5.1) * 1.4) + seed * 2.7) * 0.17
                          + sin(time * 4.2 + seed * 1.3) * 0.055
                let extent = h * (0.42 + noise(seed * 6.3) * 0.22)
                           * highAtCenter * pulse * heightGain
                let width = w * (0.106 + noise(seed * 2.7) * 0.054)
                let lean = w * (distribution * 0.26 + (noise(seed * 12) - 0.5) * 0.12)
                let flame = flamePath(x: birthX, base: base, width: width,
                                      height: extent, lean: lean, seed: seed, time: time)
                let alpha = heat * (0.34 + noise(seed * 3.2) * 0.13)
                context.fill(flame, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(alpha), location: 0),
                        .init(color: .white.opacity(alpha * 0.95), location: 0.30),
                        .init(color: .white.opacity(alpha * 0.64), location: 0.64),
                        .init(color: .white.opacity(alpha * 0.15), location: 0.95)
                    ]),
                    startPoint: CGPoint(x: birthX, y: base),
                    endPoint: CGPoint(x: birthX + lean, y: base - extent)
                ))
            }

            // Narrow, luminous internal flames suggest hot gases curling
            // through openings in the larger silhouette, not extra pillars.
            for index in 0..<6 {
                let seed = Double(index) + 71.0
                let p = (Double(index) / 5 - 0.5)
                let x = centerX + w * p * 0.19
                let pulse = 0.76 + 0.15 * sin(time * (2.2 + noise(seed) * 1.8) + seed)
                let extent = h * (0.26 + noise(seed * 4.2) * 0.16)
                           * pulse * heightGain
                let flame = flamePath(
                    x: x, base: base, width: w * (0.067 + noise(seed * 8) * 0.028),
                    height: extent, lean: w * p * 0.06,
                    seed: seed, time: time * 1.15
                )
                let alpha = heat * (0.47 + noise(seed * 3.3) * 0.19)
                context.fill(flame, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(alpha * 1.08), location: 0),
                        .init(color: .white.opacity(alpha), location: 0.36),
                        .init(color: .white.opacity(alpha * 0.39), location: 0.79),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: CGPoint(x: x, y: base),
                    endPoint: CGPoint(x: x, y: base - extent)
                ))
            }

            // Thin, curling silver wisps: smoke is slow and semi-transparent.
            for index in 0..<7 {
                let seed = Double(index)
                let lifetime = 2.9 + noise(seed * 11) * 2.0
                let progress = (time / lifetime + noise(seed * 7.3))
                                    .truncatingRemainder(dividingBy: 1)
                let x = centerX + (noise(seed * 3.7) - 0.5) * w * 0.28
                        + sin(time * 0.55 + seed * 2.0 + progress * 4) * w * 0.08
                let y = base - h * (0.22 + progress * 0.93)
                let radius = 9 + 14 * progress
                context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius * 0.7,
                                                     width: radius * 2, height: radius * 1.4)),
                    with: .radialGradient(
                        Gradient(colors: [.white.opacity(heat * 0.075 * (1 - progress)), .clear]),
                        center: CGPoint(x: x, y: y),
                        startRadius: 0, endRadius: radius
                    ))
            }
        }

        // Tiny upward embers have distinct birth positions, velocities,
        // sideways drag and finite lives. Highs and drum hits raise their
        // brightness and rate without spawning at identical intervals.
        let sparkCount = active ? 58 : 12
        for index in 0..<sparkCount {
            let seed = Double(index) + 0.37
            let rate = 0.22 + noise(seed * 3.1) * 0.27
                       + treble * 0.17 + beat * 0.08
            let cycle = noise(seed * 9.9) + time * rate
            let progress = cycle - floor(cycle)
            let spread = noise(seed * 8.1) - 0.5
            let x = centerX + spread * w * 0.44
                  + sin(time * 1.12 + seed * 2.2 + progress * 3.4) * w * 0.038
                  + progress * progress * spread * w * 0.16
            let y = base - progress * h * (0.55 + noise(seed * 1.8) * 0.62)
            let opacity = heat * (0.35 + treble * 0.36 + beat * 0.30)
                        * min(1, progress * 12) * pow(1 - progress, 1.7)
                        * (0.68 + 0.32 * sin(time * 7.5 + seed))
            let radius = 0.55 + noise(seed * 4.7) * 1.30
            let ember = Path(ellipseIn: CGRect(
                x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
            ))
            context.fill(ember, with: .color(.white.opacity(min(1, max(0, opacity)))))
            if index.isMultiple(of: 5) && active {
                var blurred = context
                blurred.addFilter(.blur(radius: 3))
                blurred.fill(ember, with: .color(.white.opacity(opacity * 0.5)))
                var tail = Path()
                tail.move(to: CGPoint(x: x, y: y))
                tail.addLine(to: CGPoint(x: x - spread * 4, y: y + 2 + radius * 2.0))
                context.stroke(tail, with: .color(.white.opacity(opacity * 0.36)),
                               style: StrokeStyle(lineWidth: 0.65, lineCap: .round))
            }
        }

        // A few crossed charcoal logs keep the base reading as a campfire.
        // Their top is hidden naturally behind the translucent mini-player.
        for direction in [-1.0, 1.0] {
            var log = Path()
            log.move(to: CGPoint(x: centerX - w * 0.17, y: base - (direction > 0 ? 4 : 18)))
            log.addLine(to: CGPoint(x: centerX + w * 0.17, y: base - (direction > 0 ? 18 : 4)))
            context.stroke(log, with: .color(Color(white: 0.26).opacity(0.46)),
                           style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.stroke(log, with: .color(.white.opacity(heat * 0.16)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        context.fill(Path(ellipseIn: CGRect(
            x: centerX - w * 0.22, y: base - 20, width: w * 0.44, height: 27
        )), with: .radialGradient(
            Gradient(colors: [.white.opacity(heat * 0.32), .clear]),
            center: CGPoint(x: centerX, y: base - 5),
            startRadius: 0, endRadius: w * 0.24
        ))
    }
}
