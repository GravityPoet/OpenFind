import SwiftUI

/// Uses Liquid Glass on macOS 26 while preserving the same geometry and a
/// native material hierarchy on the macOS 14 public-distribution baseline.
struct OpenFindGlassContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func openFindGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func openFindGlassRoundedRectangle(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func openFindGlassRectangle() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect)
        } else {
            background(.regularMaterial, in: Rectangle())
        }
    }
}
