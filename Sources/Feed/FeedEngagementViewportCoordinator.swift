import Foundation

@MainActor
protocol FeedEngagementPrefetchSink: AnyObject {
    func prefetch(events: [NostrEvent], relayURLs: [URL])
}

extension NoteReactionStatsService: FeedEngagementPrefetchSink {}

@MainActor
final class FeedEngagementViewportCoordinator: ObservableObject {
    private let prefetchSink: any FeedEngagementPrefetchSink
    private var pendingEventsByID: [String: NostrEvent] = [:]
    private var pendingRelayURLs: [String: URL] = [:]
    private var flushTask: Task<Void, Never>?

    init() {
        self.prefetchSink = NoteReactionStatsService.shared
    }

    init(prefetchSink: any FeedEngagementPrefetchSink) {
        self.prefetchSink = prefetchSink
    }

    deinit {
        flushTask?.cancel()
        MainActor.assumeIsolated {
            flush()
        }
    }

    func noteVisible(event: NostrEvent, relayURLs: [URL]) {
        pendingEventsByID[event.id.lowercased()] = event

        for relayURL in relayURLs {
            pendingRelayURLs[relayURL.absoluteString.lowercased()] = relayURL
        }

        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }

        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil

        let events = Array(pendingEventsByID.values)
        let relayURLs = Array(pendingRelayURLs.values)
        pendingEventsByID.removeAll()
        pendingRelayURLs.removeAll()

        guard !events.isEmpty, !relayURLs.isEmpty else { return }
        prefetchSink.prefetch(events: events, relayURLs: relayURLs)
    }
}
