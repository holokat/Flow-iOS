import Foundation

struct NostrProfileResolver: Sendable {
    private let profileCache: any ProfileCaching
    private let relayHintCache: any ProfileRelayHintCaching
    private let relayTimelineFetcher: RelayTimelineFetcher
    private let nostrArchivesSearchRelayURL: URL
    private let metadataFallbackRelayURLs: [URL]
    private let metadataRequestCoordinator: MetadataRequestCoordinator

    init(
        profileCache: any ProfileCaching,
        relayHintCache: any ProfileRelayHintCaching,
        relayTimelineFetcher: RelayTimelineFetcher,
        nostrArchivesSearchRelayURL: URL,
        metadataFallbackRelayURLs: [URL],
        metadataRequestCoordinator: MetadataRequestCoordinator = .shared
    ) {
        self.profileCache = profileCache
        self.relayHintCache = relayHintCache
        self.relayTimelineFetcher = relayTimelineFetcher
        self.nostrArchivesSearchRelayURL = nostrArchivesSearchRelayURL
        self.metadataFallbackRelayURLs = metadataFallbackRelayURLs
        self.metadataRequestCoordinator = metadataRequestCoordinator
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
            metadataEvents = try await relayTimelineFetcher.fetchTimelineEvents(
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
                metadataEvents = try await relayTimelineFetcher.fetchTimelineEvents(
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

        let profileRequest = await metadataRequestCoordinator.collectProfiles(Array(unresolvedPubkeys))
        unresolvedPubkeys = Set(
            profileRequest.pubkeysToFetch
                .map(normalizePubkey)
                .filter { !$0.isEmpty }
        )
        guard !unresolvedPubkeys.isEmpty else {
            await metadataRequestCoordinator.waitForProfiles(profileRequest.requestedPubkeys)
            let refreshed = await profileCache.resolve(
                pubkeys: profileRequest.requestedPubkeys,
                ignoringKnownMisses: true
            )
            profilesByPubkey.merge(refreshed.hits, uniquingKeysWith: { _, new in new })
            return profilesByPubkey
        }

        let primaryRelayTargets = normalizedRelayURLs(relayURLs)
        let prioritizedRelayTargets = await relayHintCache.prioritizedRelayURLs(
            for: Array(unresolvedPubkeys),
            baseRelayURLs: primaryRelayTargets
        )

        var fetchedProfiles = await fetchProfilesForPubkeys(
            relayURLs: prioritizedRelayTargets,
            pubkeys: Array(unresolvedPubkeys),
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
        await metadataRequestCoordinator.completeProfiles(profileRequest.pubkeysToFetch)
        await metadataRequestCoordinator.waitForProfiles(profileRequest.requestedPubkeys)
        let refreshed = await profileCache.resolve(
            pubkeys: profileRequest.requestedPubkeys,
            ignoringKnownMisses: true
        )
        profilesByPubkey.merge(refreshed.hits, uniquingKeysWith: { _, new in new })

        return profilesByPubkey
    }

    func decodeNewestProfiles(from events: [NostrEvent]) -> [String: NostrProfile] {
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
            guard let score = profileSearchScore(profile: profile, pubkey: pubkey, query: query) else { continue }

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
            guard profileSearchScore(profile: profile, pubkey: pubkey, query: query) != nil else {
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
                  let profileScore = profileSearchScore(profile: profile, pubkey: normalizedPubkey, query: query) {
            score = profileScore
        } else {
            score = 500
        }

        if preferredPubkeys.contains(normalizedPubkey) {
            score += 200
        }

        return score
    }

    private func mentionSearchRelayTargets() async -> [URL] {
        let readRelayURLs = await MainActor.run {
            RelaySettingsStore.shared.readRelayURLs
        }
        return normalizedRelayURLs(
            [nostrArchivesSearchRelayURL] + readRelayURLs + metadataFallbackRelayURLs
        )
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

        for chunk in chunks(normalizedTargets, size: 100) {
            let metadataFilter = NostrFilter(
                authors: chunk,
                kinds: [0],
                limit: max(chunk.count * 2, 100)
            )

            guard let metadataEvents = try? await relayTimelineFetcher.fetchTimelineEvents(
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

    private func metadataRelayURLs(primaryRelayURLs: [URL]) -> [URL] {
        normalizedRelayURLs(primaryRelayURLs + metadataFallbackRelayURLs)
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

    private func chunks<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<Swift.min($0 + size, values.count)])
        }
    }

    private func profileSearchScore(profile: NostrProfile, pubkey: String, query: String) -> Int? {
        ProfileSearchSupport.score(profile: profile, pubkey: pubkey, query: query)
    }
}
