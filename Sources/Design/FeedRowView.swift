import SwiftUI
import UIKit
#if canImport(Translation)
import Translation
#endif

struct ReplyContextPreviewPresentation: Equatable, Sendable {
    let parentItem: FeedItem
    let snippet: String?
    let hasImageBadge: Bool

    static func make(for item: FeedItem) -> ReplyContextPreviewPresentation? {
        guard item.displayEvent.isReplyNote,
              let parentItem = item.replyTargetFeedItem else {
            return nil
        }

        let imageURLs = NoteContentParser.imageURLs(in: parentItem.displayEvent)
        let hasImageBadge = !imageURLs.isEmpty
        let snippet = snippet(for: parentItem.displayEvent, imageURLs: imageURLs)

        guard snippet != nil || hasImageBadge else { return nil }
        return ReplyContextPreviewPresentation(
            parentItem: parentItem,
            snippet: snippet,
            hasImageBadge: hasImageBadge
        )
    }

    private static func snippet(for event: NostrEvent, imageURLs: [URL]) -> String? {
        var cleanedContent = event.content
        for imageURL in imageURLs {
            cleanedContent = cleanedContent.replacingOccurrences(of: imageURL.absoluteString, with: " ")
        }

        let normalized = cleanedContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }
        guard normalized.count > 72 else { return normalized }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: 72)
        return String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

struct ReplyContextPreviewRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var auth: AuthManager

    let presentation: ReplyContextPreviewPresentation
    let foregroundStyle: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: 6) {
            Image(systemName: "arrow.turn.up.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(foregroundStyle)

            Text("Replying to")
                .font(.caption)
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)

            AvatarView(
                url: presentation.parentItem.avatarURL,
                fallback: presentation.parentItem.displayName,
                size: 18,
                fallbackGradient: parentItemUsesCurrentAccountFallback
                    ? appSettings.avatarFallbackGradient(forAccountPubkey: auth.currentAccount?.pubkey)
                    : nil,
                fallbackForeground: parentItemUsesCurrentAccountFallback
                    ? appSettings.avatarFallbackForeground(forAccountPubkey: auth.currentAccount?.pubkey)
                    : nil
            )

            if let snippet = presentation.snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(foregroundStyle)
                    .lineLimit(1)
            }

            if presentation.hasImageBadge {
                Text("image")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(foregroundStyle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(appSettings.themePalette.tertiaryFill)
                    )
            }

            Spacer(minLength: 0)
        }

        if let onTap {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var parentItemUsesCurrentAccountFallback: Bool {
        guard let rawCurrentPubkey = auth.currentAccount?.pubkey else {
            return false
        }
        let currentPubkey = rawCurrentPubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !currentPubkey.isEmpty else { return false }

        let parentPubkey = presentation.parentItem.displayAuthorPubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return parentPubkey == currentPubkey
    }
}

private struct FeedRowCardChromeModifier: ViewModifier {
    let feedCardStyle: AppThemeFeedCardStyle?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let feedCardStyle {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    feedCardStyle.backgroundTop,
                                    feedCardStyle.backgroundBottom
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(feedCardStyle.border, lineWidth: 0.9)

                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .inset(by: 1)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        feedCardStyle.highlight,
                                        feedCardStyle.highlight.opacity(0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    }
                }
                .shadow(color: feedCardStyle.shadow, radius: 14, x: 0, y: 8)
                .shadow(color: feedCardStyle.highlight.opacity(0.08), radius: 3, x: 0, y: 1)
                .padding(.vertical, 4)
        } else {
            content
        }
    }
}

struct FeedRowView: View {
    private struct PublicationFailurePresentation: Identifiable {
        let id: String
        let message: String
    }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    private let reactionStats = NoteReactionStatsService.shared
    private let muteStore = MuteStore.shared
    private let mutedThreadStore = MutedThreadStore.shared
    @ObservedObject private var localPublicationStore = LocalPublicationStore.shared

    struct AvatarMenuActions {
        let followLabel: String
        let onFollowToggle: () -> Void
        let onViewProfile: () -> Void
    }

