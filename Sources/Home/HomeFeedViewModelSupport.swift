import Foundation

extension HomeFeedViewModel {
    struct FeedRequestStrategy: Equatable {
        let fetchTimeout: TimeInterval
        let relayFetchMode: RelayFetchMode
    }

    struct TrendingPaginationState {}

    struct TrendingPageFetchResult {
        let page: HomeFeedPageResult
        let nextState: TrendingPaginationState?
    }

    struct VisibleItemsCacheKey: Equatable {
        let itemsRevision: Int
        let feedSource: HomePrimaryFeedSource
        let mode: HomeFeedMode
        let showKinds: [Int]
        let mediaOnly: Bool
        let hideNSFW: Bool
        let filterRevision: Int
        let spamFilterSignature: String
        let mutedConversationRevision: Int
        let ignoreMediaOnly: Bool
    }

    private static let fastHomeFetchTimeout: TimeInterval = 8
    private static let fastHomeRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let paginationFetchTimeout: TimeInterval = 8
    private static let followingHomeFetchTimeout: TimeInterval = 8
    private static let followingPaginationFetchTimeout: TimeInterval = 8
    private nonisolated static let pollsInitialVisibleTarget = 8
    private nonisolated static let articlesInitialVisibleTarget = 24
    static let liveCatchUpFetchTimeout: TimeInterval = 4
    static let liveCatchUpMinimumInterval: TimeInterval = 15
    static let liveCatchUpOverlapSeconds = 90
    static let liveCatchUpLimit = 200
    static let trendingEmptyRetryDelayNanoseconds: UInt64 = 650_000_000

    nonisolated static var defaultPageSizeForTesting: Int {
        HomeFeedPaginationDefaults.pageSize
    }

    nonisolated static func trendingWindowTraversalLimitForTesting(isInitialPage: Bool) -> Int {
        let _ = isInitialPage
        return 1
    }

    nonisolated static func initialVisibleTargetForTesting(
        source: HomePrimaryFeedSource,
        mode: HomeFeedMode?,
        limit: Int
    ) -> Int {
        initialVisibleTarget(for: source, mode: mode, limit: limit)
    }

    nonisolated static func minimumVisibleItemsForSelectedModeForTesting(
        source: HomePrimaryFeedSource,
        mode: HomeFeedMode,
        pageSize: Int
    ) -> Int {
        minimumVisibleItemsForSelectedMode(
            source: source,
            mode: mode,
            pageSize: pageSize
        )
    }

    nonisolated static func supportsModeTabsForTesting(source: HomePrimaryFeedSource) -> Bool {
        supportsModeTabs(for: source)
    }

    // Network-style feeds can use a fast first non-empty relay grace window.
    // Following now favors completeness on initial load because staged hydration
    // already keeps row rendering lightweight.
    static func requestStrategy(
        for source: HomePrimaryFeedSource,
        isPagination: Bool
    ) -> FeedRequestStrategy {
        switch source {
        case .following, .articles:
            return FeedRequestStrategy(
                fetchTimeout: isPagination ? followingPaginationFetchTimeout : followingHomeFetchTimeout,
                relayFetchMode: .allRelays
            )
        case .polls:
            return FeedRequestStrategy(
                fetchTimeout: isPagination ? followingPaginationFetchTimeout : followingHomeFetchTimeout,
                relayFetchMode: isPagination ? .allRelays : .firstNonEmptyRelay
            )
        default:
            return FeedRequestStrategy(
                fetchTimeout: isPagination ? paginationFetchTimeout : fastHomeFetchTimeout,
                relayFetchMode: isPagination ? .allRelays : fastHomeRelayFetchMode
            )
        }
    }

    nonisolated static func shouldPrefetchMore(
        visibleItemCount: Int,
        currentIndex: Int
    ) -> Bool {
        guard visibleItemCount > 0 else { return false }
        guard currentIndex >= 0, currentIndex < visibleItemCount else { return false }
        let remainingItemCount = visibleItemCount - currentIndex - 1
        return remainingItemCount <= HomeFeedPaginationDefaults.prefetchTriggerDistance
    }

