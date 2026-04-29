import Foundation
import NostrSDK

struct FollowListSnapshot: Codable, Sendable {
    let content: String
    let tags: [[String]]
    let createdAt: Int?

    init(content: String, tags: [[String]], createdAt: Int? = nil) {
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }

    var followedPubkeys: [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            guard let name = tag.first?.lowercased(), name == "p" else { return nil }
            guard tag.count > 1 else { return nil }
            let value = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { return nil }
            guard Self.isValidHexPubkey(value) else { return nil }
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    var nonPubkeyTags: [[String]] {
        tags.filter { tag in
            tag.first?.lowercased() != "p"
        }
    }

    var relayHintsByPubkey: [String: [URL]] {
        var hintsByPubkey: [String: [URL]] = [:]
        var seenByPubkey: [String: Set<String>] = [:]

        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "p" else { continue }
            guard tag.count > 1 else { continue }

            let pubkey = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.isValidHexPubkey(pubkey) else { continue }

            for candidate in tag.dropFirst(2) {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard trimmed.lowercased().hasPrefix("ws://") || trimmed.lowercased().hasPrefix("wss://") else {
                    continue
                }
                guard let url = URL(string: trimmed) else { continue }

                let normalizedURL = url.absoluteString.lowercased()
                if seenByPubkey[pubkey, default: []].insert(normalizedURL).inserted {
                    hintsByPubkey[pubkey, default: []].append(url)
                }
            }
        }

        return hintsByPubkey
    }

    private static func isValidHexPubkey(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

func feedPaginationCursor(from events: [NostrEvent]) -> Int? {
    guard !events.isEmpty else { return nil }

    let now = Int(Date().timeIntervalSince1970)
    let validEvents = events.filter { $0.createdAt <= now }
    let timestamps = (validEvents.isEmpty ? events : validEvents)
        .map(\.createdAt)
        .sorted(by: >)

    guard let newestTimestamp = timestamps.first else { return nil }
    guard timestamps.count > 1 else { return newestTimestamp }

    let minimumGapSeconds = 6 * 60 * 60
    for index in 0..<(timestamps.count - 1) {
        let gap = timestamps[index] - timestamps[index + 1]
        if gap >= minimumGapSeconds {
            return timestamps[index]
        }
    }

    return timestamps.last
}

struct ProfileSearchResult: Identifiable, Hashable, Sendable {
    let pubkey: String
    let profile: NostrProfile?
    let createdAt: Int

    var id: String { pubkey }
}

private enum ProfileSearchSupport {
    static func normalizedPubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func score(profile: NostrProfile, pubkey: String, query: String) -> Int? {
        let searchableFields = fields(for: profile)
        return score(
            searchableFields: searchableFields,
            searchTokens: Set(searchableFields.flatMap(tokens(from:))),
            pubkey: pubkey,
            query: query
        )
    }

    static func score(
        searchableFields: [String],
        searchTokens: Set<String>,
        pubkey: String,
        query: String
    ) -> Int? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }

        if pubkey == normalizedQuery {
            return 1_000
        }

        if pubkey.hasPrefix(normalizedQuery) {
            return 920
        }

        guard !searchableFields.isEmpty else { return nil }

        let queryTokens = tokens(from: normalizedQuery)

        if searchableFields.contains(normalizedQuery) {
            return 900
        }

        if searchTokens.contains(normalizedQuery) {
            return 860
        }

        if searchableFields.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 820
        }

        if searchTokens.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 780
        }

        if queryTokens.count > 1 {
            if queryTokens.allSatisfy(searchTokens.contains) {
                return 760
            }

            if queryTokens.allSatisfy({ queryToken in
                searchTokens.contains(where: { $0.hasPrefix(queryToken) })
            }) {
                return 720
            }
        }

        guard normalizedQuery.count >= 2 else { return nil }

        if searchableFields.contains(where: { $0.contains(normalizedQuery) }) {
            return 700
        }

        if searchTokens.contains(where: { $0.contains(normalizedQuery) }) {
            return 660
        }

        return nil
    }

    static func fields(for profile: NostrProfile) -> [String] {
        let rawFields: [String] = [
            profile.displayName,
            profile.name,
            profile.nip05,
            profile.lud16,
            profile.lud06
        ]
        .compactMap { value in
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return normalized.isEmpty ? nil : normalized
        }

        var expandedFields: [String] = []
        var seen = Set<String>()

        for field in rawFields {
            if seen.insert(field).inserted {
                expandedFields.append(field)
            }

            let compact = field.replacingOccurrences(of: " ", with: "")
            if !compact.isEmpty, seen.insert(compact).inserted {
                expandedFields.append(compact)
            }

            if field.hasPrefix("@") {
                let dropped = String(field.dropFirst())
                if !dropped.isEmpty, seen.insert(dropped).inserted {
                    expandedFields.append(dropped)
                }
            }

            if let atIndex = field.firstIndex(of: "@"), atIndex > field.startIndex {
                let localPart = String(field[..<atIndex])
                if !localPart.isEmpty, seen.insert(localPart).inserted {
                    expandedFields.append(localPart)
                }
            }
        }

        return expandedFields
    }

    static func tokens(from field: String) -> [String] {
        field.split(whereSeparator: { character in
            !character.isLetter && !character.isNumber
        })
        .map(String.init)
        .filter { !$0.isEmpty }
    }
}

enum VertexProfileSearchError: LocalizedError {
    case invalidCredentials
    case queryTooShort
    case invalidRequest
    case invalidResponse
    case untrustedResponse
    case requestRejected(String)
    case serviceUnavailable(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Search requires a signed-in private key right now."
        case .queryTooShort:
            return "Search terms must be longer than three characters."
        case .invalidRequest:
            return "Couldn't prepare the search request."
        case .invalidResponse:
            return "Vertex returned an invalid search response."
        case .untrustedResponse:
            return "Vertex search response could not be trusted."
        case .requestRejected(let message):
            return message
        case .serviceUnavailable(let statusCode):
            return "Vertex search is unavailable right now (\(statusCode))."
        }
    }
}

private struct VertexProfileMatch: Codable, Sendable {
    let pubkey: String
    let rank: Double?
}

