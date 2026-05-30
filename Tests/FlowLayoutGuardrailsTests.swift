import XCTest
import SwiftUI
import Foundation
import UIKit
@testable import Flow

final class FlowLayoutGuardrailsTests: XCTestCase {
    func testSoftWrappedLeavesShortStringsUntouched() {
        let value = "hello world"

        XCTAssertEqual(FlowLayoutGuardrails.softWrapped(value), value)
    }

    func testSoftWrappedInsertsBreaksForLongUnbrokenRuns() {
        let value = "https://example.com/" + String(repeating: "a", count: 60)
        let wrapped = FlowLayoutGuardrails.softWrapped(value)

        XCTAssertNotEqual(wrapped, value)
        XCTAssertTrue(wrapped.contains("\u{200B}"))
        XCTAssertEqual(wrapped.replacingOccurrences(of: "\u{200B}", with: ""), value)
    }

    func testSoftWrappedCanProtectShorterProfileRuns() {
        let value = String(repeating: "A", count: 24)
        let wrapped = FlowLayoutGuardrails.softWrapped(
            value,
            maxNonBreakingRunLength: 8,
            minimumLength: 8
        )

        XCTAssertTrue(wrapped.contains("\u{200B}"))
        XCTAssertEqual(wrapped.replacingOccurrences(of: "\u{200B}", with: ""), value)
    }

    func testClampedAspectRatioRejectsInvalidValuesAndCapsOutliers() throws {
        XCTAssertNil(FlowLayoutGuardrails.clampedAspectRatio(nil))
        XCTAssertNil(FlowLayoutGuardrails.clampedAspectRatio(0))
        XCTAssertEqual(try XCTUnwrap(FlowLayoutGuardrails.clampedAspectRatio(0.05)), 0.28, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(FlowLayoutGuardrails.clampedAspectRatio(10)), 3.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(FlowLayoutGuardrails.clampedAspectRatio(1.6)), 1.6, accuracy: 0.0001)
    }

    func testAspectFitMediaSizeKeepsWideMediaWithinAvailableWidth() {
        let size = FlowLayoutGuardrails.aspectFitMediaSize(
            availableWidth: 320,
            aspectRatio: 3.2,
            maxHeight: 620,
            fallbackWidth: 320
        )

        XCTAssertEqual(size.width, 320, accuracy: 0.0001)
        XCTAssertEqual(size.height, 100, accuracy: 0.0001)
    }

    func testAspectFitMediaSizeCapsTallMediaHeightWithoutStretching() {
        let size = FlowLayoutGuardrails.aspectFitMediaSize(
            availableWidth: 320,
            aspectRatio: 0.4,
            maxHeight: 300,
            fallbackWidth: 320
        )

        XCTAssertEqual(size.width, 120, accuracy: 0.0001)
        XCTAssertEqual(size.height, 300, accuracy: 0.0001)
    }

    func testAspectFitMediaSizeCanPreserveFullWidthWhenTallMediaHeightIsCapped() {
        let size = FlowLayoutGuardrails.aspectFitMediaSize(
            availableWidth: 320,
            aspectRatio: 0.4,
            maxHeight: 300,
            fallbackWidth: 320,
            preservesAvailableWidthWhenHeightCapped: true
        )

        XCTAssertEqual(size.width, 320, accuracy: 0.0001)
        XCTAssertEqual(size.height, 300, accuracy: 0.0001)
    }

