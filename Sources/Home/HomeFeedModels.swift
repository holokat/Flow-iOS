import Foundation

enum HomeFeedPaginationDefaults {
    static let pageSize = 100
    static let prefetchTriggerDistance = 15
    static let spinnerTriggerDistance = 2
}

enum FeedPaginationHeuristic {
    static func shouldStopPaging(afterFetchedCount fetchedCount: Int) -> Bool {
        fetchedCount == 0
    }
}

enum HomeFeedMode: String, CaseIterable, Identifiable {
    case posts
    case postsAndReplies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts:
            return "Notes"
        case .postsAndReplies:
            return "Replies"
        }
    }

    func includes(_ item: FeedItem) -> Bool {
        switch self {
        case .posts:
            return !item.displayEvent.isReplyNote
        case .postsAndReplies:
            return item.displayEvent.isReplyNote
        }
    }
}

enum FeedMode: String, CaseIterable, Identifiable {
    case posts
    case postsAndReplies
    case articles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts:
            return "Notes"
        case .postsAndReplies:
            return "Replies"
        case .articles:
            return "Articles"
        }
    }
}

enum HomePrimaryFeedSource: Identifiable, Hashable {
    case network
    case following
    case articles
    case polls
    case trending
    case interests
    case news
    case custom(String)
    case hashtag(String)
    case relay(String)

    var id: String {
        switch self {
        case .network:
            return "network"
        case .following:
            return "following"
        case .articles:
            return "articles"
        case .polls:
            return "polls"
        case .trending:
            return "trending"
        case .interests:
            return "interests"
        case .news:
            return "news"
        case .custom(let feedID):
            return "custom:\(Self.normalizeCustomFeedID(feedID))"
        case .hashtag(let hashtag):
            return "hashtag:\(Self.normalizeHashtag(hashtag))"
        case .relay(let relayURL):
            return "relay:\(Self.normalizeRelayURLString(relayURL))"
        }
    }

    var storageValue: String {
        switch self {
        case .network:
            return "network"
        case .following:
            return "following"
        case .articles:
            return "articles"
        case .polls:
            return "polls"
        case .trending:
            return "trending"
        case .interests:
            return "interests"
        case .news:
            return "news"
        case .custom(let feedID):
            return "custom:\(Self.normalizeCustomFeedID(feedID))"
        case .hashtag(let hashtag):
            return "hashtag:\(Self.normalizeHashtag(hashtag))"
        case .relay(let relayURL):
            return "relay:\(Self.normalizeRelayURLString(relayURL))"
        }
    }

    init?(storageValue: String) {
        let normalized = storageValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized == "network" || normalized == "myrelays" {
            self = .network
            return
        }
        if normalized == "following" {
            self = .following
            return
        }
        if normalized == "articles" {
            self = .articles
            return
        }
        if normalized == "polls" {
            self = .polls
            return
        }
        if normalized == "trending" {
            self = .trending
            return
        }
        if normalized == "interests" {
            self = .interests
            return
        }
        if normalized == "news" {
            self = .news
            return
        }
        if normalized.hasPrefix("custom:") {
            let value = String(normalized.dropFirst("custom:".count))
            let feedID = Self.normalizeCustomFeedID(value)
            guard !feedID.isEmpty else { return nil }
            self = .custom(feedID)
            return
        }
        if normalized.hasPrefix("hashtag:") {
            let value = String(normalized.dropFirst("hashtag:".count))
            let hashtag = Self.normalizeHashtag(value)
            guard !hashtag.isEmpty else { return nil }
            self = .hashtag(hashtag)
            return
        }
        if normalized.hasPrefix("relay:") {
            let value = String(normalized.dropFirst("relay:".count))
            let relayURL = Self.normalizeRelayURLString(value)
            guard !relayURL.isEmpty else { return nil }
            self = .relay(relayURL)
            return
        }
        return nil
    }

    static func normalizeHashtag(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
    }

