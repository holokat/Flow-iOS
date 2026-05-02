import Foundation

struct HomeFeedPageFetching {
    private let service: NostrFeedService

    init(service: NostrFeedService) {
        self.service = service
    }

    func fetchTrendingFeedPage(
        hydrationRelayURLs: [URL],
        limit: Int,
        paginationState: HomeFeedViewModel.TrendingPaginationState?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedViewModel.TrendingPageFetchResult {
        guard limit > 0 else {
            return HomeFeedViewModel.TrendingPageFetchResult(
                page: HomeFeedPageResult(items: [], hadMoreAvailable: false),
                nextState: nil
            )
        }

        guard paginationState == nil else {
            return HomeFeedViewModel.TrendingPageFetchResult(
                page: HomeFeedPageResult(items: [], hadMoreAvailable: false),
                nextState: nil
            )
        }

        let pageItems = try await service.fetchTrendingNotes(
            limit: limit,
            hydrationRelayURLs: hydrationRelayURLs,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        return HomeFeedViewModel.TrendingPageFetchResult(
            page: HomeFeedPageResult(
                items: pageItems,
                hadMoreAvailable: false
            ),
            nextState: nil
        )
    }

    func fetchFollowingFeedPage(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        limit: Int,
        until: Int?,
        feedSource: HomePrimaryFeedSource? = nil,
        mode: HomeFeedMode? = nil,
        minimumVisibleCount: Int? = nil,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        guard limit > 0, !authors.isEmpty else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let targetVisibleCount = max(1, min(limit, minimumVisibleCount ?? limit))
        let maxBackfillRounds = minimumVisibleCount == nil
            ? 6
            : (targetVisibleCount >= limit ? 4 : 2)
        let probeLimit: Int
        if minimumVisibleCount != nil {
            probeLimit = min(max(targetVisibleCount * 4, 80), 160)
        } else {
            probeLimit = min(max(limit * 4, 120), 240)
        }
        var collected: [FeedItem] = []
        var cursor = until
        var exhausted = false
        var lastBatchCount = 0
        var roundsCompleted = 0
        var nextPageCursor: Int?
        let relayPlan = await service.outboxBackedRelayPlan(
            authors: authors,
            baseReadRelayURLs: relayURLs
        )

        while roundsCompleted < maxBackfillRounds {
            let qualifiedCount = mode.map { HomeFeedViewModel.visibleItemCount(collected, mode: $0) } ?? collected.count
            if qualifiedCount >= targetVisibleCount {
                break
            }

            let fetched = try await service.fetchFollowingFeedRecoveringWithOutbox(
                baseReadRelayURLs: relayURLs,
                authors: authors,
                relayPlan: relayPlan,
                kinds: kinds,
                limit: probeLimit,
                until: cursor,
                hydrationMode: hydrationMode,
                fetchTimeout: fetchTimeout,
                relayFetchMode: relayFetchMode,
                moderationSnapshot: moderationSnapshot
            )
            let fetchedEvents = fetched.map(\.event)
            lastBatchCount = fetchedEvents.count

            guard !fetchedEvents.isEmpty else {
                exhausted = true
                break
            }
            if let paginationCursor = feedPaginationCursor(from: fetchedEvents) {
                nextPageCursor = paginationCursor
            }

            collected = mergeItemArrays(
                primary: collected,
                secondary: fetched,
                feedSource: feedSource
            )

            let updatedQualifiedCount = mode.map {
                HomeFeedViewModel.visibleItemCount(collected, mode: $0)
            } ?? collected.count
            if updatedQualifiedCount >= targetVisibleCount {
                break
            }

            guard let paginationCursor = nextPageCursor else {
                exhausted = true
                break
            }

            let nextCursor = max(paginationCursor - 1, 0)
            guard nextCursor > 0, nextCursor != cursor else {
                exhausted = true
                break
            }

            cursor = nextCursor
            roundsCompleted += 1
        }

        let qualifiedCount = mode.map { HomeFeedViewModel.visibleItemCount(collected, mode: $0) } ?? collected.count
        let pageVisibleLimit = min(limit, max(qualifiedCount, 1))
        let pageItems = mode.map {
            HomeFeedViewModel.prefixForVisibleModeLimit(collected, mode: $0, visibleLimit: pageVisibleLimit)
        } ?? Array(collected.prefix(limit))
        let hadMoreAvailable =
            qualifiedCount > limit ||
            lastBatchCount >= probeLimit ||
            (!exhausted && !pageItems.isEmpty)

        return HomeFeedPageResult(
            items: pageItems,
            hadMoreAvailable: hadMoreAvailable,
            paginationCursor: nextPageCursor ?? pageItems.last?.event.createdAt
        )
    }

    func fetchModeAwarePrimaryFeedPage(
        source: HomePrimaryFeedSource,
        relayURLs: [URL],
        kinds: [Int],
        interestHashtags: [String],
        limit: Int,
        until: Int?,
        mode: HomeFeedMode?,
        minimumVisibleCount: Int,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        guard limit > 0 else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let maxBackfillRounds = minimumVisibleCount >= limit ? 4 : 2
        let targetVisibleCount = max(1, min(limit, minimumVisibleCount))
        let probeLimit = min(max(targetVisibleCount * 4, 60), 240)
        var collected: [FeedItem] = []
        var cursor = until
        var exhausted = false
        var lastBatchCount = 0
        var roundsCompleted = 0

        while roundsCompleted < maxBackfillRounds {
            let qualifiedCount = mode.map { HomeFeedViewModel.visibleItemCount(collected, mode: $0) } ?? collected.count
            if qualifiedCount >= targetVisibleCount {
                break
            }

            let fetched: [FeedItem]
            switch source {
            case .network, .relay:
                fetched = try await service.fetchFeed(
                    relayURLs: relayURLs,
                    kinds: kinds,
                    limit: probeLimit,
                    until: cursor,
                    hydrationMode: hydrationMode,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode,
                    moderationSnapshot: moderationSnapshot
                )
            case .hashtag(let hashtag):
                fetched = try await service.fetchHashtagFeed(
                    relayURLs: relayURLs,
                    hashtag: hashtag,
                    kinds: kinds,
                    limit: probeLimit,
                    until: cursor,
                    hydrationMode: hydrationMode,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode,
                    moderationSnapshot: moderationSnapshot
                )
            case .interests:
                guard !interestHashtags.isEmpty else {
                    return HomeFeedPageResult(items: [], hadMoreAvailable: false)
                }
                fetched = try await service.fetchHashtagFeed(
                    relayURLs: relayURLs,
                    hashtags: interestHashtags,
                    kinds: kinds,
                    limit: probeLimit,
                    until: cursor,
                    hydrationMode: hydrationMode,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode,
                    moderationSnapshot: moderationSnapshot
                )
            default:
                return HomeFeedPageResult(items: [], hadMoreAvailable: false)
            }

            lastBatchCount = fetched.count
            guard !fetched.isEmpty else {
                exhausted = true
                break
            }

            collected = mergeItemArrays(
                primary: collected,
                secondary: fetched,
                feedSource: source
            )

            let updatedQualifiedCount = mode.map {
                HomeFeedViewModel.visibleItemCount(collected, mode: $0)
            } ?? collected.count
            if updatedQualifiedCount >= targetVisibleCount || fetched.count >= probeLimit {
                break
            }

            guard let oldestFetchedCreatedAt = fetched.last?.event.createdAt else {
                exhausted = true
                break
            }

            let nextCursor = max(oldestFetchedCreatedAt - 1, 0)
            guard nextCursor > 0, nextCursor != cursor else {
                exhausted = true
                break
            }

            cursor = nextCursor
            roundsCompleted += 1
        }

        let qualifiedCount = mode.map { HomeFeedViewModel.visibleItemCount(collected, mode: $0) } ?? collected.count
        let pageVisibleLimit = min(limit, max(qualifiedCount, 1))
        let pageItems = mode.map {
            HomeFeedViewModel.prefixForVisibleModeLimit(
                collected,
                mode: $0,
                visibleLimit: pageVisibleLimit
            )
        } ?? Array(collected.prefix(limit))
        let hadMoreAvailable =
            qualifiedCount > limit ||
            lastBatchCount >= probeLimit ||
            (!exhausted && !pageItems.isEmpty)

        return HomeFeedPageResult(
            items: pageItems,
            hadMoreAvailable: hadMoreAvailable
        )
    }

    func fetchNewsFeedPage(
        newsRelayURLs: [URL],
        hydrationRelayURLs: [URL],
        authors: [String],
        hashtags: [String],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        let perHashtagLimit = hashtags.isEmpty ? 0 : max(8, min(18, limit))

        async let relayItemsTask = service.fetchFeed(
            relayURLs: newsRelayURLs,
            kinds: [1],
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        async let authorItemsTask = authors.isEmpty
            ? [FeedItem]()
            : service.fetchFollowingFeedRecoveringWithOutbox(
                baseReadRelayURLs: hydrationRelayURLs,
                authors: authors,
                kinds: [1],
                limit: limit,
                until: until,
                hydrationMode: hydrationMode,
                fetchTimeout: fetchTimeout,
                relayFetchMode: relayFetchMode,
                moderationSnapshot: moderationSnapshot
            )
        async let hashtagItemsTask = fetchNewsHashtagItems(
            relayURLs: newsRelayURLs,
            hashtags: hashtags,
            perHashtagLimit: perHashtagLimit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )

        let relayItems = try await relayItemsTask
        let authorItems = try await authorItemsTask
        let hashtagItems = try await hashtagItemsTask

        var seenEventIDs = Set<String>()
        let mergedEvents = Array(
            (relayItems + authorItems + hashtagItems.flatMap { $0 })
                .map(\.event)
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .filter { event in
                    seenEventIDs.insert(event.id.lowercased()).inserted
                }
        )

        let limitedEvents = Array(mergedEvents.prefix(limit))
        let hydrated = await service.buildFeedItems(
            relayURLs: hydrationRelayURLs,
            events: limitedEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )

        let hadMoreAvailable =
            relayItems.count >= limit ||
            (!authors.isEmpty && authorItems.count >= limit) ||
            hashtagItems.contains(where: { $0.count >= perHashtagLimit }) ||
            mergedEvents.count > limit

        return HomeFeedPageResult(
            items: hydrated,
            hadMoreAvailable: hadMoreAvailable
        )
    }

    func fetchCustomFeedPage(
        feed: CustomFeedDefinition,
        relayTargets: [URL],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        guard limit > 0 else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let authors = Array(feed.authorPubkeys.prefix(400))
        let hashtags = feed.hashtags
        let phrases = feed.phrases

        guard !authors.isEmpty || !hashtags.isEmpty || !phrases.isEmpty else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let perHashtagLimit = hashtags.isEmpty ? 0 : max(8, min(18, limit))
        let perPhraseLimit = phrases.isEmpty ? 0 : max(8, min(18, limit))

        async let authorItemsTask = authors.isEmpty
            ? [FeedItem]()
            : service.fetchFollowingFeed(
                relayURLs: relayTargets,
                authors: authors,
                kinds: kinds,
                limit: limit,
                until: until,
                hydrationMode: hydrationMode,
                fetchTimeout: fetchTimeout,
                relayFetchMode: relayFetchMode,
                relayOnly: true,
                moderationSnapshot: moderationSnapshot
            )
        async let hashtagItemsTask = fetchCustomFeedHashtagItems(
            hashtags: hashtags,
            relayTargets: relayTargets,
            kinds: kinds,
            limit: perHashtagLimit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        async let phraseItemsTask = fetchCustomFeedPhraseItems(
            phrases: phrases,
            relayTargets: relayTargets,
            kinds: kinds,
            limit: perPhraseLimit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )

        let authorItems = try await authorItemsTask
        let hashtagItems = try await hashtagItemsTask
        let phraseItems = try await phraseItemsTask

        let mergedItems = mergeItemArrays(
            primary: authorItems + hashtagItems.flatMap { $0 } + phraseItems.flatMap { $0 },
            secondary: []
        )

        let limitedItems = Array(mergedItems.prefix(limit))
        let hadMoreAvailable =
            (!authors.isEmpty && authorItems.count >= limit) ||
            hashtagItems.contains(where: { $0.count >= perHashtagLimit }) ||
            phraseItems.contains(where: { $0.count >= perPhraseLimit }) ||
            mergedItems.count > limit

        return HomeFeedPageResult(
            items: limitedItems,
            hadMoreAvailable: hadMoreAvailable
        )
    }

    private func mergeItemArrays(
        primary: [FeedItem],
        secondary: [FeedItem],
        feedSource: HomePrimaryFeedSource? = nil
    ) -> [FeedItem] {
        var byID: [String: FeedItem] = Dictionary(uniqueKeysWithValues: secondary.map { ($0.id, $0) })

        for item in primary {
            if let existing = byID[item.id] {
                byID[item.id] = existing.merged(with: item)
            } else {
                byID[item.id] = item
            }
        }

        return HomeFeedViewModel.sortedMergedItems(Array(byID.values), feedSource: feedSource)
    }

    private func fetchNewsHashtagItems(
        relayURLs: [URL],
        hashtags: [String],
        perHashtagLimit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [[FeedItem]] {
        guard !hashtags.isEmpty, perHashtagLimit > 0 else { return [] }

        let service = service
        return try await withThrowingTaskGroup(of: [FeedItem].self) { group in
            for hashtag in hashtags {
                group.addTask {
                    try await service.fetchHashtagFeed(
                        relayURLs: relayURLs,
                        hashtag: hashtag,
                        kinds: [1],
                        limit: perHashtagLimit,
                        until: until,
                        hydrationMode: hydrationMode,
                        fetchTimeout: fetchTimeout,
                        relayFetchMode: relayFetchMode,
                        moderationSnapshot: moderationSnapshot
                    )
                }
            }

            var merged: [[FeedItem]] = []
            for try await items in group {
                merged.append(items)
            }
            return merged
        }
    }

    private func fetchCustomFeedHashtagItems(
        hashtags: [String],
        relayTargets: [URL],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [[FeedItem]] {
        guard !hashtags.isEmpty, limit > 0 else { return [] }

        let service = service
        return try await withThrowingTaskGroup(of: [FeedItem].self) { group in
            for hashtag in hashtags {
                group.addTask {
                    try await service.fetchHashtagFeed(
                        relayURLs: relayTargets,
                        hashtag: hashtag,
                        kinds: kinds,
                        limit: limit,
                        until: until,
                        hydrationMode: hydrationMode,
                        fetchTimeout: fetchTimeout,
                        relayFetchMode: relayFetchMode,
                        moderationSnapshot: moderationSnapshot
                    )
                }
            }

            var merged: [[FeedItem]] = []
            for try await items in group {
                merged.append(items)
            }
            return merged
        }
    }

    private func fetchCustomFeedPhraseItems(
        phrases: [String],
        relayTargets: [URL],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [[FeedItem]] {
        guard !phrases.isEmpty, limit > 0 else { return [] }

        let service = service
        return try await withThrowingTaskGroup(of: [FeedItem].self) { group in
            for phrase in phrases {
                group.addTask {
                    let localItems = await service.searchLocalNotes(
                        query: phrase,
                        kinds: kinds,
                        limit: limit,
                        until: until,
                        hydrationMode: hydrationMode,
                        moderationSnapshot: moderationSnapshot
                    )

                    let remoteItems: [FeedItem]
                    do {
                        remoteItems = try await service.searchNotes(
                            relayURLs: relayTargets,
                            query: phrase,
                            kinds: kinds,
                            limit: limit,
                            until: until,
                            hydrationMode: hydrationMode,
                            fetchTimeout: fetchTimeout,
                            relayFetchMode: relayFetchMode,
                            moderationSnapshot: moderationSnapshot
                        )
                    } catch {
                        remoteItems = []
                    }

                    var byID: [String: FeedItem] = Dictionary(
                        uniqueKeysWithValues: remoteItems.map { ($0.id, $0) }
                    )

                    for item in localItems {
                        if let existing = byID[item.id] {
                            byID[item.id] = existing.merged(with: item)
                        } else {
                            byID[item.id] = item
                        }
                    }

                    return byID.values.sorted {
                        if $0.event.createdAt == $1.event.createdAt {
                            return $0.id > $1.id
                        }
                        return $0.event.createdAt > $1.event.createdAt
                    }
                }
            }

            var merged: [[FeedItem]] = []
            for try await items in group {
                merged.append(items)
            }
            return merged
        }
    }
}
