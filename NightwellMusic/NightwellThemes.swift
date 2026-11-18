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
    // Same tint across the full-player timeline and mini-player progress ring.
    var progressTint: Color { self == .vice ? Self.cyan : .white }
    static let pink = Color(red: 1.0, green: 0.19, blue: 0.66)
    static let cyan = Color(red: 0.14, green: 0.95, blue: 1.0)
    static let gold = Color(red: 1.0, green: 0.77, blue: 0.34)
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

/// A color-only Vice Nights background. No silhouettes, illustration, horizon
/// or visible geometric shapes. The palette follows the official GTA VI
/// sunset artwork (Rockstar Games /VI/media), without embedding their assets.
struct NightwellViceBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            let extent = max(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.085, green: 0.025, blue: 0.205), location: 0),
                        .init(color: Color(red: 0.225, green: 0.045, blue: 0.375), location: 0.30),
                        .init(color: Color(red: 0.345, green: 0.065, blue: 0.405), location: 0.54),
                        .init(color: Color(red: 0.145, green: 0.045, blue: 0.275), location: 0.80),
                        .init(color: Color(red: 0.035, green: 0.030, blue: 0.115), location: 1)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [
                        Color(red: 1.0, green: 0.22, blue: 0.55).opacity(0.52),
                        Color(red: 0.81, green: 0.15, blue: 0.54).opacity(0.27),
                        .clear
                    ],
                    center: UnitPoint(x: 0.93, y: 0.36),
                    startRadius: 0, endRadius: extent * 0.76
                )
                RadialGradient(
                    colors: [
                        Color(red: 1.0, green: 0.63, blue: 0.29).opacity(0.32),
                        Color(red: 1.0, green: 0.28, blue: 0.43).opacity(0.15),
                        .clear
                    ],
                    center: UnitPoint(x: 0.08, y: 0.43),
                    startRadius: 0, endRadius: extent * 0.52
                )
                RadialGradient(
                    colors: [
                        Color(red: 0.08, green: 0.62, blue: 0.98).opacity(0.42),
                        Color(red: 0.14, green: 0.30, blue: 0.84).opacity(0.23),
                        .clear
                    ],
                    center: UnitPoint(x: 0.12, y: 0.86),
                    startRadius: 0, endRadius: extent * 0.61
                )
                RadialGradient(
                    colors: [
                        Color(red: 0.18, green: 0.94, blue: 1.0).opacity(0.18),
                        .clear
                    ],
                    center: UnitPoint(x: 0.92, y: 0.95),
                    startRadius: 0, endRadius: extent * 0.38
                )
                LinearGradient(
                    colors: [.black.opacity(0.035), .clear,
                             .black.opacity(0.035), .black.opacity(0.19)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fixed sunset image for ordinary Vice Nights screens. The full player
/// keeps the existing color-only reactive artwork background.
struct NightwellViceScenicBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            Image("ViceSunset")
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.05), .clear, .black.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Preserve each screen's original standard background, share Vice Nights.
struct NightwellThemedBackground<Standard: View>: View {
    @Environment(\.nightwellAppearance) private var appearance
    @ViewBuilder let standard: () -> Standard
    var body: some View {
        Group {
            if appearance == .vice { NightwellViceBackdrop() }
            else { standard() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
private struct NightwellThemeChrome: ViewModifier {
    @Environment(\.nightwellAppearance) private var appearance
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.overlay {
            if appearance == .vice {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(
                        colors: [NightwellAppearance.pink.opacity(0.65), .clear,
                                 NightwellAppearance.cyan.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
extension View {
    func nightwellThemeChrome(_ radius: CGFloat) -> some View {
        modifier(NightwellThemeChrome(radius: radius))
    }
}

struct NightwellThemePreview: View {
    let appearance: NightwellAppearance
    var body: some View {
        ZStack {
            if appearance == .vice {
                NightwellViceBackdrop()
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