    let item: FeedItem
    var reactionCount: Int = 0
    var isLikedByCurrentUser: Bool = false
    var commentCount: Int = 0
    var repostCount: Int = 0
    var showReactions: Bool = true
    var onAvatarTap: (() -> Void)? = nil
    var avatarMenuActions: AvatarMenuActions? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    var onProfileTap: ((String) -> Void)? = nil
    var onOpenThread: (() -> Void)? = nil
    var onRepostActorTap: ((String) -> Void)? = nil
    var onReferencedEventTap: ((FeedItem) -> Void)? = nil
    var onRelayTap: ((URL) -> Void)? = nil
    var onReplyTap: (() -> Void)? = nil
    var onOptimisticPublished: ((FeedItem) -> Void)? = nil
    var onMuteConversation: ((String) -> Void)? = nil
    var suppressReplyContextForDirectReplyTargetEventID: String? = nil

    @State private var isShowingReshareSheet = false
    @State private var quoteDraft: ReshareQuoteDraft?
    @State private var isShowingReplyComposer = false
    @State private var isPublishingRepost = false
    @State private var isShowingNoteOptionsSheet = false
    @State private var isShowingReportSheet = false
    @State private var isShowingTranslation = false
    @State private var reactionSnapshot: NoteReactionEventSnapshot?
    @State private var publicationFailurePresentation: PublicationFailurePresentation?
    private let reshareService = ResharePublishService()
    private let reactionPublishService = NoteReactionPublishService()
    private let reportPublishService = NoteReportPublishService()

