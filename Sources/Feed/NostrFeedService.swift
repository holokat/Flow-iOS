import Foundation

struct NostrFeedService: Sendable {
    private let relayClient: any NostrRelayEventFetching
    private let timelineCache: any TimelineEventCaching
    private let profileCache: any ProfileCaching
    private let relayHintCache: any ProfileRelayHintCaching
    private let followListCache: any FollowListSnapshotStoring
    private let eventRepository: any EventRepositoryStoring
    private let presentationCache: FeedPresentationCache
    private let outboxDiagnosticsStore: OutboxRecoveryDiagnosticsStore
    private let relayTimelineFetcher: RelayTimelineFetcher
    nonisolated static let nostrArchivesSearchRelayURL = URL(string: "wss://search.nostrarchives.com")!
    nonisolated static let nostrArchivesTrendingRelayURL = URL(string: "wss://feeds.nostrarchives.com/notes/trending/reactions/today")!
    private static let trendingRelayURL = nostrArchivesTrendingRelayURL
    private static let followListFreshCacheAge: TimeInterval = 60 * 5
    private static let profileBackfillBatchSize = 24
    private static let metadataFallbackRelayURLs: [URL] = [
        URL(string: "wss://relay.damus.io/")!,
        URL(string: "wss://relay.primal.net/")!,
        URL(string: "wss://relay.nostr.band/")!,
        URL(string: "wss://relay.snort.social/")!,
        URL(string: "wss://nostr.wine/")!,
        URL(string: "wss://nos.lol/")!
    ]

    init(
        relayClient: any NostrRelayEventFetching = NostrRelayClient(),
        timelineCache: any TimelineEventCaching = TimelineEventCache.shared,
        profileCache: any ProfileCaching = ProfileCache.shared,
        relayHintCache: any ProfileRelayHintCaching = ProfileRelayHintCache.shared,
        followListCache: any FollowListSnapshotStoring = FollowListSnapshotCache.shared,
        eventRepository: any EventRepositoryStoring = EventRepository.shared,
        presentationCache: FeedPresentationCache = .shared,
        outboxDiagnosticsStore: OutboxRecoveryDiagnosticsStore = .shared
    ) {
        self.relayClient = relayClient
        self.timelineCache = timelineCache
        self.profileCache = profileCache
        self.relayHintCache = relayHintCache
        self.followListCache = followListCache
        self.eventRepository = eventRepository
        self.presentationCache = presentationCache
        self.outboxDiagnosticsStore = outboxDiagnosticsStore
        self.relayTimelineFetcher = RelayTimelineFetcher(
            relayClient: relayClient,
            timelineCache: timelineCache,
            eventRepository: eventRepository
        )
    }

    private var feedItemBuilder: FeedItemBuilder {
        FeedItemBuilder(
            profileCache: profileCache,
            eventRepository: eventRepository,
            presentationCache: presentationCache,
            fetchProfiles: { relayURLs, pubkeys, fetchTimeout, relayFetchMode in
                await self.profileResolver.fetchProfiles(
                    relayURLs: relayURLs,
                    pubkeys: pubkeys,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode
                )
            },
            resolveReferences: { pointersByKey, baseReadRelayURLs in
                await self.referenceResolver.fetchResolvedReferenceEvents(
                    pointersByKey: pointersByKey,
                    baseReadRelayURLs: baseReadRelayURLs
                )
            },
            makeRepostReferencePointer: { targetEventID, sourceEvent in
                self.referenceResolver.referencePointerForRepostTarget(
                    targetEventID: targetEventID,
                    sourceEvent: sourceEvent
                )
            },
            makeReplyReferencePointer: { targetEventID, sourceEvent in
                self.referenceResolver.referencePointerForReplyTarget(
                    targetEventID: targetEventID,
                    sourceEvent: sourceEvent
                )
            }
        )
    }

    private var profileResolver: NostrProfileResolver {
        NostrProfileResolver(
            profileCache: profileCache,
            relayHintCache: relayHintCache,
            relayTimelineFetcher: relayTimelineFetcher,
            nostrArchivesSearchRelayURL: Self.nostrArchivesSearchRelayURL,
            metadataFallbackRelayURLs: Self.metadataFallbackRelayURLs
        )
    }

    private var followResolver: NostrFollowResolver {
        NostrFollowResolver(
            relayClient: relayClient,
            relayTimelineFetcher: relayTimelineFetcher,
            followListCache: followListCache,
            relayHintCache: relayHintCache,
            eventRepository: eventRepository,
            outboxDiagnosticsStore: outboxDiagnosticsStore,
            metadataFallbackRelayURLs: Self.metadataFallbackRelayURLs,
            followListFreshCacheAge: Self.followListFreshCacheAge
        )
    }

