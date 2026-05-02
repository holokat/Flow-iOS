import Foundation

struct FeedItemBuilder {
    private let profileCache: any ProfileCaching
    private let eventRepository: any EventRepositoryStoring
    private let presentationCache: FeedPresentationCache
    private let fetchProfiles: ([URL], [String], TimeInterval, RelayFetchMode) async -> [String: NostrProfile]
    private let resolveReferences: ([String: NostrEventReferencePointer], [URL]) async -> [String: NostrEvent]
    private let makeRepostReferencePointer: (String, NostrEvent) -> NostrEventReferencePointer
    private let makeReplyReferencePointer: (String, NostrEvent) -> NostrEventReferencePointer

    init(
        profileCache: any ProfileCaching,
        eventRepository: any EventRepositoryStoring,
        presentationCache: FeedPresentationCache,
        fetchProfiles: @escaping ([URL], [String], TimeInterval, RelayFetchMode) async -> [String: NostrProfile],
        resolveReferences: @escaping ([String: NostrEventReferencePointer], [URL]) async -> [String: NostrEvent],
        makeRepostReferencePointer: @escaping (String, NostrEvent) -> NostrEventReferencePointer,
        makeReplyReferencePointer: @escaping (String, NostrEvent) -> NostrEventReferencePointer
    ) {
        self.profileCache = profileCache
        self.eventRepository = eventRepository
        self.presentationCache = presentationCache
        self.fetchProfiles = fetchProfiles
        self.resolveReferences = resolveReferences
        self.makeRepostReferencePointer = makeRepostReferencePointer
        self.makeReplyReferencePointer = makeReplyReferencePointer
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
            let fetchedDisplayProfiles = await fetchProfiles(relayURLs, displayPubkeys, 8, .firstNonEmptyRelay)
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
            let fetchedReplyTargetProfiles = await fetchProfiles(relayURLs, replyTargetPubkeys, 8, .firstNonEmptyRelay)
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

    func buildCachedFeedItems(
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

    func buildAuthorOnlyFeedItems(
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
        return await fetchProfiles(relayURLs, pubkeysToResolve, fetchTimeout, relayFetchMode)
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

        let cachedByID = await eventRepository.events(ids: Array(missingTargetIDs))
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
            partialResult[entry.key] = makeRepostReferencePointer(entry.value, sourceEvent)
        }

        let fetchedBySourceID = await resolveReferences(referencePointersBySourceID, relayURLs)
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

        let cachedByID = await eventRepository.events(ids: Array(missingTargetIDs))
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

        let cachedByID = await eventRepository.events(ids: Array(missingTargetIDs))
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

        let cachedByID = await eventRepository.events(ids: Array(missingTargetIDs))
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
            partialResult[entry.key] = makeReplyReferencePointer(entry.value, replySourceEvent)
        }

        let fetchedBySourceID = await resolveReferences(referencePointersBySourceID, relayURLs)
        for (sourceID, targetEvent) in fetchedBySourceID {
            resolvedBySourceID[sourceID] = targetEvent.resolvedRepostContentEvent ?? targetEvent
        }

        return resolvedBySourceID
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

    private func normalizePubkey(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func normalizedEventID(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }
}
