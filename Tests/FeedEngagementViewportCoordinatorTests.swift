import XCTest
@testable import Flow

final class FeedEngagementViewportCoordinatorTests: XCTestCase {
    @MainActor
    func testCoordinatorBatchesVisibleEventsIntoSinglePrefetch() async throws {
        let spy = SpyEngagementPrefetchSink()
        let coordinator = FeedEngagementViewportCoordinator(prefetchSink: spy)
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))

        coordinator.noteVisible(event: makeReactionTargetEvent(id: String(repeating: "a", count: 64)), relayURLs: [relayURL])
        coordinator.noteVisible(event: makeReactionTargetEvent(id: String(repeating: "b", count: 64)), relayURLs: [relayURL])
        coordinator.noteVisible(event: makeReactionTargetEvent(id: String(repeating: "a", count: 64)), relayURLs: [relayURL])

        try await Task.sleep(nanoseconds: 250_000_000)

        let calls = spy.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Set(calls[0].eventIDs), [
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64)
        ])
        XCTAssertEqual(calls[0].relayURLs, [relayURL])
    }

    @MainActor
    func testCoordinatorStartsNewBatchAfterFlush() async throws {
        let spy = SpyEngagementPrefetchSink()
        let coordinator = FeedEngagementViewportCoordinator(prefetchSink: spy)
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))

        coordinator.noteVisible(event: makeReactionTargetEvent(id: String(repeating: "a", count: 64)), relayURLs: [relayURL])
        try await Task.sleep(nanoseconds: 250_000_000)

        coordinator.noteVisible(event: makeReactionTargetEvent(id: String(repeating: "b", count: 64)), relayURLs: [relayURL])
        try await Task.sleep(nanoseconds: 250_000_000)

        let calls = spy.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls[0].eventIDs), [String(repeating: "a", count: 64)])
        XCTAssertEqual(Set(calls[1].eventIDs), [String(repeating: "b", count: 64)])
    }

    @MainActor
    func testCoordinatorFlushesPendingBatchWhenDeinitializedBeforeDebounceFires() throws {
        let spy = SpyEngagementPrefetchSink()
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))
        var coordinator: FeedEngagementViewportCoordinator? = FeedEngagementViewportCoordinator(prefetchSink: spy)

        coordinator?.noteVisible(
            event: makeReactionTargetEvent(id: String(repeating: "a", count: 64)),
            relayURLs: [relayURL]
        )
        coordinator = nil

        let calls = spy.calls
        XCTAssertEqual(calls.count, 1)
        guard let firstCall = calls.first else { return }
        XCTAssertEqual(Set(firstCall.eventIDs), [String(repeating: "a", count: 64)])
        XCTAssertEqual(firstCall.relayURLs, [relayURL])
    }

    @MainActor
    func testHashtagViewModelDoesNotHydrateSeedItemsDuringInit() async throws {
        let harness = try HashtagFeedViewModelTestHarness()
        let seedItem = FeedItem(
            event: makeReactionTargetEvent(
                id: String(repeating: "c", count: 64),
                pubkey: String(repeating: "d", count: 64),
                tags: [["t", "swift"]]
            ),
            profile: nil
        )

        _ = HashtagFeedViewModel(
            hashtag: "swift",
            relayURL: harness.relayURL,
            readRelayURLs: [harness.relayURL],
            seedItems: [seedItem],
            service: harness.service
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        let fetchCount = await harness.relayClient.fetchCount()
        XCTAssertEqual(fetchCount, 0)
    }
}

@MainActor
private final class SpyEngagementPrefetchSink: FeedEngagementPrefetchSink {
    struct Call: Sendable {
        let eventIDs: [String]
        let relayURLs: [URL]
    }

    private(set) var calls: [Call] = []

    func prefetch(events: [NostrEvent], relayURLs: [URL]) {
        calls.append(
            Call(
                eventIDs: events.map(\.id).sorted(),
                relayURLs: relayURLs.sorted { $0.absoluteString < $1.absoluteString }
            )
        )
    }
}

private func makeReactionTargetEvent(
    id: String,
    pubkey: String = String(repeating: "2", count: 64),
    tags: [[String]] = []
) -> Flow.NostrEvent {
    Flow.NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: 1_700_000_000,
        kind: 1,
        tags: tags,
        content: "Target note",
        sig: String(repeating: "3", count: 128)
    )
}

private struct HashtagFeedViewModelTestHarness {
    let relayURL = URL(string: "wss://relay.example.com")!
    let relayClient: RecordingRelayClient
    let service: NostrFeedService

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HashtagFeedViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileManager = HashtagFeedTestFileManager(rootURL: rootURL)
        let profileSnapshotStore = ProfileSnapshotStore(fileManager: fileManager)
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        let eventRepository = EventRepository(fileManager: fileManager)

        relayClient = RecordingRelayClient()
        service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: profileSnapshotStore),
            relayHintCache: ProfileRelayHintCache(),
            followListCache: followListCache,
            eventRepository: eventRepository,
            presentationCache: FeedPresentationCache()
        )
    }
}

private actor RecordingRelayClient: NostrRelayEventFetching {
    private var recordedFetchCount = 0

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        recordedFetchCount += 1
        return []
    }

    func fetchCount() -> Int {
        recordedFetchCount
    }
}

private final class HashtagFeedTestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        [rootURL]
    }
}
