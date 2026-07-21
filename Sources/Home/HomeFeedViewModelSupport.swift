import Foundation

extension HomeFeedViewModel {
    struct FeedRequestStrategy: Equatable {
        let fetchTimeout: TimeInterval
        let relayFetchMode: RelayFetchMode
    }

    struct TrendingPaginationState: Equatable {
        let archiveRangeIndex: Int
        let until: Int?
    }

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
        let followingAuthorsRevision: Int
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
        isInitialPage ? 1 : NostrFeedService.nostrArchivesTrendingBackfillRelayURLs.count
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
        case .following, .articles, .polls, .trending, .news:
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

    /// Updates an already-sorted feed slice without rebuilding and sorting the
    /// entire collection. Live relay subscriptions commonly deliver one event
    /// at a time, so insertion keeps that path linear in the small bounded
    /// buffer instead of repeatedly paying for whole-buffer sorts.
    nonisolated static func mergeSortedItemsIncrementally(
        incomingItems: [FeedItem],
        into existingItems: [FeedItem],
        feedSource: HomePrimaryFeedSource
    ) -> [FeedItem] {
        guard !incomingItems.isEmpty else { return existingItems }

        var mergedItems = existingItems
        for incomingItem in incomingItems {
            var canonicalItem = incomingItem

            if let matchingIDIndex = mergedItems.firstIndex(where: { $0.id == incomingItem.id }) {
                canonicalItem = mergedItems[matchingIDIndex].merged(with: incomingItem)
                mergedItems.remove(at: matchingIDIndex)
            }

            if feedSource == .articles,
               let replacementKey = articleReplacementKey(for: canonicalItem),
               let replacementIndex = mergedItems.firstIndex(where: {
                   articleReplacementKey(for: $0) == replacementKey
               }) {
                canonicalItem = preferredArticleReplacement(
                    existing: mergedItems[replacementIndex],
                    incoming: canonicalItem
                )
                mergedItems.remove(at: replacementIndex)
            }

            mergedItems.insert(
                canonicalItem,
                at: sortedInsertionIndex(
                    for: canonicalItem,
                    in: mergedItems,
                    feedSource: feedSource
                )
            )
        }

        return mergedItems
    }

    /// Linearly combines two sorted slices whose event IDs (and article
    /// replacement coordinates) are already disjoint. Callers split affected
    /// identities before using this helper, avoiding a growing dictionary and
    /// whole-feed sort at pagination boundaries.
    nonisolated static func mergeSortedDisjointItems(
        _ firstItems: [FeedItem],
        _ secondItems: [FeedItem],
        feedSource: HomePrimaryFeedSource,
        limit: Int? = nil
    ) -> [FeedItem] {
        let maximumCount = min(
            max(limit ?? (firstItems.count + secondItems.count), 0),
            firstItems.count + secondItems.count
        )
        guard maximumCount > 0 else { return [] }

        var mergedItems: [FeedItem] = []
        mergedItems.reserveCapacity(maximumCount)
        var firstIndex = 0
        var secondIndex = 0

        while mergedItems.count < maximumCount,
              firstIndex < firstItems.count,
              secondIndex < secondItems.count {
            if itemComesBefore(
                firstItems[firstIndex],
                secondItems[secondIndex],
                feedSource: feedSource
            ) {
                mergedItems.append(firstItems[firstIndex])
                firstIndex += 1
            } else {
                mergedItems.append(secondItems[secondIndex])
                secondIndex += 1
            }
        }

        if mergedItems.count < maximumCount, firstIndex < firstItems.count {
            let remainingCount = min(
                maximumCount - mergedItems.count,
                firstItems.count - firstIndex
            )
            mergedItems.append(contentsOf: firstItems[firstIndex..<(firstIndex + remainingCount)])
        }
        if mergedItems.count < maximumCount, secondIndex < secondItems.count {
            let remainingCount = min(
                maximumCount - mergedItems.count,
                secondItems.count - secondIndex
            )
            mergedItems.append(contentsOf: secondItems[secondIndex..<(secondIndex + remainingCount)])
        }

        return mergedItems
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

    private nonisolated static func sortedInsertionIndex(
        for item: FeedItem,
        in sortedItems: [FeedItem],
        feedSource: HomePrimaryFeedSource
    ) -> Int {
        var lowerBound = 0
        var upperBound = sortedItems.count

        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if itemComesBefore(sortedItems[midpoint], item, feedSource: feedSource) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        return lowerBound
    }

    private nonisolated static func itemComesBefore(
        _ lhs: FeedItem,
        _ rhs: FeedItem,
        feedSource: HomePrimaryFeedSource
    ) -> Bool {
        if feedSource == .articles {
            return comesBeforeInArticlesFeed(lhs, rhs)
        }

        if lhs.event.createdAt == rhs.event.createdAt {
            return lhs.id > rhs.id
        }
        return lhs.event.createdAt > rhs.event.createdAt
    }

    private nonisolated static func articlePublishedAt(for item: FeedItem) -> Int {
        item.displayEvent.longFormArticleIndexMetadata?.publishedAt ?? item.displayEvent.createdAt
    }
}
