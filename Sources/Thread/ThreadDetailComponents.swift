import SwiftUI
import UIKit

struct ThreadDetailSeparator: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var leadingPadding: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(appSettings.themePalette.chromeBorder)
            .frame(height: 0.7)
            .padding(.leading, leadingPadding)
    }
}

struct ThreadDetailRootNoteCard: View {
        @EnvironmentObject private var appSettings: AppSettingsStore
        @EnvironmentObject private var auth: AuthManager

        let item: FeedItem
        let isHiddenByNSFW: Bool
        let reactionCount: Int
        let commentCount: Int
        let repostCount: Int
        let showReactions: Bool
        let isFollowingAuthor: Bool
        let rootFollowStatusIconName: String?
        let isLikedByCurrentUser: Bool
        let isBonusReactionByCurrentUser: Bool
        let onFollowToggle: () -> Void
        let onOpenProfile: (String) -> Void
        let onOpenHashtag: (String) -> Void
        let onOpenReferencedEvent: (FeedItem) -> Void
        let onOpenRelay: (URL) -> Void
        let onOptionsTap: () -> Void
        let onReplyTap: () -> Void
        let onReactionTap: (Int) -> Void
        let onRepostTap: () -> Void
        let shareLink: String

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                if !isHiddenByNSFW, let replyContextPresentation = ReplyContextPreviewPresentation.make(for: item) {
                    ReplyContextPreviewRow(
                        presentation: replyContextPresentation,
                        foregroundStyle: appSettings.themePalette.mutedForeground,
                        onTap: {
                            onOpenReferencedEvent(replyContextPresentation.parentItem.threadNavigationItem)
                        }
                    )
                }

