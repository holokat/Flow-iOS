import Foundation

struct NostrFollowResolver: Sendable {
    private let relayClient: any NostrRelayEventFetching
    private let relayTimelineFetcher: RelayTimelineFetcher
    private let followListCache: any FollowListSnapshotStoring
    private let relayHintCache: any ProfileRelayHintCaching
    private let seenEventStore: any SeenEventStoring
    private let outboxDiagnosticsStore: OutboxRecoveryDiagnosticsStore
    private let metadataFallbackRelayURLs: [URL]
    private let followListFreshCacheAge: TimeInterval

    init(
        relayClient: any NostrRelayEventFetching,
        relayTimelineFetcher: RelayTimelineFetcher,
        followListCache: any FollowListSnapshotStoring,
        relayHintCache: any ProfileRelayHintCaching,
        seenEventStore: any SeenEventStoring,
        outboxDiagnosticsStore: OutboxRecoveryDiagnosticsStore,
        metadataFallbackRelayURLs: [URL],
        followListFreshCacheAge: TimeInterval
    ) {
        self.relayClient = relayClient
        self.relayTimelineFetcher = relayTimelineFetcher
        self.followListCache = followListCache
        self.relayHintCache = relayHintCache
        self.seenEventStore = seenEventStore
        self.outboxDiagnosticsStore = outboxDiagnosticsStore
        self.metadataFallbackRelayURLs = metadataFallbackRelayURLs
        self.followListFreshCacheAge = followListFreshCacheAge
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

        for batch in chunks(candidates.filter { !resultSet.contains($0) }, size: 80) {
            let filter = NostrFilter(
                authors: batch,
                kinds: [3],
                limit: min(max(limit * 6, 24), max(batch.count * 2, 1)),
                tagFilters: ["p": [normalizedProfilePubkey]]
            )

            guard let events = try? await relayTimelineFetcher.fetchTimelineEvents(
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
            let events = try await relayTimelineFetcher.fetchTimelineEvents(
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
            maxAge: followListFreshCacheAge
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
            fallbackRelayURLs: metadataFallbackRelayURLs
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
                    + metadataFallbackRelayURLs
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

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func chunks<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<Swift.min($0 + size, values.count)])
        }
    }
}
