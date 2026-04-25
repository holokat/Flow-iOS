import Combine
import XCTest
import NostrSDK
@testable import Flow

final class NoteReactionBonusTests: XCTestCase {
    func testToggleReactionPublishesHaloBonusTag() async throws {
        let relayClient = RecordingReactionRelayPublisher()
        let service = NoteReactionPublishService(relayClient: relayClient)
        let keypair = try XCTUnwrap(Keypair())
        let targetEvent = makeReactionTargetEvent()

        let result = try await service.toggleReaction(
            for: targetEvent,
            existingReactionID: nil,
            bonusCount: 4,
            currentNsec: keypair.privateKey.nsec,
            writeRelayURLs: [URL(string: "wss://relay.example.com")!],
            relayHintURL: URL(string: "wss://relay.example.com")!
        )

        guard case .liked = result else {
            return XCTFail("Expected a liked result.")
        }

        let capture = await relayClient.capture()
        let eventData = try XCTUnwrap(capture.eventData)
        let event = try JSONDecoder().decode(Flow.NostrEvent.self, from: eventData)

        XCTAssertEqual(firstTag(named: ReactionBonusTag.tagName, in: event), [ReactionBonusTag.tagName, "4"])
        XCTAssertEqual(event.content, "+")
    }

    @MainActor
    func testOptimisticBonusReactionContributesCombinedCount() async {
        let service = NoteReactionStatsService(
            relayClient: SpyReactionRelayClient(),
            store: NoteReactionStatsStore(fileManager: ReactionTestFileManager(rootURL: temporaryRootURL()))
        )
        let eventID = String(repeating: "a", count: 64)
        let pubkey = String(repeating: "b", count: 64)

        _ = service.applyOptimisticToggle(
            for: eventID,
            currentPubkey: pubkey,
            bonusCount: 3
        )

        XCTAssertEqual(service.reactionCount(for: eventID), 4)
        XCTAssertEqual(service.currentUserReaction(for: eventID, currentPubkey: pubkey)?.bonusCount, 3)
    }

    @MainActor
    func testRegisterPublishedReactionSumsBonusWeight() async {
        let service = NoteReactionStatsService(
            relayClient: SpyReactionRelayClient(),
            store: NoteReactionStatsStore(fileManager: ReactionTestFileManager(rootURL: temporaryRootURL()))
        )
        let targetEventID = String(repeating: "c", count: 64)
        let targetPubkey = String(repeating: "d", count: 64)
        let reactorPubkey = String(repeating: "e", count: 64)
        let reactionEvent = makeReactionEvent(
            id: String(repeating: "f", count: 64),
            pubkey: reactorPubkey,
            targetEventID: targetEventID,
            targetPubkey: targetPubkey,
            bonusCount: 6
        )

        service.registerPublishedReaction(reactionEvent, targetEventID: targetEventID)

        XCTAssertEqual(service.reactionCount(for: targetEventID), 7)
        XCTAssertEqual(
            service.currentUserReaction(for: targetEventID, currentPubkey: reactorPubkey)?.bonusCount,
            6
        )
    }

    @MainActor
    func testCurrentSnapshotSeedsIndependentRowsBeforePerEventPublisherUpdates() async {
        let targetA = String(repeating: "a", count: 64)
        let targetB = String(repeating: "b", count: 64)
        let reactor = String(repeating: "c", count: 64)
        let service = NoteReactionStatsService(
            relayClient: SpyReactionRelayClient(),
            store: NoteReactionStatsStore(fileManager: ReactionTestFileManager(rootURL: temporaryRootURL()))
        )

        service.registerPublishedReaction(
            makeReactionEvent(
                id: String(repeating: "d", count: 64),
                pubkey: reactor,
                targetEventID: targetA,
                targetPubkey: String(repeating: "e", count: 64),
                bonusCount: 0
            ),
            targetEventID: targetA
        )

        let seededRowA = service.currentSnapshot(for: targetA)
        let seededRowB = service.currentSnapshot(for: targetB)

        var rowAUpdates: [Int] = []
        var rowBUpdates: [Int] = []
        let cancellableA = service.publisher(for: targetA).sink { rowAUpdates.append($0.reactionCount) }
        let cancellableB = service.publisher(for: targetB).sink { rowBUpdates.append($0.reactionCount) }
        defer {
            cancellableA.cancel()
            cancellableB.cancel()
        }

        service.registerPublishedReaction(
            makeReactionEvent(
                id: String(repeating: "e", count: 64),
                pubkey: String(repeating: "f", count: 64),
                targetEventID: targetA,
                targetPubkey: String(repeating: "1", count: 64),
                bonusCount: 0
            ),
            targetEventID: targetA
        )

        XCTAssertEqual(seededRowA.reactionCount, 1)
        XCTAssertEqual(seededRowB.reactionCount, 0)
        XCTAssertEqual(service.currentSnapshot(for: targetB).reactionCount, 0)
        XCTAssertEqual(rowAUpdates.first, 1)
        XCTAssertEqual(rowAUpdates.last, 2)
        XCTAssertEqual(rowBUpdates, [0])
    }