    private var discoveryFeedResolver: NostrDiscoveryFeedResolver {
        NostrDiscoveryFeedResolver(
            relayTimelineFetcher: relayTimelineFetcher,
            nostrArchivesSearchRelayURL: Self.nostrArchivesSearchRelayURL,
            trendingRelayURL: Self.trendingRelayURL,
            metadataFallbackRelayURLs: Self.metadataFallbackRelayURLs,
            buildFeedItems: { relayURLs, events, hydrationMode, moderationSnapshot in
                await self.buildFeedItems(
                    relayURLs: relayURLs,
                    events: events,
                    hydrationMode: hydrationMode,
                    moderationSnapshot: moderationSnapshot
                )
            },
            buildCachedFeedItems: { events, moderationSnapshot in
                await self.buildCachedFeedItems(
                    events: events,
                    moderationSnapshot: moderationSnapshot
                )
            },
            buildAuthorOnlyFeedItems: { relayURLs, events, moderationSnapshot in
                await self.buildAuthorOnlyFeedItems(
                    relayURLs: relayURLs,
                    events: events,
                    moderationSnapshot: moderationSnapshot
                )
            }
        )
    }

    private var referenceResolver: NostrReferenceResolver {
        NostrReferenceResolver(
            relayTimelineFetcher: relayTimelineFetcher,
            eventRepository: eventRepository,
            resolveOutboxRelayPlan: { authors, baseReadRelayURLs, seedHintRelayURLsByPubkey in
                await self.followResolver.outboxBackedRelayPlan(
                    authors: authors,
                    baseReadRelayURLs: baseReadRelayURLs,
                    seedHintRelayURLsByPubkey: seedHintRelayURLsByPubkey
                )
            },
            buildFeedItems: { relayURLs, events, hydrationMode, moderationSnapshot in
                await self.buildFeedItems(
                    relayURLs: relayURLs,
                    events: events,
                    hydrationMode: hydrationMode,
                    moderationSnapshot: moderationSnapshot
                )
            }
        )
    }

    private var activityRowBuilder: ActivityRowBuilder {
        ActivityRowBuilder(
            relayTimelineFetcher: relayTimelineFetcher,
            profileCache: profileCache,
            eventRepository: eventRepository,
            resolveReferences: { pointersByReference, baseReadRelayURLs, fetchTimeout, relayFetchMode in
                await self.referenceResolver.fetchResolvedReferenceEvents(
                    pointersByKey: pointersByReference,
                    baseReadRelayURLs: baseReadRelayURLs,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode
                )
            }
        )
    }

    func outboxDiagnostics() async -> OutboxRecoveryDiagnostics {
        await outboxDiagnosticsStore.snapshot()
    }

    func ingestLiveEvents(_ events: [NostrEvent]) async {
        guard !events.isEmpty else { return }
        await eventRepository.store(events: events)
    }

    func fetchLiveCatchUpEvents(
        relayURL: URL,
        filter: NostrFilter,
        since: Int,
        limit: Int = 200,
        timeout: TimeInterval = 4
    ) async -> [NostrEvent] {
        var catchUpFilter = filter
        catchUpFilter.since = max(since, 0)
        catchUpFilter.until = nil
        catchUpFilter.limit = max(catchUpFilter.limit ?? 0, limit)

        do {
            return try await relayTimelineFetcher.fetchTimelineEvents(
                relayURL: relayURL,
                filter: catchUpFilter,
                timeout: timeout,
                useCache: false
            )
        } catch {
            return []
        }
    }

    func fetchFeed(relayURL: URL, kinds: [Int], limit: Int, until: Int?) async throws -> [FeedItem] {
        try await fetchFeed(
            relayURLs: [relayURL],
            kinds: kinds,
            limit: limit,
            until: until
        )
    }

