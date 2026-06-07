import Foundation

struct NostrDiscoveryFeedResolver: Sendable {
    private let relayTimelineFetcher: RelayTimelineFetcher
    private let nostrArchivesSearchRelayURL: URL
    private let trendingRelayURLs: [URL]
    private let metadataFallbackRelayURLs: [URL]
    private let buildFeedItems: @Sendable ([URL], [NostrEvent], FeedItemHydrationMode, MuteFilterSnapshot?) async -> [FeedItem]
    private let buildCachedFeedItems: @Sendable ([NostrEvent], MuteFilterSnapshot?) async -> [FeedItem]
    private let buildAuthorOnlyFeedItems: @Sendable ([URL], [NostrEvent], MuteFilterSnapshot?) async -> [FeedItem]

    init(
        relayTimelineFetcher: RelayTimelineFetcher,
        nostrArchivesSearchRelayURL: URL,
        trendingRelayURLs: [URL],
        metadataFallbackRelayURLs: [URL],
        buildFeedItems: @escaping @Sendable ([URL], [NostrEvent], FeedItemHydrationMode, MuteFilterSnapshot?) async -> [FeedItem],
        buildCachedFeedItems: @escaping @Sendable ([NostrEvent], MuteFilterSnapshot?) async -> [FeedItem],
        buildAuthorOnlyFeedItems: @escaping @Sendable ([URL], [NostrEvent], MuteFilterSnapshot?) async -> [FeedItem]
    ) {
        self.relayTimelineFetcher = relayTimelineFetcher
        self.nostrArchivesSearchRelayURL = nostrArchivesSearchRelayURL
        self.trendingRelayURLs = trendingRelayURLs
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
        guard limit > 0 else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

        let localLimit = localSearchProbeLimit(for: limit, moderationSnapshot: moderationSnapshot)
        let filter = NostrFilter(
            kinds: kinds,
            limit: localLimit,
            until: until
        )

        let terms = normalizedSearchTerms(from: normalizedQuery)
        let kindsSet = Set(kinds)
        let cachedEvents = FlowNostrDB.shared.queryEvents(filter: filter) ?? []
        let visibleEvents = filterVisibleEvents(cachedEvents, moderationSnapshot: moderationSnapshot)
        let timelineEvents = Array(
            deduplicateEvents(visibleEvents)
                .filter { event in
                    guard kindsSet.contains(event.kind) else { return false }
                    return eventMatchesSearchTerms(event, terms: terms)
                }
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .prefix(limit)
        )

        return await buildLocalFeedItems(
            timelineEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchTrendingNotes(
        limit: Int = 100,
        since: Int? = nil,
        until: Int? = nil,
        archiveRangeIndex: Int = 0,
        hydrationRelayURLs: [URL]? = nil,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        guard limit > 0 else { return [] }
        let cappedLimit = min(limit, 100)
        guard let trendingRelayURL = trendingRelayURL(at: archiveRangeIndex) else {
            return []
        }
        let fetchLimit = trendingProbeLimit(
            pageLimit: cappedLimit,
            moderationSnapshot: moderationSnapshot
        )
        let filter = NostrFilter(
            kinds: [1],
            limit: fetchLimit,
            since: since,
            until: until
        )

        let fetchedEvents = try await relayTimelineFetcher.fetchTimelineEvents(
            relayURLs: [trendingRelayURL],
            filter: filter,
            timeout: fetchTimeout,
            useCache: false,
            relayFetchMode: relayFetchMode
        )
        .filter { event in
            guard event.kind == 1 else { return false }
            if let since, event.createdAt < since {
                return false
            }
            if let until, event.createdAt > until {
                return false
            }
            return true
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
        guard limit > 0 else { return [] }
        let normalizedHashtag = NostrEvent.normalizedHashtagValue(hashtag)
        guard !normalizedHashtag.isEmpty else { return [] }

        let localLimit = localSearchProbeLimit(for: limit, moderationSnapshot: moderationSnapshot)
        let filter = NostrFilter(
            kinds: kinds,
            limit: localLimit,
            until: until,
            tagFilters: ["t": [normalizedHashtag]]
        )

        let kindsSet = Set(kinds)
        let cachedEvents = FlowNostrDB.shared.queryEvents(filter: filter) ?? []
        let visibleEvents = filterVisibleEvents(cachedEvents, moderationSnapshot: moderationSnapshot)
        let timelineEvents = Array(
            deduplicateEvents(visibleEvents)
                .filter { kindsSet.contains($0.kind) && event($0, containsHashtag: normalizedHashtag) }
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .prefix(limit)
        )

        return await buildLocalFeedItems(
            timelineEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
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

    private func localSearchProbeLimit(
        for limit: Int,
        moderationSnapshot: MuteFilterSnapshot?
    ) -> Int {
        min(max(expandedTimelineLimit(for: limit, moderationSnapshot: moderationSnapshot) * 10, 500), 2_000)
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

    private func event(_ event: NostrEvent, containsHashtag hashtag: String) -> Bool {
        event.tags.contains { tag in
            guard tag.count > 1,
                  tag[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "t" else {
                return false
            }
            return NostrEvent.normalizedHashtagValue(tag[1]) == hashtag
        }
    }

    private func buildLocalFeedItems(
        _ events: [NostrEvent],
        hydrationMode: FeedItemHydrationMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async -> [FeedItem] {
        guard !events.isEmpty else { return [] }

        switch hydrationMode {
        case .cachedProfilesOnly:
            return await buildCachedFeedItems(events, moderationSnapshot)
        case .full:
            return await buildFeedItems(
                metadataFallbackRelayURLs,
                events,
                hydrationMode,
                moderationSnapshot
            )
        }
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

    private func trendingRelayURL(at index: Int) -> URL? {
        guard !trendingRelayURLs.isEmpty else { return nil }
        guard index >= 0, index < trendingRelayURLs.count else { return nil }
        return trendingRelayURLs[index]
    }

    private func trendingProbeLimit(
        pageLimit: Int,
        moderationSnapshot: MuteFilterSnapshot?
    ) -> Int {
        let clampedPageLimit = max(1, pageLimit)
        let baselineProbeLimit = max(clampedPageLimit * 4, 100)
        return min(
            expandedTimelineLimit(
                for: baselineProbeLimit,
                moderationSnapshot: moderationSnapshot
            ),
            500
        )
    }
}
