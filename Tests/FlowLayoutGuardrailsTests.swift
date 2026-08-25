import XCTest
import SwiftUI
import Foundation
import UIKit
@testable import Flow

final class UserFacingCopyTests: XCTestCase {
    func testTechnicalAccountAndMessagingTermsAreRemoved() {
        let message = "An nsec is required to decrypt this NIP-17 gift wrap from the relay."
        let sanitized = UserFacingCopy.sanitizingTechnicalTerms(message).lowercased()

        for forbiddenTerm in ["nsec", "nip", "gift wrap", "relay"] {
            XCTAssertFalse(sanitized.contains(forbiddenTerm))
        }
        XCTAssertTrue(sanitized.contains("account access"))
        XCTAssertTrue(sanitized.contains("source"))
    }

    func testTechnicalAddressTermsBecomeAccountAddress() {
        let message = "Paste an npub, nprofile, or pubkey."
        let sanitized = UserFacingCopy.sanitizingTechnicalTerms(message).lowercased()

        for forbiddenTerm in ["npub", "nprofile", "pubkey"] {
            XCTAssertFalse(sanitized.contains(forbiddenTerm))
        }
        XCTAssertTrue(sanitized.contains("account address"))
    }
}

final class NoteClipboardContentTests: XCTestCase {
    func testRawContentPreservesWhitespaceLineEndingsAndMediaURL() {
        let rawContent = "\nTest\r\nhttps://media.21media.to/image.jpg  \n"
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: rawContent,
            sig: String(repeating: "f", count: 128)
        )

        XCTAssertEqual(NoteClipboardContent.rawContent(for: event), rawContent)
        XCTAssertTrue(NoteClipboardContent.canCopyRawContent(from: event))
    }

    func testEmptyRawContentCannotBeCopied() {
        let event = NostrEvent(
            id: String(repeating: "2", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "",
            sig: String(repeating: "e", count: 128)
        )

        XCTAssertFalse(NoteClipboardContent.canCopyRawContent(from: event))
    }
}

final class FollowCelebrationMotionTests: XCTestCase {
    func testRefollowAlwaysCreatesANewCelebrationTrigger() {
        var trigger = 0

        trigger = FollowCelebrationMotion.nextTrigger(
            current: trigger,
            didFollow: true,
            didChange: true
        )
        XCTAssertEqual(trigger, 1)

        trigger = FollowCelebrationMotion.nextTrigger(
            current: trigger,
            didFollow: false,
            didChange: true
        )
        XCTAssertEqual(trigger, 1)

        trigger = FollowCelebrationMotion.nextTrigger(
            current: trigger,
            didFollow: true,
            didChange: true
        )
        XCTAssertEqual(trigger, 2)
    }

    func testIdempotentFollowDoesNotCreateACelebrationTrigger() {
        XCTAssertEqual(
            FollowCelebrationMotion.nextTrigger(
                current: 4,
                didFollow: true,
                didChange: false
            ),
            4
        )
    }

    func testBurstStaysLocalButVisible() {
        XCTAssertEqual(FollowCelebrationMotion.particleCount, 8)
    }
}

final class ProfileAvatarSwipeDismissBehaviorTests: XCTestCase {
    func testDismissGestureBeginsOnlyForIntentionalDownwardMovement() {
        XCTAssertTrue(
            ProfileAvatarSwipeDismissBehavior.shouldBegin(
                translation: CGSize(width: 4, height: 24)
            )
        )
        XCTAssertFalse(
            ProfileAvatarSwipeDismissBehavior.shouldBegin(
                translation: CGSize(width: 24, height: 4)
            )
        )
        XCTAssertFalse(
            ProfileAvatarSwipeDismissBehavior.shouldBegin(
                translation: CGSize(width: 0, height: -24)
            )
        )
    }

    func testDismissesForDistanceOrProjectedFlick() {
        XCTAssertTrue(
            ProfileAvatarSwipeDismissBehavior.shouldDismiss(
                translation: 210,
                predictedEndTranslation: 225,
                containerHeight: 800
            )
        )
        XCTAssertTrue(
            ProfileAvatarSwipeDismissBehavior.shouldDismiss(
                translation: 80,
                predictedEndTranslation: 240,
                containerHeight: 800
            )
        )
        XCTAssertFalse(
            ProfileAvatarSwipeDismissBehavior.shouldDismiss(
                translation: 80,
                predictedEndTranslation: 150,
                containerHeight: 800
            )
        )
    }

    func testReducedMotionKeepsFingerTrackingWithoutScaling() {
        XCTAssertEqual(
            ProfileAvatarSwipeDismissBehavior.scale(
                offset: 180,
                containerHeight: 800,
                reduceMotion: true
            ),
            1
        )
        XCTAssertLessThan(
            ProfileAvatarSwipeDismissBehavior.scale(
                offset: 180,
                containerHeight: 800,
                reduceMotion: false
            ),
            1
        )
    }
}

final class FlowLayoutGuardrailsTests: XCTestCase {
    func testReportedPodcastZapReceiptRendersValidatedAmountAndEpisodeLink() throws {
        let zapRequest = """
        {"id":"bf9636683eb96811dbc702ed088d0caf02fd1e0d884c4569a333e056c61949a0","pubkey":"50a63cca15b16b60d329b92f628c432c8c12689b40fe9d0495eb836b5f2df637","created_at":1784589959,"kind":9734,"content":"","tags":[["relays","wss://relay.fountain.fm","wss://relay.primal.net"],["amount","123000"],["p","b866ce76be5b826695980248322b8df4c381608ffa5a5b47c4f3abe0d8f767a5"],["k","podcast:item:guid"],["i","podcast:item:guid:09e25b79-56d0-414c-a8b2-858845b482a7","https://fountain.fm/episode/NsCAC8Ys0veNH9UqU2IW"]],"sig":"52591f91a4a2ca41b997b2ae207c5fa9e3ef6bb8ab290313186962af95119d5a2c8ed5f752ca42d8ca1c6c042fa558df631146e4f4f25d5b3cb81de7e1812ae2"}
        """
        let event = NostrEvent(
            id: "1bb3fcf091d09734b1917f8b9182b0fb5cacc3d2880388fdc70cb03053967b75",
            pubkey: "b866ce76be5b826695980248322b8df4c381608ffa5a5b47c4f3abe0d8f767a5",
            createdAt: 1_784_589_960,
            kind: 9_735,
            tags: [
                ["description", zapRequest],
                ["bolt11", "lnbc1230n1p49at58pp5atsgg5m5py2qz599sztxpf347czdf0nr5q0gg5yud0p8pz2aq4ns"],
                ["i", "podcast:item:guid:09e25b79-56d0-414c-a8b2-858845b482a7", "https://fountain.fm/episode/NsCAC8Ys0veNH9UqU2IW"]
            ],
            content: "",
            sig: String(repeating: "a", count: 128)
        )

        let metadata = try XCTUnwrap(NostrZapReceiptMetadata(event: event))

        XCTAssertEqual(metadata.amountMillisats, 123_000)
        XCTAssertEqual(metadata.amountText, "123 sats")
        XCTAssertEqual(metadata.target, .podcastEpisode)
        XCTAssertEqual(metadata.destinationURL?.absoluteString, "https://fountain.fm/episode/NsCAC8Ys0veNH9UqU2IW")
        XCTAssertEqual(metadata.providerName, "Fountain")
        XCTAssertEqual(metadata.actionTitle, "Open episode on Fountain")
        XCTAssertNil(metadata.comment)
    }

