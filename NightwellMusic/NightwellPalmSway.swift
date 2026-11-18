import SwiftUI

/// Each image is a transparent palm group, separated from the original
/// Vice Nights artwork at build time. The backdrop below is clean sky.
struct NightwellPalmSwayBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let periods: [Double] = [6.4, 7.2, 8.3]
    private let amplitudes: [Double] = [3.0, -3.4, 2.8]
    private let anchors: [UnitPoint] = [
        UnitPoint(x: 0, y: .42),
        UnitPoint(x: 1, y: .20),
        UnitPoint(x: 1, y: .90)
    ]

    var body: some View {
        GeometryReader { geometry in
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 18.0,
                                        paused: scenePhase != .active)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let phase = seconds * 2.0 * Double.pi / periods[index]
                                        + Double(index) * 1.7
                            Image("ViceFronds\(index)")
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width,
                                       height: geometry.size.height)
                                .rotationEffect(
                                    .degrees(sin(phase) * amplitudes[index]),
                                    anchor: anchors[index]
                                )
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
