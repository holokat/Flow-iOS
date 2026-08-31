import Foundation

protocol NostrLiveEventSubscribing: Sendable {
    func run(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async
}

final class NostrLiveFeedSubscriber: NostrLiveEventSubscribing, @unchecked Sendable {
    private enum SubscriptionOutcome {
        case ended(receivedEvent: Bool)
        case failed(Error, receivedEvent: Bool)
    }

    private let session: URLSession
    private let connectionPool: NostrRelayPool
    private let seenEventStore: any SeenEventStoring
    private let reconnectBaseDelayNanoseconds: UInt64
    private let reconnectMaximumDelayNanoseconds: UInt64

    init(
        session: URLSession = .shared,
        connectionPool: NostrRelayPool = .shared,
        seenEventStore: any SeenEventStoring = SeenEventStore.shared,
        liveEventFallbackDelayNanoseconds: UInt64? = nil,
        receiveIdleTimeoutNanoseconds: UInt64? = nil,
        pingTimeoutNanoseconds: UInt64? = nil,
        reconnectBaseDelayNanoseconds: UInt64 = 1_000_000_000,
        reconnectMaximumDelayNanoseconds: UInt64 = 30_000_000_000
    ) {
        // Retain source compatibility with callers from the earlier subscriber.
        // The pooled stream now owns fallback, idle, and ping timing.
        _ = liveEventFallbackDelayNanoseconds
        _ = receiveIdleTimeoutNanoseconds
        _ = pingTimeoutNanoseconds
        self.session = session
        self.connectionPool = connectionPool
        self.seenEventStore = seenEventStore
        self.reconnectBaseDelayNanoseconds = max(reconnectBaseDelayNanoseconds, 1)
        self.reconnectMaximumDelayNanoseconds = max(
            reconnectMaximumDelayNanoseconds,
            reconnectBaseDelayNanoseconds
        )
    }

    func run(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void = { _ in }
    ) async {
        var consecutiveFailures = 0
        // Establish a missing cursor once for the lifetime of this run. If it
        // were recomputed after every disconnect, notes published during the
        // reconnect delay could fall behind the new cursor and be skipped.
        let reconnectFilter = Self.liveFilter(from: filter)

        while !Task.isCancelled {
            let outcome = await runSingleSubscription(
                relayURL: relayURL,
                filter: reconnectFilter,
                onNewEvent: onNewEvent
            )

            let receivedEvent: Bool
            switch outcome {
            case .ended(let didReceiveEvent):
                receivedEvent = didReceiveEvent
                if !Task.isCancelled {
                    await onStatus("Source ended the live subscription.")
                }

            case .failed(let error, let didReceiveEvent):
                receivedEvent = didReceiveEvent
                await onStatus(error.localizedDescription)
                if case RelayClientError.invalidRelayURL = error {
                    return
                }
            }

            if Task.isCancelled {
                return
            }

            consecutiveFailures = receivedEvent ? 1 : min(consecutiveFailures + 1, 16)
            let delay = Self.reconnectDelayNanoseconds(
                failureCount: consecutiveFailures,
                base: reconnectBaseDelayNanoseconds,
                maximum: reconnectMaximumDelayNanoseconds
            )
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func runSingleSubscription(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void
    ) async -> SubscriptionOutcome {
        guard let normalizedRelayURL = RelayURLSupport.normalizedURL(from: relayURL.absoluteString) else {
            return .failed(RelayClientError.invalidRelayURL(relayURL.absoluteString), receivedEvent: false)
        }

        let stream = await connectionPool.streamEvents(
            relayURL: normalizedRelayURL,
            filter: filter,
            session: session
        )

        var receivedEvent = false
        do {
            for try await event in stream {
                guard !Task.isCancelled else { break }
                receivedEvent = true
                await seenEventStore.store(events: [event])
                await seenEventStore.recordRelayObservation(
                    relayURL: normalizedRelayURL,
                    events: [event],
                    observedAt: Date()
                )
                await onNewEvent(event)
            }
            return .ended(receivedEvent: receivedEvent)
        } catch {
            return .failed(error, receivedEvent: receivedEvent)
        }
    }

    static func liveFilter(
        from filter: NostrFilter,
        now: Int = Int(Date().timeIntervalSince1970)
    ) -> NostrFilter {
        var liveFilter = filter
        // Home feed targets intentionally omit a cursor because their bounded
        // startup catch-up is fetched separately. Without this fallback, a
        // relay replays the full history for hundreds of followed authors.
        liveFilter.since = filter.since ?? now
        liveFilter.until = nil
        // NIP-01 applies limit only to the stored-event phase, so a positive
        // replay cap does not stop new events from continuing to arrive.
        // Avoid sending legacy limit: 0 because relay behavior varies.
        if let limit = filter.limit, limit <= 0 {
            liveFilter.limit = nil
        }
        return liveFilter
    }

    static func reconnectDelayNanoseconds(
        failureCount: Int,
        base: UInt64,
        maximum: UInt64,
        jitterFraction: Double = Double.random(in: 0...0.2)
    ) -> UInt64 {
        let exponent = max(min(failureCount - 1, 8), 0)
        let multiplier = UInt64(1) << UInt64(exponent)
        let multiplied = base.multipliedReportingOverflow(by: multiplier)
        let cappedBase = multiplied.overflow ? maximum : min(multiplied.partialValue, maximum)
        let jitter = UInt64(Double(cappedBase) * max(min(jitterFraction, 0.2), 0))
        return min(cappedBase + jitter, maximum)
    }
}