    func testZapReceiptDoesNotDisplayUnmatchedRequestedAmount() throws {
        let zapRequest = """
        {"kind":9734,"content":"Nice episode","tags":[["amount","124000"]]}
        """
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 9_735,
            tags: [
                ["description", zapRequest],
                ["bolt11", "lnbc1230n1ptest"]
            ],
            content: "",
            sig: String(repeating: "f", count: 128)
        )

        let metadata = try XCTUnwrap(NostrZapReceiptMetadata(event: event))

        XCTAssertNil(metadata.amountMillisats)
        XCTAssertEqual(metadata.amountText, "Lightning zap")
        XCTAssertEqual(metadata.comment, "Nice episode")
    }

    func testZapReceiptMetadataIgnoresOtherEventKinds() {
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "hello",
            sig: String(repeating: "f", count: 128)
        )

        XCTAssertNil(NostrZapReceiptMetadata(event: event))
    }

    func testUnknownEventKindUsesFriendlyFallbackWithoutRawContent() throws {
        let rawJSON = #"{"secret":"protocol detail"}"#
        let event = NostrEvent(
            id: String(repeating: "2", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 35_128,
            tags: [["description", rawJSON]],
            content: rawJSON,
            sig: String(repeating: "e", count: 128)
        )

        let metadata = try XCTUnwrap(NostrUnsupportedEventMetadata(event: event))

        XCTAssertEqual(metadata.title, "Unsupported shared item")
        XCTAssertEqual(metadata.message, "Halo can’t display this shared item yet.")
        XCTAssertEqual(metadata.kindLabel, "Kind 35128")
        XCTAssertFalse(metadata.title.contains(rawJSON))
        XCTAssertFalse(metadata.message.contains(rawJSON))
    }

    func testKnownContentAndSpecializedEventKindsDoNotUseUnsupportedFallback() {
        let recognizedKinds = [1, 20, 21, 22, 1_063, 1_068, 1_111, 1_222, 1_244, 9_735, 9_802, 30_023, 31_987, 36_787]

        for kind in recognizedKinds {
            let event = NostrEvent(
                id: String(format: "%064x", kind),
                pubkey: String(repeating: "c", count: 64),
                createdAt: 1_700_000_000,
                kind: kind,
                tags: [],
                content: "content",
                sig: String(repeating: "d", count: 128)
            )

            XCTAssertNil(NostrUnsupportedEventMetadata(event: event), "Kind \(kind) should remain renderable")
        }
    }

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

    func testBoundedFiniteWidthRejectsInvalidAndCapsToFallback() {
        XCTAssertEqual(
            FlowLayoutGuardrails.boundedFiniteWidth(.infinity, fallbackWidth: 320),
            320,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            FlowLayoutGuardrails.boundedFiniteWidth(420, fallbackWidth: 320),
            320,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            FlowLayoutGuardrails.boundedFiniteWidth(240, fallbackWidth: 320),
            240,
            accuracy: 0.0001
        )
    }

    func testFeedImageGalleryUsesBoundedGridInsteadOfHorizontalCarousel() throws {
        let source = try Self.sourceText(at: "Sources/Design/NoteImageGalleryView.swift")

        XCTAssertTrue(source.contains("private func feedGallery(_ urls: [URL]) -> some View"))
        XCTAssertTrue(source.contains("private func feedGridTileWidth(availableWidth: CGFloat) -> CGFloat"))
        XCTAssertTrue(source.contains("private var deduplicatedImageURLs: [URL]"))
        XCTAssertTrue(source.contains("private struct NoteSingleImageCellLayout: Layout"))
        XCTAssertFalse(source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertFalse(source.contains("LazyHStack(spacing: feedGallerySpacing)"))
    }

    func testWebsiteLinkCardsDoNotRequestInfiniteFeedWidth() throws {
        let source = try Self.sourceText(at: "Sources/Design/NoteContentLinkPreviewSupport.swift")
        let start = try XCTUnwrap(source.range(of: "struct WebsiteLinkCardView: View")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "struct YouTubeInlinePlayerView: View")?.lowerBound)
        let cardSource = String(source[start..<end])

        XCTAssertTrue(cardSource.contains("private static let compactFeedChromeAllowance"))
        XCTAssertTrue(cardSource.contains("private var boundedCardWidth: CGFloat"))
        XCTAssertTrue(cardSource.contains("WebsiteLinkCardWidthLayout"))
        XCTAssertFalse(cardSource.contains(".frame(maxWidth: .infinity"))
    }

    func testMainTabShellInsetsCustomNavigationOutsideEdgeToEdgeHome() throws {
        let source = try Self.sourceText(at: "Sources/App/MainTabShellView.swift")
        let start = try XCTUnwrap(source.range(of: "var body: some View")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "@ViewBuilder\n    private var nativeTabView")?.lowerBound)
        let bodySource = String(source[start..<end])

        XCTAssertTrue(bodySource.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertTrue(bodySource.contains(".overlay(alignment: .bottom)"))
        XCTAssertTrue(bodySource.contains("if reservesBottomTabBarInsetSpace"))
        XCTAssertTrue(bodySource.contains("if usesOverlayBottomTabBar"))
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

    func testProfileHeaderBannerKeepsIdentityAndPostsWithinReach() {
        XCTAssertEqual(ProfileHeaderBannerMetrics.height, 220)
        XCTAssertLessThan(ProfileHeaderBannerMetrics.height, LongFormArticleReaderLayout.heroMinHeight)
        XCTAssertLessThan(ProfileHeaderBannerMetrics.topScrimOpacity, 0.06)
        XCTAssertEqual(ProfileHeaderBannerMetrics.edgeOpacity, 0.10, accuracy: 0.0001)
    }

    func testLoadedProfileBannerImagesStayClearAndCrisplyClipped() throws {
        let source = try Self.sourceText(at: "Sources/Profile/ProfileHeaderSection.swift")

        XCTAssertGreaterThanOrEqual(ProfileHeaderBannerMetrics.loadedImageOpacity, 0.94)
        XCTAssertEqual(ProfileHeaderBannerMetrics.loadedImageSaturation, 1, accuracy: 0.0001)
        XCTAssertFalse(source.contains("bottomFadeMidOpacity"))
        XCTAssertFalse(source.contains("bottomFadeStrongOpacity"))
        XCTAssertFalse(source.contains("fadeHeight"))
        XCTAssertTrue(source.contains(".frame(height: 1)"))
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
        XCTAssertEqual(ComposeToolbarLayout.controlHeight, 40)
        XCTAssertGreaterThanOrEqual(ComposeToolbarLayout.cancelButtonHorizontalPadding, 12)
        XCTAssertGreaterThanOrEqual(ComposeToolbarLayout.draftButtonHorizontalPadding, 12)
        XCTAssertGreaterThanOrEqual(ComposeToolbarLayout.publishButtonHorizontalPadding, 16)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.leadingItemSpacing, 8)
        XCTAssertLessThanOrEqual(ComposeToolbarLayout.trailingItemSpacing, 8)
    }

    func testComposeToolbarUsesIndependentNativeGlassControls() throws {
        let sheetSource = try Self.sourceText(at: "Sources/Compose/ComposeNoteSheet.swift")
        let accessorySource = try Self.sourceText(at: "Sources/Compose/ComposeNoteSheetAccessoryViews.swift")

        XCTAssertTrue(sheetSource.contains("ToolbarSpacer(.fixed, placement: .topBarLeading)"))
        XCTAssertTrue(accessorySource.contains(".glassEffect("))
        XCTAssertFalse(accessorySource.contains(".buttonStyle(.glass)"))
        XCTAssertFalse(accessorySource.contains(".buttonStyle(.glassProminent)"))
        XCTAssertTrue(accessorySource.contains(".background(.ultraThinMaterial, in: Capsule())"))
    }

    func testComposePlaceholderUsesTheTextViewFontAndInsets() throws {
        let accessorySource = try Self.sourceText(at: "Sources/Compose/ComposeNoteSheetAccessoryViews.swift")

        XCTAssertEqual(
            ComposeEditorLayout.placeholderLeadingPadding,
            ComposeEditorLayout.textViewHorizontalPadding + ComposeEditorLayout.textContainerHorizontalInset
        )
        XCTAssertEqual(
            ComposeEditorLayout.placeholderTopPadding,
            ComposeEditorLayout.textContainerVerticalInset
        )
        XCTAssertTrue(accessorySource.contains(".font(appSettings.appFont(.body))"))
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

        XCTAssertTrue(sheetSource.contains("VStack(spacing: 0)"))
        XCTAssertTrue(sheetSource.contains("composeBottomAccessoryBar"))
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

    func testHorizontalPagingTracksIntentAndCommitsToAdjacentTabs() {
        XCTAssertTrue(
            FlowHorizontalPagingBehavior.isHorizontallyDominant(
                CGSize(width: 92, height: 18)
            )
        )
        XCTAssertTrue(
            FlowHorizontalPagingBehavior.isVerticallyDominant(
                CGSize(width: 14, height: 88)
            )
        )
        XCTAssertTrue(
            FlowHorizontalPagingBehavior.reservesGestureForBackNavigation(
                startX: 12,
                translation: 64
            )
        )
        XCTAssertFalse(
            FlowHorizontalPagingBehavior.reservesGestureForBackNavigation(
                startX: 80,
                translation: 64
            )
        )
        XCTAssertFalse(
            FlowHorizontalPagingBehavior.reservesGestureForBackNavigation(
                startX: 12,
                translation: -64
            )
        )
        XCTAssertEqual(
            FlowHorizontalPagingBehavior.targetIndex(
                currentIndex: 0,
                itemCount: 3,
                translation: -72,
                predictedEndTranslation: -86
            ),
            1
        )
        XCTAssertEqual(
            FlowHorizontalPagingBehavior.targetIndex(
                currentIndex: 2,
                itemCount: 3,
                translation: 68,
                predictedEndTranslation: 82
            ),
            1
        )
        XCTAssertEqual(
            FlowHorizontalPagingBehavior.targetIndex(
                currentIndex: 0,
                itemCount: 3,
                translation: -24,
                predictedEndTranslation: -120
            ),
            1
        )
        XCTAssertNil(
            FlowHorizontalPagingBehavior.targetIndex(
                currentIndex: 0,
                itemCount: 3,
                translation: 90,
                predictedEndTranslation: 120
            )
        )
        XCTAssertNil(
            FlowHorizontalPagingBehavior.targetIndex(
                currentIndex: 1,
                itemCount: 3,
                translation: 24,
                predictedEndTranslation: 40
            )
        )
        XCTAssertFalse(
            FlowHorizontalPagingBehavior.shouldBeginPaging(
                currentIndex: 1,
                itemCount: 3,
                startX: 12,
                horizontalDirection: 80,
                handsLeadingBoundaryToParent: false
            ),
            "The native leading-edge back gesture must own this swipe."
        )
        XCTAssertFalse(
            FlowHorizontalPagingBehavior.shouldBeginPaging(
                currentIndex: 0,
                itemCount: 3,
                startX: 120,
                horizontalDirection: 80,
                handsLeadingBoundaryToParent: true
            ),
            "The side-menu gesture must own a right swipe from the first tab."
        )
        XCTAssertTrue(
            FlowHorizontalPagingBehavior.shouldBeginPaging(
                currentIndex: 0,
                itemCount: 3,
                startX: 120,
                horizontalDirection: -80,
                handsLeadingBoundaryToParent: true
            )
        )
        XCTAssertTrue(
            FlowHorizontalPagingBehavior.shouldBeginPaging(
                currentIndex: 1,
                itemCount: 3,
                startX: 120,
                horizontalDirection: 80,
                handsLeadingBoundaryToParent: true
            )
        )
    }

    func testHorizontalPagingKeepsTheHostScreenStationary() throws {
        let source = try Self.sourceText(at: "Sources/App/FlowTransitionMotion.swift")
        let modifierStart = try XCTUnwrap(
            source.range(of: "private struct FlowHorizontalPagingModifier")
        )
        let modifierEnd = try XCTUnwrap(
            source.range(
                of: "private struct FlowPeerTabContentModifier",
                range: modifierStart.upperBound..<source.endIndex
            )
        )
        let modifierSource = source[modifierStart.lowerBound..<modifierEnd.lowerBound]

        XCTAssertFalse(modifierSource.contains(".offset("))
        XCTAssertFalse(modifierSource.contains("dragTranslation"))
        XCTAssertFalse(modifierSource.contains(".simultaneousGesture("))
        XCTAssertTrue(modifierSource.contains("UIPanGestureRecognizer"))
        XCTAssertTrue(modifierSource.contains("gestureRecognizerShouldBegin"))
        XCTAssertNil(FlowHorizontalPagingBehavior.selectionAnimation(reduceMotion: true))
        XCTAssertNotNil(FlowHorizontalPagingBehavior.selectionAnimation(reduceMotion: false))
        XCTAssertNil(FlowHorizontalPagingBehavior.contentAnimation(reduceMotion: true))
        XCTAssertNotNil(FlowHorizontalPagingBehavior.contentAnimation(reduceMotion: false))
    }

    func testPrimaryTabbedViewsUseSharedHorizontalPagingAndBackSwipe() throws {
        let homeSource = try Self.sourceText(at: "Sources/Home/HomeFeedView.swift")
        let profileSource = try Self.sourceText(at: "Sources/Profile/ProfileView.swift")
        let threadSource = try Self.sourceText(at: "Sources/Thread/ThreadDetailView.swift")
        let activitySource = try Self.sourceText(at: "Sources/Activity/ActivityView.swift")
        let messageSource = try Self.sourceText(at: "Sources/DMs/DMsView.swift")

        for source in [homeSource, profileSource, threadSource, activitySource, messageSource] {
            XCTAssertTrue(source.contains(".flowHorizontalPaging("))
        }
        for source in [homeSource, profileSource, threadSource, activitySource, messageSource] {
            XCTAssertTrue(source.contains(".flowInteractiveBackSwipe()"))
        }
    }

    func testInteractiveBackSwipeUsesAStackAwareRetainedDelegate() throws {
        let source = try Self.sourceText(at: "Sources/App/FlowTransitionMotion.swift")
        let resolverStart = try XCTUnwrap(
            source.range(of: "private struct FlowInteractiveBackSwipeResolver")
        )
        let resolverEnd = try XCTUnwrap(
            source.range(
                of: "extension View {",
                range: resolverStart.upperBound..<source.endIndex
            )
        )
        let resolverSource = source[resolverStart.lowerBound..<resolverEnd.lowerBound]

        XCTAssertTrue(resolverSource.contains("recognizer.delegate = self"))
        XCTAssertTrue(
            resolverSource.contains("navigationController.viewControllers.count > 1")
        )
        XCTAssertTrue(
            resolverSource.contains("navigationController.transitionCoordinator == nil")
        )
        XCTAssertFalse(resolverSource.contains("recognizer.delegate = nil\n                recognizer.isEnabled = true"))
    }

    func testBoundedTabContentUsesContentOnlyTransitions() throws {
        let threadSource = try Self.sourceText(at: "Sources/Thread/ThreadDetailComponents.swift")
        let messageSource = try Self.sourceText(at: "Sources/DMs/DMsView.swift")

        XCTAssertTrue(
            threadSource.contains(
                ".flowPeerTabContentTransition(selection: selectedContentTab)"
            )
        )
        XCTAssertTrue(
            messageSource.contains(
                ".flowPeerTabContentTransition(selection: activeTab)"
            )
        )
    }

    func testHomeFeedModeTabsUseNotificationCapsuleTabSelectionStyling() {
        XCTAssertNil(FlowCapsuleTabBarStylePreset.NotificationTabs.selectedBackground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.NotificationTabs.selectedForeground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.NotificationTabs.selectedStroke)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedBackground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedForeground)
        XCTAssertNil(FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedStroke)
    }

    func testFollowingEmptyStateActionsUseOneVerticalEqualWidthStack() throws {
        let source = try Self.sourceText(at: "Sources/Home/HomeFeedView.swift")
        let start = try XCTUnwrap(source.range(of: "else if viewModel.followingFeedHasNoFollowings"))
        let end = try XCTUnwrap(
            source.range(
                of: "else if viewModel.feedSource == .articles",
                range: start.upperBound..<source.endIndex
            )
        )
        let emptyFollowingBranch = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(emptyFollowingBranch.contains("VStack(spacing: 10)"))
        XCTAssertFalse(emptyFollowingBranch.contains("HStack(spacing: 10)"))
        XCTAssertEqual(
            emptyFollowingBranch.components(separatedBy: "fillsAvailableWidth: true").count - 1,
            2
        )
        XCTAssertTrue(emptyFollowingBranch.contains(".frame(maxWidth: 260)"))
    }

    func testSettingsNavigationChromeDoesNotSwitchSystemBarVisibilityDuringDetailPush() {
        XCTAssertEqual(SettingsNavigationChrome.navigationBarVisibility(isShowingDetail: false), .hidden)
        XCTAssertEqual(SettingsNavigationChrome.navigationBarVisibility(isShowingDetail: true), .hidden)
    }

    func testSettingsDetailHeaderUsesSheetBackgroundSurface() {
        XCTAssertEqual(SettingsDetailNavigationLayout.headerBackgroundRole, .form)
    }

    func testAppearanceDoesNotOfferPrimaryColorCustomization() throws {
        let appearanceSource = try Self.sourceText(at: "Sources/Home/SettingsAppearanceView.swift")
        let authSource = try Self.sourceText(at: "Sources/Auth/AuthSheetView.swift")

        XCTAssertFalse(appearanceSource.contains("Section(\"Primary Color\")"))
        XCTAssertFalse(appearanceSource.contains("ColorPicker("))
        XCTAssertFalse(appearanceSource.contains("Custom Color"))
        XCTAssertTrue(authSource.contains("private var signInAccentColor: Color {\n        appSettings.primaryColor"))
        XCTAssertFalse(authSource.contains("resolvedSignUpSeedPrimaryColorOption.color"))
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

    func testSideMenuTransitionUsesInteractiveFeedPushDrawer() {
        XCTAssertEqual(SideMenuTransitionLayout.menuWidthFraction, 0.78, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.menuWidthFraction, 0.75)
        XCTAssertLessThanOrEqual(SideMenuTransitionLayout.menuWidthFraction, 0.80)
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
            SideMenuTransitionLayout.resolvedTopSafeArea(
                explicitTopSafeAreaInset: -12,
                geometryTopSafeAreaInset: -8
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(SideMenuTransitionLayout.primaryContentOpenScale, 1, accuracy: 0.0001)
        XCTAssertEqual(
            SideMenuTransitionLayout.primaryContentOpenCornerRadius,
            44,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(SideMenuTransitionLayout.backdropOpacity, 0.3)
        XCTAssertTrue(SideMenuTransitionLayout.usesParentZStack)
        XCTAssertTrue(SideMenuTransitionLayout.keepsMenuBehindPrimaryContent)
        XCTAssertTrue(SideMenuTransitionLayout.menuFillsFullContainerHeight)
        XCTAssertLessThan(SideMenuTransitionLayout.menuZIndex, SideMenuTransitionLayout.primaryContentZIndex)
        XCTAssertGreaterThan(SideMenuTransitionLayout.menuClosedOffsetFraction, 0)
        XCTAssertLessThanOrEqual(SideMenuTransitionLayout.menuClosedOffsetFraction, 0.12)
        XCTAssertGreaterThan(SideMenuTransitionLayout.menuClosedOpacity, 0.75)
        XCTAssertEqual(SideMenuTransitionLayout.dragMinimumDistance, 10, accuracy: 0.0001)
        XCTAssertGreaterThan(SideMenuTransitionLayout.dragAxisDominanceRatio, 1)
        XCTAssertEqual(SideMenuTransitionLayout.projectedOpenThreshold, 0.5, accuracy: 0.0001)
    }

    func testSideMenuGestureClampsAndProjectsFeedPosition() {
        let openOffset: CGFloat = 312

        XCTAssertEqual(
            SideMenuTransitionLayout.clampedContentOffset(
                isOpen: false,
                dragTranslation: 120,
                openOffset: openOffset
            ),
            120,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SideMenuTransitionLayout.clampedContentOffset(
                isOpen: true,
                dragTranslation: -100,
                openOffset: openOffset
            ),
            212,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SideMenuTransitionLayout.clampedContentOffset(
                isOpen: false,
                dragTranslation: -80,
                openOffset: openOffset
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SideMenuTransitionLayout.presentationProgress(
                contentOffset: 156,
                openOffset: openOffset
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertTrue(
            SideMenuTransitionLayout.isHorizontallyDominant(
                CGSize(width: 80, height: 20)
            )
        )
        XCTAssertTrue(
            SideMenuTransitionLayout.isVerticallyDominant(
                CGSize(width: 15, height: 80)
            )
        )
        XCTAssertTrue(
            SideMenuTransitionLayout.shouldOpen(
                isOpen: false,
                predictedEndTranslation: 210,
                openOffset: openOffset
            )
        )
        XCTAssertFalse(
            SideMenuTransitionLayout.shouldOpen(
                isOpen: true,
                predictedEndTranslation: -220,
                openOffset: openOffset
            )
        )
        XCTAssertFalse(
            SideMenuTransitionLayout.canTrackMenuDrag(
                isOpen: false,
                allowsOpeningGesture: false,
                horizontalTranslation: 120
            )
        )
        XCTAssertTrue(
            SideMenuTransitionLayout.canTrackMenuDrag(
                isOpen: false,
                allowsOpeningGesture: true,
                horizontalTranslation: 120
            )
        )
        XCTAssertTrue(
            SideMenuTransitionLayout.canTrackMenuDrag(
                isOpen: true,
                allowsOpeningGesture: false,
                horizontalTranslation: -120
            )
        )
    }

    func testSideMenuRowsUseInteractiveStaggeredFadeSlideMotion() {
        XCTAssertGreaterThan(SideMenuTransitionLayout.rowStaggerProgress, 0)
        XCTAssertLessThanOrEqual(SideMenuTransitionLayout.rowStaggerProgress, 0.08)
        XCTAssertLessThan(SideMenuTransitionLayout.rowClosedXOffset, 0)
        XCTAssertEqual(SideMenuTransitionLayout.rowClosedYOffset, 0, accuracy: 0.0001)
        XCTAssertLessThan(SideMenuTransitionLayout.rowClosedOpacity, 1)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.profileHeaderAvatarSize, 48)
        XCTAssertLessThanOrEqual(SideMenuTransitionLayout.profileHeaderAvatarSize, 56)
        XCTAssertGreaterThanOrEqual(SideMenuTransitionLayout.profileHeaderLinksTopSpacing, 18)
        XCTAssertEqual(SideMenuTransitionLayout.menuButtonBackgroundOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(SideMenuTransitionLayout.menuIconBackgroundOpacity, 0, accuracy: 0.0001)
        XCTAssertNil(SideMenuTransitionLayout.animation(reduceMotion: true))
        XCTAssertNotNil(SideMenuTransitionLayout.animation(reduceMotion: false))

        let firstRowProgress = SideMenuTransitionLayout.rowPresentationProgress(
            menuProgress: 0.5,
            index: 0
        )
        let finalRowProgress = SideMenuTransitionLayout.rowPresentationProgress(
            menuProgress: 0.5,
            index: 4
        )
        XCTAssertGreaterThan(firstRowProgress, finalRowProgress)
        XCTAssertEqual(
            SideMenuTransitionLayout.rowPresentationProgress(
                menuProgress: 1,
                index: 4
            ),
            1,
            accuracy: 0.0001
        )
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

    func testHomeFeedKeepsNativeRefreshControlTopInsetAvailable() throws {
        let source = try Self.sourceText(at: "Sources/Home/HomeFeedView.swift")
        let topNavChromeStart = try XCTUnwrap(source.range(of: "private struct HomeFeedTopNavigationChromeView"))
        let topNavChromeEnd = try XCTUnwrap(source.range(of: "private struct HomeFeedNewNotesChromeOverlay"))
        let topNavChromeSource = source[topNavChromeStart.lowerBound..<topNavChromeEnd.lowerBound]

        XCTAssertTrue(source.contains(".refreshable {\n            await refreshFeed()"))
        XCTAssertTrue(source.contains("ZStack(alignment: .top) {"))
        XCTAssertTrue(source.contains("VStack(spacing: 0) {"))
        XCTAssertFalse(source.contains(".safeAreaInset(edge: .top, spacing: 0)"))
        XCTAssertTrue(source.contains("HomeFeedTopNavigationChromeView("))
        XCTAssertTrue(source.contains("feedTopAnchor\n                .homeFeedListRow()\n                .environment(\\.defaultMinListRowHeight, 0)"))
        XCTAssertTrue(source.contains("topTrackedRow(feedModeHeaderRow.homeFeedListRow(), isFirst: true)"))
        XCTAssertTrue(source.contains("tracksFirstRowTop: !showsFeedModeHeader"))
        XCTAssertTrue(source.contains("private var feedTopAnchor: some View {\n        Color.clear\n            .frame(height: 0)\n            .id(Self.feedTopAnchorID)"))
        XCTAssertFalse(source.contains(".background(feedTopOffsetReader)\n                .id(Self.feedTopAnchorID)"))
        XCTAssertFalse(source.contains("feedTopAnchorRow"))
        XCTAssertFalse(source.contains("feedTopChromeClearance"))
        XCTAssertFalse(source.contains("feedTopPadding"))
        XCTAssertFalse(source.contains("topContentPadding"))
        XCTAssertTrue(source.contains("if showsFeedModeHeader {\n                topTrackedRow(feedModeHeaderRow.homeFeedListRow(), isFirst: true)\n            }"))
        XCTAssertTrue(source.contains("private var showsFeedModeHeader: Bool {"))
        XCTAssertTrue(source.contains("feedContent(\n                    contentPadding.bottom,\n                    0,\n                    safeAreaBottom\n                )"))
        XCTAssertTrue(source.contains("safeAreaTop: safeAreaTop"))
        XCTAssertTrue(topNavChromeSource.contains("topNavigationBar()\n            .padding(.top, safeAreaTop)\n            .background(topNavigationBarBackground)"))
        XCTAssertFalse(topNavChromeSource.contains("ScrollChromeLayout.chromeOpacity("))
        XCTAssertFalse(source.contains("pullToRefreshDistance"))
        XCTAssertFalse(source.contains("isPullToRefreshActive"))
        XCTAssertFalse(source.contains("pullDistance: max(0, -offsetFromTop)"))
        XCTAssertFalse(topNavChromeSource.contains("refreshRevealOpacity"))
        XCTAssertFalse(source.contains("HomeFeedTopNavigationBarHeightPreferenceKey"))
        XCTAssertFalse(source.contains("topHiddenOffset"))
        XCTAssertFalse(source.contains("topSafeAreaInset: max(0, navigationGeometry.safeAreaInsets.top)"))
        XCTAssertTrue(topNavChromeSource.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertFalse(topNavChromeSource.contains("topBarOffset"))
        XCTAssertTrue(topNavChromeSource.contains("safeAreaTop"))
        XCTAssertFalse(topNavChromeSource.contains(".offset(y:"))
        XCTAssertFalse(topNavChromeSource.contains(".opacity("))
        XCTAssertFalse(topNavChromeSource.contains(".allowsHitTesting("))
    }

    func testHomeFeedScrollChromeDoesNotRebuildBufferedFeedContent() throws {
        let viewSource = try Self.sourceText(at: "Sources/Home/HomeFeedView.swift")
        let modelSource = try Self.sourceText(at: "Sources/Home/HomeFeedViewModel.swift")
        let overlayStart = try XCTUnwrap(
            viewSource.range(of: "private struct HomeFeedNewNotesChromeOverlay")
        )
        let overlayEnd = try XCTUnwrap(
            viewSource.range(
                of: "private struct HomeFeedLifecycleHandlers",
                range: overlayStart.upperBound..<viewSource.endIndex
            )
        )
        let overlaySource = viewSource[overlayStart.lowerBound..<overlayEnd.lowerBound]
        let bufferedMergeStart = try XCTUnwrap(
            modelSource.range(of: "private func mergeBufferedItems(")
        )
        let bufferedMergeEnd = try XCTUnwrap(
            modelSource.range(
                of: "private func primeBufferedItemsCache(",
                range: bufferedMergeStart.upperBound..<modelSource.endIndex
            )
        )
        let bufferedMergeSource = modelSource[
            bufferedMergeStart.lowerBound..<bufferedMergeEnd.lowerBound
        ]
        let mainMergeStart = try XCTUnwrap(
            modelSource.range(of: "private func mergeKeepingNewest(")
        )
        let mainMergeEnd = try XCTUnwrap(
            modelSource.range(
                of: "private func applyRefreshResults(",
                range: mainMergeStart.upperBound..<modelSource.endIndex
            )
        )
        let mainMergeSource = modelSource[mainMergeStart.lowerBound..<mainMergeEnd.lowerBound]
        let visibleCacheMergeStart = try XCTUnwrap(
            modelSource.range(of: "private func primeVisibleItemsCacheAfterMerging(")
        )
        let visibleCacheMergeEnd = try XCTUnwrap(
            modelSource.range(
                of: "private func mergeBufferedItems(",
                range: visibleCacheMergeStart.upperBound..<modelSource.endIndex
            )
        )
        let visibleCacheMergeSource = modelSource[
            visibleCacheMergeStart.lowerBound..<visibleCacheMergeEnd.lowerBound
        ]

        XCTAssertTrue(overlaySource.contains("let content: Content"))
        XCTAssertFalse(overlaySource.contains("let content: () -> Content"))
        XCTAssertTrue(overlaySource.contains("self.content = content()"))
        XCTAssertTrue(modelSource.contains("private var bufferedVisibleItemsCacheKey: VisibleItemsCacheKey?"))
        XCTAssertTrue(modelSource.contains("if bufferedVisibleItemsCacheKey == key"))
        XCTAssertTrue(modelSource.contains("return bufferedVisibleItemsCache"))
        XCTAssertTrue(viewSource.contains("guard !isFeedScrolling else { return }"))
        XCTAssertTrue(viewSource.contains(".onScrollPhaseChange"))
        XCTAssertTrue(viewSource.contains("handleLegacyScrollActivity()"))
        XCTAssertTrue(viewSource.contains("@StateObject private var legacyScrollCoordinator"))
        XCTAssertTrue(viewSource.contains("legacyScrollCoordinator.idleTask = Task { @MainActor in"))
        XCTAssertFalse(viewSource.contains("@State private var legacyScrollIdleTask"))
        XCTAssertTrue(modelSource.contains("primeVisibleItemsCacheAfterMerging"))
        XCTAssertTrue(mainMergeSource.contains("Self.mergeSortedDisjointItems("))
        XCTAssertFalse(mainMergeSource.contains("mergeItemArrays("))
        XCTAssertTrue(visibleCacheMergeSource.contains("unaffectedVisibleItems"))
        XCTAssertTrue(visibleCacheMergeSource.contains("Self.mergeSortedDisjointItems("))
        XCTAssertFalse(visibleCacheMergeSource.contains("mergeItemArrays("))
        XCTAssertTrue(modelSource.contains("private func mergeBufferedItems("))
        XCTAssertTrue(bufferedMergeSource.contains("into: existingPartition.retained"))
        XCTAssertTrue(bufferedMergeSource.contains("let affectedCanonicalItems = canonicalItems.filter(isAffected)"))
        XCTAssertFalse(bufferedMergeSource.contains("mergeItemArrays("))
        XCTAssertTrue(modelSource.contains("Self.mergeSortedItemsIncrementally("))
        XCTAssertTrue(bufferedMergeSource.contains("limit: bufferedItemLimit"))
        XCTAssertTrue(modelSource.contains("followingAuthorsRevision:"))
    }

    func testHomeFeedUsesActionsOnlyEngagementWithoutRemoteHydration() throws {
        let homeSource = try Self.sourceText(at: "Sources/Home/HomeFeedView.swift")
        let rowSource = try Self.sourceText(at: "Sources/Design/FeedRowView.swift")

        XCTAssertTrue(homeSource.contains("engagementMode: .actionsOnly"))
        XCTAssertFalse(homeSource.contains("FeedEngagementViewportCoordinator"))
        XCTAssertFalse(homeSource.contains("engagementViewport.noteVisible"))
        XCTAssertFalse(homeSource.contains("ReplyCountEstimator.counts"))
        XCTAssertTrue(rowSource.contains("case actionsOnly"))
        XCTAssertTrue(rowSource.contains("guard engagementMode == .liveCounts else"))
        XCTAssertTrue(rowSource.contains("count: showsEngagementCounts ? visibleReactionCount : 0"))
        XCTAssertTrue(rowSource.contains("refreshActionsOnlyReactionSnapshot(for: item.displayEventID)"))
        XCTAssertTrue(rowSource.contains(".onChange(of: item.displayEventID)"))
    }

    func testHomeFeedReliesOnVisibleRowsInsteadOfEagerMediaPrefetch() throws {
        let source = try Self.sourceText(at: "Sources/Home/HomeFeedViewModel.swift")

        XCTAssertFalse(source.contains("scheduleAssetPrefetch"))
        XCTAssertFalse(source.contains("assetPrefetchTask"))
        XCTAssertFalse(source.contains("assetPrefetchItemCount"))
        XCTAssertTrue(source.contains("let bufferedItemsToReveal = bufferedNewItems"))
        XCTAssertTrue(source.contains("retentionAlreadyValidated: true"))
        XCTAssertTrue(source.contains("Self.mergeSortedDisjointItems("))
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
        XCTAssertTrue(viewerSource.contains("NoteZoomableFullscreenImageView("))
        XCTAssertTrue(viewerSource.contains("kind: .profileImageFullscreen"))
        XCTAssertTrue(viewerSource.contains("Pinch or double-tap to zoom"))
        XCTAssertTrue(viewerSource.contains(".simultaneousGesture("))
        XCTAssertTrue(viewerSource.contains("guard !isImageZoomed"))
        XCTAssertTrue(viewerSource.contains("value.predictedEndTranslation"))
        XCTAssertTrue(viewerSource.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(viewerSource.contains(".presentationBackground(.clear)"))
        XCTAssertFalse(viewerSource.contains("Color.black"))
        XCTAssertFalse(viewerSource.contains(".scaledToFit()"))
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

    func testFullscreenImageZoomRespectsReduceMotion() throws {
        let source = try Self.sourceText(at: "Sources/Design/NoteContentMediaSupport.swift")
        let zoomStart = try XCTUnwrap(source.range(of: "struct NoteZoomableFullscreenImageView: View"))
        let zoomEnd = try XCTUnwrap(
            source.range(of: "struct NoteRemoteMediaView", range: zoomStart.upperBound..<source.endIndex)
        )
        let zoomSource = source[zoomStart.lowerBound..<zoomEnd.lowerBound]

        XCTAssertTrue(zoomSource.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(zoomSource.contains("reduceMotion: accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("animated: !reduceMotion"))
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

    func testOwnProfileNeverOffersFollowActions() throws {
        let feedRowSource = try Self.sourceText(at: "Sources/Design/FeedRowView.swift")
        let profileAvatarStart = try XCTUnwrap(feedRowSource.range(of: "private var profileAvatar: some View {"))
        let profileAvatarEnd = try XCTUnwrap(
            feedRowSource.range(
                of: "private var avatarWithFollowBadge: some View {",
                range: profileAvatarStart.upperBound..<feedRowSource.endIndex
            )
        )
        let profileAvatarSource = feedRowSource[profileAvatarStart.lowerBound..<profileAvatarEnd.lowerBound]

        XCTAssertTrue(
            profileAvatarSource.contains(
                "if !isAuthoredByCurrentAccount {\n                    Button {\n                        avatarMenuActions.onFollowToggle()"
            )
        )
        XCTAssertTrue(profileAvatarSource.contains("avatarMenuActions.onViewProfile()"))

        let threadSource = try Self.sourceText(at: "Sources/Thread/ThreadDetailComponents.swift")
        let rootCardStart = try XCTUnwrap(threadSource.range(of: "struct ThreadDetailRootNoteCard: View {"))
        let rootCardEnd = try XCTUnwrap(
            threadSource.range(
                of: "struct ThreadDetailInteractionRow: View {",
                range: rootCardStart.upperBound..<threadSource.endIndex
            )
        )
        let rootCardSource = threadSource[rootCardStart.lowerBound..<rootCardEnd.lowerBound]

        XCTAssertTrue(
            rootCardSource.contains(
                "if !isAuthoredByCurrentAccount {\n                            Button {\n                                onFollowToggle()"
            )
        )
        XCTAssertTrue(rootCardSource.contains("onOpenProfile(item.displayAuthorPubkey)"))

        let followingListSource = try Self.sourceText(at: "Sources/Profile/FollowingListView.swift")
        XCTAssertTrue(followingListSource.contains("if !isCurrentAccount(row.pubkey) {"))
        XCTAssertTrue(
            followingListSource.contains(
                "!isCurrentAccount($0) && !followStore.isFollowing($0)"
            )
        )
        XCTAssertTrue(followingListSource.contains("if isCurrentAccount(row.pubkey) {\n                Text(\"You\")"))
    }

    func testProfileAvatarMenuUsesMuteInsteadOfSpamMarking() throws {
        let source = try Self.sourceText(at: "Sources/Design/FeedRowView.swift")
        let menuStart = try XCTUnwrap(source.range(of: "private var profileAvatar: some View {"))
        let menuEnd = try XCTUnwrap(
            source.range(
                of: "private var avatarWithFollowBadge: some View {",
                range: menuStart.upperBound..<source.endIndex
            )
        )
        let menuSource = source[menuStart.lowerBound..<menuEnd.lowerBound]

        XCTAssertTrue(menuSource.contains("applyMuteAuthor(reason: nil)"))
        XCTAssertTrue(menuSource.contains("Label(\"Mute\", systemImage: \"speaker.slash\")"))
        XCTAssertFalse(menuSource.contains("handleToggleAuthorSpamMark()"))
        XCTAssertFalse(menuSource.contains("Mark as Spam"))
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
        let feedRowRange = try XCTUnwrap(source.range(of: "private func feedRow(_ item: FeedItem) -> some View {"))
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

    func testPulseMutedNotificationsUseAccessibleScopedRevealControls() throws {
        let activitySource = try Self.sourceText(at: "Sources/Activity/ActivityView.swift")
        let settingsSource = try Self.sourceText(at: "Sources/Home/SettingsComponents.swift")

        XCTAssertTrue(settingsSource.contains("Toggle(\"Show muted activity\""))
        XCTAssertTrue(settingsSource.contains(".accessibilityIdentifier(\"pulse-show-muted-notifications\")"))
        XCTAssertTrue(activitySource.contains("let isMutedNotification = viewModel.isMutedNotification(item)"))
        XCTAssertTrue(activitySource.contains("revealMutedContent: isMutedNotification"))
        XCTAssertTrue(activitySource.contains(".accessibilityLabel(\"Open muted notification\")"))
        XCTAssertTrue(activitySource.contains(".accessibilityValue("))
        XCTAssertTrue(activitySource.contains("minHeight: 44"))
    }

    func testBottomNavigationRemainsIconOnly() throws {
        let source = try Self.sourceText(at: "Sources/App/MainTabShellView.swift")
        let buttonStart = try XCTUnwrap(source.range(of: "private func bottomNavButton(for tab: Tab)"))
        let buttonEnd = try XCTUnwrap(
            source.range(of: "private var homeTabContent", range: buttonStart.upperBound..<source.endIndex)
        )
        let buttonSource = source[buttonStart.lowerBound..<buttonEnd.lowerBound]

        XCTAssertTrue(buttonSource.contains("Image(isSelected ? tab.selectedPhosphorIconName : tab.phosphorIconName)"))
        XCTAssertFalse(buttonSource.contains("Text("))
        XCTAssertFalse(source.contains("var compactTitle: String"))
    }

    func testSearchFollowButtonKeepsVisibleCapsulePaddingAndFullHitArea() throws {
        let source = try Self.sourceText(at: "Sources/Search/SearchViewComponents.swift")
        let rowStart = try XCTUnwrap(source.range(of: "struct SearchProfileResultRow: View"))
        let rowEnd = try XCTUnwrap(
            source.range(of: "struct SearchActionCard: View", range: rowStart.upperBound..<source.endIndex)
        )
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]

        XCTAssertTrue(rowSource.contains(".padding(.horizontal, 12)"))
        XCTAssertTrue(rowSource.contains(".padding(.vertical, 7)"))
        XCTAssertTrue(rowSource.contains(".frame(minWidth: 40, minHeight: 40)"))
        XCTAssertTrue(rowSource.contains(".followCelebration("))
        XCTAssertFalse(rowSource.contains(".sensoryFeedback(.success, trigger: isFollowing)"))
    }

    func testFollowCelebrationUsesExplicitRepeatableActionTokens() throws {
        let motionSource = try Self.sourceText(at: "Sources/App/FlowTransitionMotion.swift")
        let followStoreSource = try Self.sourceText(at: "Sources/Profile/FollowStore.swift")
        let profileSource = try Self.sourceText(at: "Sources/Profile/ProfileView.swift")

        XCTAssertTrue(motionSource.contains("trigger: trigger"))
        XCTAssertFalse(motionSource.contains(".onChange(of: isFollowing)"))
        XCTAssertTrue(followStoreSource.contains("updatedTokens[target] = FollowCelebrationMotion.nextTrigger("))
        XCTAssertTrue(profileSource.contains("trigger: followStore.followCelebrationToken(for: viewModel.pubkey)"))
    }

    func testPulseHeaderRestoresTopSafeAreaInsideSideMenuContainer() throws {
        let source = try Self.sourceText(at: "Sources/Activity/ActivityView.swift")

        XCTAssertTrue(source.contains("let safeAreaTop = max(0, geometry.safeAreaInsets.top)"))
        XCTAssertTrue(source.contains("topSafeAreaInset: safeAreaTop"))
        XCTAssertTrue(source.contains(".padding(.top, safeAreaTop)"))
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