    nonisolated static func shouldShowPaginationSpinner(
        visibleItemCount: Int,
        currentIndex: Int
    ) -> Bool {
        guard visibleItemCount > 0 else { return false }
        guard currentIndex >= 0, currentIndex < visibleItemCount else { return false }
        let remainingItemCount = visibleItemCount - currentIndex - 1
        return remainingItemCount <= HomeFeedPaginationDefaults.spinnerTriggerDistance
    }

    static func stagedHydrationMode(
        for source: HomePrimaryFeedSource,
        requestHydrationMode: FeedItemHydrationMode
    ) -> FeedItemHydrationMode {
        switch source {
        case .following, .articles, .polls, .news:
            return .cachedProfilesOnly
        default:
            return requestHydrationMode
        }
    }

    static func shouldRunImmediateHydrationUpgrade(
        for source: HomePrimaryFeedSource,
        requestHydrationMode: FeedItemHydrationMode,
        fastHydrationMode: FeedItemHydrationMode
    ) -> Bool {
        guard requestHydrationMode != fastHydrationMode else { return false }

        switch source {
        case .articles:
            // Article list surfaces only need the fast cached-profile pass to
            // publish stable rows; the eager full upgrade regresses refresh latency.
            return false
        default:
            return true
        }
    }

    nonisolated static func followingAuthorPubkeys(
        followingPubkeys: [String],
        currentUserPubkey: String?
    ) -> [String] {
        HomeFeedVisibilityFilter.followingAuthorPubkeys(
            followingPubkeys: followingPubkeys,
            currentUserPubkey: currentUserPubkey
        )
    }

    nonisolated static func prefixForVisibleModeLimitForTesting(
        _ items: [FeedItem],
        mode: HomeFeedMode,
        visibleLimit: Int
    ) -> [FeedItem] {
        prefixForVisibleModeLimit(items, mode: mode, visibleLimit: visibleLimit)
    }

    nonisolated static func visibleItemCount(_ items: [FeedItem], mode: HomeFeedMode) -> Int {
        items.reduce(into: 0) { count, item in
            if mode.includes(item) {
                count += 1
            }
        }
    }

    nonisolated static func supportsModeTabs(for source: HomePrimaryFeedSource) -> Bool {
        HomeFeedModePolicy.supportsModeTabs(for: source)
    }

    nonisolated static func modeForFetch(
        source: HomePrimaryFeedSource,
        selectedMode: HomeFeedMode
    ) -> HomeFeedMode? {
        supportsModeTabs(for: source) ? selectedMode : nil
    }

    nonisolated static func prefixForVisibleModeLimit(
        _ items: [FeedItem],
        mode: HomeFeedMode,
        visibleLimit: Int
    ) -> [FeedItem] {
        guard visibleLimit > 0 else { return [] }

        var visibleCount = 0
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            result.append(item)
            if mode.includes(item) {
                visibleCount += 1
                if visibleCount >= visibleLimit {
                    break
                }
            }
        }

