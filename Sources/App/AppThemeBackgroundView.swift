import SwiftUI
import UIKit

enum AppThemeBackgroundSpotlight {
    case none
    case feed
    case profile

    func isVisible(for theme: AppThemeOption) -> Bool {
        switch self {
        case .feed, .profile:
            return theme == .holographicLight
        case .none:
            return false
        }
    }
}

struct AppThemeBackgroundSpotlightLayout {
    let placement: AppThemeBackgroundSpotlight
    let size: CGSize

    var primarySize: CGSize {
        switch placement {
        case .feed:
            return CGSize(
                width: max(size.width * 1.24, 460),
                height: max(size.height * 0.34, 280)
            )
        case .profile:
            return CGSize(
                width: max(size.width * 1.48, 540),
                height: max(size.height * 0.48, 360)
            )
        case .none:
            return .zero
        }
    }

    var secondarySize: CGSize {
        switch placement {
        case .feed:
            return CGSize(
                width: max(size.width * 0.92, 320),
                height: max(size.height * 0.24, 210)
            )
        case .profile:
            return CGSize(
                width: max(size.width * 1.06, 380),
                height: max(size.height * 0.34, 260)
            )
        case .none:
            return .zero
        }
    }

    var primaryOffset: CGSize {
        switch placement {
        case .feed:
            return CGSize(width: size.width * 0.46, height: size.height * 0.84)
        case .profile:
            return CGSize(width: -size.width * 0.18, height: size.height * 0.34)
        case .none:
            return .zero
        }
    }

    var secondaryOffset: CGSize {
        switch placement {
        case .feed:
            return CGSize(width: size.width * 0.24, height: size.height * 0.94)
        case .profile:
            return CGSize(width: size.width * 0.28, height: size.height * 0.40)
        case .none:
            return .zero
        }
    }

    var primaryRadius: CGFloat {
        min(primarySize.width, primarySize.height) * 0.42
    }

    var secondaryRadius: CGFloat {
        min(secondarySize.width, secondarySize.height) * 0.40
    }

    func primaryOpacity(for theme: AppThemeOption) -> Double {
        theme.usesDarkGradientTreatment ? 0.11 : 0.10
    }

    func secondaryOpacity(for theme: AppThemeOption) -> Double {
        theme.usesDarkGradientTreatment ? 0.06 : 0.05
    }
}

struct AppThemeBackgroundSpotlightColors {
    let theme: AppThemeOption
    let accentColor: Color

    init(theme: AppThemeOption, accentColor: Color) {
        self.theme = theme
        self.accentColor = accentColor
    }

    var primaryStart: Color {
        blendedAccent(toward: .white, amount: theme.usesDarkGradientTreatment ? 0.06 : 0.16)
    }

    var primaryEnd: Color {
        blendedAccent(toward: .white, amount: theme.usesDarkGradientTreatment ? 0.16 : 0.34)
    }

    var secondaryStart: Color {
        blendedAccent(toward: .white, amount: theme.usesDarkGradientTreatment ? 0.12 : 0.26)
    }

    var secondaryEnd: Color {
        blendedAccent(toward: .white, amount: theme.usesDarkGradientTreatment ? 0.26 : 0.48)
    }

    private func blendedAccent(toward target: UIColor, amount: CGFloat) -> Color {
        let style: UIUserInterfaceStyle = theme.usesDarkGradientTreatment ? .dark : .light
        let resolvedAccent = UIColor(accentColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))

        var accentRed: CGFloat = 0
        var accentGreen: CGFloat = 0
        var accentBlue: CGFloat = 0
        var accentAlpha: CGFloat = 0
        guard resolvedAccent.getRed(&accentRed, green: &accentGreen, blue: &accentBlue, alpha: &accentAlpha) else {
            return accentColor
        }

        var targetRed: CGFloat = 0
        var targetGreen: CGFloat = 0
        var targetBlue: CGFloat = 0
        var targetAlpha: CGFloat = 0
        guard target.getRed(&targetRed, green: &targetGreen, blue: &targetBlue, alpha: &targetAlpha) else {
            return accentColor
        }

