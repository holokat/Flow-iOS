import Foundation
import NostrSDK
import SwiftUI
import UIKit
import UserNotifications

enum AppThemeOption: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case system
    case black
    case white
    case sakura
    case dracula
    case gamer
    case holographicLight
    case holographicDark
    case dark
    case light

    var id: String { rawValue }

    static let onboardingOptions: [AppThemeOption] = [
        .holographicLight,
        .black,
        .system,
        .dracula,
        .gamer,
        .dark
    ]

    static let appearanceOptions: [AppThemeOption] = [
        .holographicLight,
        .black,
        .system,
        .dracula,
        .gamer,
        .dark,
        .light
    ]

    var normalizedSelection: AppThemeOption {
        switch self {
        case .white, .sakura:
            return .light
        case .holographicDark:
            return .dark
        case .system, .black, .dracula, .gamer, .holographicLight, .dark, .light:
            return self
        }
    }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .black:
            return "Dark"
        case .white:
            return "Clean"
        case .sakura:
            return "Clean"
        case .dracula:
            return "Midnight"
        case .gamer:
            return "Neon"
        case .holographicLight:
            return "Light"
        case .holographicDark:
            return "Charcoal"
        case .dark:
            return "Charcoal"
        case .light:
            return "Clean"
        }
    }

    var iconName: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .black:
            return "moon.fill"
        case .white:
            return "sun.haze.fill"
        case .sakura:
            return "sun.haze.fill"
        case .dracula:
            return "moon.stars.fill"
        case .gamer:
            return "gamecontroller.fill"
        case .holographicLight, .holographicDark:
            return "sparkles"
        case .dark:
            return "moon.stars.fill"
        case .light:
            return "sun.haze.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return "Switches between Light and Dark"
        case .black:
            return "Pure black appearance"
        case .white:
            return "Classic bright appearance"
        case .sakura:
            return "Classic bright appearance"
        case .dracula:
            return "Deep shadows with cool violet surfaces"
        case .gamer:
            return "Carbon black with electric cyan surfaces"
        case .holographicLight:
            return "Bright surfaces with soft sky chrome"
        case .holographicDark:
            return "Soft graphite contrast"
        case .dark:
            return "Soft graphite contrast"
        case .light:
            return "Classic bright appearance"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .system, .black, .dracula, .gamer, .holographicLight, .dark, .light:
            return true
        case .white, .sakura, .holographicDark:
            return false
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .black, .dark, .dracula, .gamer, .holographicDark:
            return .dark
        case .white, .light, .sakura, .holographicLight:
            return .light
        }
    }

    var fixedPrimaryColor: Color? {
        nil
    }

    var fixedPrimaryGradient: LinearGradient? {
        nil
    }

    var qrShareBackgroundResourceName: String? {
        switch self {
        case .system, .black, .white, .sakura, .dracula, .gamer, .holographicLight, .holographicDark, .dark, .light:
            return nil
        }
    }

    var palette: AppThemePalette {
        switch self {
        case .system:
            return AppThemePalette.system
        case .black:
            return AppThemePalette.black
        case .white:
            return AppThemePalette.white
        case .sakura:
            return AppThemePalette.white
        case .dracula:
            return AppThemePalette.dracula
        case .gamer:
            return AppThemePalette.gamer
        case .holographicLight:
            return AppThemePalette.holographicLight
        case .holographicDark:
            return AppThemePalette.dark
        case .dark:
            return AppThemePalette.dark
        case .light:
            return AppThemePalette.white
        }
    }

    var usesDarkGradientTreatment: Bool {
        switch normalizedSelection {
        case .black, .dark, .dracula, .gamer:
            return true
        case .system, .white, .sakura, .holographicLight, .holographicDark, .light:
            return false
        }
    }
}

struct AppPrimaryColorOption: Identifiable, Hashable, Sendable {
    let hexCode: String

    var id: String { hexCode }

    var color: Color {
        Self.color(from: hexCode)
    }

    static let all: [AppPrimaryColorOption] = [
        AppPrimaryColorOption(hexCode: "FF0000"),
        AppPrimaryColorOption(hexCode: "0059FF"),
        AppPrimaryColorOption(hexCode: "FF5900"),
        AppPrimaryColorOption(hexCode: "91C500"),
        AppPrimaryColorOption(hexCode: "00D4FF"),
        AppPrimaryColorOption(hexCode: "D000FF"),
        AppPrimaryColorOption(hexCode: "9000FF")
    ]

    static let defaultOption = AppPrimaryColorOption(hexCode: "0059FF")

    static func random() -> AppPrimaryColorOption {
        all.randomElement() ?? defaultOption
    }

    static func nearest(to color: Color) -> AppPrimaryColorOption {
        let source = rgbaComponents(for: color)
        return all.min { lhs, rhs in
            distanceSquared(from: source, to: rgbaComponents(for: lhs.color))
                < distanceSquared(from: source, to: rgbaComponents(for: rhs.color))
        } ?? defaultOption
    }

    private static func color(from hexCode: String) -> Color {
        let value = UInt32(hexCode, radix: 16) ?? 0
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    private static func rgbaComponents(for color: Color) -> (Double, Double, Double, Double) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return (0, 0, 0, 1)
        }
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    private static func distanceSquared(
        from lhs: (Double, Double, Double, Double),
        to rhs: (Double, Double, Double, Double)
    ) -> Double {
        let red = lhs.0 - rhs.0
        let green = lhs.1 - rhs.1
        let blue = lhs.2 - rhs.2
        let alpha = lhs.3 - rhs.3
        return (red * red) + (green * green) + (blue * blue) + (alpha * alpha)
    }
}

