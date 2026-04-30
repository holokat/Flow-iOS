import AVFoundation
import AVKit
import ImageIO
import NostrSDK
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposeNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var composeDraftStore: AppComposeDraftStore
    @State private var isEditorFocused = false
    @StateObject private var viewModel = ComposeNoteViewModel()
    @StateObject private var speechTranscriber = ComposeSpeechTranscriber()
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var mediaAttachments: [ComposeMediaAttachment] = []
    @State private var capturePermissions = CameraCapturePermissionSnapshot.current()
    @State private var isShowingCapturePermissionSheet = false
    @State private var isShowingCameraCapture = false
    @State private var isRequestingCaptureAccess = false
    @State private var isUploadingMedia = false
    @State private var pollDraft: ComposePollDraft?
    @State private var profileDisplayName = "Account"
    @State private var profileAvatarURL: URL?
    @State private var profileFallbackSymbol = "A"
    @State private var replyTargetDisplayName: String?
    @State private var replyTargetHandle: String?
    @State private var replyTargetAvatarURL: URL?
    @State private var quotedDisplayName: String?
    @State private var quotedHandle: String?
    @State private var quotedAvatarURL: URL?
    @State private var replyTargetPreviewSnapshot: ComposeContextPreviewSnapshot?
    @State private var quotedPreviewSnapshot: ComposeContextPreviewSnapshot?
    @State private var currentAdditionalTags: [[String]] = []
    @State private var currentReplyTargetEvent: NostrEvent?
    @State private var currentReplyTargetDisplayNameHint: String?
    @State private var currentReplyTargetHandleHint: String?
    @State private var currentReplyTargetAvatarURLHint: URL?
    @State private var currentQuotedEvent: NostrEvent?
    @State private var currentQuotedDisplayNameHint: String?
    @State private var currentQuotedHandleHint: String?
    @State private var currentQuotedAvatarURLHint: URL?
    @State private var hasAppliedInitialDraft = false
    @State private var hasAppliedInitialContext = false
    @State private var hasAppliedInitialAttachments = false
    @State private var hasAppliedInitialPollDraft = false
    @State private var hasAppliedInitialSelectedMentions = false
    @State private var hasAppliedInitialSharedAttachments = false
    @State private var previewingMediaAttachment: ComposeMediaAttachment?
    @State private var isShowingKlipyGIFPicker = false
    @State private var isShowingDraftLibrary = false
    @State private var editorSelectedRange = NSRange(location: 0, length: 0)
    @State private var selectedMentions: [ComposeSelectedMention] = []
    @State private var activeMentionQuery: ComposeMentionQuery?
    @State private var mentionSuggestions: [ComposeMentionSuggestion] = []
    @State private var isLoadingMentionSuggestions = false
    @State private var mentionLookupTask: Task<Void, Never>?
    @State private var mentionSuggestionAnchorY: CGFloat = 44
    @State private var activeSavedDraftID: UUID?
    @State private var hasPublishedSuccessfully = false

    private let mediaUploadService = MediaUploadService.shared
    private let klipyGIFService = KlipyGIFService.shared
    private let profileService = NostrFeedService()

    let currentAccountPubkey: String?
    let currentNsec: String?
    let writeRelayURLs: [URL]
    var initialText: String = ""
    var initialAdditionalTags: [[String]] = []
    var initialUploadedAttachments: [ComposeMediaAttachment] = []
    var initialSharedAttachments: [SharedComposeAttachment] = []
    var initialSelectedMentions: [ComposeSelectedMention] = []
    var initialPollDraft: ComposePollDraft? = nil
    var replyTargetEvent: NostrEvent? = nil
    var replyTargetDisplayNameHint: String? = nil
    var replyTargetHandleHint: String? = nil
    var replyTargetAvatarURLHint: URL? = nil
    var quotedEvent: NostrEvent? = nil
    var quotedDisplayNameHint: String? = nil
    var quotedHandleHint: String? = nil
    var quotedAvatarURLHint: URL? = nil
    var savedDraftID: UUID? = nil
    var onOptimisticPublished: ((FeedItem) -> Void)? = nil
    var onPublished: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            standardComposerLayout
                .background(composeSheetBackground)
            .navigationTitle(composerNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: ComposeToolbarLayout.leadingItemSpacing) {
                        Button {
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .font(ComposeToolbarLayout.cancelButtonFont)
                        }
                        draftLibraryToolbarButton
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: ComposeToolbarLayout.trailingItemSpacing) {
                        composeToolbarAvatar
                        publishToolbarButton
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(composeSheetBackground)
        .task {
            applyInitialContextIfNeeded()
            applyInitialDraftIfNeeded()
            applyInitialAttachmentsIfNeeded()
            applyInitialSelectedMentionsIfNeeded()
            applyInitialPollDraftIfNeeded()
            editorSelectedRange = NSRange(location: (viewModel.text as NSString).length, length: 0)
            isEditorFocused = true
            await applyInitialSharedAttachmentsIfNeeded()
        }
        .task(id: currentAccountPubkey) {
            await refreshComposeAccountSummary()
        }
        .task(id: currentReplyTargetEvent?.id) {
            async let summaryRefresh: Void = refreshReplyTargetAuthorSummaryIfNeeded()
            async let previewRefresh: Void = refreshReplyTargetPreviewIfNeeded()
            _ = await (summaryRefresh, previewRefresh)
        }
        .task(id: currentQuotedEvent?.id) {
            async let summaryRefresh: Void = refreshQuotedAuthorSummaryIfNeeded()
            async let previewRefresh: Void = refreshQuotedPreviewIfNeeded()
            _ = await (summaryRefresh, previewRefresh)
        }
        .onDisappear {
            mentionLookupTask?.cancel()
            cleanupInitialSharedAttachments()
            saveDraftIfNeededOnDismiss()
        }
        .onChange(of: selectedMediaItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            let items = newValue
            selectedMediaItems = []
            Task {
                await handleMediaSelection(items)
            }
        }
        .sheet(isPresented: $isShowingCapturePermissionSheet) {
            CameraCapturePermissionSheet(
                permissions: capturePermissions,
                isRequestingAccess: isRequestingCaptureAccess,
                onContinue: {
                    Task {
                        await requestCameraCaptureAccess()
                    }
                },
                onOpenSettings: openSystemSettings,
                onCancel: {
                    isShowingCapturePermissionSheet = false
                }
            )
            .presentationDetents([.height(365)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $isShowingCameraCapture) {
            CameraCaptureView(
                onCapture: { capturedMedia in
                    isShowingCameraCapture = false
                    Task {
                        await handleCapturedCameraMedia(capturedMedia)
                    }
                },
                onCancel: {
                    isShowingCameraCapture = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $previewingMediaAttachment) { attachment in
            ComposeMediaAttachmentPreviewSheet(attachment: attachment)
        }
        .sheet(isPresented: $isShowingKlipyGIFPicker) {
            ComposeKlipyGIFPickerSheet(currentAccountPubkey: currentAccountPubkey) { selection in
                Task {
                    await handleKlipyGIFSelection(selection)
                }
            }
        }
        .sheet(isPresented: $isShowingDraftLibrary) {
            ComposeDraftLibrarySheet(
                drafts: availableSavedDrafts,
                activeDraftID: activeSavedDraftID,
                onOpenDraft: loadSavedDraft(_:),
                onInsertText: insertSavedDraftText(_:),
                onDeleteDraft: deleteSavedDraft(_:),
                onCreateNewDraft: clearComposerForFreshDraft
            )
        }
    }

    private var mode: ComposeNoteSheetMode {
        ComposeNoteSheetMode(
            hasReplyTarget: currentReplyTargetEvent != nil,
            hasQuotedEvent: currentQuotedEvent != nil
        )
    }

    private var isQuoteComposer: Bool {
        mode == .quote
    }

    private var isReplyComposer: Bool {
        mode == .reply
    }

    private var composerNavigationTitle: String {
        mode.navigationTitle
    }

    private var publishButtonTitle: String {
        mode.publishButtonTitle
    }

    private var availableSavedDrafts: [SavedComposeDraft] {
        composeDraftStore.drafts(for: currentAccountPubkey)
    }

    private var availableSavedDraftCount: Int {
        availableSavedDrafts.count
    }

    private var draftLibraryCountText: String? {
        guard availableSavedDraftCount > 0 else { return nil }
        if availableSavedDraftCount > 99 {
            return "99+"
        }
        return "\(availableSavedDraftCount)"
    }

    private var draftLibraryAccessibilityLabel: String {
        if availableSavedDraftCount == 1 {
            return "Open drafts, 1 saved draft"
        }
        return "Open drafts, \(availableSavedDraftCount) saved drafts"
    }

    private var composeSheetBackground: Color {
        appSettings.activeTheme == .light ? .white : appSettings.themePalette.groupedBackground
    }

    private var draftLibraryToolbarButton: some View {
        Button {
            isShowingDraftLibrary = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: availableSavedDraftCount > 0 ? "tray.full.fill" : "tray")
                    .id(availableSavedDraftCount > 0)
                    .transition(FlowTransitionMotion.iconSwapTransition(reduceMotion: accessibilityReduceMotion))
                    .foregroundStyle(appSettings.primaryColor)

                if let draftLibraryCountText {
                    Text(draftLibraryCountText)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .id(draftLibraryCountText)
                        .transition(FlowTransitionMotion.numberPopTransition(reduceMotion: accessibilityReduceMotion))
                }
            }
            .animation(FlowTransitionMotion.iconSwapAnimation(reduceMotion: accessibilityReduceMotion), value: availableSavedDraftCount > 0)
            .animation(FlowTransitionMotion.numberPopAnimation(reduceMotion: accessibilityReduceMotion), value: draftLibraryCountText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
            .padding(.horizontal, ComposeToolbarLayout.draftButtonHorizontalPadding)
            .padding(.vertical, ComposeToolbarLayout.draftButtonVerticalPadding)
            .background(
                Capsule()
                    .fill(appSettings.themePalette.tertiaryFill.opacity(ComposeToolbarLayout.draftButtonBackgroundOpacity))
            )
            .overlay {
                Capsule()
                    .stroke(
                        appSettings.themePalette.separator.opacity(ComposeToolbarLayout.draftButtonBorderOpacity),
                        lineWidth: 0.7
                    )
            }
        }
        .accessibilityLabel(draftLibraryAccessibilityLabel)
    }

    private var standardComposerLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isReplyComposer {
                    replyTargetPreviewCard
                } else if isQuoteComposer {
                    quotePreviewCard
                }
                composeCard
                statusSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var publishToolbarButton: some View {
        ComposePublishToolbarButton(
            title: publishButtonTitle,
            isPublishing: viewModel.isPublishing,
            isEnabled: canPublish
        ) {
            Task {
                await publish()
            }
        }
    }

    private var composeToolbarAvatar: some View {
        ComposeToolbarAvatarView(
            avatarURL: profileAvatarURL,
            fallbackSymbol: profileFallbackSymbol,
            accessibilityLabel: "\(mode.accessibilityActionLabel) as \(profileDisplayName)"
        )
    }

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            composeEditor

            if !mediaAttachments.isEmpty {
                mediaAttachmentPreviewList
            }

            if let _ = pollDraft, canAttachPoll {
                ComposePollEditorView(
                    draft: pollDraftBinding,
                    onRemove: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            pollDraft = nil
                        }
                    }
                )
            }

            HStack {
                PhotosPicker(
                    selection: $selectedMediaItems,
                    selectionBehavior: .ordered,
                    matching: .any(of: [.images, .videos])
                ) {
                    composeToolbarCircle {
                        if isUploadingMedia {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 18, weight: .medium))
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(appSettings.primaryColor)
                .disabled(isUploadingMedia || viewModel.isPublishing)

                cameraAttachmentButton(symbolFont: .system(size: 18, weight: .medium))

                Button {
                    isShowingKlipyGIFPicker = true
                } label: {
                    Text("GIF")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(appSettings.themePalette.tertiaryFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appSettings.primaryColor)
                .disabled(isUploadingMedia || viewModel.isPublishing)

                Button {
                    Task {
                        await handleSpeechToggle()
                    }
                } label: {
                    composeToolbarCircle(isActive: speechTranscriber.isRecording) {
                        if speechTranscriber.isRecording {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 15, weight: .semibold))
                        } else if speechTranscriber.isTranscribing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 17, weight: .medium))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isPublishing || isUploadingMedia)

                if canAttachPoll {
                    Button {
                        togglePollDraft()
                    } label: {
                        composeToolbarCircle(isActive: pollDraft != nil) {
                            Image(systemName: pollDraft == nil ? "chart.bar.xaxis" : "chart.bar.fill")
                                .font(.system(size: 17, weight: .medium))
                                .id(pollDraft != nil)
                                .transition(FlowTransitionMotion.iconSwapTransition(reduceMotion: accessibilityReduceMotion))
                        }
                    }
                    .animation(FlowTransitionMotion.iconSwapAnimation(reduceMotion: accessibilityReduceMotion), value: pollDraft != nil)
                    .buttonStyle(.plain)
                    .disabled(viewModel.isPublishing || isUploadingMedia)
                    .accessibilityLabel(pollDraft == nil ? "Add poll" : "Edit poll")
                }

                if speechTranscriber.isRecording {
                    Text(formatVoiceDuration(milliseconds: speechTranscriber.elapsedMs))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }

                Spacer()

                ComposeCharacterCountRing(
                    characterCount: viewModel.characterCount,
                    characterLimit: viewModel.characterLimit
                )

                if currentNsec == nil {
                    Label("nsec required", systemImage: "lock.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                } else if writeRelayURLs.isEmpty {
                    Label("No connected sources", systemImage: "wifi.slash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composeEditor: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.text.isEmpty {
                Text(mode.placeholderText)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            }

            composeTextView(horizontalPadding: 8, verticalPadding: 8)
                .frame(minHeight: composeEditorMinHeight)
        }
        .overlay(alignment: .topLeading) {
            if shouldShowMentionSuggestions {
                mentionSuggestionList
                    .padding(.top, mentionSuggestionPanelTopPadding)
                    .padding(.horizontal, 8)
                    .zIndex(2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: shouldShowMentionSuggestions)
        .animation(.easeInOut(duration: 0.16), value: mentionSuggestionPanelTopPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zIndex(shouldShowMentionSuggestions ? 1 : 0)
    }

    private var composeEditorMinHeight: CGFloat {
        guard shouldShowMentionSuggestions else { return 180 }
        return max(180, mentionSuggestionPanelTopPadding + ComposeMentionSuggestionPanel.maxHeight + 12)
    }

    private var mentionSuggestionPanelTopPadding: CGFloat {
        min(max(mentionSuggestionAnchorY + 12, 42), 118)
    }

    private var statusSection: some View {
        ComposeStatusSectionView(
            isPublishing: viewModel.isPublishing,
            publishSourceCount: configuredPublishSourceCount,
            feedbackMessage: viewModel.feedbackMessage,
            feedbackIsError: viewModel.feedbackIsError,
            isTranscribingSpeech: speechTranscriber.isTranscribing,
            missingNsec: currentNsec == nil,
            missingPublishSources: writeRelayURLs.isEmpty,
            pollValidationMessage: pollValidationMessage
        )
    }

    @ViewBuilder
    private func composeTextView(horizontalPadding: CGFloat, verticalPadding: CGFloat) -> some View {
        ComposeMultilineTextView(
            text: $viewModel.text,
            isFocused: $isEditorFocused,
            selectedRange: $editorSelectedRange,
            mentions: $selectedMentions,
            mentionAnchorY: $mentionSuggestionAnchorY,
            mentionColor: UIColor(appSettings.primaryColor),
            characterLimit: ComposeNoteTextLimit.maxCharacterCount,
            onMentionQueryChange: handleMentionQueryChange(_:)
        )
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private var shouldShowMentionSuggestions: Bool {
        guard isEditorFocused, activeMentionQuery != nil else { return false }
        return isLoadingMentionSuggestions || !mentionSuggestions.isEmpty
    }

    private var mentionSuggestionList: some View {
        ComposeMentionSuggestionPanel(
            suggestions: mentionSuggestions,
            isLoading: isLoadingMentionSuggestions,
            onSelect: insertMentionSuggestion(_:)
        )
    }

    private var canPublish: Bool {
        let baseIsReadyToPublish =
            currentNsec != nil &&
            !writeRelayURLs.isEmpty &&
            !speechTranscriber.isRecording &&
            !speechTranscriber.isTranscribing &&
            !viewModel.isPublishing

        guard baseIsReadyToPublish else { return false }

        if let pollDraft {
            return !viewModel.trimmedText.isEmpty && pollDraft.hasMinimumOptions
        }

        return !viewModel.trimmedText.isEmpty || !mediaAttachments.isEmpty || currentQuotedEvent != nil
    }

    private func handleMentionQueryChange(_ query: ComposeMentionQuery?) {
        guard query != activeMentionQuery else { return }
        activeMentionQuery = query
        mentionLookupTask?.cancel()

        guard isEditorFocused, let query else {
            mentionSuggestions = []
            isLoadingMentionSuggestions = false
            return
        }

        isLoadingMentionSuggestions = true
        mentionSuggestions = []
        mentionLookupTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await refreshMentionSuggestions(for: query)
        }
    }

    private func refreshMentionSuggestions(for query: ComposeMentionQuery) async {
        let normalizedQuery = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let followedPubkeys = await MainActor.run {
            FollowStore.shared.followedPubkeys
        }
        let profileResults: [ProfileSearchResult]
        if normalizedQuery.isEmpty {
            profileResults = await localMentionSeedProfileResults(
                followedPubkeys: followedPubkeys,
                limit: 24
            )
        } else {
            profileResults = await profileService.searchProfiles(
                query: normalizedQuery,
                limit: 24,
                preferredPubkeys: followedPubkeys
            )
        }

        let excludedPubkeys = Set(selectedMentions.map(\.pubkey))
        let normalizedCurrentPubkey = currentAccountPubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let suggestions = profileResults.compactMap(ComposeMentionSuggestion.init).filter { suggestion in
            guard !excludedPubkeys.contains(suggestion.pubkey) else { return false }
            if let normalizedCurrentPubkey, suggestion.pubkey == normalizedCurrentPubkey {
                return false
            }
            return true
        }

        guard !Task.isCancelled else { return }

        await MainActor.run {
            guard activeMentionQuery == query else { return }
            mentionSuggestions = suggestions
            isLoadingMentionSuggestions = false
        }
    }

    private func localMentionSeedProfileResults(
        followedPubkeys: Set<String>,
        limit: Int
    ) async -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        let orderedFollowedPubkeys = await orderedFollowedMentionPubkeys(fallback: followedPubkeys)
        let followedCandidates = Array(orderedFollowedPubkeys.prefix(max(limit * 3, 48)))
        let followedProfiles = await profileService.cachedProfiles(pubkeys: followedCandidates)
        let followedResults = followedCandidates.enumerated().compactMap { index, pubkey -> ProfileSearchResult? in
            guard let profile = followedProfiles[pubkey] else { return nil }
            return ProfileSearchResult(
                pubkey: pubkey,
                profile: profile,
                createdAt: Int.max - index
            )
        }
        let recentResults = await profileService.recentLocalProfiles(limit: limit)

        return mergedMentionProfileResults(
            [followedResults, recentResults],
            limit: limit
        )
    }

    private func orderedFollowedMentionPubkeys(fallback followedPubkeys: Set<String>) async -> [String] {
        if let normalizedCurrentPubkey = currentAccountPubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !normalizedCurrentPubkey.isEmpty,
           let snapshot = await profileService.cachedFollowListSnapshot(pubkey: normalizedCurrentPubkey) {
            let ordered = normalizedUniqueMentionPubkeys(snapshot.followedPubkeys)
            if !ordered.isEmpty {
                return ordered
            }
        }

        return normalizedUniqueMentionPubkeys(Array(followedPubkeys).sorted())
    }

    private func mergedMentionProfileResults(
        _ groups: [[ProfileSearchResult]],
        limit: Int
    ) -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var merged: [ProfileSearchResult] = []
        merged.reserveCapacity(limit)

        for group in groups {
            for result in group {
                let pubkey = result.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !pubkey.isEmpty, seen.insert(pubkey).inserted else { continue }
                merged.append(result)
                if merged.count >= limit {
                    return merged
                }
            }
        }

        return merged
    }

    private func normalizedUniqueMentionPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(pubkeys.count)

        for pubkey in pubkeys {
            let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func insertMentionSuggestion(_ suggestion: ComposeMentionSuggestion) {
        guard let query = activeMentionQuery else { return }

        let insertion = ComposeMentionSupport.insertSuggestion(
            suggestion,
            into: viewModel.text,
            replacing: query,
            existingMentions: selectedMentions
        )
        viewModel.text = insertion.text
        selectedMentions = insertion.mentions
        editorSelectedRange = insertion.selectedRange
        mentionSuggestions = []
        activeMentionQuery = nil
        isLoadingMentionSuggestions = false
        isEditorFocused = true
    }

    private var canAttachPoll: Bool {
        mode == .newNote
    }

    private var pollDraftBinding: Binding<ComposePollDraft> {
        Binding(
            get: { pollDraft ?? .defaultDraft() },
            set: { pollDraft = $0 }
        )
    }

    private var pollValidationMessage: String? {
        guard let pollDraft else { return nil }
        if viewModel.trimmedText.isEmpty {
            return "Polls need a question."
        }
        if !pollDraft.hasMinimumOptions {
            return "Add at least two option labels before posting."
        }
        return nil
    }

    private var replyTargetDisplayNameResolved: String {
        if let replyTargetDisplayName {
            let trimmed = replyTargetDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let previewSnapshot = replyTargetPreviewSnapshot {
            return String(previewSnapshot.authorPubkey.prefix(8))
        }
        return "Reply target"
    }

    private var replyTargetHandleResolved: String {
        if let replyTargetHandle {
            let trimmed = replyTargetHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
            }
        }
        if let previewSnapshot = replyTargetPreviewSnapshot {
            return "@\(String(previewSnapshot.authorPubkey.prefix(8)).lowercased())"
        }
        return "@unknown"
    }

    private var quotedDisplayNameResolved: String {
        if let quotedDisplayName {
            let trimmed = quotedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let previewSnapshot = quotedPreviewSnapshot {
            return String(previewSnapshot.authorPubkey.prefix(8))
        }
        return "Quoted note"
    }

    private var quotedHandleResolved: String {
        if let quotedHandle {
            let trimmed = quotedHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
            }
        }
        if let previewSnapshot = quotedPreviewSnapshot {
            return "@\(String(previewSnapshot.authorPubkey.prefix(8)).lowercased())"
        }
        return "@unknown"
    }

    private var replyTargetPreviewCard: some View {
        Group {
            if let previewSnapshot = replyTargetPreviewSnapshot {
                ComposeContextPreviewCardView(
                    title: "Replying to",
                    previewSnapshot: previewSnapshot,
                    displayName: replyTargetDisplayNameResolved,
                    handle: replyTargetHandleResolved,
                    avatarURL: replyTargetAvatarURL,
                    fallbackText: replyTargetDisplayNameResolved,
                    videoSummary: "Note includes video",
                    audioSummary: "Note includes audio",
                    pollSummary: "Note includes poll"
                )
            }
        }
    }

    private var quotePreviewCard: some View {
        Group {
            if let previewSnapshot = quotedPreviewSnapshot {
                ComposeContextPreviewCardView(
                    title: "Quoting",
                    previewSnapshot: previewSnapshot,
                    displayName: quotedDisplayNameResolved,
                    handle: quotedHandleResolved,
                    avatarURL: quotedAvatarURL,
                    fallbackText: quotedDisplayNameResolved,
                    videoSummary: "Quoted note includes video",
                    audioSummary: "Quoted note includes audio",
                    pollSummary: "Quoted note includes poll"
                )
            }
        }
    }

    private var mediaAttachmentPreviewList: some View {
        ComposeMediaAttachmentStrip(
            attachments: mediaAttachments,
            colorScheme: colorScheme,
            onPreview: { attachment in
                previewingMediaAttachment = attachment
            },
            onRemove: removeMediaAttachment(_:)
        )
    }

    private func composeToolbarCircle<Content: View>(
        isActive: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(isActive ? Color.white : appSettings.primaryColor)
            .tint(isActive ? Color.white : appSettings.primaryColor)
            .frame(width: 32, height: 32)
            .background(
                isActive ? appSettings.primaryColor : appSettings.themePalette.tertiaryFill,
                in: Circle()
            )
    }

    private func cameraAttachmentButton(symbolFont: Font) -> some View {
        Button {
            handleCameraButtonTap()
        } label: {
            composeToolbarCircle {
                Image(systemName: "camera")
                    .font(symbolFont)
            }
        }
        .buttonStyle(.plain)
        .disabled(isUploadingMedia || viewModel.isPublishing || isRequestingCaptureAccess)
        .accessibilityLabel("Capture photo or video")
    }

    private func refreshComposeAccountSummary() async {
        guard let currentAccountPubkey else {
            profileDisplayName = "Account"
            profileAvatarURL = nil
            profileFallbackSymbol = ""
            return
        }

        let normalizedPubkey = currentAccountPubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPubkey.isEmpty else { return }

        let fallbackIdentifier = shortNostrIdentifier(normalizedPubkey)
        profileDisplayName = fallbackIdentifier
        profileAvatarURL = nil
        profileFallbackSymbol = ""

        if let cachedProfile = await profileService.cachedProfile(pubkey: normalizedPubkey) {
            applyComposeProfile(cachedProfile, pubkey: normalizedPubkey)
        }

        let readRelayURLs = RelaySettingsStore.shared.readRelayURLs
        let fallbackRelayURLs = RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
        let relayTargets = readRelayURLs.isEmpty ? fallbackRelayURLs : readRelayURLs
        guard !relayTargets.isEmpty else { return }

        if let fetchedProfile = await profileService.fetchProfile(relayURLs: relayTargets, pubkey: normalizedPubkey) {
            applyComposeProfile(fetchedProfile, pubkey: normalizedPubkey)
        }
    }

    private func applyComposeProfile(_ profile: NostrProfile, pubkey: String) {
        let preferredName: String?

        if let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            preferredName = displayName
        } else if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            preferredName = name
        } else {
            preferredName = nil
        }

        profileDisplayName = preferredName ?? shortNostrIdentifier(pubkey)
        profileFallbackSymbol = preferredName.map { String($0.prefix(1)).uppercased() } ?? ""
        profileAvatarURL = profile.resolvedAvatarURL
    }

    private func refreshReplyTargetAuthorSummaryIfNeeded() async {
        guard let currentReplyTargetEvent else { return }

        if let currentReplyTargetDisplayNameHint {
            let trimmed = currentReplyTargetDisplayNameHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                replyTargetDisplayName = trimmed
            }
        }

        if let currentReplyTargetHandleHint {
            let trimmed = currentReplyTargetHandleHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                replyTargetHandle = trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
            }
        }

        if let currentReplyTargetAvatarURLHint {
            replyTargetAvatarURL = currentReplyTargetAvatarURLHint
        }

        let normalizedPubkey = currentReplyTargetEvent.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPubkey.isEmpty else { return }

        if let cachedProfile = await profileService.cachedProfile(pubkey: normalizedPubkey) {
            applyReplyTargetProfile(cachedProfile, pubkey: normalizedPubkey)
        }

        let readRelayURLs = RelaySettingsStore.shared.readRelayURLs
        let fallbackRelayURLs = RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
        let relayTargets = readRelayURLs.isEmpty ? fallbackRelayURLs : readRelayURLs
        guard !relayTargets.isEmpty else { return }

        if let fetchedProfile = await profileService.fetchProfile(relayURLs: relayTargets, pubkey: normalizedPubkey) {
            applyReplyTargetProfile(fetchedProfile, pubkey: normalizedPubkey)
        } else {
            if replyTargetDisplayName == nil {
                replyTargetDisplayName = String(normalizedPubkey.prefix(8))
            }
            if replyTargetHandle == nil {
                replyTargetHandle = "@\(String(normalizedPubkey.prefix(8)).lowercased())"
            }
        }
    }

    private func applyReplyTargetProfile(_ profile: NostrProfile, pubkey: String) {
        if let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            replyTargetDisplayName = displayName
        } else if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            replyTargetDisplayName = name
        } else if replyTargetDisplayName == nil {
            replyTargetDisplayName = String(pubkey.prefix(8))
        }

        let handleSeed = (profile.name ?? profile.displayName ?? String(pubkey.prefix(8)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if !handleSeed.isEmpty {
            replyTargetHandle = "@\(handleSeed)"
        } else if replyTargetHandle == nil {
            replyTargetHandle = "@\(String(pubkey.prefix(8)).lowercased())"
        }

        replyTargetAvatarURL = profile.resolvedAvatarURL
    }

    private func refreshReplyTargetPreviewIfNeeded() async {
        guard let currentReplyTargetEvent else {
            replyTargetPreviewSnapshot = nil
            return
        }

        let previewSnapshot = await Self.makeContextPreviewSnapshot(for: currentReplyTargetEvent)
        guard !Task.isCancelled else { return }
        replyTargetPreviewSnapshot = previewSnapshot
    }

    private func refreshQuotedAuthorSummaryIfNeeded() async {
        guard let currentQuotedEvent else { return }

        if let currentQuotedDisplayNameHint {
            let trimmed = currentQuotedDisplayNameHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                quotedDisplayName = trimmed
            }
        }

        if let currentQuotedHandleHint {
            let trimmed = currentQuotedHandleHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                quotedHandle = trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
            }
        }

        if let currentQuotedAvatarURLHint {
            quotedAvatarURL = currentQuotedAvatarURLHint
        }

        let normalizedPubkey = currentQuotedEvent.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPubkey.isEmpty else { return }

        if let cachedProfile = await profileService.cachedProfile(pubkey: normalizedPubkey) {
            applyQuotedProfile(cachedProfile, pubkey: normalizedPubkey)
        }

        let readRelayURLs = RelaySettingsStore.shared.readRelayURLs
        let fallbackRelayURLs = RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
        let relayTargets = readRelayURLs.isEmpty ? fallbackRelayURLs : readRelayURLs
        guard !relayTargets.isEmpty else { return }

        if let fetchedProfile = await profileService.fetchProfile(relayURLs: relayTargets, pubkey: normalizedPubkey) {
            applyQuotedProfile(fetchedProfile, pubkey: normalizedPubkey)
        } else {
            if quotedDisplayName == nil {
                quotedDisplayName = String(normalizedPubkey.prefix(8))
            }
            if quotedHandle == nil {
                quotedHandle = "@\(String(normalizedPubkey.prefix(8)).lowercased())"
            }
        }
    }

    private func applyQuotedProfile(_ profile: NostrProfile, pubkey: String) {
        if let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            quotedDisplayName = displayName
        } else if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            quotedDisplayName = name
        } else if quotedDisplayName == nil {
            quotedDisplayName = String(pubkey.prefix(8))
        }

        let handleSeed = (profile.name ?? profile.displayName ?? String(pubkey.prefix(8)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if !handleSeed.isEmpty {
            quotedHandle = "@\(handleSeed)"
        } else if quotedHandle == nil {
            quotedHandle = "@\(String(pubkey.prefix(8)).lowercased())"
        }

        quotedAvatarURL = profile.resolvedAvatarURL
    }

    private func refreshQuotedPreviewIfNeeded() async {
        guard let currentQuotedEvent else {
            quotedPreviewSnapshot = nil
            return
        }

        let previewSnapshot = await Self.makeContextPreviewSnapshot(
            for: currentQuotedEvent,
            maximumLength: 220
        )
        guard !Task.isCancelled else { return }
        quotedPreviewSnapshot = previewSnapshot
    }

    private func handleCameraButtonTap() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            viewModel.feedbackMessage = "This device doesn't have an available camera right now."
            viewModel.feedbackIsError = true
            return
        }

        let permissions = CameraCapturePermissionSnapshot.current()
        capturePermissions = permissions

        if permissions.isCameraBlocked {
            isShowingCapturePermissionSheet = true
            return
        }

        if permissions.cameraRequiresPrompt || permissions.microphoneRequiresPrompt {
            isShowingCapturePermissionSheet = true
            return
        }

        presentCameraCapture(using: permissions)
    }

    private func requestCameraCaptureAccess() async {
        guard !isRequestingCaptureAccess else { return }
        isRequestingCaptureAccess = true
        defer { isRequestingCaptureAccess = false }

        var permissions = CameraCapturePermissionSnapshot.current()

        if permissions.cameraRequiresPrompt {
            _ = await requestCaptureAccess(for: .video)
            permissions = CameraCapturePermissionSnapshot.current()
        }

        guard !permissions.isCameraBlocked else {
            capturePermissions = permissions
            return
        }

        if permissions.microphoneRequiresPrompt {
            _ = await requestCaptureAccess(for: .audio)
            permissions = CameraCapturePermissionSnapshot.current()
        }

        capturePermissions = permissions
        isShowingCapturePermissionSheet = false
        presentCameraCapture(using: permissions)
    }

    private func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func presentCameraCapture(using permissions: CameraCapturePermissionSnapshot) {
        capturePermissions = permissions

        if permissions.isMicrophoneBlocked {
            viewModel.feedbackMessage = "Microphone access is off. You can still take photos, but video capture with sound may be limited until you enable it in app settings."
            viewModel.feedbackIsError = false
        } else {
            viewModel.feedbackMessage = nil
            viewModel.feedbackIsError = false
        }

        isShowingCameraCapture = true
    }

    private func handleCapturedCameraMedia(_ capturedMedia: CapturedCameraMedia) async {
        guard !isUploadingMedia else { return }
        viewModel.feedbackMessage = nil
        viewModel.feedbackIsError = false

        guard let normalizedNsec = currentNsec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedNsec.isEmpty else {
            viewModel.feedbackMessage = "Sign in with a private key to upload media."
            viewModel.feedbackIsError = true
            return
        }

        isUploadingMedia = true
        defer {
            isUploadingMedia = false
        }

        do {
            let attachment = try await uploadCapturedMediaAttachment(capturedMedia, normalizedNsec: normalizedNsec)
            if !mediaAttachments.contains(where: { $0.url == attachment.url }) {
                mediaAttachments.append(attachment)
                removeUploadedMediaURLIfPresent(attachment.url)
            }
            isEditorFocused = true
        } catch {
            viewModel.feedbackMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't upload media right now."
            viewModel.feedbackIsError = true
        }
    }

    private func handleMediaSelection(_ items: [PhotosPickerItem]) async {
        guard !isUploadingMedia else { return }
        viewModel.feedbackMessage = nil
        viewModel.feedbackIsError = false

        guard let normalizedNsec = currentNsec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedNsec.isEmpty else {
            viewModel.feedbackMessage = "Sign in with a private key to upload media."
            viewModel.feedbackIsError = true
            return
        }

        isUploadingMedia = true
        defer {
            isUploadingMedia = false
        }

        var failedUploads = 0
        var firstError: Error?

        for item in items {
            do {
                let attachment = try await uploadMediaAttachment(from: item, normalizedNsec: normalizedNsec)

                if !mediaAttachments.contains(where: { $0.url == attachment.url }) {
                    mediaAttachments.append(attachment)
                    removeUploadedMediaURLIfPresent(attachment.url)
                }
            } catch {
                failedUploads += 1
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if failedUploads > 0 {
            let successfulUploads = items.count - failedUploads
            let detailedMessage = (firstError as? LocalizedError)?.errorDescription ?? firstError?.localizedDescription
            if successfulUploads > 0 {
                if let detailedMessage, !detailedMessage.isEmpty {
                    viewModel.feedbackMessage = "Uploaded \(successfulUploads) attachment\(successfulUploads == 1 ? "" : "s"), but \(failedUploads) failed: \(detailedMessage)"
                } else {
                    viewModel.feedbackMessage = "Uploaded \(successfulUploads) attachment\(successfulUploads == 1 ? "" : "s"), but \(failedUploads) failed."
                }
            } else {
                viewModel.feedbackMessage = detailedMessage ?? "Couldn't upload media right now."
            }
            viewModel.feedbackIsError = true
        }

        if failedUploads < items.count {
            isEditorFocused = true
        }
    }

    private func uploadMediaAttachment(from item: PhotosPickerItem, normalizedNsec: String) async throws -> ComposeMediaAttachment {
        let preparedMedia = try await MediaUploadPreparation.prepareUploadMedia(from: item)
        let filename = "note-\(UUID().uuidString).\(preparedMedia.fileExtension)"

        let result = try await mediaUploadService.uploadMedia(
            data: preparedMedia.data,
            mimeType: preparedMedia.mimeType,
            filename: filename,
            nsec: normalizedNsec,
            provider: .blossom
        )

        return ComposeMediaAttachment(
            url: result.url,
            imetaTag: result.imetaTag,
            mimeType: preparedMedia.mimeType,
            fileSizeBytes: preparedMedia.data.count
        )
    }

    private func handleKlipyGIFSelection(_ selection: KlipyGIFAttachmentCandidate) async {
        guard !isUploadingMedia else { return }
        viewModel.feedbackMessage = nil
        viewModel.feedbackIsError = false

        guard let normalizedNsec = currentNsec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedNsec.isEmpty else {
            viewModel.feedbackMessage = "Sign in with a private key to upload media."
            viewModel.feedbackIsError = true
            return
        }

        isUploadingMedia = true
        defer {
            isUploadingMedia = false
        }

        do {
            let attachment = try await uploadKlipyGIFAttachment(selection, normalizedNsec: normalizedNsec)

            if !mediaAttachments.contains(where: { $0.url == attachment.url }) {
                mediaAttachments.append(attachment)
                removeUploadedMediaURLIfPresent(attachment.url)
            }

            isEditorFocused = true
            toastCenter.show("GIF added")

            Task {
                await klipyGIFService.registerShare(
                    slug: selection.slug,
                    customerID: selection.customerID,
                    query: selection.searchQuery
                )
            }
        } catch {
            viewModel.feedbackMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't add that GIF right now."
            viewModel.feedbackIsError = true
        }
    }

    private func uploadKlipyGIFAttachment(
        _ selection: KlipyGIFAttachmentCandidate,
        normalizedNsec: String
    ) async throws -> ComposeMediaAttachment {
        let downloadedData = try await klipyGIFService.downloadGIFData(for: selection)
        let preparedMedia = try await MediaUploadPreparation.prepareGIFKeyboardUploadMedia(
            data: downloadedData,
            mimeType: selection.mimeType,
            fileExtension: selection.fileExtension
        )
        let filename = "gif-\(UUID().uuidString).\(preparedMedia.fileExtension)"

        let result = try await mediaUploadService.uploadMedia(
            data: preparedMedia.data,
            mimeType: preparedMedia.mimeType,
            filename: filename,
            nsec: normalizedNsec,
            provider: .blossom
        )

        let imetaTag = gifKeyboardIMetaTag(
            from: result.imetaTag,
            preparedMedia: preparedMedia
        )

        return ComposeMediaAttachment(
            url: result.url,
            imetaTag: imetaTag,
            mimeType: preparedMedia.mimeType,
            fileSizeBytes: preparedMedia.data.count
        )
    }

    private func gifKeyboardIMetaTag(
        from imetaTag: [String],
        preparedMedia: PreparedUploadMedia
    ) -> [String] {
        guard preparedMedia.mimeType.lowercased().hasPrefix("video/") else {
            return imetaTag
        }

        var updatedTag = imetaTag
        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("m ") }) {
            updatedTag.append("m \(preparedMedia.mimeType)")
        }
        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("size ") }) {
            updatedTag.append("size \(preparedMedia.data.count)")
        }
        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("flow-gif-loop ") }) {
            updatedTag.append("flow-gif-loop 1")
        }

        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("dim ") }),
           let previewSize = preparedMedia.previewImage?.size,
           previewSize.width > 0,
           previewSize.height > 0 {
            updatedTag.append("dim \(Int(previewSize.width.rounded()))x\(Int(previewSize.height.rounded()))")
        }

        return updatedTag
    }

    private func uploadCapturedMediaAttachment(
        _ capturedMedia: CapturedCameraMedia,
        normalizedNsec: String
    ) async throws -> ComposeMediaAttachment {
        let preparedMedia: PreparedUploadMedia

        switch capturedMedia {
        case .image(let imageData, let capturedMimeType, let capturedFileExtension):
            preparedMedia = try MediaUploadPreparation.prepareUploadMedia(
                data: imageData,
                mimeType: capturedMimeType,
                fileExtension: capturedFileExtension
            )

        case .video(let fileURL, let capturedMimeType, let capturedFileExtension):
            preparedMedia = try await MediaUploadPreparation.prepareUploadMedia(
                fileURL: fileURL,
                mimeType: capturedMimeType,
                fileExtension: capturedFileExtension
            )
        }

        let filename = "note-\(UUID().uuidString).\(preparedMedia.fileExtension)"
        let result = try await mediaUploadService.uploadMedia(
            data: preparedMedia.data,
            mimeType: preparedMedia.mimeType,
            filename: filename,
            nsec: normalizedNsec,
            provider: .blossom
        )

        return ComposeMediaAttachment(
            url: result.url,
            imetaTag: result.imetaTag,
            mimeType: preparedMedia.mimeType,
            fileSizeBytes: preparedMedia.data.count
        )
    }

    private func uploadSharedComposeAttachment(
        _ sharedAttachment: SharedComposeAttachment,
        normalizedNsec: String
    ) async throws -> ComposeMediaAttachment {
        let preparedMedia = try await prepareSharedComposeAttachmentForUpload(sharedAttachment)
        let filename = "note-\(UUID().uuidString).\(preparedMedia.fileExtension)"
        let result = try await mediaUploadService.uploadMedia(
            data: preparedMedia.data,
            mimeType: preparedMedia.mimeType,
            filename: filename,
            nsec: normalizedNsec,
            provider: .blossom
        )

        return ComposeMediaAttachment(
            url: result.url,
            imetaTag: result.imetaTag,
            mimeType: preparedMedia.mimeType,
            fileSizeBytes: preparedMedia.data.count
        )
    }

    private func removeMediaAttachment(_ attachment: ComposeMediaAttachment) {
        mediaAttachments.removeAll { $0.id == attachment.id }
    }

    private func removeUploadedMediaURLIfPresent(_ url: URL) {
        let urlString = url.absoluteString
        guard viewModel.text.contains(urlString) else { return }

        viewModel.text = viewModel.text
            .replacingOccurrences(of: "\n\(urlString)", with: "")
            .replacingOccurrences(of: urlString, with: "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleSpeechToggle() async {
        let errorMessage = await speechTranscriber.toggleRecording { transcript in
            appendSpeechToDraft(transcript)
        }

        if let errorMessage {
            viewModel.feedbackMessage = errorMessage
            viewModel.feedbackIsError = true
        }
    }

    private func appendSpeechToDraft(_ transcript: String) {
        let normalized = transcript
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.text = normalized
        } else {
            let needsSeparator = !(viewModel.text.hasSuffix(" ") || viewModel.text.hasSuffix("\n"))
            viewModel.text += needsSeparator ? " \(normalized)" : normalized
        }
        isEditorFocused = true
    }

    private func formatVoiceDuration(milliseconds: Int) -> String {
        let safeMilliseconds = max(milliseconds, 0)
        let totalSeconds = safeMilliseconds / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func defaultFileExtension(for mimeType: String) -> String {
        let normalized = mimeType.lowercased()
        if normalized.contains("jpeg") || normalized.contains("jpg") {
            return "jpg"
        }
        if normalized.contains("png") {
            return "png"
        }
        if normalized.contains("heic") {
            return "heic"
        }
        if normalized.contains("gif") {
            return "gif"
        }
        if normalized.contains("webp") {
            return "webp"
        }
        if normalized.contains("quicktime") || normalized.contains("mov") {
            return "mov"
        }
        if normalized.contains("mp4") {
            return "mp4"
        }
        if normalized.contains("mpeg") || normalized.contains("mp3") {
            return "mp3"
        }
        if normalized.contains("m4a") {
            return "m4a"
        }
        return "bin"
    }

    private func openSystemSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    private func togglePollDraft() {
        withAnimation(FlowTransitionMotion.iconSwapAnimation(reduceMotion: accessibilityReduceMotion)) {
            if pollDraft == nil {
                pollDraft = .defaultDraft()
            } else {
                pollDraft = nil
            }
        }
    }

    private func publish() async {
        guard canPublish else {
            if currentNsec == nil {
                viewModel.feedbackMessage = "This account needs an nsec to publish notes."
            } else if writeRelayURLs.isEmpty {
                viewModel.feedbackMessage = "No connected sources are configured."
            } else if let pollValidationMessage {
                viewModel.feedbackMessage = pollValidationMessage
            } else {
                viewModel.feedbackMessage = currentNsec == nil
                    ? "This account needs an nsec to publish notes."
                    : writeRelayURLs.isEmpty
                        ? "No connected sources are configured."
                        : "Write a note or attach media before posting."
            }
            viewModel.feedbackIsError = true
            return
        }

        let preparedMentions = ComposeMentionSupport.preparedMentions(
            from: viewModel.text,
            selectedMentions: selectedMentions
        )
        let publishTags = mediaAttachments.map(\.imetaTag) + currentAdditionalTags + preparedMentions.additionalTags
        guard let preparedPublication = await viewModel.preparePublication(
            content: preparedMentions.content,
            currentAccountPubkey: currentAccountPubkey,
            currentNsec: currentNsec,
            writeRelayURLs: writeRelayURLs,
            additionalTags: publishTags,
            pollDraft: pollDraft,
            replyTargetEvent: currentReplyTargetEvent
        ) else {
            return
        }

        hasPublishedSuccessfully = true
        if let activeSavedDraftID {
            composeDraftStore.deleteDraft(id: activeSavedDraftID)
        }
        mediaAttachments.removeAll()
        pollDraft = nil
        selectedMentions.removeAll()
        activeMentionQuery = nil
        mentionSuggestions = []
        activeSavedDraftID = nil
        editorSelectedRange = NSRange(location: 0, length: 0)
        LocalPublicationStore.shared.registerPublishing(item: preparedPublication.item)
        onOptimisticPublished?(preparedPublication.item)
        toastCenter.show(preparedPublication.isReply ? "Reply publishing" : preparedPublication.isPoll ? "Poll publishing" : "Note publishing", style: .info)
        dismiss()

        Task {
            let didFinish = await viewModel.finishPublication(preparedPublication)
            await MainActor.run {
                if didFinish {
                    LocalPublicationStore.shared.markPosted(eventID: preparedPublication.item.id)
                    onPublished?()
                    if preparedPublication.isPoll {
                        toastCenter.show("Poll posted")
                    } else {
                        toastCenter.show(preparedPublication.isReply ? "Reply posted" : "Note posted")
                    }
                } else {
                    let failureMessage = sanitizedPublicationFailureMessage(viewModel.feedbackMessage)
                    LocalPublicationStore.shared.markFailed(
                        eventID: preparedPublication.item.id,
                        message: failureMessage
                    )
                    let message = failureMessage
                        ?? "Couldn't publish to connected sources right now. It is still visible here."
                    toastCenter.show(message, style: .error, duration: 2.8)
                }
            }
        }
    }

    private func applyInitialContextIfNeeded() {
        guard !hasAppliedInitialContext else { return }
        hasAppliedInitialContext = true
        applyComposerContext(
            additionalTags: initialAdditionalTags,
            replyTargetEvent: replyTargetEvent,
            replyTargetDisplayNameHint: replyTargetDisplayNameHint,
            replyTargetHandleHint: replyTargetHandleHint,
            replyTargetAvatarURLHint: replyTargetAvatarURLHint,
            quotedEvent: quotedEvent,
            quotedDisplayNameHint: quotedDisplayNameHint,
            quotedHandleHint: quotedHandleHint,
            quotedAvatarURLHint: quotedAvatarURLHint
        )
        activeSavedDraftID = savedDraftID
    }

    private func sanitizedPublicationFailureMessage(_ message: String?) -> String? {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }

        return message
            .replacingOccurrences(of: "relays", with: "connections", options: .caseInsensitive)
            .replacingOccurrences(of: "relay", with: "connection", options: .caseInsensitive)
    }

    private func applyInitialDraftIfNeeded() {
        guard !hasAppliedInitialDraft else { return }
        hasAppliedInitialDraft = true

        guard viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.text = initialText
        editorSelectedRange = NSRange(location: (initialText as NSString).length, length: 0)
    }

    private func applyInitialSelectedMentionsIfNeeded() {
        guard !hasAppliedInitialSelectedMentions else { return }
        hasAppliedInitialSelectedMentions = true
        guard selectedMentions.isEmpty else { return }
        selectedMentions = initialSelectedMentions
    }

    private func applyInitialPollDraftIfNeeded() {
        guard !hasAppliedInitialPollDraft else { return }
        hasAppliedInitialPollDraft = true
        guard pollDraft == nil else { return }
        pollDraft = initialPollDraft
    }

    private func applyInitialAttachmentsIfNeeded() {
        guard !hasAppliedInitialAttachments else { return }
        hasAppliedInitialAttachments = true

        guard !initialUploadedAttachments.isEmpty else { return }

        for attachment in initialUploadedAttachments {
            guard !mediaAttachments.contains(where: { $0.url == attachment.url }) else { continue }
            mediaAttachments.append(attachment)
            removeUploadedMediaURLIfPresent(attachment.url)
        }
    }

    private func applyComposerContext(
        additionalTags: [[String]],
        replyTargetEvent: NostrEvent?,
        replyTargetDisplayNameHint: String?,
        replyTargetHandleHint: String?,
        replyTargetAvatarURLHint: URL?,
        quotedEvent: NostrEvent?,
        quotedDisplayNameHint: String?,
        quotedHandleHint: String?,
        quotedAvatarURLHint: URL?
    ) {
        currentAdditionalTags = additionalTags
        currentReplyTargetEvent = replyTargetEvent
        currentReplyTargetDisplayNameHint = normalizedDraftHint(replyTargetDisplayNameHint)
        currentReplyTargetHandleHint = normalizedDraftHandle(replyTargetHandleHint)
        currentReplyTargetAvatarURLHint = replyTargetAvatarURLHint
        currentQuotedEvent = quotedEvent
        currentQuotedDisplayNameHint = normalizedDraftHint(quotedDisplayNameHint)
        currentQuotedHandleHint = normalizedDraftHandle(quotedHandleHint)
        currentQuotedAvatarURLHint = quotedAvatarURLHint

        replyTargetDisplayName = currentReplyTargetDisplayNameHint
        replyTargetHandle = currentReplyTargetHandleHint
        replyTargetAvatarURL = currentReplyTargetAvatarURLHint
        quotedDisplayName = currentQuotedDisplayNameHint
        quotedHandle = currentQuotedHandleHint
        quotedAvatarURL = currentQuotedAvatarURLHint
        replyTargetPreviewSnapshot = nil
        quotedPreviewSnapshot = nil
    }

    private func saveDraftIfNeededOnDismiss() {
        guard !hasPublishedSuccessfully else { return }
        guard !isShowingCapturePermissionSheet,
              !isShowingCameraCapture,
              !isShowingKlipyGIFPicker,
              !isShowingDraftLibrary,
              previewingMediaAttachment == nil else {
            return
        }
        guard !viewModel.isPublishing else { return }

        let savedDraft = composeDraftStore.saveDraft(
            snapshot: currentDraftSnapshot,
            ownerPubkey: currentAccountPubkey,
            existingDraftID: activeSavedDraftID
        )

        if let savedDraft {
            activeSavedDraftID = savedDraft.id
            toastCenter.show("Draft saved locally", style: .info)
        } else {
            activeSavedDraftID = nil
        }
    }

    private var currentDraftSnapshot: SavedComposeDraftSnapshot {
        SavedComposeDraftSnapshot(
            text: viewModel.text,
            additionalTags: currentAdditionalTags,
            uploadedAttachments: mediaAttachments,
            selectedMentions: selectedMentions,
            pollDraft: pollDraft,
            replyTargetEvent: currentReplyTargetEvent,
            replyTargetDisplayNameHint: replyTargetDisplayName,
            replyTargetHandleHint: replyTargetHandle,
            replyTargetAvatarURLHint: replyTargetAvatarURL,
            quotedEvent: currentQuotedEvent,
            quotedDisplayNameHint: quotedDisplayName,
            quotedHandleHint: quotedHandle,
            quotedAvatarURLHint: quotedAvatarURL
        )
    }

    private func loadSavedDraft(_ draft: SavedComposeDraft) {
        if activeSavedDraftID != draft.id {
            _ = composeDraftStore.saveDraft(
                snapshot: currentDraftSnapshot,
                ownerPubkey: currentAccountPubkey,
                existingDraftID: activeSavedDraftID
            )
        }

        applySavedDraftSnapshot(draft.snapshot)
        activeSavedDraftID = draft.id
        toastCenter.show("Draft loaded", style: .info)
    }

    private func insertSavedDraftText(_ draft: SavedComposeDraft) {
        guard draft.canInsertText else { return }

        let existingText = viewModel.text
        let separator: String
        if existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            separator = ""
        } else if existingText.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }

        let offset = (existingText as NSString).length + (separator as NSString).length
        viewModel.text = existingText + separator + draft.snapshot.text
        selectedMentions.append(contentsOf: draft.snapshot.selectedMentions.map { $0.shifted(by: offset) })
        selectedMentions.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.handle < rhs.handle
            }
            return lhs.range.location < rhs.range.location
        }
        editorSelectedRange = NSRange(location: (viewModel.text as NSString).length, length: 0)
        isEditorFocused = true
        toastCenter.show("Draft text inserted", style: .info)
    }

    private func deleteSavedDraft(_ draft: SavedComposeDraft) {
        composeDraftStore.deleteDraft(draft)
        if activeSavedDraftID == draft.id {
            activeSavedDraftID = nil
        }
    }

    private func clearComposerForFreshDraft() {
        _ = composeDraftStore.saveDraft(
            snapshot: currentDraftSnapshot,
            ownerPubkey: currentAccountPubkey,
            existingDraftID: activeSavedDraftID
        )

        applySavedDraftSnapshot(
            SavedComposeDraftSnapshot(
                text: "",
                additionalTags: [],
                uploadedAttachments: [],
                selectedMentions: [],
                pollDraft: nil,
                replyTargetEvent: nil,
                replyTargetDisplayNameHint: nil,
                replyTargetHandleHint: nil,
                replyTargetAvatarURLHint: nil,
                quotedEvent: nil,
                quotedDisplayNameHint: nil,
                quotedHandleHint: nil,
                quotedAvatarURLHint: nil
            )
        )
        activeSavedDraftID = nil
        toastCenter.show("Started a fresh draft", style: .info)
    }

    private func applySavedDraftSnapshot(_ snapshot: SavedComposeDraftSnapshot) {
        applyComposerContext(
            additionalTags: snapshot.additionalTags,
            replyTargetEvent: snapshot.replyTargetEvent,
            replyTargetDisplayNameHint: snapshot.replyTargetDisplayNameHint,
            replyTargetHandleHint: snapshot.replyTargetHandleHint,
            replyTargetAvatarURLHint: snapshot.replyTargetAvatarURLHint,
            quotedEvent: snapshot.quotedEvent,
            quotedDisplayNameHint: snapshot.quotedDisplayNameHint,
            quotedHandleHint: snapshot.quotedHandleHint,
            quotedAvatarURLHint: snapshot.quotedAvatarURLHint
        )
        viewModel.text = snapshot.text
        mediaAttachments = snapshot.uploadedAttachments
        pollDraft = snapshot.pollDraft
        selectedMentions = snapshot.selectedMentions
        activeMentionQuery = nil
        mentionSuggestions = []
        isLoadingMentionSuggestions = false
        viewModel.feedbackMessage = nil
        viewModel.feedbackIsError = false
        editorSelectedRange = NSRange(location: (viewModel.text as NSString).length, length: 0)
        isEditorFocused = true
    }

    private func normalizedDraftHint(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedDraftHandle(_ value: String?) -> String? {
        guard let trimmed = normalizedDraftHint(value) else { return nil }
        return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
    }

    private var configuredPublishSourceCount: Int {
        let normalized = Set(writeRelayURLs.map { $0.absoluteString.lowercased() })
        return normalized.count
    }

    private func applyInitialSharedAttachmentsIfNeeded() async {
        guard !hasAppliedInitialSharedAttachments else { return }
        hasAppliedInitialSharedAttachments = true

        guard !initialSharedAttachments.isEmpty else { return }

        viewModel.feedbackMessage = nil
        viewModel.feedbackIsError = false

        guard let normalizedNsec = currentNsec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedNsec.isEmpty else {
            viewModel.feedbackMessage = "Sign in with a private key to upload media."
            viewModel.feedbackIsError = true
            return
        }

        isUploadingMedia = true
        defer {
            isUploadingMedia = false
        }

        var failedUploads = 0
        var firstError: Error?

        for sharedAttachment in initialSharedAttachments {
            do {
                let attachment = try await uploadSharedComposeAttachment(
                    sharedAttachment,
                    normalizedNsec: normalizedNsec
                )

                if !mediaAttachments.contains(where: { $0.url == attachment.url }) {
                    mediaAttachments.append(attachment)
                    removeUploadedMediaURLIfPresent(attachment.url)
                }

                FlowSharedComposeDraftStore.cleanupAttachmentFiles([sharedAttachment])
            } catch {
                failedUploads += 1
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if failedUploads > 0 {
            let successfulUploads = initialSharedAttachments.count - failedUploads
            let detailedMessage = (firstError as? LocalizedError)?.errorDescription ?? firstError?.localizedDescription
            if successfulUploads > 0 {
                if let detailedMessage, !detailedMessage.isEmpty {
                    viewModel.feedbackMessage = "Added \(successfulUploads) attachment\(successfulUploads == 1 ? "" : "s"), but \(failedUploads) failed: \(detailedMessage)"
                } else {
                    viewModel.feedbackMessage = "Added \(successfulUploads) attachment\(successfulUploads == 1 ? "" : "s"), but \(failedUploads) failed."
                }
            } else {
                viewModel.feedbackMessage = detailedMessage ?? "Couldn't upload media right now."
            }
            viewModel.feedbackIsError = true
        }

        if failedUploads < initialSharedAttachments.count {
            isEditorFocused = true
        }
    }

    private func cleanupInitialSharedAttachments() {
        guard !initialSharedAttachments.isEmpty else { return }
        FlowSharedComposeDraftStore.cleanupAttachmentFiles(initialSharedAttachments)
    }

    private func prepareSharedComposeAttachmentForUpload(
        _ sharedAttachment: SharedComposeAttachment
    ) async throws -> PreparedUploadMedia {
        guard let fileURL = sharedAttachment.resolvedFileURL else {
            throw SharedComposeImportError.missingFileURL
        }

        let mimeType = sharedAttachment.mimeType
        let normalizedMimeType = mimeType.lowercased()
        let normalizedFileExtension = sharedAttachment.fileExtension.lowercased()

        if normalizedMimeType.hasPrefix("video/") ||
            ["mp4", "mov", "m4v", "webm", "mkv"].contains(normalizedFileExtension) {
            return try await MediaUploadPreparation.prepareUploadMedia(
                fileURL: fileURL,
                mimeType: mimeType,
                fileExtension: normalizedFileExtension
            )
        }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            throw SharedComposeImportError.unreadableFile
        }

        return try MediaUploadPreparation.prepareUploadMedia(
            data: data,
            mimeType: mimeType,
            fileExtension: normalizedFileExtension
        )
    }

    nonisolated private static func renderEventForQuotePreview(_ event: NostrEvent) -> NostrEvent {
        guard event.kind == 6 || event.kind == 16 else { return event }
        guard let embedded = decodeEmbeddedEvent(from: event.content) else { return event }
        guard embedded.kind != 6 && embedded.kind != 16 else { return event }
        return embedded
    }

    nonisolated private static func makeContextPreviewSnapshot(
        for event: NostrEvent,
        maximumLength: Int? = nil
    ) async -> ComposeContextPreviewSnapshot {
        await Task.detached(priority: .userInitiated) {
            let renderedEvent = renderEventForQuotePreview(event)
            let tokens = NoteContentParser.tokenize(event: renderedEvent)
            return ComposeContextPreviewSnapshot(
                authorPubkey: renderedEvent.pubkey,
                createdAtDate: renderedEvent.createdAtDate,
                previewText: previewText(
                    from: tokens,
                    fallbackContent: renderedEvent.content,
                    maximumLength: maximumLength
                ),
                imageURLs: previewImageURLs(from: tokens),
                hasVideo: previewHasVideo(in: tokens),
                hasAudio: previewHasAudio(in: tokens),
                hasPoll: renderedEvent.pollMetadata != nil
            )
        }.value
    }

    nonisolated private static func previewText(
        from tokens: [NoteContentToken],
        fallbackContent: String,
        maximumLength: Int? = nil
    ) -> String {
        var fragments: [String] = []
        for token in tokens {
            switch token.type {
            case .text:
                let trimmed = token.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    fragments.append(trimmed)
                }
            default:
                continue
            }
        }

        let combined = fragments.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previewSource = combined.isEmpty
            ? fallbackContent.trimmingCharacters(in: .whitespacesAndNewlines)
            : combined
        guard !previewSource.isEmpty else {
            return "Note"
        }
        guard let maximumLength else {
            return previewSource
        }
        return String(previewSource.prefix(maximumLength))
    }

    nonisolated private static func previewImageURLs(
        from tokens: [NoteContentToken],
        limit: Int = 2
    ) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        for token in tokens where token.type == .image {
            guard let url = URL(string: token.value), url.scheme != nil else { continue }
            let normalized = url.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            urls.append(url)
            if urls.count == limit {
                break
            }
        }
        return urls
    }

    nonisolated private static func previewHasVideo(in tokens: [NoteContentToken]) -> Bool {
        tokens.contains(where: { $0.type == .video || $0.type == .youtubeVideo })
    }

    nonisolated private static func previewHasAudio(in tokens: [NoteContentToken]) -> Bool {
        tokens.contains(where: { $0.type == .audio })
    }

    nonisolated private static func decodeEmbeddedEvent(from content: String) -> NostrEvent? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let id = object["id"] as? String,
              let pubkey = object["pubkey"] as? String,
              let createdAt = object["created_at"] as? Int,
              let kind = object["kind"] as? Int,
              let content = object["content"] as? String,
              let sig = object["sig"] as? String else {
            return nil
        }

        let rawTags = object["tags"] as? [[Any]] ?? []
        let tags = rawTags.map { tag in
            tag.map { element in
                if let string = element as? String {
                    return string
                }
                return String(describing: element)
            }
        }

        return NostrEvent(
            id: id,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: sig
        )
    }
}
