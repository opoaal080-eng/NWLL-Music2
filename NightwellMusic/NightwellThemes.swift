import SwiftUI

// An original neon-coast design inspired by the Miami night-life atmosphere.
// It contains no official Rockstar/GTA artwork, logos, or game resources.
enum NightwellAppearance: String, CaseIterable, Identifiable {
    case standard, vice
    static let storageKey = "nw-appearance-theme"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Стандартная"
        case .vice: "Vice Nights"
        }
    }
    var subtitle: String {
        switch self {
        case .standard: "Чёрно-белый Nightwell"
        case .vice: "Неон и закат в стиле GTA VI"
        }
    }
    var accent: Color { self == .vice ? Self.pink : .white }
    static let pink = Color(red: 1.0, green: 0.34, blue: 0.67)
    static let cyan = Color(red: 0.35, green: 0.89, blue: 0.96)
    static let gold = Color(red: 1.0, green: 0.70, blue: 0.44)
}

private struct NightwellAppearanceKey: EnvironmentKey {
    static let defaultValue: NightwellAppearance = .standard
}
extension EnvironmentValues {
    var nightwellAppearance: NightwellAppearance {
        get { self[NightwellAppearanceKey.self] }
        set { self[NightwellAppearanceKey.self] = newValue }
    }
}

struct NightwellViceBackdrop: View {
    var palmTrees = true
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack {
                LinearGradient(stops: [
                    .init(color: Color(red: 0.065, green: 0.040, blue: 0.15), location: 0),
                    .init(color: Color(red: 0.18, green: 0.055, blue: 0.28), location: 0.27),
                    .init(color: Color(red: 0.32, green: 0.062, blue: 0.25), location: 0.49),
                    .init(color: Color(red: 0.065, green: 0.038, blue: 0.13), location: 0.77),
                    .init(color: Color(red: 0.012, green: 0.010, blue: 0.035), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [NightwellAppearance.pink.opacity(0.45), .clear],
                               center: UnitPoint(x: 0.81, y: 0.43), startRadius: 8,
                               endRadius: max(w, h) * 0.65)
                RadialGradient(colors: [NightwellAppearance.cyan.opacity(0.17), .clear],
                               center: UnitPoint(x: 0.1, y: 0.75), startRadius: 8,
                               endRadius: max(w, h) * 0.58)
                Circle()
                    .fill(LinearGradient(colors: [NightwellAppearance.gold,
                                                  NightwellAppearance.pink,
                                                  NightwellAppearance.pink.opacity(0.10)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: min(w * 0.63, 260), height: min(w * 0.63, 260))
                    .opacity(0.33)
                    .position(x: w * 0.81, y: h * 0.43)
                if palmTrees {
                    VicePalmSilhouette()
                        .stroke(Color(red: 0.05, green: 0.015, blue: 0.095).opacity(0.66),
                                style: StrokeStyle(lineWidth: 4.3, lineCap: .round))
                        .frame(width: w * 0.53, height: h * 0.73)
                        .position(x: w * 0.12, y: h * 0.80)
                        .blur(radius: 0.6)
                }
                LinearGradient(colors: [.black.opacity(0.03), .black.opacity(0.09),
                                        .black.opacity(0.40)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct VicePalmSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let top = CGPoint(x: w * 0.64, y: h * 0.20)
        var path = Path()
        path.move(to: CGPoint(x: w * 0.30, y: h))
        path.addQuadCurve(to: top, control: CGPoint(x: w * 0.32, y: h * 0.44))
        let leaves: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-0.51, 0.21, -0.17, -0.04), (-0.63, 0.40, -0.48, 0.07),
            (-0.52, 0.57, -0.47, 0.31), (-0.18, 0.72, -0.36, 0.45),
            (0.02, -0.18, -0.05, -0.12), (0.33, -0.08, 0.17, -0.17),
            (0.69, 0.10, 0.50, -0.02), (0.78, 0.37, 0.63, 0.10),
            (0.57, 0.52, 0.60, 0.28)
        ]
        for (dx, dy, cx, cy) in leaves {
            path.move(to: top)
            path.addQuadCurve(to: CGPoint(x: top.x + dx * w, y: top.y + dy * h),
                              control: CGPoint(x: top.x + cx * w, y: top.y + cy * h))
        }
        return path
    }
}

struct NightwellThemePreview: View {
    let appearance: NightwellAppearance
    var body: some View {
        ZStack {
            if appearance == .vice {
                NightwellViceBackdrop(palmTrees: false)
            } else {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.04), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("N").font(.system(size: 28, weight: .black, design: .rounded))
                    Spacer()
                    Image(systemName: "waveform").foregroundStyle(
                        appearance == .vice ? NightwellAppearance.cyan : .white)
                }
                Spacer()
                Text(appearance == .vice ? "VICE NIGHTS" : "NIGHTWELL")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1.5)
                Capsule().fill(appearance.accent).frame(width: 44, height: 3)
            }
            .foregroundStyle(.white)
            .padding(13)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
