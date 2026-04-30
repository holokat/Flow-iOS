import Foundation

struct ActivityRowBuilder {
    private let relayTimelineFetcher: RelayTimelineFetcher
    private let profileCache: any ProfileCaching
    private let seenEventStore: any SeenEventStoring
    private let resolveReferences: (
        [ActivityTargetReference: NostrEventReferencePointer],
        [URL],
        TimeInterval,
        RelayFetchMode
    ) async -> [ActivityTargetReference: NostrEvent]

    init(
        relayTimelineFetcher: RelayTimelineFetcher,
        profileCache: any ProfileCaching,
        seenEventStore: any SeenEventStoring,
        resolveReferences: @escaping (
            [ActivityTargetReference: NostrEventReferencePointer],
            [URL],
            TimeInterval,
            RelayFetchMode
        ) async -> [ActivityTargetReference: NostrEvent]
    ) {
        self.relayTimelineFetcher = relayTimelineFetcher
        self.profileCache = profileCache
        self.seenEventStore = seenEventStore
        self.resolveReferences = resolveReferences
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

        let activityEvents = try await relayTimelineFetcher.fetchTimelineEvents(
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

        async let reactionAndRepostEventsTask = relayTimelineFetcher.fetchTimelineEvents(
            relayURLs: relayTargets,
            filter: NostrFilter(
                kinds: [6, 7, 16],
                limit: limit,
                tagFilters: ["e": [normalizedRootEventID]]
            ),
            timeout: fetchTimeout,
            relayFetchMode: relayFetchMode
        )
        async let quoteEventsTask = relayTimelineFetcher.fetchTimelineEvents(
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
        let _ = profileFetchTimeout
        let _ = profileRelayFetchMode

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
            case .address:
                break
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

        let fetchedByReference = await resolveReferences(
            referencePointersByReference,
            relayURLs,
            fetchTimeout,
            relayFetchMode
        )
        for (reference, event) in fetchedByReference {
            resolved[reference] = event
        }

        return resolved
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
                authorPubkey: firstTaggedPubkey(in: sourceEvent)
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

    private func firstTaggedPubkey(in event: NostrEvent) -> String? {
        for tag in event.tags {
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
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func normalizedEventID(_ value: String?) -> String? {
        let normalized = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
