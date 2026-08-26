import AVFoundation
import AVKit
import ImageIO
import NostrSDK
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ComposeImageEditSession: Identifiable {
    let attachment: ComposeMediaAttachment
    let sourceImage: UIImage

    var id: UUID { attachment.id }
}

private enum ComposeImageEditError: LocalizedError {
    case attachmentUnavailable

    var errorDescription: String? {
        "That image is no longer attached."
    }
}

struct ComposeNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var composeDraftStore: AppComposeDraftStore
    @State private var isEditorFocused = false
    @ObservedObject var viewModel: ComposeNoteViewModel
    @StateObject private var speechTranscriber = ComposeSpeechTranscriber()
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var mediaAttachments: [ComposeMediaAttachment] = []
    @State private var capturePermissions = CameraCapturePermissionSnapshot.current()
    @State private var isShowingCapturePermissionSheet = false
    @State private var isShowingCameraCapture = false
    @State private var isRequestingCaptureAccess = false
    @State private var isUploadingMedia = false
    @State private var preparingEditAttachmentID: UUID?
    @State private var imageEditSession: ComposeImageEditSession?
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
    @State private var altTextMediaAttachment: ComposeMediaAttachment?
    @State private var isShowingKlipyGIFPicker = false
    @State private var isShowingDraftLibrary = false
    @State private var editorSelectionRequest = ComposeTextSelectionRequest(
        range: NSRange(location: 0, length: 0)
    )
    @State private var editorTextUpdateRequest = ComposeTextUpdateRequest(text: "")
    @State private var selectedMentions: [ComposeSelectedMention] = []
    @State private var activeMentionQuery: ComposeMentionQuery?
    @State private var mentionSuggestions: [ComposeMentionSuggestion] = []
    @State private var isLoadingMentionSuggestions = false
    @State private var mentionLookupTask: Task<Void, Never>?
    @State private var mentionSuggestionAnchorY: CGFloat = 44
    @State private var activeSavedDraftID: UUID?
    @State private var hasPublishedSuccessfully = false

    private let mediaAttachmentController = ComposeMediaAttachmentController()
    private let mentionSuggestionController = ComposeMentionSuggestionController()
    private let draftController = ComposeDraftController()
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
    var onRequestAccountAccess: (() -> Void)? = nil
    var onOptimisticPublished: ((FeedItem) -> Void)? = nil
    var onPublished: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            standardComposerLayout
                .background(composeSheetBackground)
                .navigationTitle(composerNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            ComposeCancelToolbarButton {
                                dismiss()
                            }
                        }

                        ToolbarSpacer(.fixed, placement: .topBarLeading)

                        ToolbarItem(placement: .topBarLeading) {
                            draftLibraryToolbarButton
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            publishToolbarButton
                        }
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            HStack(spacing: ComposeToolbarLayout.leadingItemSpacing) {
                                ComposeCancelToolbarButton {
                                    dismiss()
                                }
                                draftLibraryToolbarButton
                            }
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            publishToolbarButton
                        }
                    }
                }
                .toolbarBackground(composeSheetBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .presentationBackground(composeSheetBackground)
        .task {
            applyInitialContextIfNeeded()
            applyInitialDraftIfNeeded()
            applyInitialAttachmentsIfNeeded()
            applyInitialSelectedMentionsIfNeeded()
            applyInitialPollDraftIfNeeded()
            requestEditorSelection(
                NSRange(location: (viewModel.text as NSString).length, length: 0)
            )
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
        .fullScreenCover(item: $imageEditSession) { session in
            ImageRemixEditorView(sourceImage: session.sourceImage) { editedImage in
                try await replaceMediaAttachment(session.attachment, with: editedImage)
            }
        }
        .sheet(item: $previewingMediaAttachment) { attachment in
            ComposeMediaAttachmentPreviewSheet(attachment: attachment)
        }
        .sheet(item: $altTextMediaAttachment) { attachment in
            ComposeImageAltTextSheet(attachment: attachment) { altText in
                updateAltText(altText, for: attachment)
            }
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
        guard currentNsec != nil else { return "Add access" }
        return mode.primaryActionTitle(hasSigningAccess: true)
    }

    private var availableSavedDrafts: [SavedComposeDraft] {
        composeDraftStore.drafts(for: currentAccountPubkey)
    }

    private var availableSavedDraftCount: Int {
        availableSavedDrafts.count
    }

    private var composeSheetBackground: Color {
        ComposeSurfaceStyle.background(for: colorScheme)
    }

    private var draftLibraryToolbarButton: some View {
        ComposeDraftLibraryToolbarButton(savedDraftCount: availableSavedDraftCount) {
            isShowingDraftLibrary = true
        }
    }

    private var standardComposerLayout: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if currentNsec == nil {
                            accountAccessCard
                        }

                        if isReplyComposer {
                            replyTargetPreviewCard
                        } else if isQuoteComposer {
                            quotePreviewCard
                        }
                        composeCard(
                            minimumEditorHeight: ComposeEditorLayout.expandedHeight(
                                in: proxy.size.height
                            )
                        )
                        statusSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, ComposeEditorLayout.topContentPadding)
                    .padding(.bottom, ComposeEditorLayout.bottomAccessoryGap)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            composeBottomAccessoryBar
        }
    }

    private var composeBottomAccessoryBar: some View {
        VStack(spacing: 0) {
            if !mediaAttachments.isEmpty {
                ComposeMediaAttachmentStrip(
                    attachments: mediaAttachments,
                    colorScheme: colorScheme,
                    preparingEditAttachmentID: preparingEditAttachmentID,
                    onPreview: { attachment in
                        previewingMediaAttachment = attachment
                    },
                    onEdit: { attachment in
                        Task {
                            await openMediaAttachmentEditor(for: attachment)
                        }
                    },
                    onAltText: { attachment in
                        altTextMediaAttachment = attachment
                    },
                    onRemove: removeMediaAttachment(_:)
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            composeAttachmentToolbar
        }
        .background(composeSheetBackground)
    }

    private var composeAttachmentToolbar: some View {
        ComposeAttachmentToolbarBar(
            viewModel: viewModel,
            speechTranscriber: speechTranscriber,
            selectedMediaItems: $selectedMediaItems,
            pollDraft: $pollDraft,
            isUploadingMedia: isUploadingMedia,
            isRequestingCaptureAccess: isRequestingCaptureAccess,
            canAttachPoll: canAttachPoll,
            hasSigningAccess: currentNsec != nil,
            writeRelayURLs: writeRelayURLs,
            onCameraTap: handleCameraButtonTap,
            onGIFTap: {
                isShowingKlipyGIFPicker = true
            },
            onSpeechToggle: {
                Task {
                    await handleSpeechToggle()
                }
            },
            onTogglePoll: togglePollDraft
        )
    }

    private var publishToolbarButton: some View {
        ComposePublishToolbarButton(
            title: publishButtonTitle,
            isPublishing: viewModel.isPublishing,
            isEnabled: currentNsec == nil || canPublish
        ) {
            if currentNsec == nil {
                onRequestAccountAccess?()
                return
            }
            Task {
                await publish()
            }
        }
    }

    private var accountAccessCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(appSettings.primaryColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text("Add account access to post")
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)

                Text("Your draft is safe. Continue when you’re ready to publish.")
                    .font(appSettings.appFont(.subheadline))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }

            Spacer(minLength: 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onRequestAccountAccess?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onRequestAccountAccess?()
        }
        .flowHierarchyEntrance(index: 0)
    }

    private func composeCard(minimumEditorHeight: CGFloat) -> some View {
        ComposeComposerCardView(
            viewModel: viewModel,
            mode: mode,
            minimumEditorHeight: minimumEditorHeight,
            pollDraft: $pollDraft,
            isEditorFocused: $isEditorFocused,
            editorTextUpdateRequest: editorTextUpdateRequest,
            editorSelectionRequest: editorSelectionRequest,
            selectedMentions: $selectedMentions,
            mentionSuggestionAnchorY: $mentionSuggestionAnchorY,
            activeMentionQuery: activeMentionQuery,
            mentionSuggestions: mentionSuggestions,
            isLoadingMentionSuggestions: isLoadingMentionSuggestions,
            canAttachPoll: canAttachPoll,
            onMentionQueryChange: handleMentionQueryChange(_:),
            onMentionSuggestionSelect: insertMentionSuggestion(_:),
            onTogglePoll: togglePollDraft
        )
    }

    private var statusSection: some View {
        ComposeStatusSectionView(
            isPublishing: viewModel.isPublishing,
            publishSourceCount: configuredPublishSourceCount,
            feedbackMessage: viewModel.feedbackMessage,
            feedbackIsError: viewModel.feedbackIsError,
            isTranscribingSpeech: speechTranscriber.isTranscribing,
            missingNsec: false,
            missingPublishSources: writeRelayURLs.isEmpty,
            pollValidationMessage: pollValidationMessage
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
        let currentAccountPubkey = currentAccountPubkey
        let selectedMentions = selectedMentions
        let suggestions = await mentionSuggestionController.suggestions(
            for: query,
            currentAccountPubkey: currentAccountPubkey,
            selectedMentions: selectedMentions,
            profileService: profileService
        )

        guard !Task.isCancelled else { return }

        await MainActor.run {
            guard activeMentionQuery == query else { return }
            mentionSuggestions = suggestions
            isLoadingMentionSuggestions = false
        }
    }

    private func insertMentionSuggestion(_ suggestion: ComposeMentionSuggestion) {
        guard let query = activeMentionQuery else { return }

        let insertion = ComposeMentionSupport.insertSuggestion(
            suggestion,
            into: viewModel.text,
            replacing: query,
            existingMentions: selectedMentions
        )
        requestEditorTextUpdate(insertion.text)
        selectedMentions = insertion.mentions
        requestEditorSelection(insertion.selectedRange)
        mentionSuggestions = []
        activeMentionQuery = nil
        isLoadingMentionSuggestions = false
        isEditorFocused = true
    }

    private var canAttachPoll: Bool {
        mode == .newNote
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
        guard mediaAttachmentController.isCameraAvailable else {
            viewModel.feedbackMessage = "This device doesn't have an available camera right now."
            viewModel.feedbackIsError = true
            return
        }

        let permissions = mediaAttachmentController.currentCapturePermissions()
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

        var permissions = mediaAttachmentController.currentCapturePermissions()

        if permissions.cameraRequiresPrompt {
            _ = await mediaAttachmentController.requestCaptureAccess(for: .video)
            permissions = mediaAttachmentController.currentCapturePermissions()
        }

        guard !permissions.isCameraBlocked else {
            capturePermissions = permissions
            return
        }

        if permissions.microphoneRequiresPrompt {
            _ = await mediaAttachmentController.requestCaptureAccess(for: .audio)
            permissions = mediaAttachmentController.currentCapturePermissions()
        }

        capturePermissions = permissions
        isShowingCapturePermissionSheet = false
        presentCameraCapture(using: permissions)
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
            viewModel.feedbackMessage = "Sign in to upload media."
            viewModel.feedbackIsError = true
            return
        }

        isUploadingMedia = true
        defer {
            isUploadingMedia = false
        }

        do {
            let attachment = try await mediaAttachmentController.uploadAttachment(
                from: capturedMedia,
                normalizedNsec: normalizedNsec
            )
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
            viewModel.feedbackMessage = "Sign in to upload media."
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
                let attachment = try await mediaAttachmentController.uploadAttachment(
                    from: item,
                    normalizedNsec: normalizedNsec
                )

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

    private func handleKlipyGIFSelection(_ selection: KlipyGIFAttachmentCandidate) async {
        guard !isUploadingMedia else { return }
        viewModel.feedbackMessage = nil
        viewModel.feedbackIsError = false

        guard let normalizedNsec = currentNsec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedNsec.isEmpty else {
            viewModel.feedbackMessage = "Sign in to upload media."
            viewModel.feedbackIsError = true
            return
        }

        isUploadingMedia = true
        defer {
            isUploadingMedia = false
        }

        do {
            let attachment = try await mediaAttachmentController.uploadAttachment(
                from: selection,
                normalizedNsec: normalizedNsec
            )

            if !mediaAttachments.contains(where: { $0.url == attachment.url }) {
                mediaAttachments.append(attachment)
                removeUploadedMediaURLIfPresent(attachment.url)
            }

            isEditorFocused = true
            toastCenter.show("GIF added")

            Task {
                await mediaAttachmentController.registerKlipyShare(for: selection)
            }
        } catch {
            viewModel.feedbackMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't add that GIF right now."
            viewModel.feedbackIsError = true
        }
    }

    private func removeMediaAttachment(_ attachment: ComposeMediaAttachment) {
        mediaAttachments.removeAll { $0.id == attachment.id }
    }

    private func updateAltText(_ altText: String, for attachment: ComposeMediaAttachment) {
        guard let index = mediaAttachments.firstIndex(where: { $0.id == attachment.id }) else {
            toastCenter.show("That image is no longer attached.", style: .error, duration: 2.8)
            return
        }
        mediaAttachments[index] = mediaAttachments[index].settingAltText(altText)
        let wasCleared = altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        toastCenter.show(wasCleared ? "Alt text cleared" : "Alt text saved")
    }

    @MainActor
    private func openMediaAttachmentEditor(for attachment: ComposeMediaAttachment) async {
        guard attachment.isImage,
              !attachment.isGIF,
              preparingEditAttachmentID == nil else {
            return
        }

        preparingEditAttachmentID = attachment.id
        defer {
            preparingEditAttachmentID = nil
        }

        guard let sourceImage = await FlowImageCache.shared.image(for: attachment.url) else {
            toastCenter.show("Couldn't load that image for editing.", style: .error, duration: 2.8)
            return
        }
        guard mediaAttachments.contains(where: { $0.id == attachment.id }) else { return }

        imageEditSession = ComposeImageEditSession(
            attachment: attachment,
            sourceImage: sourceImage
        )
    }

    @MainActor
    private func replaceMediaAttachment(
        _ attachment: ComposeMediaAttachment,
        with editedImage: UIImage
    ) async throws {
        guard let attachmentIndex = mediaAttachments.firstIndex(where: { $0.id == attachment.id }) else {
            throw ComposeImageEditError.attachmentUnavailable
        }
        guard let normalizedNsec = currentNsec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedNsec.isEmpty else {
            throw MediaUploadError.invalidCredentials
        }

        isUploadingMedia = true
        defer {
            isUploadingMedia = false
        }

        let replacement = try await mediaAttachmentController.uploadAttachment(
            fromEditedImage: editedImage,
            normalizedNsec: normalizedNsec
        )
        guard mediaAttachments.indices.contains(attachmentIndex),
              mediaAttachments[attachmentIndex].id == attachment.id else {
            throw ComposeImageEditError.attachmentUnavailable
        }

        mediaAttachments[attachmentIndex] = replacement
        removeUploadedMediaURLIfPresent(attachment.url)
        toastCenter.show("Image updated")
    }

    private func removeUploadedMediaURLIfPresent(_ url: URL) {
        let updatedText = mediaAttachmentController.textRemovingUploadedMediaURL(url, from: viewModel.text)
        guard updatedText != viewModel.text else { return }
        requestEditorTextUpdate(updatedText)
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
            requestEditorTextUpdate(normalized)
        } else {
            let needsSeparator = !(viewModel.text.hasSuffix(" ") || viewModel.text.hasSuffix("\n"))
            requestEditorTextUpdate(
                viewModel.text + (needsSeparator ? " \(normalized)" : normalized)
            )
        }
        isEditorFocused = true
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
                viewModel.feedbackMessage = "This account needs access to publish notes."
            } else if writeRelayURLs.isEmpty {
                viewModel.feedbackMessage = "No connected sources are configured."
            } else if let pollValidationMessage {
                viewModel.feedbackMessage = pollValidationMessage
            } else {
                viewModel.feedbackMessage = currentNsec == nil
                    ? "This account needs access to publish notes."
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
        requestEditorSelection(NSRange(location: 0, length: 0))
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

        return UserFacingCopy.sanitizingTechnicalTerms(message)
    }

    private func applyInitialDraftIfNeeded() {
        guard !hasAppliedInitialDraft else { return }
        hasAppliedInitialDraft = true

        guard viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requestEditorTextUpdate(initialText)
        requestEditorSelection(
            NSRange(location: (initialText as NSString).length, length: 0)
        )
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
        currentReplyTargetDisplayNameHint = draftController.normalizedHint(replyTargetDisplayNameHint)
        currentReplyTargetHandleHint = draftController.normalizedHandle(replyTargetHandleHint)
        currentReplyTargetAvatarURLHint = replyTargetAvatarURLHint
        currentQuotedEvent = quotedEvent
        currentQuotedDisplayNameHint = draftController.normalizedHint(quotedDisplayNameHint)
        currentQuotedHandleHint = draftController.normalizedHandle(quotedHandleHint)
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

        let savedDraft = draftController.saveDraftIfNeeded(
            store: composeDraftStore,
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
        draftController.makeSnapshot(
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
            _ = draftController.saveDraftIfNeeded(
                store: composeDraftStore,
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
        guard let insertion = draftController.insertionResult(
            for: draft,
            currentText: viewModel.text,
            selectedMentions: selectedMentions
        ) else { return }

        requestEditorTextUpdate(insertion.text)
        selectedMentions = insertion.selectedMentions
        requestEditorSelection(insertion.selectedRange)
        isEditorFocused = true
        toastCenter.show("Draft text inserted", style: .info)
    }

    private func deleteSavedDraft(_ draft: SavedComposeDraft) {
        activeSavedDraftID = draftController.deleteDraft(
            draft,
            store: composeDraftStore,
            activeDraftID: activeSavedDraftID
        )
    }

    private func clearComposerForFreshDraft() {
        _ = draftController.saveDraftIfNeeded(
            store: composeDraftStore,
            snapshot: currentDraftSnapshot,
            ownerPubkey: currentAccountPubkey,
            existingDraftID: activeSavedDraftID
        )

        applySavedDraftSnapshot(draftController.freshSnapshot())
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
        requestEditorTextUpdate(snapshot.text)
        mediaAttachments = snapshot.uploadedAttachments
        pollDraft = snapshot.pollDraft
        selectedMentions = snapshot.selectedMentions
        activeMentionQuery = nil
        mentionSuggestions = []
        isLoadingMentionSuggestions = false
        viewModel.feedbackMessage = nil
        viewModel.feedbackIsError = false
        requestEditorSelection(
            NSRange(location: (viewModel.text as NSString).length, length: 0)
        )
        isEditorFocused = true
    }

    private func requestEditorSelection(_ range: NSRange) {
        editorSelectionRequest = ComposeTextSelectionRequest(range: range)
    }

    private func requestEditorTextUpdate(_ text: String) {
        viewModel.text = text
        editorTextUpdateRequest = ComposeTextUpdateRequest(text: text)
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
            viewModel.feedbackMessage = "Sign in to upload media."
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
                let attachment = try await mediaAttachmentController.uploadAttachment(
                    from: sharedAttachment,
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
