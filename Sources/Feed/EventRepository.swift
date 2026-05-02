import Foundation

actor EventRepository: EventRepositoryStoring {
    static let shared = EventRepository(persistence: .shared)

    private let persistence: EventPersistence
    private let maxStoredEvents: Int
    private var eventCache: [String: NostrEvent] = [:]
    private var seenEventIDs = Set<String>()
    private var recency: [String] = []
    private var recentFeedEventIDsByKey: [String: [String]] = [:]

    init(
        fileManager: FileManager = .default,
        persistence: EventPersistence? = nil,
        archiveBudget: EventArchiveBudget = EventArchiveBudget()
    ) {
        if let persistence {
            self.persistence = persistence
        } else {
            let archiveStore = EventArchiveStore(fileManager: fileManager, budget: archiveBudget)
            self.persistence = EventPersistence(archiveStore: archiveStore)
        }
        self.maxStoredEvents = max(archiveBudget.hotIndexTargetEventCount, 4_000)
    }

    func store(events: [NostrEvent]) async {
        guard !events.isEmpty else { return }

        var acceptedEvents: [NostrEvent] = []
        acceptedEvents.reserveCapacity(events.count)

        for event in events {
            let normalizedID = normalizeEventID(event.id)
            guard !normalizedID.isEmpty,
                  seenEventIDs.insert(normalizedID).inserted else {
                continue
            }
            cacheEvent(event, normalizedID: normalizedID, markSeen: false)
            acceptedEvents.append(event)
        }

        if !acceptedEvents.isEmpty {
            await persistence.persistEvents(acceptedEvents)
        }
    }

    func storeRecentFeed(key: String, events: [NostrEvent]) async {
        let normalizedKey = normalizeFeedKey(key)
        guard !normalizedKey.isEmpty else { return }

        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(events.count)

        for event in events {
            let normalizedID = normalizeEventID(event.id)
            guard !normalizedID.isEmpty else { continue }
            cacheEvent(event, normalizedID: normalizedID, markSeen: true)
            orderedIDs.append(normalizedID)
        }

        recentFeedEventIDsByKey[normalizedKey] = orderedIDs
        await persistence.storeRecentFeed(key: normalizedKey, events: events)
    }

    func recentFeed(key: String) async -> [NostrEvent]? {
        let normalizedKey = normalizeFeedKey(key)
        guard !normalizedKey.isEmpty else { return nil }

        if let orderedIDs = recentFeedEventIDsByKey[normalizedKey], !orderedIDs.isEmpty {
            let resolved = await events(ids: orderedIDs)
            let orderedEvents = orderedIDs.compactMap { resolved[$0] }
            if !orderedEvents.isEmpty {
                return orderedEvents
            }
        }

        let persistedIDs = await persistence.recentFeedEventIDs(key: normalizedKey)
        guard !persistedIDs.isEmpty else { return nil }
        recentFeedEventIDsByKey[normalizedKey] = persistedIDs

        let resolved = await events(ids: persistedIDs)
        let orderedEvents = persistedIDs.compactMap { resolved[$0] }
        return orderedEvents.isEmpty ? nil : orderedEvents
    }

    func events(ids: [String]) async -> [String: NostrEvent] {
        let normalizedIDs = Array(
            Set(
                ids
                    .map(normalizeEventID)
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalizedIDs.isEmpty else { return [:] }

        var resolved: [String: NostrEvent] = [:]
        var missingIDs: [String] = []
        for eventID in normalizedIDs {
            if let event = eventCache[eventID] {
                resolved[eventID] = event
            } else {
                missingIDs.append(eventID)
            }
        }

        for eventID in missingIDs {
            guard let event = await persistence.getEvent(eventID) else { continue }
            cacheEvent(event, normalizedID: eventID, markSeen: false)
            resolved[eventID] = event
        }

        return resolved
    }

    func flushPersistence() async {
        await persistence.flush()
    }

    func addEvent(_ event: NostrEvent) async {
        await store(events: [event])
    }

    func cacheEvent(_ event: NostrEvent) {
        let normalizedID = normalizeEventID(event.id)
        guard !normalizedID.isEmpty,
              eventCache[normalizedID] == nil else {
            return
        }
        cacheEvent(event, normalizedID: normalizedID, markSeen: true)
    }

    func getEvent(id: String) async -> NostrEvent? {
        let normalizedID = normalizeEventID(id)
        guard !normalizedID.isEmpty else { return nil }
        if let event = eventCache[normalizedID] {
            return event
        }
        guard let event = await persistence.getEvent(normalizedID) else {
            return nil
        }
        cacheEvent(event, normalizedID: normalizedID, markSeen: false)
        return event
    }

    @discardableResult
    func seedFromPersistence(limit: Int) async -> [NostrEvent] {
        let events = await persistence.seedCache(limit: limit)
        for event in events {
            cacheEvent(
                event,
                normalizedID: normalizeEventID(event.id),
                markSeen: shouldSeedSeenEventID(event)
            )
        }
        return events
    }

    func getCacheSize() -> Int {
        eventCache.count
    }

    func trimSeenEvents(maxSize: Int) {
        let _ = maxSize
        // Wisp keeps relay dedup independent from hot-cache eviction.
    }

    private func cacheEvent(_ event: NostrEvent, normalizedID: String, markSeen: Bool) {
        guard !normalizedID.isEmpty else { return }
        eventCache[normalizedID] = event
        if markSeen {
            seenEventIDs.insert(normalizedID)
        }
        touch(normalizedID)
    }

    private func touch(_ eventID: String) {
        recency.removeAll { $0 == eventID }
        recency.append(eventID)
        trimCacheIfNeeded()
    }

    private func trimCacheIfNeeded() {
        while recency.count > maxStoredEvents {
            let oldestID = recency.removeFirst()
            eventCache.removeValue(forKey: oldestID)
        }
    }

    private func shouldSeedSeenEventID(_ event: NostrEvent) -> Bool {
        switch event.kind {
        case 0, 1, 20, 21, 22, 1_068, 6_969, 30_023:
            return true
        default:
            return false
        }
    }

    private func normalizeEventID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeFeedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
