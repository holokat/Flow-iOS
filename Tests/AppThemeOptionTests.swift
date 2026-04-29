import XCTest
import SwiftUI
import UIKit
@testable import Flow

final class AppThemeOptionTests: XCTestCase {
    @MainActor
    func testSakuraThemeIsLegacyAndNormalizesToLight() {
        XCTAssertFalse(AppThemeOption.sakura.isEnabled)
        XCTAssertEqual(AppThemeOption.sakura.normalizedSelection, .light)
        XCTAssertEqual(AppThemeOption.sakura.preferredColorScheme, .light)
        XCTAssertNil(AppThemeOption.sakura.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.sakura.fixedPrimaryGradient)
        XCTAssertNil(AppThemeOption.sakura.qrShareBackgroundResourceName)
        assertColor(AppThemeOption.sakura.palette.background, matches: .white)
        XCTAssertNotNil(AppThemeOption.sakura.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.sakura.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.sakura.palette.pollStyle)
    }

    @MainActor
    func testMidnightPaletteIsFreeAndUsesDarkMode() {
        XCTAssertTrue(AppThemeOption.dracula.isEnabled)
        XCTAssertEqual(AppThemeOption.dracula.preferredColorScheme, .dark)
        XCTAssertNil(AppThemeOption.dracula.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.dracula.fixedPrimaryGradient)
        XCTAssertNil(AppThemeOption.dracula.qrShareBackgroundResourceName)
        assertColor(
            AppThemeOption.dracula.palette.background,
            matches: UIColor(red: 44.0 / 255.0, green: 45.0 / 255.0, blue: 60.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dracula.palette.chromeBackground,
            matches: UIColor(red: 43.0 / 255.0, green: 44.0 / 255.0, blue: 58.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dracula.palette.secondaryBackground,
            matches: UIColor(red: 0.204, green: 0.216, blue: 0.275, alpha: 1)
        )
        assertColor(
            AppThemeOption.dracula.palette.navigationBackground,
            matches: UIColor(red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 43.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dracula.palette.sheetBackground,
            matches: UIColor(red: 44.0 / 255.0, green: 45.0 / 255.0, blue: 60.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dracula.palette.sheetCardBackground,
            matches: UIColor(red: 0.204, green: 0.216, blue: 0.275, alpha: 1)
        )
        assertColor(
            AppThemeOption.dracula.palette.chromeBorder,
            matches: UIColor(white: 1, alpha: 0.07)
        )
        assertColor(
            AppThemeOption.dracula.palette.separator,
            matches: UIColor(white: 1, alpha: 0.07)
        )
        assertColor(
            AppThemeOption.dracula.palette.mutedForeground,
            matches: UIColor(red: 0.537, green: 0.549, blue: 0.675, alpha: 1)
        )
        XCTAssertNotNil(AppThemeOption.dracula.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.dracula.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.dracula.palette.pollStyle)
        assertColor(
            AppThemeOption.dracula.palette.pollStyle!.optionWinningBackground,
            matches: UIColor(red: 0.773, green: 0.565, blue: 1.0, alpha: 0.22)
        )
        assertColor(
            AppThemeOption.dracula.palette.pollStyle!.optionWinningBorder,
            matches: UIColor(red: 0.773, green: 0.565, blue: 1.0, alpha: 0.60)
        )
    }

    @MainActor
    func testNeonPaletteIsFreeAndUsesDarkMode() {
        XCTAssertTrue(AppThemeOption.gamer.isEnabled)
        XCTAssertEqual(AppThemeOption.gamer.preferredColorScheme, .dark)
        XCTAssertNil(AppThemeOption.gamer.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.gamer.fixedPrimaryGradient)
        XCTAssertNil(AppThemeOption.gamer.qrShareBackgroundResourceName)
        assertColor(
            AppThemeOption.gamer.palette.background,
            matches: UIColor(red: 0.035, green: 0.063, blue: 0.106, alpha: 1)
        )
        assertColor(
            AppThemeOption.gamer.palette.chromeBackground,
            matches: UIColor(red: 0.055, green: 0.086, blue: 0.141, alpha: 1)
        )
        assertColor(
            AppThemeOption.gamer.palette.secondaryBackground,
            matches: UIColor(red: 0.071, green: 0.114, blue: 0.188, alpha: 1)
        )
        assertColor(
            AppThemeOption.gamer.palette.mutedForeground,
            matches: UIColor(red: 0.592, green: 0.735, blue: 0.976, alpha: 1)
        )
        XCTAssertNotNil(AppThemeOption.gamer.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.gamer.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.gamer.palette.pollStyle)
        assertColor(
            AppThemeOption.gamer.palette.pollStyle!.optionWinningBorder,
            matches: UIColor(red: 0.561, green: 1.0, blue: 0.369, alpha: 0.56)
        )
    }

    @MainActor
    func testLightPaletteUsesFormerAirPalette() {
        XCTAssertTrue(AppThemeOption.holographicLight.isEnabled)
        XCTAssertEqual(AppThemeOption.holographicLight.preferredColorScheme, .light)
        XCTAssertEqual(AppThemeOption.holographicLight.title, "Light")
        XCTAssertNil(AppThemeOption.holographicLight.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.holographicLight.fixedPrimaryGradient)
        XCTAssertNil(AppThemeOption.holographicLight.qrShareBackgroundResourceName)
        assertColor(
            AppThemeOption.holographicLight.palette.background,
            matches: UIColor(red: 0.992, green: 0.996, blue: 1.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.holographicLight.palette.chromeBackground,
            matches: UIColor(red: 0.988, green: 0.994, blue: 1.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.holographicLight.palette.secondaryBackground,
            matches: UIColor(red: 0.957, green: 0.982, blue: 1.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.holographicLight.palette.linkPreviewBorder,
            matches: UIColor(white: 0, alpha: 0.04)
        )
        XCTAssertNotNil(AppThemeOption.holographicLight.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.holographicLight.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.holographicLight.palette.pollStyle)
        XCTAssertNil(AppThemeOption.holographicLight.palette.feedCardStyle)
        assertColor(
            AppThemeOption.holographicLight.palette.profileActionStyle!.primaryForeground,
            matches: UIColor(red: 0.235, green: 0.612, blue: 1.0, alpha: 1)
        )
    }

    @MainActor
    func testPaletteTitlesAndVisibleOptionsReflectRenamedChoices() {
        XCTAssertEqual(AppThemeOption.black.title, "Dark")
        XCTAssertEqual(AppThemeOption.dark.title, "Charcoal")
        XCTAssertEqual(AppThemeOption.dracula.title, "Midnight")
        XCTAssertEqual(AppThemeOption.gamer.title, "Neon")
        XCTAssertEqual(AppThemeOption.holographicLight.title, "Light")
        XCTAssertEqual(AppThemeOption.light.title, "Clean")
        XCTAssertEqual(AppThemeOption.sakura.normalizedSelection, .light)
        XCTAssertEqual(
            AppThemeOption.onboardingOptions,
            [.holographicLight, .black, .system, .dracula, .gamer, .dark]
        )
        XCTAssertEqual(
            AppThemeOption.appearanceOptions,
            [.holographicLight, .black, .system, .dracula, .gamer, .dark, .light]
        )
    }

    @MainActor
    func testDefaultThemeUsesCurrentTimeOfDay() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        XCTAssertEqual(settings.theme, expectedDefaultThemeForCurrentTime())
    }

    @MainActor
    func testLegacyHolographicDarkIsDisabledAndNormalizesToCharcoal() {
        XCTAssertFalse(AppThemeOption.holographicDark.isEnabled)
        XCTAssertEqual(AppThemeOption.holographicDark.normalizedSelection, .dark)
        XCTAssertEqual(AppThemeOption.holographicDark.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemeOption.holographicDark.title, "Charcoal")
        XCTAssertNil(AppThemeOption.holographicDark.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.holographicDark.fixedPrimaryGradient)
        XCTAssertNil(AppThemeOption.holographicDark.qrShareBackgroundResourceName)
    }

    @MainActor
    func testFixedAccentPaletteMatchesProductChoices() {
        XCTAssertEqual(
            AppSettingsStore.availablePrimaryColorOptions.map(\.hexCode),
            ["FF0000", "0059FF", "FF5900", "91C500", "00D4FF", "D000FF", "9000FF"]
        )
    }

    @MainActor
    func testFixedPrimaryColorPersistsAndProminentButtonsStaySolid() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "b", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.configure(accountPubkey: pubkey)
        settings.primaryColor = AppSettingsStore.availablePrimaryColorOptions[1].color

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertFalse(reloaded.usesPrimaryGradientForProminentButtons)
        XCTAssertNil(reloaded.activeButtonGradientOption)
        XCTAssertNil(reloaded.activeHolographicGradientOption)
        assertColor(reloaded.primaryColor, matches: UIColor(red: 0.0, green: 0x59 / 255.0, blue: 1.0, alpha: 1))
        assertColor(reloaded.linkColor, matches: UIColor(red: 0.0, green: 0x59 / 255.0, blue: 1.0, alpha: 1))
    }

    @MainActor
    func testThemeIconAccentMatchesReactionChromeForVisibleThemes() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        for theme in AppThemeOption.appearanceOptions {
            settings.beginThemePreview(theme)

            assertColor(
                settings.themeIconAccentColor,
                matches: UIColor(settings.themePalette.mutedForeground),
                file: #filePath,
                line: #line
            )
        }
    }

    @MainActor
    func testLightThemePaletteKeepsChromeNeutralAndRetintsAccentControls() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "d", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.configure(accountPubkey: pubkey)
        settings.theme = .holographicLight
        settings.primaryColor = AppSettingsStore.availablePrimaryColorOptions[0].color

        let palette = settings.themePalette
        let basePalette = AppThemeOption.holographicLight.palette

        assertColor(
            palette.profileActionStyle!.primaryForeground,
            matches: UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        assertColor(
            palette.capsuleTabStyle!.selectedForeground,
            matches: UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        assertColor(palette.background, matches: UIColor.white)
        assertColor(palette.chromeBackground, matches: UIColor.white)
        assertColor(palette.navigationBackground, matches: UIColor.white)
        assertColor(palette.sheetBackground, matches: UIColor.white)
        assertColor(
            palette.chromeBorder,
            matches: UIColor(white: 0, alpha: 0.04)
        )
        assertColor(
            palette.linkPreviewBorder,
            matches: UIColor(white: 0, alpha: 0.04)
        )
        XCTAssertFalse(colorsMatch(palette.secondaryFill, basePalette.secondaryFill))
    }

    @MainActor
    func testLegacyGradientSelectionsCollapseToAllowedAccentColors() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "c", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.configure(accountPubkey: pubkey)
        settings.theme = .holographicLight
        settings.buttonGradientOption = .strongRainbowFoil

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertFalse(reloaded.usesPrimaryGradientForProminentButtons)
        XCTAssertNil(reloaded.activeButtonGradientOption)
        XCTAssertNil(reloaded.activeHolographicGradientOption)
        XCTAssertTrue(
            AppSettingsStore.availablePrimaryColorOptions.contains { option in
                colorsMatch(option.color, reloaded.primaryColor)
            }
        )
    }

    @MainActor
    func testHolographicSpotlightOnlyAppearsOnAirScreens() {
        XCTAssertTrue(AppThemeBackgroundSpotlight.feed.isVisible(for: .holographicLight))
        XCTAssertTrue(AppThemeBackgroundSpotlight.profile.isVisible(for: .holographicLight))
        XCTAssertFalse(AppThemeBackgroundSpotlight.feed.isVisible(for: .holographicDark))
        XCTAssertFalse(AppThemeBackgroundSpotlight.none.isVisible(for: .holographicDark))
        XCTAssertFalse(AppThemeBackgroundSpotlight.feed.isVisible(for: .sakura))
        XCTAssertFalse(AppThemeBackgroundSpotlight.profile.isVisible(for: .gamer))
    }

    func testHolographicSpotlightLayoutStaysBottomAnchored() {
        let size = CGSize(width: 390, height: 844)
        let feedLayout = AppThemeBackgroundSpotlightLayout(placement: .feed, size: size)
        let profileLayout = AppThemeBackgroundSpotlightLayout(placement: .profile, size: size)

        XCTAssertGreaterThan(feedLayout.primaryOffset.height, 0)
        XCTAssertGreaterThan(feedLayout.secondaryOffset.height, 0)
        XCTAssertGreaterThan(profileLayout.primaryOffset.height, 0)
        XCTAssertGreaterThan(profileLayout.secondaryOffset.height, 0)
    }

    func testHolographicSpotlightFadesBeforeFrameEdges() {
        let layout = AppThemeBackgroundSpotlightLayout(
            placement: .feed,
            size: CGSize(width: 390, height: 844)
        )

        XCTAssertLessThan(layout.primaryRadius, min(layout.primarySize.width, layout.primarySize.height) / 2)
        XCTAssertLessThan(layout.secondaryRadius, min(layout.secondarySize.width, layout.secondarySize.height) / 2)
    }

    func testDarkGradientTreatmentUsesMagentaPurpleAccentColors() {
        let accentColor = Color(
            .sRGB,
            red: 0x8B / 255.0,
            green: 0x7D / 255.0,
            blue: 0xFF / 255.0,
            opacity: 1
        )
        let colors = AppThemeBackgroundSpotlightColors(theme: .dark, accentColor: accentColor)

        assertColor(
            colors.primaryStart,
            matches: UIColor(red: 0.5723921657, green: 0.5207842588, blue: 1.0, alpha: 1)
        )
        assertColor(
            colors.secondaryEnd,
            matches: UIColor(red: 0.6633725762, green: 0.6227451563, blue: 1.0, alpha: 1)
        )
    }

    @MainActor
    func testAppearanceThemesExposeUpdatedPaletteList() {
        XCTAssertTrue(AppThemeOption.light.isEnabled)
        XCTAssertTrue(AppThemeOption.dark.isEnabled)
        XCTAssertTrue(AppThemeOption.black.isEnabled)
        XCTAssertEqual(
            AppThemeOption.appearanceOptions,
            [.holographicLight, .black, .system, .dracula, .gamer, .dark, .light]
        )
        XCTAssertFalse(AppThemeOption.appearanceOptions.contains(.white))
        XCTAssertFalse(AppThemeOption.appearanceOptions.contains(.holographicDark))
    }

    @MainActor
    func testThemePreviewOverridesActiveTheme() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.theme = .system
        settings.beginThemePreview(.holographicLight)

        XCTAssertEqual(settings.activeTheme, .holographicLight)
        XCTAssertEqual(settings.preferredColorScheme, .light)
        XCTAssertEqual(settings.previewTheme, .holographicLight)
    }

    @MainActor
    func testLegacyWhiteThemeSelectionNormalizesToClean() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.theme = .white

        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.activeTheme, .light)
        XCTAssertEqual(settings.preferredColorScheme, .light)
    }

    @MainActor
    func testDarkThemeSelectionStaysOnBlackPalette() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.theme = .black

        XCTAssertEqual(settings.theme, .black)
        XCTAssertEqual(settings.activeTheme, .black)
        XCTAssertEqual(settings.preferredColorScheme, .dark)
    }

