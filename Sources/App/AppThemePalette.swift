import SwiftUI

struct AppThemeCapsuleTabStyle {
    let background: Color
    let border: Color
    let foreground: Color
    let selectedBackground: Color
    let selectedBorder: Color
    let selectedForeground: Color
}

struct AppThemeProfileActionStyle {
    let background: Color
    let border: Color
    let foreground: Color
    let primaryBackground: Color
    let primaryBorder: Color
    let primaryForeground: Color
    let bannerBackground: Color
    let bannerBorder: Color
    let bannerForeground: Color
}

struct AppThemePollStyle {
    let cardBackground: Color
    let cardBorder: Color
    let metadataForeground: Color
    let optionBackground: Color
    let optionResultBackground: Color
    let optionBorder: Color
    let optionSelectedBackground: Color
    let optionSelectedBorder: Color
    let optionWinningBackground: Color
    let optionWinningBorder: Color
    let imagePlaceholderBackground: Color
    let imagePlaceholderForeground: Color
    let neutralBadgeBackground: Color
    let neutralBadgeForeground: Color
    let refreshButtonBackground: Color
    let refreshButtonForeground: Color
}

struct AppThemeFeedCardStyle {
    let backgroundTop: Color
    let backgroundBottom: Color
    let border: Color
    let highlight: Color
    let shadow: Color
}

