import SwiftUI

/// Match the native presentation's curved corners while retaining the existing inset.
struct NightwellSheetSurface: ViewModifier {
    let gradient: LinearGradient

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(ConcentricRectangle(corners: .concentric, isUniform: true))
                .background {
                    ConcentricRectangle(corners: .concentric, isUniform: true)
                        .fill(gradient)
                }
                .presentationBackground(gradient)
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
                RoundedRectangle(cornerRadius: 49, style: .continuous)
                    .fill(gradient)
                    .padding(-1)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .presentationBackground(.clear)
    }
}