enum HolographicGradientOption: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case softHolographicSheen
    case iridescentPastelFilm
    case holographicChromeLook
    case neonHolographicBlend
    case pearlHolographicGradient
    case strongRainbowFoil
    case multiLayerHolographicFoil
    case radialHolographicGlow

    struct AccentPalette {
        let primary: Color
        let secondary: Color
        let tertiary: Color
        let shadow: Color
    }

    enum PreviewEffect {
        case none
        case sheen
        case radialGlow
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .softHolographicSheen:
            return "Soft holographic sheen"
        case .iridescentPastelFilm:
            return "Iridescent pastel film"
        case .holographicChromeLook:
            return "Holographic chrome look"
        case .neonHolographicBlend:
            return "Neon holographic blend"
        case .pearlHolographicGradient:
            return "Pearl holographic gradient"
        case .strongRainbowFoil:
            return "Strong rainbow foil"
        case .multiLayerHolographicFoil:
            return "Multi-layer holographic foil"
        case .radialHolographicGlow:
            return "Radial holographic glow"
        }
    }

    var previewEffect: PreviewEffect {
        switch self {
        case .multiLayerHolographicFoil:
            return .sheen
        case .radialHolographicGlow:
            return .radialGlow
        case .softHolographicSheen,
             .iridescentPastelFilm,
             .holographicChromeLook,
             .neonHolographicBlend,
             .pearlHolographicGradient,
             .strongRainbowFoil:
            return .none
        }
    }

    var buttonGradient: LinearGradient {
        LinearGradient(
            stops: buttonStops,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var uiGradient: LinearGradient {
        LinearGradient(
            stops: uiStops,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func borderColor(for theme: AppThemeOption) -> Color {
        switch self {
        case .softHolographicSheen:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(154, 178, 224, 0.26)
                : Self.rgba(122, 138, 170, 0.26)
        case .iridescentPastelFilm:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(186, 191, 214, 0.24)
                : Self.rgba(151, 157, 179, 0.22)
        case .holographicChromeLook:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(180, 175, 167, 0.24)
                : Self.rgba(142, 139, 134, 0.24)
        case .neonHolographicBlend:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(131, 162, 208, 0.28)
                : Self.rgba(96, 122, 162, 0.26)
        case .pearlHolographicGradient:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(196, 196, 206, 0.22)
                : Self.rgba(161, 162, 174, 0.20)
        case .strongRainbowFoil:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(166, 154, 190, 0.28)
                : Self.rgba(125, 117, 150, 0.26)
        case .multiLayerHolographicFoil:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(162, 176, 196, 0.26)
                : Self.rgba(124, 137, 157, 0.24)
        case .radialHolographicGlow:
            return theme.usesDarkGradientTreatment
                ? Self.rgba(155, 177, 206, 0.24)
                : Self.rgba(118, 136, 164, 0.22)
        }
    }

    func accentPalette(for theme: AppThemeOption) -> AccentPalette {
        switch self {
        case .softHolographicSheen:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0x8B7DFF),
                    secondary: Self.hex(0xFF8FCF),
                    tertiary: Self.hex(0x6FD6FF),
                    shadow: Self.hex(0xFF8FCF)
                )
            }
            return AccentPalette(
                primary: Self.hex(0x6FD6FF),
                secondary: Self.hex(0x8B7DFF),
                tertiary: Self.hex(0x8FE3B0),
                shadow: Self.hex(0xFF8FCF)
            )
        case .iridescentPastelFilm:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0xF6DCFB),
                    secondary: Self.hex(0xD9D6FF),
                    tertiary: Self.hex(0xE2EDFF),
                    shadow: Self.hex(0xF6DCFB)
                )
            }
            return AccentPalette(
                primary: Self.hex(0xE2EDFF),
                secondary: Self.hex(0xF6DCFB),
                tertiary: Self.hex(0xEEF7D8),
                shadow: Self.hex(0xD9D6FF)
            )
        case .holographicChromeLook:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0xD8D4EE),
                    secondary: Self.hex(0xF4B5B2),
                    tertiary: Self.hex(0xC8ECB2),
                    shadow: Self.hex(0xF0D9A2)
                )
            }
            return AccentPalette(
                primary: Self.hex(0xF4B5B2),
                secondary: Self.hex(0xD8D4EE),
                tertiary: Self.hex(0xC8ECB2),
                shadow: Self.hex(0xF0D9A2)
            )
        case .neonHolographicBlend:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0x5D6BFF),
                    secondary: Self.hex(0xFF56C8),
                    tertiary: Self.hex(0x47D8FF),
                    shadow: Self.hex(0xFF56C8)
                )
            }
            return AccentPalette(
                primary: Self.hex(0x47D8FF),
                secondary: Self.hex(0x5D6BFF),
                tertiary: Self.hex(0x57EFB7),
                shadow: Self.hex(0xFF56C8)
            )
        case .pearlHolographicGradient:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0xF3EBFF),
                    secondary: Self.hex(0xE2EFFF),
                    tertiary: Self.hex(0xFFF2DA),
                    shadow: Self.hex(0xF3EBFF)
                )
            }
            return AccentPalette(
                primary: Self.hex(0xE2EFFF),
                secondary: Self.hex(0xF3EBFF),
                tertiary: Self.hex(0xECF8DF),
                shadow: Self.hex(0xF3EBFF)
            )
        case .strongRainbowFoil:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0xD97CFF),
                    secondary: Self.hex(0x69A6FF),
                    tertiary: Self.hex(0xFF5D72),
                    shadow: Self.hex(0xD97CFF)
                )
            }
            return AccentPalette(
                primary: Self.hex(0x69A6FF),
                secondary: Self.hex(0xD97CFF),
                tertiary: Self.hex(0x57DCB5),
                shadow: Self.hex(0xFF5D72)
            )
        case .multiLayerHolographicFoil:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0xD59CFF),
                    secondary: Self.hex(0xFF94DC),
                    tertiary: Self.hex(0x7FDFFF),
                    shadow: Self.hex(0xFF94DC)
                )
            }
            return AccentPalette(
                primary: Self.hex(0x7FDFFF),
                secondary: Self.hex(0xD59CFF),
                tertiary: Self.hex(0x8BE8C3),
                shadow: Self.hex(0xFF94DC)
            )
        case .radialHolographicGlow:
            if theme.usesDarkGradientTreatment {
                return AccentPalette(
                    primary: Self.hex(0x7CA7FF),
                    secondary: Self.hex(0xF0B7EC),
                    tertiary: Self.hex(0xABF0CD),
                    shadow: Self.hex(0xF0B7EC)
                )
            }
            return AccentPalette(
                primary: Self.hex(0x7CA7FF),
                secondary: Self.hex(0xF0B7EC),
                tertiary: Self.hex(0xABF0CD),
                shadow: Self.hex(0xF0B7EC)
            )
        }
    }

    var defaultLinkColor: Color {
        switch self {
        case .softHolographicSheen:
            return Self.hex(0xFF6EC4)
        case .iridescentPastelFilm:
            return Self.hex(0xC76BFF)
        case .holographicChromeLook:
            return Self.hex(0xF97376)
        case .neonHolographicBlend:
            return Self.hex(0xFF00CC)
        case .pearlHolographicGradient:
            return Self.hex(0x8B5CF6)
        case .strongRainbowFoil:
            return Self.hex(0xFF4FD8)
        case .multiLayerHolographicFoil:
            return Self.hex(0xC77DFF)
        case .radialHolographicGlow:
            return Self.hex(0x5B8CFF)
        }
    }

    private var buttonStops: [Gradient.Stop] {
        switch self {
        case .softHolographicSheen:
            return [
                Self.stop(0xFF6EC4, 0.00),
                Self.stop(0x7873F5, 0.20),
                Self.stop(0x4ADEFF, 0.40),
                Self.stop(0x7CF29C, 0.60),
                Self.stop(0xFFF275, 0.80),
                Self.stop(0xFF8FAB, 1.00)
            ]
        case .iridescentPastelFilm:
            return [
                Self.stop(0xFDFBFB, 0.00),
                Self.stop(0xEBEDEE, 0.08),
                Self.stop(0xD6EAFF, 0.22),
                Self.stop(0xFFD6F6, 0.38),
                Self.stop(0xD8FFD6, 0.55),
                Self.stop(0xFFF0C2, 0.72),
                Self.stop(0xD9D6FF, 0.88),
                Self.stop(0xFFFFFF, 1.00)
            ]
        case .holographicChromeLook:
            return [
                Self.stop(0xCFD9DF, 0.00),
                Self.stop(0xE2EBF0, 0.12),
                Self.stop(0xF6D365, 0.24),
                Self.stop(0xFDA085, 0.36),
                Self.stop(0xC3CFE2, 0.48),
                Self.stop(0xFBC2EB, 0.62),
                Self.stop(0xA1C4FD, 0.78),
                Self.stop(0xD4FC79, 1.00)
            ]
        case .neonHolographicBlend:
            return [
                Self.stop(0xFF00CC, 0.00),
                Self.stop(0x3333FF, 0.18),
                Self.stop(0x00E5FF, 0.36),
                Self.stop(0x00FF99, 0.54),
                Self.stop(0xFFEE00, 0.72),
                Self.stop(0xFF4D6D, 1.00)
            ]
        case .pearlHolographicGradient:
            return [
                Self.stop(0xFFFFFF, 0.00),
                Self.stop(0xF3E8FF, 0.18),
                Self.stop(0xDBEAFE, 0.34),
                Self.stop(0xDCFCE7, 0.50),
                Self.stop(0xFEF3C7, 0.68),
                Self.stop(0xFDE2E4, 0.84),
                Self.stop(0xFFFFFF, 1.00)
            ]
        case .strongRainbowFoil:
            return [
                Self.stop(0xFF003C, 0.00),
                Self.stop(0xFF8A00, 0.16),
                Self.stop(0xFFE600, 0.32),
                Self.stop(0x00D084, 0.48),
                Self.stop(0x00C2FF, 0.64),
                Self.stop(0x7A5CFF, 0.82),
                Self.stop(0xFF4FD8, 1.00)
            ]
        case .multiLayerHolographicFoil:
            return [
                Self.stop(0xFF7AD9, 0.00),
                Self.stop(0x7AFCFF, 0.20),
                Self.stop(0x7AFFB3, 0.40),
                Self.stop(0xFFF47A, 0.60),
                Self.stop(0xC77DFF, 0.80),
                Self.stop(0xFF7A7A, 1.00)
            ]
        case .radialHolographicGlow:
            return [
                Self.stop(0x5B8CFF, 0.00),
                Self.stop(0x9BFFB0, 0.25),
                Self.stop(0xFFF3A3, 0.50),
                Self.stop(0xFFB3E6, 0.75),
                Self.stop(0xBFA6FF, 1.00)
            ]
        }
    }

    private var uiStops: [Gradient.Stop] {
        switch self {
        case .softHolographicSheen:
            return [
                Self.stop(0xFF8FCF, 0.00),
                Self.stop(0x8B7DFF, 0.28),
                Self.stop(0x6FD6FF, 0.58),
                Self.stop(0x8FE3B0, 0.78),
                Self.stop(0xFFD7A3, 1.00)
            ]
        case .iridescentPastelFilm:
            return [
                Self.stop(0xFBF7FF, 0.00),
                Self.stop(0xE2EDFF, 0.30),
                Self.stop(0xF6DCFB, 0.58),
                Self.stop(0xEEF7D8, 0.82),
                Self.stop(0xFFF8E2, 1.00)
            ]
        case .holographicChromeLook:
            return [
                Self.stop(0xDBE3E8, 0.00),
                Self.stop(0xF0D9A2, 0.32),
                Self.stop(0xF4B5B2, 0.58),
                Self.stop(0xD8D4EE, 0.82),
                Self.stop(0xC8ECB2, 1.00)
            ]
        case .neonHolographicBlend:
            return [
                Self.stop(0xFF56C8, 0.00),
                Self.stop(0x5D6BFF, 0.30),
                Self.stop(0x47D8FF, 0.58),
                Self.stop(0x57EFB7, 0.82),
                Self.stop(0xFFD36E, 1.00)
            ]
        case .pearlHolographicGradient:
            return [
                Self.stop(0xFFFEFE, 0.00),
                Self.stop(0xF3EBFF, 0.30),
                Self.stop(0xE2EFFF, 0.56),
                Self.stop(0xECF8DF, 0.80),
                Self.stop(0xFFF2DA, 1.00)
            ]
        case .strongRainbowFoil:
            return [
                Self.stop(0xFF5D72, 0.00),
                Self.stop(0xFFB14F, 0.24),
                Self.stop(0xFFE27A, 0.46),
                Self.stop(0x57DCB5, 0.68),
                Self.stop(0x69A6FF, 0.86),
                Self.stop(0xD97CFF, 1.00)
            ]
        case .multiLayerHolographicFoil:
            return [
                Self.stop(0xFF94DC, 0.00),
                Self.stop(0x7FDFFF, 0.30),
                Self.stop(0x8BE8C3, 0.58),
                Self.stop(0xF7E38C, 0.80),
                Self.stop(0xD59CFF, 1.00)
            ]
        case .radialHolographicGlow:
            return [
                Self.stop(0x7CA7FF, 0.00),
                Self.stop(0xABF0CD, 0.34),
                Self.stop(0xFFF0A8, 0.66),
                Self.stop(0xF0B7EC, 1.00)
            ]
        }
    }

    private static func stop(_ hex: Int, _ location: Double) -> Gradient.Stop {
        Gradient.Stop(color: self.hex(hex), location: location)
    }

    private static func hex(_ value: Int, opacity: Double = 1) -> Color {
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue).opacity(opacity)
    }

    private static func rgba(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> Color {
        Color(red: red / 255.0, green: green / 255.0, blue: blue / 255.0).opacity(alpha)
    }
}

enum AppVisualAccentMode: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case expressive
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expressive:
            return "Expressive"
        case .minimal:
            return "Minimal"
        }
    }

    var subtitle: String {
        switch self {
        case .expressive:
            return "Gradient buttons with an extracted link color"
        case .minimal:
            return "One primary color for buttons and links"
        }
    }
}

enum ExpressiveGradientOption: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case aurora
    case prism
    case ember
    case bloom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora:
            return "Aurora"
        case .prism:
            return "Prism"
        case .ember:
            return "Ember"
        case .bloom:
            return "Bloom"
        }
    }

    var legacyHolographicOption: HolographicGradientOption {
        switch self {
        case .aurora:
            return .softHolographicSheen
        case .prism:
            return .neonHolographicBlend
        case .ember:
            return .holographicChromeLook
        case .bloom:
            return .radialHolographicGlow
        }
    }

    var buttonGradient: LinearGradient {
        legacyHolographicOption.buttonGradient
    }

    var uiGradient: LinearGradient {
        legacyHolographicOption.uiGradient
    }

    var buttonTextColor: Color {
        switch self {
        case .aurora, .prism:
            return .white
        case .ember, .bloom:
            return .black
        }
    }

    var linkColors: [Color] {
        switch self {
        case .aurora:
            return [
                Self.hex(0xFF6EC4),
                Self.hex(0x7873F5),
                Self.hex(0x18A8D8),
                Self.hex(0x2F9D55)
            ]
        case .prism:
            return [
                Self.hex(0xFF00CC),
                Self.hex(0x3333FF),
                Self.hex(0x008C99),
                Self.hex(0xD94F00)
            ]
        case .ember:
            return [
                Self.hex(0xD14B3D),
                Self.hex(0xA56800),
                Self.hex(0x6C63B8),
                Self.hex(0x408238)
            ]
        case .bloom:
            return [
                Self.hex(0x5B8CFF),
                Self.hex(0xC45DAE),
                Self.hex(0x2A9F66),
                Self.hex(0x8B63D8)
            ]
        }
    }

    func linkColor(at index: Int) -> Color {
        let colors = linkColors
        guard !colors.isEmpty else { return legacyHolographicOption.defaultLinkColor }
        let normalizedIndex = Self.normalizedLinkColorIndex(index, count: colors.count)
        return colors[normalizedIndex]
    }

    static func mapped(from option: HolographicGradientOption) -> ExpressiveGradientOption {
        switch option {
        case .softHolographicSheen, .iridescentPastelFilm, .pearlHolographicGradient:
            return .aurora
        case .neonHolographicBlend, .strongRainbowFoil, .multiLayerHolographicFoil:
            return .prism
        case .holographicChromeLook:
            return .ember
        case .radialHolographicGlow:
            return .bloom
        }
    }

    static func normalizedLinkColorIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    private static func hex(_ value: Int) -> Color {
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}

struct StoredColor: Codable, Hashable, Sendable {
    let archivedData: Data

    init(color: Color) {
        let uiColor = UIColor(color)
        archivedData = (try? NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: true)) ?? Data()
    }

    var color: Color {
        color(fallback: AppSettingsStore.defaultPrimaryColor)
    }

    func color(fallback: Color) -> Color {
        guard !archivedData.isEmpty,
              let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: archivedData) else {
            return fallback
        }
        return Color(uiColor)
    }
}

