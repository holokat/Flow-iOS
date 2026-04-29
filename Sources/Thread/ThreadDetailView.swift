import SwiftUI
import UIKit

enum ThreadDetailViewLayout {
    static func navigationTitle(hasArticleHero: Bool) -> String {
        hasArticleHero ? "" : "Note"
    }

    static func navigationBarVisibility(hasArticleHero: Bool) -> Visibility {
        hasArticleHero ? .hidden : .visible
    }

    static func topControlTopPadding(
        safeAreaInset: CGFloat,
        minimumPadding: CGFloat = 4
    ) -> CGFloat {
        minimumPadding + max(0, safeAreaInset)
    }
}

struct ThreadDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var relaySettings: RelaySettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @StateObject var viewModel: ThreadDetailViewModel
    @ObservedObject private var reactionStats = NoteReactionStatsService.shared
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var muteStore = MuteStore.shared
    @ObservedObject private var mutedThreadStore = MutedThreadStore.shared

    @State private var selectedThreadItem: FeedItem?
    @State private var activeReplyTarget: FeedItem?
    @State private var selectedHashtagRoute: HashtagRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var selectedRelayRoute: RelayRoute?
    @State private var selectedContentTab: ThreadDetailContentTab = .replies
    @State private var hasAppliedInitialReplyFocus = false
    @State private var hasAppliedInitialReplyScroll = false
    @State private var pendingReplyScrollTargetID: String?
    @State private var isShowingReshareSheet = false
    @State private var quoteDraft: ReshareQuoteDraft?
    @State private var isPublishingRepost = false
    @State private var isShowingRootNoteOptionsSheet = false
    @State private var isShowingRootReportSheet = false
    @State private var isShowingRootTranslation = false

    private let reactionPublishService: NoteReactionPublishService
    private let reshareService: ResharePublishService
    private let reportPublishService: NoteReportPublishService
    private let initialReplyScrollTargetID: String?
    private let initiallyFocusReplyComposer: Bool

    init(
        initialItem: FeedItem,
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        initialReplyScrollTargetID: String? = nil,
        initiallyFocusReplyComposer: Bool = false,
        service: NostrFeedService = NostrFeedService(),
        reactionPublishService: NoteReactionPublishService = NoteReactionPublishService(),
        reshareService: ResharePublishService = ResharePublishService(),
        reportPublishService: NoteReportPublishService = NoteReportPublishService()
    ) {
        _viewModel = StateObject(
            wrappedValue: ThreadDetailViewModel(
                rootItem: initialItem,
                relayURL: relayURL,
                readRelayURLs: readRelayURLs,
                service: service
            )
        )
        self.reactionPublishService = reactionPublishService
        self.reshareService = reshareService
        self.reportPublishService = reportPublishService
        self.initialReplyScrollTargetID = initialReplyScrollTargetID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.initiallyFocusReplyComposer = initiallyFocusReplyComposer
    }

    var body: some View {
        let _ = appSettings.spamReplyFilterSignature

        Group {
            if let articleMetadata {
                articleDetailBody(articleMetadata: articleMetadata)
            } else {
                noteDetailBody
            }
        }
        .background(appSettings.themePalette.background)
        .navigationTitle(
            ThreadDetailViewLayout.navigationTitle(hasArticleHero: articleMetadata != nil)
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(
            ThreadDetailViewLayout.navigationBarVisibility(
                hasArticleHero: articleMetadata != nil
            ),
            for: .navigationBar
        )
        .onChange(of: auth.currentAccount?.pubkey) { _, _ in
            configureStores()
        }
        .onChange(of: auth.currentNsec) { _, _ in
            configureStores()
        }
        .onChange(of: relaySettings.readRelays) { _, _ in
            configureStores()
        }
        .onChange(of: relaySettings.writeRelays) { _, _ in
            configureStores()
        }
        .onChange(of: appSettings.slowConnectionMode) { _, _ in
            configureStores()
        }
        .onChange(of: appSettings.spamReplyFilterSignature) { _, _ in
            viewModel.spamPreferencesChanged()
        }
        .onChange(of: followStore.followedPubkeys) { _, _ in
            configureSpamFilterContext()
        }
        .navigationDestination(item: $selectedHashtagRoute) { route in
            HashtagFeedView(
                hashtag: route.normalizedHashtag,
                relayURL: effectiveRelayURL,
                readRelayURLs: effectiveReadRelayURLs,
                seedItems: route.seedItems
            )
        }
        .navigationDestination(item: $selectedThreadItem) { item in
            ThreadDetailView(
                initialItem: item,
                relayURL: effectiveRelayURL,
                readRelayURLs: effectiveReadRelayURLs
            )
        }
        .navigationDestination(item: $selectedProfileRoute) { route in
            ProfileView(
                pubkey: route.pubkey,
                relayURL: effectiveRelayURL,
                readRelayURLs: effectiveReadRelayURLs,
                writeRelayURLs: effectiveWriteRelayURLs
            )
        }
        .navigationDestination(item: $selectedRelayRoute) { route in
            RelayFeedView(relayURL: route.relayURL, title: route.displayName)
        }
        .sheet(isPresented: $isShowingReshareSheet) {
            ReshareActionSheetView(
                isWorking: isPublishingRepost,
                onRepost: {
                    Task {
                        await publishRootRepost()
                    }
                },
                onQuote: {
                    quoteDraft = reshareService.buildQuoteDraft(
                        for: viewModel.rootItem,
                        relayHintURL: effectiveReadRelayURLs.first
                    )
                    isShowingReshareSheet = false
                }
            )
        }
        .sheet(item: $quoteDraft) { draft in
            ComposeNoteSheet(
                currentAccountPubkey: auth.currentAccount?.pubkey,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                initialText: draft.initialText,
                initialAdditionalTags: draft.additionalTags,
                quotedEvent: draft.quotedEvent,
                quotedDisplayNameHint: draft.quotedDisplayNameHint,
                quotedHandleHint: draft.quotedHandleHint,
                quotedAvatarURLHint: draft.quotedAvatarURLHint,
                onOptimisticPublished: { item in
                    if item.displayEvent.referencesConversation(id: viewModel.rootItem.displayEventID) {
                        viewModel.appendLocalReply(item)
                    }
                },
                onPublished: {
                    Task {
                        await viewModel.refresh()
                    }
                }
            )
        }
        .sheet(item: $activeReplyTarget) { target in
            ComposeNoteSheet(
                currentAccountPubkey: auth.currentAccount?.pubkey,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                replyTargetEvent: target.displayEvent,
                replyTargetDisplayNameHint: target.displayName,
                replyTargetHandleHint: target.handle,
                replyTargetAvatarURLHint: target.avatarURL,
                onOptimisticPublished: { item in
                    viewModel.appendLocalReply(item)
                },
                onPublished: {
                    Task {
                        await viewModel.refresh()
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingRootNoteOptionsSheet) {
            NoteOptionsBottomSheetView(
                canCopyText: rootHasCopyableNoteText,
                onCopyText: {
                    UIPasteboard.general.string = rootCopyableNoteText
                    toastCenter.show("Copied text")
                },
                onCopyEventID: {
                    UIPasteboard.general.string = rootCopyableEventIdentifier
                    toastCenter.show("Copied event ID")
                },
                onCopyLink: {
                    UIPasteboard.general.string = rootNoteShareLink
                    toastCenter.show("Copied link")
                },
                showsTranslateAction: rootCanTranslateNote,
                onTranslate: rootCanTranslateNote ? {
                    presentRootTranslation()
                } : nil,
                onMute: {
                    handleRootMuteAuthor()
                },
                onMuteThread: {
                    handleRootMuteThread()
                },
                spamMarkTitle: rootSpamMarkActionTitle,
                spamMarkIcon: rootSpamMarkActionIcon,
                canToggleSpamMark: !isRootOwnedByCurrentAccount,
                onToggleSpamMark: {
                    handleRootToggleSpamMark()
                },
                onReport: {
                    presentRootReportFlow()
                }
            )
            .presentationDetents([.height(rootCanTranslateNote ? 655 : 600), .medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingRootReportSheet) {
            NoteReportSheetView(noteAuthorName: viewModel.rootItem.displayName) { type, details in
                try await submitRootReport(type: type, details: details)
            }
        }
        .noteTranslationPresentation(
            isPresented: $isShowingRootTranslation,
            text: rootNoteTranslationText
        )
        .safeAreaInset(edge: .bottom) {
            ThreadDetailReplyDockBar(
                primaryColor: appSettings.primaryColor,
                colorSchemeOverride: colorScheme,
                onTap: {
                    presentReplyComposer(for: viewModel.rootItem.canonicalDisplayItem)
                }
            )
        }
    }

    private var noteDetailBody: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ThreadDetailRootNoteCard(
                        item: viewModel.rootItem,
                        isHiddenByNSFW: hideNSFWEnabled && viewModel.rootItem.moderationEvents.contains(where: { $0.containsNSFWHashtag }),
                        reactionCount: rootReactionCount,
                        commentCount: rootReplyCount,
                        repostCount: rootRepostCount,
                        showReactions: appSettings.reactionsVisibleInFeeds,
                        isFollowingAuthor: followStore.isFollowing(viewModel.rootItem.displayAuthorPubkey),
                        rootFollowStatusIconName: rootFollowStatusIconName,
                        isLikedByCurrentUser: isRootLikedByCurrentUser,
                        isBonusReactionByCurrentUser: isRootBonusReactionByCurrentUser,
                        onFollowToggle: {
                            followStore.toggleFollow(viewModel.rootItem.displayAuthorPubkey)
                        },
                        onOpenProfile: openProfile,
                        onOpenHashtag: openHashtagFeed,
                        onOpenReferencedEvent: { referencedItem in
                            selectedThreadItem = referencedItem.threadNavigationItem
                        },
                        onOpenRelay: openRelayFeed,
                        onOptionsTap: {
                            isShowingRootNoteOptionsSheet = true
                        },
                        onReplyTap: {
                            presentReplyComposer(for: viewModel.rootItem.canonicalDisplayItem)
                        },
                        onReactionTap: { bonusCount in
                            Task {
                                await handleRootReactionTap(bonusCount: bonusCount)
                            }
                        },
                        onRepostTap: {
                            isShowingReshareSheet = true
                        },
                        shareLink: rootNoteShareLink
                    )

                    ThreadDetailSeparator(leadingPadding: 16)

                    ThreadDetailContentSection(
                        selectedContentTab: $selectedContentTab,
                        replies: threadReplies,
                        spamReplies: threadSpamReplies,
                        spamRepliesExpanded: viewModel.isSpamRepliesExpanded,
                        replyCountsByTarget: replyCountsByTarget,
                        noteActivityRows: noteActivityRows,
                        isLoadingReplies: viewModel.isLoading,
                        isLoadingReactions: viewModel.isLoadingNoteActivity,
                        repliesErrorMessage: viewModel.errorMessage,
                        reactionsErrorMessage: viewModel.noteActivityErrorMessage,
                        rootEventID: viewModel.rootItem.displayEventID,
                        showReactions: appSettings.reactionsVisibleInFeeds,
                        effectiveReadRelayURLs: effectiveReadRelayURLs,
                        currentUserPubkey: auth.currentAccount?.pubkey,
                        isFollowingAuthor: { followStore.isFollowing($0) },
                        onFollowToggle: { followStore.toggleFollow($0) },
                        onOpenHashtag: openHashtagFeed,
                        onOpenProfile: openProfile,
                        onOpenRelay: openRelayFeed,
                        onOpenThread: { item in
                            selectedThreadItem = item.threadNavigationItem
                        },
                        onReplyTap: { item in
                            presentReplyComposer(for: item)
                        },
                        onToggleSpamReplies: {
                            viewModel.toggleSpamRepliesExpanded()
                        },
                        onMarkNotSpam: { pubkey in
                            viewModel.markSpamReplyAuthorAsNotSpam(pubkey)
                            toastCenter.show("Moved replies back into the thread", style: .info)
                        }
                    )
                }
            }
            .refreshable {
                await viewModel.refresh(
                    includeNoteActivity: selectedContentTab == .reactions || viewModel.hasLoadedNoteActivity
                )
            }
            .task {
                await performInitialLoad(isArticle: false)
            }
            .onChange(of: pendingReplyScrollTargetID) { _, replyID in
                guard let replyID else { return }
                Task { @MainActor in
                    await scrollReplyIntoView(replyID: replyID, using: scrollProxy)
                    pendingReplyScrollTargetID = nil
                }
            }
            .onChange(of: selectedContentTab) { _, newValue in
                guard newValue == .reactions else { return }
                Task {
                    await viewModel.loadNoteActivityIfNeeded()
                }
            }
        }
    }

    private func articleDetailBody(articleMetadata: NostrLongFormArticleMetadata) -> some View {
        ThreadDetailArticleBody(
            item: viewModel.rootItem,
            articleMetadata: articleMetadata,
            isHiddenByNSFW: hideNSFWEnabled && viewModel.rootItem.moderationEvents.contains(where: { $0.containsNSFWHashtag }),
            isOwnedByCurrentUser: isRootOwnedByCurrentAccount,
            isFollowingAuthor: followStore.isFollowing(viewModel.rootItem.displayAuthorPubkey),
            showReactions: appSettings.reactionsVisibleInFeeds,
            errorMessage: viewModel.errorMessage,
            reactionCount: rootReactionCount,
            isLikedByCurrentUser: isRootLikedByCurrentUser,
            isBonusReactionByCurrentUser: isRootBonusReactionByCurrentUser,
            shareLink: rootNoteShareLink,
            onFollowToggle: {
                followStore.toggleFollow(viewModel.rootItem.displayAuthorPubkey)
            },
            onOpenProfile: openProfile,
            onOpenHashtag: openHashtagFeed,
            onReplyTap: {
                presentReplyComposer(for: viewModel.rootItem.canonicalDisplayItem)
            },
            onRepostTap: {
                isShowingReshareSheet = true
            },
            onReactionTap: { bonusCount in
                Task {
                    await handleRootReactionTap(bonusCount: bonusCount)
                }
            }
        )
        .refreshable {
            await viewModel.refresh(includeNoteActivity: viewModel.hasLoadedNoteActivity)
        }
        .task {
            await performInitialLoad(isArticle: true)
        }
    }

    private var rootNoteShareLink: String {
        if let externalURL = NoteContentParser.njumpURL(for: viewModel.rootItem.displayEventID) {
            return externalURL.absoluteString
        }
        return "https://nlink.to/\(viewModel.rootItem.displayEventID)"
    }

    private var rootCopyableEventIdentifier: String {
        NoteContentParser.neventIdentifier(
            for: viewModel.rootItem.displayEvent,
            relayHints: effectiveReadRelayURLs
        ) ?? viewModel.rootItem.displayEventID
    }

    private var rootReactionCount: Int {
        reactionStats.reactionCount(for: viewModel.rootItem.displayEventID)
    }

    private var rootReplyCount: Int {
        max(threadReplies.count, reactionStats.replyCount(for: viewModel.rootItem.displayEventID))
    }

    private var rootRepostCount: Int {
        reactionStats.repostCount(for: viewModel.rootItem.displayEventID)
    }

    private var articleMetadata: NostrLongFormArticleMetadata? {
        viewModel.rootItem.displayEvent.longFormArticleMetadata
    }

    private var isRootLikedByCurrentUser: Bool {
        reactionStats.isReactedByCurrentUser(
            for: viewModel.rootItem.displayEventID,
            currentPubkey: auth.currentAccount?.pubkey
        )
    }

    private var isRootBonusReactionByCurrentUser: Bool {
        reactionStats.currentUserReaction(
            for: viewModel.rootItem.displayEventID,
            currentPubkey: auth.currentAccount?.pubkey
        )?.bonusCount ?? 0 > 0
    }

    private var isRootOwnedByCurrentAccount: Bool {
        guard let currentPubkey = auth.currentAccount?.pubkey else {
            return false
        }
        return currentPubkey.lowercased() == viewModel.rootItem.displayAuthorPubkey.lowercased()
    }

    private var rootFollowStatusIconName: String? {
        guard !isRootOwnedByCurrentAccount else { return nil }
        return followStore.isFollowing(viewModel.rootItem.displayAuthorPubkey)
            ? "checkmark.circle.fill"
            : "plus.circle.fill"
    }

    private var rootNoteTranslationText: String {
        viewModel.rootItem.displayEvent.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rootCopyableNoteText: String {
        viewModel.rootItem.displayEvent.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rootHasCopyableNoteText: Bool {
        !rootCopyableNoteText.isEmpty
    }

    private var rootCanTranslateNote: Bool {
        guard !rootNoteTranslationText.isEmpty else { return false }
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            return true
        }
        #endif
        return false
    }

    private var isRootAuthorMarkedSpam: Bool {
        appSettings.isSpamFilterMarked(viewModel.rootItem.displayAuthorPubkey)
    }

    private var rootSpamMarkActionTitle: String {
        isRootAuthorMarkedSpam ? "Remove Spam Mark" : "Mark as Spam"
    }

    private var rootSpamMarkActionIcon: String {
        isRootAuthorMarkedSpam ? "checkmark.shield" : "exclamationmark.shield"
    }

    private func presentRootTranslation() {
        guard rootCanTranslateNote else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            isShowingRootTranslation = true
        }
    }

    private func handleRootMuteAuthor() {
        let wasMuted = muteStore.isMuted(viewModel.rootItem.displayAuthorPubkey)
        muteStore.toggleMute(viewModel.rootItem.displayAuthorPubkey)
        let isMuted = muteStore.isMuted(viewModel.rootItem.displayAuthorPubkey)

        if !wasMuted && isMuted {
            toastCenter.show("Muted \(viewModel.rootItem.displayName)")
        } else if wasMuted && !isMuted {
            toastCenter.show("Unmuted \(viewModel.rootItem.displayName)", style: .info)
        } else if let errorMessage = muteStore.lastPublishError,
                  !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toastCenter.show(errorMessage, style: .error, duration: 2.8)
        }
    }

    private func handleRootMuteThread() {
        let threadID = viewModel.rootItem.displayEvent.conversationID
        mutedThreadStore.configure(accountPubkey: auth.currentAccount?.pubkey)

        if mutedThreadStore.mute(threadID) {
            toastCenter.show("Muted thread")
        } else {
            toastCenter.show("Thread already muted", style: .info)
        }
    }

    private func handleRootToggleSpamMark() {
        guard !isRootOwnedByCurrentAccount else { return }
        if isRootAuthorMarkedSpam {
            appSettings.removeSpamFilterMarkedPubkey(viewModel.rootItem.displayAuthorPubkey)
            toastCenter.show("Removed spam mark", style: .info)
        } else {
            appSettings.addSpamFilterMarkedPubkey(viewModel.rootItem.displayAuthorPubkey)
            toastCenter.show("Marked \(viewModel.rootItem.displayName) as spam")
        }
    }

    private func presentRootReportFlow() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            isShowingRootReportSheet = true
        }
    }

    private func submitRootReport(type: NoteReportType, details: String) async throws {
        try await reportPublishService.publishReport(
            for: viewModel.rootItem.displayEvent,
            type: type,
            details: details,
            currentNsec: auth.currentNsec,
            writeRelayURLs: effectiveWriteRelayURLs
        )
        await MainActor.run {
            if type == .spam {
                appSettings.addSpamFilterMarkedPubkey(viewModel.rootItem.displayAuthorPubkey)
                toastCenter.show("Report sent and marked as spam")
            } else {
                toastCenter.show("Report sent")
            }
        }
    }

    @MainActor
    private func applyInitialReplyPresentationIfNeeded() async {
        guard initiallyFocusReplyComposer, !hasAppliedInitialReplyFocus else { return }
        hasAppliedInitialReplyFocus = true
        try? await Task.sleep(nanoseconds: 220_000_000)
        presentReplyComposer(for: viewModel.rootItem.canonicalDisplayItem)
    }

    @MainActor
    private func applyInitialReplyScrollIfNeeded() async {
        guard let initialReplyScrollTargetID, !initialReplyScrollTargetID.isEmpty else { return }
        guard !hasAppliedInitialReplyScroll else { return }
        hasAppliedInitialReplyScroll = true

        let scrollRetryDelays: [UInt64] = [
            80_000_000,
            180_000_000,
            320_000_000
        ]

        for delay in scrollRetryDelays {
            try? await Task.sleep(nanoseconds: delay)
            pendingReplyScrollTargetID = initialReplyScrollTargetID
        }
    }

    @MainActor
    private func scrollReplyIntoView(replyID: String, using scrollProxy: ScrollViewProxy) async {
        let targetID = replyAnchorID(for: replyID)
        let scrollRetryDelays: [UInt64] = [
            0,
            140_000_000,
            280_000_000
        ]

        for delay in scrollRetryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            withAnimation(.easeInOut(duration: 0.22)) {
                scrollProxy.scrollTo(targetID, anchor: .bottom)
            }
        }
    }

    @MainActor
    private func presentReplyComposer(for item: FeedItem) {
        activeReplyTarget = item
    }

    @MainActor
    private func handleRootReactionTap(bonusCount: Int = 0) async {
        let eventID = viewModel.rootItem.displayEventID
        guard reactionStats.beginPublishingReaction(for: eventID) else { return }
        let existingReaction = reactionStats.currentUserReaction(
            for: eventID,
            currentPubkey: auth.currentAccount?.pubkey
        )
        let optimisticToggle = reactionStats.applyOptimisticToggle(
            for: eventID,
            currentPubkey: auth.currentAccount?.pubkey,
            bonusCount: bonusCount
        )
        defer {
            reactionStats.endPublishingReaction(for: eventID)
        }

        do {
            let result = try await reactionPublishService.toggleReaction(
                for: viewModel.rootItem.displayEvent,
                existingReactionID: existingReaction?.id,
                bonusCount: bonusCount,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                relayHintURL: effectiveReadRelayURLs.first
            )

            switch result {
            case .liked(let reactionEvent):
                reactionStats.registerPublishedReaction(
                    reactionEvent,
                    targetEventID: eventID
                )
            case .unliked(let reactionID):
                reactionStats.registerDeletedReaction(
                    reactionID: reactionID,
                    targetEventID: eventID
                )
            }
        } catch {
            reactionStats.rollbackOptimisticToggle(for: eventID, snapshot: optimisticToggle)
            return
        }
    }

    private func openHashtagFeed(hashtag: String) {
        selectedHashtagRoute = HashtagRoute(
            hashtag: hashtag,
            seedItems: matchingHashtagSeedItems(
                hashtag: hashtag,
                from: [viewModel.rootItem] + threadReplies
            )
        )
    }

    private func replyAnchorID(for replyID: String) -> String {
        "thread-detail-reply-\(replyID.lowercased())"
    }

    private func openProfile(pubkey: String) {
        selectedProfileRoute = ProfileRoute(pubkey: pubkey)
    }

    private func openRelayFeed(relayURL: URL) {
        selectedRelayRoute = RelayRoute(relayURL: relayURL)
    }

    private var hideNSFWEnabled: Bool {
        appSettings.hideNSFWContent
    }

    private var threadReplies: [FeedItem] {
        filteredReplies
    }

    private var threadSpamReplies: [FeedItem] {
        filteredSpamReplies
    }

    private var replyCountsByTarget: [String: Int] {
        ReplyCountEstimator.counts(for: threadReplies + threadSpamReplies)
    }

    private var filteredReplies: [FeedItem] {
        viewModel.replies.filter { item in
            if muteStore.shouldHideAny(item.moderationEvents) {
                return false
            }
            if hideNSFWEnabled && item.moderationEvents.contains(where: { $0.containsNSFWHashtag }) {
                return false
            }
            return true
        }
    }

    private var filteredSpamReplies: [FeedItem] {
        viewModel.spamReplies.filter { item in
            if muteStore.shouldHideAny(item.moderationEvents) {
                return false
            }
            if hideNSFWEnabled && item.moderationEvents.contains(where: { $0.containsNSFWHashtag }) {
                return false
            }
            return true
        }
    }

    private var noteActivityRows: [ActivityRow] {
        viewModel.noteActivityRows.filter { !muteStore.isMuted($0.actorPubkey) }
    }

    private func configureStores() {
        relaySettings.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec
        )
        followStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
        muteStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
        configureSpamFilterContext()
    }

    private func configureSpamFilterContext() {
        viewModel.configureSpamFilter(
            currentUserPubkey: auth.currentAccount?.pubkey,
            followedPubkeys: followStore.followedPubkeys
        )
    }

    private func performInitialLoad(isArticle: Bool) async {
        configureStores()

        if appSettings.reactionsVisibleInFeeds {
            reactionStats.prefetch(events: [viewModel.rootItem.displayEvent], relayURLs: effectiveReadRelayURLs)
        }

        if !isArticle, initiallyFocusReplyComposer {
            Task { @MainActor in
                await applyInitialReplyPresentationIfNeeded()
            }
        }

        await viewModel.loadIfNeeded()

        if !isArticle, initialReplyScrollTargetID != nil {
            Task { @MainActor in
                await applyInitialReplyScrollIfNeeded()
            }
        }
    }

    @MainActor
    private func publishRootRepost() async {
        guard !isPublishingRepost else { return }
        isPublishingRepost = true
        defer { isPublishingRepost = false }

        do {
            _ = try await reshareService.publishRepost(
                of: viewModel.rootItem.displayEvent,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                relayHintURL: effectiveReadRelayURLs.first
            )
            isShowingReshareSheet = false
        } catch {
            let errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toastCenter.show(errorMessage, style: .error, duration: 2.8)
        }
    }
}