    @MainActor
    func testLegacyHolographicDarkSelectionNormalizesToCharcoal() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.theme = .holographicDark

        XCTAssertEqual(settings.theme, .dark)
        XCTAssertEqual(settings.activeTheme, .dark)
        XCTAssertEqual(settings.preferredColorScheme, .dark)
    }

    @MainActor
    func testVisibleThemesPersistWithoutUnlock() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        for theme in AppThemeOption.appearanceOptions {
            settings.theme = theme
            XCTAssertEqual(settings.theme, theme.normalizedSelection)
            XCTAssertEqual(settings.activeTheme, theme.normalizedSelection)
        }
    }

    @MainActor
    func testAllFontsAreEnabled() {
        for option in AppFontOption.allCases {
            XCTAssertTrue(option.isEnabled)
        }
    }

    @MainActor
    func testFontPreviewOverridesActiveFont() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.fontOption = .system
        settings.beginFontPreview(.inter)

        XCTAssertEqual(settings.activeFontOption, .inter)
        XCTAssertEqual(settings.previewFontOption, .inter)
        XCTAssertEqual(settings.fontOption, .system)
    }

    @MainActor
    func testFontSelectionPersistsWithoutUnlock() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "d", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.configure(accountPubkey: pubkey)
        settings.fontOption = .ebGaramond

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertEqual(reloaded.fontOption, .ebGaramond)
        XCTAssertEqual(reloaded.activeFontOption, .ebGaramond)
    }

    @MainActor
    func testBundledCustomFontsExistInMainBundle() {
        let bundledFonts = [
            "DMSans.ttf",
            "EBGaramond.ttf",
            "ElmsSans.ttf",
            "GeistSans.ttf",
            "HubotSans.ttf",
            "Inter.ttf",
            "MonaSans.ttf",
            "Nacelle-Bold.otf",
            "Nacelle-Italic.otf",
            "Nacelle-Regular.otf",
            "Nacelle-SemiBold.otf",
            "Nunito.ttf",
            "PublicSans.ttf",
            "SpaceGrotesk.ttf"
        ]

        for fontFile in bundledFonts {
            let parts = fontFile.split(separator: ".", maxSplits: 1)
            XCTAssertEqual(parts.count, 2)
            XCTAssertNotNil(
                Bundle.main.url(
                    forResource: String(parts[0]),
                    withExtension: String(parts[1])
                ),
                "Missing bundled font: \(fontFile)"
            )
        }
    }

    @MainActor
    func testBlackThemeKeepsPureBlackBackgroundAndChrome() {
        assertColor(AppThemeOption.black.palette.background, matches: .black)
        assertColor(AppThemeOption.black.palette.chromeBackground, matches: .black)
        assertColor(
            AppThemeOption.black.palette.chromeBorder,
            matches: UIColor.white.withAlphaComponent(0.08)
        )
        assertColor(
            AppThemeOption.black.palette.separator,
            matches: UIColor.white.withAlphaComponent(0.13)
        )
        assertColor(
            AppThemeOption.black.palette.linkPreviewBorder,
            matches: UIColor.white.withAlphaComponent(0.13)
        )
        assertColor(
            AppThemeOption.black.palette.articlePreviewBorder,
            matches: UIColor.white.withAlphaComponent(0.15)
        )
    }

    @MainActor
    func testLightThemeUsesFormerWhitePalette() {
        assertColor(AppThemeOption.light.palette.background, matches: .white)
        assertColor(AppThemeOption.light.palette.chromeBackground, matches: .white)
        assertColor(
            AppThemeOption.light.palette.chromeBorder,
            matches: UIColor.black.withAlphaComponent(0.04)
        )
        XCTAssertNotNil(AppThemeOption.light.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.light.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.light.palette.pollStyle)
        assertColor(
            AppThemeOption.light.palette.capsuleTabStyle!.background,
            matches: UIColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1)
        )
        assertColor(
            AppThemeOption.light.palette.profileActionStyle!.primaryBackground,
            matches: .white
        )
        assertColor(
            AppThemeOption.light.palette.pollStyle!.cardBorder,
            matches: UIColor.black.withAlphaComponent(0.04)
        )
        XCTAssertEqual(AppThemeOption.white.normalizedSelection, .light)
        XCTAssertFalse(AppThemeOption.white.isEnabled)
    }

    @MainActor
    func testDarkThemeMatchesReferencePalette() {
        XCTAssertEqual(AppThemeOption.dark.preferredColorScheme, .dark)
        XCTAssertNil(AppThemeOption.dark.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.dark.fixedPrimaryGradient)
        assertColor(
            AppThemeOption.dark.palette.background,
            matches: UIColor(red: 23.0 / 255.0, green: 23.0 / 255.0, blue: 25.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dark.palette.navigationBackground,
            matches: UIColor(red: 19.0 / 255.0, green: 19.0 / 255.0, blue: 20.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dark.palette.secondaryBackground,
            matches: UIColor(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dark.palette.sheetBackground,
            matches: UIColor(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dark.palette.sheetCardBackground,
            matches: UIColor(red: 58.0 / 255.0, green: 58.0 / 255.0, blue: 58.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dark.palette.sheetCardBorder,
            matches: UIColor(red: 75.0 / 255.0, green: 75.0 / 255.0, blue: 75.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dark.palette.foreground,
            matches: UIColor(red: 226.0 / 255.0, green: 226.0 / 255.0, blue: 227.0 / 255.0, alpha: 1)
        )
        assertColor(
            AppThemeOption.dark.palette.mutedForeground,
            matches: UIColor(red: 125.0 / 255.0, green: 125.0 / 255.0, blue: 126.0 / 255.0, alpha: 1)
        )
        XCTAssertNotNil(AppThemeOption.dark.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.dark.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.dark.palette.pollStyle)
    }

    @MainActor
    func testSystemThemeSwitchesBetweenLightAndDarkPalettes() {
        assertColor(
            AppThemeOption.system.palette.background,
            matches: .white,
            style: .light
        )
        assertColor(
            AppThemeOption.system.palette.chromeBorder,
            matches: UIColor.black.withAlphaComponent(0.04),
            style: .light
        )
        assertColor(
            AppThemeOption.system.palette.sheetCardBackground,
            matches: .white,
            style: .light
        )
        assertColor(
            AppThemeOption.system.palette.background,
            matches: UIColor(red: 23.0 / 255.0, green: 23.0 / 255.0, blue: 25.0 / 255.0, alpha: 1),
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.navigationBackground,
            matches: UIColor(red: 19.0 / 255.0, green: 19.0 / 255.0, blue: 20.0 / 255.0, alpha: 1),
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.sheetCardBackground,
            matches: UIColor(red: 58.0 / 255.0, green: 58.0 / 255.0, blue: 58.0 / 255.0, alpha: 1),
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.sheetCardBorder,
            matches: UIColor(red: 75.0 / 255.0, green: 75.0 / 255.0, blue: 75.0 / 255.0, alpha: 1),
            style: .dark
        )
    }

    @MainActor
    func testDefaultThemesKeepSharedQRCodePresentationBackground() {
        XCTAssertNil(AppThemeOption.system.qrShareBackgroundResourceName)
        XCTAssertNil(AppThemeOption.black.qrShareBackgroundResourceName)
        XCTAssertNil(AppThemeOption.light.qrShareBackgroundResourceName)
        XCTAssertNil(AppThemeOption.dark.qrShareBackgroundResourceName)
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .system),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .black),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .light),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .dark),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
    }

    @MainActor
    func testAdditionalThemesResolveCustomQRCodePresentationBackgrounds() {
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .sakura),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .dracula),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .gamer),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .holographicLight),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
        XCTAssertEqual(
            ProfileQRCodePresentationBackground.resourceName(for: .holographicDark),
            ProfileQRCodePresentationBackground.defaultResourceName
        )
    }

    @MainActor
    func testBundledThemeAssetsExistInMainBundle() {
        XCTAssertNil(AppThemeOption.sakura.qrShareBackgroundResourceName)
    }

    @MainActor
    func testFullWidthNoteRowsPersistsAcrossStoreReload() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "a", count: 64)

        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)
        settings.configure(accountPubkey: pubkey)
        settings.fullWidthNoteRows = true

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertTrue(reloaded.fullWidthNoteRows)
    }

    @MainActor
    func testFloatingComposeButtonPreferencePersistsAcrossStoreReload() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "a", count: 64)

        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)
        settings.configure(accountPubkey: pubkey)
        settings.floatingComposeButtonEnabled = true

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertTrue(reloaded.floatingComposeButtonEnabled)
    }

    func testFloatingComposePaddingClearsVisibleBottomBar() {
        let padding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: 65,
            isBottomTabBarVisible: true
        )

        XCTAssertEqual(padding, 101)
    }

    func testFloatingComposePaddingSitsCloserWhenBottomBarIsHidden() {
        let hiddenPadding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: 65,
            isBottomTabBarVisible: false
        )
        let visiblePadding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: 65,
            isBottomTabBarVisible: true
        )

        XCTAssertEqual(hiddenPadding, 32)
        XCTAssertLessThan(hiddenPadding, visiblePadding)
    }

    func testBottomTabBarStaysVisibleOnHomeRoot() {
        XCTAssertTrue(
            ScrollChromeLayout.isBottomTabBarVisible(
                isHomeSideMenuPresented: false,
                selectedTabIsDirectMessages: false,
                isDirectMessagesRootVisible: true
            )
        )
    }

    func testBottomTabBarStillHidesBehindHomeSideMenu() {
        XCTAssertFalse(
            ScrollChromeLayout.isBottomTabBarVisible(
                isHomeSideMenuPresented: true,
                selectedTabIsDirectMessages: false,
                isDirectMessagesRootVisible: true
            )
        )
    }

    func testBottomTabBarStillHidesOnNestedDirectMessagesScreen() {
        XCTAssertFalse(
            ScrollChromeLayout.isBottomTabBarVisible(
                isHomeSideMenuPresented: false,
                selectedTabIsDirectMessages: true,
                isDirectMessagesRootVisible: false
            )
        )
    }

    func testHomeBottomBarUsesSafeAreaInsetInsteadOfOverlay() {
        XCTAssertFalse(
            ScrollChromeLayout.usesOverlayBottomTabBar(
                selectedTabIsHome: true,
                isHomeSideMenuPresented: false
            )
        )
    }

    func testVisibleBottomBarReservesInsetSpace() {
        XCTAssertTrue(
            ScrollChromeLayout.reservesBottomTabBarInsetSpace(
                isBottomTabBarVisible: true,
                usesOverlayBottomTabBar: false
            )
        )
    }

    func testHiddenBottomBarDoesNotReserveInsetSpace() {
        XCTAssertFalse(
            ScrollChromeLayout.reservesBottomTabBarInsetSpace(
                isBottomTabBarVisible: false,
                usesOverlayBottomTabBar: false
            )
        )
    }

    func testAudioPlayerProgressClampsToPlayableRange() {
        XCTAssertEqual(
            NoteAudioPlayerLayout.progress(currentTime: -8, duration: 120),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NoteAudioPlayerLayout.progress(currentTime: 30, duration: 120),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NoteAudioPlayerLayout.progress(currentTime: 140, duration: 120),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NoteAudioPlayerLayout.progress(currentTime: 30, duration: 0),
            0,
            accuracy: 0.0001
        )
    }

    func testAudioPlayerSeekSecondsClampDragProgress() {
        XCTAssertEqual(
            NoteAudioPlayerLayout.seekSeconds(forProgress: -0.5, duration: 80),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NoteAudioPlayerLayout.seekSeconds(forProgress: 0.5, duration: 80),
            40,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NoteAudioPlayerLayout.seekSeconds(forProgress: 1.5, duration: 80),
            80,
            accuracy: 0.0001
        )
    }

    func testAudioPlayerUsesLargePlayButtonAndScrubbableWaveformHeight() {
        XCTAssertGreaterThanOrEqual(NoteAudioPlayerLayout.playButtonDiameter, 52)
        XCTAssertGreaterThanOrEqual(NoteAudioPlayerLayout.waveformHeight, 44)
    }

    func testSelectingSearchTabRequestsSearchRootReset() {
        let effects = MainTabSelectionPolicy.effects(
            previousTab: .home,
            selectedTab: .search,
            wasActivityRootVisible: true
        )

        XCTAssertTrue(effects.resetsSearchRoot)
        XCTAssertFalse(effects.resetsHomeRoot)
        XCTAssertFalse(effects.resetsActivityRoot)
    }

    func testReselectingSearchTabRequestsSearchRootReset() {
        let effects = MainTabSelectionPolicy.effects(
            previousTab: .search,
            selectedTab: .search,
            wasActivityRootVisible: true
        )

        XCTAssertTrue(effects.resetsSearchRoot)
        XCTAssertFalse(effects.resetsHomeRoot)
        XCTAssertFalse(effects.resetsActivityRoot)
    }

    @MainActor
    func testMarkedSpamIsSharedAcrossAccountsAndNotSpamOverridesLocally() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let firstAccountPubkey = String(repeating: "a", count: 64)
        let secondAccountPubkey = String(repeating: "c", count: 64)
        let targetPubkey = String(repeating: "b", count: 64)

        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)
        settings.configure(accountPubkey: firstAccountPubkey)
        settings.addSpamFilterMarkedPubkey(targetPubkey)

        XCTAssertTrue(settings.isSpamFilterMarked(targetPubkey))
        XCTAssertTrue(settings.shouldHideSpamMarkedPubkey(targetPubkey))
        XCTAssertFalse(settings.isSpamReplySafelisted(targetPubkey))

        settings.addSpamReplySafelistedPubkey(targetPubkey)

        XCTAssertTrue(settings.isSpamFilterMarked(targetPubkey))
        XCTAssertTrue(settings.isSpamReplySafelisted(targetPubkey))
        XCTAssertFalse(settings.shouldHideSpamMarkedPubkey(targetPubkey))

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: firstAccountPubkey)

        XCTAssertTrue(reloaded.isSpamFilterMarked(targetPubkey))
        XCTAssertTrue(reloaded.isSpamReplySafelisted(targetPubkey))
        XCTAssertFalse(reloaded.shouldHideSpamMarkedPubkey(targetPubkey))

        reloaded.configure(accountPubkey: secondAccountPubkey)

        XCTAssertTrue(reloaded.isSpamFilterMarked(targetPubkey))
        XCTAssertFalse(reloaded.isSpamReplySafelisted(targetPubkey))
        XCTAssertTrue(reloaded.shouldHideSpamMarkedPubkey(targetPubkey))
    }

    @MainActor
    func testNewsRelayURLsDropHTTPSValuesAndKeepWebSocketRelays() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.setNewsRelayURLs([
            URL(string: "https://relay.snort.social")!,
            URL(string: "wss://relay.damus.io")!
        ])

        XCTAssertEqual(
            settings.newsRelayURLs.map(\.absoluteString),
            ["wss://relay.damus.io/"]
        )
    }

    @MainActor
    func testAddNewsRelayNormalizesBareHostsToSecureWebSocketURLs() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.setNewsRelayURLs([URL(string: "wss://relay.damus.io/")!])
        try settings.addNewsRelay("relay.snort.social")

        XCTAssertEqual(
            settings.newsRelayURLs.map(\.absoluteString),
            ["wss://relay.damus.io/", "wss://relay.snort.social/"]
        )
    }

    private func assertColor(
        _ color: Color,
        matches expected: UIColor,
        style: UIUserInterfaceStyle = .light,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let traitCollection = UITraitCollection(userInterfaceStyle: style)
        let actual = UIColor(color).resolvedColor(with: traitCollection)
        let expected = expected.resolvedColor(with: traitCollection)

        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var actualAlpha: CGFloat = 0
        XCTAssertTrue(
            actual.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha),
            file: file,
            line: line
        )

        var expectedRed: CGFloat = 0
        var expectedGreen: CGFloat = 0
        var expectedBlue: CGFloat = 0
        var expectedAlpha: CGFloat = 0
        XCTAssertTrue(
            expected.getRed(&expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha),
            file: file,
            line: line
        )

        XCTAssertEqual(actualRed, expectedRed, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualGreen, expectedGreen, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualBlue, expectedBlue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualAlpha, expectedAlpha, accuracy: 0.001, file: file, line: line)
    }

    private func colorsMatch(
        _ lhs: Color,
        _ rhs: Color,
        style: UIUserInterfaceStyle = .light
    ) -> Bool {
        let traitCollection = UITraitCollection(userInterfaceStyle: style)
        let lhsColor = UIColor(lhs).resolvedColor(with: traitCollection)
        let rhsColor = UIColor(rhs).resolvedColor(with: traitCollection)

        var lhsRed: CGFloat = 0
        var lhsGreen: CGFloat = 0
        var lhsBlue: CGFloat = 0
        var lhsAlpha: CGFloat = 0
        guard lhsColor.getRed(&lhsRed, green: &lhsGreen, blue: &lhsBlue, alpha: &lhsAlpha) else {
            return false
        }

        var rhsRed: CGFloat = 0
        var rhsGreen: CGFloat = 0
        var rhsBlue: CGFloat = 0
        var rhsAlpha: CGFloat = 0
        guard rhsColor.getRed(&rhsRed, green: &rhsGreen, blue: &rhsBlue, alpha: &rhsAlpha) else {
            return false
        }

        return abs(lhsRed - rhsRed) < 0.001
            && abs(lhsGreen - rhsGreen) < 0.001
            && abs(lhsBlue - rhsBlue) < 0.001
            && abs(lhsAlpha - rhsAlpha) < 0.001
    }

    @MainActor
    private func expectedDefaultThemeForCurrentTime() -> AppThemeOption {
        let hour = Calendar.current.component(.hour, from: Date())
        return (6..<18).contains(hour) ? .holographicLight : .black
    }
}
