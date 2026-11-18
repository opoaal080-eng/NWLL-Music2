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
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                // Night-time coastal skyline: dark enough for readable controls,
                // with subtle pink / indigo neon rather than a flat magenta slab.
                LinearGradient(stops: [
                    .init(color: Color(red: 0.035, green: 0.028, blue: 0.085), location: 0),
                    .init(color: Color(red: 0.082, green: 0.045, blue: 0.16), location: 0.26),
                    .init(color: Color(red: 0.17, green: 0.055, blue: 0.20), location: 0.51),
                    .init(color: Color(red: 0.075, green: 0.045, blue: 0.14), location: 0.76),
                    .init(color: Color(red: 0.015, green: 0.014, blue: 0.035), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [
                    NightwellAppearance.pink.opacity(0.27),
                    Color(red: 0.30, green: 0.10, blue: 0.37).opacity(0.10),
                    .clear
                ], center: UnitPoint(x: 0.78, y: 0.54), startRadius: 6,
                   endRadius: max(w, h) * 0.65)
                RadialGradient(colors: [
                    NightwellAppearance.cyan.opacity(0.12), .clear
                ], center: UnitPoint(x: 0.08, y: 0.70), startRadius: 8,
                   endRadius: max(w, h) * 0.45)
                Ellipse()
                    .fill(NightwellAppearance.gold.opacity(0.21))
                    .frame(width: w * 0.62, height: max(35, h * 0.08))
                    .blur(radius: max(24, w * 0.11))
                    .position(x: w * 0.73, y: h * 0.63)
                ViceCoastalSkyline()
                    .fill(Color(red: 0.027, green: 0.022, blue: 0.070).opacity(0.65))
                Rectangle()
                    .fill(LinearGradient(colors: [
                        .clear,
                        NightwellAppearance.pink.opacity(0.20),
                        NightwellAppearance.gold.opacity(0.17),
                        .clear
                    ], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .position(x: w * 0.5, y: h * 0.75)
                    .blur(radius: 0.6)
                if palmTrees {
                    VicePalmSilhouette()
                        .stroke(Color(red: 0.025, green: 0.020, blue: 0.065).opacity(0.52),
                                style: StrokeStyle(lineWidth: 3.1, lineCap: .round))
                        .frame(width: w * 0.43, height: h * 0.60)
                        .position(x: w * 0.08, y: h * 0.83)
                        .blur(radius: 1.1)
                }
                LinearGradient(colors: [
                    .black.opacity(0.08), .clear, .black.opacity(0.06),
                    .black.opacity(0.40)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Distant, low-contrast silhouette, not a foreground illustration.
private struct ViceCoastalSkyline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let buildings: [(CGFloat, CGFloat, CGFloat)] = [
            (0.02, 0.015, 0.67), (0.05, 0.028, 0.72), (0.12, 0.020, 0.64),
            (0.16, 0.032, 0.70), (0.22, 0.015, 0.68), (0.27, 0.035, 0.73),
            (0.35, 0.020, 0.66), (0.40, 0.024, 0.69), (0.47, 0.018, 0.72),
            (0.54, 0.033, 0.70), (0.61, 0.017, 0.66), (0.67, 0.026, 0.71),
            (0.74, 0.024, 0.69), (0.80, 0.038, 0.74), (0.89, 0.016, 0.70),
            (0.94, 0.028, 0.67)
        ]
        for (x, width, top) in buildings {
            path.addRect(CGRect(x: rect.width * x, y: rect.height * top,
                                width: rect.width * width,
                                height: rect.height * (0.77 - top)))
        }
        return path
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
