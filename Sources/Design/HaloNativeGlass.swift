import SwiftUI

/// Applies Apple's Liquid Glass on supported systems and a plain system
/// material on the app's older deployment targets.
private struct HaloNativeGlassModifier<GlassShape: Shape>: ViewModifier {
    let tint: Color?
    let isInteractive: Bool
    let shape: GlassShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(nativeGlass, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    @available(iOS 26.0, *)
    private var nativeGlass: Glass {
        var glass = Glass.regular.interactive(isInteractive)
        if let tint {
            glass = glass.tint(tint)
        }
        return glass
    }
}

extension View {
    func haloNativeGlass<GlassShape: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: GlassShape
    ) -> some View {
        modifier(
            HaloNativeGlassModifier(
                tint: tint,
                isInteractive: interactive,
                shape: shape
            )
        )
    }
}
