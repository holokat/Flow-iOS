import Foundation

struct HomeFeedVisibilityFilter {
    struct BufferedItemPartition {
        let retained: [FeedItem]
        let visible: [FeedItem]
    }

    struct Configuration {
        let feedSource: HomePrimaryFeedSource
        let mode: HomeFeedMode
        let showKinds: [Int]
        let mediaOnly: Bool
        let ignoreMediaOnly: Bool
        let followingPubkeys: [String]
        let currentUserPubkey: String?
        let mutedConversationIDs: Set<String>
        let muteSnapshot: MuteFilterSnapshot
        let hideNSFW: Bool
        let spamMarkedPubkeys: Set<String>
        let spamSafelistedPubkeys: Set<String>
    }

    static func visibleItems(
        _ source: [FeedItem],
        configuration: Configuration
    ) -> [FeedItem] {
        let allowedKinds = allowedKinds(for: configuration.feedSource, showKinds: configuration.showKinds)
        let supportsModeFiltering = HomeFeedViewModel.supportsModeTabs(for: configuration.feedSource)
        let allowedAuthors = sourceUsesFollowingAuthors(configuration.feedSource)
            ? allowedFollowingAuthors(configuration: configuration)
            : nil

        return source.filter { item in
            if !isAllowedForCurrentSource(
                item,
                configuration: configuration,
                allowedAuthors: allowedAuthors
            ) {
                return false
            }

            if configuration.muteSnapshot.shouldHideAny(in: item.moderationEvents) {
                return false
            }

            if isHiddenByManualSpam(item, configuration: configuration) {
                return false
            }

            return isVisibleAfterRetention(
                item,
                configuration: configuration,
                allowedKinds: allowedKinds,
                supportsModeFiltering: supportsModeFiltering
            )
        }
    }

    /// Produces the rows retained by Home and the rows visible under the current
    /// presentation filters in one pass. In particular, the expensive mute and
    /// encoded-spam checks run only once per buffered item before a reveal.
    static func partitionBufferedItems(
        _ source: [FeedItem],
        configuration: Configuration
    ) -> BufferedItemPartition {
        let allowedKinds = allowedKinds(for: configuration.feedSource, showKinds: configuration.showKinds)
        let supportsModeFiltering = HomeFeedViewModel.supportsModeTabs(for: configuration.feedSource)
        let allowedAuthors = sourceUsesFollowingAuthors(configuration.feedSource)
            ? allowedFollowingAuthors(configuration: configuration)
            : nil
        var retained: [FeedItem] = []
        var visible: [FeedItem] = []
        retained.reserveCapacity(source.count)
        visible.reserveCapacity(source.count)

        for item in source {
            guard isAllowedForCurrentSource(
                item,
                configuration: configuration,
                allowedAuthors: allowedAuthors
            ) else {
                continue
            }
            guard !configuration.muteSnapshot.shouldHideAny(in: item.moderationEvents) else {
                continue
            }
            guard !isHiddenByManualSpam(item, configuration: configuration) else {
                continue
            }

            retained.append(item)
            if isVisibleAfterRetention(
                item,
                configuration: configuration,
                allowedKinds: allowedKinds,
                supportsModeFiltering: supportsModeFiltering
            ) {
                visible.append(item)
            }
        }

        return BufferedItemPartition(retained: retained, visible: visible)
    }

    /// Applies only presentation filters to items that have already passed
    /// source, mute, and manual-spam retention checks.
    static func visibleRetainedItems(
        _ source: [FeedItem],
        configuration: Configuration
    ) -> [FeedItem] {
        let allowedKinds = allowedKinds(for: configuration.feedSource, showKinds: configuration.showKinds)
        let supportsModeFiltering = HomeFeedViewModel.supportsModeTabs(for: configuration.feedSource)

        return source.filter { item in
            isVisibleAfterRetention(
                item,
                configuration: configuration,
                allowedKinds: allowedKinds,
                supportsModeFiltering: supportsModeFiltering
            )
        }
    }

    /// Re-applies only source membership to rows that already passed mute and
    /// spam retention. This is used when a refreshed follow list changes so we
    /// can drop unfollowed authors without repeating expensive moderation work.
    static func retainedItemsAllowedForCurrentSource(
        _ source: [FeedItem],
        configuration: Configuration
    ) -> [FeedItem] {
        let allowedAuthors = sourceUsesFollowingAuthors(configuration.feedSource)
            ? allowedFollowingAuthors(configuration: configuration)
            : nil

        return source.filter { item in
            isAllowedForCurrentSource(
                item,
                configuration: configuration,
                allowedAuthors: allowedAuthors
            )
        }
    }

    static func pruneMutedItems(
        _ source: [FeedItem],
        configuration: Configuration
    ) -> [FeedItem] {
        guard configuration.muteSnapshot.hasAnyRules || !configuration.spamMarkedPubkeys.isEmpty else {
            return source
        }

        return source.filter { item in
            !configuration.muteSnapshot.shouldHideAny(in: item.moderationEvents) &&
                !isHiddenByManualSpam(item, configuration: configuration)
        }
    }

