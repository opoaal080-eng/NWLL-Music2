import SwiftUI

// App-wide single-brand splash. The original Studio monogram is preserved.
struct NightwellStartupSplash: View {
    let brandOpacity: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Opaque background avoids showing the app before the intro.
                Color(red: 0.018, green: 0.020, blue: 0.026)

                RadialGradient(
                    colors: [
                        Color(red: 0.13, green: 0.15, blue: 0.18).opacity(0.55),
                        Color(red: 0.018, green: 0.020, blue: 0.026)
                    ],
                    center: .center,
                    startRadius: 5,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.72
                )

                studioBrand(width: geometry.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(brandOpacity)
                    .scaleEffect(CGFloat(0.975 + 0.025 * brandOpacity))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nightwell Studio")
    }

    private func studioBrand(width: CGFloat) -> some View {
        let markWidth = min(width * 0.79, 390)

        return VStack(spacing: 0) {
            NightwellStudioMark()
                .frame(width: markWidth, height: markWidth * 680 / 880)
                .accessibilityHidden(true)
                .padding(.bottom, 25)

            Text("NIGHTWELL")
                .font(.custom("AvenirNextCondensed-DemiBold", size: min(width * 0.093, 42)))
                .tracking(5.2)
                .foregroundStyle(Color.white.opacity(0.96))
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Text("STUDIO")
                .font(.custom("AvenirNext-Medium", size: min(width * 0.038, 17)))
                .tracking(10)
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.top, 10)
        }
        .padding(.horizontal, 22)
    }

}
// The studio monogram is traced from the supplied photograph, not an SF Symbol.
// Original contours are retained, while the photographed background, blooming
// highlights, glare, and display artefacts are replaced by clean metallic fills.
private struct NightwellStudioMark: View {
    var body: some View {
        Canvas { context, size in
            let transform = CGAffineTransform(scaleX: size.width / 880, y: size.height / 680)

            var rightPillar = Path()
            rightPillar.move(to: CGPoint(x: 586, y: 126))
            rightPillar.addLine(to: CGPoint(x: 707, y: 17))
            rightPillar.addLine(to: CGPoint(x: 707, y: 539))
            rightPillar.addLine(to: CGPoint(x: 586, y: 434))
            rightPillar.closeSubpath()
            context.fill(
                rightPillar.applying(transform),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.97, green: 0.98, blue: 0.99),
                        Color(red: 0.80, green: 0.83, blue: 0.86),
                        Color(red: 0.28, green: 0.32, blue: 0.37)
                    ]),
                    startPoint: CGPoint(x: size.width * 0.73, y: 0),
                    endPoint: CGPoint(x: size.width * 0.73, y: size.height * 0.90)
                )
            )

            var leftFoot = Path()
            leftFoot.move(to: CGPoint(x: 133, y: 413))
            leftFoot.addCurve(
                to: CGPoint(x: 258, y: 291),
                control1: CGPoint(x: 166, y: 359),
                control2: CGPoint(x: 215, y: 280)
            )
            leftFoot.addLine(to: CGPoint(x: 258, y: 539))
            leftFoot.addLine(to: CGPoint(x: 133, y: 648))
            leftFoot.closeSubpath()
            context.fill(
                leftFoot.applying(transform),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.58, green: 0.62, blue: 0.67),
                        Color(red: 0.88, green: 0.90, blue: 0.93),
                        Color.white
                    ]),
                    startPoint: CGPoint(x: size.width * 0.14, y: size.height * 0.40),
                    endPoint: CGPoint(x: size.width * 0.25, y: size.height)
                )
            )

            var flowingRibbon = Path()
            flowingRibbon.move(to: CGPoint(x: 9, y: 63))
            flowingRibbon.addCurve(
                to: CGPoint(x: 423, y: 260),
                control1: CGPoint(x: 179, y: 58),
                control2: CGPoint(x: 298, y: 111)
            )
            flowingRibbon.addCurve(
                to: CGPoint(x: 842, y: 651),
                control1: CGPoint(x: 576, y: 433),
                control2: CGPoint(x: 705, y: 608)
            )
            flowingRibbon.addCurve(
                to: CGPoint(x: 466, y: 493),
                control1: CGPoint(x: 653, y: 631),
                control2: CGPoint(x: 546, y: 557)
            )
            flowingRibbon.addCurve(
                to: CGPoint(x: 258, y: 291),
                control1: CGPoint(x: 369, y: 409),
                control2: CGPoint(x: 309, y: 317)
            )
            flowingRibbon.addCurve(
                to: CGPoint(x: 133, y: 413),
                control1: CGPoint(x: 215, y: 280),
                control2: CGPoint(x: 166, y: 359)
            )
            flowingRibbon.addLine(to: CGPoint(x: 133, y: 121))
            flowingRibbon.addCurve(
                to: CGPoint(x: 9, y: 63),
                control1: CGPoint(x: 98, y: 89),
                control2: CGPoint(x: 54, y: 72)
            )
            flowingRibbon.closeSubpath()
            context.fill(
                flowingRibbon.applying(transform),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.67, green: 0.72, blue: 0.78),
                        Color(red: 0.83, green: 0.87, blue: 0.90),
                        Color.white,
                        Color(red: 0.95, green: 0.97, blue: 0.98)
                    ]),
                    startPoint: CGPoint(x: size.width * 0.1, y: size.height * 0.03),
                    endPoint: CGPoint(x: size.width * 0.95, y: size.height)
                )
            )
        }
        .accessibilityHidden(true)
    }
}
