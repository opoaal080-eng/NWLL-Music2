import SwiftUI

/// Match the native presentation's curved corners while retaining the existing inset.
struct NightwellSheetSurface: ViewModifier {
    let gradient: LinearGradient
    @Environment(\.nightwellAppearance) private var appearance
    private var activeGradient: LinearGradient {
        appearance == .vice
            ? LinearGradient(colors: [Color(red: 0.10, green: 0.05, blue: 0.20),
                                      Color(red: 0.25, green: 0.09, blue: 0.28),
                                      Color(red: 0.025, green: 0.03, blue: 0.075)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : gradient
    }

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(ConcentricRectangle(corners: .concentric, isUniform: true))
                .background {
                    NightwellThemedBackground { gradient }
                        .clipShape(ConcentricRectangle(corners: .concentric, isUniform: true))
                }
                .presentationBackground(activeGradient)
                .tint(appearance.accent)
        } else {
            legacySurface(content)
        }
        #else
        legacySurface(content)
        #endif
    }

    private func legacySurface(_ content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
            .background {
                NightwellThemedBackground { gradient }
                    .clipShape(RoundedRectangle(cornerRadius: 49, style: .continuous))
                    .padding(-1)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .presentationBackground(.clear)
            .tint(appearance.accent)
    }
}
