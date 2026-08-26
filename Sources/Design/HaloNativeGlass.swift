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

enum HaloNativeGlassButtonProminence {
    case standard
    case prominent
}

/// Keeps buttons system-owned across deployment targets. Current releases use
/// Apple's Glass button styles while iOS 17-25 use the corresponding bordered
/// system styles.
private struct HaloNativeGlassButtonStyleModifier: ViewModifier {
    let prominence: HaloNativeGlassButtonProminence

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            switch prominence {
            case .standard:
                content.buttonStyle(.glass)
            case .prominent:
                content.buttonStyle(.glassProminent)
            }
        } else {
            switch prominence {
            case .standard:
                content.buttonStyle(.bordered)
            case .prominent:
                content.buttonStyle(.borderedProminent)
            }
        }
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

    func haloNativeGlassButtonStyle(
        _ prominence: HaloNativeGlassButtonProminence = .standard
    ) -> some View {
        modifier(HaloNativeGlassButtonStyleModifier(prominence: prominence))
    }
}