struct GeneratedButtonGradient: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let colors: [StoredColor]

    init(id: UUID = UUID(), colors: [Color]) {
        self.id = id
        self.colors = Array(colors.prefix(3)).map(StoredColor.init(color:))
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var gradientColors: [Color] {
        let decodedColors = colors.map(\.color)
        if decodedColors.count >= 2 {
            return Array(decodedColors.prefix(3))
        }
        return [
            AppSettingsStore.defaultPrimaryColor,
            AppSettingsStore.defaultPrimaryColor
        ]
    }

    static func random() -> GeneratedButtonGradient {
        let palette = GradientPalette.allCases.randomElement() ?? .iridescent
        let colors = palette.makeColors()
        return GeneratedButtonGradient(colors: colors)
    }

    static func randomHolographic() -> GeneratedButtonGradient {
        let recipe = HolographicRecipe.allCases.randomElement() ?? .prism
        return GeneratedButtonGradient(colors: recipe.makeColors())
    }

    private enum GradientPalette: CaseIterable {
        case iridescent
        case neon
        case pearl
        case dusk
        case tropic
        case chrome
        case auric

        func makeColors() -> [Color] {
            let count = Int.random(in: 2...3)
            let baseHue = Double.random(in: 0...1)

            return (0..<count).map { index in
                let offset = hueOffset(for: index, count: count)
                let hue = (baseHue + offset).truncatingRemainder(dividingBy: 1)
                return color(hue: hue)
            }
        }

        private func hueOffset(for index: Int, count: Int) -> Double {
            let denominator = Double(max(count, 1))
            switch self {
            case .iridescent:
                return Double(index) * Double.random(in: 0.16...0.26)
            case .neon:
                return Double(index) * Double.random(in: 0.18...0.30)
            case .pearl:
                return Double(index) / denominator * Double.random(in: 0.10...0.18)
            case .dusk:
                return Double(index) / denominator * Double.random(in: 0.08...0.22)
            case .tropic:
                return Double(index) / denominator * Double.random(in: 0.20...0.34)
            case .chrome:
                return Double(index) / denominator * Double.random(in: 0.12...0.20)
            case .auric:
                return Double(index) / denominator * Double.random(in: 0.04...0.15)
            }
        }

        private func color(hue: Double) -> Color {
            switch self {
            case .iridescent:
                return Color(
                    hue: hue,
                    saturation: Double.random(in: 0.30...0.58),
                    brightness: Double.random(in: 0.86...1.00)
                )
            case .neon:
                return Color(
                    hue: hue,
                    saturation: Double.random(in: 0.74...0.98),
                    brightness: Double.random(in: 0.82...1.00)
                )
            case .pearl:
                return Color(
                    hue: hue,
                    saturation: Double.random(in: 0.14...0.34),
                    brightness: Double.random(in: 0.92...1.00)
                )
            case .dusk:
                return Color(
                    hue: hue,
                    saturation: Double.random(in: 0.42...0.70),
                    brightness: Double.random(in: 0.56...0.80)
                )
            case .tropic:
                return Color(
                    hue: hue,
                    saturation: Double.random(in: 0.56...0.84),
                    brightness: Double.random(in: 0.76...0.96)
                )
            case .chrome:
                return Color(
                    hue: hue,
                    saturation: Double.random(in: 0.22...0.42),
                    brightness: Double.random(in: 0.74...0.94)
                )
            case .auric:
                return Color(
                    hue: hue,
                    saturation: Double.random(in: 0.34...0.62),
                    brightness: Double.random(in: 0.88...0.99)
                )
            }
        }
    }

    private enum HolographicRecipe: CaseIterable {
        case prism
        case opal
        case aurora
        case pearlFoil
        case candySheen
        case chromeMist
        case polarBloom
        case ultraviolet

        func makeColors() -> [Color] {
            let baseHue = Double.random(in: 0...1)
            return colorStops.map { stop in
                Color(
                    hue: normalizedHue(baseHue + stop.hueOffset),
                    saturation: Double.random(in: stop.saturationRange),
                    brightness: Double.random(in: stop.brightnessRange)
                )
            }
        }

        private var colorStops: [HolographicColorStop] {
            switch self {
            case .prism:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.36...0.58, brightnessRange: 0.92...1.00),
                    .init(hueOffset: 0.17, saturationRange: 0.46...0.72, brightnessRange: 0.86...0.98),
                    .init(hueOffset: 0.31, saturationRange: 0.34...0.56, brightnessRange: 0.92...1.00)
                ]
            case .opal:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.20...0.34, brightnessRange: 0.96...1.00),
                    .init(hueOffset: 0.11, saturationRange: 0.30...0.44, brightnessRange: 0.90...1.00),
                    .init(hueOffset: 0.24, saturationRange: 0.24...0.38, brightnessRange: 0.94...1.00)
                ]
            case .aurora:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.34...0.56, brightnessRange: 0.90...1.00),
                    .init(hueOffset: 0.20, saturationRange: 0.44...0.70, brightnessRange: 0.84...0.98),
                    .init(hueOffset: 0.40, saturationRange: 0.28...0.52, brightnessRange: 0.88...1.00)
                ]
            case .pearlFoil:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.16...0.28, brightnessRange: 0.97...1.00),
                    .init(hueOffset: 0.14, saturationRange: 0.24...0.38, brightnessRange: 0.92...1.00),
                    .init(hueOffset: 0.28, saturationRange: 0.20...0.34, brightnessRange: 0.95...1.00)
                ]
            case .candySheen:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.48...0.72, brightnessRange: 0.90...1.00),
                    .init(hueOffset: 0.16, saturationRange: 0.40...0.68, brightnessRange: 0.88...0.98),
                    .init(hueOffset: 0.32, saturationRange: 0.34...0.60, brightnessRange: 0.92...1.00)
                ]
            case .chromeMist:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.22...0.36, brightnessRange: 0.92...1.00),
                    .init(hueOffset: 0.09, saturationRange: 0.18...0.30, brightnessRange: 0.86...0.96),
                    .init(hueOffset: 0.22, saturationRange: 0.24...0.40, brightnessRange: 0.92...1.00)
                ]
            case .polarBloom:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.26...0.44, brightnessRange: 0.94...1.00),
                    .init(hueOffset: 0.13, saturationRange: 0.30...0.50, brightnessRange: 0.90...1.00),
                    .init(hueOffset: 0.26, saturationRange: 0.22...0.40, brightnessRange: 0.95...1.00)
                ]
            case .ultraviolet:
                return [
                    .init(hueOffset: 0.00, saturationRange: 0.38...0.60, brightnessRange: 0.90...1.00),
                    .init(hueOffset: 0.12, saturationRange: 0.46...0.72, brightnessRange: 0.84...0.96),
                    .init(hueOffset: 0.25, saturationRange: 0.34...0.56, brightnessRange: 0.92...1.00)
                ]
            }
        }

        private func normalizedHue(_ hue: Double) -> Double {
            let wrapped = hue.truncatingRemainder(dividingBy: 1)
            return wrapped >= 0 ? wrapped : wrapped + 1
        }
    }

    private struct HolographicColorStop {
        let hueOffset: Double
        let saturationRange: ClosedRange<Double>
        let brightnessRange: ClosedRange<Double>
    }
}

enum AppFontSize: Int, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case small
    case medium
    case large
    case extraLarge

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small:
            return "Small"
        case .medium:
            return "Default"
        case .large:
            return "Large"
        case .extraLarge:
            return "XL"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small:
            return .small
        case .medium:
            return .medium
        case .large:
            return .large
        case .extraLarge:
            return .xLarge
        }
    }
}

enum BreakReminderInterval: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case off
    case twentyMinutes
    case fortyMinutes
    case oneHour
    case twoHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .twentyMinutes:
            return "20 Minutes"
        case .fortyMinutes:
            return "40 Minutes"
        case .oneHour:
            return "1 Hour"
        case .twoHours:
            return "2 Hours"
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .off:
            return nil
        case .twentyMinutes:
            return 20 * 60
        case .fortyMinutes:
            return 40 * 60
        case .oneHour:
            return 60 * 60
        case .twoHours:
            return 2 * 60 * 60
        }
    }
}

struct CustomFeedDefinition: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var iconSystemName: String
    var hashtags: [String]
    var authorPubkeys: [String]
    var phrases: [String]

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        iconSystemName: String = CustomFeedIconCatalog.defaultIcon,
        hashtags: [String] = [],
        authorPubkeys: [String] = [],
        phrases: [String] = []
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.hashtags = hashtags
        self.authorPubkeys = authorPubkeys
        self.phrases = phrases
    }

    var hasSources: Bool {
        !hashtags.isEmpty || !authorPubkeys.isEmpty || !phrases.isEmpty
    }

    var cacheSignature: String {
        [
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            iconSystemName.lowercased(),
            hashtags.joined(separator: ","),
            authorPubkeys.joined(separator: ","),
            phrases.map { $0.lowercased() }.joined(separator: ",")
        ].joined(separator: "|")
    }
}

enum CustomFeedIconCatalog {
    static let defaultIcon = "square.stack.3d.up.fill"

    static let availableIcons: [String] = [
        "square.stack.3d.up.fill",
        "magnifyingglass",
        "newspaper.fill",
        "sparkles",
        "bolt.fill",
        "waveform.path.ecg",
        "soccerball",
        "trophy.fill",
        "figure.run",
        "globe.americas.fill",
        "chart.line.uptrend.xyaxis",
        "music.note",
        "headphones",
        "mic.fill",
        "film.fill",
        "camera.fill",
        "gamecontroller.fill",
        "leaf.fill",
        "flame.fill",
        "moon.stars.fill",
        "sun.max.fill",
        "flag.fill",
        "bird.fill",
        "book.fill",
        "heart.text.square.fill",
        "person.3.fill"
    ]

    static func normalizedIcon(_ iconSystemName: String?) -> String {
        guard let iconSystemName, availableIcons.contains(iconSystemName) else {
            return defaultIcon
        }
        return iconSystemName
    }

    static func randomIconName() -> String {
        availableIcons.randomElement() ?? defaultIcon
    }
}

enum AppSettingsError: LocalizedError {
    case invalidNewsRelayURL
    case newsRelayRequired
    case invalidNewsAuthorIdentifier
    case invalidNewsHashtag
    case invalidCustomFeedName
    case customFeedRequiresContent