    static func pruneItemsForSource(
        _ source: [FeedItem],
        configuration: Configuration
    ) -> [FeedItem] {
        switch configuration.feedSource {
        case .following, .polls, .articles:
            let allowedAuthors = allowedFollowingAuthors(configuration: configuration)
            guard !allowedAuthors.isEmpty else { return [] }

            return source.filter { item in
                let isAllowedAuthor = allowedAuthors.contains(normalizePubkey(item.displayAuthorPubkey))
                guard isAllowedAuthor else { return false }
                if configuration.feedSource == .polls {
                    return item.displayEvent.pollMetadata != nil
                }
                if configuration.feedSource == .articles {
                    return HomeFeedViewModel.isVisibleArticle(item)
                }
                return true
            }

        default:
            return source
        }
    }

    static func isAllowedForCurrentSource(
        _ item: FeedItem,
        configuration: Configuration
    ) -> Bool {
        let allowedAuthors = sourceUsesFollowingAuthors(configuration.feedSource)
            ? allowedFollowingAuthors(configuration: configuration)
            : nil
        return isAllowedForCurrentSource(
            item,
            configuration: configuration,
            allowedAuthors: allowedAuthors
        )
    }

    private static func isAllowedForCurrentSource(
        _ item: FeedItem,
        configuration: Configuration,
        allowedAuthors: Set<String>?
    ) -> Bool {
        switch configuration.feedSource {
        case .following:
            guard let allowedAuthors, !allowedAuthors.isEmpty else { return false }
            return allowedAuthors.contains(normalizePubkey(item.displayAuthorPubkey))

        case .articles:
            guard let allowedAuthors, !allowedAuthors.isEmpty else { return false }
            guard allowedAuthors.contains(normalizePubkey(item.displayAuthorPubkey)) else { return false }
            return HomeFeedViewModel.isVisibleArticle(item)

        case .polls:
            guard let allowedAuthors, !allowedAuthors.isEmpty else { return false }
            guard allowedAuthors.contains(normalizePubkey(item.displayAuthorPubkey)) else { return false }
            return item.displayEvent.pollMetadata != nil

        default:
            return true
        }
    }

    private static func isVisibleAfterRetention(
        _ item: FeedItem,
        configuration: Configuration,
        allowedKinds: Set<Int>,
        supportsModeFiltering: Bool
    ) -> Bool {
        if configuration.mutedConversationIDs.contains(item.displayEvent.conversationID) {
            return false
        }

        if configuration.hideNSFW && item.moderationEvents.contains(where: { $0.containsNSFWHashtag }) {
            return false
        }

        if !allowedKinds.contains(item.event.kind) {
            return false
        }

        if supportsModeFiltering && !configuration.mode.includes(item) {
            return false
        }

        if configuration.feedSource != .polls &&
            configuration.feedSource != .articles &&
            !configuration.ignoreMediaOnly &&
            configuration.mediaOnly &&
            !item.displayEvent.hasMedia {
            return false
        }

        return true
    }

    static func sourceUsesFollowingAuthors(_ source: HomePrimaryFeedSource) -> Bool {
        switch source {
        case .following, .articles, .polls:
            return true
        default:
            return false
        }
    }

    static func allowedFollowingAuthors(configuration: Configuration) -> Set<String> {
        Set(
            followingAuthorPubkeys(
                followingPubkeys: configuration.followingPubkeys,
                currentUserPubkey: configuration.currentUserPubkey
            )
        )
    }

    static func followingAuthorPubkeys(
        followingPubkeys: [String],
        currentUserPubkey: String?
    ) -> [String] {
        var ordered: [String] = []
        if let currentUserPubkey {
            ordered.append(currentUserPubkey)
        }
        ordered.append(contentsOf: followingPubkeys)

        var seen = Set<String>()
        return ordered.compactMap { rawPubkey in
            let normalized = normalizePubkey(rawPubkey)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func allowedKinds(
        for source: HomePrimaryFeedSource,
        showKinds: [Int]
    ) -> Set<Int> {
        switch source {
        case .polls:
            return Set(FeedKindFilters.pollKinds)
        case .articles:
            return [FeedKindFilters.longFormArticle]
        default:
            return Set(showKinds)
        }
    }

    private static func isHiddenByManualSpam(
        _ item: FeedItem,
        configuration: Configuration
    ) -> Bool {
        let normalizedPubkey = normalizePubkey(item.displayAuthorPubkey)
        guard normalizedPubkey != normalizePubkey(configuration.currentUserPubkey) else { return false }
        return configuration.spamMarkedPubkeys.contains(normalizedPubkey) &&
            !configuration.spamSafelistedPubkeys.contains(normalizedPubkey)
    }

    private static func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
