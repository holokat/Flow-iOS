import Foundation

struct NostrDiscoveryFeedResolver: Sendable {
    private let relayTimelineFetcher: RelayTimelineFetcher
    private let nostrArchivesSearchRelayURL: URL
    private let trendingRelayURL: URL
    private let metadataFallbackRelayURLs: [URL]
    private let buildFeedItems: @Sendable ([URL], [NostrEvent], FeedItemHydrationMode, MuteFilterSnapshot?) async -> [FeedItem]
    private let buildCachedFeedItems: @Sendable ([NostrEvent], MuteFilterSnapshot?) async -> [FeedItem]
    private let buildAuthorOnlyFeedItems: @Sendable ([URL], [NostrEvent], MuteFilterSnapshot?) async -> [FeedItem]

    init(
        relayTimelineFetcher: RelayTimelineFetcher,
        nostrArchivesSearchRelayURL: URL,
        trendingRelayURL: URL,
        metadataFallbackRelayURLs: [URL],
        buildFeedItems: @escaping @Sendable ([URL], [NostrEvent], FeedItemHydrationMode, MuteFilterSnapshot?) async -> [FeedItem],
        buildCachedFeedItems: @escaping @Sendable ([NostrEvent], MuteFilterSnapshot?) async -> [FeedItem],
        buildAuthorOnlyFeedItems: @escaping @Sendable ([URL], [NostrEvent], MuteFilterSnapshot?) async -> [FeedItem]
    ) {
        self.relayTimelineFetcher = relayTimelineFetcher
        self.nostrArchivesSearchRelayURL = nostrArchivesSearchRelayURL
        self.trendingRelayURL = trendingRelayURL
        self.metadataFallbackRelayURLs = metadataFallbackRelayURLs
        self.buildFeedItems = buildFeedItems
        self.buildCachedFeedItems = buildCachedFeedItems
        self.buildAuthorOnlyFeedItems = buildAuthorOnlyFeedItems
    }

    func searchNotes(
        relayURLs: [URL],
        query: String,
        kinds: [Int],
        limit: Int,
        until: Int? = nil,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        guard limit > 0 else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }
        let shouldVerifyResults = shouldLocallyVerifyNIP50Results(for: normalizedQuery)
        let searchTerms = shouldVerifyResults ? normalizedSearchTerms(from: normalizedQuery) : []

        if shouldUseNostrArchivesRESTSearch(relayURLs: relayURLs) {
            let archivedEvents = (try? await NostrArchivesSearchService.shared.searchNotes(
                query: normalizedQuery,
                kinds: kinds,
                limit: limit
            )) ?? []
            if !archivedEvents.isEmpty {
                return await buildFeedItems(relayURLs, archivedEvents, hydrationMode, moderationSnapshot)
            }
        }

        let primarySearchLimit = expandedTimelineLimit(
            for: max(limit * 2, 120),
            moderationSnapshot: moderationSnapshot
        )
        let fallbackSearchLimit = min(
            expandedTimelineLimit(
                for: min(max(limit * 8, 220), 600),
                moderationSnapshot: moderationSnapshot
            ),
            600
        )

        let kindsSet = Set(kinds)
        let searchFilter = NostrFilter(
            kinds: kinds,
            search: normalizedQuery,
            limit: primarySearchLimit,
            until: until
        )

        var firstError: Error?
        var fetchedEvents: [NostrEvent] = []

        do {
            fetchedEvents = try await relayTimelineFetcher.fetchTimelineEvents(
                relayURLs: relayURLs,
                filter: searchFilter,
                timeout: fetchTimeout,
                useCache: false,
                relayFetchMode: relayFetchMode
            )
            .filter { event in
                guard kindsSet.contains(event.kind) else { return false }
                if let until, event.createdAt > until {
                    return false
                }
                guard shouldVerifyResults else { return true }
                return eventMatchesSearchTerms(event, terms: searchTerms)
            }
            fetchedEvents = filterVisibleEvents(fetchedEvents, moderationSnapshot: moderationSnapshot)
        } catch {
            firstError = error
        }

