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
    func openFindInteractiveGlassRoundedRectangle(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    @ViewBuilder
    func openFindSelectedGlassRoundedRectangle(
        cornerRadius: CGFloat,
        tintOpacity: Double = 0.08
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                // A selected row is an information state, not a primary CTA.
                // Keep the accent as a translucent tint so the row remains
                // legible over the panel's material instead of becoming a
                // solid system-blue block.
                .regular.tint(Color.accentColor.opacity(tintOpacity)).interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            background(.regularMaterial, in: RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(tintOpacity * 0.75))
            }
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
