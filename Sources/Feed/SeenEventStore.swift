import Foundation

actor SeenEventStore: SeenEventStoring {
    static let shared = SeenEventStore()

    private let maxStoredEvents: Int
    private var eventsByID: [String: NostrEvent] = [:]
    private var recency: [String] = []
    private var recentFeedEventIDsByKey: [String: [String]] = [:]

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
}
