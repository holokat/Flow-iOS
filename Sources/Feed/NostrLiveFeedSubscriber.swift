import Foundation

final class NostrLiveFeedSubscriber: @unchecked Sendable {
    private let session: URLSession
    private let connectionPool: NostrRelayPool

    init(
        session: URLSession = .shared,
        connectionPool: NostrRelayPool = .shared,
        liveEventFallbackDelayNanoseconds: UInt64 = 1_200_000_000,
        receiveIdleTimeoutNanoseconds: UInt64 = 45_000_000_000,
        pingTimeoutNanoseconds: UInt64 = 8_000_000_000
    ) {
        self.session = session
        self.connectionPool = connectionPool
        let _ = liveEventFallbackDelayNanoseconds
        let _ = receiveIdleTimeoutNanoseconds
        let _ = pingTimeoutNanoseconds
    }

    func run(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void = { _ in }
    ) async {
        while !Task.isCancelled {
            do {
                try await runSingleSubscription(
                    relayURL: relayURL,
                    filter: filter,
                    onNewEvent: onNewEvent
                )
            } catch {
                await onStatus(error.localizedDescription)
                if case RelayClientError.invalidRelayURL = error {
                    return
                }
            }

            if Task.isCancelled {
                return
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func runSingleSubscription(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void
    ) async throws {
        guard let normalizedRelayURL = RelayURLSupport.normalizedURL(from: relayURL.absoluteString) else {
            throw RelayClientError.invalidRelayURL(relayURL.absoluteString)
        }

        var liveFilter = filter
        liveFilter.since = Int(Date().timeIntervalSince1970)
        liveFilter.until = nil
        liveFilter.limit = 0

        let stream = await connectionPool.streamEvents(
            relayURL: normalizedRelayURL,
            filter: liveFilter,
            session: session
        )

        for try await event in stream {
            guard !Task.isCancelled else { break }
            await onNewEvent(event)
        }
    }
}
