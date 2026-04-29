import XCTest
import SwiftUI
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
        XCTAssertGreaterThanOrEqual(ProfileHeaderBannerMetrics.height, 260)
        XCTAssertGreaterThanOrEqual(
            ProfileHeaderBannerMetrics.fadeHeight,
            ProfileHeaderBannerMetrics.height * 0.68
        )
    }

    func testLoadedProfileBannerImagesAreMutedIntoChrome() {
        XCTAssertLessThanOrEqual(ProfileHeaderBannerMetrics.loadedImageOpacity, 0.72)
        XCTAssertGreaterThan(ProfileHeaderBannerMetrics.loadedImageOpacity, 0.5)
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

    func testComposeToolbarUsesCompactThemeAwareControls() {
        XCTAssertEqual(ComposeToolbarLayout.cancelButtonFontWeight, ComposeToolbarLayout.publishButtonFontWeight)
        XCTAssertEqual(ComposeToolbarLayout.cancelButtonFontWeight, .semibold)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.leadingItemSpacing, 8)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.trailingItemSpacing, 8)
        XCTAssertGreaterThan(ComposeToolbarLayout.draftButtonBackgroundOpacity, 0)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.draftButtonBackgroundOpacity, 1)
    }

    func testBreakReminderChoiceLayoutUsesManageAccountsArtworkAndCopy() {
        XCTAssertEqual(BreakReminderChoiceLayout.artworkImageName, "manage-accounts-background")
        XCTAssertEqual(BreakReminderChoiceLayout.promptText, "Take a break or continue?")
        XCTAssertEqual(BreakReminderChoiceLayout.takeBreakButtonTitle, "Take a break")
        XCTAssertEqual(BreakReminderChoiceLayout.continueButtonTitle, "Continue")
        XCTAssertEqual(BreakReminderChoiceLayout.successText, "Wise choice! Enjoy!")
        XCTAssertEqual(BreakReminderChoiceLayout.takeBreakCloseDelay, 4, accuracy: 0.0001)
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

}
