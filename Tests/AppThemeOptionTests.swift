import XCTest
import Foundation
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
            matches: UIColor(white: 0, alpha: 0.08)
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
            matches: UIColor(white: 0, alpha: 0.08)
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
        assertColor(
            AppThemeOption.light.palette.linkPreviewBorder,
            matches: UIColor.black.withAlphaComponent(0.08)
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
            AppThemeOption.system.palette.linkPreviewBorder,
            matches: UIColor.black.withAlphaComponent(0.08),
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
        let bottomTabBarHeight = FloatingComposeButtonLayout.defaultBottomTabBarHeight
        let padding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: bottomTabBarHeight,
            isBottomTabBarVisible: true
        )

        XCTAssertEqual(padding, 55)
    }

    func testFloatingComposePaddingSitsCloserWhenBottomBarIsHidden() {
        let bottomTabBarHeight = FloatingComposeButtonLayout.defaultBottomTabBarHeight
        let hiddenPadding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: bottomTabBarHeight,
            isBottomTabBarVisible: false
        )
        let visiblePadding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: bottomTabBarHeight,
            isBottomTabBarVisible: true
        )

        XCTAssertEqual(hiddenPadding, 32)
        XCTAssertLessThan(hiddenPadding, visiblePadding)
    }

    func testFloatingComposeButtonUsesRequestedTrailingPadding() {
        XCTAssertEqual(FloatingComposeButtonLayout.trailingPadding, 26)
    }

    func testFloatingComposePaddingMovesContinuouslyWithBottomBarOffset() {
        let bottomTabBarHeight = FloatingComposeButtonLayout.defaultBottomTabBarHeight
        let hiddenPadding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: bottomTabBarHeight,
            hiddenProgress: 1
        )
        let visiblePadding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: bottomTabBarHeight,
            hiddenProgress: 0
        )
        let halfwayPadding = FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: 34,
            bottomTabBarHeight: bottomTabBarHeight,
            hiddenProgress: 0.5
        )

        XCTAssertEqual(halfwayPadding, (hiddenPadding + visiblePadding) / 2, accuracy: 0.0001)
    }

    func testFloatingComposeButtonAnimatesAgainstNumericBottomPadding() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let overlayRange = try XCTUnwrap(source.range(of: "private var floatingComposeButtonOverlay: some View"))
        let buttonRange = try XCTUnwrap(source.range(of: "private var composeFloatingButton: some View"))
        let overlaySource = source[overlayRange.lowerBound..<buttonRange.lowerBound]

        XCTAssertTrue(overlaySource.contains("let bottomPadding = floatingComposeBottomPadding"))
        XCTAssertTrue(overlaySource.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(overlaySource.contains("FloatingComposeButtonLayout.movementAnimation"))
        XCTAssertTrue(overlaySource.contains("value: bottomPadding"))
    }

    func testFloatingComposeButtonTracksFullBottomBarHiddenProgress() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let progressRange = try XCTUnwrap(source.range(of: "private func bottomTabBarHiddenProgress"))
        let visibleRange = try XCTUnwrap(source.range(of: "private var composeSheetDraftBinding"))
        let progressSource = source[progressRange.lowerBound..<visibleRange.lowerBound]

        XCTAssertTrue(progressSource.contains("ScrollChromeLayout.bottomHiddenOffset"))
        XCTAssertTrue(progressSource.contains("ScrollChromeLayout.hiddenProgress"))
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

    func testHomeBottomBarUsesOverlayChrome() {
        XCTAssertTrue(
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

    func testScrollChromeTracksDownwardScrollDeltaContinuously() {
        let initial = ScrollChromeOffsets(
            previousScrollY: 10,
            topBarOffset: 0,
            bottomBarOffset: 0
        )

        let updated = ScrollChromeLayout.offsetsByApplyingScroll(
            currentScrollY: 30,
            state: initial,
            topBarHeight: 64,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(updated.previousScrollY, 30, accuracy: 0.0001)
        XCTAssertEqual(updated.topBarOffset, -20, accuracy: 0.0001)
        XCTAssertEqual(updated.bottomBarOffset, 30.9375, accuracy: 0.0001)
    }

    func testScrollChromeInitialMeasurementOnlyEstablishesScrollBaseline() {
        let updated = ScrollChromeLayout.offsetsByApplyingScroll(
            currentScrollY: 120,
            state: ScrollChromeOffsets(),
            topBarHeight: 64,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(updated.previousScrollY, 120, accuracy: 0.0001)
        XCTAssertEqual(updated.topBarOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(updated.bottomBarOffset, 0, accuracy: 0.0001)
        XCTAssertTrue(updated.hasMeasuredScrollY)
    }

    func testScrollChromeTracksUpwardScrollDeltaContinuously() {
        let initial = ScrollChromeOffsets(
            previousScrollY: 30,
            topBarOffset: -20,
            bottomBarOffset: 20
        )

        let updated = ScrollChromeLayout.offsetsByApplyingScroll(
            currentScrollY: 20,
            state: initial,
            topBarHeight: 64,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(updated.previousScrollY, 20, accuracy: 0.0001)
        XCTAssertEqual(updated.topBarOffset, -10, accuracy: 0.0001)
        XCTAssertEqual(updated.bottomBarOffset, 4.53125, accuracy: 0.0001)
    }

    func testScrollChromeBottomBarFinishesHidingWithTopBar() {
        let initial = ScrollChromeOffsets(
            previousScrollY: 0,
            topBarOffset: 0,
            bottomBarOffset: 0,
            hasMeasuredScrollY: true
        )

        let updated = ScrollChromeLayout.offsetsByApplyingScroll(
            currentScrollY: 64,
            state: initial,
            topBarHeight: 64,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(updated.topBarOffset, -64, accuracy: 0.0001)
        XCTAssertEqual(updated.bottomBarOffset, 99, accuracy: 0.0001)
    }

    func testScrollChromeRestoresAtTopOfFeed() {
        let initial = ScrollChromeOffsets(
            previousScrollY: 80,
            topBarOffset: -64,
            bottomBarOffset: 99
        )

        let updated = ScrollChromeLayout.offsetsByApplyingScroll(
            currentScrollY: 8,
            state: initial,
            topBarHeight: 64,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(updated.previousScrollY, 8, accuracy: 0.0001)
        XCTAssertEqual(updated.topBarOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(updated.bottomBarOffset, 0, accuracy: 0.0001)
    }

    func testScrollChromeSettlingPreservesPartialMovement() {
        let moved = ScrollChromeLayout.settledOffsets(
            topBarOffset: -30,
            bottomBarOffset: 50,
            topBarHeight: 64,
            bottomHiddenOffset: 99
        )

        XCTAssertEqual(moved.topBarOffset, -30, accuracy: 0.0001)
        XCTAssertEqual(moved.bottomBarOffset, 50, accuracy: 0.0001)
    }

    func testScrollChromeContentPaddingMatchesOverlayChrome() {
        let padding = ScrollChromeLayout.feedContentPadding(
            topBarHeight: 58,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(padding.top, 58, accuracy: 0.0001)
        XCTAssertEqual(padding.bottom, 99, accuracy: 0.0001)
    }

    func testScrollChromeContentPaddingStaysStableWhileBottomChromeMoves() {
        let hiddenPadding = ScrollChromeLayout.feedContentPadding(
            topBarHeight: 58,
            bottomBarHeight: 65,
            safeAreaBottom: 34,
            bottomBarVisibleFraction: 0
        )
        let partialPadding = ScrollChromeLayout.feedContentPadding(
            topBarHeight: 58,
            bottomBarHeight: 65,
            safeAreaBottom: 34,
            bottomBarVisibleFraction: 0.25
        )
        let visiblePadding = ScrollChromeLayout.feedContentPadding(
            topBarHeight: 58,
            bottomBarHeight: 65,
            safeAreaBottom: 34,
            bottomBarVisibleFraction: 1
        )

        XCTAssertEqual(hiddenPadding.top, 58, accuracy: 0.0001)
        XCTAssertEqual(hiddenPadding.bottom, 99, accuracy: 0.0001)
        XCTAssertEqual(partialPadding.bottom, 99, accuracy: 0.0001)
        XCTAssertEqual(visiblePadding.bottom, 99, accuracy: 0.0001)
    }

    func testHomeFeedKeepsTopPaddingStableWhileOverlayChromeMoves() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let paddingRange = try XCTUnwrap(source.range(of: "let contentPadding = ScrollChromeLayout.feedContentPadding"))
        let feedContentRange = try XCTUnwrap(source.range(of: "feedContent(", range: paddingRange.upperBound..<source.endIndex))
        let paddingSource = source[paddingRange.lowerBound..<feedContentRange.lowerBound]

        XCTAssertFalse(paddingSource.contains("topBarOffset:"))
    }

    func testHomeFeedScrollContentCanUnderlayHiddenChromeAtBothEdges() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains(".ignoresSafeArea(edges: [.top, .bottom])"))
    }

    func testScrollChromeContentPaddingStaysStableWhileTopChromeMoves() {
        let hiddenPadding = ScrollChromeLayout.feedContentPadding(
            topBarHeight: 58,
            topBarOffset: -58,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )
        let partialPadding = ScrollChromeLayout.feedContentPadding(
            topBarHeight: 58,
            topBarOffset: -20,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )
        let visiblePadding = ScrollChromeLayout.feedContentPadding(
            topBarHeight: 58,
            topBarOffset: 0,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(hiddenPadding.top, 58, accuracy: 0.0001)
        XCTAssertEqual(partialPadding.top, 58, accuracy: 0.0001)
        XCTAssertEqual(visiblePadding.top, 58, accuracy: 0.0001)
    }

    func testScrollChromeKeepsScrollBookkeepingOutOfPublishedChromeState() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")

        XCTAssertTrue(source.contains("final class ScrollChromeTracker"))
        XCTAssertTrue(source.contains("shouldPublishVisualOffsets"))
    }

    func testScrollChromeTopHiddenOffsetIncludesSafeArea() {
        XCTAssertEqual(
            ScrollChromeLayout.topHiddenOffset(
                topBarHeight: 58,
                safeAreaTop: 62
            ),
            120,
            accuracy: 0.0001
        )
    }

    func testHomeTopChromeStartsBelowSystemSafeAreaAndCollapsesWithIt() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("topSafeAreaInset: max(0, navigationGeometry.safeAreaInsets.top)"))
        XCTAssertTrue(source.contains("let safeAreaTop = max(max(0, topSafeAreaInset), geometry.safeAreaInsets.top)"))
        XCTAssertTrue(source.contains("let topHiddenOffset = ScrollChromeLayout.topHiddenOffset"))
        XCTAssertTrue(source.contains("topBarHeight: topHiddenOffset"))
        XCTAssertTrue(source.contains(".padding(.top, safeAreaTop)"))
        XCTAssertTrue(source.contains(".offset(y: scrollChromeOffsets.topBarOffset)"))
        XCTAssertTrue(source.contains("hiddenOffset: topHiddenOffset"))
    }

    func testHomeFeedCapturesSafeAreaBeforeRootIgnoresIt() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("GeometryReader { navigationGeometry in\n            NavigationStack"))
        XCTAssertTrue(source.contains("topSafeAreaInset: max(0, navigationGeometry.safeAreaInsets.top)"))
        XCTAssertTrue(source.contains("bottomSafeAreaInset: max(0, navigationGeometry.safeAreaInsets.bottom)"))
        XCTAssertTrue(source.contains("let topSafeAreaInset: CGFloat"))
        XCTAssertTrue(source.contains("let bottomSafeAreaInset: CGFloat"))
    }

    func testHomeFeedRootSpansDeviceEdgesLikeProfileHeader() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        XCTAssertTrue(source.contains("}\n        .ignoresSafeArea(edges: [.top, .bottom])\n        .toolbar(.hidden, for: .navigationBar)"))
    }

    func testHomeTopChromeBackgroundMovesAndFadesWithVisibleChrome() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertFalse(source.contains(".background(topNavigationBackground)"))
        XCTAssertFalse(source.contains("private var topNavigationBackground"))
        XCTAssertTrue(source.contains("let topVisibleFraction = topNavigationBarVisibleFraction"))
        XCTAssertTrue(source.contains(".background(topNavigationBarBackground)"))
        XCTAssertTrue(source.contains(".opacity(topVisibleFraction)"))
        XCTAssertTrue(source.contains("private var topNavigationBarBackground: some View"))
        XCTAssertTrue(source.contains("appSettings.themePalette.background"))
        XCTAssertTrue(source.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertTrue(source.contains(".fill(topNavigationControlFill)"))
    }

    func testHomeTopChromeFadesWithHiddenOffset() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("let topVisibleFraction = topNavigationBarVisibleFraction(topHiddenOffset: topHiddenOffset)"))
        XCTAssertTrue(source.contains(".opacity(topVisibleFraction)"))
        XCTAssertTrue(source.contains("offset: -scrollChromeOffsets.topBarOffset"))
    }

    func testHomePullToRefreshUsesNativeRefreshControl() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("let list = List {"))
        XCTAssertTrue(source.contains(".refreshable {\n            await refreshFeed()\n        }"))
        let refreshFunctionRange = try XCTUnwrap(source.range(of: "private func refreshFeed() async"))
        let revealFunctionRange = try XCTUnwrap(source.range(of: "private func revealBufferedNewItems", range: refreshFunctionRange.upperBound..<source.endIndex))
        let refreshFunctionSource = source[refreshFunctionRange.lowerBound..<revealFunctionRange.lowerBound]
        XCTAssertTrue(refreshFunctionSource.contains("await viewModel.refresh()"))
        XCTAssertFalse(refreshFunctionSource.contains("visibleBufferedNewItemsCount"))
        XCTAssertFalse(source.contains("ScrollView(.vertical"))
        XCTAssertFalse(source.contains("pullToRefreshIndicator"))
        XCTAssertFalse(source.contains("pullToRefreshDistance"))
        XCTAssertFalse(source.contains("isManualRefreshActive"))
        XCTAssertFalse(source.contains("max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))"))
    }

    func testHomeFeedKeepsBottomPaddingStableWhileOverlayChromeMoves() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let paddingRange = try XCTUnwrap(source.range(of: "let contentPadding = ScrollChromeLayout.feedContentPadding"))
        let feedContentRange = try XCTUnwrap(source.range(of: "feedContent(", range: paddingRange.upperBound..<source.endIndex))
        let paddingSource = source[paddingRange.lowerBound..<feedContentRange.lowerBound]

        XCTAssertFalse(paddingSource.contains("bottomContentVisibleFraction"))
        XCTAssertFalse(paddingSource.contains("bottomBarVisibleFraction"))
    }

    func testScrollChromeVisibleFractionTracksBottomOffset() {
        XCTAssertEqual(
            ScrollChromeLayout.visibleFraction(offset: 0, hiddenOffset: 100),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScrollChromeLayout.visibleFraction(offset: 40, hiddenOffset: 100),
            0.6,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScrollChromeLayout.visibleFraction(offset: 100, hiddenOffset: 100),
            0,
            accuracy: 0.0001
        )
    }

    func testScrollChromeBottomContentPaddingIgnoresSafeAreaSpacer() {
        XCTAssertEqual(
            ScrollChromeLayout.bottomContentVisibleFraction(
                offset: 0,
                bottomBarHeight: 65
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScrollChromeLayout.bottomContentVisibleFraction(
                offset: 32.5,
                bottomBarHeight: 65
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScrollChromeLayout.bottomContentVisibleFraction(
                offset: 65,
                bottomBarHeight: 65
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testNewNotesIslandTracksVisibleTopChromeHeight() {
        let visiblePadding = ScrollChromeLayout.newNotesIslandTopPadding(
            topBarHeight: 64,
            topBarOffset: 0
        )
        let partiallyHiddenPadding = ScrollChromeLayout.newNotesIslandTopPadding(
            topBarHeight: 64,
            topBarOffset: -32
        )
        let hiddenPadding = ScrollChromeLayout.newNotesIslandTopPadding(
            topBarHeight: 64,
            topBarOffset: -64
        )

        XCTAssertEqual(visiblePadding, 72, accuracy: 0.0001)
        XCTAssertEqual(partiallyHiddenPadding, 40, accuracy: 0.0001)
        XCTAssertEqual(hiddenPadding, 8, accuracy: 0.0001)
    }

    func testHomeFeedNewNotesIslandUsesPostedCopyAndSequencesReveal() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("Text(\"posted\")"))
        XCTAssertTrue(source.contains("private func revealBufferedNewItems(scrollProxy: ScrollViewProxy)"))
        XCTAssertTrue(source.contains("Self.bufferedRevealDelayNanoseconds"))

        let revealRange = try XCTUnwrap(source.range(of: "private func revealBufferedNewItems(scrollProxy: ScrollViewProxy)"))
        let revealSource = source[revealRange.lowerBound...]
        let scrollRange = try XCTUnwrap(revealSource.range(of: "scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)"))
        let showRange = try XCTUnwrap(revealSource.range(of: "viewModel.showBufferedNewItems()"))

        XCTAssertLessThan(scrollRange.lowerBound, showRange.lowerBound)
    }

    func testHomeFeedKeepsScrollChromeOffsetReaderOutsideLazyRows() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let scrollViewRange = try XCTUnwrap(source.range(of: "ScrollView(.vertical, showsIndicators: true) {"))
        let scrollContent = source[scrollViewRange.lowerBound...]
        let stackRange = try XCTUnwrap(scrollContent.range(of: "VStack(alignment: .leading, spacing: 0) {"))
        let sentinelRange = try XCTUnwrap(scrollContent.range(of: "feedTopPadding(height: topContentPadding)"))
        let lazyRowsRange = try XCTUnwrap(scrollContent.range(of: "LazyVStack(alignment: .leading, spacing: 0) {"))

        XCTAssertLessThan(stackRange.lowerBound, sentinelRange.lowerBound)
        XCTAssertLessThan(sentinelRange.lowerBound, lazyRowsRange.lowerBound)
    }

    func testHomeFeedUsesNativeScrollGeometryForChromeOffsets() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains(".onScrollGeometryChange(for: CGFloat.self)"))
        XCTAssertTrue(source.contains("handleScroll(currentScrollY: scrollY"))
    }

    func testOverlayBottomTabBarFadesWithScrollChromeVisibility() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let overlayRange = try XCTUnwrap(source.range(of: "private var overlayBottomTabBar: some View"))
        let overlaySource = source[overlayRange.lowerBound...]
        let frameRange = try XCTUnwrap(overlaySource.range(of: ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)"))
        let offsetRange = try XCTUnwrap(overlaySource.range(of: ".offset(y: bottomTabBarOffset(safeAreaBottom: safeAreaBottom))"))

        XCTAssertTrue(source.contains("if isBottomTabBarVisible {"))
        XCTAssertTrue(source.contains(".offset(y: bottomTabBarOffset(safeAreaBottom: safeAreaBottom))"))
        XCTAssertTrue(source.contains(".opacity(bottomTabBarVisibleFraction(safeAreaBottom: safeAreaBottom))"))
        XCTAssertLessThan(frameRange.lowerBound, offsetRange.lowerBound)
    }

    func testBottomTabBarDoesNotDoubleApplyBottomSafeAreaPadding() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let barRange = try XCTUnwrap(source.range(of: "private var bottomTabBar: some View"))
        let barSource = source[barRange.lowerBound...]

        XCTAssertTrue(source.contains("bottomTabBar"))
        XCTAssertTrue(source.contains("bottomTabBarOffset(safeAreaBottom: safeAreaBottom)"))
        XCTAssertFalse(barSource.contains(".frame(height: max(0, safeAreaBottom))"))
        XCTAssertFalse(barSource.contains(".padding(.bottom, max(0, safeAreaBottom))"))
        XCTAssertFalse(source.contains("bottomTabBarBackground\n                    .ignoresSafeArea(edges: .bottom)"))
    }

    func testBottomTabBarUsesFixedInternalVerticalPaddingForTapComfort() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let barRange = try XCTUnwrap(source.range(of: "private var bottomTabBar: some View"))
        let barSource = source[barRange.lowerBound...]

        XCTAssertTrue(source.contains("private static let bottomTabBarIconBottomPadding: CGFloat = 15"))
        XCTAssertTrue(source.contains("private static let bottomTabBarIconTopPadding: CGFloat = 5"))
        XCTAssertTrue(source.contains("static let defaultBottomTabBarHeight: CGFloat = 67"))
        XCTAssertTrue(barSource.contains(".padding(.top, Self.bottomTabBarIconTopPadding)"))
        XCTAssertTrue(barSource.contains(".padding(.bottom, Self.bottomTabBarIconBottomPadding)"))
        XCTAssertFalse(barSource.contains("safeAreaBottom + Self.bottomTabBarIconBottomPadding"))
    }

    func testBottomTabBarKeepsSafeAreaTransparentWhileUsingItForHiddenOffset() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let barRange = try XCTUnwrap(source.range(of: "private var bottomTabBar: some View"))
        let barSource = source[barRange.lowerBound...]
        let overlayRange = try XCTUnwrap(source.range(of: "private var overlayBottomTabBar: some View"))
        let overlaySource = source[overlayRange.lowerBound..<barRange.lowerBound]
        let visibleFractionRange = try XCTUnwrap(source.range(of: "private func bottomTabBarVisibleFraction"))
        let nextSectionRange = try XCTUnwrap(source.range(of: "private var composeSheetDraftBinding"))
        let visibleFractionSource = source[visibleFractionRange.lowerBound..<nextSectionRange.lowerBound]

        XCTAssertFalse(barSource.contains(".frame(height: max(0, safeAreaBottom))"))
        XCTAssertFalse(overlaySource.contains(".padding(.bottom, safeAreaBottom)"))
        XCTAssertTrue(overlaySource.contains(".ignoresSafeArea(edges: .bottom)"))
        XCTAssertTrue(source.contains(".offset(y: bottomTabBarOffset(safeAreaBottom: safeAreaBottom))"))
        XCTAssertTrue(source.contains("ScrollChromeLayout.bottomHiddenOffset"))
        XCTAssertTrue(visibleFractionSource.contains("ScrollChromeLayout.bottomContentVisibleFraction"))
        XCTAssertFalse(visibleFractionSource.contains("hiddenOffset: hiddenOffset"))
    }

    func testHomeNestedRoutesForceBottomTabBarVisible() throws {
        let shellSource = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let homeSource = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(shellSource.contains("@State private var isHomeRootVisible = true"))
        XCTAssertTrue(shellSource.contains("isRootVisible: $isHomeRootVisible"))
        XCTAssertTrue(homeSource.contains("@Binding var isRootVisible: Bool"))
        XCTAssertTrue(shellSource.contains("guard selectedTab == .home, isHomeRootVisible else { return 0 }"))
        XCTAssertTrue(shellSource.contains("guard selectedTab == .home, isHomeRootVisible else { return 1 }"))
    }

    func testReservedBottomInsetDoesNotRenderSecondTabBar() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let insetRange = try XCTUnwrap(source.range(of: ".safeAreaInset(edge: .bottom, spacing: 0)"))
        let overlayRange = try XCTUnwrap(source.range(of: ".overlay(alignment: .bottom)"))
        let insetSource = source[insetRange.lowerBound..<overlayRange.lowerBound]

        XCTAssertTrue(insetSource.contains("Color.clear"))
        XCTAssertTrue(insetSource.contains(".frame(height: bottomTabBarHeight)"))
        XCTAssertFalse(insetSource.contains("bottomTabBar(safeAreaBottom: 0)"))
    }

    func testHomeProfileDestinationsReceiveSharedScrollChromeContext() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")

        XCTAssertTrue(source.contains(".environment(\\.flowScrollChromeOffsets, $homeScrollChrome)"))
        XCTAssertTrue(source.contains(".environment(\\.flowBottomTabBarHeight, bottomTabBarHeight)"))
    }

    func testProfileBottomClearanceStaysStableWhileSharedScrollChromeMoves() throws {
        let source = try sourceText(at: "Sources/Profile/ProfileView.swift")
        let clearanceRange = try XCTUnwrap(source.range(of: "private func profileBottomScrollClearance"))
        let nextSectionRange = try XCTUnwrap(source.range(of: "private var profileBackButton"))
        let clearanceSource = source[clearanceRange.lowerBound..<nextSectionRange.lowerBound]

        XCTAssertFalse(source.contains("private static let bottomScrollClearance: CGFloat = 110"))
        XCTAssertTrue(source.contains("@Environment(\\.flowScrollChromeOffsets)"))
        XCTAssertTrue(source.contains("profileBottomScrollClearance("))
        XCTAssertFalse(clearanceSource.contains("ScrollChromeLayout.bottomContentVisibleFraction"))
        XCTAssertTrue(source.contains(".onScrollGeometryChange(for: CGFloat.self)"))
        XCTAssertTrue(source.contains(".ignoresSafeArea(edges: [.top, .bottom])"))
    }

    func testSideMenuUsesWhiteLightSurfaceDarkerDarkSurfaceAndTintedIconCircles() throws {
        let source = try sourceText(at: "Sources/Home/HomeSlideoutMenuView.swift")

        XCTAssertTrue(source.contains("private static let darkMenuBackground = Color(red: 17.0 / 255.0, green: 17.0 / 255.0, blue: 17.0 / 255.0)"))
        XCTAssertTrue(source.contains("effectiveMenuColorScheme == .light ? .white : Self.darkMenuBackground"))
        XCTAssertTrue(source.contains("let iconTint = tint ?? appSettings.themePalette.foreground.opacity(0.86)"))
        XCTAssertTrue(source.contains("let textTint = tint ?? appSettings.themePalette.foreground"))
        XCTAssertTrue(source.contains(".foregroundStyle(iconTint)"))
        XCTAssertTrue(source.contains(".foregroundStyle(textTint)"))
        XCTAssertTrue(source.contains("private func menuCircleBackgroundFill(tint: Color? = nil) -> Color {"))
        XCTAssertTrue(source.contains("return baseTint.opacity(effectiveMenuColorScheme == .light ? 0.08 : 0.16)"))
        XCTAssertTrue(source.contains("private func menuCircleStroke(tint: Color? = nil) -> Color {"))
        XCTAssertTrue(source.contains("return baseTint.opacity(effectiveMenuColorScheme == .light ? 0.12 : 0.22)"))
        XCTAssertTrue(source.contains("menuCircleBackgroundFill(tint: tint)"))
        XCTAssertTrue(source.contains("menuCircleStroke(tint: tint)"))
        XCTAssertFalse(source.contains(".background(.ultraThinMaterial, in: Circle())"))
        XCTAssertTrue(source.contains("SideMenuTransitionLayout.logoutTopSpacing"))
    }

    func testSideMenuProfileCloseOverlaysBannerAndQRAlignsWithIdentity() throws {
        let source = try sourceText(at: "Sources/Home/HomeSlideoutMenuView.swift")
        let headerStart = try XCTUnwrap(source.range(of: "private func accountProfileHeader(_ account: AuthAccount) -> some View {"))
        let headerEnd = try XCTUnwrap(source.range(of: "private var closeOnlyHeader: some View"))
        let headerSource = source[headerStart.lowerBound..<headerEnd.lowerBound]
        let bannerRange = try XCTUnwrap(headerSource.range(of: "SideMenuProfileBannerArtwork"))
        let identityRange = try XCTUnwrap(headerSource.range(of: "HStack(alignment: .center"))
        let qrRange = try XCTUnwrap(headerSource.range(of: "profileQRButton"))
        let closeRange = try XCTUnwrap(headerSource.range(of: "closeMenuButton"))

        XCTAssertLessThan(bannerRange.lowerBound, closeRange.lowerBound)
        XCTAssertLessThan(closeRange.lowerBound, identityRange.lowerBound)
        XCTAssertLessThan(identityRange.lowerBound, qrRange.lowerBound)
        XCTAssertTrue(headerSource.contains("accountHeaderBannerURL"))
        XCTAssertTrue(headerSource.contains("SideMenuTransitionLayout.profileHeaderAvatarSize / 2"))
    }

    func testHomeSideMenuStartsBelowTopSafeArea() throws {
        let homeSource = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let sideMenuSource = try sourceText(at: "Sources/Design/SideMenuContainer.swift")
        let sideMenuRange = try XCTUnwrap(homeSource.range(of: "SideMenuContainer("))
        let sideMenuCallSource = homeSource[sideMenuRange.lowerBound...]

        XCTAssertTrue(sideMenuCallSource.contains("isOpen: $isShowingSideMenu"))
        XCTAssertTrue(sideMenuCallSource.contains("topSafeAreaInset: safeAreaTop"))
        XCTAssertTrue(sideMenuSource.contains("let resolvedTopSafeArea = SideMenuTransitionLayout.resolvedTopSafeArea("))
        XCTAssertTrue(sideMenuSource.contains("explicitTopSafeAreaInset: topSafeAreaInset,"))
        XCTAssertTrue(sideMenuSource.contains("geometryTopSafeAreaInset: geometry.safeAreaInsets.top"))
        XCTAssertTrue(sideMenuSource.contains(".frame(width: width, height: height, alignment: .topLeading)"))
        XCTAssertTrue(sideMenuSource.contains(".offset(\n                x: isOpen ? 0 : -width * SideMenuTransitionLayout.menuClosedOffsetFraction,\n                y: topOffset\n            )"))
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

    @MainActor
    func testApplyingLinkColorColorsOnlyLinkedRuns() throws {
        var attributed = AttributedString("Visit Halo and docs")

        let haloRange = try XCTUnwrap(attributed.range(of: "Halo"))
        attributed[haloRange].link = try XCTUnwrap(URL(string: "https://halo.example"))

        let styled = AttributedLinkStyler.applyingLinkColor(.blue, to: attributed)
        var expected = attributed
        expected[haloRange].foregroundColor = .blue

        let styledVisitRange = try XCTUnwrap(styled.range(of: "Visit"))

        XCTAssertEqual(styled, expected)
        XCTAssertNil(styled[styledVisitRange].foregroundColor)
    }

    @MainActor
    func testApplyingLinkColorRetintsMarkdownLinks() throws {
        let parsed = try XCTUnwrap(try? AttributedString(markdown: "Read [Halo](https://halo.example)"))
        let haloRange = try XCTUnwrap(parsed.range(of: "Halo"))

        let styled = AttributedLinkStyler.applyingLinkColor(.red, to: parsed)
        var expected = parsed
        expected[haloRange].foregroundColor = .red

        XCTAssertEqual(styled, expected)
    }

    func testFollowStatusBadgesUsePrimaryColorInsteadOfAccentAsset() throws {
        let feedRowSource = try sourceText(at: "Sources/Design/FeedRowView.swift")
        let followBadgeRange = try XCTUnwrap(feedRowSource.range(of: "private func followBadge(iconName: String) -> some View {"))
        let repostBannerRange = try XCTUnwrap(feedRowSource.range(of: "private var repostBanner: some View"))
        let followBadgeSource = feedRowSource[followBadgeRange.lowerBound..<repostBannerRange.lowerBound]

        XCTAssertTrue(followBadgeSource.contains(".foregroundStyle(appSettings.primaryColor)"))
        XCTAssertFalse(followBadgeSource.contains(".foregroundStyle(Color.accentColor)"))

        let threadSource = try sourceText(at: "Sources/Thread/ThreadDetailComponents.swift")
        let rootStatusRange = try XCTUnwrap(threadSource.range(of: "if let rootFollowStatusIconName {"))
        let rootStatusSource = threadSource[rootStatusRange.lowerBound...]

        XCTAssertTrue(rootStatusSource.contains(".foregroundStyle(appSettings.primaryColor)"))
        XCTAssertFalse(rootStatusSource.contains(".foregroundStyle(Color.accentColor)"))

        let profileSource = try sourceText(at: "Sources/Profile/ProfileHeaderSection.swift")
        let profileStatusRange = try XCTUnwrap(profileSource.range(of: "if let followStatusIconName {"))
        let profileStatusSource = profileSource[profileStatusRange.lowerBound...]

        XCTAssertTrue(profileStatusSource.contains(".foregroundStyle(appSettings.primaryColor)"))
        XCTAssertFalse(profileStatusSource.contains(".foregroundStyle(Color.accentColor)"))
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

    private func sourceText(at relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRootURL = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repositoryRootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

final class QRCodeRendererTests: XCTestCase {
    func testRenderReusesImageForRepeatedPayload() throws {
        let payload = "nostr:npub1flowtestpayload"

        let firstImage = try XCTUnwrap(QRCodeRenderer.render(payload: payload))
        let secondImage = try XCTUnwrap(QRCodeRenderer.render(payload: payload))

        XCTAssertTrue(firstImage === secondImage)
    }
}
