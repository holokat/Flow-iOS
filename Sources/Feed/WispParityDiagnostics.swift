import Foundation

struct WispParityDiagnosticsSnapshot: Equatable, Sendable {
    var relayRequests = 0
    var relayEventsReceived = 0
    var duplicateRelayEventsDropped = 0
    var persistedEventsQueued = 0
    var liveBatchesFlushed = 0
}

actor WispParityDiagnosticsStore {
    static let shared = WispParityDiagnosticsStore()

    private var snapshot = WispParityDiagnosticsSnapshot()

    func recordRelayRequest() {
        snapshot.relayRequests += 1
    }

    func recordRelayEvents(received: Int, duplicatesDropped: Int) {
        snapshot.relayEventsReceived += received
        snapshot.duplicateRelayEventsDropped += duplicatesDropped
    }

    func recordPersistedQueued(_ count: Int) {
        snapshot.persistedEventsQueued += count
    }

    func recordLiveBatchFlushed() {
        snapshot.liveBatchesFlushed += 1
    }

    func currentSnapshot() -> WispParityDiagnosticsSnapshot {
        snapshot
    }

    func reset() {
        snapshot = WispParityDiagnosticsSnapshot()
    }
}