    static func normalizeCustomFeedID(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func normalizeRelayURLString(_ value: String) -> String {
        guard let relayURL = RelayURLSupport.normalizedURL(from: value),
              let normalized = RelayURLSupport.normalizedRelayURLString(relayURL) else {
            return ""
        }
        return normalized
    }
}

enum HomeFeedError: Error {
    case networkRequiresLogin
    case followingRequiresLogin
    case articlesRequiresLogin
    case pollsRequiresLogin
}

struct HomeFeedPageResult {
    let items: [FeedItem]
    let hadMoreAvailable: Bool
    let paginationCursor: Int?

    init(
        items: [FeedItem],
        hadMoreAvailable: Bool,
        paginationCursor: Int? = nil
    ) {
        self.items = items
        self.hadMoreAvailable = hadMoreAvailable
        self.paginationCursor = paginationCursor
    }
}

struct HomeFeedLiveSubscriptionTarget: Sendable {
    let relayURL: URL
    let filter: NostrFilter
    let signature: String
}

@MainActor
enum HomeFeedSourceResolver {
    private static let trendingRelayURL = NostrFeedService.nostrArchivesTrendingRelayURL
    private static let newsFallbackRelayURL = URL(string: "wss://news.utxo.one")!
    private static let customFeedSupplementalRelayURLs: [URL] = [
        URL(string: "wss://relay.damus.io/"),
        URL(string: "wss://nos.lol/"),
        URL(string: "wss://relay.nostr.band/"),
        URL(string: "wss://nostr.mom/"),
        NostrFeedService.nostrArchivesSearchRelayURL
    ].compactMap { $0 }

