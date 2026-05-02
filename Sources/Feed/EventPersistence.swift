import Foundation

actor EventPersistence {
    static let shared = EventPersistence()

    static let persistedKinds: Set<Int> = [
        0,
        1,
        6,
        7,
        9_735,
        20,
        21,
        22,
        1_068,
        6_969,
        30_023
    ]

    private let archiveStore: EventArchiveStore
    private let batchLimit: Int
    private let flushDelayNanoseconds: UInt64
    private var currentUserPubkey: String?
    private var pendingByID: [String: NostrEvent] = [:]
    private var flushTask: Task<Void, Never>?

    init(
        archiveStore: EventArchiveStore = EventArchiveStore(),
        currentUserPubkey: String? = nil,
        batchLimit: Int = 50,
        flushDelayNanoseconds: UInt64 = 200_000_000
    ) {
        self.archiveStore = archiveStore
        self.currentUserPubkey = Self.normalizedKey(currentUserPubkey)
        self.batchLimit = max(batchLimit, 1)
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    func setCurrentUserPubkey(_ pubkey: String?) {
        currentUserPubkey = Self.normalizedKey(pubkey)
    }

    func shouldPersist(_ event: NostrEvent) -> Bool {
        if let currentUserPubkey,
           Self.normalizedKey(event.pubkey) == currentUserPubkey {
            return true
        }
        return Self.persistedKinds.contains(event.kind)
    }

    func persistEvent(_ event: NostrEvent) async {
        await persistEvents([event])
    }

    func persistEvents(_ events: [NostrEvent]) async {
        guard !events.isEmpty else { return }

        for event in events where shouldPersist(event) {
            let eventID = Self.normalizedEventID(event.id)
            guard !eventID.isEmpty else { continue }
            pendingByID[eventID] = event
        }

        guard !pendingByID.isEmpty else { return }

        if pendingByID.count >= batchLimit {
            await flush()
        } else {
            scheduleFlush()
        }
    }

    func flush() async {
        await flushPendingEvents(cancelScheduledFlush: true)
    }

    func seedCache(limit: Int) async -> [NostrEvent] {
        let pinnedIDs = await archiveStore.prioritizedPinnedEventIDs(limit: limit)
        return await archiveStore.recentEvents(limit: limit, pinnedIDs: Set(pinnedIDs))
    }

    func getEvent(_ id: String) async -> NostrEvent? {
        let normalizedID = Self.normalizedEventID(id)
        guard !normalizedID.isEmpty else { return nil }
        return await archiveStore.events(ids: [normalizedID])[normalizedID]
    }

    func hasEvent(_ id: String) async -> Bool {
        await getEvent(id) != nil
    }

    func storeRecentFeed(key: String, events: [NostrEvent]) async {
        await archiveStore.storeRecentFeed(key: key, events: events)
    }

    func recentFeedEventIDs(key: String) async -> [String] {
        await archiveStore.recentFeedEventIDs(key: key)
    }

    func searchProfiles(query: String, limit: Int) async -> [NostrEvent] {
        await archiveStore.searchEvents(query: query, kinds: [0], limit: limit)
    }

    func searchNotes(query: String, limit: Int) async -> [NostrEvent] {
        await archiveStore.searchEvents(query: query, kinds: [1, 20, 21, 22, 1_068, 30_023], limit: limit)
    }

    func getEventsByAuthorAndKind(author: String, kind: Int, limit: Int) async -> [NostrEvent] {
        await archiveStore.events(author: author, kinds: [kind], limit: limit)
    }

    func getRecentNotificationEvents(limit: Int) async -> [NostrEvent] {
        await archiveStore.events(kinds: [1, 6, 7, 9_735], limit: limit)
    }

    func getZapReceipts(limit: Int) async -> [NostrEvent] {
        await archiveStore.events(kinds: [9_735], limit: limit)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }

        let delay = flushDelayNanoseconds
        flushTask = Task { [delay] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await self.flushPendingEvents(cancelScheduledFlush: false)
        }
    }

    private func flushPendingEvents(cancelScheduledFlush: Bool) async {
        if cancelScheduledFlush {
            flushTask?.cancel()
        }
        flushTask = nil

        guard !pendingByID.isEmpty else { return }

        let events = Array(pendingByID.values)
        pendingByID.removeAll(keepingCapacity: true)

        await archiveStore.store(events: events)
    }

    private static func normalizedEventID(_ eventID: String) -> String {
        eventID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizedKey(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == true ? nil : normalized
    }
}