                HStack(alignment: .center, spacing: 10) {
                    Menu {
                        Button {
                            onFollowToggle()
                        } label: {
                            Label(
                                isFollowingAuthor ? "Unfollow" : "Follow",
                                systemImage: isFollowingAuthor
                                    ? "person.crop.circle.badge.minus"
                                    : "plus.circle"
                            )
                        }
                        Button {
                            onOpenProfile(item.displayAuthorPubkey)
                        } label: {
                            Label("View Profile", systemImage: "person")
                        }
                    } label: {
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
                                if let rootFollowStatusIconName {
                                    ZStack {
                                        Circle()
                                            .fill(appSettings.themePalette.background)
                                            .frame(width: 18, height: 18)

                                        Image(systemName: rootFollowStatusIconName)
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(appSettings.primaryColor)
                                    }
                                    .offset(x: 3, y: 3)
                                    .accessibilityHidden(true)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile actions for \(item.displayName)")

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Text(item.handle)
                            .font(.subheadline)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if let clientName = item.displayEvent.clientName {
                            Text("via \(clientName)")
                                .font(.subheadline)
                                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                                .lineLimit(1)
                        }

                        Text(RelativeTimestampFormatter.shortString(from: item.displayEvent.createdAtDate))
                            .font(.subheadline)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .lineLimit(1)

                        Button {
                            onOptionsTap()
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(appSettings.themePalette.mutedForeground)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Note options")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isHiddenByNSFW {
                    ThreadDetailNSFWHiddenCard()
                } else {
                    NoteContentView(
                        event: item.displayEvent,
                        mediaLayout: .feed,
                        reactionCount: showReactions ? reactionCount : 0,
                        commentCount: showReactions ? commentCount : 0,
                        articleAuthor: LongFormArticleAuthorSummary(item: item),
                        onHashtagTap: onOpenHashtag,
                        onProfileTap: onOpenProfile,
                        onReferencedEventTap: onOpenReferencedEvent,
                        onRelayTap: onOpenRelay
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showReactions {
                    ThreadDetailInteractionRow(
                        replyCount: commentCount,
                        repostCount: repostCount,
                        reactionCount: reactionCount,
                        isLikedByCurrentUser: isLikedByCurrentUser,
                        isBonusReactionByCurrentUser: isBonusReactionByCurrentUser,
                        primaryColor: appSettings.primaryColor,
                        onReplyTap: onReplyTap,
                        onRepostTap: onRepostTap,
                        onReactionTap: onReactionTap,
                        shareLink: shareLink
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
            return authorPubkey == currentPubkey
        }
    }

struct ThreadDetailInteractionRow: View {
        @EnvironmentObject private var appSettings: AppSettingsStore

        let replyCount: Int?
        let repostCount: Int
        let reactionCount: Int
        let isLikedByCurrentUser: Bool
        let isBonusReactionByCurrentUser: Bool
        let primaryColor: Color
        let onReplyTap: () -> Void
        let onRepostTap: () -> Void
        let onReactionTap: (Int) -> Void
        let shareLink: String

        var body: some View {
            HStack(spacing: 14) {
                Button(action: onReplyTap) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.right")
                        if let replyCount, replyCount > 0 {
                            Text("\(replyCount)")
                                .font(.footnote)
                        }
                    }
                    .frame(minWidth: 34, minHeight: 30, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                .accessibilityLabel("Reply")

                Button(action: onRepostTap) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                        if repostCount > 0 {
                            Text("\(repostCount)")
                                .font(.footnote)
                        }
                    }
                    .frame(minWidth: 34, minHeight: 30, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                .accessibilityLabel("Re-share")

                ReactionButton(
                    isLiked: isLikedByCurrentUser,
                    isBonusReaction: isBonusReactionByCurrentUser,
                    count: reactionCount,
                    bonusActiveColor: primaryColor,
                    minHeight: 30,
                    action: onReactionTap
                )

                ShareLink(item: shareLink) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(minWidth: 34, minHeight: 30, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                .accessibilityLabel("Share")
            }
            .font(.headline)
        }
    }

struct ThreadDetailContentSection: View {
        @EnvironmentObject private var appSettings: AppSettingsStore

        @Binding var selectedContentTab: ThreadDetailContentTab
        let replies: [FeedItem]
        let spamReplies: [FeedItem]
        let spamRepliesExpanded: Bool
        let replyCountsByTarget: [String: Int]
        let noteActivityRows: [ActivityRow]
        let isLoadingReplies: Bool
        let isLoadingReactions: Bool
        let repliesErrorMessage: String?
        let reactionsErrorMessage: String?
        let rootEventID: String
        let showReactions: Bool
        let effectiveReadRelayURLs: [URL]
        let currentUserPubkey: String?
        let isFollowingAuthor: (String) -> Bool
        let onFollowToggle: (String) -> Void
        let onOpenHashtag: (String) -> Void
        let onOpenProfile: (String) -> Void
        let onOpenRelay: (URL) -> Void
        let onOpenThread: (FeedItem) -> Void
        let onReplyTap: (FeedItem) -> Void
        let onToggleSpamReplies: () -> Void
        let onMarkNotSpam: (String) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                FlowCapsuleTabBar(
                    selection: $selectedContentTab,
                    items: ThreadDetailContentTab.allCases,
                    title: { $0.title }
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                switch selectedContentTab {
                case .replies:
                    ThreadDetailRepliesSection(
                        replies: replies,
                        spamReplies: spamReplies,
                        spamRepliesExpanded: spamRepliesExpanded,
                        replyCountsByTarget: replyCountsByTarget,
                        isLoading: isLoadingReplies,
                        rootEventID: rootEventID,
                        showReactions: showReactions,
                        effectiveReadRelayURLs: effectiveReadRelayURLs,
                        currentUserPubkey: currentUserPubkey,
                        isFollowingAuthor: isFollowingAuthor,
                        onFollowToggle: onFollowToggle,
                        onOpenHashtag: onOpenHashtag,
                        onOpenProfile: onOpenProfile,
                        onOpenRelay: onOpenRelay,
                        onOpenThread: onOpenThread,
                        onReplyTap: onReplyTap,
                        onToggleSpamReplies: onToggleSpamReplies,
                        onMarkNotSpam: onMarkNotSpam
                    )

                    if let repliesErrorMessage {
                        Text(repliesErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                case .reactions:
                    ThreadDetailReactionsSection(
                        noteActivityRows: noteActivityRows,
                        isLoading: isLoadingReactions,
                        onOpenProfile: onOpenProfile
                    )

                    if let reactionsErrorMessage {
                        Text(reactionsErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

struct ThreadDetailRepliesSection: View {
        @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
        @EnvironmentObject private var appSettings: AppSettingsStore
        @ObservedObject private var reactionStats = NoteReactionStatsService.shared
        @StateObject private var engagementViewport = FeedEngagementViewportCoordinator()

        let replies: [FeedItem]
        let spamReplies: [FeedItem]
        let spamRepliesExpanded: Bool
        let replyCountsByTarget: [String: Int]
        let isLoading: Bool
        let rootEventID: String
        let showReactions: Bool
        let effectiveReadRelayURLs: [URL]
        let currentUserPubkey: String?
        let isFollowingAuthor: (String) -> Bool
        let onFollowToggle: (String) -> Void
        let onOpenHashtag: (String) -> Void
        let onOpenProfile: (String) -> Void
        let onOpenRelay: (URL) -> Void
        let onOpenThread: (FeedItem) -> Void
        let onReplyTap: (FeedItem) -> Void
        let onToggleSpamReplies: () -> Void
        let onMarkNotSpam: (String) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading && replies.isEmpty && spamReplies.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if replies.isEmpty && spamReplies.isEmpty {
                    VStack(spacing: 6) {
                        Text("No replies yet")
                            .font(.headline)
                        Text("Replies will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                } else {
                    ForEach(replies) { reply in
                        replyRow(reply)
                            .transition(FlowTransitionMotion.feedItemInsertionTransition(reduceMotion: accessibilityReduceMotion))
                    }

                    if !spamReplies.isEmpty {
                        ThreadDetailSpamRepliesGroup(
                            engagementViewport: engagementViewport,
                            replies: spamReplies,
                            isExpanded: spamRepliesExpanded,
                            replyCountsByTarget: replyCountsByTarget,
                            rootEventID: rootEventID,
                            showReactions: showReactions,
                            effectiveReadRelayURLs: effectiveReadRelayURLs,
                            currentUserPubkey: currentUserPubkey,
                            isFollowingAuthor: isFollowingAuthor,
                            onFollowToggle: onFollowToggle,
                            onOpenHashtag: onOpenHashtag,
                            onOpenProfile: onOpenProfile,
                            onOpenRelay: onOpenRelay,
                            onOpenThread: onOpenThread,
                            onReplyTap: onReplyTap,
                            onToggle: onToggleSpamReplies,
                            onMarkNotSpam: onMarkNotSpam
                        )
                    }
                }
            }
            .animation(
                FlowTransitionMotion.feedInsertionAnimation(reduceMotion: accessibilityReduceMotion),
                value: replies.map(\.id)
            )
        }

        private func replyRow(_ reply: FeedItem) -> some View {
            FeedRowView(
                item: reply,
                reactionCount: reactionStats.reactionCount(for: reply.displayEventID),
                isLikedByCurrentUser: reactionStats.isReactedByCurrentUser(
                    for: reply.displayEventID,
                    currentPubkey: currentUserPubkey
                ),
                commentCount: replyCountsByTarget[reply.displayEventID.lowercased()] ?? 0,
                repostCount: reactionStats.repostCount(for: reply.displayEventID),
                showReactions: showReactions,
                avatarMenuActions: .init(
                    followLabel: isFollowingAuthor(reply.displayAuthorPubkey) ? "Unfollow" : "Follow",
                    onFollowToggle: {
                        onFollowToggle(reply.displayAuthorPubkey)
                    },
                    onViewProfile: {
                        onOpenProfile(reply.displayAuthorPubkey)
                    }
                ),
                onHashtagTap: onOpenHashtag,
                onProfileTap: onOpenProfile,
                onOpenThread: {
                    onOpenThread(reply)
                },
                onRepostActorTap: onOpenProfile,
                onReferencedEventTap: { referencedItem in
                    onOpenThread(referencedItem)
                },
                onRelayTap: onOpenRelay,
                onReplyTap: {
                    onReplyTap(reply)
                },
                suppressReplyContextForDirectReplyTargetEventID: rootEventID
            )
            .id("thread-detail-reply-\(reply.id.lowercased())")
            .padding(.horizontal, 16)
            .onAppear {
                if showReactions {
                    engagementViewport.noteVisible(
                        event: reply.displayEvent,
                        relayURLs: effectiveReadRelayURLs
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if appSettings.themePalette.feedCardStyle == nil {
                    ThreadDetailSeparator(leadingPadding: 56)
                }
            }
        }
    }

struct ThreadDetailSpamRepliesGroup: View {
        @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
        @EnvironmentObject private var appSettings: AppSettingsStore
        @ObservedObject private var reactionStats = NoteReactionStatsService.shared

        let engagementViewport: FeedEngagementViewportCoordinator
        let replies: [FeedItem]
        let isExpanded: Bool
        let replyCountsByTarget: [String: Int]
        let rootEventID: String
        let showReactions: Bool
        let effectiveReadRelayURLs: [URL]
        let currentUserPubkey: String?
        let isFollowingAuthor: (String) -> Bool
        let onFollowToggle: (String) -> Void
        let onOpenHashtag: (String) -> Void
        let onOpenProfile: (String) -> Void
        let onOpenRelay: (URL) -> Void
        let onOpenThread: (FeedItem) -> Void
        let onReplyTap: (FeedItem) -> Void
        let onToggle: () -> Void
        let onMarkNotSpam: (String) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))

                        Text("\(replies.count) hidden \(replies.count == 1 ? "reply" : "replies") from likely spam accounts")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(isExpanded ? "Hide" : "Show")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    }
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(appSettings.themePalette.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(appSettings.themePalette.chromeBorder, lineWidth: 0.7)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityLabel("Hidden likely spam replies")

                if isExpanded {
                    ForEach(replies) { reply in
                        FeedRowView(
                            item: reply,
                            reactionCount: reactionStats.reactionCount(for: reply.displayEventID),
                            isLikedByCurrentUser: reactionStats.isReactedByCurrentUser(
                                for: reply.displayEventID,
                                currentPubkey: currentUserPubkey
                            ),
                            commentCount: replyCountsByTarget[reply.displayEventID.lowercased()] ?? 0,
                            repostCount: reactionStats.repostCount(for: reply.displayEventID),
                            showReactions: showReactions,
                            avatarMenuActions: .init(
                                followLabel: isFollowingAuthor(reply.displayAuthorPubkey) ? "Unfollow" : "Follow",
                                onFollowToggle: {
                                    onFollowToggle(reply.displayAuthorPubkey)
                                },
                                onViewProfile: {
                                    onOpenProfile(reply.displayAuthorPubkey)
                                }
                            ),
                            onHashtagTap: onOpenHashtag,
                            onProfileTap: onOpenProfile,
                            onOpenThread: {
                                onOpenThread(reply)
                            },
                            onRepostActorTap: onOpenProfile,
                            onReferencedEventTap: { referencedItem in
                                onOpenThread(referencedItem)
                            },
                            onRelayTap: onOpenRelay,
                            onReplyTap: {
                                onReplyTap(reply)
                            },
                            suppressReplyContextForDirectReplyTargetEventID: rootEventID
                        )
                        .id("thread-detail-spam-reply-\(reply.id.lowercased())")
                        .transition(FlowTransitionMotion.feedItemInsertionTransition(reduceMotion: accessibilityReduceMotion))
                        .padding(.horizontal, 16)
                        .onAppear {
                            if showReactions {
                                engagementViewport.noteVisible(
                                    event: reply.displayEvent,
                                    relayURLs: effectiveReadRelayURLs
                                )
                            }
                        }

                        HStack {
                            Spacer(minLength: 0)
                            Button("Not spam") {
                                onMarkNotSpam(reply.displayAuthorPubkey)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                        if appSettings.themePalette.feedCardStyle == nil {
                            ThreadDetailSeparator(leadingPadding: 72)
                        }
                    }
                }
            }
            .animation(
                FlowTransitionMotion.feedInsertionAnimation(reduceMotion: accessibilityReduceMotion),
                value: replies.map(\.id)
            )
        }
    }

struct ThreadDetailReactionsSection: View {
        @EnvironmentObject private var appSettings: AppSettingsStore

        let noteActivityRows: [ActivityRow]
        let isLoading: Bool
        let onOpenProfile: (String) -> Void

        var body: some View {
            Group {
                if isLoading && noteActivityRows.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if noteActivityRows.isEmpty {
                    VStack(spacing: 6) {
                        Text("No reactions yet")
                            .font(.headline)
                        Text("Likes, reposts, and quote shares will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                } else {
                    ForEach(noteActivityRows) { activity in
                        ActivityRowCell(
                            item: activity,
                            onAvatarTap: {
                                onOpenProfile(activity.actorPubkey)
                            }
                        )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                        ThreadDetailSeparator(leadingPadding: 56)
                    }
                }
            }
        }
    }

struct ThreadDetailArticleBody: View {
        @EnvironmentObject private var appSettings: AppSettingsStore
        @Environment(\.dismiss) private var dismiss

        let item: FeedItem
        let articleMetadata: NostrLongFormArticleMetadata
        let isHiddenByNSFW: Bool
        let isOwnedByCurrentUser: Bool
        let isFollowingAuthor: Bool
        let showReactions: Bool
        let errorMessage: String?
        let reactionCount: Int
        let isLikedByCurrentUser: Bool
        let isBonusReactionByCurrentUser: Bool
        let shareLink: String
        let onFollowToggle: () -> Void
        let onOpenProfile: (String) -> Void
        let onOpenHashtag: (String) -> Void
        let onReplyTap: () -> Void
        let onRepostTap: () -> Void
        let onReactionTap: (Int) -> Void

        var body: some View {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if isHiddenByNSFW {
                            ThreadDetailNSFWHiddenCard()
                                .padding(.horizontal, 20)
                                .padding(.top, 18)
                                .frame(maxWidth: 820, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            LongFormArticleReaderView(
                                item: item,
                                article: articleMetadata,
                                isOwnedByCurrentUser: isOwnedByCurrentUser,
                                isFollowingAuthor: isFollowingAuthor,
                                shareLink: shareLink,
                                onFollowToggle: onFollowToggle,
                                onProfileTap: onOpenProfile,
                                onHashtagTap: onOpenHashtag
                            )
                            .overlay(alignment: .topLeading) {
                                articleBackButton(topSafeAreaInset: proxy.safeAreaInsets.top)
                            }

                            if showReactions {
                                VStack(alignment: .leading, spacing: 18) {
                                    ThreadDetailSeparator()
                                    ThreadDetailInteractionRow(
                                        replyCount: nil,
                                        repostCount: 0,
                                        reactionCount: reactionCount,
                                        isLikedByCurrentUser: isLikedByCurrentUser,
                                        isBonusReactionByCurrentUser: isBonusReactionByCurrentUser,
                                        primaryColor: appSettings.primaryColor,
                                        onReplyTap: onReplyTap,
                                        onRepostTap: onRepostTap,
                                        onReactionTap: onReactionTap,
                                        shareLink: shareLink
                                    )
                                }
                                .padding(.horizontal, 20)
                                .frame(maxWidth: 820, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                                    .padding(.horizontal, 20)
                                    .frame(maxWidth: 820, alignment: .center)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .ignoresSafeArea(edges: .top)
            }
        }

        private var articleBackButtonForeground: Color {
            appSettings.themePalette.profileActionStyle?.bannerForeground ?? appSettings.themePalette.foreground
        }

        private var articleBackButtonBorder: Color {
            appSettings.themePalette.profileActionStyle?.bannerBorder ?? appSettings.themePalette.separator.opacity(0.88)
        }

        private var articleBackButtonBackground: Color {
            appSettings.themePalette.profileActionStyle?.bannerBackground ?? appSettings.themePalette.modalBackground
        }

        private func articleBackButton(topSafeAreaInset: CGFloat) -> some View {
            Button {
                dismiss()
            } label: {
                ProfileBannerCircleIcon(
                    systemImage: "chevron.left",
                    foreground: articleBackButtonForeground,
                    border: articleBackButtonBorder,
                    background: articleBackButtonBackground
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(
                .top,
                ThreadDetailViewLayout.topControlTopPadding(safeAreaInset: topSafeAreaInset)
            )
            .accessibilityLabel("Back")
        }
    }

struct ThreadDetailNSFWHiddenCard: View {
        @EnvironmentObject private var appSettings: AppSettingsStore

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                Text("Content hidden by NSFW filter.")
                    .font(.subheadline)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appSettings.themePalette.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(appSettings.themePalette.chromeBorder, lineWidth: 0.5)
            )
        }
    }

extension ThreadDetailView {
    var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: effectiveReadRelayURLs
        )
    }

    var effectiveRelayURL: URL {
        if appSettings.slowConnectionMode {
            return AppSettingsStore.slowModeRelayURL
        }
        return viewModel.relayURL
    }
}

enum ThreadDetailContentTab: String, CaseIterable, Hashable {
    case replies
    case reactions

    var title: String {
        switch self {
        case .replies:
            return "Replies"
        case .reactions:
            return "Reactions"
        }
    }
}