    func testProfileHeaderWidthUsesFiniteProposal() {
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.boundedWidth(
                proposedWidth: 300,
                fallbackWidth: 320
            ),
            300,
            accuracy: 0.0001
        )
    }

    func testProfileHeaderWidthCapsOversizedProposalToVisibleFallback() {
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.boundedWidth(
                proposedWidth: 420,
                fallbackWidth: 320
            ),
            320,
            accuracy: 0.0001
        )
    }

    func testProfileHeaderTrailingChromeIgnoresOversizedParentWidth() {
        let originX = ProfileHeaderLayoutGuardrails.trailingControlOriginX(
            parentWidth: 1_200,
            visibleWidth: 320,
            controlWidth: 36,
            horizontalPadding: 16
        )

        XCTAssertEqual(originX, 268, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(originX + 36, 304)
    }

    func testProfileHeaderWidthFallsBackWhenProposalIsInvalid() {
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.boundedWidth(
                proposedWidth: nil,
                fallbackWidth: 320
            ),
            320,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.boundedWidth(
                proposedWidth: .infinity,
                fallbackWidth: 320
            ),
            320,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.boundedWidth(
                proposedWidth: -1,
                fallbackWidth: 320
            ),
            320,
            accuracy: 0.0001
        )
    }

    func testProfileHeaderBannerUsesMoreImmersiveHeight() {
        XCTAssertEqual(ProfileHeaderBannerMetrics.height, LongFormArticleReaderLayout.heroMinHeight)
        XCTAssertEqual(
            ProfileHeaderBannerMetrics.fadeHeight,
            ProfileHeaderBannerMetrics.height * 0.21,
            accuracy: 0.0001
        )
        XCTAssertLessThan(ProfileHeaderBannerMetrics.fadeHeight, ProfileHeaderBannerMetrics.height * 0.24)
        XCTAssertLessThan(ProfileHeaderBannerMetrics.topScrimOpacity, 0.06)
        XCTAssertLessThanOrEqual(ProfileHeaderBannerMetrics.bottomFadeMidOpacity, 0.1)
        XCTAssertLessThanOrEqual(ProfileHeaderBannerMetrics.bottomFadeStrongOpacity, 0.5)
    }

    func testLoadedProfileBannerImagesStayClearAboveBottomFade() {
        XCTAssertGreaterThanOrEqual(ProfileHeaderBannerMetrics.loadedImageOpacity, 0.94)
        XCTAssertEqual(ProfileHeaderBannerMetrics.loadedImageSaturation, 1, accuracy: 0.0001)
    }

    func testProfileHeaderTopControlsRespectTopSafeArea() {
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.topControlsTopPadding(safeAreaInset: 0),
            12,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.topControlsTopPadding(safeAreaInset: 47),
            59,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ProfileHeaderLayoutGuardrails.topControlsTopPadding(safeAreaInset: -8),
            12,
            accuracy: 0.0001
        )
    }

    func testProfileHeaderEntranceMotionSettlesAvatarAndIdentityAtDifferentSpeeds() {
        XCTAssertGreaterThan(
            ProfileHeaderEntranceMotion.springResponse(for: .avatar),
            ProfileHeaderEntranceMotion.springResponse(for: .identity)
        )

        let avatarStart = ProfileHeaderEntranceMotion.presentation(
            for: .avatar,
            isSettled: false,
            reduceMotion: false
        )
        let identityStart = ProfileHeaderEntranceMotion.presentation(
            for: .identity,
            isSettled: false,
            reduceMotion: false
        )
        let avatarReducedMotion = ProfileHeaderEntranceMotion.presentation(
            for: .avatar,
            isSettled: false,
            reduceMotion: true
        )

        XCTAssertGreaterThan(avatarStart.yOffset, identityStart.yOffset)
        XCTAssertLessThan(avatarStart.scale, identityStart.scale)
        XCTAssertEqual(avatarReducedMotion.yOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(avatarReducedMotion.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(avatarReducedMotion.opacity, 1, accuracy: 0.0001)
    }

    func testComposeToolbarUsesCompactThemeAwareControls() {
        XCTAssertEqual(ComposeToolbarLayout.cancelButtonFontWeight, ComposeToolbarLayout.publishButtonFontWeight)
        XCTAssertEqual(ComposeToolbarLayout.cancelButtonFontWeight, .semibold)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.leadingItemSpacing, 8)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.trailingItemSpacing, 8)
        XCTAssertGreaterThan(ComposeToolbarLayout.draftButtonBackgroundOpacity, 0)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.draftButtonBackgroundOpacity, 1)
    }

    func testComposeMediaAttachmentsSitAboveBottomToolbarOutsideEditorCard() throws {
        let sheetSource = try Self.sourceText(at: "Sources/Compose/ComposeNoteSheet.swift")
        let accessorySource = try Self.sourceText(at: "Sources/Compose/ComposeNoteSheetAccessoryViews.swift")
        let bottomBarStart = try XCTUnwrap(sheetSource.range(of: "private var composeBottomAccessoryBar: some View {"))
        let bottomBarEnd = try XCTUnwrap(sheetSource.range(of: "private var composeAttachmentToolbar", range: bottomBarStart.upperBound..<sheetSource.endIndex))
        let bottomBarSource = sheetSource[bottomBarStart.lowerBound..<bottomBarEnd.lowerBound]
        let previewRange = try XCTUnwrap(bottomBarSource.range(of: "ComposeMediaAttachmentStrip("))
        let toolbarRange = try XCTUnwrap(bottomBarSource.range(of: "composeAttachmentToolbar"))
        let cardStart = try XCTUnwrap(accessorySource.range(of: "struct ComposeComposerCardView: View {"))
        let cardEnd = try XCTUnwrap(accessorySource.range(of: "struct ComposeAttachmentToolbarBar: View {"))
        let cardSource = accessorySource[cardStart.lowerBound..<cardEnd.lowerBound]

        XCTAssertTrue(sheetSource.contains(".safeAreaInset(edge: .bottom, spacing: 0) {\n            composeBottomAccessoryBar\n        }"))
        XCTAssertLessThan(previewRange.lowerBound, toolbarRange.lowerBound)
        XCTAssertFalse(cardSource.contains("ComposeMediaAttachmentStrip("))
        XCTAssertFalse(cardSource.contains("let mediaAttachments: [ComposeMediaAttachment]"))
    }

    func testComposeMediaAttachmentPreviewIsLargerSquare() {
        XCTAssertEqual(CompactMediaAttachmentPreview.thumbnailWidth, CompactMediaAttachmentPreview.thumbnailHeight, accuracy: 0.0001)
        XCTAssertGreaterThan(CompactMediaAttachmentPreview.thumbnailWidth, 116)
    }

    func testFlowTransitionMotionTimingsMatchTransitionReferenceAndRespectReduceMotion() {
        XCTAssertEqual(FlowTransitionMotion.duration(.badgePop, reduceMotion: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FlowTransitionMotion.duration(.textSwap, reduceMotion: false), 0.2, accuracy: 0.0001)
        XCTAssertEqual(FlowTransitionMotion.duration(.sidePanelOpen, reduceMotion: false), 0.4, accuracy: 0.0001)
        XCTAssertEqual(FlowTransitionMotion.duration(.numberPop, reduceMotion: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FlowTransitionMotion.duration(.badgePop, reduceMotion: true), 0, accuracy: 0.0001)
        XCTAssertEqual(FlowTransitionMotion.duration(.textSwap, reduceMotion: true), 0, accuracy: 0.0001)
        XCTAssertEqual(FlowTransitionMotion.duration(.sidePanelOpen, reduceMotion: true), 0, accuracy: 0.0001)
        XCTAssertEqual(FlowTransitionMotion.duration(.numberPop, reduceMotion: true), 0, accuracy: 0.0001)
    }

    func testHomeFeedModeTabsUseNotificationCapsuleTabSelectionStyling() {
        XCTAssertNil(FlowCapsuleTabBarStylePreset.NotificationTabs.selectedBackground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.NotificationTabs.selectedForeground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.NotificationTabs.selectedStroke)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedBackground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedForeground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedStroke)
    }

    func testSettingsNavigationChromeDoesNotSwitchSystemBarVisibilityDuringDetailPush() {
        XCTAssertEqual(SettingsNavigationChrome.navigationBarVisibility(isShowingDetail: false), .hidden)
        XCTAssertEqual(SettingsNavigationChrome.navigationBarVisibility(isShowingDetail: true), .hidden)
    }

    func testSettingsDetailHeaderUsesSheetBackgroundSurface() {
        XCTAssertEqual(SettingsDetailNavigationLayout.headerBackgroundRole, .form)
    }

    func testPrimaryColorSelectionUsesBorderOnlyIndicator() {
        XCTAssertNil(SettingsPrimaryColorSwatchSelectionIndicator.selectedSystemImageName)
        XCTAssertEqual(SettingsPrimaryColorSwatchSelectionIndicator.selectedBorderWidth, 2.5, accuracy: 0.0001)
    }

    func testBreakReminderChoiceLayoutUsesManageAccountsArtworkAndCopy() {
        XCTAssertEqual(BreakReminderChoiceLayout.artworkImageName, "manage-accounts-background")
        XCTAssertEqual(BreakReminderChoiceLayout.promptText, "Take a break or continue?")
        XCTAssertEqual(BreakReminderChoiceLayout.takeBreakButtonTitle, "Take a break")
        XCTAssertEqual(BreakReminderChoiceLayout.continueButtonTitle, "Continue")
        XCTAssertEqual(BreakReminderChoiceLayout.successText, "Wise choice! Enjoy!")
        XCTAssertEqual(BreakReminderChoiceLayout.takeBreakCloseDelay, 4, accuracy: 0.0001)
    }

    func testBreakReminderChoiceUsesFullScreenSurface() {
        XCTAssertTrue(BreakReminderChoiceLayout.usesFullScreenSurface)
        XCTAssertTrue(BreakReminderChoiceLayout.hostIgnoresSafeArea)
        XCTAssertEqual(BreakReminderChoiceLayout.surfaceCornerRadius, 0, accuracy: 0.0001)
        XCTAssertEqual(BreakReminderChoiceLayout.surfaceHorizontalInset, 0, accuracy: 0.0001)
        XCTAssertEqual(BreakReminderChoiceLayout.surfaceBottomInset, 0, accuracy: 0.0001)
    }

    func testManageAccountsGlassUsesWhiteTintWithReadableText() {
        XCTAssertGreaterThanOrEqual(ManageAccountsGlassStyle.darkSurfaceWhiteOpacity, 0.44)
        XCTAssertGreaterThanOrEqual(ManageAccountsGlassStyle.lightSurfaceWhiteOpacity, 0.86)
        XCTAssertGreaterThanOrEqual(ManageAccountsGlassStyle.darkBorderWhiteOpacity, 0.24)
        XCTAssertGreaterThanOrEqual(ManageAccountsGlassStyle.primaryTextWhiteOpacity, 0.94)
        XCTAssertGreaterThanOrEqual(ManageAccountsGlassStyle.secondaryTextWhiteOpacity, 0.76)
        XCTAssertGreaterThanOrEqual(ManageAccountsGlassStyle.controlWhiteTintOpacity, 0.42)
        XCTAssertTrue(ManageAccountsGlassStyle.deleteIconUsesPrimaryTextColor)
        XCTAssertGreaterThan(ManageAccountsGlassStyle.textShadowOpacity, 0)
    }

    func testSignInSurfacesMatchAccountsGlassOpacity() {
        XCTAssertEqual(
            ManageAccountsGlassStyle.signInCardDarkSurfaceWhiteOpacity,
            ManageAccountsGlassStyle.darkSurfaceWhiteOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ManageAccountsGlassStyle.signInCardLightSurfaceWhiteOpacity,
            ManageAccountsGlassStyle.lightSurfaceWhiteOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ManageAccountsGlassStyle.signInTabContainerDarkSurfaceWhiteOpacity,
            ManageAccountsGlassStyle.darkSurfaceWhiteOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ManageAccountsGlassStyle.signInTabContainerLightSurfaceWhiteOpacity,
            ManageAccountsGlassStyle.lightSurfaceWhiteOpacity,
            accuracy: 0.0001
        )
        XCTAssertTrue(ManageAccountsGlassStyle.signInPrivateKeyLabelUsesInkColor)
    }

    func testCreateAccountCloseButtonUsesGlassInsteadOfPrimaryFill() {
        XCTAssertTrue(ManageAccountsGlassStyle.closeButtonUsesGlassSurface)
        XCTAssertFalse(ManageAccountsGlassStyle.closeButtonUsesPrimaryColorFill)
        XCTAssertGreaterThan(ManageAccountsGlassStyle.closeButtonLightWhiteTintOpacity, 0.24)
        XCTAssertLessThanOrEqual(ManageAccountsGlassStyle.closeButtonDarkWhiteTintOpacity, 0.24)
    }

    func testManageAccountSwitchMotionUsesLivelyButContainedFeedback() {
        XCTAssertEqual(ManageAccountSwitchMotion.activePillTitle, "Active")
        XCTAssertEqual(ManageAccountSwitchMotion.toastText(for: "Avery"), "Switched to Avery")
        XCTAssertLessThan(ManageAccountSwitchMotion.pressedScale, 1)
        XCTAssertGreaterThan(ManageAccountSwitchMotion.avatarSelectedScale, 1)
        XCTAssertGreaterThan(ManageAccountSwitchMotion.haloFinalScale, ManageAccountSwitchMotion.haloInitialScale)
        XCTAssertEqual(ManageAccountSwitchMotion.duration(.selection, reduceMotion: true), 0, accuracy: 0.0001)
        XCTAssertNil(ManageAccountSwitchMotion.selectionAnimation(reduceMotion: true))
    }

    func testSearchBarUsesFloatingThemeAwareGlassField() {
        XCTAssertFalse(SearchBarGlassStyle.usesSolidBarBackground)
        XCTAssertGreaterThanOrEqual(SearchBarGlassStyle.lightFieldWhiteOpacity, 0.84)
        XCTAssertLessThanOrEqual(SearchBarGlassStyle.darkFieldWhiteOverlayOpacity, 0.14)
        XCTAssertGreaterThan(SearchBarGlassStyle.rimHighlightLineWidth, SearchBarGlassStyle.innerBorderLineWidth)
        XCTAssertGreaterThan(SearchBarGlassStyle.lightDropShadowOpacity, SearchBarGlassStyle.darkDropShadowOpacity)
        XCTAssertEqual(SearchBarGlassStyle.fieldCornerRadius, 22, accuracy: 0.0001)
    }

    func testSideMenuTransitionUsesContainedSoftPushDrawer() {
        XCTAssertEqual(SideMenuTransitionLayout.menuWidthFraction, 0.78, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.menuWidthFraction, 0.75)
        XCTAssertLessThanOrEqual(SideMenuTransitionLayout.menuWidthFraction, 0.80)
        XCTAssertEqual(
            SideMenuTransitionLayout.menuTopOffset(topSafeAreaInset: 59),
            59,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SideMenuTransitionLayout.resolvedTopSafeArea(
                explicitTopSafeAreaInset: 59,
                geometryTopSafeAreaInset: 92
            ),
            59,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SideMenuTransitionLayout.resolvedTopSafeArea(
                explicitTopSafeAreaInset: 0,
                geometryTopSafeAreaInset: 47
            ),
            47,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SideMenuTransitionLayout.menuHeight(for: 852, topSafeAreaInset: 59),
            793,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SideMenuTransitionLayout.menuTopOffset(topSafeAreaInset: -8),
            0,
            accuracy: 0.0001
        )
        XCTAssertLessThan(SideMenuTransitionLayout.primaryContentOpenScale, 1)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.primaryContentOpenCornerRadius, 24)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.menuTrailingCornerRadius, 28)
        XCTAssertGreaterThan(SideMenuTransitionLayout.backdropOpacity, 0.16)
        XCTAssertTrue(SideMenuTransitionLayout.usesParentZStack)
        XCTAssertFalse(SideMenuTransitionLayout.keepsMenuBehindPrimaryContent)
        XCTAssertTrue(SideMenuTransitionLayout.clipsCompositionToContainerBounds)
        XCTAssertGreaterThan(SideMenuTransitionLayout.menuZIndex, SideMenuTransitionLayout.primaryContentZIndex)
        XCTAssertGreaterThan(SideMenuTransitionLayout.menuZIndex, SideMenuTransitionLayout.backdropZIndex)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.menuClosedOffsetFraction, 1)
        XCTAssertEqual(SideMenuTransitionLayout.menuClosedOpacity, 0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(SideMenuTransitionLayout.primaryContentOpenOffsetFraction, 0.06)
        XCTAssertGreaterThan(SideMenuTransitionLayout.backdropBlurRadius, 0)
    }

    func testSideMenuRowsUseStaggeredFadeSlideMotion() {
        XCTAssertGreaterThan(SideMenuTransitionLayout.rowStaggerDelay, 0)
        XCTAssertLessThanOrEqual(SideMenuTransitionLayout.rowStaggerDelay, 0.08)
        XCTAssertLessThan(SideMenuTransitionLayout.rowClosedXOffset, 0)
        XCTAssertEqual(SideMenuTransitionLayout.rowClosedYOffset, 0, accuracy: 0.0001)
        XCTAssertLessThan(SideMenuTransitionLayout.rowClosedOpacity, 1)
        XCTAssertEqual(SideMenuTransitionLayout.menuButtonBackgroundOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(SideMenuTransitionLayout.menuIconBackgroundOpacity, 0, accuracy: 0.0001)
        XCTAssertNil(SideMenuTransitionLayout.animation(reduceMotion: true))
        XCTAssertNotNil(SideMenuTransitionLayout.animation(reduceMotion: false))
    }

    func testSideMenuProfileBannerFadesIntoMenuContent() {
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.profileBannerHeight, 200)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.profileBannerFadeHeight, 110)
        XCTAssertLessThanOrEqual(
            SideMenuTransitionLayout.profileBannerFadeHeight,
            SideMenuTransitionLayout.profileBannerHeight
        )
        XCTAssertGreaterThan(SideMenuTransitionLayout.profileHeaderAvatarSize, 60)
        XCTAssertGreaterThan(SideMenuTransitionLayout.profileHeaderLinksTopSpacing, 20)
        XCTAssertGreaterThan(SideMenuTransitionLayout.logoutTopSpacing, 12)
    }

    func testHomeSlideoutMenuUsesCompactAccountFocusedCopy() throws {
        let source = try Self.sourceText(at: "Sources/Home/HomeSlideoutMenuView.swift")

        XCTAssertFalse(source.contains("Text(\"Menu\")"))
        XCTAssertFalse(source.contains("title: \"View Profile\""))
        XCTAssertFalse(source.contains("title: \"Manage Accounts\""))
        XCTAssertFalse(source.contains("Text(\"Active\")"))
        XCTAssertFalse(source.contains("Divider()"))
        XCTAssertTrue(source.contains("title: \"Profile\""))
        XCTAssertTrue(source.contains("title: \"Accounts\""))
        XCTAssertTrue(source.contains("Text(accountHandle)"))
    }

    func testAuthSheetSignInAndAccountsUseStableSharedChrome() {
        XCTAssertEqual(AuthSheetChromeLayout.navigationTitle(for: .signIn), "Account")
        XCTAssertEqual(AuthSheetChromeLayout.navigationTitle(for: .accounts), "Account")
        XCTAssertTrue(AuthSheetChromeLayout.hidesSystemNavigationBar(for: .signIn))
        XCTAssertTrue(AuthSheetChromeLayout.hidesSystemNavigationBar(for: .accounts))
        XCTAssertEqual(
            AuthSheetChromeLayout.contentTopSpacerHeight(for: .signIn),
            AuthSheetChromeLayout.contentTopSpacerHeight(for: .accounts),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AuthSheetChromeLayout.contentHorizontalPadding(for: .signIn),
            AuthSheetChromeLayout.contentHorizontalPadding(for: .accounts),
            accuracy: 0.0001
        )
    }

    func testAuthSheetCustomHeaderPadsBelowTopSafeArea() throws {
        let source = try Self.sourceText(at: "Sources/Auth/AuthSheetView.swift")

        XCTAssertTrue(source.contains("customHeaderTopPadding(safeAreaInset: geometry.safeAreaInsets.top)"))
        XCTAssertEqual(
            AuthSheetChromeLayout.customHeaderTopPadding(safeAreaInset: 0),
            AuthSheetChromeLayout.headerTopPadding,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AuthSheetChromeLayout.customHeaderTopPadding(safeAreaInset: 47),
            AuthSheetChromeLayout.headerTopPadding + 47,
            accuracy: 0.0001
        )
    }

    func testAuthSheetAccountHeaderUsesWhiteArtworkChrome() throws {
        let source = try Self.sourceText(at: "Sources/Auth/AuthSheetView.swift")
        let headerStart = try XCTUnwrap(source.range(of: "private var authSheetHeader: some View"))
        let signInSectionStart = try XCTUnwrap(source.range(of: "private var signInSection: some View"))
        let headerSource = String(source[headerStart.lowerBound..<signInSectionStart.lowerBound])

        XCTAssertTrue(headerSource.contains("Text(\"Account\")"))
        XCTAssertTrue(headerSource.contains(".foregroundStyle(authHeaderForeground)"))
        XCTAssertFalse(headerSource.contains(".foregroundStyle(.primary)"))
    }

    func testAuthSheetPresentationsUseFreshIdentityForRequestedInitialTab() throws {
        let sourceFiles = [
            "Sources/Home/HomeFeedView.swift",
            "Sources/Activity/ActivityView.swift",
            "Sources/App/MainTabShellView.swift"
        ]

        for sourceFile in sourceFiles {
            let source = try Self.sourceText(at: sourceFile)
            let identityAssignmentCount = source.components(
                separatedBy: "authSheetPresentationID = UUID()"
            ).count - 1

            XCTAssertTrue(source.contains("@State private var authSheetPresentationID = UUID()"), sourceFile)
            XCTAssertGreaterThanOrEqual(identityAssignmentCount, 2, sourceFile)
            XCTAssertTrue(source.contains(".id(authSheetPresentationID)"), sourceFile)
        }
    }

    func testAccountsTabRowsOnlyShowAvatarNameAndHandle() throws {
        let source = try Self.sourceText(at: "Sources/Auth/AuthSheetView.swift")
        let rowStart = try XCTUnwrap(source.range(of: "private func accountRow(for account: AuthAccount) -> some View {"))
        let rowEnd = try XCTUnwrap(source.range(of: "private var activeAccountPill: some View"))
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]

        XCTAssertTrue(rowSource.contains("accountAvatar(for: account"))
        XCTAssertTrue(rowSource.contains("Text(accountDisplayName(for: account))"))
        XCTAssertTrue(rowSource.contains("accountHandle(for: account)"))
        XCTAssertFalse(rowSource.contains("accountBackupLabel"))
        XCTAssertFalse(source.contains("Private key account"))
        XCTAssertFalse(source.contains("iCloud backup"))
    }

    func testWelcomeScratchRevealAdvancesThroughArtworkSequence() {
        let cycledAssetNames = WelcomeArtwork.orderedCycle.reduce(
            into: [WelcomeArtwork.orderedCycle[0].assetName]
        ) { names, artwork in
            names.append(WelcomeScratchRevealLayout.nextArtwork(after: artwork).assetName)
        }

        XCTAssertEqual(
            cycledAssetNames,
            [
                "welcome-scene-city",
                "welcome-scene-bedroom",
                "welcome-scene-cafe",
                "welcome-scene-park",
                "welcome-scene-terrace",
                "welcome-scene-city"
            ]
        )
    }

    func testWelcomeArtworkSelectionStartsFromFirstOrderedImage() {
        XCTAssertEqual(
            WelcomeArtwork.orderedCycle.map(\.assetName),
            [
                "welcome-scene-city",
                "welcome-scene-bedroom",
                "welcome-scene-cafe",
                "welcome-scene-park",
                "welcome-scene-terrace"
            ]
        )
        XCTAssertEqual(WelcomeArtworkSelection.initial().artwork, WelcomeArtwork.orderedCycle[0])
    }

    func testWelcomeArtworkAssetsLoadForEveryScratchableScene() {
        let appBundle = Bundle(for: AuthManager.self)

        for artwork in WelcomeArtwork.orderedCycle {
            XCTAssertNotNil(
                UIImage(named: artwork.assetName, in: appBundle, compatibleWith: nil),
                "Missing welcome artwork asset named \(artwork.assetName)"
            )
        }
    }

    func testWelcomeHeroTextUsesFullScreenArtworkContrastOverlay() throws {
        let welcomeSource = try Self.sourceText(at: "Sources/Onboarding/WelcomeOnboardingView.swift")
        let artworkSource = try Self.sourceText(at: "Sources/Onboarding/WelcomeArtwork.swift")

        XCTAssertTrue(welcomeSource.contains("overlayOpacity: 0.34"))
        XCTAssertTrue(welcomeSource.contains(".foregroundStyle(.white.opacity(0.92))"))
        XCTAssertFalse(welcomeSource.contains("welcomeHeroTitleContrastScrim"))
        XCTAssertFalse(welcomeSource.contains(".background {\n                    welcomeHeroTitleContrastScrim"))
        XCTAssertFalse(welcomeSource.contains(".background(.ultraThinMaterial"))
        XCTAssertFalse(welcomeSource.contains("RoundedRectangle(cornerRadius"))
        XCTAssertTrue(artworkSource.contains("LinearGradient(\n                stops: ["))
        XCTAssertTrue(artworkSource.contains("Color.black.opacity(overlayOpacity * 0.42)"))
        XCTAssertTrue(artworkSource.contains("Color.black.opacity(overlayOpacity)"))
    }

    func testWelcomeScratchRevealCompletionUsesCoverageThreshold() {
        XCTAssertEqual(WelcomeScratchRevealLayout.completionThreshold, 0.90, accuracy: 0.0001)
        XCTAssertFalse(
            WelcomeScratchRevealLayout.shouldAdvance(
                coverage: 0.899,
                phase: .scratchEnded
            )
        )
        XCTAssertTrue(
            WelcomeScratchRevealLayout.shouldAdvance(
                coverage: 0.90,
                phase: .scratchEnded
            )
        )
    }

    func testWelcomeScratchRevealDoesNotAdvanceDuringActiveScratch() {
        XCTAssertFalse(
            WelcomeScratchRevealLayout.shouldAdvance(
                coverage: 1,
                phase: .activeScratch
            )
        )
        XCTAssertTrue(
            WelcomeScratchRevealLayout.shouldAdvance(
                coverage: 1,
                phase: .scratchEnded
            )
        )
    }

    func testWelcomeScratchHeartBurstTravelsFromBottomTowardPageMiddle() {
        let viewportSize = CGSize(width: 390, height: 844)
        let particles = WelcomeScratchHeartBurstLayout.particles(in: viewportSize)
        let uniqueTints = Set(particles.map(\.tint))

        XCTAssertEqual(particles.count, WelcomeScratchHeartBurstLayout.particleCount)
        XCTAssertTrue(particles.allSatisfy { $0.symbolName == WelcomeScratchHeartBurstLayout.heartSymbolName })
        XCTAssertGreaterThanOrEqual(uniqueTints.count, 4)
        XCTAssertGreaterThanOrEqual(WelcomeScratchHeartBurstLayout.heartTints.count, uniqueTints.count)
        XCTAssertTrue(particles.allSatisfy { $0.bottomLift >= 36 })
        XCTAssertTrue(particles.allSatisfy { $0.yTravel >= viewportSize.height * 0.44 })
        XCTAssertTrue(particles.allSatisfy { $0.yTravel <= viewportSize.height * 0.58 })
        XCTAssertTrue(particles.allSatisfy { abs($0.xDrift) <= viewportSize.width * 0.34 })
        XCTAssertTrue(particles.allSatisfy { $0.duration >= 1.15 })
        XCTAssertGreaterThan(particles.last?.delay ?? 0, particles.first?.delay ?? 0)
    }

    func testProfileFollowingCountTextDoesNotShowZeroBeforeRemoteCountResolves() {
        XCTAssertEqual(
            ProfileViewLayout.followingCountText(
                isOwnProfile: false,
                ownFollowingCount: 12,
                remoteFollowingCount: 0,
                hasResolvedRemoteFollowingCount: false
            ),
            "following"
        )
        XCTAssertEqual(
            ProfileViewLayout.followingCountText(
                isOwnProfile: false,
                ownFollowingCount: 12,
                remoteFollowingCount: 0,
                hasResolvedRemoteFollowingCount: true
            ),
            "0 following"
        )
        XCTAssertEqual(
            ProfileViewLayout.followingCountText(
                isOwnProfile: true,
                ownFollowingCount: 12,
                remoteFollowingCount: 0,
                hasResolvedRemoteFollowingCount: false
            ),
            "12 following"
        )
    }

    func testProfileIdentityPlacesFollowingCountBeforeFollowsYouBadgeOnMetadataRow() throws {
        let source = try Self.sourceText(at: "Sources/Profile/ProfileHeaderSection.swift")
        let blockStart = try XCTUnwrap(source.range(of: "private struct ProfileIdentityBlock: View {"))
        let blockEnd = try XCTUnwrap(
            source.range(of: "private struct ProfileFollowsYouBadge: View {") ??
                source.range(of: "private struct ProfileInfoRows: View {")
        )
        let blockSource = source[blockStart.lowerBound..<blockEnd.lowerBound]

        XCTAssertFalse(blockSource.contains("identityTitleSection"))
        XCTAssertTrue(blockSource.contains("ProfileFollowsYouBadge()"))
        XCTAssertTrue(blockSource.contains("Spacer(minLength: 12)"))
        XCTAssertFalse(blockSource.contains("Text(\"Follows you\")"))
        XCTAssertTrue(blockSource.contains("if followsCurrentUser {"))

        let badgeRange = try XCTUnwrap(blockSource.range(of: "ProfileFollowsYouBadge()"))
        let followingButtonRange = try XCTUnwrap(blockSource.range(of: "Button(action: onFollowingTap)"))
        XCTAssertGreaterThan(badgeRange.lowerBound, followingButtonRange.lowerBound)
    }

    func testProfileViewStartsFollowRelationshipRefreshAlongsideProfileLoad() throws {
        let source = try Self.sourceText(at: "Sources/Profile/ProfileView.swift")

        XCTAssertTrue(source.contains("async let loadIfNeeded: Void = viewModel.loadIfNeeded()"))
        XCTAssertTrue(
            source.contains(
                "async let refreshFollowRelationship: Void = viewModel.refreshFollowRelationship("
            )
        )
        XCTAssertTrue(source.contains("_ = await (loadIfNeeded, refreshFollowRelationship, refreshKnownFollowers)"))
        XCTAssertFalse(source.contains("await viewModel.loadIfNeeded()\n            await viewModel.refreshFollowRelationship"))
    }

    func testProfileFeedRowsUseHomeFeedDividerTint() throws {
        let homeSource = try Self.sourceText(at: "Sources/Home/HomeFeedView.swift")
        let profileSource = try Self.sourceText(at: "Sources/Profile/ProfileView.swift")

        XCTAssertTrue(homeSource.contains(".fill(appSettings.themePalette.chromeBorder)"))
        XCTAssertTrue(profileSource.contains(".listRowSeparatorTint(appSettings.themePalette.chromeBorder)"))
        XCTAssertFalse(profileSource.contains(".listRowSeparatorTint(appSettings.themePalette.separator)"))
    }

    func testProfileAvatarFullscreenViewerUsesThemeAwareBackdropAndToolbarChrome() throws {
        let source = try Self.sourceText(at: "Sources/Profile/ProfileMediaSupport.swift")
        let viewerStart = try XCTUnwrap(source.range(of: "struct ProfileAvatarFullscreenViewer: View {"))
        let viewerEnd = try XCTUnwrap(source.range(of: "struct ProfileLoopingVideoView: UIViewRepresentable {"))
        let viewerSource = source[viewerStart.lowerBound..<viewerEnd.lowerBound]

        XCTAssertTrue(viewerSource.contains("@EnvironmentObject private var appSettings: AppSettingsStore"))
        XCTAssertTrue(viewerSource.contains("@Environment(\\.colorScheme) private var colorScheme"))
        XCTAssertTrue(viewerSource.contains("viewerBackgroundColor"))
        XCTAssertTrue(viewerSource.contains("viewerNavigationBarColor"))
        XCTAssertTrue(viewerSource.contains(".toolbarBackground(viewerNavigationBarColor, for: .navigationBar)"))
        XCTAssertTrue(viewerSource.contains(".toolbarColorScheme(effectiveColorScheme == .dark ? .dark : .light, for: .navigationBar)"))
        XCTAssertFalse(viewerSource.contains("Color.black"))
    }

    func testImageFullscreenRemixToolbarIconUsesSharedChromeColor() throws {
        let source = try Self.sourceText(at: "Sources/Design/NoteImageFullscreenViewer.swift")
        let actionBarStart = try XCTUnwrap(source.range(of: "private var mediaActionBar: some View {"))
        let actionBarEnd = try XCTUnwrap(source.range(of: "private var visibleReactionCount", range: actionBarStart.upperBound..<source.endIndex))
        let actionBarSource = source[actionBarStart.lowerBound..<actionBarEnd.lowerBound]
        let remixIconStart = try XCTUnwrap(actionBarSource.range(of: "Image(systemName: \"paintbrush.pointed.fill\")"))
        let remixIconSource = actionBarSource[remixIconStart.lowerBound..<actionBarSource.endIndex]

        XCTAssertTrue(remixIconSource.contains(".foregroundStyle(chromeForegroundColor)"))
        XCTAssertFalse(remixIconSource.contains(".foregroundStyle(appSettings.primaryColor)"))
    }

    func testProfileScreenDoesNotUseMidPageSpotlightGlow() throws {
        let source = try Self.sourceText(at: "Sources/Profile/ProfileView.swift")

        XCTAssertTrue(source.contains("AppThemeBackgroundView()"))
        XCTAssertFalse(source.contains("AppThemeBackgroundView(holographicSpotlight: .profile)"))
    }

    func testComposePublicationRegistersLocalStateAndUsesConnectedSourcesCopy() throws {
        let composeSource = try Self.sourceText(at: "Sources/Compose/ComposeNoteSheet.swift")
        let notePublishSource = try Self.sourceText(at: "Sources/Compose/ComposeNotePublishService.swift")
        let replyPublishSource = try Self.sourceText(at: "Sources/Thread/ThreadReplyPublishService.swift")

        XCTAssertTrue(composeSource.contains("LocalPublicationStore.shared.registerPublishing(item: preparedPublication.item)"))
        XCTAssertTrue(composeSource.contains("LocalPublicationStore.shared.markPosted(eventID: preparedPublication.item.id)"))
        XCTAssertTrue(composeSource.contains("LocalPublicationStore.shared.markFailed("))
        XCTAssertTrue(composeSource.contains("No connected sources are configured."))
        XCTAssertFalse(composeSource.contains("No publish sources are configured."))
        XCTAssertTrue(notePublishSource.contains("Couldn't publish to connected sources right now."))
        XCTAssertTrue(replyPublishSource.contains("Couldn't publish to connected sources right now."))
    }

    func testThreadReplyRefreshMergesLocalPublicationReplies() throws {
        let source = try Self.sourceText(at: "Sources/Thread/ThreadDetailViewModel.swift")

        XCTAssertTrue(source.contains("rawReplies = mergeWithLocalPublicationReplies("))
        XCTAssertTrue(source.contains("let visibleReplies = self.mergeWithLocalPublicationReplies("))
        XCTAssertTrue(source.contains("private func localPublicationReplies(rootEventID: String? = nil) -> [FeedItem]"))
    }

    func testFeedRowShowsPublicationProgressAndFailureDetails() throws {
        let source = try Self.sourceText(at: "Sources/Design/FeedRowView.swift")

        XCTAssertTrue(source.contains("@ObservedObject private var localPublicationStore = LocalPublicationStore.shared"))
        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertTrue(source.contains("Image(systemName: \"exclamationmark.circle.fill\")"))
        XCTAssertTrue(source.contains("This item is still visible here, but it couldn't publish to connected sources."))
        XCTAssertTrue(source.contains("Alert("))
    }

    func testThreadDetailArticleHeroUsesTransparentNavigationChrome() {
        XCTAssertEqual(
            ThreadDetailViewLayout.navigationTitle(hasArticleHero: true),
            ""
        )
        XCTAssertEqual(
            ThreadDetailViewLayout.navigationBarVisibility(hasArticleHero: true),
            .hidden
        )
    }

    func testThreadDetailNoteKeepsStandardNavigationChrome() {
        XCTAssertEqual(
            ThreadDetailViewLayout.navigationTitle(hasArticleHero: false),
            "Note"
        )
        XCTAssertEqual(
            ThreadDetailViewLayout.navigationBarVisibility(hasArticleHero: false),
            .visible
        )
    }

    func testThreadDetailArticleTopControlsRespectSafeArea() {
        XCTAssertEqual(
            ThreadDetailViewLayout.topControlTopPadding(safeAreaInset: 0),
            4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ThreadDetailViewLayout.topControlTopPadding(safeAreaInset: 47),
            51,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ThreadDetailViewLayout.topControlTopPadding(safeAreaInset: -8),
            4,
            accuracy: 0.0001
        )
    }

    func testThreadDetailNoteDoesNotAddManualTopSafeAreaPadding() throws {
        let source = try Self.sourceText(at: "Sources/Thread/ThreadDetailView.swift")
        let noteBodyStart = try XCTUnwrap(source.range(of: "private var noteDetailBody: some View"))
        let articleBodyStart = try XCTUnwrap(source.range(of: "private func articleDetailBody", range: noteBodyStart.upperBound..<source.endIndex))
        let noteBodySource = source[noteBodyStart.lowerBound..<articleBodyStart.lowerBound]

        XCTAssertFalse(source.contains("noteTopContentSafeAreaCompensation"))
        XCTAssertFalse(noteBodySource.contains(".padding(\n                        .top,"))
    }

    func testThreadDetailNoteReservesBottomClearanceForReplyActions() {
        XCTAssertEqual(
            ThreadDetailViewLayout.noteBottomContentPadding(
                bottomTabBarHeight: 65,
                safeAreaBottom: 34
            ),
            123,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ThreadDetailViewLayout.noteBottomContentPadding(
                bottomTabBarHeight: 65,
                safeAreaBottom: -8
            ),
            89,
            accuracy: 0.0001
        )
    }

    func testThreadDetailNoteKeepsRootContentBelowNavigationHeader() throws {
        let source = try Self.sourceText(at: "Sources/Thread/ThreadDetailView.swift")
        let noteBodyStart = try XCTUnwrap(source.range(of: "private var noteDetailBody: some View"))
        let articleBodyStart = try XCTUnwrap(source.range(of: "private func articleDetailBody", range: noteBodyStart.upperBound..<source.endIndex))
        let noteBodySource = source[noteBodyStart.lowerBound..<articleBodyStart.lowerBound]

        XCTAssertFalse(noteBodySource.contains(".padding(\n                        .top,\n                        ThreadDetailViewLayout.noteTopContentSafeAreaCompensation("))
        XCTAssertTrue(source.contains(".toolbarBackground(appSettings.themePalette.background, for: .navigationBar)"))
        XCTAssertTrue(source.contains(".toolbarBackground(.visible, for: .navigationBar)"))
    }

    func testThreadDetailNoteDoesNotInstallBottomReplyDock() throws {
        let viewSource = try Self.sourceText(at: "Sources/Thread/ThreadDetailView.swift")
        let componentsSource = try Self.sourceText(at: "Sources/Thread/ThreadDetailComponents.swift")

        XCTAssertFalse(viewSource.contains("ThreadDetailReplyDockBar("))
        XCTAssertFalse(componentsSource.contains("struct ThreadDetailReplyDockBar"))
        XCTAssertFalse(componentsSource.contains("Text(\"Post your reply\")"))
        XCTAssertFalse(componentsSource.contains("Tap below to post the first reply."))
        XCTAssertTrue(componentsSource.contains("Text(\"Replies will appear here.\")"))
    }

    func testHomeFeedFullWidthNoteRowsRemoveSeparatorLeadingInset() throws {
        let source = try Self.sourceText(at: "Sources/Home/HomeFeedView.swift")
        let feedRowRange = try XCTUnwrap(source.range(of: "private func feedRow(_ item: FeedItem, visibleReplyCounts: [String: Int]) -> some View {"))
        let animateRange = try XCTUnwrap(source.range(of: "private func animateFeedInsertion", range: feedRowRange.upperBound..<source.endIndex))
        let feedRowSource = source[feedRowRange.lowerBound..<animateRange.lowerBound]

        XCTAssertTrue(feedRowSource.contains(".padding(.leading, appSettings.fullWidthNoteRows ? 0 : Self.feedHorizontalInset)"))
    }

    func testThreadDetailSpamNoticeUsesThemeBackgroundInsteadOfPrimaryChrome() throws {
        let source = try Self.sourceText(at: "Sources/Thread/ThreadDetailComponents.swift")
        let groupStart = try XCTUnwrap(source.range(of: "struct ThreadDetailSpamRepliesGroup"))
        let groupEnd = try XCTUnwrap(source.range(of: "struct ThreadDetailReactionsSection"))
        let groupSource = String(source[groupStart.lowerBound..<groupEnd.lowerBound])

        XCTAssertTrue(groupSource.contains(".fill(appSettings.themePalette.background)"))
        XCTAssertFalse(groupSource.contains(".fill(appSettings.themePalette.secondaryBackground)"))
        XCTAssertFalse(groupSource.contains("appSettings.primaryColor"))
    }

    func testSettingsNavigationRowsDoNotLayerTapGesturesOntoNavigationLinks() throws {
        let source = try Self.sourceText(at: "Sources/Home/SettingsComponents.swift")
        let navigationRowStart = try XCTUnwrap(source.range(of: "struct SettingsNavigationRow"))
        let toggleRowStart = try XCTUnwrap(source.range(of: "struct SettingsToggleRow"))
        let navigationRowsSource = String(source[navigationRowStart.lowerBound..<toggleRowStart.lowerBound])

        XCTAssertFalse(navigationRowsSource.contains(".simultaneousGesture(TapGesture"))
        XCTAssertFalse(navigationRowsSource.contains(".onTapGesture"))
    }

    func testAppDoesNotRotateAlternateIconsAutomatically() throws {
        let flowSource = try Self.sourceText(at: "Sources/App/FlowApp.swift")
        let appSources = try Self.sourceTexts(under: "Sources/App")

        XCTAssertFalse(flowSource.contains("AppIconRotator"))
        XCTAssertFalse(appSources.contains("setAlternateIconName"))
    }

}

private extension FlowLayoutGuardrailsTests {
    static func sourceText(at relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRootURL = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repositoryRootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    static func sourceTexts(under relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRootURL = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let directoryURL = repositoryRootURL.appendingPathComponent(relativePath)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }

        var combinedSource = ""
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            combinedSource += try String(contentsOf: fileURL, encoding: .utf8)
        }
        return combinedSource
    }
}
