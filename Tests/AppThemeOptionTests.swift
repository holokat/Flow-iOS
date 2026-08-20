import XCTest
import Foundation
import SwiftUI
import UIKit
@testable import Flow

final class AppThemeOptionTests: XCTestCase {
    @MainActor
    func testRemovedLightAliasesNormalizeToLight() {
        for theme in [AppThemeOption.white, .sakura, .holographicLight] {
            XCTAssertFalse(theme.isEnabled)
            XCTAssertEqual(theme.normalizedSelection, .light)
            XCTAssertEqual(theme.preferredColorScheme, .light)
            XCTAssertEqual(theme.title, "Light")
            assertColor(theme.palette.background, matches: .white)
        }
    }

    @MainActor
    func testRemovedDarkAliasesNormalizeToDark() {
        for theme in [AppThemeOption.dracula, .gamer, .holographicDark, .dark] {
            XCTAssertFalse(theme.isEnabled)
            XCTAssertEqual(theme.normalizedSelection, .black)
            XCTAssertEqual(theme.preferredColorScheme, .dark)
            XCTAssertEqual(theme.title, "Dark")
            assertColor(theme.palette.background, matches: .black)
        }
    }

    @MainActor
    func testPaletteTitlesAndVisibleOptionsReflectRenamedChoices() {
        XCTAssertEqual(AppThemeOption.black.title, "Dark")
        XCTAssertEqual(AppThemeOption.dark.title, "Dark")
        XCTAssertEqual(AppThemeOption.dracula.title, "Dark")
        XCTAssertEqual(AppThemeOption.gamer.title, "Dark")
        XCTAssertEqual(AppThemeOption.holographicLight.title, "Light")
        XCTAssertEqual(AppThemeOption.light.title, "Light")
        XCTAssertEqual(AppThemeOption.sakura.normalizedSelection, .light)
        XCTAssertEqual(
            AppThemeOption.onboardingOptions,
            [.light, .black, .system]
        )
        XCTAssertEqual(
            AppThemeOption.appearanceOptions,
            [.light, .black, .system]
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
    func testLegacyHolographicDarkIsDisabledAndNormalizesToDark() {
        XCTAssertFalse(AppThemeOption.holographicDark.isEnabled)
        XCTAssertEqual(AppThemeOption.holographicDark.normalizedSelection, .black)
        XCTAssertEqual(AppThemeOption.holographicDark.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemeOption.holographicDark.title, "Dark")
        XCTAssertNil(AppThemeOption.holographicDark.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.holographicDark.fixedPrimaryGradient)
        XCTAssertNil(AppThemeOption.holographicDark.qrShareBackgroundResourceName)
    }

    @MainActor
    func testFixedAccentMatchesLightAndDarkProductBlue() {
        assertColor(
            AppSettingsStore.defaultPrimaryColor,
            matches: UIColor(red: 40.0 / 255.0, green: 95.0 / 255.0, blue: 244.0 / 255.0, alpha: 1),
            style: .light
        )
        assertColor(
            AppSettingsStore.defaultPrimaryColor,
            matches: UIColor(red: 63.0 / 255.0, green: 142.0 / 255.0, blue: 247.0 / 255.0, alpha: 1),
            style: .dark
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
        settings.primaryColor = .red

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertFalse(reloaded.usesPrimaryGradientForProminentButtons)
        XCTAssertNil(reloaded.activeButtonGradientOption)
        XCTAssertNil(reloaded.activeHolographicGradientOption)
        assertColor(
            reloaded.primaryColor,
            matches: UIColor(red: 40.0 / 255.0, green: 95.0 / 255.0, blue: 244.0 / 255.0, alpha: 1)
        )
        assertColor(
            reloaded.linkColor,
            matches: UIColor(red: 40.0 / 255.0, green: 95.0 / 255.0, blue: 244.0 / 255.0, alpha: 1)
        )
        XCTAssertFalse(reloaded.canCustomizePrimaryColor)
    }

    @MainActor
    func testSavedCustomPrimaryColorCannotOverrideFixedAccent() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "1", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)
        let customColor = Color(red: 0.18, green: 0.42, blue: 0.73)

        settings.configure(accountPubkey: pubkey)
        settings.primaryColor = customColor

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        assertColor(
            reloaded.primaryColor,
            matches: UIColor(red: 40.0 / 255.0, green: 95.0 / 255.0, blue: 244.0 / 255.0, alpha: 1)
        )
        assertColor(
            reloaded.linkColor,
            matches: UIColor(red: 40.0 / 255.0, green: 95.0 / 255.0, blue: 244.0 / 255.0, alpha: 1)
        )
        XCTAssertNil(reloaded.selectedPrimaryColorOption)

        reloaded.primaryColor = AppSettingsStore.availablePrimaryColorOptions[0].color

        assertColor(
            reloaded.primaryColor,
            matches: UIColor(red: 40.0 / 255.0, green: 95.0 / 255.0, blue: 244.0 / 255.0, alpha: 1)
        )
        XCTAssertNil(reloaded.selectedPrimaryColorOption)
    }

    @MainActor
    func testClickSoundEffectIsAlwaysSilent() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "2", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.configure(accountPubkey: pubkey)

        XCTAssertEqual(settings.clickSoundEffect, .none)
        XCTAssertTrue(AppClickSoundEffect.audibleCases.isEmpty)

        settings.clickSoundEffect = .none

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertEqual(reloaded.clickSoundEffect, .none)
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
    func testRemovedLightThemeSelectionUsesLightPalette() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "d", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.configure(accountPubkey: pubkey)
        settings.theme = .holographicLight
        settings.primaryColor = AppSettingsStore.availablePrimaryColorOptions[0].color

        let palette = settings.themePalette
        let basePalette = AppThemeOption.light.palette

        XCTAssertEqual(settings.theme, .light)

        assertColor(
            palette.profileActionStyle!.primaryForeground,
            matches: UIColor(basePalette.profileActionStyle!.primaryForeground)
        )
        assertColor(
            palette.capsuleTabStyle!.selectedForeground,
            matches: UIColor(basePalette.capsuleTabStyle!.selectedForeground)
        )
        assertColor(palette.background, matches: UIColor.white)
        assertColor(palette.chromeBackground, matches: UIColor.white)
        assertColor(palette.navigationBackground, matches: UIColor.white)
        assertColor(palette.sheetBackground, matches: UIColor(basePalette.sheetBackground))
        assertColor(
            palette.chromeBorder,
            matches: UIColor(white: 0, alpha: 0.04)
        )
        assertColor(
            palette.linkPreviewBorder,
            matches: UIColor(white: 0, alpha: 0.08)
        )
        XCTAssertTrue(colorsMatch(palette.secondaryFill, basePalette.secondaryFill))
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
        assertColor(
            reloaded.primaryColor,
            matches: UIColor(red: 40.0 / 255.0, green: 95.0 / 255.0, blue: 244.0 / 255.0, alpha: 1)
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
        XCTAssertTrue(AppThemeOption.black.isEnabled)
        XCTAssertTrue(AppThemeOption.system.isEnabled)
        XCTAssertEqual(AppThemeOption.light.title, "Light")
        XCTAssertEqual(AppThemeOption.black.title, "Dark")
        XCTAssertEqual(AppThemeOption.system.title, "System")
        XCTAssertFalse(AppThemeOption.dark.isEnabled)
        XCTAssertFalse(AppThemeOption.holographicLight.isEnabled)
        XCTAssertFalse(AppThemeOption.dracula.isEnabled)
        XCTAssertFalse(AppThemeOption.gamer.isEnabled)
        XCTAssertEqual(
            AppThemeOption.appearanceOptions,
            [.light, .black, .system]
        )
        XCTAssertFalse(AppThemeOption.appearanceOptions.contains(.white))
        XCTAssertFalse(AppThemeOption.appearanceOptions.contains(.holographicDark))
    }

    func testAppearancePalettePickerIsCompactWithoutStandaloneLabel() throws {
        let source = try sourceText(at: "Sources/Home/SettingsAppearanceView.swift")

        XCTAssertFalse(source.contains("Text(\"Color Palette\")"))
        XCTAssertTrue(source.contains("HStack(spacing: 8)"))
        XCTAssertTrue(source.contains("ForEach(appearanceThemeOptions)"))
        XCTAssertTrue(source.contains(".frame(height: 42)"))
        XCTAssertFalse(source.contains("LazyVGrid(\n                        columns: [\n                            GridItem(.flexible(), spacing: 10)"))
    }

    func testOnboardingPalettePickerIsInlineWithoutStandaloneLabel() throws {
        let source = try sourceText(at: "Sources/Onboarding/SignupOnboardingView.swift")
        let paletteStart = try XCTUnwrap(source.range(of: "HStack(spacing: 8) {\n                        ForEach(Self.onboardingThemeOptions)"))
        let paletteSource = source[paletteStart.lowerBound...]

        XCTAssertFalse(source.contains("fieldLabel(\"Color Palette\")"))
        XCTAssertTrue(paletteSource.contains("ForEach(Self.onboardingThemeOptions)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 50)"))
        XCTAssertFalse(paletteSource.prefix(400).contains("LazyVGrid"))
        XCTAssertFalse(paletteSource.prefix(400).contains("GridItem(.flexible(minimum: 140)"))
    }

    @MainActor
    func testThemePreviewOverridesActiveTheme() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.theme = .system
        settings.beginThemePreview(.light)

        XCTAssertEqual(settings.activeTheme, .light)
        XCTAssertEqual(settings.preferredColorScheme, .light)
        XCTAssertEqual(settings.previewTheme, .light)
    }