    static func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    static func normalizedFavoriteHashtags(_ hashtags: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for hashtag in hashtags {
            let normalized = HomePrimaryFeedSource.normalizeHashtag(hashtag)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    static func normalizedFavoriteRelayURLs(_ relayURLs: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for relayURL in relayURLs {
            let normalized = HomePrimaryFeedSource.normalizeRelayURLString(relayURL)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    static func normalizedOrderedPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys {
            let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    static func resolvedFeedSource(
        _ source: HomePrimaryFeedSource,
        favoriteHashtags: [String],
        favoriteRelayURLs: [String],
        interestHashtags: [String],
        customFeeds: [CustomFeedDefinition]
    ) -> HomePrimaryFeedSource {
        switch source {
        case .custom(let feedID):
            return customFeedDefinition(id: feedID, customFeeds: customFeeds) == nil ? .network : .custom(feedID)
        case .hashtag(let hashtag):
            let normalizedHashtag = HomePrimaryFeedSource.normalizeHashtag(hashtag)
            guard favoriteHashtags.contains(normalizedHashtag) else {
                return .network
            }
            return .hashtag(normalizedHashtag)
        case .relay(let relayURL):
            let normalizedRelayURL = HomePrimaryFeedSource.normalizeRelayURLString(relayURL)
            guard favoriteRelayURLs.contains(normalizedRelayURL) else {
                return .network
            }
            return .relay(normalizedRelayURL)
        case .polls:
            return AppSettingsStore.shared.pollsFeedVisible ? .polls : .network
        case .interests:
            return interestHashtags.isEmpty ? .network : .interests
        default:
            return source
        }
    }

    static func relayURLs(
        for source: HomePrimaryFeedSource,
        readRelayURLs: [URL]
    ) -> [URL] {
        switch source {
        case .trending:
            return [trendingRelayURL]
        case .news:
            let newsRelays = normalizedRelayURLs(AppSettingsStore.shared.newsRelayURLs)
            return newsRelays.isEmpty ? [newsFallbackRelayURL] : newsRelays
        case .custom:
            let combined = normalizedRelayURLs(readRelayURLs + customFeedSupplementalRelayURLs)
            return combined.isEmpty ? readRelayURLs : combined
        case .relay(let relayURL):
            guard let normalizedRelayURL = RelayURLSupport.normalizedURL(from: relayURL) else {
                return readRelayURLs
            }
            return [normalizedRelayURL]
        default:
            return readRelayURLs
        }
    }

    static func hydrationRelayURLs(
        for source: HomePrimaryFeedSource,
        readRelayURLs: [URL]
    ) -> [URL] {
        switch source {
        case .trending:
            let combined = normalizedRelayURLs(readRelayURLs + relayURLs(for: .trending, readRelayURLs: readRelayURLs))
            return combined.isEmpty ? [trendingRelayURL] : combined
        case .news:
            let combined = normalizedRelayURLs(readRelayURLs + relayURLs(for: .news, readRelayURLs: readRelayURLs))
            return combined.isEmpty ? [newsFallbackRelayURL] : combined
        case .custom:
            return relayURLs(for: source, readRelayURLs: readRelayURLs)
        case .relay:
            let combined = normalizedRelayURLs(readRelayURLs + relayURLs(for: source, readRelayURLs: readRelayURLs))
            return combined.isEmpty ? relayURLs(for: source, readRelayURLs: readRelayURLs) : combined
        default:
            return relayURLs(for: source, readRelayURLs: readRelayURLs)
        }
    }

    static func feedKinds(for source: HomePrimaryFeedSource, showKinds: [Int]) -> [Int] {
        switch source {
        case .interests, .custom, .network, .following, .hashtag, .relay:
            return FeedKindFilters.normalizedKinds(showKinds)
        case .articles:
            return [FeedKindFilters.longFormArticle]
        case .polls:
            return FeedKindFilters.pollKinds
        case .trending, .news:
            return [1]
        }
    }

    static func customFeedDefinition(
        id: String,
        customFeeds: [CustomFeedDefinition]
    ) -> CustomFeedDefinition? {
        let normalizedID = HomePrimaryFeedSource.normalizeCustomFeedID(id)
        guard !normalizedID.isEmpty else { return nil }
        return customFeeds.first { $0.id == normalizedID }
    }

    static func configuredNewsAuthorPubkeys() -> [String] {
        normalizedOrderedPubkeys(AppSettingsStore.shared.newsAuthorPubkeys)
    }

    static func configuredNewsHashtags() -> [String] {
        normalizedFavoriteHashtags(AppSettingsStore.shared.newsHashtags)
    }

    static func configuredInterestHashtags(_ interestHashtags: [String]) -> [String] {
        normalizedFavoriteHashtags(interestHashtags)
    }

    static func usesCompositePagination(_ source: HomePrimaryFeedSource) -> Bool {
        switch source {
        case .following, .articles, .polls, .news, .custom:
            return true
        default:
            return false
        }
    }
}

enum HomeFeedPageFetcher {
    static func mergeItemArrays(primary: [FeedItem], secondary: [FeedItem]) -> [FeedItem] {
        var byID: [String: FeedItem] = Dictionary(uniqueKeysWithValues: secondary.map { ($0.id, $0) })

        for item in primary {
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

    static func fetchInterestsFeedPage(
        service: NostrFeedService,
        relayTargets: [URL],
        kinds: [Int],
        hashtags: [String],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> HomeFeedPageResult {
        guard !hashtags.isEmpty else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let fetched = try await service.fetchHashtagFeed(
            relayURLs: relayTargets,
            hashtags: hashtags,
            kinds: kinds,
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        return HomeFeedPageResult(
            items: fetched,
            hadMoreAvailable: fetched.count >= limit
        )
    }

    static func fetchNewsFeedPage(
        service: NostrFeedService,
        newsRelayURLs: [URL],
        hydrationRelayURLs: [URL],
        authors: [String],
        hashtags: [String],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
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

        let relayItems = try await relayItemsTask
        let authorItems = try await authorItemsTask

        let hashtagItems: [[FeedItem]]
        if hashtags.isEmpty {
            hashtagItems = []
        } else {
            hashtagItems = try await withThrowingTaskGroup(of: [FeedItem].self) { group in
                for hashtag in hashtags {
                    group.addTask {
                        try await service.fetchHashtagFeed(
                            relayURLs: newsRelayURLs,
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

    static func fetchCustomFeedPage(
        service: NostrFeedService,
        feed: CustomFeedDefinition,
        relayTargets: [URL],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
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
            service: service,
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
            service: service,
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

    private static func fetchCustomFeedHashtagItems(
        service: NostrFeedService,
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

    private static func fetchCustomFeedPhraseItems(
        service: NostrFeedService,
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

@MainActor
enum HomeFeedLiveUpdatePlanner {
    static func subscriptionTargets(
        for source: HomePrimaryFeedSource,
        kinds: [Int],
        readRelayURLs: [URL],
        interestHashtags: [String],
        customFeeds: [CustomFeedDefinition],
        followingPubkeys: [String],
        currentUserPubkey: String?
    ) -> [HomeFeedLiveSubscriptionTarget] {
        switch source {
        case .network:
            return targets(
                relayURLs: HomeFeedSourceResolver.relayURLs(for: .network, readRelayURLs: readRelayURLs),
                filter: NostrFilter(kinds: kinds, limit: 100),
                scopeSignature: "network"
            )

        case .relay(let relayURL):
            let normalizedRelayURL = HomePrimaryFeedSource.normalizeRelayURLString(relayURL)
            guard !normalizedRelayURL.isEmpty else { return [] }
            return targets(
                relayURLs: HomeFeedSourceResolver.relayURLs(for: source, readRelayURLs: readRelayURLs),
                filter: NostrFilter(kinds: kinds, limit: 100),
                scopeSignature: "relay:\(normalizedRelayURL)"
            )

        case .trending:
            return []

        case .interests:
            let hashtags = HomeFeedSourceResolver.configuredInterestHashtags(interestHashtags)
            guard !hashtags.isEmpty else { return [] }
            return targets(
                relayURLs: HomeFeedSourceResolver.relayURLs(for: .interests, readRelayURLs: readRelayURLs),
                filter: NostrFilter(kinds: kinds, limit: 100, tagFilters: ["t": hashtags]),
                scopeSignature: "interests:\(hashtags.joined(separator: ","))"
            )

        case .news:
            var plannedTargets: [HomeFeedLiveSubscriptionTarget] = []

            let newsRelayTargets = HomeFeedSourceResolver.relayURLs(for: .news, readRelayURLs: readRelayURLs)
            plannedTargets.append(contentsOf: targets(
                relayURLs: newsRelayTargets,
                filter: NostrFilter(kinds: [1], limit: 100),
                scopeSignature: "news-relays"
            ))

            let authors = Array(HomeFeedSourceResolver.configuredNewsAuthorPubkeys().prefix(400))
            if !authors.isEmpty {
                let newsAuthorRelayTargets = HomeFeedSourceResolver.normalizedRelayURLs(newsRelayTargets + readRelayURLs)
                plannedTargets.append(contentsOf: targets(
                    relayURLs: newsAuthorRelayTargets,
                    filter: NostrFilter(authors: authors, kinds: [1], limit: 100),
                    scopeSignature: "news-authors:\(authors.joined(separator: ","))"
                ))
            }

            let hashtags = HomeFeedSourceResolver.configuredNewsHashtags()
            if !hashtags.isEmpty {
                plannedTargets.append(contentsOf: targets(
                    relayURLs: newsRelayTargets,
                    filter: NostrFilter(kinds: [1], limit: 100, tagFilters: ["t": hashtags]),
                    scopeSignature: "news-hashtags:\(hashtags.joined(separator: ","))"
                ))
            }

            return deduplicatedTargets(plannedTargets)

        case .custom(let feedID):
            guard let feed = HomeFeedSourceResolver.customFeedDefinition(id: feedID, customFeeds: customFeeds) else {
                return []
            }

            var plannedTargets: [HomeFeedLiveSubscriptionTarget] = []
            let relayTargets = HomeFeedSourceResolver.relayURLs(for: source, readRelayURLs: readRelayURLs)

            let authors = Array(feed.authorPubkeys.prefix(400))
            if !authors.isEmpty {
                plannedTargets.append(contentsOf: targets(
                    relayURLs: relayTargets,
                    filter: NostrFilter(authors: authors, kinds: kinds, limit: 100),
                    scopeSignature: "custom-authors:\(feedID):\(authors.joined(separator: ","))"
                ))
            }

            let hashtags = Array(feed.hashtags.prefix(40))
            if !hashtags.isEmpty {
                plannedTargets.append(contentsOf: targets(
                    relayURLs: relayTargets,
                    filter: NostrFilter(kinds: kinds, limit: 100, tagFilters: ["t": hashtags]),
                    scopeSignature: "custom-hashtags:\(feedID):\(hashtags.joined(separator: ","))"
                ))
            }

            return deduplicatedTargets(plannedTargets)

        case .hashtag(let hashtag):
            let normalizedHashtag = HomePrimaryFeedSource.normalizeHashtag(hashtag)
            guard !normalizedHashtag.isEmpty else { return [] }
            return targets(
                relayURLs: HomeFeedSourceResolver.relayURLs(for: source, readRelayURLs: readRelayURLs),
                filter: NostrFilter(kinds: kinds, limit: 100, tagFilters: ["t": [normalizedHashtag]]),
                scopeSignature: "hashtag:\(normalizedHashtag)"
            )

        case .following:
            let liveAuthors = Array(
                HomeFeedViewModel.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                .prefix(400)
            )
            .sorted()
            guard !liveAuthors.isEmpty else { return [] }
            return targets(
                relayURLs: HomeFeedSourceResolver.relayURLs(for: .following, readRelayURLs: readRelayURLs),
                filter: NostrFilter(authors: liveAuthors, kinds: kinds, limit: 100),
                scopeSignature: "following:\(liveAuthors.joined(separator: ","))"
            )

        case .articles:
            let liveAuthors = Array(
                HomeFeedViewModel.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                .prefix(400)
            )
            .sorted()
            guard !liveAuthors.isEmpty else { return [] }
            return targets(
                relayURLs: HomeFeedSourceResolver.relayURLs(for: .articles, readRelayURLs: readRelayURLs),
                filter: NostrFilter(authors: liveAuthors, kinds: [FeedKindFilters.longFormArticle], limit: 100),
                scopeSignature: "articles:\(liveAuthors.joined(separator: ","))"
            )

        case .polls:
            let liveAuthors = Array(
                HomeFeedViewModel.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                .prefix(400)
            )
            .sorted()
            guard !liveAuthors.isEmpty else { return [] }
            return targets(
                relayURLs: HomeFeedSourceResolver.relayURLs(for: .polls, readRelayURLs: readRelayURLs),
                filter: NostrFilter(authors: liveAuthors, kinds: FeedKindFilters.pollKinds, limit: 100),
                scopeSignature: "polls:\(liveAuthors.joined(separator: ","))"
            )
        }
    }

    private static func targets(
        relayURLs: [URL],
        filter: NostrFilter,
        scopeSignature: String
    ) -> [HomeFeedLiveSubscriptionTarget] {
        HomeFeedSourceResolver.normalizedRelayURLs(relayURLs).map { relayURL in
            HomeFeedLiveSubscriptionTarget(
                relayURL: relayURL,
                filter: filter,
                signature: "\(scopeSignature)|\(relayURL.absoluteString.lowercased())"
            )
        }
    }

    private static func deduplicatedTargets(
        _ targets: [HomeFeedLiveSubscriptionTarget]
    ) -> [HomeFeedLiveSubscriptionTarget] {
        var seen = Set<String>()
        var ordered: [HomeFeedLiveSubscriptionTarget] = []

        for target in targets {
            guard seen.insert(target.signature).inserted else { continue }
            ordered.append(target)
        }

        return ordered
    }
}