struct AppThemePalette {
    private static let sakuraPinkTint = Color(red: 0.992, green: 0.647, blue: 0.835) // #FDA5D5
    private static let sakuraPrimary = Color(red: 1.0, green: 0.404, blue: 0.941)
    private static let sakuraBorder = Color(red: 1.0, green: 0.882, blue: 0.945) // #FFE1F1
    private static let sakuraSoftWhite = Color(red: 1.0, green: 0.985, blue: 0.992)
    private static let sakuraPetalWash = Color(red: 1.0, green: 0.947, blue: 0.979)
    private static let draculaBackground = Color(red: 44.0 / 255.0, green: 45.0 / 255.0, blue: 60.0 / 255.0) // #2C2D3C
    private static let draculaFloating = Color(red: 0.204, green: 0.216, blue: 0.275) // #343746
    private static let draculaRaised = Color(red: 0.259, green: 0.278, blue: 0.353) // #44475A
    private static let draculaBorder = Color.white.opacity(0.07) // rgba(255, 255, 255, 0.07)
    private static let draculaChrome = Color(red: 43.0 / 255.0, green: 44.0 / 255.0, blue: 58.0 / 255.0) // #2B2C3A
    private static let draculaNavigation = Color(red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 43.0 / 255.0) // #20202B
    private static let draculaDarker = Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 40.0 / 255.0) // #1E1E28
    private static let draculaForeground = Color(red: 0.973, green: 0.973, blue: 0.949) // #F8F8F2
    private static let draculaComment = Color(red: 0.537, green: 0.549, blue: 0.675) // #898CAC
    private static let draculaGreen = Color(red: 0.314, green: 0.980, blue: 0.482) // #50FA7B
    private static let draculaCyan = Color(red: 0.545, green: 0.914, blue: 0.992) // #8BE9FD
    private static let draculaPurple = Color(red: 0.773, green: 0.565, blue: 1.0) // #C590FF
    private static let draculaPink = Color(red: 1.0, green: 0.475, blue: 0.776) // #FF79C6
    private static let draculaOrange = Color(red: 1.0, green: 0.722, blue: 0.424) // #FFB86C
    private static let gamerBackground = Color(red: 0.035, green: 0.063, blue: 0.106) // #09101B
    private static let gamerChrome = Color(red: 0.055, green: 0.086, blue: 0.141) // #0E1624
    private static let gamerFloating = Color(red: 0.071, green: 0.114, blue: 0.188) // #121D30
    private static let gamerRaised = Color(red: 0.094, green: 0.153, blue: 0.263) // #182743
    private static let gamerBorder = Color(red: 0.329, green: 0.920, blue: 0.996).opacity(0.10)
    private static let gamerForeground = Color(red: 0.933, green: 0.957, blue: 0.988) // #EEF4FC
    private static let gamerMuted = Color(red: 0.592, green: 0.735, blue: 0.976) // #97BBF9
    private static let gamerPurple = Color(red: 0.553, green: 0.408, blue: 1.0) // #8D68FF
    private static let gamerCyan = Color(red: 0.329, green: 0.920, blue: 0.996) // #54EBFE
    private static let gamerGreen = Color(red: 0.561, green: 1.0, blue: 0.369) // #8FFF5E
    private static let gamerPink = Color(red: 1.0, green: 0.412, blue: 0.741) // #FF69BD
    private static let gamerOrange = Color(red: 1.0, green: 0.694, blue: 0.333) // #FFB155
    private static let holographicLightBackground = Color(red: 0.992, green: 0.996, blue: 1.0)
    private static let holographicLightChrome = Color(red: 0.988, green: 0.994, blue: 1.0)
    private static let holographicLightSurface = Color(red: 0.957, green: 0.982, blue: 1.0)
    private static let holographicLightRaised = Color(red: 0.976, green: 0.966, blue: 1.0)
    private static let holographicLightBorder = Color.black.opacity(0.04)
    private static let holographicLightLinkPreviewBorder = Color.black.opacity(0.08)
    private static let holographicLightForeground = Color(red: 0.055, green: 0.075, blue: 0.125)
    private static let holographicLightMuted = Color(red: 0.365, green: 0.418, blue: 0.540)
    private static let holographicDarkBackground = Color(red: 0.035, green: 0.043, blue: 0.075)
    private static let holographicDarkChrome = Color(red: 0.055, green: 0.067, blue: 0.118)
    private static let holographicDarkSurface = Color(red: 0.080, green: 0.098, blue: 0.164)
    private static let holographicDarkRaised = Color(red: 0.110, green: 0.129, blue: 0.214)
    private static let holographicDarkBorder = Color(red: 0.690, green: 0.604, blue: 1.0).opacity(0.12)
    private static let holographicDarkForeground = Color(red: 0.940, green: 0.970, blue: 1.0)
    private static let holographicDarkMuted = Color(red: 0.640, green: 0.735, blue: 0.890)
    private static let holographicBlue = Color(red: 0.235, green: 0.612, blue: 1.0)
    private static let holographicCyan = Color(red: 0.380, green: 0.906, blue: 1.0)
    private static let holographicLavender = Color(red: 0.690, green: 0.604, blue: 1.0)
    private static let holographicPink = Color(red: 1.0, green: 0.560, blue: 0.780)
    private static let holographicMint = Color(red: 0.580, green: 1.0, blue: 0.780)
    private static let blackSheet = Color(red: 0.082, green: 0.082, blue: 0.082) // #151515
    private static let blackSheetCard = Color(red: 0.137, green: 0.137, blue: 0.137) // #232323
    private static let blackSheetCardBorder = Color(red: 0.235, green: 0.235, blue: 0.235) // #3C3C3C
    private static let darkBackground = Color(red: 23.0 / 255.0, green: 23.0 / 255.0, blue: 25.0 / 255.0) // #171719
    private static let darkNavigation = Color(red: 19.0 / 255.0, green: 19.0 / 255.0, blue: 20.0 / 255.0) // #131314
    private static let darkSurface = Color(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0) // #292929
    private static let darkRaised = Color(red: 58.0 / 255.0, green: 58.0 / 255.0, blue: 58.0 / 255.0) // #3A3A3A
    private static let darkBorder = Color(red: 75.0 / 255.0, green: 75.0 / 255.0, blue: 75.0 / 255.0) // #4B4B4B
    private static let darkForeground = Color(red: 226.0 / 255.0, green: 226.0 / 255.0, blue: 227.0 / 255.0) // #E2E2E3
    private static let darkSecondaryForeground = Color(red: 211.0 / 255.0, green: 211.0 / 255.0, blue: 213.0 / 255.0) // #D3D3D5
    private static let darkMuted = Color(red: 125.0 / 255.0, green: 125.0 / 255.0, blue: 126.0 / 255.0) // #7D7D7E
    private static let darkIconMuted = Color(red: 128.0 / 255.0, green: 128.0 / 255.0, blue: 137.0 / 255.0) // #808089
    private static let whiteSurface = Color(red: 0.965, green: 0.965, blue: 0.972)
    private static let whiteRaised = Color(red: 0.945, green: 0.945, blue: 0.955)
    private static let whiteBorder = Color.black.opacity(0.08)
    private static let whiteStrongBorder = Color.black.opacity(0.14)
    private static let whiteMuted = Color.black.opacity(0.58)
    private static let whitePrimary = Color.black.opacity(0.88)

    private static func adaptiveSeparator(
        lightMultiplier: CGFloat = 1,
        darkAlpha: CGFloat
    ) -> Color {
        Color(
            UIColor { traits in
                let resolvedSeparator = UIColor.separator.resolvedColor(with: traits)
                if traits.userInterfaceStyle == .dark {
                    return UIColor.white.withAlphaComponent(darkAlpha)
                }
                let scaledAlpha = min(max(resolvedSeparator.cgColor.alpha * lightMultiplier, 0), 1)
                return resolvedSeparator.withAlphaComponent(scaledAlpha)
            }
        )
    }

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }

    private static func adaptiveColor(light: Color, dark: Color) -> Color {
        Color(
            UIColor { traits in
                let source = traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
                return source.resolvedColor(with: traits)
            }
        )
    }

    private static func adaptiveCapsuleTabStyle(
        light: AppThemeCapsuleTabStyle?,
        dark: AppThemeCapsuleTabStyle?
    ) -> AppThemeCapsuleTabStyle? {
        guard let light, let dark else {
            return light ?? dark
        }

        return AppThemeCapsuleTabStyle(
            background: adaptiveColor(light: light.background, dark: dark.background),
            border: adaptiveColor(light: light.border, dark: dark.border),
            foreground: adaptiveColor(light: light.foreground, dark: dark.foreground),
            selectedBackground: adaptiveColor(light: light.selectedBackground, dark: dark.selectedBackground),
            selectedBorder: adaptiveColor(light: light.selectedBorder, dark: dark.selectedBorder),
            selectedForeground: adaptiveColor(light: light.selectedForeground, dark: dark.selectedForeground)
        )
    }

    private static func adaptiveProfileActionStyle(
        light: AppThemeProfileActionStyle?,
        dark: AppThemeProfileActionStyle?
    ) -> AppThemeProfileActionStyle? {
        guard let light, let dark else {
            return light ?? dark
        }

        return AppThemeProfileActionStyle(
            background: adaptiveColor(light: light.background, dark: dark.background),
            border: adaptiveColor(light: light.border, dark: dark.border),
            foreground: adaptiveColor(light: light.foreground, dark: dark.foreground),
            primaryBackground: adaptiveColor(light: light.primaryBackground, dark: dark.primaryBackground),
            primaryBorder: adaptiveColor(light: light.primaryBorder, dark: dark.primaryBorder),
            primaryForeground: adaptiveColor(light: light.primaryForeground, dark: dark.primaryForeground),
            bannerBackground: adaptiveColor(light: light.bannerBackground, dark: dark.bannerBackground),
            bannerBorder: adaptiveColor(light: light.bannerBorder, dark: dark.bannerBorder),
            bannerForeground: adaptiveColor(light: light.bannerForeground, dark: dark.bannerForeground)
        )
    }

    private static func adaptivePollStyle(
        light: AppThemePollStyle?,
        dark: AppThemePollStyle?
    ) -> AppThemePollStyle? {
        guard let light, let dark else {
            return light ?? dark
        }

        return AppThemePollStyle(
            cardBackground: adaptiveColor(light: light.cardBackground, dark: dark.cardBackground),
            cardBorder: adaptiveColor(light: light.cardBorder, dark: dark.cardBorder),
            metadataForeground: adaptiveColor(light: light.metadataForeground, dark: dark.metadataForeground),
            optionBackground: adaptiveColor(light: light.optionBackground, dark: dark.optionBackground),
            optionResultBackground: adaptiveColor(light: light.optionResultBackground, dark: dark.optionResultBackground),
            optionBorder: adaptiveColor(light: light.optionBorder, dark: dark.optionBorder),
            optionSelectedBackground: adaptiveColor(light: light.optionSelectedBackground, dark: dark.optionSelectedBackground),
            optionSelectedBorder: adaptiveColor(light: light.optionSelectedBorder, dark: dark.optionSelectedBorder),
            optionWinningBackground: adaptiveColor(light: light.optionWinningBackground, dark: dark.optionWinningBackground),
            optionWinningBorder: adaptiveColor(light: light.optionWinningBorder, dark: dark.optionWinningBorder),
            imagePlaceholderBackground: adaptiveColor(light: light.imagePlaceholderBackground, dark: dark.imagePlaceholderBackground),
            imagePlaceholderForeground: adaptiveColor(light: light.imagePlaceholderForeground, dark: dark.imagePlaceholderForeground),
            neutralBadgeBackground: adaptiveColor(light: light.neutralBadgeBackground, dark: dark.neutralBadgeBackground),
            neutralBadgeForeground: adaptiveColor(light: light.neutralBadgeForeground, dark: dark.neutralBadgeForeground),
            refreshButtonBackground: adaptiveColor(light: light.refreshButtonBackground, dark: dark.refreshButtonBackground),
            refreshButtonForeground: adaptiveColor(light: light.refreshButtonForeground, dark: dark.refreshButtonForeground)
        )
    }

    private static func adaptiveFeedCardStyle(
        light: AppThemeFeedCardStyle?,
        dark: AppThemeFeedCardStyle?
    ) -> AppThemeFeedCardStyle? {
        guard let light, let dark else {
            return light ?? dark
        }

        return AppThemeFeedCardStyle(
            backgroundTop: adaptiveColor(light: light.backgroundTop, dark: dark.backgroundTop),
            backgroundBottom: adaptiveColor(light: light.backgroundBottom, dark: dark.backgroundBottom),
            border: adaptiveColor(light: light.border, dark: dark.border),
            highlight: adaptiveColor(light: light.highlight, dark: dark.highlight),
            shadow: adaptiveColor(light: light.shadow, dark: dark.shadow)
        )
    }

    private static func tintedLightColor(
        base: Color,
        accent: Color,
        amount: CGFloat,
        opacity: CGFloat = 1
    ) -> Color {
        let baseColor = UIColor(base).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let accentColor = UIColor(accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))

        var baseRed: CGFloat = 0
        var baseGreen: CGFloat = 0
        var baseBlue: CGFloat = 0
        var baseAlpha: CGFloat = 0
        guard baseColor.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha) else {
            return accent.opacity(opacity)
        }

        var accentRed: CGFloat = 0
        var accentGreen: CGFloat = 0
        var accentBlue: CGFloat = 0
        var accentAlpha: CGFloat = 0
        guard accentColor.getRed(&accentRed, green: &accentGreen, blue: &accentBlue, alpha: &accentAlpha) else {
            return accent.opacity(opacity)
        }

        let blend = max(0, min(amount, 1))
        let red = baseRed + ((accentRed - baseRed) * blend)
        let green = baseGreen + ((accentGreen - baseGreen) * blend)
        let blue = baseBlue + ((accentBlue - baseBlue) * blend)

        return Color(
            .sRGB,
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            opacity: Double(opacity)
        )
    }

    private static func adaptivePalette(light: AppThemePalette, dark: AppThemePalette) -> AppThemePalette {
        AppThemePalette(
            background: adaptiveColor(light: light.background, dark: dark.background),
            chromeBackground: adaptiveColor(light: light.chromeBackground, dark: dark.chromeBackground),
            chromeBorder: adaptiveColor(light: light.chromeBorder, dark: dark.chromeBorder),
            mutedForeground: adaptiveColor(light: light.mutedForeground, dark: dark.mutedForeground),
            foreground: adaptiveColor(light: light.foreground, dark: dark.foreground),
            secondaryForeground: adaptiveColor(light: light.secondaryForeground, dark: dark.secondaryForeground),
            tertiaryForeground: adaptiveColor(light: light.tertiaryForeground, dark: dark.tertiaryForeground),
            inverseForeground: adaptiveColor(light: light.inverseForeground, dark: dark.inverseForeground),
            placeholderForeground: adaptiveColor(light: light.placeholderForeground, dark: dark.placeholderForeground),
            iconForeground: adaptiveColor(light: light.iconForeground, dark: dark.iconForeground),
            iconMutedForeground: adaptiveColor(light: light.iconMutedForeground, dark: dark.iconMutedForeground),
            secondaryBackground: adaptiveColor(light: light.secondaryBackground, dark: dark.secondaryBackground),
            quoteBackground: adaptiveColor(light: light.quoteBackground, dark: dark.quoteBackground),
            groupedBackground: adaptiveColor(light: light.groupedBackground, dark: dark.groupedBackground),
            secondaryGroupedBackground: adaptiveColor(light: light.secondaryGroupedBackground, dark: dark.secondaryGroupedBackground),
            navigationBackground: adaptiveColor(light: light.navigationBackground, dark: dark.navigationBackground),
            navigationControlBackground: adaptiveColor(light: light.navigationControlBackground, dark: dark.navigationControlBackground),
            sheetBackground: adaptiveColor(light: light.sheetBackground, dark: dark.sheetBackground),
            sheetCardBackground: adaptiveColor(light: light.sheetCardBackground, dark: dark.sheetCardBackground),
            sheetCardBorder: adaptiveColor(light: light.sheetCardBorder, dark: dark.sheetCardBorder),
            sheetInsetBackground: adaptiveColor(light: light.sheetInsetBackground, dark: dark.sheetInsetBackground),
            modalBackground: adaptiveColor(light: light.modalBackground, dark: dark.modalBackground),
            elevatedBackground: adaptiveColor(light: light.elevatedBackground, dark: dark.elevatedBackground),
            overlayBackground: adaptiveColor(light: light.overlayBackground, dark: dark.overlayBackground),
            secondaryFill: adaptiveColor(light: light.secondaryFill, dark: dark.secondaryFill),
            tertiaryFill: adaptiveColor(light: light.tertiaryFill, dark: dark.tertiaryFill),
            separator: adaptiveColor(light: light.separator, dark: dark.separator),
            successForeground: adaptiveColor(light: light.successForeground, dark: dark.successForeground),
            warningForeground: adaptiveColor(light: light.warningForeground, dark: dark.warningForeground),
            errorForeground: adaptiveColor(light: light.errorForeground, dark: dark.errorForeground),
            linkPreviewBackground: adaptiveColor(light: light.linkPreviewBackground, dark: dark.linkPreviewBackground),
            linkPreviewBorder: adaptiveColor(light: light.linkPreviewBorder, dark: dark.linkPreviewBorder),
            articlePreviewBackgroundTop: adaptiveColor(light: light.articlePreviewBackgroundTop, dark: dark.articlePreviewBackgroundTop),
            articlePreviewBackgroundBottom: adaptiveColor(light: light.articlePreviewBackgroundBottom, dark: dark.articlePreviewBackgroundBottom),
            articlePreviewBorder: adaptiveColor(light: light.articlePreviewBorder, dark: dark.articlePreviewBorder),
            capsuleTabStyle: adaptiveCapsuleTabStyle(light: light.capsuleTabStyle, dark: dark.capsuleTabStyle),
            profileActionStyle: adaptiveProfileActionStyle(light: light.profileActionStyle, dark: dark.profileActionStyle),
            pollStyle: adaptivePollStyle(light: light.pollStyle, dark: dark.pollStyle),
            feedCardStyle: adaptiveFeedCardStyle(light: light.feedCardStyle, dark: dark.feedCardStyle)
        )
    }

    let background: Color
    let chromeBackground: Color
    let chromeBorder: Color
    let mutedForeground: Color
    let foreground: Color
    let secondaryForeground: Color
    let tertiaryForeground: Color
    let inverseForeground: Color
    let placeholderForeground: Color
    let iconForeground: Color
    let iconMutedForeground: Color
    let secondaryBackground: Color
    let quoteBackground: Color
    let groupedBackground: Color
    let secondaryGroupedBackground: Color
    let navigationBackground: Color
    let navigationControlBackground: Color
    let sheetBackground: Color
    let sheetCardBackground: Color
    let sheetCardBorder: Color
    let sheetInsetBackground: Color
    let modalBackground: Color
    let elevatedBackground: Color
    let overlayBackground: Color
    let secondaryFill: Color
    let tertiaryFill: Color
    let separator: Color
    let successForeground: Color
    let warningForeground: Color
    let errorForeground: Color
    let linkPreviewBackground: Color
    let linkPreviewBorder: Color
    let articlePreviewBackgroundTop: Color
    let articlePreviewBackgroundBottom: Color
    let articlePreviewBorder: Color
    let capsuleTabStyle: AppThemeCapsuleTabStyle?
    let profileActionStyle: AppThemeProfileActionStyle?
    let pollStyle: AppThemePollStyle?
    var feedCardStyle: AppThemeFeedCardStyle? = nil

    func applying(
        holographicGradient option: HolographicGradientOption,
        for theme: AppThemeOption
    ) -> AppThemePalette {
        let accents = option.accentPalette(for: theme)
        let border = option.borderColor(for: theme)
        let selectedBackground = accents.primary.opacity(theme.usesDarkGradientTreatment ? 0.18 : 0.14)
        let supportingBackground = accents.secondary.opacity(theme.usesDarkGradientTreatment ? 0.16 : 0.14)
        let tertiaryFill = accents.tertiary.opacity(theme.usesDarkGradientTreatment ? 0.18 : 0.14)
        let primaryForeground = theme.usesDarkGradientTreatment ? foreground : .white

        let capsuleTabStyle = capsuleTabStyle.map { style in
            AppThemeCapsuleTabStyle(
                background: style.background,
                border: border,
                foreground: style.foreground,
                selectedBackground: selectedBackground,
                selectedBorder: border,
                selectedForeground: style.selectedForeground
            )
        }

        let profileActionStyle = profileActionStyle.map { style in
            AppThemeProfileActionStyle(
                background: style.background,
                border: border,
                foreground: style.foreground,
                primaryBackground: selectedBackground,
                primaryBorder: border,
                primaryForeground: primaryForeground,
                bannerBackground: style.bannerBackground,
                bannerBorder: border,
                bannerForeground: style.bannerForeground
            )
        }

        let pollStyle = pollStyle.map { style in
            AppThemePollStyle(
                cardBackground: style.cardBackground,
                cardBorder: border,
                metadataForeground: style.metadataForeground,
                optionBackground: style.optionBackground,
                optionResultBackground: style.optionResultBackground,
                optionBorder: border,
                optionSelectedBackground: selectedBackground,
                optionSelectedBorder: border,
                optionWinningBackground: supportingBackground,
                optionWinningBorder: border,
                imagePlaceholderBackground: style.imagePlaceholderBackground,
                imagePlaceholderForeground: style.imagePlaceholderForeground,
                neutralBadgeBackground: style.neutralBadgeBackground,
                neutralBadgeForeground: style.neutralBadgeForeground,
                refreshButtonBackground: selectedBackground,
                refreshButtonForeground: theme.usesDarkGradientTreatment ? accents.secondary : accents.primary
            )
        }

        let feedCardStyle = feedCardStyle.map { style in
            AppThemeFeedCardStyle(
                backgroundTop: style.backgroundTop,
                backgroundBottom: style.backgroundBottom,
                border: border,
                highlight: accents.primary.opacity(theme.usesDarkGradientTreatment ? 0.28 : 0.34),
                shadow: accents.shadow.opacity(theme.usesDarkGradientTreatment ? 0.14 : 0.12)
            )
        }

        return AppThemePalette(
            background: background,
            chromeBackground: chromeBackground,
            chromeBorder: border,
            mutedForeground: mutedForeground,
            foreground: foreground,
            secondaryForeground: secondaryForeground,
            tertiaryForeground: tertiaryForeground,
            inverseForeground: inverseForeground,
            placeholderForeground: placeholderForeground,
            iconForeground: iconForeground,
            iconMutedForeground: iconMutedForeground,
            secondaryBackground: secondaryBackground,
            quoteBackground: quoteBackground,
            groupedBackground: groupedBackground,
            secondaryGroupedBackground: secondaryGroupedBackground,
            navigationBackground: navigationBackground,
            navigationControlBackground: navigationControlBackground,
            sheetBackground: sheetBackground,
            sheetCardBackground: sheetCardBackground,
            sheetCardBorder: border,
            sheetInsetBackground: sheetInsetBackground,
            modalBackground: modalBackground,
            elevatedBackground: elevatedBackground,
            overlayBackground: overlayBackground,
            secondaryFill: selectedBackground,
            tertiaryFill: tertiaryFill,
            separator: border,
            successForeground: successForeground,
            warningForeground: warningForeground,
            errorForeground: errorForeground,
            linkPreviewBackground: linkPreviewBackground,
            linkPreviewBorder: border,
            articlePreviewBackgroundTop: articlePreviewBackgroundTop,
            articlePreviewBackgroundBottom: articlePreviewBackgroundBottom,
            articlePreviewBorder: border,
            capsuleTabStyle: capsuleTabStyle,
            profileActionStyle: profileActionStyle,
            pollStyle: pollStyle,
            feedCardStyle: feedCardStyle
        )
    }

    func applyingLightPrimaryAccent(_ accent: Color) -> AppThemePalette {
        let groupedWash = Self.tintedLightColor(
            base: .white,
            accent: accent,
            amount: 0.018,
            opacity: 0.985
        )
        let backgroundWash = Self.tintedLightColor(
            base: .white,
            accent: accent,
            amount: 0.10
        )
        let surfaceWash = Self.tintedLightColor(
            base: Self.holographicLightSurface,
            accent: accent,
            amount: 0.14
        )
        let raisedWash = Self.tintedLightColor(
            base: Self.holographicLightRaised,
            accent: accent,
            amount: 0.16
        )
        let border = Color.black.opacity(0.04)
        let strongBorder = border
        let secondaryFill = Self.tintedLightColor(
            base: .white,
            accent: accent,
            amount: 0.72,
            opacity: 0.12
        )
        let tertiaryFill = Self.tintedLightColor(
            base: .white,
            accent: accent,
            amount: 0.56,
            opacity: 0.10
        )
        let selectedBackground = Self.tintedLightColor(
            base: .white,
            accent: accent,
            amount: 0.72,
            opacity: 0.16
        )
        let supportingBackground = Self.tintedLightColor(
            base: .white,
            accent: accent,
            amount: 0.58,
            opacity: 0.14
        )
        let winningBackground = Self.tintedLightColor(
            base: .white,
            accent: accent,
            amount: 0.62,
            opacity: 0.18
        )
        let winningBorder = border

        return AppThemePalette(
            background: .white,
            chromeBackground: .white,
            chromeBorder: border,
            mutedForeground: mutedForeground,
            foreground: foreground,
            secondaryForeground: secondaryForeground,
            tertiaryForeground: tertiaryForeground,
            inverseForeground: inverseForeground,
            placeholderForeground: placeholderForeground,
            iconForeground: iconForeground,
            iconMutedForeground: iconMutedForeground,
            secondaryBackground: surfaceWash,
            quoteBackground: .white,
            groupedBackground: groupedWash,
            secondaryGroupedBackground: surfaceWash,
            navigationBackground: .white,
            navigationControlBackground: .white,
            sheetBackground: .white,
            sheetCardBackground: .white,
            sheetCardBorder: border,
            sheetInsetBackground: surfaceWash,
            modalBackground: .white,
            elevatedBackground: raisedWash,
            overlayBackground: overlayBackground,
            secondaryFill: secondaryFill,
            tertiaryFill: tertiaryFill,
            separator: border,
            successForeground: successForeground,
            warningForeground: warningForeground,
            errorForeground: errorForeground,
            linkPreviewBackground: .white,
            linkPreviewBorder: Self.holographicLightLinkPreviewBorder,
            articlePreviewBackgroundTop: .white,
            articlePreviewBackgroundBottom: backgroundWash,
            articlePreviewBorder: border,
            capsuleTabStyle: capsuleTabStyle.map { style in
                AppThemeCapsuleTabStyle(
                    background: style.background,
                    border: border,
                    foreground: style.foreground,
                    selectedBackground: selectedBackground,
                    selectedBorder: strongBorder,
                    selectedForeground: accent
                )
            },
            profileActionStyle: profileActionStyle.map { style in
                AppThemeProfileActionStyle(
                    background: style.background,
                    border: border,
                    foreground: style.foreground,
                    primaryBackground: selectedBackground,
                    primaryBorder: strongBorder,
                    primaryForeground: accent,
                    bannerBackground: style.bannerBackground,
                    bannerBorder: border,
                    bannerForeground: style.bannerForeground
                )
            },
            pollStyle: pollStyle.map { style in
                AppThemePollStyle(
                    cardBackground: style.cardBackground,
                    cardBorder: border,
                    metadataForeground: style.metadataForeground,
                    optionBackground: style.optionBackground,
                    optionResultBackground: style.optionResultBackground,
                    optionBorder: border,
                    optionSelectedBackground: selectedBackground,
                    optionSelectedBorder: strongBorder,
                    optionWinningBackground: winningBackground,
                    optionWinningBorder: winningBorder,
                    imagePlaceholderBackground: style.imagePlaceholderBackground,
                    imagePlaceholderForeground: style.imagePlaceholderForeground,
                    neutralBadgeBackground: style.neutralBadgeBackground,
                    neutralBadgeForeground: style.neutralBadgeForeground,
                    refreshButtonBackground: supportingBackground,
                    refreshButtonForeground: accent
                )
            },
            feedCardStyle: feedCardStyle
        )
    }

    static let black = AppThemePalette(
        background: .black,
        chromeBackground: .black,
        chromeBorder: Color.white.opacity(0.08),
        mutedForeground: Color.white.opacity(0.58),
        foreground: Color.white.opacity(0.95),
        secondaryForeground: Color.white.opacity(0.58),
        tertiaryForeground: Color.white.opacity(0.42),
        inverseForeground: .black,
        placeholderForeground: Color.white.opacity(0.28),
        iconForeground: Color.white.opacity(0.95),
        iconMutedForeground: Color.white.opacity(0.58),
        secondaryBackground: Color(red: 0.11, green: 0.11, blue: 0.13),
        quoteBackground: Color(red: 0.11, green: 0.11, blue: 0.13),
        groupedBackground: .black,
        secondaryGroupedBackground: Self.blackSheet,
        navigationBackground: .black,
        navigationControlBackground: Self.blackSheetCard,
        sheetBackground: Self.blackSheet,
        sheetCardBackground: Self.blackSheetCard,
        sheetCardBorder: Self.blackSheetCardBorder,
        sheetInsetBackground: Self.blackSheet,
        modalBackground: Self.blackSheet,
        elevatedBackground: Color(red: 0.11, green: 0.11, blue: 0.13),
        overlayBackground: Color.black.opacity(0.34),
        secondaryFill: Color.white.opacity(0.10),
        tertiaryFill: Color.white.opacity(0.06),
        separator: Color.white.opacity(0.13),
        successForeground: .green,
        warningForeground: .orange,
        errorForeground: .red,
        linkPreviewBackground: Color(red: 0.11, green: 0.11, blue: 0.13),
        linkPreviewBorder: Color.white.opacity(0.13),
        articlePreviewBackgroundTop: Color(red: 0.11, green: 0.11, blue: 0.13),
        articlePreviewBackgroundBottom: .black,
        articlePreviewBorder: Color.white.opacity(0.15),
        capsuleTabStyle: nil,
        profileActionStyle: nil,
        pollStyle: nil
    )

    static let white = AppThemePalette(
        background: Color.white,
        chromeBackground: Color.white,
        chromeBorder: Self.holographicLightBorder,
        mutedForeground: Color.black.opacity(0.45),
        foreground: Self.whitePrimary,
        secondaryForeground: Self.whiteMuted,
        tertiaryForeground: Color.black.opacity(0.34),
        inverseForeground: .white,
        placeholderForeground: Color.black.opacity(0.28),
        iconForeground: Self.whitePrimary,
        iconMutedForeground: Self.whiteMuted,
        secondaryBackground: Color(red: 0.96, green: 0.96, blue: 0.97),
        quoteBackground: Color(red: 0.96, green: 0.96, blue: 0.97),
        groupedBackground: Color(red: 0.98, green: 0.98, blue: 0.985),
        secondaryGroupedBackground: Color(red: 0.955, green: 0.955, blue: 0.965),
        navigationBackground: .white,
        navigationControlBackground: Color(red: 0.96, green: 0.96, blue: 0.97),
        sheetBackground: Self.whiteRaised,
        sheetCardBackground: .white,
        sheetCardBorder: Self.holographicLightBorder,
        sheetInsetBackground: Self.whiteSurface,
        modalBackground: .white,
        elevatedBackground: Color(red: 0.96, green: 0.96, blue: 0.97),
        overlayBackground: Color.black.opacity(0.18),
        secondaryFill: Color.black.opacity(0.08),
        tertiaryFill: Color.black.opacity(0.05),
        separator: Self.holographicLightBorder,
        successForeground: .green,
        warningForeground: .orange,
        errorForeground: .red,
        linkPreviewBackground: Color(red: 0.96, green: 0.96, blue: 0.97),
        linkPreviewBorder: Self.whiteBorder,
        articlePreviewBackgroundTop: Color(red: 0.96, green: 0.96, blue: 0.97),
        articlePreviewBackgroundBottom: .white,
        articlePreviewBorder: Self.holographicLightBorder,
        capsuleTabStyle: AppThemeCapsuleTabStyle(
            background: Self.whiteSurface,
            border: Self.holographicLightBorder,
            foreground: Self.whiteMuted,
            selectedBackground: .white,
            selectedBorder: Self.whiteStrongBorder,
            selectedForeground: Self.whitePrimary
        ),
        profileActionStyle: AppThemeProfileActionStyle(
            background: Self.whiteSurface,
            border: Self.holographicLightBorder,
            foreground: Self.whitePrimary,
            primaryBackground: .white,
            primaryBorder: Self.whiteStrongBorder,
            primaryForeground: .black,
            bannerBackground: Color.white.opacity(0.96),
            bannerBorder: Self.holographicLightBorder,
            bannerForeground: Self.whitePrimary
        ),
        pollStyle: AppThemePollStyle(
            cardBackground: .white,
            cardBorder: Self.holographicLightBorder,
            metadataForeground: Self.whiteMuted,
            optionBackground: Self.whiteSurface,
            optionResultBackground: Self.whiteRaised,
            optionBorder: Self.holographicLightBorder,
            optionSelectedBackground: Color.black.opacity(0.06),
            optionSelectedBorder: Color.black.opacity(0.12),
            optionWinningBackground: Color.black.opacity(0.08),
            optionWinningBorder: Self.whiteStrongBorder,
            imagePlaceholderBackground: Self.whiteRaised,
            imagePlaceholderForeground: Self.whiteMuted,
            neutralBadgeBackground: Self.whiteRaised,
            neutralBadgeForeground: Self.whiteMuted,
            refreshButtonBackground: Self.whiteSurface,
            refreshButtonForeground: Self.whitePrimary
        )
    )

    static let dark = AppThemePalette(
        background: Self.darkBackground,
        chromeBackground: Self.darkBackground,
        chromeBorder: Self.darkSurface,
        mutedForeground: Self.darkMuted,
        foreground: Self.darkForeground,
        secondaryForeground: Self.darkSecondaryForeground,
        tertiaryForeground: Self.darkMuted,
        inverseForeground: Self.darkBackground,
        placeholderForeground: Self.darkMuted.opacity(0.68),
        iconForeground: Self.darkForeground,
        iconMutedForeground: Self.darkIconMuted,
        secondaryBackground: Self.darkSurface,
        quoteBackground: Self.darkSurface,
        groupedBackground: Self.darkBackground,
        secondaryGroupedBackground: Self.darkSurface,
        navigationBackground: Self.darkNavigation,
        navigationControlBackground: Self.darkSurface,
        sheetBackground: Self.darkSurface,
        sheetCardBackground: Self.darkRaised,
        sheetCardBorder: Self.darkBorder,
        sheetInsetBackground: Self.darkRaised,
        modalBackground: Self.darkSurface,
        elevatedBackground: Self.darkRaised,
        overlayBackground: Color.black.opacity(0.34),
        secondaryFill: Self.darkRaised,
        tertiaryFill: Self.darkSurface,
        separator: Self.darkBorder,
        successForeground: .green,
        warningForeground: .orange,
        errorForeground: .red,
        linkPreviewBackground: Self.darkSurface,
        linkPreviewBorder: Self.darkSurface,
        articlePreviewBackgroundTop: Self.darkSurface,
        articlePreviewBackgroundBottom: Self.darkBackground,
        articlePreviewBorder: Self.darkBorder,
        capsuleTabStyle: AppThemeCapsuleTabStyle(
            background: Self.darkSurface,
            border: Self.darkSurface,
            foreground: Self.darkMuted,
            selectedBackground: Color.accentColor.opacity(0.18),
            selectedBorder: Color.accentColor.opacity(0.54),
            selectedForeground: Color.accentColor
        ),
        profileActionStyle: AppThemeProfileActionStyle(
            background: Self.darkSurface,
            border: Self.darkSurface,
            foreground: Self.darkForeground,
            primaryBackground: Color.accentColor,
            primaryBorder: Color.accentColor,
            primaryForeground: .white,
            bannerBackground: Self.darkSurface,
            bannerBorder: Self.darkSurface,
            bannerForeground: Self.darkForeground
        ),
        pollStyle: AppThemePollStyle(
            cardBackground: Self.darkSurface,
            cardBorder: Self.darkSurface,
            metadataForeground: Self.darkMuted,
            optionBackground: Self.darkRaised,
            optionResultBackground: Self.darkRaised,
            optionBorder: Self.darkBorder,
            optionSelectedBackground: Color.accentColor.opacity(0.18),
            optionSelectedBorder: Color.accentColor.opacity(0.54),
            optionWinningBackground: Color.accentColor.opacity(0.18),
            optionWinningBorder: Color.accentColor.opacity(0.54),
            imagePlaceholderBackground: Self.darkRaised,
            imagePlaceholderForeground: Self.darkMuted,
            neutralBadgeBackground: Self.darkRaised,
            neutralBadgeForeground: Self.darkSecondaryForeground,
            refreshButtonBackground: Self.darkRaised,
            refreshButtonForeground: Self.darkSecondaryForeground
        )
    )

    static let system = adaptivePalette(light: Self.white, dark: Self.dark)

    static let holographicLight = AppThemePalette(
        background: Self.holographicLightBackground,
        chromeBackground: Self.holographicLightChrome,
        chromeBorder: Self.holographicLightBorder,
        mutedForeground: Self.holographicLightMuted,
        foreground: Self.holographicLightForeground,
        secondaryForeground: Self.holographicLightMuted,
        tertiaryForeground: Self.holographicLightMuted.opacity(0.68),
        inverseForeground: .white,
        placeholderForeground: Self.holographicLightMuted.opacity(0.48),
        iconForeground: Self.holographicLightForeground,
        iconMutedForeground: Self.holographicLightMuted,
        secondaryBackground: Self.holographicLightSurface,
        quoteBackground: .white,
        groupedBackground: Self.holographicLightBackground,
        secondaryGroupedBackground: Self.holographicLightSurface,
        navigationBackground: Self.holographicLightChrome,
        navigationControlBackground: Self.holographicLightSurface,
        sheetBackground: Self.holographicLightBackground,
        sheetCardBackground: .white,
        sheetCardBorder: Self.holographicLightBorder,
        sheetInsetBackground: Self.holographicLightSurface,
        modalBackground: .white,
        elevatedBackground: Self.holographicLightRaised,
        overlayBackground: Color.black.opacity(0.16),
        secondaryFill: Self.holographicCyan.opacity(0.12),
        tertiaryFill: Self.holographicLavender.opacity(0.12),
        separator: Self.holographicLightBorder,
        successForeground: .green,
        warningForeground: .orange,
        errorForeground: Self.holographicPink,
        linkPreviewBackground: .white,
        linkPreviewBorder: Self.holographicLightLinkPreviewBorder,
        articlePreviewBackgroundTop: .white,
        articlePreviewBackgroundBottom: Self.holographicLightBackground,
        articlePreviewBorder: Self.holographicLightBorder,
        capsuleTabStyle: AppThemeCapsuleTabStyle(
            background: .white,
            border: Self.holographicLightBorder,
            foreground: Self.holographicLightMuted,
            selectedBackground: Self.holographicCyan.opacity(0.14),
            selectedBorder: Self.holographicLavender.opacity(0.46),
            selectedForeground: Self.holographicBlue
        ),
        profileActionStyle: AppThemeProfileActionStyle(
            background: .white,
            border: Self.holographicLightBorder,
            foreground: Self.holographicLightForeground,
            primaryBackground: Self.holographicBlue.opacity(0.14),
            primaryBorder: Self.holographicLavender.opacity(0.46),
            primaryForeground: Self.holographicBlue,
            bannerBackground: Color.white.opacity(0.94),
            bannerBorder: Self.holographicLightBorder,
            bannerForeground: Self.holographicLightMuted
        ),
        pollStyle: AppThemePollStyle(
            cardBackground: .white,
            cardBorder: Self.holographicLightBorder,
            metadataForeground: Self.holographicLightMuted,
            optionBackground: Self.holographicLightSurface,
            optionResultBackground: Self.holographicLightRaised,
            optionBorder: Self.holographicLightBorder,
            optionSelectedBackground: Self.holographicCyan.opacity(0.14),
            optionSelectedBorder: Self.holographicLavender.opacity(0.46),
            optionWinningBackground: Self.holographicMint.opacity(0.16),
            optionWinningBorder: Self.holographicMint.opacity(0.52),
            imagePlaceholderBackground: Self.holographicLightRaised,
            imagePlaceholderForeground: Self.holographicLightMuted,
            neutralBadgeBackground: Self.holographicLightSurface,
            neutralBadgeForeground: Self.holographicLightMuted,
            refreshButtonBackground: Self.holographicCyan.opacity(0.12),
            refreshButtonForeground: Self.holographicBlue
        ),
        feedCardStyle: nil
    )

    static let holographicDark = AppThemePalette(
        background: Self.holographicDarkBackground,
        chromeBackground: Self.holographicDarkChrome,
        chromeBorder: Self.holographicDarkBorder,
        mutedForeground: Self.holographicDarkMuted,
        foreground: Self.holographicDarkForeground,
        secondaryForeground: Self.holographicDarkMuted,
        tertiaryForeground: Self.holographicDarkMuted.opacity(0.72),
        inverseForeground: Self.holographicDarkBackground,
        placeholderForeground: Self.holographicDarkMuted.opacity(0.58),
        iconForeground: Self.holographicDarkForeground,
        iconMutedForeground: Self.holographicDarkMuted,
        secondaryBackground: Self.holographicDarkSurface,
        quoteBackground: Self.holographicDarkSurface,
        groupedBackground: Self.holographicDarkBackground,
        secondaryGroupedBackground: Self.holographicDarkChrome,
        navigationBackground: Self.holographicDarkBackground,
        navigationControlBackground: Self.holographicDarkSurface,
        sheetBackground: Self.holographicDarkBackground,
        sheetCardBackground: Self.holographicDarkSurface,
        sheetCardBorder: Self.holographicDarkBorder,
        sheetInsetBackground: Self.holographicDarkChrome,
        modalBackground: Self.holographicDarkSurface,
        elevatedBackground: Self.holographicDarkRaised,
        overlayBackground: Color.black.opacity(0.86),
        secondaryFill: Self.holographicLavender.opacity(0.16),
        tertiaryFill: Self.holographicPink.opacity(0.14),
        separator: Self.holographicDarkBorder,
        successForeground: Self.holographicPink,
        warningForeground: .orange,
        errorForeground: Self.holographicPink,
        linkPreviewBackground: Self.holographicDarkSurface,
        linkPreviewBorder: Self.holographicDarkBorder,
        articlePreviewBackgroundTop: Self.holographicDarkSurface,
        articlePreviewBackgroundBottom: Self.holographicDarkChrome,
        articlePreviewBorder: Self.holographicDarkBorder,
        capsuleTabStyle: AppThemeCapsuleTabStyle(
            background: Self.holographicDarkChrome,
            border: Self.holographicDarkBorder,
            foreground: Self.holographicDarkMuted,
            selectedBackground: Self.holographicLavender.opacity(0.15),
            selectedBorder: Self.holographicPink.opacity(0.34),
            selectedForeground: Self.holographicDarkForeground
        ),
        profileActionStyle: AppThemeProfileActionStyle(
            background: Self.holographicDarkChrome,
            border: Self.holographicDarkBorder,
            foreground: Self.holographicDarkForeground.opacity(0.86),
            primaryBackground: Self.holographicLavender.opacity(0.15),
            primaryBorder: Self.holographicPink.opacity(0.34),
            primaryForeground: Self.holographicDarkForeground,
            bannerBackground: Self.holographicDarkSurface.opacity(0.94),
            bannerBorder: Self.holographicDarkBorder,
            bannerForeground: Self.holographicDarkForeground
        ),
        pollStyle: AppThemePollStyle(
            cardBackground: Self.holographicDarkSurface,
            cardBorder: Self.holographicDarkBorder,
            metadataForeground: Self.holographicDarkMuted,
            optionBackground: Self.holographicDarkChrome,
            optionResultBackground: Self.holographicDarkRaised.opacity(0.76),
            optionBorder: Self.holographicDarkBorder,
            optionSelectedBackground: Self.holographicLavender.opacity(0.15),
            optionSelectedBorder: Self.holographicPink.opacity(0.34),
            optionWinningBackground: Self.holographicPink.opacity(0.12),
            optionWinningBorder: Self.holographicPink.opacity(0.34),
            imagePlaceholderBackground: Self.holographicDarkChrome,
            imagePlaceholderForeground: Self.holographicDarkMuted,
            neutralBadgeBackground: Self.holographicDarkRaised.opacity(0.86),
            neutralBadgeForeground: Self.holographicDarkForeground.opacity(0.84),
            refreshButtonBackground: Self.holographicLavender.opacity(0.14),
            refreshButtonForeground: Self.holographicPink
        )
    )

    static let sakura = AppThemePalette(
        background: Color(red: 1.0, green: 0.994, blue: 0.997),
        chromeBackground: Color(red: 1.0, green: 0.996, blue: 0.998),
        chromeBorder: Self.sakuraBorder,
        mutedForeground: Self.sakuraPinkTint,
        foreground: Color.black.opacity(0.84),
        secondaryForeground: Self.sakuraPinkTint,
        tertiaryForeground: Self.sakuraPinkTint.opacity(0.72),
        inverseForeground: .white,
        placeholderForeground: Self.sakuraPinkTint.opacity(0.46),
        iconForeground: Color.black.opacity(0.84),
        iconMutedForeground: Self.sakuraPinkTint,
        secondaryBackground: Color(red: 0.998, green: 0.978, blue: 0.989),
        quoteBackground: .white,
        groupedBackground: Color(red: 0.999, green: 0.988, blue: 0.994),
        secondaryGroupedBackground: Color(red: 0.996, green: 0.972, blue: 0.985),
        navigationBackground: Color(red: 1.0, green: 0.996, blue: 0.998),
        navigationControlBackground: Color.white.opacity(0.88),
        sheetBackground: Color(red: 0.996, green: 0.972, blue: 0.985),
        sheetCardBackground: .white,
        sheetCardBorder: Self.sakuraBorder,
        sheetInsetBackground: Color(red: 0.998, green: 0.978, blue: 0.989),
        modalBackground: Color.white.opacity(0.96),
        elevatedBackground: Color(red: 0.998, green: 0.978, blue: 0.989),
        overlayBackground: Color.black.opacity(0.16),
        secondaryFill: Color(red: 0.968, green: 0.760, blue: 0.880).opacity(0.12),
        tertiaryFill: Color(red: 0.986, green: 0.878, blue: 0.942).opacity(0.16),
        separator: Self.sakuraBorder,
        successForeground: .green,
        warningForeground: .orange,
        errorForeground: .red,
        linkPreviewBackground: .white,
        linkPreviewBorder: Self.sakuraBorder,
        articlePreviewBackgroundTop: .white,
        articlePreviewBackgroundBottom: .white,
        articlePreviewBorder: Self.sakuraBorder,
        capsuleTabStyle: AppThemeCapsuleTabStyle(
            background: .white,
            border: Self.sakuraBorder,
            foreground: Self.sakuraPinkTint,
            selectedBackground: Self.sakuraPetalWash,
            selectedBorder: Self.sakuraBorder,
            selectedForeground: Self.sakuraPrimary
        ),
        profileActionStyle: AppThemeProfileActionStyle(
            background: .white,
            border: Self.sakuraBorder,
            foreground: Self.sakuraPinkTint,
            primaryBackground: Self.sakuraPetalWash,
            primaryBorder: Self.sakuraBorder,
            primaryForeground: Self.sakuraPrimary,
            bannerBackground: Color.white.opacity(0.90),
            bannerBorder: Self.sakuraBorder,
            bannerForeground: Self.sakuraPinkTint
        ),
        pollStyle: AppThemePollStyle(
            cardBackground: .white,
            cardBorder: Self.sakuraBorder,
            metadataForeground: Self.sakuraPinkTint,
            optionBackground: Self.sakuraSoftWhite,
            optionResultBackground: Self.sakuraPetalWash,
            optionBorder: Self.sakuraBorder,
            optionSelectedBackground: Self.sakuraPinkTint.opacity(0.16),
            optionSelectedBorder: Self.sakuraBorder,
            optionWinningBackground: Self.sakuraPrimary.opacity(0.12),
            optionWinningBorder: Self.sakuraBorder,
            imagePlaceholderBackground: Self.sakuraPetalWash,
            imagePlaceholderForeground: Self.sakuraPinkTint,
            neutralBadgeBackground: Self.sakuraPetalWash,
            neutralBadgeForeground: Self.sakuraPinkTint,
            refreshButtonBackground: Self.sakuraPetalWash,
            refreshButtonForeground: Self.sakuraPinkTint
        )
    )

    static let dracula = AppThemePalette(
        background: Self.draculaBackground,
        chromeBackground: Self.draculaChrome,
        chromeBorder: Self.draculaBorder,
        mutedForeground: Self.draculaComment,
        foreground: Self.draculaForeground,
        secondaryForeground: Self.draculaComment,
        tertiaryForeground: Self.draculaComment.opacity(0.78),
        inverseForeground: Self.draculaDarker,
        placeholderForeground: Self.draculaComment.opacity(0.66),
        iconForeground: Self.draculaForeground,
        iconMutedForeground: Self.draculaComment,
        secondaryBackground: Self.draculaFloating,
        quoteBackground: Self.draculaFloating,
        groupedBackground: Self.draculaDarker,
        secondaryGroupedBackground: Self.draculaChrome,
        navigationBackground: Self.draculaNavigation,
        navigationControlBackground: Self.draculaFloating,
        sheetBackground: Self.draculaBackground,
        sheetCardBackground: Self.draculaFloating,
        sheetCardBorder: Self.draculaBorder,
        sheetInsetBackground: Self.draculaChrome,
        modalBackground: Self.draculaFloating,
        elevatedBackground: Self.draculaRaised.opacity(0.86),
        overlayBackground: Self.draculaDarker.opacity(0.84),
        secondaryFill: Self.draculaRaised.opacity(0.86),
        tertiaryFill: Self.draculaComment.opacity(0.28),
        separator: Self.draculaBorder,
        successForeground: Self.draculaGreen,
        warningForeground: Self.draculaOrange,
        errorForeground: Self.draculaPink,
        linkPreviewBackground: Self.draculaFloating,
        linkPreviewBorder: Self.draculaBorder,
        articlePreviewBackgroundTop: Self.draculaFloating,
        articlePreviewBackgroundBottom: Self.draculaChrome,
        articlePreviewBorder: Self.draculaBorder,
        capsuleTabStyle: AppThemeCapsuleTabStyle(
            background: Self.draculaChrome,
            border: Self.draculaBorder,
            foreground: Self.draculaComment,
            selectedBackground: Self.draculaPurple.opacity(0.20),
            selectedBorder: Self.draculaPurple.opacity(0.54),
            selectedForeground: Self.draculaForeground
        ),
        profileActionStyle: AppThemeProfileActionStyle(
            background: Self.draculaChrome,
            border: Self.draculaBorder,
            foreground: Self.draculaForeground.opacity(0.82),
            primaryBackground: Self.draculaPurple.opacity(0.22),
            primaryBorder: Self.draculaPurple.opacity(0.56),
            primaryForeground: Self.draculaForeground,
            bannerBackground: Self.draculaFloating.opacity(0.94),
            bannerBorder: Self.draculaBorder,
            bannerForeground: Self.draculaForeground
        ),
        pollStyle: AppThemePollStyle(
            cardBackground: Self.draculaFloating,
            cardBorder: Self.draculaBorder,
            metadataForeground: Self.draculaComment,
            optionBackground: Self.draculaChrome,
            optionResultBackground: Self.draculaRaised.opacity(0.72),
            optionBorder: Self.draculaBorder,
            optionSelectedBackground: Self.draculaPurple.opacity(0.18),
            optionSelectedBorder: Self.draculaPurple.opacity(0.56),
            optionWinningBackground: Self.draculaPurple.opacity(0.22),
            optionWinningBorder: Self.draculaPurple.opacity(0.60),
            imagePlaceholderBackground: Self.draculaChrome,
            imagePlaceholderForeground: Self.draculaComment,
            neutralBadgeBackground: Self.draculaRaised.opacity(0.86),
            neutralBadgeForeground: Self.draculaForeground.opacity(0.82),
            refreshButtonBackground: Self.draculaPink.opacity(0.18),
            refreshButtonForeground: Self.draculaPink
        )
    )

    static let gamer = AppThemePalette(
        background: Self.gamerBackground,
        chromeBackground: Self.gamerChrome,
        chromeBorder: Self.gamerBorder,
        mutedForeground: Self.gamerMuted,
        foreground: Self.gamerForeground,
        secondaryForeground: Self.gamerMuted,
        tertiaryForeground: Self.gamerMuted.opacity(0.78),
        inverseForeground: Self.gamerBackground,
        placeholderForeground: Self.gamerMuted.opacity(0.60),
        iconForeground: Self.gamerForeground,
        iconMutedForeground: Self.gamerMuted,
        secondaryBackground: Self.gamerFloating,
        quoteBackground: Self.gamerFloating,
        groupedBackground: Color(red: 0.024, green: 0.043, blue: 0.075),
        secondaryGroupedBackground: Self.gamerChrome,
        navigationBackground: Self.gamerBackground,
        navigationControlBackground: Self.gamerFloating,
        sheetBackground: Self.gamerBackground,
        sheetCardBackground: Self.gamerFloating,
        sheetCardBorder: Self.gamerBorder,
        sheetInsetBackground: Self.gamerChrome,
        modalBackground: Self.gamerFloating,
        elevatedBackground: Self.gamerRaised.opacity(0.90),
        overlayBackground: Color(red: 0.020, green: 0.031, blue: 0.055).opacity(0.88),
        secondaryFill: Self.gamerRaised.opacity(0.82),
        tertiaryFill: Self.gamerPurple.opacity(0.20),
        separator: Self.gamerBorder,
        successForeground: Self.gamerGreen,
        warningForeground: Self.gamerOrange,
        errorForeground: Self.gamerPink,
        linkPreviewBackground: Self.gamerFloating,
        linkPreviewBorder: Self.gamerBorder,
        articlePreviewBackgroundTop: Self.gamerFloating,
        articlePreviewBackgroundBottom: Self.gamerChrome,
        articlePreviewBorder: Self.gamerBorder,
        capsuleTabStyle: AppThemeCapsuleTabStyle(
            background: Self.gamerChrome,
            border: Self.gamerBorder,
            foreground: Self.gamerMuted,
            selectedBackground: Self.gamerPurple.opacity(0.20),
            selectedBorder: Self.gamerCyan.opacity(0.42),
            selectedForeground: Self.gamerForeground
        ),
        profileActionStyle: AppThemeProfileActionStyle(
            background: Self.gamerChrome,
            border: Self.gamerBorder,
            foreground: Self.gamerForeground.opacity(0.82),
            primaryBackground: Self.gamerPurple.opacity(0.22),
            primaryBorder: Self.gamerCyan.opacity(0.48),
            primaryForeground: Self.gamerForeground,
            bannerBackground: Self.gamerFloating.opacity(0.94),
            bannerBorder: Self.gamerBorder,
            bannerForeground: Self.gamerForeground
        ),
        pollStyle: AppThemePollStyle(
            cardBackground: Self.gamerFloating,
            cardBorder: Self.gamerBorder,
            metadataForeground: Self.gamerMuted,
            optionBackground: Self.gamerChrome,
            optionResultBackground: Self.gamerRaised.opacity(0.72),
            optionBorder: Self.gamerBorder.opacity(0.92),
            optionSelectedBackground: Self.gamerPurple.opacity(0.18),
            optionSelectedBorder: Self.gamerCyan.opacity(0.56),
            optionWinningBackground: Self.gamerGreen.opacity(0.16),
            optionWinningBorder: Self.gamerGreen.opacity(0.56),
            imagePlaceholderBackground: Self.gamerChrome,
            imagePlaceholderForeground: Self.gamerMuted,
            neutralBadgeBackground: Self.gamerRaised.opacity(0.86),
            neutralBadgeForeground: Self.gamerForeground.opacity(0.84),
            refreshButtonBackground: Self.gamerCyan.opacity(0.18),
            refreshButtonForeground: Self.gamerCyan
        )
    )
}