    @MainActor
    func testCurrentSnapshotReturnsLatestStateWithoutObservation() async {
        let eventID = String(repeating: "f", count: 64)
        let reactor = String(repeating: "1", count: 64)
        let service = NoteReactionStatsService(
            relayClient: SpyReactionRelayClient(),
            store: NoteReactionStatsStore(fileManager: ReactionTestFileManager(rootURL: temporaryRootURL()))
        )

        service.registerPublishedReaction(
            makeReactionEvent(
                id: String(repeating: "2", count: 64),
                pubkey: reactor,
                targetEventID: eventID,
                targetPubkey: String(repeating: "3", count: 64),
                bonusCount: 0
            ),
            targetEventID: eventID
        )

        XCTAssertEqual(service.currentSnapshot(for: eventID).reactionCount, 1)
    }

    @MainActor
    func testPrefetchMergesReplyAndRepostCountsWithReactions() async throws {
        let targetEventID = String(repeating: "1", count: 64)
        let targetPubkey = String(repeating: "2", count: 64)
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))
        let targetEvent = makeReactionTargetEvent(
            id: targetEventID,
            pubkey: targetPubkey
        )
        let replyEvent = makeReplyEvent(
            id: String(repeating: "3", count: 64),
            pubkey: String(repeating: "4", count: 64),
            targetEventID: targetEventID,
            targetPubkey: targetPubkey
        )
        let repostEvent = makeRepostEvent(
            id: String(repeating: "5", count: 64),
            pubkey: String(repeating: "6", count: 64),
            targetEventID: targetEventID,
            targetPubkey: targetPubkey
        )
        let reactionEvent = makeReactionEvent(
            id: String(repeating: "7", count: 64),
            pubkey: String(repeating: "8", count: 64),
            targetEventID: targetEventID,
            targetPubkey: targetPubkey,
            bonusCount: 0
        )
        let relayClient = SpyReactionRelayClient(events: [replyEvent, repostEvent, reactionEvent])
        let service = NoteReactionStatsService(
            relayClient: relayClient,
            store: NoteReactionStatsStore(fileManager: ReactionTestFileManager(rootURL: temporaryRootURL()))
        )

        service.prefetch(events: [targetEvent], relayURLs: [relayURL])
        try await Task.sleep(nanoseconds: 160_000_000)

        XCTAssertEqual(service.reactionCount(for: targetEventID), 1)
        XCTAssertEqual(service.replyCount(for: targetEventID), 1)
        XCTAssertEqual(service.repostCount(for: targetEventID), 1)
        let capturedFilters = await relayClient.capturedFilters()
        XCTAssertEqual(capturedFilters.first?.kinds?.sorted(), [1, 6, 7, 16, 1111, 1244])
    }

    private func temporaryRootURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteReactionBonusTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingReactionRelayPublisher: NostrRelayEventPublishing {
    private var eventData: Data?

    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async throws {
        self.eventData = eventData
    }

    func capture() -> ReactionRelayPublishCapture {
        ReactionRelayPublishCapture(eventData: eventData)
    }
}

private struct ReactionRelayPublishCapture: Sendable {
    let eventData: Data?
}

private actor SpyReactionRelayClient: NostrRelayEventFetching {
    private let events: [Flow.NostrEvent]
    private var filters: [NostrFilter] = []

    init(events: [Flow.NostrEvent] = []) {
        self.events = events
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        filters.append(filter)
        return events
    }

    func capturedFilters() -> [NostrFilter] {
        filters
    }
}

private final class ReactionTestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        [rootURL]
    }
}

private func makeReactionTargetEvent(
    id: String = String(repeating: "1", count: 64),
    pubkey: String = String(repeating: "2", count: 64)
) -> Flow.NostrEvent {
    Flow.NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: 1_700_000_000,
        kind: 1,
        tags: [],
        content: "Target note",
        sig: String(repeating: "3", count: 128)
    )
}

private func makeReplyEvent(
    id: String,
    pubkey: String,
    targetEventID: String,
    targetPubkey: String
) -> Flow.NostrEvent {
    Flow.NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: 1_700_000_010,
        kind: 1,
        tags: [
            ["e", targetEventID, "", "reply"],
            ["p", targetPubkey]
        ],
        content: "Replying",
        sig: String(repeating: "5", count: 128)
    )
}

private func makeRepostEvent(
    id: String,
    pubkey: String,
    targetEventID: String,
    targetPubkey: String
) -> Flow.NostrEvent {
    Flow.NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: 1_700_000_020,
        kind: 6,
        tags: [
            ["e", targetEventID],
            ["p", targetPubkey]
        ],
        content: "",
        sig: String(repeating: "6", count: 128)
    )
}

private func makeReactionEvent(
    id: String,
    pubkey: String,
    targetEventID: String,
    targetPubkey: String,
    bonusCount: Int
) -> Flow.NostrEvent {
    var tags = [
        ["e", targetEventID],
        ["p", targetPubkey],
        ["k", "1"]
    ]
    if let bonusTag = ReactionBonusTag.bonusTag(for: bonusCount) {
        tags.append(bonusTag)
    }
    return Flow.NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: 1_700_000_000,
        kind: 7,
        tags: tags,
        content: "+",
        sig: String(repeating: "4", count: 128)
    )
}

private func firstTag(named name: String, in event: Flow.NostrEvent) -> [String]? {
    event.tags.first { tag in
        tag.first?.lowercased() == name.lowercased()
    }
}