    var errorDescription: String? {
        switch self {
        case .invalidNewsRelayURL:
            return "Enter a valid News relay URL (wss://...)."
        case .newsRelayRequired:
            return "Keep at least one News relay."
        case .invalidNewsAuthorIdentifier:
            return "Enter a valid hex pubkey, npub, or nprofile for News people."
        case .invalidNewsHashtag:
            return "Enter a valid hashtag for the News feed."
        case .invalidCustomFeedName:
            return "Give your feed a name."
        case .customFeedRequiresContent:
            return "Add at least one hashtag, person, or phrase to save this feed."
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()
    nonisolated static let slowModeRelayURL = URL(string: "wss://relay.damus.io/")!
    nonisolated static let defaultNewsRelayURLs = [URL(string: "wss://news.utxo.one")!]
    nonisolated static let availablePrimaryColorOptions = AppPrimaryColorOption.all
    nonisolated static var defaultPrimaryColor: Color {
        AppPrimaryColorOption.defaultOption.color
    }
    nonisolated static var defaultButtonTextColor: Color {
        Color.white
    }
    nonisolated static let legacyStorageKey = "x21.app.settings"
    nonisolated static let legacyScopedStorageKeyPrefix = "x21.app.settings.v2"
    nonisolated static let storageKeyPrefix = "flow.app.settings.v2"
    nonisolated static let legacyMigrationAccountKey = "flow.app.settings.legacyMigratedAccount"
    nonisolated static let sharedSpamFilterMarkedPubkeysKey = "flow.app.spamFilter.markedPubkeys.v1"

    private struct MentionMetadataDecoder: MetadataCoding {}

    @Published private var persistedSettings: PersistedSettings
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var previewTheme: AppThemeOption?
    @Published private(set) var previewFontOption: AppFontOption?
    @Published private var sharedSpamFilterMarkedPubkeys: [String]

    private let defaults: UserDefaults
    private let authStore: AuthStore
    private var currentAccountStorageID: String?
    private var notificationAuthorizationTask: Task<Void, Never>?

    private struct PersistedSettings: Codable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case primaryColor
            case theme
            case visualAccentMode
            case expressiveGradientOption
            case expressiveLinkColorIndex
            case minimalPrimaryColor
            case buttonGradientOption
            case generatedButtonGradient
            case buttonTextColor
            case holographicLightGradientOption
            case holographicDarkGradientOption
            case fontOption
            case fontSize
            case breakReminderInterval
            case liveReactsEnabled
            case hideNSFWContent
            case spamReplyFilterEnabled
            case spamFilterMarkedPubkeys
            case spamReplyFilterSafelistedPubkeys
            case autoplayVideos
            case autoplayVideoSoundEnabled
            case blurMediaFromUnfollowedAuthors
            case mediaEfficiencyEnabled
            case mediaFileSizeLimitsEnabled
            case largeGIFAutoplayLimitEnabled
            case floatingComposeButtonEnabled
            case fullWidthNoteRows
            case textOnlyMode
            case slowConnectionMode
            case localCorpusCrawlEnabled
            case localCorpusCrawlWiFiOnly
            case localCorpusBackgroundRefreshEnabled
            case localCorpusCrawlHopCount
            case localCorpusDeepMediaBackfillEnabled
            case notificationsEnabled
            case activityMentionNotificationsEnabled
            case activityReactionNotificationsEnabled
            case activityReplyNotificationsEnabled
            case activityReshareNotificationsEnabled
            case activityQuoteShareNotificationsEnabled
            case mediaUploadProvider
            case newsRelayURLs
            case newsAuthorPubkeys
            case newsHashtags
            case pollsFeedVisible
            case customFeeds
            case webOfTrustHops
        }

        var primaryColor: StoredColor?
        var theme: AppThemeOption = AppSettingsStore.defaultThemeForCurrentTime()
        var visualAccentMode: AppVisualAccentMode = .minimal
        var expressiveGradientOption: ExpressiveGradientOption = .aurora
        var expressiveLinkColorIndex: Int = 0
        var minimalPrimaryColor: StoredColor?
        var buttonGradientOption: HolographicGradientOption?
        var generatedButtonGradient: GeneratedButtonGradient?
        var buttonTextColor: StoredColor?
        var fontOption: AppFontOption = .system
        var fontSize: AppFontSize = .medium
        var breakReminderInterval: BreakReminderInterval = .fortyMinutes
        var liveReactsEnabled: Bool = true
        var hideNSFWContent: Bool = true
        var spamReplyFilterEnabled: Bool = true
        var spamFilterMarkedPubkeys: [String] = []
        var spamReplyFilterSafelistedPubkeys: [String] = []
        var autoplayVideos: Bool = true
        var autoplayVideoSoundEnabled: Bool = false
        var blurMediaFromUnfollowedAuthors: Bool = true
        var mediaEfficiencyEnabled: Bool = true
        var mediaFileSizeLimitsEnabled: Bool = true
        var largeGIFAutoplayLimitEnabled: Bool = true
        var floatingComposeButtonEnabled: Bool = false
        var fullWidthNoteRows: Bool = false
        var textOnlyMode: Bool = false
        var slowConnectionMode: Bool = false
        var localCorpusCrawlEnabled: Bool = true
        var localCorpusCrawlWiFiOnly: Bool = false
        var localCorpusBackgroundRefreshEnabled: Bool = true
        var localCorpusCrawlHopCount: Int = 2
        var localCorpusDeepMediaBackfillEnabled: Bool = true
        var notificationsEnabled: Bool = false
        var activityMentionNotificationsEnabled: Bool = true
        var activityReactionNotificationsEnabled: Bool = true
        var activityReplyNotificationsEnabled: Bool = true
        var activityReshareNotificationsEnabled: Bool = true
        var activityQuoteShareNotificationsEnabled: Bool = true
        var mediaUploadProvider: MediaUploadProvider = .blossom
        var newsRelayURLs: [URL] = AppSettingsStore.defaultNewsRelayURLs
        var newsAuthorPubkeys: [String] = []
        var newsHashtags: [String] = []
        var pollsFeedVisible: Bool = true
        var customFeeds: [CustomFeedDefinition] = []
        var webOfTrustHops: Int = 3

        init() {
            let defaultColor = StoredColor(color: AppSettingsStore.defaultPrimaryColor)
            primaryColor = defaultColor
            minimalPrimaryColor = defaultColor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedTheme = (try? container.decode(AppThemeOption.self, forKey: .theme)) ?? .system
            theme = decodedTheme.normalizedSelection

            let decodedMinimalPrimaryColor = try container.decodeIfPresent(
                StoredColor.self,
                forKey: .minimalPrimaryColor
            )
            let decodedLegacyPrimaryColor = try container.decodeIfPresent(
                StoredColor.self,
                forKey: .primaryColor
            )
            let decodedPrimaryColor = decodedMinimalPrimaryColor ?? decodedLegacyPrimaryColor
            buttonGradientOption = try container.decodeIfPresent(HolographicGradientOption.self, forKey: .buttonGradientOption)
            generatedButtonGradient = try container.decodeIfPresent(GeneratedButtonGradient.self, forKey: .generatedButtonGradient)
            buttonTextColor = try container.decodeIfPresent(StoredColor.self, forKey: .buttonTextColor)
            if buttonGradientOption == nil {
                switch decodedTheme {
                case .holographicLight:
                    buttonGradientOption = try container.decodeIfPresent(
                        HolographicGradientOption.self,
                        forKey: .holographicLightGradientOption
                    )
                case .holographicDark:
                    buttonGradientOption = try container.decodeIfPresent(
                        HolographicGradientOption.self,
                        forKey: .holographicDarkGradientOption
                    )
                case .system, .black, .white, .sakura, .dracula, .gamer, .dark, .light:
                    break
                }
            }
            expressiveGradientOption = try container.decodeIfPresent(
                ExpressiveGradientOption.self,
                forKey: .expressiveGradientOption
            ) ?? buttonGradientOption.map(ExpressiveGradientOption.mapped(from:)) ?? .aurora
            let decodedLinkColorIndex = try container.decodeIfPresent(Int.self, forKey: .expressiveLinkColorIndex) ?? 0
            expressiveLinkColorIndex = ExpressiveGradientOption.normalizedLinkColorIndex(
                decodedLinkColorIndex,
                count: expressiveGradientOption.linkColors.count
            )
            let decodedVisualAccentMode = try container.decodeIfPresent(AppVisualAccentMode.self, forKey: .visualAccentMode)

            let migratedPrimaryColor = decodedPrimaryColor?.color
                ?? AppSettingsStore.legacyPrimaryColor(
                    buttonGradientOption: buttonGradientOption,
                    generatedButtonGradient: generatedButtonGradient,
                    expressiveGradientOption: expressiveGradientOption,
                    expressiveLinkColorIndex: expressiveLinkColorIndex,
                    visualAccentMode: decodedVisualAccentMode
                )
                ?? AppSettingsStore.defaultPrimaryColor
            let normalizedPrimaryColor = AppSettingsStore.normalizedPrimaryColorOption(for: migratedPrimaryColor).color
            let storedPrimaryColor = StoredColor(color: normalizedPrimaryColor)
            primaryColor = storedPrimaryColor
            minimalPrimaryColor = storedPrimaryColor
            visualAccentMode = .minimal
            buttonGradientOption = nil
            generatedButtonGradient = nil
            buttonTextColor = nil
            fontOption = (try? container.decode(AppFontOption.self, forKey: .fontOption)) ?? .system
            fontSize = (try? container.decode(AppFontSize.self, forKey: .fontSize)) ?? .medium
            breakReminderInterval = (try? container.decode(BreakReminderInterval.self, forKey: .breakReminderInterval)) ?? .fortyMinutes
            liveReactsEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveReactsEnabled) ?? true
            hideNSFWContent = try container.decodeIfPresent(Bool.self, forKey: .hideNSFWContent) ?? true
            spamReplyFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .spamReplyFilterEnabled) ?? true
            spamFilterMarkedPubkeys = AppSettingsStore.normalizedNewsAuthorPubkeys(
                try container.decodeIfPresent([String].self, forKey: .spamFilterMarkedPubkeys) ?? []
            )
            spamReplyFilterSafelistedPubkeys = AppSettingsStore.normalizedNewsAuthorPubkeys(
                try container.decodeIfPresent([String].self, forKey: .spamReplyFilterSafelistedPubkeys) ?? []
            )
            autoplayVideos = try container.decodeIfPresent(Bool.self, forKey: .autoplayVideos) ?? true
            autoplayVideoSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoplayVideoSoundEnabled) ?? false
            blurMediaFromUnfollowedAuthors = try container.decodeIfPresent(Bool.self, forKey: .blurMediaFromUnfollowedAuthors) ?? true
            mediaEfficiencyEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaEfficiencyEnabled) ?? true
            mediaFileSizeLimitsEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaFileSizeLimitsEnabled) ?? true
            largeGIFAutoplayLimitEnabled = try container.decodeIfPresent(Bool.self, forKey: .largeGIFAutoplayLimitEnabled) ?? true
            floatingComposeButtonEnabled = try container.decodeIfPresent(Bool.self, forKey: .floatingComposeButtonEnabled) ?? false
            fullWidthNoteRows = try container.decodeIfPresent(Bool.self, forKey: .fullWidthNoteRows) ?? false
            textOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .textOnlyMode) ?? false
            slowConnectionMode = try container.decodeIfPresent(Bool.self, forKey: .slowConnectionMode) ?? false
            localCorpusCrawlEnabled = try container.decodeIfPresent(Bool.self, forKey: .localCorpusCrawlEnabled) ?? true
            localCorpusCrawlWiFiOnly = try container.decodeIfPresent(Bool.self, forKey: .localCorpusCrawlWiFiOnly) ?? false
            localCorpusBackgroundRefreshEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .localCorpusBackgroundRefreshEnabled
            ) ?? true
            localCorpusCrawlHopCount = AppSettingsStore.clampedLocalCorpusCrawlHopCount(
                try container.decodeIfPresent(Int.self, forKey: .localCorpusCrawlHopCount) ?? 2
            )
            localCorpusDeepMediaBackfillEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .localCorpusDeepMediaBackfillEnabled
            ) ?? true
            notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
            activityMentionNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .activityMentionNotificationsEnabled) ?? true
            activityReactionNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .activityReactionNotificationsEnabled) ?? true
            activityReplyNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .activityReplyNotificationsEnabled) ?? true
            activityReshareNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .activityReshareNotificationsEnabled) ?? true
            activityQuoteShareNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .activityQuoteShareNotificationsEnabled) ?? true
            mediaUploadProvider = (try? container.decode(MediaUploadProvider.self, forKey: .mediaUploadProvider)) ?? .blossom
            newsRelayURLs = AppSettingsStore.normalizedRelayURLs(
                (try? container.decode([URL].self, forKey: .newsRelayURLs)) ?? AppSettingsStore.defaultNewsRelayURLs,
                fallback: AppSettingsStore.defaultNewsRelayURLs
            )
            newsAuthorPubkeys = AppSettingsStore.normalizedNewsAuthorPubkeys(
                try container.decodeIfPresent([String].self, forKey: .newsAuthorPubkeys) ?? []
            )
            newsHashtags = AppSettingsStore.normalizedNewsHashtags(
                try container.decodeIfPresent([String].self, forKey: .newsHashtags) ?? []
            )
            pollsFeedVisible = try container.decodeIfPresent(Bool.self, forKey: .pollsFeedVisible) ?? true
            customFeeds = AppSettingsStore.normalizedCustomFeeds(
                try container.decodeIfPresent([CustomFeedDefinition].self, forKey: .customFeeds) ?? []
            )
            webOfTrustHops = AppSettingsStore.clampedWebOfTrustHops(
                try container.decodeIfPresent(Int.self, forKey: .webOfTrustHops) ?? 3
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let encodedMinimalColor = minimalPrimaryColor ?? primaryColor
            try container.encodeIfPresent(encodedMinimalColor, forKey: .primaryColor)
            try container.encodeIfPresent(encodedMinimalColor, forKey: .minimalPrimaryColor)
            try container.encode(theme, forKey: .theme)
            try container.encode(visualAccentMode, forKey: .visualAccentMode)
            try container.encode(expressiveGradientOption, forKey: .expressiveGradientOption)
            try container.encode(expressiveLinkColorIndex, forKey: .expressiveLinkColorIndex)
            let legacyButtonGradient = visualAccentMode == .expressive
                ? expressiveGradientOption.legacyHolographicOption
                : nil
            try container.encodeIfPresent(legacyButtonGradient, forKey: .buttonGradientOption)
            try container.encodeIfPresent(buttonTextColor, forKey: .buttonTextColor)
            try container.encode(fontOption, forKey: .fontOption)
            try container.encode(fontSize, forKey: .fontSize)
            try container.encode(breakReminderInterval, forKey: .breakReminderInterval)
            try container.encode(liveReactsEnabled, forKey: .liveReactsEnabled)
            try container.encode(hideNSFWContent, forKey: .hideNSFWContent)
            try container.encode(spamReplyFilterEnabled, forKey: .spamReplyFilterEnabled)
            try container.encode(spamFilterMarkedPubkeys, forKey: .spamFilterMarkedPubkeys)
            try container.encode(spamReplyFilterSafelistedPubkeys, forKey: .spamReplyFilterSafelistedPubkeys)
            try container.encode(autoplayVideos, forKey: .autoplayVideos)
            try container.encode(autoplayVideoSoundEnabled, forKey: .autoplayVideoSoundEnabled)
            try container.encode(blurMediaFromUnfollowedAuthors, forKey: .blurMediaFromUnfollowedAuthors)
            try container.encode(mediaEfficiencyEnabled, forKey: .mediaEfficiencyEnabled)
            try container.encode(mediaFileSizeLimitsEnabled, forKey: .mediaFileSizeLimitsEnabled)
            try container.encode(largeGIFAutoplayLimitEnabled, forKey: .largeGIFAutoplayLimitEnabled)
            try container.encode(floatingComposeButtonEnabled, forKey: .floatingComposeButtonEnabled)
            try container.encode(fullWidthNoteRows, forKey: .fullWidthNoteRows)
            try container.encode(textOnlyMode, forKey: .textOnlyMode)
            try container.encode(slowConnectionMode, forKey: .slowConnectionMode)
            try container.encode(localCorpusCrawlEnabled, forKey: .localCorpusCrawlEnabled)
            try container.encode(localCorpusCrawlWiFiOnly, forKey: .localCorpusCrawlWiFiOnly)
            try container.encode(localCorpusBackgroundRefreshEnabled, forKey: .localCorpusBackgroundRefreshEnabled)
            try container.encode(localCorpusCrawlHopCount, forKey: .localCorpusCrawlHopCount)
            try container.encode(localCorpusDeepMediaBackfillEnabled, forKey: .localCorpusDeepMediaBackfillEnabled)
            try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
            try container.encode(activityMentionNotificationsEnabled, forKey: .activityMentionNotificationsEnabled)
            try container.encode(activityReactionNotificationsEnabled, forKey: .activityReactionNotificationsEnabled)
            try container.encode(activityReplyNotificationsEnabled, forKey: .activityReplyNotificationsEnabled)
            try container.encode(activityReshareNotificationsEnabled, forKey: .activityReshareNotificationsEnabled)
            try container.encode(activityQuoteShareNotificationsEnabled, forKey: .activityQuoteShareNotificationsEnabled)
            try container.encode(mediaUploadProvider, forKey: .mediaUploadProvider)
            try container.encode(newsRelayURLs, forKey: .newsRelayURLs)
            try container.encode(newsAuthorPubkeys, forKey: .newsAuthorPubkeys)
            try container.encode(newsHashtags, forKey: .newsHashtags)
            try container.encode(pollsFeedVisible, forKey: .pollsFeedVisible)
            try container.encode(customFeeds, forKey: .customFeeds)
            try container.encode(webOfTrustHops, forKey: .webOfTrustHops)
        }
    }

    init(defaults: UserDefaults = .standard, authStore: AuthStore = .shared) {
        self.defaults = defaults
        self.authStore = authStore
        self.sharedSpamFilterMarkedPubkeys = Self.loadSharedSpamFilterMarkedPubkeys(defaults: defaults)
        let authState = authStore.load()
        let initialAccountStorageID = Self.normalizedSettingsAccountID(
            authState.accounts.first(where: { $0.id == authState.currentAccountID })?.pubkey
        )
        let allowLegacyGlobalMigration = authState.accounts.count <= 1
        self.currentAccountStorageID = initialAccountStorageID

        if let initialAccountStorageID,
           let migratedSettings = Self.migrateLegacySettingsIfNeeded(
               defaults: defaults,
               accountStorageID: initialAccountStorageID,
               allowLegacyGlobalMigration: allowLegacyGlobalMigration
           ) {
            persistedSettings = migratedSettings
        } else if let initialAccountStorageID {
            persistedSettings = Self.loadPersistedSettings(
                defaults: defaults,
                accountStorageID: initialAccountStorageID,
                allowLegacyFallback: false
            )
        } else {
            persistedSettings = PersistedSettings()
        }
        normalizeLocalCorpusCrawlDefaultsIfNeeded()
        migrateScopedSpamFilterMarkedPubkeysIfNeeded()
    }

    deinit {
        notificationAuthorizationTask?.cancel()
    }

    func configure(accountPubkey: String?) {
        let normalizedAccountStorageID = Self.normalizedSettingsAccountID(accountPubkey)
        guard currentAccountStorageID != normalizedAccountStorageID else { return }
        let allowLegacyGlobalMigration = authStore.hasSingleAccountHint()

        currentAccountStorageID = normalizedAccountStorageID

        guard let normalizedAccountStorageID else {
            persistedSettings = PersistedSettings()
            return
        }

        if let migratedSettings = Self.migrateLegacySettingsIfNeeded(
            defaults: defaults,
            accountStorageID: normalizedAccountStorageID,
            allowLegacyGlobalMigration: allowLegacyGlobalMigration
        ) {
            persistedSettings = migratedSettings
            migrateScopedSpamFilterMarkedPubkeysIfNeeded()
            return
        }

        persistedSettings = Self.loadPersistedSettings(
            defaults: defaults,
            accountStorageID: normalizedAccountStorageID,
            allowLegacyFallback: false
        )
        normalizeLocalCorpusCrawlDefaultsIfNeeded()
        migrateScopedSpamFilterMarkedPubkeysIfNeeded()
    }

    var primaryColor: Color {
        get {
            persistedSettings.minimalPrimaryColor?.color ?? persistedSettings.primaryColor?.color ?? Self.defaultPrimaryColor
        }
        set {
            let storedColor = StoredColor(color: Self.normalizedPrimaryColorOption(for: newValue).color)
            persistedSettings.visualAccentMode = .minimal
            persistedSettings.primaryColor = storedColor
            persistedSettings.minimalPrimaryColor = storedColor
            persistedSettings.buttonTextColor = nil
            persist()
        }
    }

    var primaryColorOption: AppPrimaryColorOption {
        Self.normalizedPrimaryColorOption(for: primaryColor)
    }

    var linkColor: Color {
        primaryColor
    }

    var visualAccentMode: AppVisualAccentMode {
        get { .minimal }
        set {
            persistedSettings.visualAccentMode = .minimal
            persistedSettings.buttonTextColor = nil
            persist()
        }
    }

    var expressiveGradientOption: ExpressiveGradientOption {
        get { persistedSettings.expressiveGradientOption }
        set {
            persistedSettings.expressiveGradientOption = newValue
            primaryColor = newValue.linkColor(at: persistedSettings.expressiveLinkColorIndex)
            persistedSettings.buttonGradientOption = nil
            persistedSettings.generatedButtonGradient = nil
            persistedSettings.buttonTextColor = nil
            persist()
        }
    }

    var expressiveLinkColorIndex: Int {
        get { persistedSettings.expressiveLinkColorIndex }
        set {
            persistedSettings.expressiveLinkColorIndex = ExpressiveGradientOption.normalizedLinkColorIndex(
                newValue,
                count: persistedSettings.expressiveGradientOption.linkColors.count
            )
            persist()
        }
    }

    func refreshExpressiveLinkColor() {
        primaryColor = linkColor
        persist()
    }

    private func normalizeExpressiveLinkColorIndex() {
        persistedSettings.expressiveLinkColorIndex = ExpressiveGradientOption.normalizedLinkColorIndex(
            persistedSettings.expressiveLinkColorIndex,
            count: persistedSettings.expressiveGradientOption.linkColors.count
        )
    }

    var buttonGradientOption: HolographicGradientOption? {
        get { nil }
        set {
            if let newValue {
                persistedSettings.expressiveGradientOption = ExpressiveGradientOption.mapped(from: newValue)
                primaryColor = newValue.defaultLinkColor
            } else {
                persistedSettings.visualAccentMode = .minimal
                persistedSettings.buttonGradientOption = nil
            }
            persistedSettings.generatedButtonGradient = nil
            persistedSettings.buttonTextColor = nil
            persist()
        }
    }

    var generatedButtonGradient: GeneratedButtonGradient? {
        get { nil }
        set {
            if let newValue {
                primaryColor = Self.averageColor(from: newValue.gradientColors)
            }
            persistedSettings.generatedButtonGradient = nil
            persist()
        }
    }

    var buttonTextColor: Color {
        get { Self.buttonTextColor(for: persistedSettings) }
        set {}
    }

    func applyGeneratedButtonGradient(_ gradient: GeneratedButtonGradient) {
        generatedButtonGradient = gradient
    }

    func clearButtonGradient() {
        persistedSettings.visualAccentMode = .minimal
        persistedSettings.buttonGradientOption = nil
        persistedSettings.generatedButtonGradient = nil
        persistedSettings.buttonTextColor = nil
        persist()
    }

    var holographicLightGradientOption: HolographicGradientOption {
        get { persistedSettings.buttonGradientOption ?? .softHolographicSheen }
        set { buttonGradientOption = newValue }
    }

    var holographicDarkGradientOption: HolographicGradientOption {
        get { persistedSettings.buttonGradientOption ?? .softHolographicSheen }
        set { buttonGradientOption = newValue }
    }

    var activeButtonGradientOption: HolographicGradientOption? {
        nil
    }

    var activeGeneratedButtonGradient: GeneratedButtonGradient? {
        nil
    }

    var activeHolographicGradientOption: HolographicGradientOption? {
        nil
    }

    var themeIconAccentColor: Color {
        themePalette.mutedForeground
    }

    var usesPrimaryGradientForProminentButtons: Bool {
        false
    }

    var primaryGradient: LinearGradient {
        Self.primaryGradient(for: persistedSettings)
    }

    func avatarFallbackGradient(forAccountPubkey accountPubkey: String?) -> LinearGradient {
        Self.primaryGradient(for: persistedSettings(forAccountPubkey: accountPubkey))
    }

    func avatarFallbackForeground(forAccountPubkey accountPubkey: String?) -> Color {
        Self.buttonTextColor(for: persistedSettings(forAccountPubkey: accountPubkey))
    }

    var theme: AppThemeOption {
        get { persistedSettings.theme.normalizedSelection }
        set {
            previewTheme = nil
            persistedSettings.theme = newValue.normalizedSelection
            persist()
        }
    }

    var fontSize: AppFontSize {
        get { persistedSettings.fontSize }
        set {
            persistedSettings.fontSize = newValue
            persist()
        }
    }

    var fontOption: AppFontOption {
        get { persistedSettings.fontOption }
        set {
            previewFontOption = nil
            persistedSettings.fontOption = newValue
            persist()
        }
    }

    var breakReminderInterval: BreakReminderInterval {
        get { persistedSettings.breakReminderInterval }
        set {
            persistedSettings.breakReminderInterval = newValue
            persist()
        }
    }

    var liveReactsEnabled: Bool {
        get { persistedSettings.liveReactsEnabled }
        set {
            persistedSettings.liveReactsEnabled = newValue
            persist()
        }
    }

    var textOnlyMode: Bool {
        get { persistedSettings.textOnlyMode }
        set {
            persistedSettings.textOnlyMode = newValue
            persist()
        }
    }

    var hideNSFWContent: Bool {
        get { persistedSettings.hideNSFWContent }
        set {
            persistedSettings.hideNSFWContent = newValue
            persist()
        }
    }

    var spamReplyFilterEnabled: Bool {
        get { persistedSettings.spamReplyFilterEnabled }
        set {
            persistedSettings.spamReplyFilterEnabled = newValue
            persist()
        }
    }

    var spamReplyFilterSafelistedPubkeys: [String] {
        persistedSettings.spamReplyFilterSafelistedPubkeys
    }

    var spamFilterMarkedPubkeys: [String] {
        sharedSpamFilterMarkedPubkeys
    }

    var spamFilterLabelSignature: String {
        [
            spamFilterMarkedPubkeys.joined(separator: "|"),
            spamReplyFilterSafelistedPubkeys.joined(separator: "|")
        ]
        .joined(separator: "-")
    }

    func isSpamReplySafelisted(_ pubkey: String) -> Bool {
        let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return persistedSettings.spamReplyFilterSafelistedPubkeys.contains(normalized)
    }

    func isSpamFilterMarked(_ pubkey: String) -> Bool {
        let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return sharedSpamFilterMarkedPubkeys.contains(normalized)
    }

    func shouldHideSpamMarkedPubkey(_ pubkey: String) -> Bool {
        isSpamFilterMarked(pubkey) && !isSpamReplySafelisted(pubkey)
    }

    func addSpamReplySafelistedPubkey(_ pubkey: String) {
        guard let normalized = Self.normalizedNewsAuthorPubkey(from: pubkey) else { return }
        if !persistedSettings.spamReplyFilterSafelistedPubkeys.contains(normalized) {
            persistedSettings.spamReplyFilterSafelistedPubkeys.append(normalized)
            persistedSettings.spamReplyFilterSafelistedPubkeys.sort()
            persist()
        }
    }

    func removeSpamReplySafelistedPubkey(_ pubkey: String) {
        let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        let updated = persistedSettings.spamReplyFilterSafelistedPubkeys.filter { $0 != normalized }
        guard updated.count != persistedSettings.spamReplyFilterSafelistedPubkeys.count else { return }
        persistedSettings.spamReplyFilterSafelistedPubkeys = updated
        persist()
    }

    func addSpamFilterMarkedPubkey(_ pubkey: String) {
        guard let normalized = Self.normalizedNewsAuthorPubkey(from: pubkey) else { return }
        if persistedSettings.spamReplyFilterSafelistedPubkeys.contains(normalized) {
            persistedSettings.spamReplyFilterSafelistedPubkeys.removeAll { $0 == normalized }
            persist()
        }
        if !sharedSpamFilterMarkedPubkeys.contains(normalized) {
            sharedSpamFilterMarkedPubkeys.append(normalized)
            sharedSpamFilterMarkedPubkeys.sort()
            persistSharedSpamFilterMarkedPubkeys()
        }
    }

    func removeSpamFilterMarkedPubkey(_ pubkey: String) {
        let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        let updated = sharedSpamFilterMarkedPubkeys.filter { $0 != normalized }
        guard updated.count != sharedSpamFilterMarkedPubkeys.count else { return }
        sharedSpamFilterMarkedPubkeys = updated
        persistSharedSpamFilterMarkedPubkeys()
    }

    var autoplayVideos: Bool {
        get { persistedSettings.autoplayVideos }
        set {
            persistedSettings.autoplayVideos = newValue
            persist()
        }
    }

    var autoplayVideoSoundEnabled: Bool {
        get { persistedSettings.autoplayVideoSoundEnabled }
        set {
            persistedSettings.autoplayVideoSoundEnabled = newValue
            persist()
        }
    }

    var blurMediaFromUnfollowedAuthors: Bool {
        get { persistedSettings.blurMediaFromUnfollowedAuthors }
        set {
            persistedSettings.blurMediaFromUnfollowedAuthors = newValue
            persist()
        }
    }

    var mediaEfficiencyEnabled: Bool {
        get { persistedSettings.mediaEfficiencyEnabled }
        set {
            persistedSettings.mediaEfficiencyEnabled = newValue
            persist()
        }
    }

    var mediaFileSizeLimitsEnabled: Bool {
        get { persistedSettings.mediaFileSizeLimitsEnabled }
        set {
            persistedSettings.mediaFileSizeLimitsEnabled = newValue
            persist()
        }
    }

    var largeGIFAutoplayLimitEnabled: Bool {
        get { persistedSettings.largeGIFAutoplayLimitEnabled }
        set {
            persistedSettings.largeGIFAutoplayLimitEnabled = newValue
            persist()
        }
    }

    var floatingComposeButtonEnabled: Bool {
        get { persistedSettings.floatingComposeButtonEnabled }
        set {
            persistedSettings.floatingComposeButtonEnabled = newValue
            persist()
        }
    }

    var mediaFileSizeLimitsEffective: Bool {
        mediaEfficiencyEnabled && mediaFileSizeLimitsEnabled
    }

    var largeGIFAutoplayLimitEffective: Bool {
        mediaEfficiencyEnabled && largeGIFAutoplayLimitEnabled
    }

    var fullWidthNoteRows: Bool {
        get { persistedSettings.fullWidthNoteRows }
        set {
            persistedSettings.fullWidthNoteRows = newValue
            persist()
        }
    }

    var slowConnectionMode: Bool {
        get { persistedSettings.slowConnectionMode }
        set {
            persistedSettings.slowConnectionMode = newValue
            persist()
        }
    }

    var notificationsEnabled: Bool {
        get { persistedSettings.notificationsEnabled }
        set {
            persistedSettings.notificationsEnabled = newValue
            persist()

            if newValue {
                scheduleNotificationAuthorizationCheck()
            } else {
                notificationAuthorizationTask?.cancel()
                notificationAuthorizationTask = nil
            }
        }
    }

    var activityMentionNotificationsEnabled: Bool {
        get { persistedSettings.activityMentionNotificationsEnabled }
        set {
            persistedSettings.activityMentionNotificationsEnabled = newValue
            persist()
        }
    }

    var activityReactionNotificationsEnabled: Bool {
        get { persistedSettings.activityReactionNotificationsEnabled }
        set {
            persistedSettings.activityReactionNotificationsEnabled = newValue
            persist()
        }
    }

    var activityReplyNotificationsEnabled: Bool {
        get { persistedSettings.activityReplyNotificationsEnabled }
        set {
            persistedSettings.activityReplyNotificationsEnabled = newValue
            persist()
        }
    }

    var activityReshareNotificationsEnabled: Bool {
        get { persistedSettings.activityReshareNotificationsEnabled }
        set {
            persistedSettings.activityReshareNotificationsEnabled = newValue
            persist()
        }
    }

    var activityQuoteShareNotificationsEnabled: Bool {
        get { persistedSettings.activityQuoteShareNotificationsEnabled }
        set {
            persistedSettings.activityQuoteShareNotificationsEnabled = newValue
            persist()
        }
    }

    var mediaUploadProvider: MediaUploadProvider {
        get { persistedSettings.mediaUploadProvider }
        set {
            persistedSettings.mediaUploadProvider = newValue
            persist()
        }
    }

    var newsRelayURLs: [URL] {
        get { persistedSettings.newsRelayURLs }
        set {
            persistedSettings.newsRelayURLs = Self.normalizedRelayURLs(
                newValue,
                fallback: Self.defaultNewsRelayURLs
            )
            persist()
        }
    }

    var newsAuthorPubkeys: [String] {
        get { persistedSettings.newsAuthorPubkeys }
        set {
            persistedSettings.newsAuthorPubkeys = Self.normalizedNewsAuthorPubkeys(newValue)
            persist()
        }
    }

    var newsHashtags: [String] {
        get { persistedSettings.newsHashtags }
        set {
            persistedSettings.newsHashtags = Self.normalizedNewsHashtags(newValue)
            persist()
        }
    }

    var pollsFeedVisible: Bool {
        get { persistedSettings.pollsFeedVisible }
        set {
            persistedSettings.pollsFeedVisible = newValue
            persist()
        }
    }

    var webOfTrustHops: Int {
        get { persistedSettings.webOfTrustHops }
        set {
            persistedSettings.webOfTrustHops = Self.clampedWebOfTrustHops(newValue)
            persist()
        }
    }

    var localCorpusCrawlEnabled: Bool {
        get { persistedSettings.localCorpusCrawlEnabled }
        set {
            persistedSettings.localCorpusCrawlEnabled = newValue
            persist()
        }
    }

    var localCorpusCrawlWiFiOnly: Bool {
        get { persistedSettings.localCorpusCrawlWiFiOnly }
        set {
            persistedSettings.localCorpusCrawlWiFiOnly = newValue
            persist()
        }
    }

    var localCorpusBackgroundRefreshEnabled: Bool {
        get { persistedSettings.localCorpusBackgroundRefreshEnabled }
        set {
            persistedSettings.localCorpusBackgroundRefreshEnabled = newValue
            persist()
        }
    }

    var localCorpusCrawlHopCount: Int {
        get { persistedSettings.localCorpusCrawlHopCount }
        set {
            persistedSettings.localCorpusCrawlHopCount = Self.clampedLocalCorpusCrawlHopCount(newValue)
            persist()
        }
    }

    var localCorpusDeepMediaBackfillEnabled: Bool {
        get { persistedSettings.localCorpusDeepMediaBackfillEnabled }
        set {
            persistedSettings.localCorpusDeepMediaBackfillEnabled = newValue
            persist()
        }
    }

    var customFeeds: [CustomFeedDefinition] {
        get { persistedSettings.customFeeds }
        set {
            persistedSettings.customFeeds = Self.normalizedCustomFeeds(newValue)
            persist()
        }
    }

    func addNewsRelay(_ relayInput: String) throws {
        guard let relayURL = Self.normalizedRelayURL(from: relayInput) else {
            throw AppSettingsError.invalidNewsRelayURL
        }

        setNewsRelayURLs(newsRelayURLs + [relayURL])
    }

    func removeNewsRelay(_ relayURL: URL) throws {
        guard newsRelayURLs.count > 1 else {
            throw AppSettingsError.newsRelayRequired
        }

        let normalizedRelayURL = Self.normalizedRelayURL(relayURL) ?? relayURL
        let updatedRelayURLs = newsRelayURLs.filter { $0.absoluteString != normalizedRelayURL.absoluteString }

        guard updatedRelayURLs.count < newsRelayURLs.count else { return }
        setNewsRelayURLs(updatedRelayURLs)
    }

    func setNewsRelayURLs(_ relayURLs: [URL]) {
        newsRelayURLs = relayURLs
    }

    func addNewsAuthor(_ rawIdentifier: String) throws {
        guard let pubkey = Self.normalizedNewsAuthorPubkey(from: rawIdentifier) else {
            throw AppSettingsError.invalidNewsAuthorIdentifier
        }
        setNewsAuthorPubkeys(newsAuthorPubkeys + [pubkey])
    }

    func removeNewsAuthor(_ pubkey: String) {
        let normalizedPubkey = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPubkey.isEmpty else { return }
        newsAuthorPubkeys = newsAuthorPubkeys.filter { $0 != normalizedPubkey }
    }

    func setNewsAuthorPubkeys(_ pubkeys: [String]) {
        newsAuthorPubkeys = pubkeys
    }

    func addNewsHashtag(_ rawHashtag: String) throws {
        guard let hashtag = Self.normalizedNewsHashtag(rawHashtag) else {
            throw AppSettingsError.invalidNewsHashtag
        }
        setNewsHashtags(newsHashtags + [hashtag])
    }

    func removeNewsHashtag(_ hashtag: String) {
        let normalizedHashtag = Self.normalizedNewsHashtag(hashtag) ?? hashtag
        newsHashtags = newsHashtags.filter { $0 != normalizedHashtag }
    }

    func setNewsHashtags(_ hashtags: [String]) {
        newsHashtags = hashtags
    }

    func saveCustomFeed(_ feed: CustomFeedDefinition) throws {
        let normalizedFeed = try Self.normalizedCustomFeed(feed)
        var updatedFeeds = customFeeds

        if let existingIndex = updatedFeeds.firstIndex(where: { $0.id == normalizedFeed.id }) {
            updatedFeeds[existingIndex] = normalizedFeed
        } else {
            updatedFeeds.append(normalizedFeed)
        }

        customFeeds = updatedFeeds
    }

    func removeCustomFeed(id: String) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedID.isEmpty else { return }
        customFeeds = customFeeds.filter { $0.id != normalizedID }
    }

    func customFeed(withID id: String) -> CustomFeedDefinition? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedID.isEmpty else { return nil }
        return customFeeds.first { $0.id == normalizedID }
    }

    var activeTheme: AppThemeOption {
        if let previewTheme, previewTheme.isEnabled {
            return previewTheme
        }
        let requestedTheme = persistedSettings.theme.normalizedSelection
        return requestedTheme.isEnabled ? requestedTheme : .system
    }

    var themePalette: AppThemePalette {
        let palette = activeTheme.palette

        switch activeTheme.normalizedSelection {
        case .holographicLight:
            return palette.applyingLightPrimaryAccent(primaryColor)
        case .system, .black, .white, .sakura, .dracula, .gamer, .holographicDark, .dark, .light:
            return palette
        }
    }

    var settingsCardBorder: Color {
        activeTheme == .gamer ? themePalette.chromeBorder : themePalette.sheetCardBorder
    }

    func themeSeparator(defaultOpacity: Double) -> Color {
        switch activeTheme.normalizedSelection {
        case .gamer, .holographicLight, .light:
            return themePalette.separator
        case .system:
            return Color(
                UIColor { [self] traits in
                    let resolved = UIColor(self.themePalette.separator).resolvedColor(with: traits)
                    guard traits.userInterfaceStyle == .dark else { return resolved }
                    let scaledAlpha = min(max(resolved.cgColor.alpha * defaultOpacity, 0), 1)
                    return resolved.withAlphaComponent(scaledAlpha)
                }
            )
        default:
            return themePalette.separator.opacity(defaultOpacity)
        }
    }

    var activeFontOption: AppFontOption {
        if let previewFontOption, previewFontOption.isEnabled {
            return previewFontOption
        }
        let requestedFontOption = persistedSettings.fontOption
        return requestedFontOption.isEnabled ? requestedFontOption : .system
    }

    var canCustomizePrimaryColor: Bool {
        true
    }

    func canBeginThemePreview(_ theme: AppThemeOption) -> Bool {
        theme.isEnabled
    }

    @discardableResult
    func beginThemePreview(_ theme: AppThemeOption) -> Bool {
        guard canBeginThemePreview(theme) else { return false }
        previewTheme = theme
        return true
    }

    func endThemePreview() {
        previewTheme = nil
    }

    func beginFontPreview(_ option: AppFontOption) {
        guard option.isEnabled else { return }
        previewFontOption = option
    }

    func endFontPreview() {
        previewFontOption = nil
    }

    var preferredColorScheme: ColorScheme? {
        activeTheme.preferredColorScheme
    }

    var dynamicTypeSize: DynamicTypeSize {
        fontSize.dynamicTypeSize
    }

    var reactionsVisibleInFeeds: Bool {
        !slowConnectionMode
    }

    func effectiveReadRelayURLs(from relayURLs: [URL]) -> [URL] {
        if slowConnectionMode {
            return [Self.slowModeRelayURL]
        }
        let normalized = Self.normalizedRelayURLs(relayURLs)
        return normalized.isEmpty ? [Self.slowModeRelayURL] : normalized
    }

    func effectiveWriteRelayURLs(from relayURLs: [URL], fallbackReadRelayURLs: [URL] = []) -> [URL] {
        if slowConnectionMode {
            return [Self.slowModeRelayURL]
        }

        let normalizedWrite = Self.normalizedRelayURLs(relayURLs)
        if !normalizedWrite.isEmpty {
            return normalizedWrite
        }

        let normalizedFallback = Self.normalizedRelayURLs(fallbackReadRelayURLs)
        return normalizedFallback.isEmpty ? [Self.slowModeRelayURL] : normalizedFallback
    }

    var notificationsStatusDescription: String {
        switch notificationAuthorizationStatus {
        case .notDetermined:
            return notificationsEnabled
                ? "Waiting for iOS to ask for permission."
                : "Turn this on to request permission."
        case .authorized, .provisional, .ephemeral:
            return notificationsEnabled
                ? "Notifications are enabled on this device."
                : "Notifications are allowed, but this app setting is off."
        case .denied:
            return "Notifications are blocked in iOS Settings."
        @unknown default:
            return "Notification status is unavailable."
        }
    }

    var activityNotificationPreferenceSignature: String {
        [
            activityMentionNotificationsEnabled,
            activityReactionNotificationsEnabled,
            activityReplyNotificationsEnabled,
            activityReshareNotificationsEnabled,
            activityQuoteShareNotificationsEnabled
        ]
        .map { $0 ? "1" : "0" }
        .joined(separator: "-")
    }

    var spamReplyFilterSignature: String {
        [
            spamReplyFilterEnabled ? "1" : "0",
            spamFilterMarkedPubkeys.joined(separator: "|"),
            spamReplyFilterSafelistedPubkeys.joined(separator: "|")
        ]
        .joined(separator: "-")
    }

    func isActivityNotificationEnabled(for preference: ActivityNotificationPreference) -> Bool {
        switch preference {
        case .mentions:
            return activityMentionNotificationsEnabled
        case .reactions:
            return activityReactionNotificationsEnabled
        case .replies:
            return activityReplyNotificationsEnabled
        case .reshares:
            return activityReshareNotificationsEnabled
        case .quoteShares:
            return activityQuoteShareNotificationsEnabled
        }
    }

    func refreshNotificationAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus

        if settings.authorizationStatus == .denied {
            if persistedSettings.notificationsEnabled {
                persistedSettings.notificationsEnabled = false
                persist()
            }
        }
    }

    private func scheduleNotificationAuthorizationCheck() {
        notificationAuthorizationTask?.cancel()
        notificationAuthorizationTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveNotificationAuthorization()
        }
    }

    private func resolveNotificationAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .denied:
            if persistedSettings.notificationsEnabled {
                persistedSettings.notificationsEnabled = false
                persist()
            }
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            let refreshed = await center.notificationSettings()
            notificationAuthorizationStatus = refreshed.authorizationStatus

            if !granted || !(refreshed.authorizationStatus == .authorized || refreshed.authorizationStatus == .provisional || refreshed.authorizationStatus == .ephemeral) {
                if persistedSettings.notificationsEnabled {
                    persistedSettings.notificationsEnabled = false
                    persist()
                }
            }
        @unknown default:
            if persistedSettings.notificationsEnabled {
                persistedSettings.notificationsEnabled = false
                persist()
            }
        }

        notificationAuthorizationTask = nil
    }

    private func persist() {
        guard currentAccountStorageID != nil else { return }
        guard let data = try? JSONEncoder().encode(persistedSettings) else { return }
        defaults.set(data, forKey: Self.storageKey(for: currentAccountStorageID))
    }

    private func normalizeLocalCorpusCrawlDefaultsIfNeeded() {
        guard persistedSettings.localCorpusCrawlEnabled,
              persistedSettings.localCorpusCrawlWiFiOnly,
              persistedSettings.localCorpusBackgroundRefreshEnabled,
              persistedSettings.localCorpusCrawlHopCount == 2,
              !persistedSettings.localCorpusDeepMediaBackfillEnabled else {
            return
        }

        persistedSettings.localCorpusCrawlWiFiOnly = false
        persistedSettings.localCorpusDeepMediaBackfillEnabled = true
        persist()
    }

    private func persistSharedSpamFilterMarkedPubkeys() {
        defaults.set(sharedSpamFilterMarkedPubkeys, forKey: Self.sharedSpamFilterMarkedPubkeysKey)
    }

    private func persistedSettings(forAccountPubkey accountPubkey: String?) -> PersistedSettings {
        guard let normalizedAccountStorageID = Self.normalizedSettingsAccountID(accountPubkey) else {
            return persistedSettings
        }

        if normalizedAccountStorageID == currentAccountStorageID {
            return persistedSettings
        }

        return Self.loadPersistedSettings(
            defaults: defaults,
            accountStorageID: normalizedAccountStorageID,
            allowLegacyFallback: false
        )
    }

    nonisolated static func defaultThemeForCurrentTime(
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> AppThemeOption {
        let hour = calendar.component(.hour, from: date)
        return (6..<18).contains(hour) ? .holographicLight : .black
    }

    nonisolated static func normalizedPrimaryColorOption(for color: Color) -> AppPrimaryColorOption {
        AppPrimaryColorOption.nearest(to: color)
    }

    nonisolated static func legacyPrimaryColor(
        buttonGradientOption: HolographicGradientOption?,
        generatedButtonGradient: GeneratedButtonGradient?,
        expressiveGradientOption: ExpressiveGradientOption,
        expressiveLinkColorIndex: Int,
        visualAccentMode: AppVisualAccentMode?
    ) -> Color? {
        if let generatedButtonGradient {
            return averageColor(from: generatedButtonGradient.gradientColors)
        }
        if let buttonGradientOption {
            return buttonGradientOption.defaultLinkColor
        }
        guard visualAccentMode == .expressive else { return nil }
        return expressiveGradientOption.linkColor(at: expressiveLinkColorIndex)
    }

    private static func primaryGradient(for settings: PersistedSettings) -> LinearGradient {
        let color = settings.minimalPrimaryColor?.color ?? settings.primaryColor?.color ?? defaultPrimaryColor
        return LinearGradient(
            colors: [color, color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func buttonTextColor(for settings: PersistedSettings) -> Color {
        let color = settings.minimalPrimaryColor?.color ?? settings.primaryColor?.color ?? defaultPrimaryColor
        return contrastingForegroundColor(for: color)
    }

    nonisolated static func averageColor(from colors: [Color]) -> Color {
        guard !colors.isEmpty else { return defaultPrimaryColor }

        var totalRed = 0.0
        var totalGreen = 0.0
        var totalBlue = 0.0
        var sampleCount = 0.0

        for color in colors {
            let uiColor = UIColor(color)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                continue
            }
            totalRed += Double(red)
            totalGreen += Double(green)
            totalBlue += Double(blue)
            sampleCount += 1
        }

        guard sampleCount > 0 else { return defaultPrimaryColor }
        return Color(
            red: totalRed / sampleCount,
            green: totalGreen / sampleCount,
            blue: totalBlue / sampleCount
        )
    }

    private static func contrastingForegroundColor(for color: Color) -> Color {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return defaultButtonTextColor
        }
        let luminance = (0.299 * Double(red)) + (0.587 * Double(green)) + (0.114 * Double(blue))
        return luminance > 0.68 ? .black : .white
    }

    private func migrateScopedSpamFilterMarkedPubkeysIfNeeded() {
        guard !persistedSettings.spamFilterMarkedPubkeys.isEmpty else { return }
        let merged = Self.normalizedNewsAuthorPubkeys(
            sharedSpamFilterMarkedPubkeys + persistedSettings.spamFilterMarkedPubkeys
        )
        if merged != sharedSpamFilterMarkedPubkeys {
            sharedSpamFilterMarkedPubkeys = merged
            persistSharedSpamFilterMarkedPubkeys()
        }
        persistedSettings.spamFilterMarkedPubkeys = []
        persist()
    }

    nonisolated private static func storageKey(for accountStorageID: String?) -> String {
        "\(storageKeyPrefix).\(accountStorageID ?? "anonymous")"
    }

    nonisolated private static func legacyScopedStorageKey(for accountStorageID: String?) -> String {
        "\(legacyScopedStorageKeyPrefix).\(accountStorageID ?? "anonymous")"
    }

    nonisolated private static func decodeSettings(from data: Data?) -> PersistedSettings? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(PersistedSettings.self, from: data)
    }

    nonisolated private static func loadSharedSpamFilterMarkedPubkeys(defaults: UserDefaults) -> [String] {
        normalizedNewsAuthorPubkeys(defaults.stringArray(forKey: sharedSpamFilterMarkedPubkeysKey) ?? [])
    }

    nonisolated private static func loadPersistedSettings(
        defaults: UserDefaults,
        accountStorageID: String?,
        allowLegacyFallback: Bool
    ) -> PersistedSettings {
        if let scopedSettings = decodeSettings(from: defaults.data(forKey: storageKey(for: accountStorageID))) {
            return scopedSettings
        }

        if let legacyScopedSettings = decodeSettings(from: defaults.data(forKey: legacyScopedStorageKey(for: accountStorageID))) {
            if let encoded = try? JSONEncoder().encode(legacyScopedSettings) {
                defaults.set(encoded, forKey: storageKey(for: accountStorageID))
            }
            return legacyScopedSettings
        }

        if allowLegacyFallback,
           let legacySettings = decodeSettings(from: defaults.data(forKey: legacyStorageKey)) {
            return legacySettings
        }

        return PersistedSettings()
    }

    nonisolated private static func migrateLegacySettingsIfNeeded(
        defaults: UserDefaults,
        accountStorageID: String,
        allowLegacyGlobalMigration: Bool
    ) -> PersistedSettings? {
        guard defaults.data(forKey: storageKey(for: accountStorageID)) == nil else { return nil }
        if let legacyScopedSettings = decodeSettings(from: defaults.data(forKey: legacyScopedStorageKey(for: accountStorageID))) {
            guard let encoded = try? JSONEncoder().encode(legacyScopedSettings) else { return legacyScopedSettings }
            defaults.set(encoded, forKey: storageKey(for: accountStorageID))
            return legacyScopedSettings
        }

        guard allowLegacyGlobalMigration else { return nil }
        guard defaults.string(forKey: legacyMigrationAccountKey) == nil else { return nil }
        guard let legacySettings = decodeSettings(from: defaults.data(forKey: legacyStorageKey)) else {
            return nil
        }
        guard let encoded = try? JSONEncoder().encode(legacySettings) else { return legacySettings }

        defaults.set(encoded, forKey: storageKey(for: accountStorageID))
        defaults.set(accountStorageID, forKey: legacyMigrationAccountKey)
        return legacySettings
    }

    nonisolated private static func normalizedSettingsAccountID(_ pubkey: String?) -> String? {
        let normalized = pubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    nonisolated private static func normalizedRelayURL(_ relayURL: URL) -> URL? {
        RelayURLSupport.normalizedURL(from: relayURL.absoluteString)
    }

    nonisolated private static func normalizedRelayURL(from relayInput: String) -> URL? {
        let trimmedInput = relayInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return nil
        }

        let candidate = trimmedInput.contains("://") ? trimmedInput : "wss://\(trimmedInput)"
        guard let relayURL = URL(string: candidate) else {
            return nil
        }
        return normalizedRelayURL(relayURL)
    }

    nonisolated static func clampedWebOfTrustHops(_ value: Int) -> Int {
        min(max(value, 1), 5)
    }

    nonisolated static func clampedLocalCorpusCrawlHopCount(_ value: Int) -> Int {
        min(max(value, 1), 2)
    }

    nonisolated private static func normalizedRelayURLs(_ relayURLs: [URL], fallback: [URL] = []) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            guard let normalized = normalizedRelayURL(relayURL) else { continue }
            let normalizedKey = normalized.absoluteString
            guard seen.insert(normalizedKey).inserted else { continue }
            ordered.append(normalized)
        }

        if ordered.isEmpty, !fallback.isEmpty {
            return normalizedRelayURLs(fallback)
        }

        return ordered
    }

    nonisolated private static func normalizedNewsAuthorPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys {
            let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    nonisolated static func normalizedNewsAuthorPubkey(from rawIdentifier: String) -> String? {
        let normalized = normalizedIdentifier(rawIdentifier)
        guard !normalized.isEmpty else { return nil }

        if normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
            return normalized
        }

        if normalized.hasPrefix("npub1") {
            return PublicKey(npub: normalized)?.hex.lowercased()
        }

        if normalized.hasPrefix("nprofile1") {
            let decoder = MentionMetadataDecoder()
            let metadata = try? decoder.decodedMetadata(from: normalized)
            return metadata?.pubkey?.lowercased()
        }

        return nil
    }

    nonisolated private static func normalizedNewsHashtags(_ hashtags: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for hashtag in hashtags {
            guard let normalized = normalizedNewsHashtag(hashtag) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    nonisolated static func normalizedNewsHashtag(_ rawHashtag: String) -> String? {
        let normalized = rawHashtag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    nonisolated static func normalizedCustomFeedName(_ rawName: String) -> String? {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    nonisolated static func normalizedCustomFeedPhrase(_ rawPhrase: String) -> String? {
        let normalized = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    nonisolated private static func normalizedCustomFeedPhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for phrase in phrases {
            guard let normalized = normalizedCustomFeedPhrase(phrase) else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    nonisolated private static func normalizedCustomFeed(_ feed: CustomFeedDefinition) throws -> CustomFeedDefinition {
        guard let normalizedName = normalizedCustomFeedName(feed.name) else {
            throw AppSettingsError.invalidCustomFeedName
        }

        let normalizedHashtags = normalizedNewsHashtags(feed.hashtags)
        let normalizedAuthors = normalizedNewsAuthorPubkeys(feed.authorPubkeys)
        let normalizedPhrases = normalizedCustomFeedPhrases(feed.phrases)

        guard !normalizedHashtags.isEmpty || !normalizedAuthors.isEmpty || !normalizedPhrases.isEmpty else {
            throw AppSettingsError.customFeedRequiresContent
        }

        let normalizedID = feed.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return CustomFeedDefinition(
            id: normalizedID.isEmpty ? UUID().uuidString.lowercased() : normalizedID,
            name: normalizedName,
            iconSystemName: CustomFeedIconCatalog.normalizedIcon(feed.iconSystemName),
            hashtags: normalizedHashtags,
            authorPubkeys: normalizedAuthors,
            phrases: normalizedPhrases
        )
    }

    nonisolated private static func normalizedCustomFeeds(_ feeds: [CustomFeedDefinition]) -> [CustomFeedDefinition] {
        var seen = Set<String>()
        var ordered: [CustomFeedDefinition] = []

        for feed in feeds {
            guard let normalizedFeed = try? normalizedCustomFeed(feed) else { continue }
            guard seen.insert(normalizedFeed.id).inserted else { continue }
            ordered.append(normalizedFeed)
        }

        return ordered
    }

    nonisolated private static func normalizedIdentifier(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if trimmed.hasPrefix("nostr:") {
            return String(trimmed.dropFirst("nostr:".count))
        }

        return trimmed
    }
}