actor VertexProfileSearchService {
    static let shared = VertexProfileSearchService()

    nonisolated static let relayURL = URL(string: "wss://relay.vertexlab.io")!

    private static let apiURL = URL(string: "https://relay.vertexlab.io/api/v1/dvms")!
    private static let requestKind = 5_315
    private static let responseKind = 6_315
    private static let errorKind = 7_000
    private static let trustedResponsePubkey = "b0565a0d950477811f35ff76e5981ede67a90469a97feec13dc17f36290debfe"

    private let cacheTTL: TimeInterval = 60 * 15
    private var searchCache: [String: (matches: [VertexProfileMatch], createdAt: Int, storedAt: Date)] = [:]

    func searchProfiles(
        query: String,
        limit: Int,
        nsec: String,
        relayURLs: [URL],
        feedService: NostrFeedService = NostrFeedService()
    ) async throws -> [ProfileSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count > 3 else {
            throw VertexProfileSearchError.queryTooShort
        }

        let normalizedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let keypair = Keypair(nsec: normalizedNsec) else {
            throw VertexProfileSearchError.invalidCredentials
        }

        let clampedLimit = min(max(limit, 1), 100)
        let cacheKey = "\(normalizedQuery.lowercased())|\(clampedLimit)"

        let cached = cachedSearch(for: cacheKey)
        let rawMatches: [VertexProfileMatch]
        let createdAt: Int

        if let cached {
            rawMatches = cached.matches
            createdAt = cached.createdAt
        } else {
            let searchResult = try await performSearchRequest(
                query: normalizedQuery,
                limit: clampedLimit,
                keypair: keypair
            )
            rawMatches = searchResult.matches
            createdAt = searchResult.createdAt
            searchCache[cacheKey] = (matches: rawMatches, createdAt: createdAt, storedAt: Date())
        }

        let pubkeys = normalizedPubkeys(from: rawMatches)
        guard !pubkeys.isEmpty else { return [] }

        let profileRelayTargets = normalizedRelayURLs([Self.relayURL] + relayURLs)
        let profilesByPubkey = await feedService.fetchProfiles(
            relayURLs: profileRelayTargets,
            pubkeys: pubkeys
        )

        return pubkeys.enumerated().map { index, pubkey in
            ProfileSearchResult(
                pubkey: pubkey,
                profile: profilesByPubkey[pubkey],
                createdAt: createdAt - index
            )
        }
    }

    private func performSearchRequest(
        query: String,
        limit: Int,
        keypair: Keypair
    ) async throws -> (matches: [VertexProfileMatch], createdAt: Int) {
        let requestEvent = try makeRequestEvent(query: query, limit: limit, keypair: keypair)

        let requestData = try JSONEncoder().encode(requestEvent)
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.httpBody = requestData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VertexProfileSearchError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw VertexProfileSearchError.serviceUnavailable(statusCode: httpResponse.statusCode)
        }

        let responseEvent = try JSONDecoder().decode(NostrEvent.self, from: responseData)
        try validateResponseEvent(responseEvent, requestID: requestEvent.id, requesterPubkey: keypair.publicKey.hex)

        if responseEvent.kind == Self.errorKind {
            let message = responseStatusMessage(from: responseEvent.tags) ?? "Vertex search failed."
            throw VertexProfileSearchError.requestRejected(message)
        }

        guard responseEvent.kind == Self.responseKind else {
            throw VertexProfileSearchError.invalidResponse
        }

        guard let contentData = responseEvent.content.data(using: .utf8) else {
            throw VertexProfileSearchError.invalidResponse
        }

        let decodedMatches = try JSONDecoder().decode([VertexProfileMatch].self, from: contentData)
        return (decodedMatches, responseEvent.createdAt)
    }

    private func makeRequestEvent(
        query: String,
        limit: Int,
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        let rawTags = [
            ["param", "search", query],
            ["param", "limit", "\(limit)"],
            ["param", "sort", "globalPagerank"]
        ]
        let sdkTags = rawTags.compactMap(decodeSDKTag(from:))

        let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(Self.requestKind))
            .content("")
            .appendTags(contentsOf: sdkTags)
            .build(signedBy: keypair)

        guard !event.id.isEmpty else {
            throw VertexProfileSearchError.invalidRequest
        }
        return event
    }

    private func validateResponseEvent(
        _ responseEvent: NostrEvent,
        requestID: String,
        requesterPubkey: String
    ) throws {
        guard responseEvent.pubkey.lowercased() == Self.trustedResponsePubkey else {
            throw VertexProfileSearchError.untrustedResponse
        }

        let normalizedRequestID = requestID.lowercased()
        let normalizedRequesterPubkey = requesterPubkey.lowercased()

        let referencesRequest = responseEvent.tags.contains { tag in
            guard let name = tag.first?.lowercased(), name == "e", tag.count > 1 else { return false }
            return tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedRequestID
        }
        guard referencesRequest else {
            throw VertexProfileSearchError.invalidResponse
        }

        let referencesRequester = responseEvent.tags.contains { tag in
            guard let name = tag.first?.lowercased(), name == "p", tag.count > 1 else { return false }
            return tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedRequesterPubkey
        }
        guard referencesRequester else {
            throw VertexProfileSearchError.invalidResponse
        }
    }

    private func cachedSearch(for key: String) -> (matches: [VertexProfileMatch], createdAt: Int)? {
        guard let cached = searchCache[key] else { return nil }
        guard Date().timeIntervalSince(cached.storedAt) <= cacheTTL else {
            searchCache.removeValue(forKey: key)
            return nil
        }
        return (cached.matches, cached.createdAt)
    }

    private func normalizedPubkeys(from matches: [VertexProfileMatch]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for match in matches {
            let normalized = match.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
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

    private func responseStatusMessage(from tags: [[String]]) -> String? {
        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "status", tag.count > 2 else { continue }
            let value = tag[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func decodeSDKTag(from raw: [String]) -> NostrSDK.Tag? {
        guard raw.count >= 2 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
            return nil
        }
        return tag
    }
}

enum FeedItemHydrationMode: Sendable {
    case full
    case cachedProfilesOnly
}

enum RelayFetchMode: Sendable, Equatable {
    case allRelays

    // Fast path for UI surfaces that prefer the first relay with matching data
    // over waiting on the full relay set.
    case firstNonEmptyRelay

    // Stricter latency path for screens where one slow empty relay should not
    // hold up visible content once another relay has matching events.
    case firstRelayWithEvents
}

actor FeedPresentationCache {
    static let shared = FeedPresentationCache()

    private let capacity: Int
    private var itemsByEventID: [String: FeedItem] = [:]
    private var accessOrder: [String] = []

    init(capacity: Int = 512) {
        self.capacity = max(capacity, 1)
    }

    func cachedItems(for eventIDs: [String]) -> [String: FeedItem] {
        var cached: [String: FeedItem] = [:]

        for rawID in eventIDs {
            let eventID = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !eventID.isEmpty, let item = itemsByEventID[eventID] else { continue }
            cached[eventID] = item
            touch(eventID)
        }

        return cached
    }

    func store(_ items: [FeedItem]) {
        guard !items.isEmpty else { return }

        for item in items {
            let eventID = item.id
            itemsByEventID[eventID] = item
            touch(eventID)
        }

        evictIfNeeded()
    }

    private func touch(_ eventID: String) {
        accessOrder.removeAll(where: { $0 == eventID })
        accessOrder.append(eventID)
    }

    private func evictIfNeeded() {
        while itemsByEventID.count > capacity, let evictedID = accessOrder.first {
            accessOrder.removeFirst()
            itemsByEventID.removeValue(forKey: evictedID)
        }
    }
}

struct OutboxRecoveryDiagnostics: Equatable, Sendable {
    var directoryHitCount: Int = 0
    var writeRelayFallbackCount: Int = 0
    var genericReadRelayFallbackCount: Int = 0
}

actor OutboxRecoveryDiagnosticsStore {
    static let shared = OutboxRecoveryDiagnosticsStore()

    private var diagnostics = OutboxRecoveryDiagnostics()

    func snapshot() -> OutboxRecoveryDiagnostics {
        diagnostics
    }

    func record(
        directoryHits: Int,
        writeRelayFallbacks: Int,
        genericReadRelayFallbacks: Int
    ) {
        diagnostics.directoryHitCount += directoryHits
        diagnostics.writeRelayFallbackCount += writeRelayFallbacks
        diagnostics.genericReadRelayFallbackCount += genericReadRelayFallbacks
    }
}

struct NostrFeedService: Sendable {
    private let relayClient: any NostrRelayEventFetching
    private let timelineCache: any TimelineEventCaching
    private let profileCache: any ProfileCaching
    private let relayHintCache: any ProfileRelayHintCaching
    private let followListCache: any FollowListSnapshotStoring
    private let seenEventStore: any SeenEventStoring
    private let presentationCache: FeedPresentationCache
    private let outboxDiagnosticsStore: OutboxRecoveryDiagnosticsStore
    nonisolated static let nostrArchivesSearchRelayURL = URL(string: "wss://search.nostrarchives.com")!
    nonisolated static let nostrArchivesTrendingRelayURL = URL(string: "wss://feeds.nostrarchives.com/notes/trending/reactions/today")!
    private static let trendingRelayURL = nostrArchivesTrendingRelayURL
    private static let followListFreshCacheAge: TimeInterval = 60 * 5
    private static let profileBackfillBatchSize = 24
    private static let dittoEOSEGraceTimeout: TimeInterval = 0.3
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
        seenEventStore: any SeenEventStoring = SeenEventStore.shared,
        presentationCache: FeedPresentationCache = .shared,
        outboxDiagnosticsStore: OutboxRecoveryDiagnosticsStore = .shared
    ) {
        self.relayClient = relayClient
        self.timelineCache = timelineCache
        self.profileCache = profileCache
        self.relayHintCache = relayHintCache
        self.followListCache = followListCache
        self.seenEventStore = seenEventStore
        self.presentationCache = presentationCache
        self.outboxDiagnosticsStore = outboxDiagnosticsStore
    }

    func outboxDiagnostics() async -> OutboxRecoveryDiagnostics {
        await outboxDiagnosticsStore.snapshot()
    }

    func ingestLiveEvents(_ events: [NostrEvent]) async {
        guard !events.isEmpty else { return }
        await seenEventStore.store(events: events)
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
            return try await fetchTimelineEvents(
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
        let fetchedEvents = try await fetchTimelineEventsFromRelaysOnly(
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
                        let events = try await fetchTimelineEvents(
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

                    guard let events = try? await fetchTimelineEventsFromRelaysOnly(
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
                await seenEventStore.store(events: deduplicateEvents(collected))
            }

            return windowsByAuthor
        }

        return windowsByAuthor
    }

    func fetchFollowings(relayURL: URL, pubkey: String) async throws -> [String] {
        try await fetchFollowings(relayURLs: [relayURL], pubkey: pubkey)
    }

    func fetchFollowings(
        relayURLs: [URL],
        pubkey: String,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [String] {
        try await fetchFollowings(
            relayURLs: relayURLs,
            pubkey: pubkey,
            relayFetchMode: relayFetchMode,
            relayOnly: false,
            fallbackToCachedSnapshot: true
        )
    }

    func fetchFollowings(
        relayURLs: [URL],
        pubkey: String,
        relayFetchMode: RelayFetchMode,
        relayOnly: Bool,
        fallbackToCachedSnapshot: Bool
    ) async throws -> [String] {
        let snapshot = try await fetchFollowListSnapshot(
            relayURLs: relayURLs,
            pubkey: pubkey,
            relayFetchMode: relayFetchMode,
            relayOnly: relayOnly,
            fallbackToCachedSnapshot: fallbackToCachedSnapshot
        )
        return snapshot?.followedPubkeys ?? []
    }

    func fetchKnownFollowers(
        relayURLs: [URL],
        profilePubkey: String,
        candidatePubkeys: [String],
        limit: Int = 5,
        fetchTimeout: TimeInterval = 4,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [String] {
        let normalizedProfilePubkey = normalizePubkey(profilePubkey)
        guard limit > 0, !normalizedProfilePubkey.isEmpty else { return [] }

        let relayTargets = normalizedRelayURLs(relayURLs)
        guard !relayTargets.isEmpty else { return [] }

        let candidates = normalizedUniquePubkeys(candidatePubkeys)
            .filter { $0 != normalizedProfilePubkey }
        guard !candidates.isEmpty else { return [] }

        var results: [String] = []
        var resultSet = Set<String>()

        func appendResult(_ pubkey: String) {
            guard results.count < limit else { return }
            guard resultSet.insert(pubkey).inserted else { return }
            results.append(pubkey)
        }

        for candidate in candidates {
            guard let snapshot = await followListCache.cachedSnapshot(pubkey: candidate) else {
                continue
            }
            if snapshot.followedPubkeys.contains(normalizedProfilePubkey) {
                appendResult(candidate)
            }
            if results.count >= limit {
                return results
            }
        }

        for batch in candidates.filter({ !resultSet.contains($0) }).chunked(into: 80) {
            let filter = NostrFilter(
                authors: batch,
                kinds: [3],
                limit: min(max(limit * 6, 24), max(batch.count * 2, 1)),
                tagFilters: ["p": [normalizedProfilePubkey]]
            )

            guard let events = try? await fetchTimelineEvents(
                relayURLs: relayTargets,
                filter: filter,
                timeout: fetchTimeout,
                useCache: false,
                relayFetchMode: relayFetchMode
            ) else {
                continue
            }

            let batchSet = Set(batch)
            var hitAuthors: [String] = []
            var seenHitAuthors = Set<String>()

            for event in events where event.kind == 3 {
                let author = normalizePubkey(event.pubkey)
                guard batchSet.contains(author), !resultSet.contains(author) else { continue }
                guard event.tags.contains(where: { tag in
                    tag.count > 1 &&
                        tag.first?.lowercased() == "p" &&
                        normalizePubkey(tag[1]) == normalizedProfilePubkey
                }) else {
                    continue
                }
                if seenHitAuthors.insert(author).inserted {
                    hitAuthors.append(author)
                }
            }

            for author in hitAuthors {
                guard let snapshot = try? await fetchFollowListSnapshot(
                    relayURLs: relayTargets,
                    pubkey: author,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode
                ) else {
                    continue
                }
                if snapshot.followedPubkeys.contains(normalizedProfilePubkey) {
                    appendResult(author)
                }
                if results.count >= limit {
                    return results
                }
            }
        }

        return results
    }

    func cachedKnownFollowers(
        profilePubkey: String,
        candidatePubkeys: [String],
        limit: Int = 5
    ) async -> [String] {
        let normalizedProfilePubkey = normalizePubkey(profilePubkey)
        guard limit > 0, !normalizedProfilePubkey.isEmpty else { return [] }

        let candidates = normalizedUniquePubkeys(candidatePubkeys)
            .filter { $0 != normalizedProfilePubkey }
        guard !candidates.isEmpty else { return [] }

        var results: [String] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard let snapshot = await followListCache.cachedSnapshot(pubkey: candidate) else {
                continue
            }
            guard snapshot.followedPubkeys.contains(normalizedProfilePubkey) else {
                continue
            }
            if seen.insert(candidate).inserted {
                results.append(candidate)
            }
            if results.count >= limit {
                return results
            }
        }

        return results
    }

    func cachedFollowListSnapshot(pubkey: String) async -> FollowListSnapshot? {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return nil }
        let snapshot = await followListCache.cachedSnapshot(pubkey: normalizedPubkey)
        if let snapshot {
            await relayHintCache.storeHints(snapshot.relayHintsByPubkey)
        }
        return snapshot
    }

    func storeFollowListSnapshotLocally(_ snapshot: FollowListSnapshot, for pubkey: String) async {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return }

        await followListCache.storeSnapshot(snapshot, for: normalizedPubkey)
        await relayHintCache.storeHints(snapshot.relayHintsByPubkey)
    }

    func fetchFollowListSnapshot(relayURL: URL, pubkey: String) async throws -> FollowListSnapshot? {
        try await fetchFollowListSnapshot(relayURLs: [relayURL], pubkey: pubkey)
    }

    func fetchFollowListSnapshot(
        relayURLs: [URL],
        pubkey: String,
        fetchTimeout: TimeInterval = 10,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool = false,
        fallbackToCachedSnapshot: Bool = true
    ) async throws -> FollowListSnapshot? {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return nil }

        let cachedSnapshot = fallbackToCachedSnapshot
            ? await followListCache.cachedSnapshot(pubkey: normalizedPubkey)
            : nil

        let contactsFilter = NostrFilter(
            authors: [normalizedPubkey],
            kinds: [3],
            limit: 50
        )

        do {
            let events = try await fetchTimelineEvents(
                relayURLs: relayURLs,
                filter: contactsFilter,
                timeout: fetchTimeout,
                useCache: false,
                relayFetchMode: relayFetchMode,
                relayOnly: relayOnly
            )

            if let snapshot = extractFollowListSnapshot(from: events) {
                await followListCache.storeSnapshot(snapshot, for: normalizedPubkey)
                await relayHintCache.storeHints(snapshot.relayHintsByPubkey)
                return snapshot
            }

            if let cachedSnapshot {
                await relayHintCache.storeHints(cachedSnapshot.relayHintsByPubkey)
            }
            return cachedSnapshot
        } catch {
            if let cachedSnapshot {
                await relayHintCache.storeHints(cachedSnapshot.relayHintsByPubkey)
                return cachedSnapshot
            }
            throw error
        }
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
        let fetchedEvents = try await fetchTimelineEvents(
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
        let normalizedAuthors = normalizedUniquePubkeys(authors)
        let normalizedSeedHints = normalizedHintRelayMap(seedHintRelayURLsByPubkey)
        if !normalizedSeedHints.isEmpty {
            await relayHintCache.storeHints(normalizedSeedHints)
        }

        var directoryEntries = await cachedAuthorRelayDirectoryEntries(for: normalizedAuthors)
        let authorsNeedingDirectoryFetch = normalizedAuthors.filter { author in
            let entry = directoryEntries[author]
            return (entry?.readRelayURLs.isEmpty ?? true) && (entry?.writeRelayURLs.isEmpty ?? true)
        }

        if !authorsNeedingDirectoryFetch.isEmpty {
            let fetchedEntries = await fetchAuthorRelayDirectoryEntries(
                for: authorsNeedingDirectoryFetch,
                baseReadRelayURLs: baseReadRelayURLs,
                existingEntries: directoryEntries
            )
            directoryEntries.merge(fetchedEntries, uniquingKeysWith: { _, new in new })
        }

        await recordOutboxPlanDiagnostics(
            authors: normalizedAuthors,
            directoryEntries: directoryEntries
        )

        return AuthorRelayPlanner().makePlan(
            authors: normalizedAuthors,
            baseReadRelayURLs: baseReadRelayURLs,
            directoryEntriesByPubkey: directoryEntries,
            fallbackRelayURLs: Self.metadataFallbackRelayURLs
        )
    }

    func refreshAuthorRelayDirectory(
        relayURLs: [URL],
        pubkey: String
    ) async {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return }

        let existingEntries = await cachedAuthorRelayDirectoryEntries(for: [normalizedPubkey])
        _ = await fetchAuthorRelayDirectoryEntries(
            for: [normalizedPubkey],
            baseReadRelayURLs: relayURLs,
            existingEntries: existingEntries
        )
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
                return await buildFeedItems(
                    relayURLs: relayURLs,
                    events: archivedEvents,
                    hydrationMode: hydrationMode,
                    moderationSnapshot: moderationSnapshot
                )
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
            fetchedEvents = try await fetchTimelineEvents(
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
                let fallbackEvents = try await fetchTimelineEvents(
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
        return await buildFeedItems(
            relayURLs: relayURLs,
            events: timelineEvents,
            hydrationMode: hydrationMode,
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
        let _ = query
        let _ = kinds
        let _ = limit
        let _ = until
        let _ = hydrationMode
        let _ = moderationSnapshot
        return []
    }

    func fetchReferencedFeedItem(
        reference: NostrEventReferencePointer,
        relayURLs: [URL],
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 8,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> FeedItem? {
        let relayTargets = await referenceRelayTargets(
            for: reference,
            baseRelayURLs: relayURLs
        )
        guard !relayTargets.isEmpty else { return nil }

        let event: NostrEvent?
        switch reference.target {
        case .eventID(let eventID):
            event = await fetchReferencedEventByID(
                eventID,
                relayURLs: relayTargets,
                fetchTimeout: fetchTimeout
            )
        case .replaceable(let kind, let pubkey, let identifier):
            event = await fetchReplaceableReferencedEvent(
                kind: kind,
                pubkey: pubkey,
                identifier: identifier,
                relayURLs: relayTargets,
                fetchTimeout: fetchTimeout
            )
        }

        guard let event else { return nil }
        await seenEventStore.store(events: [event])

        let items = await buildFeedItems(
            relayURLs: relayTargets,
            events: [event],
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )
        return items.first
    }

    func fetchReferencedEvents(
        references: [NostrEventReferencePointer],
        baseRelayURLs: [URL],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [NostrEventReferencePointer: NostrEvent] {
        let uniqueReferences = Array(Set(references))
        guard !uniqueReferences.isEmpty else { return [:] }

        var resolved: [NostrEventReferencePointer: NostrEvent] = [:]
        var unresolvedEventReferences: [NostrEventReferencePointer] = []
        var unresolvedAddressReferences: [(reference: NostrEventReferencePointer, address: ActivityAddress)] = []

        for reference in uniqueReferences {
            switch reference.target {
            case .eventID(let rawEventID):
                let eventID = rawEventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !eventID.isEmpty else { continue }
                unresolvedEventReferences.append(
                    NostrEventReferencePointer(
                        normalizedIdentifier: reference.normalizedIdentifier,
                        target: .eventID(eventID),
                        relayHints: reference.relayHints,
                        authorPubkey: reference.authorPubkey
                    )
                )

            case .replaceable(let kind, let pubkey, let identifier):
                let normalizedPubkey = normalizePubkey(pubkey)
                let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedPubkey.isEmpty, !normalizedIdentifier.isEmpty else { continue }
                unresolvedAddressReferences.append(
                    (
                        reference,
                        ActivityAddress(
                            kind: kind,
                            pubkey: normalizedPubkey,
                            identifier: normalizedIdentifier
                        )
                    )
                )
            }
        }

        if !unresolvedEventReferences.isEmpty {
            let cachedByID = await seenEventStore.events(
                ids: unresolvedEventReferences.compactMap(\.eventID)
            )
            if !cachedByID.isEmpty {
                unresolvedEventReferences.removeAll { reference in
                    guard let eventID = reference.eventID,
                          let event = cachedByID[eventID] else {
                        return false
                    }
                    resolved[reference] = event
                    return true
                }
            }
        }

        var fetchedEvents: [NostrEvent] = []

        if !unresolvedEventReferences.isEmpty {
            struct EventReferenceGroup {
                var relayURLs: [URL]
                var eventIDs: Set<String>
                var referencesByEventID: [String: [NostrEventReferencePointer]]
            }

            var groups: [String: EventReferenceGroup] = [:]
            for reference in unresolvedEventReferences {
                guard let eventID = reference.eventID else { continue }
                let relayTargets = await referenceRelayTargets(
                    for: reference,
                    baseRelayURLs: baseRelayURLs
                )
                let signature = relayTargets.map { $0.absoluteString.lowercased() }.joined(separator: "|")
                var group = groups[signature] ?? EventReferenceGroup(
                    relayURLs: relayTargets,
                    eventIDs: [],
                    referencesByEventID: [:]
                )
                group.eventIDs.insert(eventID)
                group.referencesByEventID[eventID, default: []].append(reference)
                groups[signature] = group
            }

            for group in groups.values {
                let eventIDs = Array(group.eventIDs)
                guard !group.relayURLs.isEmpty, !eventIDs.isEmpty else { continue }

                let filter = NostrFilter(
                    ids: eventIDs,
                    limit: max(eventIDs.count * 2, eventIDs.count)
                )

                guard let events = try? await fetchTimelineEventsFromRelaysOnly(
                    relayURLs: group.relayURLs,
                    filter: filter,
                    timeout: fetchTimeout,
                    useCache: false,
                    relayFetchMode: relayFetchMode
                ) else {
                    continue
                }

                let newestByID = Dictionary(
                    uniqueKeysWithValues: deduplicateEvents(events)
                        .sorted(by: { lhs, rhs in
                            if lhs.createdAt == rhs.createdAt {
                                return lhs.id > rhs.id
                            }
                            return lhs.createdAt > rhs.createdAt
                        })
                        .map { ($0.id.lowercased(), $0) }
                )

                for (eventID, referencesForEventID) in group.referencesByEventID {
                    guard let event = newestByID[eventID] else { continue }
                    fetchedEvents.append(event)
                    for reference in referencesForEventID {
                        resolved[reference] = event
                    }
                }
            }
        }

        if !unresolvedAddressReferences.isEmpty {
            struct AddressReferenceGroup {
                var relayURLs: [URL]
                var addresses: Set<ActivityAddress>
                var referencesByAddress: [ActivityAddress: [NostrEventReferencePointer]]
            }

            var groups: [String: AddressReferenceGroup] = [:]
            for entry in unresolvedAddressReferences {
                let relayTargets = await referenceRelayTargets(
                    for: entry.reference,
                    baseRelayURLs: baseRelayURLs
                )
                let signature = relayTargets.map { $0.absoluteString.lowercased() }.joined(separator: "|")
                let key = "\(signature)|\(entry.address.kind)|\(entry.address.pubkey)"
                var group = groups[key] ?? AddressReferenceGroup(
                    relayURLs: relayTargets,
                    addresses: [],
                    referencesByAddress: [:]
                )
                group.addresses.insert(entry.address)
                group.referencesByAddress[entry.address, default: []].append(entry.reference)
                groups[key] = group
            }

            for group in groups.values {
                guard let sample = group.addresses.first,
                      !group.relayURLs.isEmpty else {
                    continue
                }

                let identifiers = Array(Set(group.addresses.map(\.identifier)))
                let filter = NostrFilter(
                    authors: [sample.pubkey],
                    kinds: [sample.kind],
                    limit: max(identifiers.count * 4, 20),
                    tagFilters: ["d": identifiers]
                )

                guard let events = try? await fetchTimelineEventsFromRelaysOnly(
                    relayURLs: group.relayURLs,
                    filter: filter,
                    timeout: fetchTimeout,
                    useCache: false,
                    relayFetchMode: relayFetchMode
                ) else {
                    continue
                }

                let newestByAddress = newestAddressEvents(
                    from: events,
                    addresses: group.addresses
                )
                for (address, event) in newestByAddress {
                    fetchedEvents.append(event)
                    for reference in group.referencesByAddress[address] ?? [] {
                        resolved[reference] = event
                    }
                }
            }
        }

        let deduplicatedFetched = deduplicateEvents(fetchedEvents)
        if !deduplicatedFetched.isEmpty {
            await seenEventStore.store(events: deduplicatedFetched)
        }

        return resolved
    }

    func fetchOutboxBackedReferencedEvents(
        references: [NostrEventReferencePointer],
        baseReadRelayURLs: [URL],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [NostrEventReferencePointer: NostrEvent] {
        await fetchReferencedEvents(
            references: references,
            baseRelayURLs: baseReadRelayURLs,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    func searchProfiles(
        query: String,
        limit: Int,
        preferredPubkeys: Set<String> = []
    ) async -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return [] }

        let normalizedPreferredPubkeys = Set(
            preferredPubkeys
                .map(normalizePubkey)
                .filter { !$0.isEmpty }
        )
        let localLimit = min(max(limit * 3, 24), 120)
        let localResults = await cachedProfileSearchResults(
            query: normalizedQuery,
            limit: localLimit,
            preferredPubkeys: normalizedPreferredPubkeys
        )

        let shouldSearchRemotely = normalizedQuery.count >= 2 && localResults.count < limit
        let archiveResults: [ProfileSearchResult]
        let remoteResults: [ProfileSearchResult]
        if shouldSearchRemotely {
            archiveResults = await NostrArchivesSearchService.shared.searchProfiles(
                query: normalizedQuery,
                limit: min(max(limit * 2, 24), 100)
            )

            let shouldUseRelayFallback = localResults.count + archiveResults.count < limit
            let relayTargets = shouldUseRelayFallback ? await mentionSearchRelayTargets() : []
            if relayTargets.isEmpty {
                remoteResults = []
            } else {
                remoteResults = (try? await searchProfiles(
                    relayURLs: relayTargets,
                    query: normalizedQuery,
                    limit: min(max(limit * 2, 24), 120),
                    fetchTimeout: 6,
                    relayFetchMode: .firstNonEmptyRelay
                )) ?? []
            }
        } else {
            archiveResults = []
            remoteResults = []
        }

        return mergedProfileSearchResults(
            groups: [localResults, archiveResults, remoteResults],
            query: normalizedQuery,
            preferredPubkeys: normalizedPreferredPubkeys,
            limit: limit
        )
    }

    func recentLocalProfiles(limit: Int) async -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        let recentPubkeys = await profileCache.recentProfilePubkeys(limit: min(max(limit * 3, 24), 120))
        guard !recentPubkeys.isEmpty else { return [] }

        let cachedProfiles = await profileCache.cachedProfiles(pubkeys: recentPubkeys)
        let referenceTime = Int(Date().timeIntervalSince1970)

        return Array(recentPubkeys.enumerated().compactMap { index, pubkey in
            guard let profile = cachedProfiles[pubkey] else { return nil }
            return ProfileSearchResult(
                pubkey: pubkey,
                profile: profile,
                createdAt: referenceTime - index
            )
        }.prefix(limit))
    }

    func searchProfiles(
        relayURLs: [URL],
        query: String,
        limit: Int,
        fetchTimeout: TimeInterval = 10,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return [] }

        let metadataFilter = NostrFilter(
            kinds: [0],
            search: normalizedQuery,
            limit: max(limit * 4, 60)
        )

        var firstError: Error?
        var metadataEvents: [NostrEvent] = []

        do {
            metadataEvents = try await fetchTimelineEvents(
                relayURLs: relayURLs,
                filter: metadataFilter,
                timeout: fetchTimeout,
                useCache: false,
                relayFetchMode: relayFetchMode
            )
            .filter { $0.kind == 0 }
        } catch {
            firstError = error
        }

        if metadataEvents.isEmpty {
            let fallbackFilter = NostrFilter(
                kinds: [0],
                limit: min(max(limit * 20, 180), 500)
            )

            do {
                metadataEvents = try await fetchTimelineEvents(
                    relayURLs: relayURLs,
                    filter: fallbackFilter,
                    timeout: fetchTimeout,
                    relayFetchMode: relayFetchMode
                )
                .filter { $0.kind == 0 }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if metadataEvents.isEmpty, let firstError {
            throw firstError
        }

        let sortedEvents = deduplicateEvents(metadataEvents).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }

        return await matchedProfileResults(
            from: sortedEvents,
            query: normalizedQuery,
            limit: limit
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

        let fetchedEvents = try await fetchTimelineEvents(
            relayURLs: [Self.trendingRelayURL],
            filter: filter,
            timeout: fetchTimeout,
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
            return await buildCachedFeedItems(
                events: timelineEvents,
                moderationSnapshot: moderationSnapshot
            )
        case .full:
            let authorRelayTargets = normalizedRelayURLs(
                (hydrationRelayURLs ?? []) + Self.metadataFallbackRelayURLs + [Self.trendingRelayURL]
            )
            return await buildAuthorOnlyFeedItems(
                relayURLs: authorRelayTargets,
                events: timelineEvents,
                moderationSnapshot: moderationSnapshot
            )
        }
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
        guard limit > 0 else { return [] }
        let normalizedPubkey = normalizePubkey(currentUserPubkey)
        guard !normalizedPubkey.isEmpty else { return [] }

        let relayTargets = normalizedRelayURLs(relayURLs)
        guard !relayTargets.isEmpty else { return [] }

        let activityFilter = NostrFilter(
            kinds: filter.eventKinds,
            limit: limit,
            tagFilters: ["p": [normalizedPubkey]]
        )

        let activityEvents = try await fetchTimelineEvents(
            relayURLs: relayTargets,
            filter: activityFilter,
            timeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )

        let limitedEvents = Array(
            filteredActivityEvents(
                from: activityEvents,
                currentUserPubkey: normalizedPubkey
            )
            .prefix(limit)
        )

        return await buildActivityRows(
            relayURLs: relayTargets,
            currentUserPubkey: normalizedPubkey,
            events: limitedEvents,
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
        let normalizedPubkey = normalizePubkey(currentUserPubkey)
        guard !normalizedPubkey.isEmpty else { return [] }

        let relayTargets = normalizedRelayURLs(relayURLs)
        guard !relayTargets.isEmpty else { return [] }

        let filteredEvents = filteredActivityEvents(
            from: events,
            currentUserPubkey: normalizedPubkey
        )
        return await buildResolvedActivityRows(
            relayURLs: relayTargets,
            events: filteredEvents,
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
        guard limit > 0 else { return [] }
        guard let normalizedRootEventID = normalizedEventID(rootEventID) else { return [] }

        let relayTargets = normalizedRelayURLs(relayURLs)
        guard !relayTargets.isEmpty else { return [] }

        async let reactionAndRepostEventsTask = fetchTimelineEvents(
            relayURLs: relayTargets,
            filter: NostrFilter(
                kinds: [6, 7, 16],
                limit: limit,
                tagFilters: ["e": [normalizedRootEventID]]
            ),
            timeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
        async let quoteEventsTask = fetchTimelineEvents(
            relayURLs: relayTargets,
            filter: NostrFilter(
                kinds: [1, 1111, 1244],
                limit: limit,
                tagFilters: ["q": [normalizedRootEventID]]
            ),
            timeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )

        let mergedEvents = deduplicateEvents(try await reactionAndRepostEventsTask + quoteEventsTask)

        return await buildNoteActivityRows(
            relayURLs: relayTargets,
            rootEventID: normalizedRootEventID,
            events: mergedEvents,
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
        let normalizedRootEventID = normalizedEventID(rootEventID) ?? rootEventID.lowercased()
        let normalizedRootAuthorPubkey = normalizePubkey(rootAuthorPubkey)

        return try await fetchNoteActivityRows(
            relayURLs: relayURLs,
            rootEventID: rootEventID,
            limit: limit,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            profileFetchTimeout: profileFetchTimeout,
            profileRelayFetchMode: profileRelayFetchMode,
            knownTargetPubkeysByEventID: normalizedRootAuthorPubkey.isEmpty
                ? [:]
                : [normalizedRootEventID: normalizedRootAuthorPubkey]
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
        guard let normalizedRootEventID = normalizedEventID(rootEventID) else { return [] }

        let relayTargets = normalizedRelayURLs(relayURLs)
        guard !relayTargets.isEmpty else { return [] }

        let filteredEvents = filteredNoteActivityEvents(
            from: events,
            rootEventID: normalizedRootEventID
        )

        return await buildResolvedActivityRows(
            relayURLs: relayTargets,
            events: filteredEvents,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            profileFetchTimeout: profileFetchTimeout,
            profileRelayFetchMode: profileRelayFetchMode,
            knownTargetPubkeysByEventID: knownTargetPubkeysByEventID
        )
    }

    private func buildResolvedActivityRows(
        relayURLs: [URL],
        events: [NostrEvent],
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        profileFetchTimeout: TimeInterval,
        profileRelayFetchMode: RelayFetchMode,
        knownTargetPubkeysByEventID: [String: String] = [:]
    ) async -> [ActivityRow] {
        let relayTargets = normalizedRelayURLs(relayURLs)
        guard !relayTargets.isEmpty else { return [] }
        guard !events.isEmpty else { return [] }

        let actorPubkeys = Array(
            Set(events.map { normalizePubkey($0.pubkey) })
                .filter { !$0.isEmpty }
        )
        async let actorProfilesTask = actorPubkeys.isEmpty
            ? [String: NostrProfile]()
            : profileCache.cachedProfiles(pubkeys: actorPubkeys)
        async let targetEventsTask = resolveActivityTargetEvents(
            relayURLs: relayTargets,
            sourceEvents: events,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            knownTargetPubkeysByEventID: knownTargetPubkeysByEventID
        )

        let actorProfiles = await actorProfilesTask
        let targetEventsByReference = await targetEventsTask
        let targetPubkeys = Array(
            Set(
                targetEventsByReference.values
                    .map { normalizePubkey($0.pubkey) }
                    .filter { !$0.isEmpty }
            )
        )
        // Keep Activity's first paint fast by using cached target profiles only.
        // Thread detail now hydrates its own root item, so we no longer need to
        // block the entire activity list on a second network round-trip here.
        let targetProfiles = targetPubkeys.isEmpty
            ? [:]
            : await profileCache.cachedProfiles(pubkeys: targetPubkeys)

        return events.compactMap { event in
            guard let action = event.activityAction else { return nil }

            let normalizedActorPubkey = normalizePubkey(event.pubkey)
            let actor = ActivityActor(pubkey: event.pubkey, profile: actorProfiles[normalizedActorPubkey])
            let targetReference = resolvedActivityTargetReference(for: event)
            let resolvedTargetEvent = targetReference.flatMap { targetEventsByReference[$0] }
            let targetProfile = resolvedTargetEvent.flatMap {
                targetProfiles[normalizePubkey($0.pubkey)]
            }
            let targetSnippet = resolvedTargetEvent?.activitySnippet()
                ?? fallbackActivitySnippet(for: event, action: action)
            let target = ActivityTargetNote(
                reference: targetReference,
                event: resolvedTargetEvent,
                profile: targetProfile,
                snippet: targetSnippet
            )

            return ActivityRow(
                event: event,
                actor: actor,
                action: action,
                target: target
            )
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
        let fetchedEvents = try await fetchTimelineEventsFromRelaysOnly(
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
        let fetchedEvents = try await fetchTimelineEventsFromRelaysOnly(
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
        return await buildFeedItems(
            relayURLs: relayURLs,
            events: timelineEvents,
            hydrationMode: hydrationMode,
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

        let directReplies = try await fetchTimelineEvents(
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
            let nestedReplies = (try? await fetchTimelineEvents(
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
        await profileCache.cachedProfile(pubkey: normalizePubkey(pubkey))
    }

    func cachedProfiles(pubkeys: [String]) async -> [String: NostrProfile] {
        await profileCache.cachedProfiles(pubkeys: pubkeys)
    }

    func prewarmProfiles(
        relayURLs: [URL],
        pubkeys: [String],
        relayHintsByPubkey: [String: [URL]] = [:]
    ) async {
        guard !relayHintsByPubkey.isEmpty else {
            _ = await fetchProfiles(relayURLs: relayURLs, pubkeys: pubkeys)
            return
        }

        await relayHintCache.storeHints(relayHintsByPubkey)
        _ = await fetchProfiles(relayURLs: relayURLs, pubkeys: pubkeys)
    }

    func fetchProfile(
        relayURLs: [URL],
        pubkey: String,
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> NostrProfile? {
        let profiles = await fetchProfiles(
            relayURLs: relayURLs,
            pubkeys: [pubkey],
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
        return profiles[normalizePubkey(pubkey)]
    }

    func fetchFollowingCount(relayURL: URL, pubkey: String) async -> Int {
        await fetchFollowingCount(relayURLs: [relayURL], pubkey: pubkey)
    }

    func cachedFollowingCount(pubkey: String) async -> Int? {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return nil }
        guard let cachedSnapshot = await followListCache.cachedSnapshot(pubkey: normalizedPubkey) else {
            return nil
        }
        return cachedSnapshot.followedPubkeys.count
    }

    func fetchFollowingCount(
        relayURLs: [URL],
        pubkey: String,
        fetchTimeout: TimeInterval = 10,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> Int {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return 0 }
        if let cachedSnapshot = await followListCache.cachedSnapshot(
            pubkey: normalizedPubkey,
            maxAge: Self.followListFreshCacheAge
        ) {
            return cachedSnapshot.followedPubkeys.count
        }

        guard let snapshot = try? await fetchFollowListSnapshot(
            relayURLs: relayURLs,
            pubkey: pubkey,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        ) else {
            return 0
        }
        return snapshot.followedPubkeys.count
    }

    func fetchProfiles(relayURL: URL, pubkeys: [String]) async -> [String: NostrProfile] {
        await fetchProfiles(relayURLs: [relayURL], pubkeys: pubkeys)
    }

    func fetchProfiles(
        relayURLs: [URL],
        pubkeys: [String],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    ) async -> [String: NostrProfile] {
        let normalizedPubkeys = Array(
            Set(
                pubkeys
                    .map { normalizePubkey($0) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalizedPubkeys.isEmpty else { return [:] }

        let resolved = await profileCache.resolve(
            pubkeys: normalizedPubkeys,
            ignoringKnownMisses: true
        )
        var profilesByPubkey = resolved.hits
        var unresolvedPubkeys = Set(resolved.missing)
        guard !unresolvedPubkeys.isEmpty else {
            return profilesByPubkey
        }

        let primaryRelayTargets = normalizedRelayURLs(relayURLs)
        let prioritizedRelayTargets = await relayHintCache.prioritizedRelayURLs(
            for: Array(unresolvedPubkeys),
            baseRelayURLs: primaryRelayTargets
        )

        let requestedPubkeys = Array(unresolvedPubkeys)
        var fetchedProfiles = await fetchProfilesForPubkeys(
            relayURLs: prioritizedRelayTargets,
            pubkeys: requestedPubkeys,
            timeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
        let fetchedPubkeys = Set(fetchedProfiles.keys.map(normalizePubkey))
        unresolvedPubkeys.subtract(fetchedPubkeys)

        if !unresolvedPubkeys.isEmpty {
            let metadataRelayTargets = metadataRelayURLs(primaryRelayURLs: prioritizedRelayTargets)
            let fallbackProfiles = await fetchProfilesForPubkeys(
                relayURLs: metadataRelayTargets,
                pubkeys: Array(unresolvedPubkeys),
                timeout: fetchTimeout,
                relayFetchMode: relayFetchMode
            )
            if !fallbackProfiles.isEmpty {
                fetchedProfiles.merge(fallbackProfiles, uniquingKeysWith: { _, new in new })
                let fallbackPubkeys = Set(fallbackProfiles.keys.map(normalizePubkey))
                unresolvedPubkeys.subtract(fallbackPubkeys)
            }
        }

        if !fetchedProfiles.isEmpty || !unresolvedPubkeys.isEmpty {
            profilesByPubkey.merge(fetchedProfiles, uniquingKeysWith: { _, new in new })
            await profileCache.store(
                profiles: fetchedProfiles,
                missed: Array(unresolvedPubkeys)
            )
        }

        return profilesByPubkey
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

            guard let batchEvents = try? await fetchTimelineEventsFromRelaysOnly(
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

        await seenEventStore.store(events: selected)
        await hydrateReplaceableSideEffects(events: selected)
        return selected
    }

    private func referenceRelayTargets(
        for reference: NostrEventReferencePointer,
        baseRelayURLs: [URL]
    ) async -> [URL] {
        let relayTargets = normalizedRelayURLs(reference.relayHints + baseRelayURLs)
        guard !relayTargets.isEmpty else { return [] }
        return relayTargets
    }

    private func fetchReferencedEventByID(
        _ eventID: String,
        relayURLs: [URL],
        fetchTimeout: TimeInterval
    ) async -> NostrEvent? {
        let normalizedEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEventID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }

        if let cached = await seenEventStore.events(ids: [normalizedEventID])[normalizedEventID] {
            return cached
        }

        let filter = NostrFilter(ids: [normalizedEventID], limit: 1)
        guard let fetchedEvents = try? await fetchTimelineEvents(
            relayURLs: relayURLs,
            filter: filter,
            timeout: fetchTimeout,
            useCache: false,
            relayFetchMode: .allRelays
        ) else {
            return nil
        }

        return deduplicateEvents(fetchedEvents)
            .first { $0.id.lowercased() == normalizedEventID }
    }

    private func fetchReplaceableReferencedEvent(
        kind: Int,
        pubkey: String,
        identifier: String,
        relayURLs: [URL],
        fetchTimeout: TimeInterval
    ) async -> NostrEvent? {
        let normalizedPubkey = normalizePubkey(pubkey)
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind >= 0, !normalizedPubkey.isEmpty, !normalizedIdentifier.isEmpty else {
            return nil
        }

        let filter = NostrFilter(
            authors: [normalizedPubkey],
            kinds: [kind],
            limit: 40,
            tagFilters: ["d": [normalizedIdentifier]]
        )
        guard let fetchedEvents = try? await fetchTimelineEvents(
            relayURLs: relayURLs,
            filter: filter,
            timeout: fetchTimeout,
            useCache: false,
            relayFetchMode: .allRelays
        ) else {
            return nil
        }

        return deduplicateEvents(fetchedEvents)
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id > $1.id
                }
                return $0.createdAt > $1.createdAt
            }
            .first { event in
                guard event.kind == kind else { return false }
                guard event.pubkey.lowercased() == normalizedPubkey else { return false }
                return event.tags.contains { tag in
                    guard let name = tag.first?.lowercased(), name == "d" else { return false }
                    guard tag.count > 1 else { return false }
                    return tag[1].trimmingCharacters(in: .whitespacesAndNewlines) == normalizedIdentifier
                }
            }
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
        let uniqueEvents = deduplicateEvents(
            filterVisibleEvents(events, moderationSnapshot: moderationSnapshot)
        )
        let eventIDs = uniqueEvents.map { $0.id.lowercased() }

        switch hydrationMode {
        case .cachedProfilesOnly:
            return await buildCachedFeedItems(
                events: uniqueEvents,
                moderationSnapshot: moderationSnapshot
            )
        case .full:
            break
        }

        var itemsByEventID = await presentationCache.cachedItems(for: eventIDs)
        if !itemsByEventID.isEmpty {
            itemsByEventID = await refreshedCachedFeedItems(itemsByEventID)
        }
        let missingEvents = uniqueEvents.filter { event in
            guard let cachedItem = itemsByEventID[event.id.lowercased()] else { return true }
            return cachedItemNeedsFullHydration(cachedItem, sourceEvent: event)
        }

        guard !missingEvents.isEmpty else {
            return filterVisibleFeedItems(
                uniqueEvents.compactMap { itemsByEventID[$0.id.lowercased()] },
                moderationSnapshot: moderationSnapshot
            )
        }

        async let actorProfilesTask = hydrateActorProfiles(for: missingEvents, relayURLs: relayURLs)
        async let displayEventsTask = resolveDisplayEvents(for: missingEvents, relayURLs: relayURLs)

        let profilesByPubkey = await actorProfilesTask
        let displayEventsBySourceID = await displayEventsTask
        async let replyTargetEventsTask = resolveReplyTargetEvents(
            for: missingEvents,
            displayEventsBySourceID: displayEventsBySourceID,
            relayURLs: relayURLs
        )
        let displayPubkeys = Array(
            Set(
                displayEventsBySourceID.values
                    .map { normalizePubkey($0.pubkey) }
                    .filter { !$0.isEmpty }
            )
        )

        var displayProfilesByPubkey = profilesByPubkey
        if !displayPubkeys.isEmpty {
            let fetchedDisplayProfiles = await fetchProfiles(relayURLs: relayURLs, pubkeys: displayPubkeys)
            displayProfilesByPubkey.merge(fetchedDisplayProfiles, uniquingKeysWith: { existing, _ in existing })
        }

        let replyTargetEventsBySourceID = await replyTargetEventsTask
        let replyTargetPubkeys = Array(
            Set(
                replyTargetEventsBySourceID.values
                    .map { normalizePubkey($0.pubkey) }
                    .filter { !$0.isEmpty }
            )
        )
        var replyTargetProfilesByPubkey = displayProfilesByPubkey
        if !replyTargetPubkeys.isEmpty {
            let fetchedReplyTargetProfiles = await fetchProfiles(relayURLs: relayURLs, pubkeys: replyTargetPubkeys)
            replyTargetProfilesByPubkey.merge(
                fetchedReplyTargetProfiles,
                uniquingKeysWith: { existing, _ in existing }
            )
        }

        let freshItems = missingEvents.map { event in
            let normalizedPubkey = normalizePubkey(event.pubkey)
            let displayEvent = displayEventsBySourceID[event.id.lowercased()]
            let displayProfile = displayEvent.flatMap { displayProfilesByPubkey[normalizePubkey($0.pubkey)] }
            let replyTargetEvent = replyTargetEventsBySourceID[event.id.lowercased()]
            let replyTargetProfile = replyTargetEvent.flatMap {
                replyTargetProfilesByPubkey[normalizePubkey($0.pubkey)]
            }

            return FeedItem(
                event: event,
                profile: profilesByPubkey[normalizedPubkey],
                displayEventOverride: displayEvent,
                displayProfileOverride: displayProfile,
                replyTargetEvent: replyTargetEvent,
                replyTargetProfile: replyTargetProfile
            )
        }
        let filteredFreshItems = filterVisibleFeedItems(freshItems, moderationSnapshot: moderationSnapshot)
        let mergedFreshItems = filteredFreshItems.map { item in
            if let existing = itemsByEventID[item.id] {
                return existing.merged(with: item)
            }
            return item
        }
        await presentationCache.store(mergedFreshItems)
        for item in mergedFreshItems {
            itemsByEventID[item.id] = item
        }

        return filterVisibleFeedItems(
            uniqueEvents.compactMap { itemsByEventID[$0.id.lowercased()] },
            moderationSnapshot: moderationSnapshot
        )
    }

    private func refreshedCachedFeedItems(_ cachedItems: [String: FeedItem]) async -> [String: FeedItem] {
        let associatedPubkeys = Array(
            Set(
                cachedItems.values.flatMap { item in
                    [
                        normalizePubkey(item.event.pubkey),
                        normalizePubkey(item.displayEventOverride?.pubkey ?? ""),
                        normalizePubkey(item.replyTargetEvent?.pubkey ?? "")
                    ].filter { !$0.isEmpty }
                }
            )
        )
        guard !associatedPubkeys.isEmpty else { return cachedItems }

        let latestProfilesByPubkey = await profileCache.cachedProfiles(pubkeys: associatedPubkeys)
        guard !latestProfilesByPubkey.isEmpty else { return cachedItems }

        var refreshed: [String: FeedItem] = [:]
        refreshed.reserveCapacity(cachedItems.count)
        for (eventID, item) in cachedItems {
            refreshed[eventID] = refreshedCachedFeedItem(item, profilesByPubkey: latestProfilesByPubkey)
        }
        return refreshed
    }

    private func refreshedCachedFeedItem(
        _ item: FeedItem,
        profilesByPubkey: [String: NostrProfile]
    ) -> FeedItem {
        let actorProfile = profilesByPubkey[normalizePubkey(item.event.pubkey)] ?? item.profile
        let displayProfile = item.displayEventOverride.flatMap {
            profilesByPubkey[normalizePubkey($0.pubkey)]
        } ?? item.displayProfileOverride
        let replyTargetProfile = item.replyTargetEvent.flatMap {
            profilesByPubkey[normalizePubkey($0.pubkey)]
        } ?? item.replyTargetProfile

        return FeedItem(
            event: item.event,
            profile: actorProfile,
            displayEventOverride: item.displayEventOverride,
            displayProfileOverride: displayProfile,
            replyTargetEvent: item.replyTargetEvent,
            replyTargetProfile: replyTargetProfile
        )
    }

    private func cachedItemNeedsFullHydration(_ item: FeedItem, sourceEvent: NostrEvent) -> Bool {
        let normalizedSourceID = sourceEvent.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if item.profile == nil {
            return true
        }

        if sourceEvent.isRepost, item.displayEvent.id.lowercased() == normalizedSourceID {
            return true
        }

        if item.displayEventOverride != nil, item.displayProfileOverride == nil {
            return true
        }

        let replySourceEvent = item.displayEvent
        if replySourceEvent.isReplyNote, item.replyTargetEvent == nil {
            return true
        }

        if item.replyTargetEvent != nil, item.replyTargetProfile == nil {
            return true
        }

        return false
    }

    func buildAuthorHydratedFeedItems(
        relayURLs: [URL],
        events: [NostrEvent],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        await buildAuthorOnlyFeedItems(
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
        let actorPubkeys = Array(
            Set(
                events
                    .map { normalizePubkey($0.pubkey) }
                    .filter { !$0.isEmpty }
            )
        )
        let actorProfilesByPubkey = await profileCache.cachedProfiles(pubkeys: actorPubkeys)

        let displayEventsBySourceID = await resolveCachedDisplayEvents(for: events)
        let displayPubkeys = Array(
            Set(
                displayEventsBySourceID.values
                    .map { normalizePubkey($0.pubkey) }
                    .filter { !$0.isEmpty }
            )
        )
        let displayProfilesByPubkey = await profileCache.cachedProfiles(pubkeys: displayPubkeys)
        let replyTargetEventsBySourceID = await resolveCachedReplyTargetEvents(
            for: events,
            displayEventsBySourceID: displayEventsBySourceID
        )
        let replyTargetPubkeys = Array(
            Set(
                replyTargetEventsBySourceID.values
                    .map { normalizePubkey($0.pubkey) }
                    .filter { !$0.isEmpty }
            )
        )
        let replyTargetProfilesByPubkey = await profileCache.cachedProfiles(pubkeys: replyTargetPubkeys)

        let items = events.map { event in
            let normalizedPubkey = normalizePubkey(event.pubkey)
            let displayEvent = displayEventsBySourceID[event.id.lowercased()]
            let displayProfile = displayEvent.flatMap { displayProfilesByPubkey[normalizePubkey($0.pubkey)] }
            let replyTargetEvent = replyTargetEventsBySourceID[event.id.lowercased()]
            let replyTargetProfile = replyTargetEvent.flatMap {
                replyTargetProfilesByPubkey[normalizePubkey($0.pubkey)]
            }

            return FeedItem(
                event: event,
                profile: actorProfilesByPubkey[normalizedPubkey],
                displayEventOverride: displayEvent,
                displayProfileOverride: displayProfile,
                replyTargetEvent: replyTargetEvent,
                replyTargetProfile: replyTargetProfile
            )
        }
        return filterVisibleFeedItems(items, moderationSnapshot: moderationSnapshot)
    }

    private func buildAuthorOnlyFeedItems(
        relayURLs: [URL],
        events: [NostrEvent],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> [FeedItem] {
        let uniqueEvents = deduplicateEvents(
            filterVisibleEvents(events, moderationSnapshot: moderationSnapshot)
        )
        let profilesByPubkey = await hydrateActorProfiles(
            for: uniqueEvents,
            relayURLs: relayURLs,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
        let items = uniqueEvents.map { event in
            let normalizedPubkey = normalizePubkey(event.pubkey)
            return FeedItem(event: event, profile: profilesByPubkey[normalizedPubkey])
        }
        return filterVisibleFeedItems(items, moderationSnapshot: moderationSnapshot)
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

    private func hydrateActorProfiles(
        for events: [NostrEvent],
        relayURLs: [URL],
        fetchTimeout: TimeInterval = 8,
        relayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    ) async -> [String: NostrProfile] {
        let pubkeysToResolve = Array(
            Set(events.map { normalizePubkey($0.pubkey) })
                .filter { !$0.isEmpty }
        )
        guard !pubkeysToResolve.isEmpty else { return [:] }
        return await fetchProfiles(
            relayURLs: relayURLs,
            pubkeys: pubkeysToResolve,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
    }

    private func resolveDisplayEvents(
        for events: [NostrEvent],
        relayURLs: [URL]
    ) async -> [String: NostrEvent] {
        let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id.lowercased(), $0) })
        var displayEventsBySourceID: [String: NostrEvent] = [:]
        var missingSourceToTargetIDs: [String: String] = [:]
        var missingTargetIDs = Set<String>()

        for event in events where event.isRepost {
            let sourceID = event.id.lowercased()

            if let embeddedEvent = event.resolvedRepostContentEvent {
                displayEventsBySourceID[sourceID] = embeddedEvent
                continue
            }

            guard let targetID = event.repostTargetEventID else { continue }
            if let localTarget = eventsByID[targetID] {
                displayEventsBySourceID[sourceID] = localTarget.resolvedRepostContentEvent ?? localTarget
                continue
            }

            missingSourceToTargetIDs[sourceID] = targetID
            missingTargetIDs.insert(targetID)
        }

        guard !missingTargetIDs.isEmpty else { return displayEventsBySourceID }

        let cachedByID = await seenEventStore.events(ids: Array(missingTargetIDs))
        if !cachedByID.isEmpty {
            var remainingSourceToTargetIDs: [String: String] = [:]
            for (sourceID, targetID) in missingSourceToTargetIDs {
                if let targetEvent = cachedByID[targetID] {
                    displayEventsBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
                } else {
                    remainingSourceToTargetIDs[sourceID] = targetID
                }
            }

            missingSourceToTargetIDs = remainingSourceToTargetIDs
            missingTargetIDs = Set(remainingSourceToTargetIDs.values)
        }

        guard !missingTargetIDs.isEmpty else { return displayEventsBySourceID }
        let referencePointersBySourceID = missingSourceToTargetIDs.reduce(into: [String: NostrEventReferencePointer]()) {
            partialResult,
            entry in
            guard let sourceEvent = eventsByID[entry.key] else { return }
            partialResult[entry.key] = referencePointerForRepostTarget(
                targetEventID: entry.value,
                sourceEvent: sourceEvent
            )
        }

        let fetchedBySourceID = await fetchResolvedReferenceEvents(
            pointersByKey: referencePointersBySourceID,
            baseReadRelayURLs: relayURLs
        )
        for (sourceID, targetEvent) in fetchedBySourceID {
            displayEventsBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
        }

        return displayEventsBySourceID
    }

    private func resolveCachedDisplayEvents(
        for events: [NostrEvent]
    ) async -> [String: NostrEvent] {
        let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id.lowercased(), $0) })
        var displayEventsBySourceID: [String: NostrEvent] = [:]
        var missingSourceToTargetIDs: [String: String] = [:]
        var missingTargetIDs = Set<String>()

        for event in events where event.isRepost {
            let sourceID = event.id.lowercased()

            if let embeddedEvent = event.resolvedRepostContentEvent {
                displayEventsBySourceID[sourceID] = embeddedEvent
                continue
            }

            guard let targetID = event.repostTargetEventID else { continue }
            if let localTarget = eventsByID[targetID] {
                displayEventsBySourceID[sourceID] = localTarget.resolvedRepostContentEvent ?? localTarget
                continue
            }

            missingSourceToTargetIDs[sourceID] = targetID
            missingTargetIDs.insert(targetID)
        }

        guard !missingTargetIDs.isEmpty else { return displayEventsBySourceID }

        let cachedByID = await seenEventStore.events(ids: Array(missingTargetIDs))
        for (sourceID, targetID) in missingSourceToTargetIDs {
            guard let targetEvent = cachedByID[targetID] else { continue }
            displayEventsBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
        }

        return displayEventsBySourceID
    }

    private func resolveCachedReplyTargetEvents(
        for events: [NostrEvent],
        displayEventsBySourceID: [String: NostrEvent]
    ) async -> [String: NostrEvent] {
        let availableEvents = deduplicateEvents(events + Array(displayEventsBySourceID.values))
        let availableEventsByID = Dictionary(
            uniqueKeysWithValues: availableEvents.map { ($0.id.lowercased(), $0) }
        )

        var resolvedBySourceID: [String: NostrEvent] = [:]
        var missingSourceToTargetIDs: [String: String] = [:]
        var missingTargetIDs = Set<String>()

        for event in events {
            let sourceID = event.id.lowercased()
            let replySourceEvent = displayEventsBySourceID[sourceID] ?? event
            guard replySourceEvent.isReplyNote else { continue }
            guard let targetID = normalizedEventID(replySourceEvent.directReplyEventReferenceID) else { continue }

            if let targetEvent = availableEventsByID[targetID] {
                resolvedBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
            } else {
                missingSourceToTargetIDs[sourceID] = targetID
                missingTargetIDs.insert(targetID)
            }
        }

        guard !missingTargetIDs.isEmpty else { return resolvedBySourceID }

        let cachedByID = await seenEventStore.events(ids: Array(missingTargetIDs))
        for (sourceID, targetID) in missingSourceToTargetIDs {
            guard let targetEvent = cachedByID[targetID] else { continue }
            resolvedBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
        }

        return resolvedBySourceID
    }

    private func resolveReplyTargetEvents(
        for events: [NostrEvent],
        displayEventsBySourceID: [String: NostrEvent],
        relayURLs: [URL]
    ) async -> [String: NostrEvent] {
        let availableEvents = deduplicateEvents(events + Array(displayEventsBySourceID.values))
        let availableEventsByID = Dictionary(
            uniqueKeysWithValues: availableEvents.map { ($0.id.lowercased(), $0) }
        )

        var resolvedBySourceID: [String: NostrEvent] = [:]
        var missingSourceToTargetIDs: [String: String] = [:]
        var missingTargetIDs = Set<String>()

        for event in events {
            let sourceID = event.id.lowercased()
            let replySourceEvent = displayEventsBySourceID[sourceID] ?? event
            guard replySourceEvent.isReplyNote else { continue }
            guard let targetID = normalizedEventID(replySourceEvent.directReplyEventReferenceID) else { continue }

            if let localTarget = availableEventsByID[targetID] {
                resolvedBySourceID[sourceID] = localTarget.resolvedRepostContentEvent ?? localTarget
                continue
            }

            missingSourceToTargetIDs[sourceID] = targetID
            missingTargetIDs.insert(targetID)
        }

        guard !missingTargetIDs.isEmpty else { return resolvedBySourceID }

        let cachedByID = await seenEventStore.events(ids: Array(missingTargetIDs))
        if !cachedByID.isEmpty {
            var remainingSourceToTargetIDs: [String: String] = [:]
            for (sourceID, targetID) in missingSourceToTargetIDs {
                if let targetEvent = cachedByID[targetID] {
                    resolvedBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
                } else {
                    remainingSourceToTargetIDs[sourceID] = targetID
                }
            }

            missingSourceToTargetIDs = remainingSourceToTargetIDs
            missingTargetIDs = Set(remainingSourceToTargetIDs.values)
        }

        guard !missingTargetIDs.isEmpty else { return resolvedBySourceID }
        let eventsBySourceID = Dictionary(
            uniqueKeysWithValues: events.map { ($0.id.lowercased(), $0) }
        )
        let referencePointersBySourceID = missingSourceToTargetIDs.reduce(into: [String: NostrEventReferencePointer]()) {
            partialResult,
            entry in
            guard let sourceEvent = eventsBySourceID[entry.key] else { return }
            let replySourceEvent = displayEventsBySourceID[entry.key] ?? sourceEvent
            partialResult[entry.key] = referencePointerForReplyTarget(
                targetEventID: entry.value,
                sourceEvent: replySourceEvent
            )
        }

        let fetchedBySourceID = await fetchResolvedReferenceEvents(
            pointersByKey: referencePointersBySourceID,
            baseReadRelayURLs: relayURLs
        )
        for (sourceID, targetEvent) in fetchedBySourceID {
            resolvedBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
        }

        return resolvedBySourceID
    }

    private func resolveActivityTargetEvents(
        relayURLs: [URL],
        sourceEvents: [NostrEvent],
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        knownTargetPubkeysByEventID: [String: String] = [:]
    ) async -> [ActivityTargetReference: NostrEvent] {
        let eventsByID = Dictionary(uniqueKeysWithValues: sourceEvents.map { ($0.id.lowercased(), $0) })

        var resolved: [ActivityTargetReference: NostrEvent] = [:]
        let uniqueReferences = Array(Set(sourceEvents.compactMap { resolvedActivityTargetReference(for: $0) }))
        guard !uniqueReferences.isEmpty else { return resolved }

        var missingEventIDs = Set<String>()
        var missingAddresses = Set<ActivityAddress>()

        for reference in uniqueReferences {
            switch reference {
            case .eventID(let eventID):
                let normalizedEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalizedEventID.isEmpty else { continue }
                if let event = eventsByID[normalizedEventID] {
                    resolved[reference] = event
                } else {
                    missingEventIDs.insert(normalizedEventID)
                }

            case .address(let address):
                missingAddresses.insert(address)
            }
        }

        if !missingEventIDs.isEmpty {
            let cachedByID = await seenEventStore.events(ids: Array(missingEventIDs))
            if !cachedByID.isEmpty {
                for eventID in Array(missingEventIDs) {
                    if let event = cachedByID[eventID] {
                        resolved[.eventID(eventID)] = event
                        missingEventIDs.remove(eventID)
                    }
                }
            }
        }

        let referencePointersByReference = uniqueReferences.reduce(into: [ActivityTargetReference: NostrEventReferencePointer]()) {
            partialResult,
            reference in
            guard resolved[reference] == nil else { return }
            guard let sourceEvent = firstSourceEvent(for: reference, in: sourceEvents) else { return }
            var pointer = referencePointerForActivityTarget(
                reference,
                sourceEvent: sourceEvent
            )
            if pointer.targetPubkey == nil,
               case .eventID(let eventID) = reference,
               let knownTargetPubkey = knownTargetPubkeysByEventID[eventID],
               !knownTargetPubkey.isEmpty {
                pointer = NostrEventReferencePointer(
                    normalizedIdentifier: pointer.normalizedIdentifier,
                    target: pointer.target,
                    relayHints: pointer.relayHints,
                    authorPubkey: knownTargetPubkey
                )
            }
            partialResult[reference] = pointer
        }

        let fetchedByReference = await fetchResolvedReferenceEvents(
            pointersByKey: referencePointersByReference,
            baseReadRelayURLs: relayURLs,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
        for (reference, event) in fetchedByReference {
            resolved[reference] = event
        }

        return resolved
    }

    private func newestAddressEvents(
        from events: [NostrEvent],
        addresses: Set<ActivityAddress>
    ) -> [ActivityAddress: NostrEvent] {
        guard !addresses.isEmpty else { return [:] }

        var newestByAddress: [ActivityAddress: NostrEvent] = [:]
        let sorted = deduplicateEvents(events).sorted(by: { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        })

        for event in sorted {
            let normalizedPubkey = event.pubkey.lowercased()
            guard let identifier = firstReplaceableIdentifier(in: event) else { continue }
            let address = ActivityAddress(kind: event.kind, pubkey: normalizedPubkey, identifier: identifier)
            guard addresses.contains(address) else { continue }
            if newestByAddress[address] == nil {
                newestByAddress[address] = event
            }
        }

        return newestByAddress
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

    private func fallbackActivitySnippet(for event: NostrEvent, action: ActivityAction) -> String {
        switch action {
        case .mention, .reply, .quoteShare:
            return event.activitySnippet()
        case .reaction(let reaction):
            return reaction.displayValue
        case .reshare:
            return "Re-shared your note"
        }
    }

    private func filteredActivityEvents(
        from events: [NostrEvent],
        currentUserPubkey: String
    ) -> [NostrEvent] {
        deduplicateEvents(
            events
                .filter { $0.activityAction != nil }
                .filter { $0.mentionedPubkeys.contains(where: { $0.lowercased() == currentUserPubkey }) }
                .filter { normalizePubkey($0.pubkey) != currentUserPubkey }
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
        )
    }

    private func filteredNoteActivityEvents(
        from events: [NostrEvent],
        rootEventID: String
    ) -> [NostrEvent] {
        deduplicateEvents(
            events
                .filter { event in
                    guard let action = event.activityAction else { return false }
                    guard resolvedActivityTargetReference(for: event)?.eventID?.lowercased() == rootEventID else {
                        return false
                    }

                    switch action {
                    case .reaction, .reshare, .quoteShare:
                        return true
                    case .mention, .reply:
                        return false
                    }
                }
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
        )
    }

    private func resolvedActivityTargetReference(for event: NostrEvent) -> ActivityTargetReference? {
        if let activityTargetReference = event.activityTargetReference {
            return activityTargetReference
        }

        guard let action = event.activityAction else { return nil }
        switch action {
        case .reaction, .reshare:
            guard let eventID = normalizedEventID(event.lastEventReferenceID) else { return nil }
            return .eventID(eventID)
        case .mention, .reply, .quoteShare:
            return nil
        }
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

    private func fetchResolvedReferenceEvents<Key: Hashable>(
        pointersByKey: [Key: NostrEventReferencePointer],
        baseReadRelayURLs: [URL],
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [Key: NostrEvent] {
        guard !pointersByKey.isEmpty else { return [:] }

        let resolvedByPointer = await fetchReferencedEvents(
            references: Array(pointersByKey.values),
            baseRelayURLs: baseReadRelayURLs,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )

        var resolvedByKey: [Key: NostrEvent] = [:]
        for (key, pointer) in pointersByKey {
            guard let event = resolvedByPointer[pointer] else { continue }
            resolvedByKey[key] = event
        }
        return resolvedByKey
    }

    private func referencePointerForRepostTarget(
        targetEventID: String,
        sourceEvent: NostrEvent
    ) -> NostrEventReferencePointer {
        NostrEventReferencePointer(
            normalizedIdentifier: targetEventID,
            target: .eventID(targetEventID),
            relayHints: relayHintsForEventReference(
                targetEventID: targetEventID,
                sourceEvent: sourceEvent,
                preferredTagNames: ["e"]
            ),
            authorPubkey: repostTargetAuthorHint(in: sourceEvent)
        )
    }

    private func referencePointerForReplyTarget(
        targetEventID: String,
        sourceEvent: NostrEvent
    ) -> NostrEventReferencePointer {
        NostrEventReferencePointer(
            normalizedIdentifier: targetEventID,
            target: .eventID(targetEventID),
            relayHints: relayHintsForEventReference(
                targetEventID: targetEventID,
                sourceEvent: sourceEvent,
                preferredTagNames: ["e"]
            ),
            authorPubkey: replyTargetAuthorHint(in: sourceEvent)
        )
    }

    private func referencePointerForActivityTarget(
        _ reference: ActivityTargetReference,
        sourceEvent: NostrEvent
    ) -> NostrEventReferencePointer {
        switch reference {
        case .eventID(let eventID):
            return NostrEventReferencePointer(
                normalizedIdentifier: eventID,
                target: .eventID(eventID),
                relayHints: relayHintsForEventReference(
                    targetEventID: eventID,
                    sourceEvent: sourceEvent,
                    preferredTagNames: ["q", "e"]
                ),
                authorPubkey: activityTargetAuthorHint(in: sourceEvent)
            )

        case .address(let address):
            let normalizedIdentifier = "\(address.kind):\(address.pubkey):\(address.identifier)"
            return NostrEventReferencePointer(
                normalizedIdentifier: normalizedIdentifier,
                target: .replaceable(
                    kind: address.kind,
                    pubkey: address.pubkey,
                    identifier: address.identifier
                ),
                relayHints: relayHintsForAddressReference(address, sourceEvent: sourceEvent),
                authorPubkey: address.pubkey
            )
        }
    }

    private func relayHintsForEventReference(
        targetEventID: String,
        sourceEvent: NostrEvent,
        preferredTagNames: Set<String>
    ) -> [URL] {
        RelayURLSupport.normalizedRelayURLs(
            sourceEvent.tags.compactMap { tag in
                guard tag.count > 2 else { return nil }
                guard let tagName = tag.first?.lowercased(), preferredTagNames.contains(tagName) else {
                    return nil
                }
                guard normalizedEventID(tag[1]) == targetEventID else { return nil }
                return RelayURLSupport.normalizedURL(from: tag[2])
            }
        )
    }

    private func relayHintsForAddressReference(
        _ address: ActivityAddress,
        sourceEvent: NostrEvent
    ) -> [URL] {
        let normalizedIdentifier = "\(address.kind):\(address.pubkey):\(address.identifier)"
        return RelayURLSupport.normalizedRelayURLs(
            sourceEvent.tags.compactMap { tag in
                guard tag.count > 2 else { return nil }
                guard tag.first?.lowercased() == "a" else { return nil }
                let candidate = tag[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard candidate == normalizedIdentifier else { return nil }
                return RelayURLSupport.normalizedURL(from: tag[2])
            }
        )
    }

    private func repostTargetAuthorHint(in event: NostrEvent) -> String? {
        firstTaggedPubkey(in: event)
    }

    private func replyTargetAuthorHint(in event: NostrEvent) -> String? {
        lastTaggedPubkey(in: event) ?? firstTaggedPubkey(in: event)
    }

    private func activityTargetAuthorHint(in event: NostrEvent) -> String? {
        firstTaggedPubkey(in: event)
    }

    private func firstTaggedPubkey(in event: NostrEvent) -> String? {
        for tag in event.tags {
            guard let name = tag.first?.lowercased(), name == "p", tag.count > 1 else { continue }
            if let pubkey = normalizedEventID(tag[1]) {
                return pubkey
            }
        }
        return nil
    }

    private func lastTaggedPubkey(in event: NostrEvent) -> String? {
        for tag in event.tags.reversed() {
            guard let name = tag.first?.lowercased(), name == "p", tag.count > 1 else { continue }
            if let pubkey = normalizedEventID(tag[1]) {
                return pubkey
            }
        }
        return nil
    }

    private func firstSourceEvent(
        for reference: ActivityTargetReference,
        in sourceEvents: [NostrEvent]
    ) -> NostrEvent? {
        for event in sourceEvents {
            guard resolvedActivityTargetReference(for: event) == reference else { continue }
            return event
        }
        return nil
    }

    private func normalizedEventID(_ value: String?) -> String? {
        let normalized = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
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

    private func profileMatchesQuery(profile: NostrProfile, pubkey: String, query: String) -> Bool {
        Self.profileSearchScore(profile: profile, pubkey: pubkey, query: query) != nil
    }

    private static func profileSearchScore(profile: NostrProfile, pubkey: String, query: String) -> Int? {
        ProfileSearchSupport.score(profile: profile, pubkey: pubkey, query: query)
    }

    private func matchedProfileResults(
        from events: [NostrEvent],
        query: String,
        limit: Int
    ) async -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var matches: [(result: ProfileSearchResult, score: Int)] = []
        var fetchedProfiles: [String: NostrProfile] = [:]

        for event in events {
            guard let profile = NostrProfile.decode(from: event.content) else { continue }
            let pubkey = normalizePubkey(event.pubkey)
            guard !pubkey.isEmpty else { continue }
            guard seen.insert(pubkey).inserted else { continue }
            guard let score = Self.profileSearchScore(profile: profile, pubkey: pubkey, query: query) else { continue }

            fetchedProfiles[pubkey] = profile
            matches.append((
                result: ProfileSearchResult(pubkey: pubkey, profile: profile, createdAt: event.createdAt),
                score: score
            ))
        }

        if !fetchedProfiles.isEmpty {
            await profileCache.store(profiles: fetchedProfiles, missed: [])
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    if lhs.result.createdAt == rhs.result.createdAt {
                        return lhs.result.pubkey < rhs.result.pubkey
                    }
                    return lhs.result.createdAt > rhs.result.createdAt
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map(\.result)
    }

    private func mergeProfileSearchResults(
        groups: [[ProfileSearchResult]],
        limit: Int
    ) -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var ordered: [ProfileSearchResult] = []

        for group in groups {
            for result in group {
                let normalizedPubkey = result.pubkey.lowercased()
                guard seen.insert(normalizedPubkey).inserted else { continue }
                ordered.append(result)

                if ordered.count >= limit {
                    return ordered
                }
            }
        }

        return ordered
    }

    private func recentProfileResults(
        from events: [NostrEvent],
        limit: Int
    ) async -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var results: [ProfileSearchResult] = []
        var fetchedProfiles: [String: NostrProfile] = [:]

        for event in events {
            guard let profile = NostrProfile.decode(from: event.content) else { continue }
            let pubkey = normalizePubkey(event.pubkey)
            guard !pubkey.isEmpty else { continue }
            guard seen.insert(pubkey).inserted else { continue }

            fetchedProfiles[pubkey] = profile
            results.append(
                ProfileSearchResult(
                    pubkey: pubkey,
                    profile: profile,
                    createdAt: event.createdAt
                )
            )

            if results.count >= limit {
                break
            }
        }

        if !fetchedProfiles.isEmpty {
            await profileCache.store(profiles: fetchedProfiles, missed: [])
        }

        return results
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

    private func fetchProfilesForPubkeys(
        relayURLs: [URL],
        pubkeys: [String],
        timeout: TimeInterval,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async -> [String: NostrProfile] {
        let normalizedTargets = Array(
            Set(
                pubkeys
                    .map { normalizePubkey($0) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalizedTargets.isEmpty else { return [:] }
        let targetRelayURLs = normalizedRelayURLs(relayURLs)
        guard !targetRelayURLs.isEmpty else { return [:] }

        var collectedProfiles: [String: NostrProfile] = [:]

        for chunk in normalizedTargets.chunked(into: 100) {
            let metadataFilter = NostrFilter(
                authors: chunk,
                kinds: [0],
                limit: max(chunk.count * 2, 100)
            )

            guard let metadataEvents = try? await fetchTimelineEvents(
                relayURLs: targetRelayURLs,
                filter: metadataFilter,
                timeout: timeout,
                useCache: false,
                relayFetchMode: relayFetchMode
            ) else {
                continue
            }

            let decoded = decodeNewestProfiles(from: metadataEvents)
            guard !decoded.isEmpty else { continue }
            collectedProfiles.merge(decoded, uniquingKeysWith: { existing, _ in existing })
        }

        return collectedProfiles
    }

    private func decodeNewestProfiles(from events: [NostrEvent]) -> [String: NostrProfile] {
        let newestFirst = deduplicateEvents(events)
            .filter { $0.kind == 0 }
            .sorted(by: { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            })

        var decodedByPubkey: [String: NostrProfile] = [:]
        for event in newestFirst {
            let normalizedPubkey = normalizePubkey(event.pubkey)
            guard !normalizedPubkey.isEmpty else { continue }
            guard decodedByPubkey[normalizedPubkey] == nil else { continue }
            guard let profile = NostrProfile.decode(from: event.content) else { continue }
            decodedByPubkey[normalizedPubkey] = profile
        }
        return decodedByPubkey
    }

    private func fetchTimelineEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true
    ) async throws -> [NostrEvent] {
        let events: [NostrEvent]
        let fetchOperation = {
            try await fetchEventsEnforcingTimeout(
                relayURL: relayURL,
                filter: filter,
                timeout: timeout
            )
        }
        if !useCache {
            events = try await fetchOperation()
        } else {
            let cacheKey = generateTimelineKey(relayURL: relayURL, filter: filter)
            events = try await timelineCache.events(for: cacheKey) {
                try await fetchOperation()
            }
        }

        if !events.isEmpty {
            await seenEventStore.store(events: events)
        }
        return events
    }

    private func fetchTimelineEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [NostrEvent] {
        let targets = normalizedRelayURLs(relayURLs)
        guard !targets.isEmpty else { return [] }

        if relayFetchMode == .firstRelayWithEvents {
            let result: (events: [NostrEvent], successfulFetches: Int, firstError: Error?) = await withTaskGroup(
                of: (events: [NostrEvent]?, error: Error?).self,
                returning: (events: [NostrEvent], successfulFetches: Int, firstError: Error?).self
            ) { group in
                for relayURL in targets {
                    group.addTask {
                        do {
                            let events = try await fetchTimelineEvents(
                                relayURL: relayURL,
                                filter: filter,
                                timeout: timeout,
                                useCache: useCache
                            )
                            return (events: events, error: nil)
                        } catch {
                            return (events: nil, error: error)
                        }
                    }
                }

                var firstError: Error?
                var successfulFetches = 0

                for await item in group {
                    if let events = item.events {
                        successfulFetches += 1
                        guard !events.isEmpty else { continue }
                        group.cancelAll()
                        return (events, successfulFetches, firstError)
                    } else if firstError == nil, let error = item.error {
                        firstError = error
                    }
                }

                return ([], successfulFetches, firstError)
            }

            if !result.events.isEmpty {
                return mergedTimelineEvents(result.events, filter: filter)
            }

            if result.successfulFetches == 0, let firstError = result.firstError {
                throw firstError
            }
            return []
        }

        if relayFetchMode == .firstNonEmptyRelay {
            let result = await fetchFirstNonEmptyRelayResult(
                relayURLs: targets,
                filter: filter,
                timeout: timeout,
                useCache: useCache
            )

            if result.successfulFetches > 0 {
                return mergedTimelineEvents(result.mergedEvents, filter: filter)
            }

            if !result.didTimeOut, result.successfulFetches == 0, let firstError = result.firstError {
                throw firstError
            }
            return []
        }

        let result: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?) = await withTaskGroup(
            of: (events: [NostrEvent]?, error: Error?).self,
            returning: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?).self
        ) { group in
            for relayURL in targets {
                group.addTask {
                    do {
                        let events = try await fetchTimelineEvents(
                            relayURL: relayURL,
                            filter: filter,
                            timeout: timeout,
                            useCache: useCache
                        )
                        return (events: events, error: nil)
                    } catch {
                        return (events: nil, error: error)
                    }
                }
            }

            var mergedEvents: [NostrEvent] = []
            var firstError: Error?
            var successfulFetches = 0

            for await item in group {
                if let events = item.events {
                    successfulFetches += 1
                    mergedEvents.append(contentsOf: events)
                } else if firstError == nil, let error = item.error {
                    firstError = error
                }
            }

            return (mergedEvents, successfulFetches, firstError)
        }

        if result.successfulFetches > 0 {
            return mergedTimelineEvents(result.mergedEvents, filter: filter)
        }

        if result.successfulFetches == 0, let firstError = result.firstError {
            throw firstError
        }
        return []
    }

    private func fetchTimelineEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool
    ) async throws -> [NostrEvent] {
        if relayOnly {
            return try await fetchTimelineEventsFromRelaysOnly(
                relayURLs: relayURLs,
                filter: filter,
                timeout: timeout,
                useCache: useCache,
                relayFetchMode: relayFetchMode
            )
        }

        return try await fetchTimelineEvents(
            relayURLs: relayURLs,
            filter: filter,
            timeout: timeout,
            useCache: useCache,
            relayFetchMode: relayFetchMode
        )
    }

    private func fetchTimelineEventsFromRelaysOnly(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [NostrEvent] {
        let targets = normalizedRelayURLs(relayURLs)
        guard !targets.isEmpty else { return [] }

        if relayFetchMode == .firstRelayWithEvents {
            let result: (events: [NostrEvent], successfulFetches: Int, firstError: Error?) = await withTaskGroup(
                of: (events: [NostrEvent]?, error: Error?).self,
                returning: (events: [NostrEvent], successfulFetches: Int, firstError: Error?).self
            ) { group in
                for relayURL in targets {
                    group.addTask {
                        do {
                            let events = try await fetchTimelineEvents(
                                relayURL: relayURL,
                                filter: filter,
                                timeout: timeout,
                                useCache: useCache
                            )
                            return (events: events, error: nil)
                        } catch {
                            return (events: nil, error: error)
                        }
                    }
                }

                var firstError: Error?
                var successfulFetches = 0

                for await item in group {
                    if let events = item.events {
                        successfulFetches += 1
                        guard !events.isEmpty else { continue }
                        group.cancelAll()
                        return (events, successfulFetches, firstError)
                    } else if firstError == nil, let error = item.error {
                        firstError = error
                    }
                }

                return ([], successfulFetches, firstError)
            }

            if !result.events.isEmpty {
                return mergedTimelineEvents(result.events, filter: filter)
            }

            if result.successfulFetches == 0, let firstError = result.firstError {
                throw firstError
            }
            return []
        }

        if relayFetchMode == .firstNonEmptyRelay {
            let result = await fetchFirstNonEmptyRelayResult(
                relayURLs: targets,
                filter: filter,
                timeout: timeout,
                useCache: useCache
            )

            if result.successfulFetches > 0 {
                return mergedTimelineEvents(result.mergedEvents, filter: filter)
            }

            if !result.didTimeOut, result.successfulFetches == 0, let firstError = result.firstError {
                throw firstError
            }
            return []
        }

        let result: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?) = await withTaskGroup(
            of: (events: [NostrEvent]?, error: Error?).self,
            returning: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?).self
        ) { group in
            for relayURL in targets {
                group.addTask {
                    do {
                        let events = try await fetchTimelineEvents(
                            relayURL: relayURL,
                            filter: filter,
                            timeout: timeout,
                            useCache: useCache
                        )
                        return (events: events, error: nil)
                    } catch {
                        return (events: nil, error: error)
                    }
                }
            }

            var mergedEvents: [NostrEvent] = []
            var firstError: Error?
            var successfulFetches = 0

            for await item in group {
                if let events = item.events {
                    successfulFetches += 1
                    mergedEvents.append(contentsOf: events)
                } else if firstError == nil, let error = item.error {
                    firstError = error
                }
            }

            return (mergedEvents, successfulFetches, firstError)
        }

        if result.successfulFetches > 0 {
            return mergedTimelineEvents(result.mergedEvents, filter: filter)
        }

        if result.successfulFetches == 0, let firstError = result.firstError {
            throw firstError
        }
        return []
    }

    private func fetchFirstNonEmptyRelayResult(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval,
        useCache: Bool
    ) async -> (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?, didTimeOut: Bool) {
        enum RelayProgress {
            case relay(events: [NostrEvent]?, error: Error?)
            case deadline
            case graceWindowClosed
        }

        return await withTaskGroup(
            of: RelayProgress.self,
            returning: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?, didTimeOut: Bool).self
        ) { group in
            for relayURL in relayURLs {
                group.addTask {
                    do {
                        let events = try await fetchTimelineEvents(
                            relayURL: relayURL,
                            filter: filter,
                            timeout: timeout,
                            useCache: useCache
                        )
                        return .relay(events: events, error: nil)
                    } catch {
                        return .relay(events: nil, error: error)
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds(for: timeout))
                return .deadline
            }

            var mergedEvents: [NostrEvent] = []
            var firstError: Error?
            var successfulFetches = 0
            var hasStartedGraceWindow = false

            for await progress in group {
                switch progress {
                case .relay(let events, let error):
                    if let events {
                        successfulFetches += 1
                        mergedEvents.append(contentsOf: events)

                        if !hasStartedGraceWindow {
                            hasStartedGraceWindow = true
                            let graceTimeout = min(timeout, Self.dittoEOSEGraceTimeout)
                            group.addTask {
                                try? await Task.sleep(
                                    nanoseconds: Self.timeoutNanoseconds(for: graceTimeout)
                                )
                                return .graceWindowClosed
                            }
                        }
                    } else if firstError == nil, let error {
                        firstError = error
                    }
                case .graceWindowClosed:
                    if successfulFetches > 0 {
                        group.cancelAll()
                        return (mergedEvents, successfulFetches, firstError, false)
                    }
                case .deadline:
                    group.cancelAll()
                    return (mergedEvents, successfulFetches, firstError, true)
                }
            }

            return (mergedEvents, successfulFetches, firstError, false)
        }
    }

    private func fetchEventsEnforcingTimeout(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        guard timeout > 0 else {
            return try await relayClient.fetchEvents(
                relayURL: relayURL,
                filter: filter,
                timeout: timeout
            )
        }

        return try await withThrowingTaskGroup(of: [NostrEvent].self) { group in
            group.addTask {
                try await relayClient.fetchEvents(
                    relayURL: relayURL,
                    filter: filter,
                    timeout: timeout
                )
            }

            group.addTask {
                try await Task.sleep(
                    nanoseconds: Self.timeoutNanoseconds(for: timeout)
                )
                throw RelayFetchTimeoutError.timedOut
            }

            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw RelayFetchTimeoutError.timedOut
            }
            return result
        }
    }

    private nonisolated static func timeoutNanoseconds(for timeout: TimeInterval) -> UInt64 {
        UInt64(max(timeout, 0) * 1_000_000_000)
    }

    private func mergedTimelineEvents(_ events: [NostrEvent], filter: NostrFilter) -> [NostrEvent] {
        let merged = deduplicateEvents(events).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }

        if let limit = filter.limit {
            return Array(merged.prefix(limit))
        }
        return merged
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

        let newestProfiles = decodeNewestProfiles(from: events)
        if !newestProfiles.isEmpty {
            await profileCache.store(profiles: newestProfiles, missed: [])
        }

        for event in events where event.kind == 3 {
            let snapshot = FollowListSnapshot(
                content: event.content,
                tags: event.tags,
                createdAt: event.createdAt
            )
            await followListCache.storeSnapshot(snapshot, for: normalizePubkey(event.pubkey))
            await relayHintCache.storeHints(snapshot.relayHintsByPubkey)
        }
    }

    private func extractFollowListSnapshot(from events: [NostrEvent]) -> FollowListSnapshot? {
        guard let newest = events
            .filter({ $0.kind == 3 })
            .sorted(by: { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            })
            .first else {
            return nil
        }

        return FollowListSnapshot(
            content: newest.content,
            tags: newest.tags,
            createdAt: newest.createdAt
        )
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

    private func metadataRelayURLs(primaryRelayURLs: [URL]) -> [URL] {
        normalizedRelayURLs(primaryRelayURLs + Self.metadataFallbackRelayURLs)
    }

    private func cachedAuthorRelayDirectoryEntries(
        for pubkeys: [String]
    ) async -> [String: AuthorRelayDirectoryEntry] {
        guard !pubkeys.isEmpty else { return [:] }

        if let directoryCache = relayHintCache as? any AuthorRelayDirectoryCaching {
            return await directoryCache.entries(for: pubkeys)
        }

        let relayHintsByPubkey = await relayHintCache.relayHints(for: pubkeys)
        var entries: [String: AuthorRelayDirectoryEntry] = [:]

        for pubkey in normalizedUniquePubkeys(pubkeys) {
            entries[pubkey] = AuthorRelayDirectoryEntry(
                readRelayURLs: [],
                writeRelayURLs: [],
                hintRelayURLs: relayHintsByPubkey[pubkey] ?? [],
                refreshedAt: nil
            )
        }

        return entries
    }

    private func fetchAuthorRelayDirectoryEntries(
        for pubkeys: [String],
        baseReadRelayURLs: [URL],
        existingEntries: [String: AuthorRelayDirectoryEntry]
    ) async -> [String: AuthorRelayDirectoryEntry] {
        let normalizedPubkeys = normalizedUniquePubkeys(pubkeys)
        guard !normalizedPubkeys.isEmpty else { return [:] }

        let profileEventService = ProfileEventService(
            relayClient: relayClient,
            seenEventStore: seenEventStore
        )
        let normalizedBaseReadRelayURLs = normalizedRelayURLs(baseReadRelayURLs)

        var fetchedEntries: [String: AuthorRelayDirectoryEntry] = [:]
        for pubkey in normalizedPubkeys {
            let existingEntry = existingEntries[pubkey]
            let discoveryRelayURLs = normalizedRelayURLs(
                (existingEntry?.hintRelayURLs ?? [])
                    + normalizedBaseReadRelayURLs
                    + Self.metadataFallbackRelayURLs
            )
            guard !discoveryRelayURLs.isEmpty else { continue }

            let snapshot = await profileEventService.fetchRelayConnectionsSnapshot(
                relayURLs: discoveryRelayURLs,
                pubkey: pubkey
            )
            guard !snapshot.isEmpty else { continue }

            let entry = snapshot.authorRelayDirectoryEntry(
                hintRelayURLs: existingEntry?.hintRelayURLs ?? []
            )
            fetchedEntries[pubkey] = entry
        }

        if let directoryCache = relayHintCache as? any AuthorRelayDirectoryCaching {
            for (pubkey, entry) in fetchedEntries {
                await directoryCache.store(entry: entry, for: pubkey)
            }
        }

        return fetchedEntries
    }

    private func recordOutboxPlanDiagnostics(
        authors: [String],
        directoryEntries: [String: AuthorRelayDirectoryEntry]
    ) async {
        guard !authors.isEmpty else { return }

        var directoryHits = 0
        var writeRelayFallbacks = 0
        var genericReadRelayFallbacks = 0

        for author in authors {
            guard let entry = directoryEntries[author] else {
                genericReadRelayFallbacks += 1
                continue
            }

            if !entry.readRelayURLs.isEmpty || !entry.writeRelayURLs.isEmpty {
                directoryHits += 1
            }
            if entry.readRelayURLs.isEmpty, !entry.writeRelayURLs.isEmpty {
                writeRelayFallbacks += 1
            }
            if entry.readRelayURLs.isEmpty {
                genericReadRelayFallbacks += 1
            }
        }

        await outboxDiagnosticsStore.record(
            directoryHits: directoryHits,
            writeRelayFallbacks: writeRelayFallbacks,
            genericReadRelayFallbacks: genericReadRelayFallbacks
        )
    }

    private func groupedAuthorsByRelaySignature(
        authors: [String],
        relayPlan: AuthorRelayPlan
    ) -> [String: (relayURLs: [URL], authors: [String])] {
        var grouped: [String: (relayURLs: [URL], authors: [String])] = [:]

        for author in authors {
            let relayURLs = relayPlan.relayURLs(for: author)
            let signature = relayURLs
                .map { $0.absoluteString.lowercased() }
                .joined(separator: "|")

            if var existing = grouped[signature] {
                existing.authors.append(author)
                grouped[signature] = existing
            } else {
                grouped[signature] = (relayURLs: relayURLs, authors: [author])
            }
        }

        return grouped
    }

    private func mergedFeedItemsKeepingNewest(
        existing: [FeedItem],
        incoming: [FeedItem]
    ) -> [FeedItem] {
        guard !incoming.isEmpty else { return existing }

        var itemsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for item in incoming {
            itemsByID[item.id] = item
        }

        return itemsByID.values.sorted { lhs, rhs in
            if lhs.event.createdAt == rhs.event.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.event.createdAt > rhs.event.createdAt
        }
    }

    private func normalizedHintRelayMap(_ hintsByPubkey: [String: [URL]]) -> [String: [URL]] {
        var normalizedHints: [String: [URL]] = [:]

        for (pubkey, relayURLs) in hintsByPubkey {
            let normalizedPubkey = normalizePubkey(pubkey)
            guard !normalizedPubkey.isEmpty else { continue }

            let normalizedRelayURLs = RelayURLSupport.normalizedRelayURLs(relayURLs)
            guard !normalizedRelayURLs.isEmpty else { continue }
            normalizedHints[normalizedPubkey] = normalizedRelayURLs
        }

        return normalizedHints
    }
    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func mentionSearchRelayTargets() async -> [URL] {
        let readRelayURLs = await MainActor.run {
            RelaySettingsStore.shared.readRelayURLs
        }
        return normalizedRelayURLs(
            [Self.nostrArchivesSearchRelayURL] + readRelayURLs + Self.metadataFallbackRelayURLs
        )
    }

    private func shouldUseNostrArchivesRESTSearch(relayURLs: [URL]) -> Bool {
        relayURLs.contains { relayURL in
            relayURL.host?.lowercased() == Self.nostrArchivesSearchRelayURL.host?.lowercased()
        }
    }

    private func cachedProfileSearchResults(
        query: String,
        limit: Int,
        preferredPubkeys: Set<String>
    ) async -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        let recentPubkeys = await profileCache.recentProfilePubkeys(limit: max(limit * 2, 24))
        let orderedCandidatePubkeys = orderedUniqueProfileSearchPubkeys(
            preferredPubkeys: preferredPubkeys,
            recentPubkeys: recentPubkeys
        )
        guard !orderedCandidatePubkeys.isEmpty else { return [] }

        let cachedProfiles = await profileCache.cachedProfiles(pubkeys: orderedCandidatePubkeys)
        let recencyByPubkey = Dictionary(
            uniqueKeysWithValues: recentPubkeys.enumerated().map { index, pubkey in
                (pubkey, max(limit * 2 - index, 0))
            }
        )

        return orderedCandidatePubkeys.compactMap { pubkey in
            guard let profile = cachedProfiles[pubkey] else { return nil }
            guard Self.profileSearchScore(profile: profile, pubkey: pubkey, query: query) != nil else {
                return nil
            }

            return ProfileSearchResult(
                pubkey: pubkey,
                profile: profile,
                createdAt: recencyByPubkey[pubkey] ?? 0
            )
        }
    }

    private func orderedUniqueProfileSearchPubkeys(
        preferredPubkeys: Set<String>,
        recentPubkeys: [String]
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in preferredPubkeys.sorted() where seen.insert(pubkey).inserted {
            ordered.append(pubkey)
        }

        for pubkey in recentPubkeys where seen.insert(pubkey).inserted {
            ordered.append(pubkey)
        }

        return ordered
    }

    private func mergedProfileSearchResults(
        groups: [[ProfileSearchResult]],
        query: String,
        preferredPubkeys: Set<String>,
        limit: Int
    ) -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var collected: [ProfileSearchResult] = []

        for group in groups {
            for result in group {
                let normalizedPubkey = normalizePubkey(result.pubkey)
                guard !normalizedPubkey.isEmpty, seen.insert(normalizedPubkey).inserted else { continue }
                collected.append(
                    ProfileSearchResult(
                        pubkey: normalizedPubkey,
                        profile: result.profile,
                        createdAt: result.createdAt
                    )
                )
            }
        }

        let sorted = collected.sorted { lhs, rhs in
            let lhsScore = mergedProfileSearchScore(
                result: lhs,
                query: query,
                preferredPubkeys: preferredPubkeys
            )
            let rhsScore = mergedProfileSearchScore(
                result: rhs,
                query: query,
                preferredPubkeys: preferredPubkeys
            )
            if lhsScore == rhsScore {
                if lhs.createdAt == rhs.createdAt {
                    return lhs.pubkey < rhs.pubkey
                }
                return lhs.createdAt > rhs.createdAt
            }
            return lhsScore > rhsScore
        }

        return Array(sorted.prefix(limit))
    }

    private func mergedProfileSearchScore(
        result: ProfileSearchResult,
        query: String,
        preferredPubkeys: Set<String>
    ) -> Int {
        let normalizedPubkey = normalizePubkey(result.pubkey)
        var score = 0

        if normalizedPubkey == query {
            score = 1_000
        } else if normalizedPubkey.hasPrefix(query) {
            score = 920
        } else if let profile = result.profile,
                  let profileScore = Self.profileSearchScore(profile: profile, pubkey: normalizedPubkey, query: query) {
            score = profileScore
        } else {
            score = 500
        }

        if preferredPubkeys.contains(normalizedPubkey) {
            score += 200
        }

        return score
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

private enum RelayFetchTimeoutError: Error {
    case timedOut
}
