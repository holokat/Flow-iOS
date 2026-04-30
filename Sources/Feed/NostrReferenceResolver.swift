import Foundation

struct NostrReferenceResolver: Sendable {
    private let relayTimelineFetcher: RelayTimelineFetcher
    private let seenEventStore: any SeenEventStoring
    private let resolveOutboxRelayPlan: @Sendable ([String], [URL], [String: [URL]]) async -> AuthorRelayPlan
    private let buildFeedItems: @Sendable (
        [URL],
        [NostrEvent],
        FeedItemHydrationMode,
        MuteFilterSnapshot?
    ) async -> [FeedItem]

    init(
        relayTimelineFetcher: RelayTimelineFetcher,
        seenEventStore: any SeenEventStoring,
        resolveOutboxRelayPlan: @escaping @Sendable ([String], [URL], [String: [URL]]) async -> AuthorRelayPlan,
        buildFeedItems: @escaping @Sendable (
            [URL],
            [NostrEvent],
            FeedItemHydrationMode,
            MuteFilterSnapshot?
        ) async -> [FeedItem]
    ) {
        self.relayTimelineFetcher = relayTimelineFetcher
        self.seenEventStore = seenEventStore
        self.resolveOutboxRelayPlan = resolveOutboxRelayPlan
        self.buildFeedItems = buildFeedItems
    }

    func fetchReferencedFeedItem(
        reference: NostrEventReferencePointer,
        relayURLs: [URL],
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 8,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async -> FeedItem? {
        let relayTargets = await referencedFeedItemRelayTargets(
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
            relayTargets,
            [event],
            hydrationMode,
            moderationSnapshot
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

                guard let events = try? await relayTimelineFetcher.fetchTimelineEventsFromRelaysOnly(
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

                guard let events = try? await relayTimelineFetcher.fetchTimelineEventsFromRelaysOnly(
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

    func fetchResolvedReferenceEvents<Key: Hashable>(
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

    func referencePointerForRepostTarget(
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

    func referencePointerForReplyTarget(
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

    private func referenceRelayTargets(
        for reference: NostrEventReferencePointer,
        baseRelayURLs: [URL]
    ) async -> [URL] {
        let relayTargets = normalizedRelayURLs(reference.relayHints + baseRelayURLs)
        guard !relayTargets.isEmpty else { return [] }
        return relayTargets
    }

    private func referencedFeedItemRelayTargets(
        for reference: NostrEventReferencePointer,
        baseRelayURLs: [URL]
    ) async -> [URL] {
        let directTargets = await referenceRelayTargets(
            for: reference,
            baseRelayURLs: baseRelayURLs
        )
        guard let targetPubkey = reference.targetPubkey else {
            return directTargets
        }

        let seedHints = reference.relayHints.isEmpty
            ? [:]
            : [targetPubkey: reference.relayHints]
        let relayPlan = await resolveOutboxRelayPlan(
            [targetPubkey],
            baseRelayURLs,
            seedHints
        )
        return normalizedRelayURLs(relayPlan.relayURLs(for: targetPubkey) + directTargets)
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
        guard let fetchedEvents = try? await relayTimelineFetcher.fetchTimelineEvents(
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
        guard let fetchedEvents = try? await relayTimelineFetcher.fetchTimelineEvents(
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

    private func repostTargetAuthorHint(in event: NostrEvent) -> String? {
        firstTaggedPubkey(in: event)
    }

    private func replyTargetAuthorHint(in event: NostrEvent) -> String? {
        lastTaggedPubkey(in: event) ?? firstTaggedPubkey(in: event)
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

    private func normalizedEventID(_ value: String?) -> String? {
        let normalized = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