        return result
    }

    nonisolated static func initialVisibleTarget(
        for source: HomePrimaryFeedSource,
        mode: HomeFeedMode?,
        limit: Int
    ) -> Int {
        let baseline: Int
        switch source {
        case .polls:
            baseline = pollsInitialVisibleTarget
        case .articles:
            baseline = articlesInitialVisibleTarget
        case .following:
            let _ = mode
            baseline = limit
        default:
            baseline = limit
        }

        return max(1, min(limit, baseline))
    }

    nonisolated static func minimumVisibleItemsForSelectedMode(
        source: HomePrimaryFeedSource,
        mode: HomeFeedMode,
        pageSize: Int
    ) -> Int {
        switch source {
        case .following:
            return initialVisibleTarget(
                for: source,
                mode: mode,
                limit: pageSize
            )
        default:
            return min(max(pageSize / 3, 8), pageSize)
        }
    }

    nonisolated static func sortedMergedItems(
        _ items: [FeedItem],
        feedSource: HomePrimaryFeedSource?
    ) -> [FeedItem] {
        guard feedSource == .articles else {
            return items.sorted {
                if $0.event.createdAt == $1.event.createdAt {
                    return $0.id > $1.id
                }
                return $0.event.createdAt > $1.event.createdAt
            }
        }

        var keyedArticles: [String: FeedItem] = [:]
        var unkeyedItems: [FeedItem] = []

        for item in items {
            guard let replacementKey = articleReplacementKey(for: item) else {
                unkeyedItems.append(item)
                continue
            }

            if let existing = keyedArticles[replacementKey] {
                keyedArticles[replacementKey] = preferredArticleReplacement(
                    existing: existing,
                    incoming: item
                )
            } else {
                keyedArticles[replacementKey] = item
            }
        }

        return (Array(keyedArticles.values) + unkeyedItems).sorted(by: comesBeforeInArticlesFeed)
    }

    nonisolated static func containsArticleReplacement(
        for item: FeedItem,
        in replacementKeys: Set<String>
    ) -> Bool {
        guard let replacementKey = articleReplacementKey(for: item) else { return false }
        return replacementKeys.contains(replacementKey)
    }

    nonisolated static func articleReplacementKeys(in items: [FeedItem]) -> Set<String> {
        Set(items.compactMap(articleReplacementKey))
    }

    nonisolated static func isVisibleArticle(_ item: FeedItem) -> Bool {
        item.event.kind == FeedKindFilters.longFormArticle &&
            !item.event.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated static func articleReplacementKey(for item: FeedItem) -> String? {
        let displayEvent = item.displayEvent
        guard displayEvent.kind == FeedKindFilters.longFormArticle,
              let rawIdentifier = displayEvent.longFormArticleIndexMetadata?.identifier else {
            return nil
        }

        let identifier = rawIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !identifier.isEmpty else { return nil }

        let normalizedPubkey = displayEvent.pubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedPubkey.isEmpty else { return nil }

        return "\(displayEvent.kind)|\(normalizedPubkey)|\(identifier)"
    }

    private nonisolated static func preferredArticleReplacement(
        existing: FeedItem,
        incoming: FeedItem
    ) -> FeedItem {
        if articleEditComesAfter(incoming, existing) {
            return existing.merged(with: incoming)
        }

        return incoming.merged(with: existing)
    }

    private nonisolated static func articleEditComesAfter(
        _ lhs: FeedItem,
        _ rhs: FeedItem
    ) -> Bool {
        let lhsEvent = lhs.displayEvent
        let rhsEvent = rhs.displayEvent
        if lhsEvent.createdAt == rhsEvent.createdAt {
            return lhs.displayEventID.lowercased() > rhs.displayEventID.lowercased()
        }

        return lhsEvent.createdAt > rhsEvent.createdAt
    }

    private nonisolated static func comesBeforeInArticlesFeed(
        _ lhs: FeedItem,
        _ rhs: FeedItem
    ) -> Bool {
        let lhsPublishedAt = articlePublishedAt(for: lhs)
        let rhsPublishedAt = articlePublishedAt(for: rhs)
        if lhsPublishedAt == rhsPublishedAt {
            if lhs.displayEvent.createdAt == rhs.displayEvent.createdAt {
                return lhs.displayEventID.lowercased() > rhs.displayEventID.lowercased()
            }

            return lhs.displayEvent.createdAt > rhs.displayEvent.createdAt
        }

        return lhsPublishedAt > rhsPublishedAt
    }

    private nonisolated static func articlePublishedAt(for item: FeedItem) -> Int {
        item.displayEvent.longFormArticleIndexMetadata?.publishedAt ?? item.displayEvent.createdAt
    }
}