        let blend = max(0, min(amount, 1))
        let red = accentRed + ((targetRed - accentRed) * blend)
        let green = accentGreen + ((targetGreen - accentGreen) * blend)
        let blue = accentBlue + ((targetBlue - accentBlue) * blend)

        return Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: 1)
    }
}

struct AppThemeBackgroundView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let holographicSpotlight: AppThemeBackgroundSpotlight

    init(holographicSpotlight: AppThemeBackgroundSpotlight = .none) {
        self.holographicSpotlight = holographicSpotlight
    }

    var body: some View {
        let palette = appSettings.themePalette

        ZStack {
            palette.background

            if appSettings.activeTheme == .dracula {
                LinearGradient(
                    colors: [
                        AppThemePalette.dracula.background,
                        Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 40.0 / 255.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if appSettings.activeTheme == .sakura {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.98),
                        Color(red: 1.0, green: 0.973, blue: 0.987).opacity(0.94),
                        Color(red: 0.989, green: 0.941, blue: 0.970).opacity(0.88)
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        Color(red: 0.984, green: 0.855, blue: 0.928).opacity(0.14),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 340
                )
                .offset(x: -18, y: -36)

                RadialGradient(
                    colors: [
                        Color(red: 1.0, green: 0.940, blue: 0.972).opacity(0.10),
                        Color.clear
                    ],
                    center: .topTrailing,
                    startRadius: 18,
                    endRadius: 300
                )
                .offset(x: 16, y: -26)
            } else if appSettings.activeTheme == .gamer {
                LinearGradient(
                    colors: [
                        AppThemePalette.gamer.background.opacity(0.99),
                        AppThemePalette.gamer.chromeBackground.opacity(0.98),
                        Color(red: 0.024, green: 0.043, blue: 0.075).opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        Color(red: 0.553, green: 0.408, blue: 1.0).opacity(0.08),
                        Color.clear
                    ],
                    center: .bottomTrailing,
                    startRadius: 22,
                    endRadius: 360
                )
                .offset(x: 30, y: 54)
            }

            if holographicSpotlight.isVisible(for: appSettings.activeTheme) {
                HolographicSpotlightAccent(
                    theme: appSettings.activeTheme,
                    accentColor: appSettings.primaryColor,
                    placement: holographicSpotlight
                )
            }
        }
    }
}

private struct HolographicSpotlightAccent: View {
    let theme: AppThemeOption
    let accentColor: Color
    let placement: AppThemeBackgroundSpotlight

    var body: some View {
        GeometryReader { geometry in
            let layout = AppThemeBackgroundSpotlightLayout(
                placement: placement,
                size: geometry.size
            )

            ZStack {
                primarySpotlight(layout: layout)
                secondarySpotlight(layout: layout)
            }
            .allowsHitTesting(false)
        }
    }

    private func primarySpotlight(layout: AppThemeBackgroundSpotlightLayout) -> some View {
        let opacity = layout.primaryOpacity(for: theme)
        let colors = AppThemeBackgroundSpotlightColors(theme: theme, accentColor: accentColor)

        return RadialGradient(
            colors: [
                colors.primaryStart.opacity(opacity),
                colors.primaryEnd.opacity(opacity * 0.44),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: layout.primaryRadius
        )
        .frame(width: layout.primarySize.width, height: layout.primarySize.height)
        .offset(layout.primaryOffset)
    }

    private func secondarySpotlight(layout: AppThemeBackgroundSpotlightLayout) -> some View {
        let opacity = layout.secondaryOpacity(for: theme)
        let colors = AppThemeBackgroundSpotlightColors(theme: theme, accentColor: accentColor)

        return RadialGradient(
            colors: [
                colors.secondaryStart.opacity(opacity),
                colors.secondaryEnd.opacity(opacity * 0.34),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: layout.secondaryRadius
        )
        .frame(width: layout.secondarySize.width, height: layout.secondarySize.height)
        .offset(layout.secondaryOffset)
    }
}
