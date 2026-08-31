import Foundation

actor SeenEventStore: SeenEventStoring {
    static let shared = SeenEventStore()

    private let maxStoredEvents: Int
    private var eventsByID: [String: NostrEvent] = [:]
    private var recency: [String] = []
    private var recentFeedEventIDsByKey: [String: [String]] = [:]
    private var relayObservationsByEventID: [String: [String: EventRelayObservation]] = [:]
    private static let maxRelayObservationsPerEvent = 32

    init(
        fileManager: FileManager = .default,
        archiveBudget: EventArchiveBudget = EventArchiveBudget()
    ) {
        let _ = fileManager
        self.maxStoredEvents = max(archiveBudget.hotIndexTargetEventCount, 4_000)
    }

    func store(events: [NostrEvent]) async {
        guard !events.isEmpty else { return }
        for event in events {
            storeEvent(event)
        }
    }

    func storeRecentFeed(key: String, events: [NostrEvent]) async {
        let normalizedKey = normalizeKey(key)
        guard !normalizedKey.isEmpty else { return }

        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(events.count)

        for event in events {
            let normalizedID = normalizeEventID(event.id)
            guard !normalizedID.isEmpty else { continue }
            storeEvent(event, normalizedID: normalizedID)
            orderedIDs.append(normalizedID)
        }

        recentFeedEventIDsByKey[normalizedKey] = orderedIDs
    }

    func recentFeed(key: String) async -> [NostrEvent]? {
        let normalizedKey = normalizeKey(key)
        guard !normalizedKey.isEmpty else { return nil }
        guard let orderedIDs = recentFeedEventIDsByKey[normalizedKey], !orderedIDs.isEmpty else {
            return nil
        }
        guard !orderedIDs.isEmpty else { return nil }

        let events = orderedIDs.compactMap { eventsByID[$0] }
        return events.isEmpty ? nil : events
    }

    func events(ids: [String]) async -> [String: NostrEvent] {
        let normalizedIDs = Array(
            Set(
                ids
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalizedIDs.isEmpty else { return [:] }

        var resolved: [String: NostrEvent] = [:]
        for eventID in normalizedIDs {
            if let event = eventsByID[eventID] {
                resolved[eventID] = event
            }
        }
        return resolved
    }

    func queryEvents(filter: NostrFilter) async -> [NostrEvent] {
        let idSet = normalizedSet(filter.ids)
        let authorSet = normalizedSet(filter.authors)
        let kindSet = filter.kinds.map(Set.init)
        let tagFilters = normalizedTagFilters(filter.tagFilters)

        let filtered = eventsByID.values.filter { event in
            let eventID = normalizeEventID(event.id)
            if let idSet, !idSet.contains(eventID) {
                return false
            }
            if let authorSet, !authorSet.contains(event.pubkey.lowercased()) {
                return false
            }
            if let kindSet, !kindSet.contains(event.kind) {
                return false
            }
            if let since = filter.since, event.createdAt < since {
                return false
            }
            if let until = filter.until, event.createdAt > until {
                return false
            }
            return matchesTagFilters(event, tagFilters: tagFilters)
        }
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.lowercased() > rhs.id.lowercased()
            }
            return lhs.createdAt > rhs.createdAt
        }

        guard let limit = filter.limit else { return filtered }
        return Array(filtered.prefix(max(limit, 0)))
    }

    func recordRelayObservation(
        relayURL: URL,
        events: [NostrEvent],
        observedAt: Date = Date()
    ) async {
        guard !events.isEmpty,
              let normalizedRelayURL = RelayURLSupport.normalizedURL(from: relayURL.absoluteString) else {
            return
        }
        let relayKey = normalizedRelayURL.absoluteString.lowercased()

        for event in events {
            let eventID = normalizeEventID(event.id)
            guard !eventID.isEmpty, eventsByID[eventID] != nil else { continue }

            var observations = relayObservationsByEventID[eventID] ?? [:]
            let firstSeenAt = observations[relayKey]?.firstSeenAt ?? observedAt
            observations[relayKey] = EventRelayObservation(
                relayURL: normalizedRelayURL,
                firstSeenAt: min(firstSeenAt, observedAt),
                lastSeenAt: max(observations[relayKey]?.lastSeenAt ?? observedAt, observedAt)
            )
            if observations.count > Self.maxRelayObservationsPerEvent {
                let retainedKeys = Set(
                    observations
                        .sorted { lhs, rhs in
                            if lhs.value.lastSeenAt == rhs.value.lastSeenAt {
                                return lhs.key < rhs.key
                            }
                            return lhs.value.lastSeenAt > rhs.value.lastSeenAt
                        }
                        .prefix(Self.maxRelayObservationsPerEvent)
                        .map(\.key)
                )
                observations = observations.filter { retainedKeys.contains($0.key) }
            }
            relayObservationsByEventID[eventID] = observations
        }
    }

    func relayObservations(eventID: String) async -> [EventRelayObservation] {
        let normalizedID = normalizeEventID(eventID)
        guard !normalizedID.isEmpty else { return [] }
        return (relayObservationsByEventID[normalizedID] ?? [:])
            .values
            .sorted { lhs, rhs in
                lhs.relayURL.absoluteString.lowercased() < rhs.relayURL.absoluteString.lowercased()
            }
    }

    private func storeEvent(_ event: NostrEvent, normalizedID: String? = nil) {
        let resolvedID = normalizedID ?? normalizeEventID(event.id)
        guard !resolvedID.isEmpty else { return }
        eventsByID[resolvedID] = event
        touch(resolvedID)
    }

    private func touch(_ eventID: String) {
        recency.removeAll { $0 == eventID }
        recency.append(eventID)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        while recency.count > maxStoredEvents {
            let oldestID = recency.removeFirst()
            eventsByID.removeValue(forKey: oldestID)
            relayObservationsByEventID.removeValue(forKey: oldestID)
            for key in recentFeedEventIDsByKey.keys {
                recentFeedEventIDsByKey[key]?.removeAll { $0 == oldestID }
                if recentFeedEventIDsByKey[key]?.isEmpty == true {
                    recentFeedEventIDsByKey.removeValue(forKey: key)
                }
            }
        }
    }

    private func normalizeEventID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSet(_ values: [String]?) -> Set<String>? {
        guard let values else { return nil }
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return normalized.isEmpty ? nil : Set(normalized)
    }

    private func normalizedTagFilters(_ filters: [String: [String]]?) -> [String: Set<String>] {
        guard let filters else { return [:] }
        return filters.reduce(into: [String: Set<String>]()) { result, pair in
            let key = pair.key
                .trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
                .lowercased()
            let values = pair.value
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard !key.isEmpty, !values.isEmpty else { return }
            result[key] = Set(values)
        }
    }

    private func matchesTagFilters(
        _ event: NostrEvent,
        tagFilters: [String: Set<String>]
    ) -> Bool {
        guard !tagFilters.isEmpty else { return true }
        for (tagName, allowedValues) in tagFilters {
            let hasMatchingTag = event.tags.contains { tag in
                guard tag.count > 1,
                      tag[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == tagName else {
                    return false
                }
                return allowedValues.contains(
                    tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }
            if !hasMatchingTag {
                return false
            }
        }
        return true
    }
}