    init(
        item: FeedItem,
        initialEngagementSnapshot: NoteReactionEventSnapshot? = nil,
        reactionCount: Int = 0,
        isLikedByCurrentUser: Bool = false,
        commentCount: Int = 0,
        repostCount: Int = 0,
        showReactions: Bool = true,
        onAvatarTap: (() -> Void)? = nil,
        avatarMenuActions: AvatarMenuActions? = nil,
        onHashtagTap: ((String) -> Void)? = nil,
        onProfileTap: ((String) -> Void)? = nil,
        onOpenThread: (() -> Void)? = nil,
        onRepostActorTap: ((String) -> Void)? = nil,
        onReferencedEventTap: ((FeedItem) -> Void)? = nil,
        onRelayTap: ((URL) -> Void)? = nil,
        onReplyTap: (() -> Void)? = nil,
        onOptimisticPublished: ((FeedItem) -> Void)? = nil,
        onMuteConversation: ((String) -> Void)? = nil,
        suppressReplyContextForDirectReplyTargetEventID: String? = nil
    ) {
        self.item = item
        self.reactionCount = reactionCount
        self.isLikedByCurrentUser = isLikedByCurrentUser
        self.commentCount = commentCount
        self.repostCount = repostCount
        self.showReactions = showReactions
        self.onAvatarTap = onAvatarTap
        self.avatarMenuActions = avatarMenuActions
        self.onHashtagTap = onHashtagTap
        self.onProfileTap = onProfileTap
        self.onOpenThread = onOpenThread
        self.onRepostActorTap = onRepostActorTap
        self.onReferencedEventTap = onReferencedEventTap
        self.onRelayTap = onRelayTap
        self.onReplyTap = onReplyTap
        self.onOptimisticPublished = onOptimisticPublished
        self.onMuteConversation = onMuteConversation
        self.suppressReplyContextForDirectReplyTargetEventID = suppressReplyContextForDirectReplyTargetEventID
        _reactionSnapshot = State(initialValue: initialEngagementSnapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.isRepost {
                repostBanner
                    .padding(.leading, rowContentLeadingInset)
            }

            if shouldShowReplyContext, let replyContextPresentation {
                replyContextRow(replyContextPresentation)
                    .padding(.leading, rowContentLeadingInset)
            }

            rowContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .modifier(FeedRowCardChromeModifier(feedCardStyle: appSettings.themePalette.feedCardStyle))
        .noteTranslationPresentation(
            isPresented: $isShowingTranslation,
            text: noteTranslationText
        )
        .alert(item: $publicationFailurePresentation) { details in
            Alert(
                title: Text("Couldn't publish"),
                message: Text(details.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onReceive(reactionStats.publisher(for: item.displayEventID)) { snapshot in
            reactionSnapshot = snapshot
        }
        .sheet(isPresented: $isShowingReshareSheet) {
            ReshareActionSheetView(
                isWorking: isPublishingRepost,
                onRepost: {
                    Task {
                        await publishRepost()
                    }
                },
                onQuote: {
                    quoteDraft = reshareService.buildQuoteDraft(
                        for: item,
                        relayHintURL: effectiveReadRelayURLs.first
                    )
                    isShowingReshareSheet = false
                }
            )
        }
        .sheet(isPresented: $isShowingNoteOptionsSheet) {
            NoteOptionsBottomSheetView(
                canCopyText: hasCopyableNoteText,
                onCopyText: {
                    UIPasteboard.general.string = copyableNoteText
                    toastCenter.show("Copied text")
                },
                onCopyEventID: {
                    UIPasteboard.general.string = copyableEventIdentifier
                    toastCenter.show("Copied event ID")
                },
                onCopyLink: {
                    UIPasteboard.general.string = copyableNoteLink
                    toastCenter.show("Copied link")
                },
                showsTranslateAction: canTranslateNote,
                onTranslate: canTranslateNote ? {
                    presentTranslation()
                } : nil,
                onMute: {
                    handleMuteAuthor()
                },
                onMuteThread: {
                    handleMuteThread()
                },
                spamMarkTitle: spamMarkActionTitle,
                spamMarkIcon: spamMarkActionIcon,
                canToggleSpamMark: canToggleAuthorSpamMark,
                onToggleSpamMark: {
                    handleToggleAuthorSpamMark()
                },
                onReport: {
                    presentReportFlow()
                }
            )
            .presentationDetents([.height(canTranslateNote ? 655 : 600), .medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingReportSheet) {
            NoteReportSheetView(noteAuthorName: item.displayName) { type, details in
                try await submitReport(type: type, details: details)
            }
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
                onOptimisticPublished: onOptimisticPublished
            )
        }
        .sheet(isPresented: $isShowingReplyComposer) {
            ComposeNoteSheet(
                currentAccountPubkey: auth.currentAccount?.pubkey,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                replyTargetEvent: item.displayEvent,
                replyTargetDisplayNameHint: item.displayName,
                replyTargetHandleHint: item.handle,
                replyTargetAvatarURLHint: item.avatarURL,
                onOptimisticPublished: onOptimisticPublished
            )
        }
    }

    private var visibleReactionCount: Int {
        reactionSnapshot?.reactionCount ?? reactionCount
    }

    private var visibleReplyCount: Int {
        max(commentCount, reactionSnapshot?.replyCount ?? 0)
    }

    private var visibleRepostCount: Int {
        max(repostCount, reactionSnapshot?.repostCount ?? 0)
    }

    private var resolvedIsLikedByCurrentUser: Bool {
        reactionSnapshot?.isReactedByCurrentUser(currentPubkey: auth.currentAccount?.pubkey) ?? isLikedByCurrentUser
    }

    private var usesFullWidthNoteRows: Bool {
        appSettings.fullWidthNoteRows
    }

    private var rowContentLeadingInset: CGFloat {
        usesFullWidthNoteRows ? 0 : 56
    }

    @ViewBuilder
    private var rowContent: some View {
        if usesFullWidthNoteRows {
            fullWidthRowContent
        } else {
            compactRowContent
        }
    }

    private var compactRowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            profileAvatar

            VStack(alignment: .leading, spacing: 6) {
                metadataHeader(alignment: .firstTextBaseline)
                noteBodyContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fullWidthRowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                profileAvatar
                metadataHeader(alignment: .firstTextBaseline)
                    .frame(minHeight: 44, alignment: .center)
            }

            noteBodyContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataHeader(alignment: VerticalAlignment) -> some View {
        HStack(alignment: alignment, spacing: 6) {
            HStack(alignment: alignment, spacing: 6) {
                Text(item.displayName)
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(2)

                Text(item.handle)
                    .font(appSettings.appFont(.subheadline))
                    .foregroundStyle(mutedChromeColor)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture {
                handleAuthorTap()
            }

            Spacer(minLength: 8)
                .frame(height: 28)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenThread?()
                }

            clientAttributionLabel

            Text(RelativeTimestampFormatter.shortString(from: item.displayEvent.createdAtDate))
                .font(appSettings.appFont(.caption1))
                .foregroundStyle(mutedChromeColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenThread?()
                }

            publicationStatusAccessory

            noteOptionsButton
        }
    }

    private var noteBodyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoteContentView(
                event: item.displayEvent,
                reactionCount: showReactions ? visibleReactionCount : 0,
                commentCount: showReactions ? visibleReplyCount : 0,
                trustedMediaSharerPubkey: item.isRepost ? item.actorPubkey : nil,
                articleAuthor: LongFormArticleAuthorSummary(item: item),
                onHashtagTap: onHashtagTap,
                onProfileTap: onProfileTap,
                onReferencedEventTap: onReferencedEventTap,
                onRelayTap: onRelayTap
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                TapGesture().onEnded {
                    onOpenThread?()
                },
                including: .gesture
            )

            if showReactions {
                reactionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reactionBar: some View {
        HStack(spacing: 14) {
            Button {
                if let onReplyTap {
                    onReplyTap()
                } else {
                    isShowingReplyComposer = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                    if visibleReplyCount > 0 {
                        Text("\(visibleReplyCount)")
                            .font(appSettings.appFont(.footnote))
                    }
                }
                .frame(minWidth: 34, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(mutedChromeColor)
            .accessibilityLabel("Reply")

            Button {
                isShowingReshareSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                    if visibleRepostCount > 0 {
                        Text("\(visibleRepostCount)")
                            .font(appSettings.appFont(.footnote))
                    }
                }
                .frame(minWidth: 34, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(mutedChromeColor)
            .accessibilityLabel("Re-share")

            ReactionButton(
                isLiked: resolvedIsLikedByCurrentUser,
                isBonusReaction: isBonusReactionByCurrentUser,
                count: visibleReactionCount,
                bonusActiveColor: appSettings.primaryColor,
                inactiveColor: mutedChromeColor
            ) { bonusCount in
                Task {
                    await handleReactionTap(bonusCount: bonusCount)
                }
            }

            ShareLink(item: copyableNoteLink) {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: 34, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(mutedChromeColor)
            .accessibilityLabel("Share")
        }
        .font(appSettings.appFont(.headline))
    }

    private var isBonusReactionByCurrentUser: Bool {
        let currentReaction = reactionSnapshot?.currentUserReaction(currentPubkey: auth.currentAccount?.pubkey)
            ?? reactionStats.currentUserReaction(
                for: item.displayEventID,
                currentPubkey: auth.currentAccount?.pubkey
            )
        return currentReaction?.bonusCount ?? 0 > 0
    }

    private var mutedChromeColor: Color {
        appSettings.themePalette.mutedForeground
    }

    private var publicationRecord: LocalPublicationRecord? {
        localPublicationStore.record(for: item.id)
    }

    @ViewBuilder
    private var publicationStatusAccessory: some View {
        switch publicationRecord?.state {
        case .publishing:
            ProgressView()
                .controlSize(.small)
                .tint(mutedChromeColor)
                .frame(width: 16, height: 16)
                .transition(FlowTransitionMotion.iconSwapTransition(reduceMotion: accessibilityReduceMotion))
                .accessibilityLabel("Publishing")
        case .failed:
            Button {
                publicationFailurePresentation = PublicationFailurePresentation(
                    id: item.id,
                    message: publicationFailureMessage
                )
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.warningForeground)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .transition(FlowTransitionMotion.iconSwapTransition(reduceMotion: accessibilityReduceMotion))
            .accessibilityLabel("Publishing failed")
            .accessibilityHint("Shows why this item couldn't publish to connected sources")
        default:
            EmptyView()
        }
    }

    private var publicationFailureMessage: String {
        if let message = publicationRecord?.state.failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }

        return "This item is still visible here, but it couldn't publish to connected sources."
    }

    @ViewBuilder
    private var clientAttributionLabel: some View {
        if let clientName = item.displayEvent.clientName {
            Text("via \(clientName)")
                .font(appSettings.appFont(.caption1))
                .foregroundStyle(mutedChromeColor)
                .lineLimit(1)
                .layoutPriority(-2)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenThread?()
                }
        }
    }

    private var followBadgeIconName: String? {
        guard !isAuthoredByCurrentAccount, let avatarMenuActions else { return nil }
        let normalized = avatarMenuActions.followLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("unfollow") ? "checkmark.circle.fill" : "plus.circle.fill"
    }

    private var isAuthoredByCurrentAccount: Bool {
        guard let rawCurrentPubkey = auth.currentAccount?.pubkey else {
            return false
        }
        let currentPubkey = rawCurrentPubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !currentPubkey.isEmpty else { return false }

        let authorPubkey = item.displayAuthorPubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return currentPubkey == authorPubkey
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let avatarMenuActions {
            Menu {
                Button {
                    avatarMenuActions.onFollowToggle()
                } label: {
                    Label(avatarMenuActions.followLabel, systemImage: followMenuIcon(for: avatarMenuActions.followLabel))
                }
                Button {
                    avatarMenuActions.onViewProfile()
                } label: {
                    Label("View Profile", systemImage: "person")
                }

                if canToggleAuthorSpamMark {
                    Button {
                        handleToggleAuthorSpamMark()
                    } label: {
                        Label(spamMarkActionTitle, systemImage: spamMarkActionIcon)
                    }
                }
            } label: {
                avatarWithFollowBadge
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile actions for \(item.displayName)")
        } else if let onAvatarTap {
            Button {
                onAvatarTap()
            } label: {
                avatarWithFollowBadge
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile options")
        } else {
            avatarWithFollowBadge
        }
    }

    private var avatarWithFollowBadge: some View {
        AvatarView(
            url: item.avatarURL,
            fallback: item.displayName,
            fallbackGradient: isAuthoredByCurrentAccount
                ? appSettings.avatarFallbackGradient(forAccountPubkey: auth.currentAccount?.pubkey)
                : nil,
            fallbackForeground: isAuthoredByCurrentAccount
                ? appSettings.avatarFallbackForeground(forAccountPubkey: auth.currentAccount?.pubkey)
                : nil
        )
            .overlay(alignment: .bottomTrailing) {
                if let followBadgeIconName {
                    followBadge(iconName: followBadgeIconName)
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private func followBadge(iconName: String) -> some View {
        if appSettings.usesPrimaryGradientForProminentButtons {
            ZStack {
                Circle()
                    .fill(appSettings.themePalette.background)
                    .frame(width: 18, height: 18)

                Circle()
                    .fill(appSettings.primaryGradient)
                    .frame(width: 16, height: 16)

                Image(systemName: iconName.contains("checkmark") ? "checkmark" : "plus")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(appSettings.buttonTextColor)
            }
        } else {
            ZStack {
                Circle()
                    .fill(appSettings.themePalette.background)
                    .frame(width: 18, height: 18)

                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(appSettings.primaryColor)
            }
        }
    }

    private var repostBanner: some View {
        Button {
            onRepostActorTap?(item.actorPubkey)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mutedChromeColor)

                AvatarView(url: item.actorAvatarURL, fallback: item.actorDisplayName, size: 18)

                Text("\(item.actorDisplayName) reposted")
                    .font(.caption)
                    .foregroundStyle(mutedChromeColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(onRepostActorTap == nil)
    }

    private var shouldShowReplyContext: Bool {
        guard item.displayEvent.isReplyNote, replyContextPresentation != nil else { return false }

        guard let suppressedTargetID = normalizedEventID(suppressReplyContextForDirectReplyTargetEventID) else {
            return true
        }

        let directReplyTargetID = normalizedEventID(item.displayEvent.directReplyEventReferenceID)
        return directReplyTargetID != suppressedTargetID
    }

    private var replyContextPresentation: ReplyContextPreviewPresentation? {
        ReplyContextPreviewPresentation.make(for: item)
    }

    private var shouldAllowReplyContextNavigation: Bool {
        guard let suppressedTargetID = normalizedEventID(suppressReplyContextForDirectReplyTargetEventID) else {
            return true
        }

        let directReplyTargetID = normalizedEventID(item.displayEvent.directReplyEventReferenceID)
        return directReplyTargetID != suppressedTargetID
    }

    @ViewBuilder
    private func replyContextRow(_ presentation: ReplyContextPreviewPresentation) -> some View {
        ReplyContextPreviewRow(
            presentation: presentation,
            foregroundStyle: mutedChromeColor,
            onTap: shouldAllowReplyContextNavigation ? {
                onReferencedEventTap?(presentation.parentItem.threadNavigationItem)
            } : nil
        )
    }

    private var noteOptionsButton: some View {
        Button {
            isShowingNoteOptionsSheet = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(mutedChromeColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Note options")
    }

    private func normalizedEventID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    @MainActor
    private func handleReactionTap(bonusCount: Int = 0) async {
        let eventID = item.displayEventID
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
                for: item.displayEvent,
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

    private func handleAuthorTap() {
        if let avatarMenuActions {
            avatarMenuActions.onViewProfile()
            return
        }

        if let onAvatarTap {
            onAvatarTap()
            return
        }

        onOpenThread?()
    }

    @MainActor
    private func publishRepost() async {
        guard !isPublishingRepost else { return }
        isPublishingRepost = true
        defer { isPublishingRepost = false }

        do {
            _ = try await reshareService.publishRepost(
                of: item.displayEvent,
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

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: effectiveReadRelayURLs
        )
    }

    private var copyableNoteLink: String {
        if let externalURL = NoteContentParser.njumpURL(for: item.displayEventID) {
            return externalURL.absoluteString
        }
        return "https://nlink.to/\(item.displayEventID)"
    }

    private var copyableEventIdentifier: String {
        NoteContentParser.neventIdentifier(
            for: item.displayEvent,
            relayHints: effectiveReadRelayURLs
        ) ?? item.displayEventID
    }

    private var noteTranslationText: String {
        item.displayEvent.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var copyableNoteText: String {
        item.displayEvent.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCopyableNoteText: Bool {
        !copyableNoteText.isEmpty
    }

    private var isAuthorMarkedSpam: Bool {
        appSettings.isSpamFilterMarked(item.displayAuthorPubkey)
    }

    private var canToggleAuthorSpamMark: Bool {
        !isAuthoredByCurrentAccount
    }

    private var spamMarkActionTitle: String {
        isAuthorMarkedSpam ? "Remove Spam Mark" : "Mark as Spam"
    }

    private var spamMarkActionIcon: String {
        isAuthorMarkedSpam ? "checkmark.shield" : "exclamationmark.shield"
    }

    private var canTranslateNote: Bool {
        guard !noteTranslationText.isEmpty else { return false }
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            return true
        }
        #endif
        return false
    }

    private func followMenuIcon(for label: String) -> String {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("unfollow") {
            return "person.crop.circle.badge.minus"
        }
        return "plus.circle"
    }

    private func presentTranslation() {
        guard canTranslateNote else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            isShowingTranslation = true
        }
    }

    private func handleMuteAuthor() {
        let wasMuted = muteStore.isMuted(item.displayAuthorPubkey)
        muteStore.toggleMute(item.displayAuthorPubkey)
        let isMuted = muteStore.isMuted(item.displayAuthorPubkey)

        if !wasMuted && isMuted {
            toastCenter.show("Muted \(item.displayName)")
        } else if wasMuted && !isMuted {
            toastCenter.show("Unmuted \(item.displayName)", style: .info)
        } else if let errorMessage = muteStore.lastPublishError,
                  !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toastCenter.show(errorMessage, style: .error, duration: 2.8)
        }
    }

    private func handleMuteThread() {
        let threadID = item.displayEvent.conversationID
        mutedThreadStore.configure(accountPubkey: auth.currentAccount?.pubkey)

        if mutedThreadStore.mute(threadID) {
            onMuteConversation?(threadID)
            toastCenter.show("Muted thread")
        } else {
            toastCenter.show("Thread already muted", style: .info)
        }
    }

    private func handleToggleAuthorSpamMark() {
        guard canToggleAuthorSpamMark else { return }
        if isAuthorMarkedSpam {
            appSettings.removeSpamFilterMarkedPubkey(item.displayAuthorPubkey)
            toastCenter.show("Removed spam mark", style: .info)
        } else {
            appSettings.addSpamFilterMarkedPubkey(item.displayAuthorPubkey)
            toastCenter.show("Marked \(item.displayName) as spam")
        }
    }

    private func presentReportFlow() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            isShowingReportSheet = true
        }
    }

    private func submitReport(type: NoteReportType, details: String) async throws {
        try await reportPublishService.publishReport(
            for: item.displayEvent,
            type: type,
            details: details,
            currentNsec: auth.currentNsec,
            writeRelayURLs: effectiveWriteRelayURLs
        )
        await MainActor.run {
            if type == .spam {
                appSettings.addSpamFilterMarkedPubkey(item.displayAuthorPubkey)
                toastCenter.show("Report sent and marked as spam")
            } else {
                toastCenter.show("Report sent")
            }
        }
    }
}

struct NoteOptionsBottomSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore

    let canCopyText: Bool
    let onCopyText: () -> Void
    let onCopyEventID: () -> Void
    let onCopyLink: () -> Void
    let showsTranslateAction: Bool
    let onTranslate: (() -> Void)?
    let onMute: () -> Void
    let onMuteThread: (() -> Void)?
    let spamMarkTitle: String
    let spamMarkIcon: String
    let canToggleSpamMark: Bool
    let onToggleSpamMark: () -> Void
    let onReport: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                optionRow(
                    title: "Copy Text",
                    icon: "text.alignleft",
                    isEnabled: canCopyText,
                    tint: .primary
                ) {
                    onCopyText()
                }

                sheetDivider

                optionRow(
                    title: "Copy Event ID",
                    icon: "number",
                    isEnabled: true,
                    tint: .primary
                ) {
                    onCopyEventID()
                }

                sheetDivider

                optionRow(
                    title: "Copy Link",
                    icon: "link",
                    isEnabled: true,
                    tint: .primary
                ) {
                    onCopyLink()
                }

                if showsTranslateAction {
                    sheetDivider

                    optionRow(
                        title: "Translate Note",
                        icon: "globe",
                        isEnabled: true,
                        tint: .primary
                    ) {
                        onTranslate?()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(appSettings.themePalette.sheetCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(appSettings.themeSeparator(defaultOpacity: 0.18), lineWidth: 0.8)
            )

            VStack(spacing: 0) {
                optionRow(
                    title: "Mute",
                    icon: "speaker.slash",
                    isEnabled: true,
                    tint: .primary
                ) {
                    onMute()
                }

                if let onMuteThread {
                    sheetDivider

                    optionRow(
                        title: "Mute Thread",
                        icon: "bell.slash",
                        isEnabled: true,
                        tint: .primary
                    ) {
                        onMuteThread()
                    }
                }

                sheetDivider

                optionRow(
                    title: spamMarkTitle,
                    icon: spamMarkIcon,
                    isEnabled: canToggleSpamMark,
                    tint: .orange
                ) {
                    onToggleSpamMark()
                }

                sheetDivider

                optionRow(
                    title: "Report",
                    icon: "exclamationmark.bubble",
                    isEnabled: true,
                    tint: .red
                ) {
                    onReport()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(appSettings.themePalette.sheetCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(appSettings.themeSeparator(defaultOpacity: 0.18), lineWidth: 0.8)
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(appSettings.themePalette.sheetBackground)
        .presentationBackground(appSettings.themePalette.sheetBackground)
    }

    private var sheetDivider: some View {
        Rectangle()
            .fill(appSettings.themeSeparator(defaultOpacity: 0.18))
            .frame(height: 0.75)
            .padding(.leading, 16)
    }

    @ViewBuilder
    private func optionRow(
        title: String,
        icon: String,
        isEnabled: Bool,
        tint: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            guard isEnabled else { return }
            action?()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isEnabled ? tint : appSettings.themePalette.mutedForeground)

                Spacer(minLength: 0)

                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isEnabled ? tint : appSettings.themePalette.mutedForeground)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    @ViewBuilder
    func noteTranslationPresentation(
        isPresented: Binding<Bool>,
        text: String
    ) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            self.translationPresentation(isPresented: isPresented, text: text)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

struct AvatarView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let url: URL?
    let fallback: String
    var size: CGFloat = 44
    var fallbackGradient: LinearGradient?
    var fallbackForeground: Color?

    var body: some View {
        Group {
            if appSettings.textOnlyMode {
                fallbackAvatar
            } else if let url {
                CachedAsyncImage(url: url, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(appSettings.themePalette.separator, lineWidth: 0.5)
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            if let fallbackGradient {
                Circle().fill(fallbackGradient)
            } else {
                Circle().fill(appSettings.themePalette.secondaryFill)
            }
            Text(String(fallback.prefix(1)).uppercased())
                .font(size >= 32 ? .headline : .caption.weight(.semibold))
                .foregroundStyle(fallbackForeground ?? appSettings.themePalette.mutedForeground)
        }
    }
}
