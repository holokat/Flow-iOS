import Foundation

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