    @MainActor
    func testLegacyWhiteThemeSelectionNormalizesToLight() {
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
    func testLegacyHolographicDarkSelectionNormalizesToDark() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.theme = .holographicDark

        XCTAssertEqual(settings.theme, .black)
        XCTAssertEqual(settings.activeTheme, .black)
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
    func testFontPreviewKeepsSystemFont() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.fontOption = .system
        settings.beginFontPreview(.inter)

        XCTAssertEqual(settings.activeFontOption, .system)
        XCTAssertNil(settings.previewFontOption)
        XCTAssertEqual(settings.fontOption, .system)
    }

    @MainActor
    func testFontSelectionAlwaysResetsToSystem() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let authStore = AuthStore(defaults: defaults)
        let pubkey = String(repeating: "d", count: 64)
        let settings = AppSettingsStore(defaults: defaults, authStore: authStore)

        settings.configure(accountPubkey: pubkey)
        settings.fontOption = .ebGaramond

        let reloaded = AppSettingsStore(defaults: defaults, authStore: authStore)
        reloaded.configure(accountPubkey: pubkey)

        XCTAssertEqual(reloaded.fontOption, .system)
        XCTAssertEqual(reloaded.activeFontOption, .system)
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
        XCTAssertNotNil(AppThemeOption.black.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.black.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.black.palette.pollStyle)
        assertColor(
            AppThemeOption.black.palette.capsuleTabStyle!.background,
            matches: UIColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1)
        )
        assertColor(
            AppThemeOption.black.palette.capsuleTabStyle!.selectedBackground,
            matches: UIColor.white.withAlphaComponent(0.14)
        )
        assertColor(
            AppThemeOption.black.palette.capsuleTabStyle!.selectedBorder,
            matches: UIColor.white.withAlphaComponent(0.24)
        )
        assertColor(
            AppThemeOption.black.palette.capsuleTabStyle!.selectedForeground,
            matches: UIColor.white.withAlphaComponent(0.95)
        )
        assertColor(
            AppThemeOption.black.palette.profileActionStyle!.background,
            matches: UIColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1)
        )
        assertColor(
            AppThemeOption.black.palette.pollStyle!.cardBackground,
            matches: UIColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1)
        )
        assertColor(
            AppThemeOption.black.palette.pollStyle!.optionBackground,
            matches: UIColor(red: 0.082, green: 0.082, blue: 0.082, alpha: 1)
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
        assertColor(
            AppThemeOption.light.palette.sheetCardBorder,
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
    func testLegacyDarkThemeUsesBlackPalette() {
        XCTAssertEqual(AppThemeOption.dark.preferredColorScheme, .dark)
        XCTAssertNil(AppThemeOption.dark.fixedPrimaryColor)
        XCTAssertNil(AppThemeOption.dark.fixedPrimaryGradient)
        assertColor(
            AppThemeOption.dark.palette.background,
            matches: .black
        )
        XCTAssertNotNil(AppThemeOption.dark.palette.capsuleTabStyle)
        XCTAssertNotNil(AppThemeOption.dark.palette.profileActionStyle)
        XCTAssertNotNil(AppThemeOption.dark.palette.pollStyle)
        assertColor(
            AppThemeOption.dark.palette.pollStyle!.cardBackground,
            matches: UIColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1)
        )
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
            AppThemeOption.system.palette.sheetCardBorder,
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
            matches: .black,
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.navigationBackground,
            matches: .black,
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.sheetCardBackground,
            matches: UIColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1),
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.sheetCardBorder,
            matches: UIColor(red: 0.235, green: 0.235, blue: 0.235, alpha: 1),
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.capsuleTabStyle!.background,
            matches: UIColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1),
            style: .dark
        )
        assertColor(
            AppThemeOption.system.palette.pollStyle!.cardBackground,
            matches: UIColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1),
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

    func testBottomTabBarStaysVisibleOnHomeRoot() {
        XCTAssertTrue(
            ScrollChromeLayout.isBottomTabBarVisible(
                isHomeSideMenuPresented: false
            )
        )
    }

    func testBottomTabBarStillHidesBehindHomeSideMenu() {
        XCTAssertFalse(
            ScrollChromeLayout.isBottomTabBarVisible(
                isHomeSideMenuPresented: true
            )
        )
    }

    func testBottomTabBarStaysVisibleOnNestedDirectMessagesScreen() {
        XCTAssertTrue(
            ScrollChromeLayout.isBottomTabBarVisible(
                isHomeSideMenuPresented: false
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

    @MainActor
    func testScrollChromeStoreCanForceStartupChromeVisible() {
        let store = ScrollChromeStore()
        store.publishVisualOffsetsIfNeeded(
            ScrollChromeOffsets(
                previousScrollY: 90,
                topBarOffset: -66,
                bottomBarOffset: 84,
                hasMeasuredScrollY: true
            )
        )

        XCTAssertEqual(store.offsets.bottomBarOffset, 84, accuracy: 0.0001)

        store.showChromeAtRest()

        XCTAssertEqual(store.offsets.topBarOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(store.offsets.bottomBarOffset, 0, accuracy: 0.0001)
        XCTAssertFalse(store.offsets.hasMeasuredScrollY)
        XCTAssertEqual(
            ScrollChromeLayout.chromeOpacity(
                bottomBarOffset: store.offsets.bottomBarOffset,
                bottomBarHeight: 50,
                safeAreaBottom: 34
            ),
            1,
            accuracy: 0.0001
        )
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
            safeAreaTop: 47,
            bottomBarHeight: 65,
            safeAreaBottom: 34
        )

        XCTAssertEqual(padding.top, 105, accuracy: 0.0001)
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

    func testHomeFeedExtendsBehindTransparentTopAndBottomChrome() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains(".ignoresSafeArea(edges: [.top, .bottom])"))
        XCTAssertTrue(source.contains(".contentMargins(.vertical, 0, for: .scrollContent)"))
        XCTAssertTrue(source.contains(".homeFeedNativeTabBarMinimizeBehavior()"))
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

    func testHomeScrollChromeStateIsScopedToChromeObservers() throws {
        let shellSource = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let homeSource = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let profileSource = try sourceText(at: "Sources/Profile/ProfileView.swift")

        XCTAssertTrue(shellSource.contains("@State private var homeScrollChromeStore = ScrollChromeStore()"))
        XCTAssertFalse(shellSource.contains("@State private var homeScrollChrome = ScrollChromeOffsets()"))
        XCTAssertTrue(shellSource.contains("scrollChromeStore: homeScrollChromeStore"))
        XCTAssertTrue(shellSource.contains("ScrollChromeOpacityReader("))
        XCTAssertTrue(shellSource.contains("ScrollChromeLayout.chromeOpacity("))
        XCTAssertTrue(shellSource.contains("homeScrollChromeStore.showChromeAtRest()"))
        XCTAssertTrue(shellSource.contains("bottomNavigationCapsule\n                .frame(maxWidth: 520)"))
        XCTAssertTrue(shellSource.contains("GlassEffectContainer(spacing: 8)"))
        XCTAssertTrue(shellSource.contains(".contentShape(Rectangle())\n                .opacity(chromeOpacity)"))
        XCTAssertTrue(shellSource.contains("TabView(selection: tabSelection)"))
        XCTAssertTrue(shellSource.contains("func flowNativeTabBarHidden() -> some View"))
        XCTAssertTrue(shellSource.contains(".environment(\\.flowBottomTabBarHeight, bottomTabBarHeight)"))
        XCTAssertTrue(shellSource.contains("private var customBottomNavBar: some View"))
        XCTAssertTrue(homeSource.contains("let scrollChromeStore: ScrollChromeStore"))
        XCTAssertTrue(homeSource.contains("@ObservedObject var scrollChromeStore: ScrollChromeStore"))
        XCTAssertTrue(homeSource.contains("showScrollChromeAtRest()"))
        XCTAssertTrue(homeSource.contains("scrollChromeTracker.resetBaseline()"))
        XCTAssertTrue(homeSource.contains("scrollChromeStore.showChromeAtRest()"))
        XCTAssertTrue(homeSource.contains("HomeFeedTopNavigationChromeView("))
        XCTAssertTrue(homeSource.contains("HomeFeedNewNotesChromeOverlay("))
        XCTAssertTrue(profileSource.contains("@Environment(\\.flowScrollChromeStore)"))
        XCTAssertFalse(profileSource.contains("@Environment(\\.flowScrollChromeOffsets)"))
    }

    func testHomeTopChromeUsesPulseStyleStickyBar() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let topNavChromeStart = try XCTUnwrap(source.range(of: "private struct HomeFeedTopNavigationChromeView"))
        let topNavChromeEnd = try XCTUnwrap(source.range(of: "private struct HomeFeedNewNotesChromeOverlay"))
        let topNavChromeSource = source[topNavChromeStart.lowerBound..<topNavChromeEnd.lowerBound]

        XCTAssertFalse(source.contains("topNavigationToTabsSpacing"))
        XCTAssertTrue(source.contains("ZStack(alignment: .top) {"))
        XCTAssertFalse(source.contains(".safeAreaInset(edge: .top, spacing: 0)"))
        XCTAssertTrue(source.contains("feedContent(\n                contentPadding.bottom,\n                contentPadding.top,\n                safeAreaBottom\n            )"))
        XCTAssertTrue(source.contains("feedTopChromeClearance(height: topBarHeight)\n                .homeFeedListRow()"))
        XCTAssertTrue(source.contains("HomeFeedTopNavigationChromeView(\n                scrollChromeStore: scrollChromeStore,\n                bottomBarHeight: bottomTabBarHeight,\n                safeAreaTop: safeAreaTop,\n                safeAreaBottom: safeAreaBottom,\n                topNavigationBar: topNavigationBar\n            )"))
        XCTAssertTrue(topNavChromeSource.contains("topNavigationBar()\n            .padding(.top, safeAreaTop)\n            .background(topNavigationBarBackground)\n            .opacity(chromeOpacity)"))
        XCTAssertTrue(topNavChromeSource.contains("ScrollChromeLayout.chromeOpacity("))
        XCTAssertFalse(source.contains("topSafeAreaInset: max(0, navigationGeometry.safeAreaInsets.top)"))
        XCTAssertFalse(source.contains("let safeAreaTop = max(max(0, topSafeAreaInset), geometry.safeAreaInsets.top)"))
        XCTAssertFalse(source.contains("topNavigationContentHeight"))
        XCTAssertFalse(source.contains("topHiddenOffset"))
        XCTAssertFalse(source.contains("topBarHeight: topNavigationContentHeight"))
        XCTAssertFalse(source.contains("topNavigationContentHeight + topNavigationToTabsSpacing"))
        XCTAssertTrue(topNavChromeSource.contains("let safeAreaTop: CGFloat"))
        XCTAssertTrue(topNavChromeSource.contains(".padding(.top, safeAreaTop)"))
        XCTAssertFalse(topNavChromeSource.contains(".offset(y: topBarOffset)"))
    }

    func testHomeFeedUsesPulseStyleSafeAreaBehavior() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("NavigationStack {\n            HomeFeedRootContent("))
        XCTAssertFalse(source.contains("GeometryReader { navigationGeometry in"))
        XCTAssertFalse(source.contains("topSafeAreaInset: max(0, navigationGeometry.safeAreaInsets.top)"))
        XCTAssertFalse(source.contains("bottomSafeAreaInset: max(0, navigationGeometry.safeAreaInsets.bottom)"))
        XCTAssertTrue(source.contains("let safeAreaTop = max(0, geometry.safeAreaInsets.top)"))
        XCTAssertTrue(source.contains("safeAreaTop: safeAreaTop"))
        XCTAssertFalse(source.contains("let topSafeAreaInset: CGFloat"))
        XCTAssertFalse(source.contains("let bottomSafeAreaInset: CGFloat"))
    }

    func testHomeFeedDestinationsStayAttachedToHomeRootContent() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let rootStart = try XCTUnwrap(source.range(of: "private var navigationRoot: some View {"))
        let feedContentStart = try XCTUnwrap(source.range(of: "private func feedContent", range: rootStart.upperBound..<source.endIndex))
        let rootSource = String(source[rootStart.lowerBound..<feedContentStart.lowerBound])

        XCTAssertTrue(rootSource.contains("NavigationStack {\n            HomeFeedRootContent("))
        XCTAssertTrue(rootSource.contains("            )\n            .modifier(navigationDestinationsModifier)\n        }"))
        XCTAssertFalse(rootSource.contains("            }\n            .modifier(navigationDestinationsModifier)\n        }"))
    }

    func testHomeFeedRootUsesSafeAreaClearanceInsideEdgeToEdgeScrollContent() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let rootStart = try XCTUnwrap(source.range(of: "private struct HomeFeedRootContent"))
        let rootEnd = try XCTUnwrap(source.range(of: "private struct HomeFeedTopNavigationChromeView"))
        let rootSource = source[rootStart.lowerBound..<rootEnd.lowerBound]

        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        XCTAssertTrue(source.contains("}\n        .toolbar(.hidden, for: .navigationBar)"))
        XCTAssertTrue(rootSource.contains("let safeAreaTop = max(0, geometry.safeAreaInsets.top)"))
        XCTAssertTrue(rootSource.contains("safeAreaTop: safeAreaTop"))
        XCTAssertTrue(rootSource.contains(".ignoresSafeArea(edges: [.top, .bottom])"))
    }

    func testHomeTopChromeUsesStaticThemeBackground() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let topNavChromeStart = try XCTUnwrap(source.range(of: "private struct HomeFeedTopNavigationChromeView"))
        let topNavChromeEnd = try XCTUnwrap(source.range(of: "private struct HomeFeedNewNotesChromeOverlay"))
        let topNavChromeSource = source[topNavChromeStart.lowerBound..<topNavChromeEnd.lowerBound]

        XCTAssertFalse(source.contains(".background(topNavigationBackground)"))
        XCTAssertFalse(source.contains("private var topNavigationBackground"))
        XCTAssertTrue(topNavChromeSource.contains("topNavigationBar()\n            .padding(.top, safeAreaTop)\n            .background(topNavigationBarBackground)\n            .opacity(chromeOpacity)"))
        XCTAssertTrue(source.contains(".background(topNavigationBarBackground)"))
        XCTAssertTrue(source.contains("private var topNavigationBarBackground: some View"))
        XCTAssertTrue(source.contains("appSettings.themePalette.background"))
        XCTAssertTrue(topNavChromeSource.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertTrue(source.contains(".fill(topNavigationControlFill)"))
    }

    func testHomeTopChromeDoesNotFadeWithHiddenOffset() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertFalse(source.contains("topNavigationBarVisibleFraction"))
        XCTAssertFalse(source.contains("ScrollChromeLayout.visibleFraction"))
        XCTAssertFalse(source.contains("offset: -topBarOffset"))
        XCTAssertTrue(source.contains("private var chromeOpacity: Double"))
        XCTAssertTrue(source.contains("ScrollChromeLayout.chromeOpacity("))
    }

    func testHomePullToRefreshUsesNativeRefreshControl() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains("let list = List {"))
        XCTAssertTrue(source.contains(".refreshable {\n            await refreshFeed()\n        }"))
        let refreshFunctionRange = try XCTUnwrap(source.range(of: "private func refreshFeed() async"))
        let revealFunctionRange = try XCTUnwrap(source.range(of: "private func revealBufferedNewItems", range: refreshFunctionRange.upperBound..<source.endIndex))
        let refreshFunctionSource = source[refreshFunctionRange.lowerBound..<revealFunctionRange.lowerBound]
        XCTAssertTrue(refreshFunctionSource.contains("await viewModel.refresh(force: true)"))
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

    func testScrollChromeOpacityDimsOnScrollDownAndRestoresOnScrollUp() {
        XCTAssertEqual(
            ScrollChromeLayout.chromeOpacity(
                bottomBarOffset: 0,
                bottomBarHeight: 50,
                safeAreaBottom: 0
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScrollChromeLayout.chromeOpacity(
                bottomBarOffset: 25,
                bottomBarHeight: 50,
                safeAreaBottom: 0
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScrollChromeLayout.chromeOpacity(
                bottomBarOffset: 50,
                bottomBarHeight: 50,
                safeAreaBottom: 0
            ),
            ScrollChromeLayout.dimmedChromeOpacity,
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

        let revealRange = try XCTUnwrap(source.range(of: "private func revealBufferedNewItems(scrollProxy: ScrollViewProxy)"))
        let revealEndRange = try XCTUnwrap(
            source.range(
                of: "private func configureFeedDependenciesAndLoad()",
                range: revealRange.upperBound..<source.endIndex
            )
        )
        let revealSource = source[revealRange.lowerBound..<revealEndRange.lowerBound]
        let showRange = try XCTUnwrap(revealSource.range(of: "viewModel.showBufferedNewItems()"))
        let scrollRange = try XCTUnwrap(
            revealSource.range(of: "scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)")
        )

        XCTAssertLessThan(showRange.lowerBound, scrollRange.lowerBound)
        XCTAssertFalse(revealSource.contains("revealTargetID"))
        XCTAssertEqual(
            revealSource.components(separatedBy: "guard viewModel.visibleBufferedNewItemsCount > 0").count,
            2
        )
        XCTAssertTrue(source.contains(".id(item.id)\n                        .homeFeedListRow()"))
    }

    func testHomeFeedKeepsScrollChromeOffsetReaderOutsideLazyRows() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let listRange = try XCTUnwrap(source.range(of: "let list = List {"))
        let listContent = source[listRange.lowerBound...]
        let rowsRange = try XCTUnwrap(listContent.range(of: "feedRows("))
        let trackedHeaderRange = try XCTUnwrap(listContent.range(of: "topTrackedRow(feedModeHeaderRow.homeFeedListRow(), isFirst: true)"))

        XCTAssertTrue(source.contains("private func topTrackedRow<Row: View>(_ row: Row, isFirst: Bool) -> some View"))
        XCTAssertTrue(source.contains("private func feedTopChromeClearance(height: CGFloat) -> some View {\n        Color.clear\n            .frame(height: max(0, height))\n            .id(Self.feedTopAnchorID)"))
        XCTAssertFalse(source.contains(".background(feedTopOffsetReader)\n                .id(Self.feedTopAnchorID)"))
        XCTAssertFalse(source.contains("feedTopAnchorRow"))
        XCTAssertFalse(source.contains("feedTopPadding"))
        XCTAssertFalse(source.contains("topContentPadding"))
        XCTAssertLessThan(trackedHeaderRange.lowerBound, rowsRange.lowerBound)
        XCTAssertFalse(source.contains("LazyVStack(alignment: .leading, spacing: 0)"))
    }

    func testHomeFeedUsesExplicitScrollProxyForReliableTopReveal() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let feedContentRange = try XCTUnwrap(source.range(of: "private func feedContent("))
        let feedListRange = try XCTUnwrap(source.range(of: "@ViewBuilder\n    private func feedList", range: feedContentRange.upperBound..<source.endIndex))
        let feedContentSource = source[feedContentRange.lowerBound..<feedListRange.lowerBound]

        XCTAssertTrue(feedContentSource.contains("ScrollViewReader { scrollProxy in"))
        XCTAssertTrue(source.contains("scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)"))
        XCTAssertFalse(source.contains("@State private var feedScrollTarget: String?"))
        XCTAssertFalse(source.contains(".scrollPosition(id: $feedScrollTarget, anchor: .top)"))
        XCTAssertTrue(source.contains(".contentMargins(.vertical, 0, for: .scrollContent)"))
        XCTAssertFalse(source.contains(".environment(\\.defaultMinListRowHeight, 0)"))
        XCTAssertTrue(source.contains(".homeFeedNativeTabBarMinimizeBehavior()"))
        XCTAssertTrue(source.contains("self.scrollEdgeEffectHidden(true, for: .bottom)"))
        XCTAssertFalse(source.contains("self.tabBarMinimizeBehavior(.onScrollDown)"))
        XCTAssertFalse(source.contains("let topNavigationBar: () -> AnyView"))
        XCTAssertFalse(source.contains("let feedContent: (_ topPadding: CGFloat, _ bottomPadding: CGFloat, _ topBarHeight: CGFloat, _ safeAreaBottom: CGFloat) -> AnyView"))
        XCTAssertFalse(source.contains("_ topPadding: CGFloat"))
        XCTAssertFalse(source.contains("let sideMenuContent: () -> AnyView"))
    }

    func testHomeFeedUsesNativeScrollGeometryForChromeOffsets() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(source.contains(".onScrollGeometryChange(for: CGFloat.self)"))
        XCTAssertTrue(source.contains("handleScroll(currentScrollY: scrollY"))
    }

    func testFeedSourcePickerCanOpenFeedsSettingsForCreateFeed() throws {
        let source = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let pickerRange = try XCTUnwrap(source.range(of: "private var feedSourcePickerSheet"))
        let optionRange = try XCTUnwrap(source.range(of: "private func feedSourceOptionButton", range: pickerRange.upperBound..<source.endIndex))
        let pickerSource = source[pickerRange.lowerBound..<optionRange.lowerBound]

        XCTAssertTrue(pickerSource.contains("Label(\"Create Feed\", systemImage: \"plus.circle.fill\")"))
        XCTAssertTrue(source.contains("private func openFeedsSettingsFromFeedSourcePicker()"))
        XCTAssertTrue(source.contains("settingsSheetState.show(.feeds)"))
        XCTAssertTrue(source.contains("isShowingSettings = true"))
    }

    func testFeedsSettingsShowsCustomFeedsInline() throws {
        let feedsSource = try sourceText(at: "Sources/Home/SettingsFeedsView.swift")
        let customFeedsSource = try sourceText(at: "Sources/Home/SettingsCustomFeedsView.swift")

        XCTAssertTrue(feedsSource.contains("SettingsCustomFeedsSection()"))
        XCTAssertFalse(feedsSource.contains("SettingsNavigationRow(title: \"Custom Feeds\""))
        XCTAssertFalse(feedsSource.contains("Choose what powers Interests and News."))
        XCTAssertTrue(customFeedsSource.contains("struct SettingsCustomFeedsSection"))
        XCTAssertTrue(customFeedsSource.contains("Label(\"Create Feed\", systemImage: \"plus.circle.fill\")"))
        XCTAssertTrue(customFeedsSource.contains("ForEach(appSettings.customFeeds)"))
        XCTAssertFalse(customFeedsSource.contains(".background(appSettings.themePalette.sheetCardBackground"))
        XCTAssertFalse(customFeedsSource.contains(".listRowBackground(Color.clear)"))
        XCTAssertFalse(customFeedsSource.contains("Text(\"Custom Feeds\")"))
        XCTAssertFalse(customFeedsSource.contains("Mix hashtags, people, and phrases into feeds"))
    }

    func testCustomFeedEditorUsesSeparateConciseSourceCards() throws {
        let source = try sourceText(at: "Sources/Home/SettingsCustomFeedsView.swift")

        XCTAssertTrue(source.contains("Section(\"Hashtags\")"))
        XCTAssertTrue(source.contains("Section(\"People\")"))
        XCTAssertTrue(source.contains("Section(\"Phrases\")"))
        XCTAssertTrue(source.contains("Text(\"Feed icon\")"))
        XCTAssertFalse(source.contains("Section(\"Add Hashtag\")"))
        XCTAssertFalse(source.contains("Section(\"Add Phrase\")"))
        XCTAssertFalse(source.contains("Hashtags pull in topic-based notes"))
        XCTAssertFalse(source.contains("People always pull notes"))
        XCTAssertFalse(source.contains("Phrases search across note content"))
    }

    func testBottomNavigationUsesCustomBarAndKeepsNativeTabBarHidden() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")

        XCTAssertTrue(source.contains("TabView(selection: tabSelection)"))
        XCTAssertTrue(source.contains("SwiftUI.Tab(value: Tab.compose)"))
        XCTAssertTrue(source.contains("private func tabBarIcon(for tab: Tab)"))
        XCTAssertTrue(source.contains(".tabItem { tabBarIcon(for: .home) }"))
        XCTAssertTrue(source.contains(".tabItem { tabBarIcon(for: .search) }"))
        XCTAssertTrue(source.contains(".tabItem { tabBarIcon(for: .compose) }"))
        XCTAssertTrue(source.contains(".tabItem { tabBarIcon(for: .dms) }"))
        XCTAssertTrue(source.contains("private var activityTabShowsUnreadBadge: Bool"))
        XCTAssertTrue(source.contains("activityViewModel.hasUnread && !isActivityListVisible"))
        XCTAssertTrue(source.contains("if tab == .activity, activityTabShowsUnreadBadge"))
        XCTAssertTrue(source.contains("if reservesBottomTabBarInsetSpace {\n                customBottomNavBar\n            }"))
        XCTAssertTrue(source.contains("if usesOverlayBottomTabBar {\n                customBottomNavBar\n            }"))
        XCTAssertTrue(source.contains("ForEach(Tab.allCases, id: \\.self)"))
        XCTAssertTrue(source.contains("Button {\n            handleTabSelection(tab)"))
        XCTAssertTrue(source.contains("func flowNativeTabBarHidden() -> some View"))
        XCTAssertEqual(source.components(separatedBy: ".flowNativeTabBarHidden()").count - 1, 10)
        XCTAssertTrue(source.contains(".toolbar(.hidden, for: .tabBar)"))
        XCTAssertFalse(source.contains("private var usesNativeBottomNavigationBar: Bool"))
        XCTAssertFalse(source.contains("private var usesCustomBottomNavigationBar: Bool"))
        XCTAssertFalse(source.contains("private var nativeBottomNavigationVisibility: Visibility"))
        XCTAssertFalse(source.contains("usesNativeBottomNavigationBar ? .visible : .hidden"))
        XCTAssertFalse(source.contains(".badge(activityTabBadgeLabel)"))
        XCTAssertFalse(source.contains("ActivityTabUnreadBadgeModifier"))
        XCTAssertFalse(source.contains("showsUnreadDot"))
        XCTAssertFalse(source.contains(".frame(width: 8, height: 8)"))
        XCTAssertFalse(source.contains("homeCollapsedTabAffordance"))
        XCTAssertFalse(source.contains("shouldShowCollapsedHomeTabAffordance"))
        XCTAssertFalse(source.contains(".toolbar(nativeBottomNavigationVisibility, for: .tabBar)"))
        XCTAssertTrue(source.contains(".environment(\\.symbolVariants, .none)"))
        XCTAssertFalse(source.contains("private func tabBarLabel"))
        XCTAssertTrue(source.contains("GlassEffectContainer(spacing: 8)"))
        XCTAssertTrue(source.contains(".glassEffect(.regular.interactive(), in: Capsule())"))
        XCTAssertTrue(source.contains(".background(.ultraThinMaterial, in: Capsule())"))
        XCTAssertTrue(source.contains("Image(isSelected ? tab.selectedPhosphorIconName : tab.phosphorIconName)"))
    }

    func testComposeTabUsesNativeItemAsActionWithoutSelectingPlaceholder() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let selectionRange = try XCTUnwrap(source.range(of: "private var tabSelection: Binding<Tab>"))
        let effectiveRelayRange = try XCTUnwrap(source.range(of: "private var effectiveWriteRelayURLs"))
        let selectionSource = source[selectionRange.lowerBound..<effectiveRelayRange.lowerBound]

        XCTAssertTrue(source.contains("case compose"))
        XCTAssertTrue(source.contains("Color.clear"))
        XCTAssertTrue(source.contains(".tag(Tab.compose)"))
        XCTAssertTrue(source.contains("SwiftUI.Tab(value: Tab.compose)"))
        XCTAssertTrue(selectionSource.contains("guard newValue != .compose else"))
        XCTAssertTrue(selectionSource.contains("handleComposeTap()"))
        XCTAssertFalse(selectionSource.contains("selectedTab = .compose"))
    }

    func testNativeTabBarDoesNotRenderSecondCustomBottomBar() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")

        XCTAssertFalse(source.contains("private struct BottomTabBarChromeOverlay: View"))
        XCTAssertFalse(source.contains("private struct FloatingComposeButtonChromeOverlay: View"))
        XCTAssertFalse(source.contains("FloatingComposeButtonLayout"))
        XCTAssertFalse(source.contains("floatingComposeButtonOverlay"))
        XCTAssertFalse(source.contains("private var bottomTabBar"))
        XCTAssertFalse(source.contains("private func bottomTabBar(safeAreaBottom: CGFloat)"))
        XCTAssertFalse(source.contains("BottomTabBarHeightPreferenceKey"))
        XCTAssertFalse(source.contains("ConditionalOpacityModifier"))
    }

    func testHomeNestedRoutesForceBottomTabBarVisible() throws {
        let shellSource = try sourceText(at: "Sources/App/MainTabShellView.swift")
        let homeSource = try sourceText(at: "Sources/Home/HomeFeedView.swift")

        XCTAssertTrue(shellSource.contains("@State private var isHomeRootVisible = true"))
        XCTAssertTrue(shellSource.contains("isRootVisible: $isHomeRootVisible"))
        XCTAssertTrue(homeSource.contains("@Binding var isRootVisible: Bool"))
        XCTAssertTrue(shellSource.contains("if usesOverlayBottomTabBar {\n                customBottomNavBar\n            }"))
        XCTAssertTrue(shellSource.contains("func flowNativeTabBarHidden() -> some View"))
        XCTAssertFalse(shellSource.contains("private var nativeBottomNavigationVisibility: Visibility"))
        XCTAssertFalse(shellSource.contains("usesNativeBottomNavigationBar ? .visible : .hidden"))
        XCTAssertFalse(shellSource.contains("private func shouldHideNativeTabBarForHomeScroll"))
    }

    func testReservedBottomInsetUsesTheSharedCustomTabBar() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")

        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertTrue(source.contains("if reservesBottomTabBarInsetSpace {\n                customBottomNavBar\n            }"))
        XCTAssertFalse(source.contains("Color.clear\n                    .frame(height: bottomTabBarHeight)"))
        XCTAssertFalse(source.contains("bottomTabBar(safeAreaBottom: 0)"))
    }

    func testHomeProfileDestinationsReceiveSharedScrollChromeContext() throws {
        let source = try sourceText(at: "Sources/App/MainTabShellView.swift")

        XCTAssertTrue(source.contains(".environment(\\.flowScrollChromeStore, homeScrollChromeStore)"))
        XCTAssertTrue(source.contains(".environment(\\.flowBottomTabBarHeight, bottomTabBarHeight)"))
    }

    func testProfileBottomClearanceStaysStableWhileSharedScrollChromeMoves() throws {
        let source = try sourceText(at: "Sources/Profile/ProfileView.swift")
        let clearanceRange = try XCTUnwrap(source.range(of: "private func profileBottomScrollClearance"))
        let nextSectionRange = try XCTUnwrap(source.range(of: "private var profileBackButton"))
        let clearanceSource = source[clearanceRange.lowerBound..<nextSectionRange.lowerBound]

        XCTAssertFalse(source.contains("private static let bottomScrollClearance: CGFloat = 110"))
        XCTAssertTrue(source.contains("@Environment(\\.flowScrollChromeStore)"))
        XCTAssertTrue(source.contains("profileBottomScrollClearance("))
        XCTAssertFalse(clearanceSource.contains("ScrollChromeLayout.bottomContentVisibleFraction"))
        XCTAssertTrue(source.contains(".onScrollGeometryChange(for: CGFloat.self)"))
        XCTAssertTrue(source.contains(".ignoresSafeArea(edges: [.top, .bottom])"))
    }

    func testSideMenuUsesDistinctDarkBackgroundAndUnframedNavigationRows() throws {
        let source = try sourceText(at: "Sources/Home/HomeSlideoutMenuView.swift")

        XCTAssertFalse(source.contains("private static let darkMenuBackground"))
        XCTAssertTrue(source.contains("if effectiveColorScheme == .dark"))
        XCTAssertTrue(source.contains("red: 17.0 / 255.0"))
        XCTAssertTrue(source.contains("green: 17.0 / 255.0"))
        XCTAssertTrue(source.contains("blue: 17.0 / 255.0"))
        XCTAssertTrue(source.contains("appSettings.themePalette.background"))
        XCTAssertTrue(source.contains("let iconTint = tint ?? appSettings.themePalette.foreground.opacity(0.9)"))
        XCTAssertTrue(source.contains("let textTint = tint ?? appSettings.themePalette.foreground"))
        XCTAssertTrue(source.contains(".foregroundStyle(iconTint)"))
        XCTAssertTrue(source.contains(".foregroundStyle(textTint)"))
        XCTAssertTrue(source.contains(".font(.system(size: 21, weight: .regular))"))
        XCTAssertTrue(source.contains(".frame(minHeight: 56)"))
        XCTAssertTrue(source.contains("SideMenuPressButtonStyle"))
        XCTAssertTrue(source.contains("? 0.96"))
        XCTAssertFalse(source.contains("menuCircleBackgroundFill"))
        XCTAssertFalse(source.contains("menuCircleStroke"))
        XCTAssertFalse(source.contains(".background(.ultraThinMaterial, in: Circle())"))
        XCTAssertTrue(source.contains("SideMenuTransitionLayout.logoutTopSpacing"))
    }

    func testSideMenuProfileHeaderUsesAvatarIdentityAndQRWithoutBanner() throws {
        let source = try sourceText(at: "Sources/Home/HomeSlideoutMenuView.swift")
        let headerStart = try XCTUnwrap(source.range(of: "private func accountProfileHeader(_ account: AuthAccount) -> some View {"))
        let headerEnd = try XCTUnwrap(source.range(of: "private var guestHeader: some View"))
        let headerSource = source[headerStart.lowerBound..<headerEnd.lowerBound]
        let avatarRange = try XCTUnwrap(headerSource.range(of: "accountHeaderAvatar"))
        let identityRange = try XCTUnwrap(headerSource.range(of: "Text(resolvedName)"))
        let qrRange = try XCTUnwrap(headerSource.range(of: "profileQRButton"))

        XCTAssertLessThan(avatarRange.lowerBound, qrRange.lowerBound)
        XCTAssertLessThan(qrRange.lowerBound, identityRange.lowerBound)
        XCTAssertFalse(headerSource.contains("SideMenuProfileBannerArtwork"))
        XCTAssertFalse(headerSource.contains("closeMenuButton"))
        XCTAssertFalse(source.contains("accountHeaderBannerURL"))
        XCTAssertTrue(headerSource.contains("max(menuSafeAreaInsets.top, 0) + 14"))
        XCTAssertTrue(source.contains("Color.white.opacity(0.1)"))
        XCTAssertTrue(source.contains("Color.black.opacity(0.1)"))
    }

    func testHomeSideMenuUsesContainerSafeAreaResolution() throws {
        let homeSource = try sourceText(at: "Sources/Home/HomeFeedView.swift")
        let sideMenuSource = try sourceText(at: "Sources/Design/SideMenuContainer.swift")
        let sideMenuRange = try XCTUnwrap(homeSource.range(of: "SideMenuContainer("))
        let sideMenuCallSource = homeSource[sideMenuRange.lowerBound...]

        // The container must stay mounted regardless of menu state so the
        // open/close spring and row stagger animations can play.
        XCTAssertFalse(homeSource.contains("if isShowingSideMenu {\n                    SideMenuContainer("))
        XCTAssertTrue(homeSource.contains("private func primaryContent("))
        XCTAssertTrue(sideMenuCallSource.contains("isOpen: $isShowingSideMenu"))
        XCTAssertTrue(sideMenuCallSource.contains("topSafeAreaInset: safeAreaTop"))
        XCTAssertTrue(sideMenuCallSource.contains("menuBackground: HomeSlideoutMenuStyle.background("))
        XCTAssertTrue(sideMenuSource.contains("let resolvedTopSafeArea = SideMenuTransitionLayout.resolvedTopSafeArea("))
        XCTAssertTrue(sideMenuSource.contains("explicitTopSafeAreaInset: topSafeAreaInset,"))
        XCTAssertTrue(sideMenuSource.contains("geometryTopSafeAreaInset: geometry.safeAreaInsets.top"))
        XCTAssertTrue(sideMenuSource.contains("private let menuBackground: Color"))
        XCTAssertTrue(sideMenuSource.contains("menuBackground\n                    .frame(width: geometry.size.width, height: geometry.size.height)"))
        XCTAssertTrue(sideMenuSource.contains(".frame(width: width, height: height, alignment: .topLeading)"))
        XCTAssertTrue(sideMenuSource.contains(".ignoresSafeArea()"))
        XCTAssertTrue(sideMenuSource.contains(".environment(\\.sideMenuSafeAreaInsets, safeAreaInsets)"))
        XCTAssertTrue(sideMenuSource.contains(".environment(\\.sideMenuPresentationProgress, progress)"))
        XCTAssertTrue(sideMenuSource.contains(".simultaneousGesture(sideMenuDragGesture(openOffset: openOffset), including: .all)"))
        XCTAssertTrue(sideMenuSource.contains("value.predictedEndTranslation.width"))
        XCTAssertTrue(sideMenuSource.contains("UnevenRoundedRectangle("))
        XCTAssertTrue(sideMenuSource.contains("topLeadingRadius: cornerRadius"))
        XCTAssertTrue(sideMenuSource.contains("bottomLeadingRadius: cornerRadius"))
        XCTAssertTrue(sideMenuSource.contains(".clipShape(panelShape)"))
        XCTAssertFalse(sideMenuSource.contains("SideMenuLeadingRoundedShape"))
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

    func testLeavingActivityTabRequestsActivityRootReset() {
        let effects = MainTabSelectionPolicy.effects(
            previousTab: .activity,
            selectedTab: .home,
            wasActivityRootVisible: false
        )

        XCTAssertTrue(effects.resetsActivityRoot)
    }

    func testRedundantActivitySelectionDoesNotResetDetailNavigation() {
        let effects = MainTabSelectionPolicy.effects(
            previousTab: .activity,
            selectedTab: .activity,
            wasActivityRootVisible: false
        )

        XCTAssertFalse(effects.resetsActivityRoot)
    }

    func testSelectingActivityUsesSameRootFromEveryOtherTab() {
        for origin in [MainTabShellView.Tab.home, .search, .dms] {
            let effects = MainTabSelectionPolicy.effects(
                previousTab: origin,
                selectedTab: .activity,
                wasActivityRootVisible: true
            )

            XCTAssertFalse(effects.resetsHomeRoot, "Origin: \(origin)")
            XCTAssertFalse(effects.resetsSearchRoot, "Origin: \(origin)")
            XCTAssertFalse(effects.resetsActivityRoot, "Origin: \(origin)")
        }
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

        let profileSource = try sourceText(at: "Sources/Profile/ProfileControls.swift")
        let profileStatusRange = try XCTUnwrap(profileSource.range(of: "struct ProfileActionTextButton: View"))
        let profileStatusSource = profileSource[profileStatusRange.lowerBound...]

        XCTAssertTrue(profileStatusSource.contains("appSettings.primaryColor"))
        XCTAssertTrue(profileStatusSource.contains("appSettings.buttonTextColor"))
        XCTAssertFalse(profileStatusSource.contains("style?.primaryForeground"))
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
        .system
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