        if fetchedEvents.isEmpty {
            let fallbackFilter = NostrFilter(
                kinds: kinds,
                limit: fallbackSearchLimit,
                until: until
            )

            do {
                let fallbackEvents = try await relayTimelineFetcher.fetchTimelineEvents(
                    relayURLs: relayURLs,
                    filter: fallbackFilter,
                    timeout: fetchTimeout,
                    relayFetchMode: relayFetchMode
                )
                fetchedEvents = fallbackEvents.filter { event in
                    guard kindsSet.contains(event.kind) else { return false }
                    if let until, event.createdAt > until {
                        return false
                    }
                    guard shouldVerifyResults else { return true }
                    return eventMatchesSearchTerms(event, terms: searchTerms)
                }
                fetchedEvents = filterVisibleEvents(fetchedEvents, moderationSnapshot: moderationSnapshot)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if fetchedEvents.isEmpty, let firstError {
            throw firstError
        }

        let timelineEvents = Array(
            deduplicateEvents(fetchedEvents)
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .prefix(limit)
        )
        return await buildFeedItems(relayURLs, timelineEvents, hydrationMode, moderationSnapshot)
    }

    func searchLocalNotes(
        query: String,
        kinds: [Int],
        limit: Int,
        until: Int? = nil,
        hydrationMode: FeedItemHydrationMode = .full,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        let _ = query
        let _ = kinds
        let _ = limit
        let _ = until
        let _ = hydrationMode
        let _ = moderationSnapshot
        return []
    }

    func fetchTrendingNotes(
        limit: Int = 100,
        since: Int? = nil,
        until: Int? = nil,
        hydrationRelayURLs: [URL]? = nil,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        guard limit > 0 else { return [] }
        let cappedLimit = min(limit, 100)
        let _ = since
        let _ = until
        let fetchLimit = min(
            expandedTimelineLimit(for: cappedLimit, moderationSnapshot: moderationSnapshot),
            240
        )
        let filter = NostrFilter(
            kinds: [1],
            limit: fetchLimit
        )

        let fetchedEvents = try await relayTimelineFetcher.fetchTimelineEvents(
            relayURLs: [trendingRelayURL],
            filter: filter,
            timeout: fetchTimeout,
            useCache: false,
            relayFetchMode: relayFetchMode
        )
        .filter { $0.kind == 1 }
        let visibleEvents = filterVisibleEvents(fetchedEvents, moderationSnapshot: moderationSnapshot)
        let timelineEvents = Array(
            deduplicateEvents(visibleEvents)
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .prefix(cappedLimit)
        )

        switch hydrationMode {
        case .cachedProfilesOnly:
            return await buildCachedFeedItems(timelineEvents, moderationSnapshot)
        case .full:
            let authorRelayTargets = normalizedRelayURLs(
                (hydrationRelayURLs ?? []) + metadataFallbackRelayURLs + [trendingRelayURL]
            )
            return await buildAuthorOnlyFeedItems(authorRelayTargets, timelineEvents, moderationSnapshot)
        }
    }

    func fetchHashtagFeed(
        relayURL: URL,
        hashtag: String,
        kinds: [Int],
        limit: Int,
        until: Int?
    ) async throws -> [FeedItem] {
        try await fetchHashtagFeed(
            relayURLs: [relayURL],
            hashtag: hashtag,
            kinds: kinds,
            limit: limit,
            until: until
        )
    }

    func fetchHashtagFeed(
        relayURLs: [URL],
        hashtag: String,
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        guard limit > 0 else {
            return []
        }
        let fetchLimit = expandedTimelineLimit(for: limit, moderationSnapshot: moderationSnapshot)

        let normalizedHashtag = NostrEvent.normalizedHashtagValue(hashtag)
        guard !normalizedHashtag.isEmpty else {
            return []
        }

        let filter = NostrFilter(
            kinds: kinds,
            limit: fetchLimit,
            until: until,
            tagFilters: ["t": [normalizedHashtag]]
        )

        let kindsSet = Set(kinds)
        let fetchedEvents = try await relayTimelineFetcher.fetchTimelineEventsFromRelaysOnly(
            relayURLs: relayURLs,
            filter: filter,
            timeout: fetchTimeout,
            useCache: false,
            relayFetchMode: relayFetchMode
        )
            .filter { kindsSet.contains($0.kind) }
        let visibleEvents = filterVisibleEvents(fetchedEvents, moderationSnapshot: moderationSnapshot)
        let timelineEvents = Array(
            deduplicateEvents(visibleEvents)
                .sorted(by: { $0.createdAt > $1.createdAt })
                .prefix(limit)
        )
        return await buildFeedItems(relayURLs, timelineEvents, hydrationMode, moderationSnapshot)
    }

    func fetchLocalHashtagFeed(
        hashtag: String,
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        let _ = hashtag
        let _ = kinds
        let _ = limit
        let _ = until
        let _ = hydrationMode
        let _ = moderationSnapshot
        return []
    }

    func fetchHashtagFeed(
        relayURLs: [URL],
        hashtags: [String],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        guard limit > 0 else { return [] }
        let fetchLimit = expandedTimelineLimit(for: limit, moderationSnapshot: moderationSnapshot)

        let normalizedHashtags = Array(
            Set(
                hashtags
                    .map(NostrEvent.normalizedHashtagValue)
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalizedHashtags.isEmpty else { return [] }

        let filter = NostrFilter(
            kinds: kinds,
            limit: fetchLimit,
            until: until,
            tagFilters: ["t": normalizedHashtags]
        )

        let kindsSet = Set(kinds)
        let fetchedEvents = try await relayTimelineFetcher.fetchTimelineEventsFromRelaysOnly(
            relayURLs: relayURLs,
            filter: filter,
            timeout: fetchTimeout,
            useCache: false,
            relayFetchMode: relayFetchMode
        )
        .filter { event in
            guard kindsSet.contains(event.kind) else { return false }
            let eventHashtags = Set<String>(
                event.tags.compactMap { tag in
                    guard let name = tag.first?.lowercased(), name == "t", tag.count > 1 else { return nil }
                    return tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            )
            return !eventHashtags.isDisjoint(with: normalizedHashtags)
        }
        let visibleEvents = filterVisibleEvents(fetchedEvents, moderationSnapshot: moderationSnapshot)

        let timelineEvents = Array(
            deduplicateEvents(visibleEvents)
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .prefix(limit)
        )
        return await buildFeedItems(relayURLs, timelineEvents, hydrationMode, moderationSnapshot)
    }

    private func expandedTimelineLimit(
        for limit: Int,
        moderationSnapshot: MuteFilterSnapshot?
    ) -> Int {
        guard moderationSnapshot?.hasUserRules == true else { return limit }
        return min(max(limit * 4, limit), 240)
    }

    private func filterVisibleEvents(
        _ events: [NostrEvent],
        moderationSnapshot: MuteFilterSnapshot?
    ) -> [NostrEvent] {
        guard let moderationSnapshot, moderationSnapshot.hasAnyRules else {
            return events
        }
        return events.filter { !moderationSnapshot.shouldHide($0) }
    }

    private func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    private func normalizedSearchTerms(from query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func shouldLocallyVerifyNIP50Results(for query: String) -> Bool {
        !query.contains(":") && !query.contains("\"")
    }

    private func eventMatchesSearchTerms(_ event: NostrEvent, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let tagText = event.tags.flatMap { $0 }.joined(separator: " ")
        let haystack = "\(event.content) \(event.pubkey) \(event.id) \(tagText)"
            .lowercased()

        return terms.allSatisfy { haystack.contains($0) }
    }

    private func deduplicateEvents(_ events: [NostrEvent]) -> [NostrEvent] {
        var uniqueEvents: [NostrEvent] = []
        var seen = Set<String>()
        for event in events {
            let normalizedID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty, !seen.contains(normalizedID) else { continue }
            uniqueEvents.append(event)
            seen.insert(normalizedID)
        }
        return uniqueEvents
    }

    private func shouldUseNostrArchivesRESTSearch(relayURLs: [URL]) -> Bool {
        relayURLs.contains { relayURL in
            relayURL.host?.lowercased() == nostrArchivesSearchRelayURL.host?.lowercased()
        }
    }
}
