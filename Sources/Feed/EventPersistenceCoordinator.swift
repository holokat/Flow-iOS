import Foundation

actor EventPersistenceCoordinator {
    static let shared = EventPersistenceCoordinator()

    private let archiveStore: EventArchiveStore
    private let batchLimit: Int
    private let flushDelayNanoseconds: UInt64
    private var pendingByID: [String: NostrEvent] = [:]
    private var flushTask: Task<Void, Never>?

    init(
        archiveStore: EventArchiveStore = EventArchiveStore(),
        batchLimit: Int = 50,
        flushDelayNanoseconds: UInt64 = 200_000_000
    ) {
        self.archiveStore = archiveStore
        self.batchLimit = max(batchLimit, 1)
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    func enqueue(
        events: [NostrEvent],
        policy: EventPersistencePolicy = EventPersistencePolicy()
    ) async {
        guard !events.isEmpty else { return }

        for event in events where policy.shouldPersist(event) {
            let eventID = Self.normalizedEventID(event.id)
            guard !eventID.isEmpty else { continue }
            pendingByID[eventID] = event
        }

        guard !pendingByID.isEmpty else { return }

        if pendingByID.count >= batchLimit {
            await flushNow()
        } else {
            scheduleFlush()
        }
    }

    func flushNow() async {
        await flushPendingEvents(cancelScheduledFlush: true)
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
}