    func fetchFeed(
        relayURLs: [URL],
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
        let filter = NostrFilter(
            kinds: kinds,
            limit: fetchLimit,
            until: until
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
        return await buildFeedItems(
            relayURLs: relayURLs,
            events: timelineEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchFollowingFeed(
        relayURL: URL,
        authors: [String],
        kinds: [Int],
        limit: Int,
        until: Int?
    ) async throws -> [FeedItem] {
        try await fetchFollowingFeed(
            relayURLs: [relayURL],
            authors: authors,
            kinds: kinds,
            limit: limit,
            until: until
        )
    }

    func fetchFollowingFeed(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool = false,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        let timelineEvents = try await fetchFollowingEvents(
            relayURLs: relayURLs,
            authors: authors,
            kinds: kinds,
            limit: limit,
            until: until,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            relayOnly: relayOnly,
            moderationSnapshot: moderationSnapshot
        )
        return await buildFeedItems(
            relayURLs: relayURLs,
            events: timelineEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchFollowingEvents(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        limit: Int,
        until: Int?,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool = false,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [NostrEvent] {
        guard limit > 0 else { return [] }
        let normalizedAuthors = normalizedUniquePubkeys(authors)
        guard !normalizedAuthors.isEmpty else { return [] }

        let kindsSet = Set(kinds)
        let authorBatches = normalizedAuthors.chunked(into: 250)
        let perBatchLimit = min(
            expandedTimelineLimit(for: max(limit, 50), moderationSnapshot: moderationSnapshot),
            240
        )

        let fetchedEventsResult: (events: [NostrEvent], successfulBatches: Int, firstError: Error?) = await withTaskGroup(
            of: (events: [NostrEvent]?, error: Error?).self,
            returning: (events: [NostrEvent], successfulBatches: Int, firstError: Error?).self
        ) { group in
            for batch in authorBatches {
                group.addTask {
                    let filter = NostrFilter(
                        authors: batch,
                        kinds: kinds,
                        limit: perBatchLimit,
                        until: until
                    )

                    do {
                        let events = try await relayTimelineFetcher.fetchTimelineEvents(
                            relayURLs: relayURLs,
                            filter: filter,
                            timeout: fetchTimeout,
                            useCache: false,
                            relayFetchMode: relayFetchMode,
                            relayOnly: relayOnly
                        )
                        return (events: events, error: nil)
                    } catch {
                        return (events: nil, error: error)
                    }
                }
            }

            var merged: [NostrEvent] = []
            var successfulBatches = 0
            var firstError: Error?

            for await result in group {
                if let batchEvents = result.events {
                    successfulBatches += 1
                    merged.append(contentsOf: batchEvents)

                    if relayFetchMode == .firstRelayWithEvents, merged.count >= limit {
                        group.cancelAll()
                        break
                    }
                } else if firstError == nil, let error = result.error {
                    firstError = error
                }
            }

            return (merged, successfulBatches, firstError)
        }

        if fetchedEventsResult.events.isEmpty,
           fetchedEventsResult.successfulBatches == 0,
           let firstError = fetchedEventsResult.firstError {
            throw firstError
        }

        let fetchedEvents = fetchedEventsResult.events
            .filter { kindsSet.contains($0.kind) }
        let visibleEvents = filterVisibleEvents(fetchedEvents, moderationSnapshot: moderationSnapshot)
        return Array(
            deduplicateEvents(visibleEvents)
                .sorted(by: { $0.createdAt > $1.createdAt })
                .prefix(limit)
        )
    }

    func fetchFollowingFeedRecoveringWithOutbox(
        baseReadRelayURLs: [URL],
        authors: [String],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        try await fetchOutboxBackedFollowingFeed(
            baseReadRelayURLs: baseReadRelayURLs,
            authors: authors,
            kinds: kinds,
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchOlderAuthorWindows(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        untilByAuthor: [String: Int?],
        perAuthorLimit: Int,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [String: [NostrEvent]] {
        let normalizedAuthors = normalizedUniquePubkeys(authors)
        let kindsSet = Set(kinds)
        let clampedLimit = max(perAuthorLimit, 1)

        guard !normalizedAuthors.isEmpty, !kindsSet.isEmpty else {
            return [:]
        }

        let windowsByAuthor = await withTaskGroup(
            of: (pubkey: String, events: [NostrEvent]).self,
            returning: [String: [NostrEvent]].self
        ) { group in
            for author in normalizedAuthors {
                group.addTask {
                    let filter = NostrFilter(
                        authors: [author],
                        kinds: Array(kindsSet),
                        limit: clampedLimit,
                        until: untilByAuthor[author] ?? nil
                    )

                    guard let events = try? await relayTimelineFetcher.fetchTimelineEventsFromRelaysOnly(
                        relayURLs: relayURLs,
                        filter: filter,
                        timeout: fetchTimeout,
                        useCache: false,
                        relayFetchMode: relayFetchMode
                    ) else {
                        return (author, [])
                    }

                    let windowEvents = Array(
                        deduplicateEvents(events)
                            .filter { kindsSet.contains($0.kind) }
                            .sorted(by: { lhs, rhs in
                                if lhs.createdAt == rhs.createdAt {
                                    return lhs.id > rhs.id
                                }
                                return lhs.createdAt > rhs.createdAt
                            })
                            .prefix(clampedLimit)
                    )
                    return (author, windowEvents)
                }
            }

            var windowsByAuthor: [String: [NostrEvent]] = [:]
            var collected: [NostrEvent] = []

            for await result in group {
                windowsByAuthor[result.pubkey] = result.events
                collected.append(contentsOf: result.events)
            }

            if !collected.isEmpty {
                await eventRepository.store(events: deduplicateEvents(collected))
            }

            return windowsByAuthor
        }

        return windowsByAuthor
    }

    func fetchFollowings(relayURL: URL, pubkey: String) async throws -> [String] {
        try await followResolver.fetchFollowings(relayURL: relayURL, pubkey: pubkey)
    }

    func fetchFollowings(
        relayURLs: [URL],
        pubkey: String,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [String] {
        try await followResolver.fetchFollowings(
            relayURLs: relayURLs,
            pubkey: pubkey,
            relayFetchMode: relayFetchMode
        )
    }

    func fetchFollowings(
        relayURLs: [URL],
        pubkey: String,
        relayFetchMode: RelayFetchMode,
        relayOnly: Bool,
        fallbackToCachedSnapshot: Bool
    ) async throws -> [String] {
        try await followResolver.fetchFollowings(
            relayURLs: relayURLs,
            pubkey: pubkey,
            relayFetchMode: relayFetchMode,
            relayOnly: relayOnly,
            fallbackToCachedSnapshot: fallbackToCachedSnapshot
        )
    }

    func fetchKnownFollowers(
        relayURLs: [URL],
        profilePubkey: String,
        candidatePubkeys: [String],
        limit: Int = 5,
        fetchTimeout: TimeInterval = 4,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [String] {
        await followResolver.fetchKnownFollowers(
            relayURLs: relayURLs,
            profilePubkey: profilePubkey,
            candidatePubkeys: candidatePubkeys,
            limit: limit,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    func cachedKnownFollowers(
        profilePubkey: String,
        candidatePubkeys: [String],
        limit: Int = 5
    ) async -> [String] {
        await followResolver.cachedKnownFollowers(
            profilePubkey: profilePubkey,
            candidatePubkeys: candidatePubkeys,
            limit: limit
        )
    }

    func cachedFollowListSnapshot(pubkey: String) async -> FollowListSnapshot? {
        await followResolver.cachedFollowListSnapshot(pubkey: pubkey)
    }

    func storeFollowListSnapshotLocally(_ snapshot: FollowListSnapshot, for pubkey: String) async {
        await followResolver.storeFollowListSnapshotLocally(snapshot, for: pubkey)
    }

    func fetchFollowListSnapshot(relayURL: URL, pubkey: String) async throws -> FollowListSnapshot? {
        try await followResolver.fetchFollowListSnapshot(relayURL: relayURL, pubkey: pubkey)
    }

    func fetchFollowListSnapshot(
        relayURLs: [URL],
        pubkey: String,
        fetchTimeout: TimeInterval = 10,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool = false,
        fallbackToCachedSnapshot: Bool = true
    ) async throws -> FollowListSnapshot? {
        try await followResolver.fetchFollowListSnapshot(
            relayURLs: relayURLs,
            pubkey: pubkey,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            relayOnly: relayOnly,
            fallbackToCachedSnapshot: fallbackToCachedSnapshot
        )
    }

    func fetchAuthorFeed(
        relayURL: URL,
        authorPubkey: String,
        kinds: [Int],
        limit: Int,
        until: Int?
    ) async throws -> [FeedItem] {
        try await fetchAuthorFeed(
            relayURLs: [relayURL],
            authorPubkey: authorPubkey,
            kinds: kinds,
            limit: limit,
            until: until
        )
    }

    func fetchAuthorFeed(
        relayURLs: [URL],
        authorPubkey: String,
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool = false,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        let timelineEvents = try await fetchAuthorEvents(
            relayURLs: relayURLs,
            authorPubkey: authorPubkey,
            kinds: kinds,
            limit: limit,
            until: until,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            relayOnly: relayOnly,
            moderationSnapshot: moderationSnapshot
        )
        return await buildFeedItems(
            relayURLs: relayURLs,
            events: timelineEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchAuthorEvents(
        relayURLs: [URL],
        authorPubkey: String,
        kinds: [Int],
        limit: Int,
        until: Int?,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool = false,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [NostrEvent] {
        guard limit > 0 else { return [] }
        let fetchLimit = expandedTimelineLimit(for: limit, moderationSnapshot: moderationSnapshot)
        let filter = NostrFilter(
            authors: [authorPubkey],
            kinds: kinds,
            limit: fetchLimit,
            until: until
        )

        let kindsSet = Set(kinds)
        let fetchedEvents = try await relayTimelineFetcher.fetchTimelineEvents(
            relayURLs: relayURLs,
            filter: filter,
            timeout: fetchTimeout,
            useCache: false,
            relayFetchMode: relayFetchMode,
            relayOnly: relayOnly
        )
            .filter { kindsSet.contains($0.kind) }
        let visibleEvents = filterVisibleEvents(fetchedEvents, moderationSnapshot: moderationSnapshot)
        let timelineEvents = Array(
            deduplicateEvents(visibleEvents)
                .sorted(by: { $0.createdAt > $1.createdAt })
                .prefix(limit)
        )
        return timelineEvents
    }

    func outboxBackedRelayPlan(
        authors: [String],
        baseReadRelayURLs: [URL],
        seedHintRelayURLsByPubkey: [String: [URL]] = [:]
    ) async -> AuthorRelayPlan {
        await followResolver.outboxBackedRelayPlan(
            authors: authors,
            baseReadRelayURLs: baseReadRelayURLs,
            seedHintRelayURLsByPubkey: seedHintRelayURLsByPubkey
        )
    }

    func refreshAuthorRelayDirectory(
        relayURLs: [URL],
        pubkey: String
    ) async {
        await followResolver.refreshAuthorRelayDirectory(relayURLs: relayURLs, pubkey: pubkey)
    }

    func fetchOutboxBackedAuthorFeed(
        baseReadRelayURLs: [URL],
        authorPubkey: String,
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        let normalizedAuthor = normalizePubkey(authorPubkey)
        guard !normalizedAuthor.isEmpty else { return [] }

        let relayPlan = await outboxBackedRelayPlan(
            authors: [normalizedAuthor],
            baseReadRelayURLs: baseReadRelayURLs
        )
        let effectiveRelayFetchMode: RelayFetchMode =
            relayFetchMode == .firstRelayWithEvents ? .firstNonEmptyRelay : relayFetchMode

        return try await fetchAuthorFeed(
            relayURLs: relayPlan.relayURLs(for: normalizedAuthor),
            authorPubkey: normalizedAuthor,
            kinds: kinds,
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: effectiveRelayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchOutboxBackedFollowingFeed(
        baseReadRelayURLs: [URL],
        authors: [String],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        guard limit > 0 else { return [] }

        let normalizedAuthors = normalizedUniquePubkeys(authors)
        guard !normalizedAuthors.isEmpty else { return [] }

        let relayPlan = await outboxBackedRelayPlan(
            authors: normalizedAuthors,
            baseReadRelayURLs: baseReadRelayURLs
        )
        let effectiveRelayFetchMode: RelayFetchMode =
            relayFetchMode == .firstRelayWithEvents ? .firstNonEmptyRelay : relayFetchMode

        let groupedAuthors = Dictionary(grouping: normalizedAuthors) { author in
            relayGroupKey(for: relayPlan.relayURLs(for: author))
        }

        let groupResults: (results: [(items: [FeedItem], relayURLs: [URL])], firstError: Error?) = await withTaskGroup(
            of: (items: [FeedItem]?, relayURLs: [URL], error: Error?).self,
            returning: (results: [(items: [FeedItem], relayURLs: [URL])], firstError: Error?).self
        ) { group in
            for (groupKey, groupAuthors) in groupedAuthors {
                let relayURLs = relayURLs(fromRelayGroupKey: groupKey)
                guard !relayURLs.isEmpty else { continue }

                group.addTask { [self] in
                    do {
                        let items = try await fetchFollowingFeed(
                            relayURLs: relayURLs,
                            authors: groupAuthors,
                            kinds: kinds,
                            limit: limit,
                            until: until,
                            hydrationMode: hydrationMode,
                            fetchTimeout: fetchTimeout,
                            relayFetchMode: effectiveRelayFetchMode,
                            moderationSnapshot: moderationSnapshot
                        )
                        return (items, relayURLs, nil)
                    } catch {
                        return (nil, relayURLs, error)
                    }
                }
            }

            var results: [(items: [FeedItem], relayURLs: [URL])] = []
            var firstError: Error?
            for await result in group {
                if let items = result.items {
                    results.append((items, result.relayURLs))
                } else if firstError == nil, let error = result.error {
                    firstError = error
                }
            }
            return (results, firstError)
        }

        var mergedItemsByID: [String: FeedItem] = [:]
        for result in groupResults.results {
            for item in result.items {
                mergedItemsByID[item.id.lowercased()] = item
            }
        }

        if mergedItemsByID.isEmpty, let firstError = groupResults.firstError {
            throw firstError
        }

        return Array(mergedItemsByID.values)
            .sorted(by: { lhs, rhs in
                if lhs.event.createdAt == rhs.event.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.event.createdAt > rhs.event.createdAt
            })
            .prefix(limit)
            .map { $0 }
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
        try await discoveryFeedResolver.searchNotes(
            relayURLs: relayURLs,
            query: query,
            kinds: kinds,
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func searchLocalNotes(
        query: String,
        kinds: [Int],
        limit: Int,
        until: Int? = nil,
        hydrationMode: FeedItemHydrationMode = .full,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await discoveryFeedResolver.searchLocalNotes(
            query: query,
            kinds: kinds,
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchReferencedFeedItem(
        reference: NostrEventReferencePointer,
        relayURLs: [URL],
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 8,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> FeedItem? {
        await referenceResolver.fetchReferencedFeedItem(
            reference: reference,
            relayURLs: relayURLs,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchReferencedEvents(
        references: [NostrEventReferencePointer],
        baseRelayURLs: [URL],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [NostrEventReferencePointer: NostrEvent] {
        await referenceResolver.fetchReferencedEvents(
            references: references,
            baseRelayURLs: baseRelayURLs,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    func fetchOutboxBackedReferencedEvents(
        references: [NostrEventReferencePointer],
        baseReadRelayURLs: [URL],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [NostrEventReferencePointer: NostrEvent] {
        await referenceResolver.fetchOutboxBackedReferencedEvents(
            references: references,
            baseReadRelayURLs: baseReadRelayURLs,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    func searchProfiles(
        query: String,
        limit: Int,
        preferredPubkeys: Set<String> = []
    ) async -> [ProfileSearchResult] {
        await profileResolver.searchProfiles(
            query: query,
            limit: limit,
            preferredPubkeys: preferredPubkeys
        )
    }

    func recentLocalProfiles(limit: Int) async -> [ProfileSearchResult] {
        await profileResolver.recentLocalProfiles(limit: limit)
    }

    func searchProfiles(
        relayURLs: [URL],
        query: String,
        limit: Int,
        fetchTimeout: TimeInterval = 10,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [ProfileSearchResult] {
        try await profileResolver.searchProfiles(
            relayURLs: relayURLs,
            query: query,
            limit: limit,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
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
        try await discoveryFeedResolver.fetchTrendingNotes(
            limit: limit,
            since: since,
            until: until,
            hydrationRelayURLs: hydrationRelayURLs,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchActivityRows(
        relayURL: URL,
        currentUserPubkey: String,
        filter: ActivityFilter = .all,
        limit: Int = 100
    ) async throws -> [ActivityRow] {
        try await fetchActivityRows(
            relayURLs: [relayURL],
            currentUserPubkey: currentUserPubkey,
            filter: filter,
            limit: limit
        )
    }

    func fetchActivityRows(
        relayURLs: [URL],
        currentUserPubkey: String,
        filter: ActivityFilter = .all,
        limit: Int = 100,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        profileFetchTimeout: TimeInterval = 8,
        profileRelayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [ActivityRow] {
        try await activityRowBuilder.fetchActivityRows(
            relayURLs: relayURLs,
            currentUserPubkey: currentUserPubkey,
            filter: filter,
            limit: limit,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            profileFetchTimeout: profileFetchTimeout,
            profileRelayFetchMode: profileRelayFetchMode
        )
    }

    func buildActivityRows(
        relayURLs: [URL],
        currentUserPubkey: String,
        events: [NostrEvent],
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        profileFetchTimeout: TimeInterval = 8,
        profileRelayFetchMode: RelayFetchMode = .allRelays
    ) async -> [ActivityRow] {
        await activityRowBuilder.buildActivityRows(
            relayURLs: relayURLs,
            currentUserPubkey: currentUserPubkey,
            events: events,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            profileFetchTimeout: profileFetchTimeout,
            profileRelayFetchMode: profileRelayFetchMode
        )
    }

    func fetchNoteActivityRows(
        relayURLs: [URL],
        rootEventID: String,
        limit: Int = 100,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        profileFetchTimeout: TimeInterval = 8,
        profileRelayFetchMode: RelayFetchMode = .allRelays,
        knownTargetPubkeysByEventID: [String: String] = [:]
    ) async throws -> [ActivityRow] {
        try await activityRowBuilder.fetchNoteActivityRows(
            relayURLs: relayURLs,
            rootEventID: rootEventID,
            limit: limit,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            profileFetchTimeout: profileFetchTimeout,
            profileRelayFetchMode: profileRelayFetchMode,
            knownTargetPubkeysByEventID: knownTargetPubkeysByEventID
        )
    }

    func fetchThreadNoteActivityRows(
        relayURLs: [URL],
        rootEventID: String,
        rootAuthorPubkey: String,
        limit: Int = 100,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        profileFetchTimeout: TimeInterval = 8,
        profileRelayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [ActivityRow] {
        try await activityRowBuilder.fetchThreadNoteActivityRows(
            relayURLs: relayURLs,
            rootEventID: rootEventID,
            rootAuthorPubkey: rootAuthorPubkey,
            limit: limit,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            profileFetchTimeout: profileFetchTimeout,
            profileRelayFetchMode: profileRelayFetchMode
        )
    }

    func buildNoteActivityRows(
        relayURLs: [URL],
        rootEventID: String,
        events: [NostrEvent],
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        profileFetchTimeout: TimeInterval = 8,
        profileRelayFetchMode: RelayFetchMode = .allRelays,
        knownTargetPubkeysByEventID: [String: String] = [:]
    ) async -> [ActivityRow] {
        await activityRowBuilder.buildNoteActivityRows(
            relayURLs: relayURLs,
            rootEventID: rootEventID,
            events: events,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            profileFetchTimeout: profileFetchTimeout,
            profileRelayFetchMode: profileRelayFetchMode,
            knownTargetPubkeysByEventID: knownTargetPubkeysByEventID
        )
    }

    func fetchHashtagFeed(
        relayURL: URL,
        hashtag: String,
        kinds: [Int],
        limit: Int,
        until: Int?
    ) async throws -> [FeedItem] {
        try await discoveryFeedResolver.fetchHashtagFeed(
            relayURL: relayURL,
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
        try await discoveryFeedResolver.fetchHashtagFeed(
            relayURLs: relayURLs,
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

    func fetchLocalHashtagFeed(
        hashtag: String,
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await discoveryFeedResolver.fetchLocalHashtagFeed(
            hashtag: hashtag,
            kinds: kinds,
            limit: limit,
            until: until,
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
        try await discoveryFeedResolver.fetchHashtagFeed(
            relayURLs: relayURLs,
            hashtags: hashtags,
            kinds: kinds,
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchThreadReplies(
        relayURL: URL,
        rootEventID: String,
        limit: Int = 150,
        includeNestedReplies: Bool = true
    ) async throws -> [FeedItem] {
        try await fetchThreadReplies(
            relayURLs: [relayURL],
            rootEventID: rootEventID,
            limit: limit,
            includeNestedReplies: includeNestedReplies
        )
    }

    func fetchThreadReplies(
        relayURLs: [URL],
        rootEventID: String,
        limit: Int = 150,
        includeNestedReplies: Bool = true,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> [FeedItem] {
        let fetchLimit = expandedTimelineLimit(for: limit, moderationSnapshot: moderationSnapshot)
        let directFilter = NostrFilter(
            kinds: [1, 1111, 1244],
            limit: fetchLimit,
            tagFilters: ["e": [rootEventID]]
        )

        let directReplies = try await relayTimelineFetcher.fetchTimelineEvents(
            relayURLs: relayURLs,
            filter: directFilter,
            timeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
            .filter { $0.id != rootEventID }
            .filter(\.isReplyNote)
            .filter { $0.references(eventID: rootEventID) }
        let directReplyIDs = Set(directReplies.map(\.id))

        var allReplies = directReplies
        if includeNestedReplies, !directReplyIDs.isEmpty {
            let nestedFilter = NostrFilter(
                kinds: [1, 1111, 1244],
                limit: fetchLimit,
                tagFilters: ["e": Array(directReplyIDs.prefix(60))]
            )
            let nestedReplies = (try? await relayTimelineFetcher.fetchTimelineEvents(
                relayURLs: relayURLs,
                filter: nestedFilter,
                timeout: fetchTimeout,
                relayFetchMode: relayFetchMode
            )) ?? []
            let relevantNested = nestedReplies
                .filter { $0.id != rootEventID }
                .filter(\.isReplyNote)
                .filter { event in
                    event.references(eventID: rootEventID) ||
                    event.eventReferenceIDs.contains(where: { directReplyIDs.contains($0) })
                }
            allReplies.append(contentsOf: relevantNested)
        }

        let uniqueEvents = deduplicateEvents(
            filterVisibleEvents(allReplies, moderationSnapshot: moderationSnapshot)
                .sorted(by: { $0.createdAt < $1.createdAt })
        )
        return await buildFeedItems(
            relayURLs: relayURLs,
            events: uniqueEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func fetchProfile(relayURL: URL, pubkey: String) async -> NostrProfile? {
        await fetchProfile(relayURLs: [relayURL], pubkey: pubkey)
    }

    func cachedProfile(pubkey: String) async -> NostrProfile? {
        await profileResolver.cachedProfile(pubkey: pubkey)
    }

    func cachedProfiles(pubkeys: [String]) async -> [String: NostrProfile] {
        await profileResolver.cachedProfiles(pubkeys: pubkeys)
    }

    func prewarmProfiles(
        relayURLs: [URL],
        pubkeys: [String],
        relayHintsByPubkey: [String: [URL]] = [:]
    ) async {
        await profileResolver.prewarmProfiles(
            relayURLs: relayURLs,
            pubkeys: pubkeys,
            relayHintsByPubkey: relayHintsByPubkey
        )
    }

    func fetchProfile(
        relayURLs: [URL],
        pubkey: String,
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> NostrProfile? {
        await profileResolver.fetchProfile(
            relayURLs: relayURLs,
            pubkey: pubkey,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    func fetchFollowingCount(relayURL: URL, pubkey: String) async -> Int {
        await followResolver.fetchFollowingCount(relayURL: relayURL, pubkey: pubkey)
    }

    func cachedFollowingCount(pubkey: String) async -> Int? {
        await followResolver.cachedFollowingCount(pubkey: pubkey)
    }

    func fetchFollowingCount(
        relayURLs: [URL],
        pubkey: String,
        fetchTimeout: TimeInterval = 10,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> Int {
        await followResolver.fetchFollowingCount(
            relayURLs: relayURLs,
            pubkey: pubkey,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    func fetchProfiles(relayURL: URL, pubkeys: [String]) async -> [String: NostrProfile] {
        await profileResolver.fetchProfiles(relayURLs: [relayURL], pubkeys: pubkeys)
    }

    func fetchProfiles(
        relayURLs: [URL],
        pubkeys: [String],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    ) async -> [String: NostrProfile] {
        await profileResolver.fetchProfiles(
            relayURLs: relayURLs,
            pubkeys: pubkeys,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    func refreshLatestReplaceablesForAuthors(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        perAuthorLimit: Int = 8,
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [NostrEvent] {
        let normalizedAuthors = normalizedUniquePubkeys(authors)
        let kindsSet = Set(kinds)
        let clampedPerAuthorLimit = max(perAuthorLimit, 1)

        guard !normalizedAuthors.isEmpty, !kindsSet.isEmpty else {
            return []
        }

        var collected: [NostrEvent] = []
        for batch in normalizedAuthors.chunked(into: 80) {
            let filter = NostrFilter(
                authors: batch,
                kinds: Array(kindsSet),
                limit: max(batch.count * clampedPerAuthorLimit, clampedPerAuthorLimit)
            )

            guard let batchEvents = try? await relayTimelineFetcher.fetchTimelineEventsFromRelaysOnly(
                relayURLs: relayURLs,
                filter: filter,
                timeout: fetchTimeout,
                useCache: false,
                relayFetchMode: relayFetchMode
            ) else {
                continue
            }

            collected.append(contentsOf: batchEvents)
        }

        let selected = newestReplaceableEvents(
            from: collected,
            kinds: kindsSet,
            authorPubkeys: Set(normalizedAuthors)
        )

        guard !selected.isEmpty else {
            return []
        }

        await eventRepository.store(events: selected)
        await hydrateReplaceableSideEffects(events: selected)
        return selected
    }

    func buildFeedItems(
        relayURL: URL,
        events: [NostrEvent],
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await buildFeedItems(
            relayURLs: [relayURL],
            events: events,
            moderationSnapshot: moderationSnapshot
        )
    }

    func buildFeedItems(
        relayURLs: [URL],
        events: [NostrEvent],
        hydrationMode: FeedItemHydrationMode = .full,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await feedItemBuilder.buildFeedItems(
            relayURLs: relayURLs,
            events: events,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    func buildAuthorHydratedFeedItems(
        relayURLs: [URL],
        events: [NostrEvent],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await feedItemBuilder.buildAuthorHydratedFeedItems(
            relayURLs: relayURLs,
            events: events,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
    }

    private func buildCachedFeedItems(
        events: [NostrEvent],
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await feedItemBuilder.buildCachedFeedItems(
            events: events,
            moderationSnapshot: moderationSnapshot
        )
    }

    private func buildAuthorOnlyFeedItems(
        relayURLs: [URL],
        events: [NostrEvent],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await feedItemBuilder.buildAuthorOnlyFeedItems(
            relayURLs: relayURLs,
            events: events,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
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

    private func filterVisibleFeedItems(
        _ items: [FeedItem],
        moderationSnapshot: MuteFilterSnapshot?
    ) -> [FeedItem] {
        guard let moderationSnapshot, moderationSnapshot.hasAnyRules else {
            return items
        }
        return items.filter { !moderationSnapshot.shouldHideAny(in: $0.moderationEvents) }
    }

    private func firstReplaceableIdentifier(in event: NostrEvent) -> String? {
        for tag in event.tags {
            guard let name = tag.first?.lowercased(), name == "d" else { continue }
            guard tag.count > 1 else { continue }
            let identifier = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !identifier.isEmpty {
                return identifier
            }
        }
        return nil
    }

    private func relayGroupKey(for relayURLs: [URL]) -> String {
        relayURLs
            .compactMap { RelayURLSupport.normalizedRelayURLString($0) }
            .joined(separator: "|")
    }

    private func relayURLs(fromRelayGroupKey key: String) -> [URL] {
        key
            .split(separator: "|")
            .compactMap { RelayURLSupport.normalizedURL(from: String($0)) }
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

    private func newestReplaceableEvents(
        from events: [NostrEvent],
        kinds: Set<Int>,
        authorPubkeys: Set<String>
    ) -> [NostrEvent] {
        guard !events.isEmpty, !kinds.isEmpty, !authorPubkeys.isEmpty else { return [] }

        let sorted = deduplicateEvents(events)
            .filter { event in
                kinds.contains(event.kind) && authorPubkeys.contains(normalizePubkey(event.pubkey))
            }
            .sorted(by: { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            })

        var selectedByKey: [String: NostrEvent] = [:]
        for event in sorted {
            let normalizedPubkey = normalizePubkey(event.pubkey)
            guard !normalizedPubkey.isEmpty else { continue }

            let identifier = firstReplaceableIdentifier(in: event) ?? ""
            let key = "\(event.kind)|\(normalizedPubkey)|\(identifier)"
            if selectedByKey[key] == nil {
                selectedByKey[key] = event
            }
        }

        return selectedByKey.values.sorted(by: { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        })
    }

    private func hydrateReplaceableSideEffects(events: [NostrEvent]) async {
        guard !events.isEmpty else { return }

        let newestProfiles = profileResolver.decodeNewestProfiles(from: events)
        if !newestProfiles.isEmpty {
            await profileCache.store(profiles: newestProfiles, missed: [])
        }

        for event in events where event.kind == 3 {
            let snapshot = FollowListSnapshot(
                content: event.content,
                tags: event.tags,
                createdAt: event.createdAt
            )
            await followResolver.storeFollowListSnapshotLocally(snapshot, for: event.pubkey)
        }
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

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedUniquePubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys {
            let normalized = normalizePubkey(pubkey)
            guard normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)

        var index = startIndex
        while index < endIndex {
            let nextIndex = Swift.min(index + size, endIndex)
            result.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }

        return result
    }
}
