import XCTest
@testable import Flow

final class ActivityRowPreviewDisplayTests: XCTestCase {
    func testReactionToImageOnlyNoteUsesImagePreview() {
        let imageURL = URL(string: "https://cdn.example.com/photo.jpg")!
        let targetEvent = makeEvent(
            id: hex("1"),
            pubkey: hex("a"),
            kind: 1,
            tags: [],
            content: imageURL.absoluteString
        )
        let row = ActivityRow(
            event: makeReactionEvent(targetEventID: targetEvent.id),
            actor: ActivityActor(pubkey: hex("b"), profile: nil),
            action: .reaction(ActivityReaction(content: "+", shortcode: nil, customEmojiImageURL: nil)),
            target: ActivityTargetNote(
                reference: .eventID(targetEvent.id),
                event: targetEvent,
                profile: nil,
                snippet: targetEvent.activitySnippet()
            )
        )

        XCTAssertEqual(row.previewDisplay, .image(imageURL))
    }

    func testReactionToVideoOnlyNoteKeepsMediaFallback() {
        let targetEvent = makeEvent(
            id: hex("2"),
            pubkey: hex("c"),
            kind: 1,
            tags: [],
            content: "https://cdn.example.com/clip.mp4"
        )
        let row = ActivityRow(
            event: makeReactionEvent(targetEventID: targetEvent.id),
            actor: ActivityActor(pubkey: hex("d"), profile: nil),
            action: .reaction(ActivityReaction(content: "+", shortcode: nil, customEmojiImageURL: nil)),
            target: ActivityTargetNote(
                reference: .eventID(targetEvent.id),
                event: targetEvent,
                profile: nil,
                snippet: targetEvent.activitySnippet()
            )
        )

        XCTAssertEqual(row.previewDisplay, .mediaPlaceholder)
    }

    func testReplyPreviewUsesConversationIDForThreadMuting() {
        let rootEventID = hex("4")
        let replyEvent = makeEvent(
            id: hex("5"),
            pubkey: hex("6"),
            kind: 1,
            tags: [["e", rootEventID, "", "root"]],
            content: "reply body"
        )
        let row = ActivityRow(
            event: replyEvent,
            actor: ActivityActor(pubkey: hex("7"), profile: nil),
            action: .reply(kind: 1),
            target: ActivityTargetNote(
                reference: .eventID(rootEventID),
                event: nil,
                profile: nil,
                snippet: "thread root"
            )
        )

        XCTAssertEqual(row.threadMuteIdentifier, rootEventID)
    }
}

final class ActivityViewModelLoadingTests: XCTestCase {
    @MainActor
    func testLoadIfNeededLoadsPulseMentionRows() async throws {
        let currentUserPubkey = hex("a")
        let mentionEvent = makeEvent(
            id: hex("6"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Mentioning you in Pulse",
            createdAt: 1_700_000_100
        )
        let harness = try ActivityViewModelHarness(
            initialRelayEvents: [
                defaultActivityRelayURL: [mentionEvent]
            ]
        )

        harness.viewModel.configure(
            currentUserPubkey: currentUserPubkey,
            readRelayURLs: [defaultActivityRelayURL]
        )
        await harness.viewModel.loadIfNeeded()
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [mentionEvent.id])
        XCTAssertEqual(harness.viewModel.visibleItems.first?.action.title, "Mention")
    }
}

private let defaultActivityRelayURL = URL(string: "wss://activity-relay.example.com")!

private actor ActivityTestRelayClient: NostrRelayEventFetching {
    private var eventsByRelay: [String: [NostrEvent]]

    init(eventsByRelay: [URL: [NostrEvent]]) {
        var normalized: [String: [NostrEvent]] = [:]
        for (relayURL, events) in eventsByRelay {
            normalized[canonicalRelayString(relayURL)] = events
        }
        self.eventsByRelay = normalized
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        let authors = Set((filter.authors ?? []).map { $0.lowercased() })
        let ids = Set((filter.ids ?? []).map { $0.lowercased() })
        let kinds = Set(filter.kinds ?? [])
        let until = filter.until
        let since = filter.since
        let limit = filter.limit ?? Int.max
        let tagFilters = filter.tagFilters ?? [:]

        return Array(
            (eventsByRelay[canonicalRelayString(relayURL)] ?? [])
                .filter { event in
                    if !authors.isEmpty && !authors.contains(event.pubkey.lowercased()) {
                        return false
                    }
                    if !ids.isEmpty && !ids.contains(event.id.lowercased()) {
                        return false
                    }
                    if !kinds.isEmpty && !kinds.contains(event.kind) {
                        return false
                    }
                    if let until, event.createdAt > until {
                        return false
                    }
                    if let since, event.createdAt < since {
                        return false
                    }

                    for (tagName, allowedValues) in tagFilters {
                        let normalizedTagName = tagName.lowercased()
                        let normalizedAllowedValues = Set(allowedValues.map { $0.lowercased() })
                        let matchesTag = event.tags.contains { tag in
                            tag.count > 1 &&
                                tag[0].lowercased() == normalizedTagName &&
                                normalizedAllowedValues.contains(tag[1].lowercased())
                        }
                        if !matchesTag {
                            return false
                        }
                    }

                    return true
                }
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .prefix(limit)
        )
    }
}

@MainActor
private final class ActivityViewModelHarness {
    let rootURL: URL
    let viewModel: ActivityViewModel

    init(
        relayURL: URL = defaultActivityRelayURL,
        initialRelayEvents: [URL: [NostrEvent]]
    ) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileManager = ActivityTestFileManager(rootURL: rootURL)
        let defaults = UserDefaults(suiteName: "ActivityViewModelTests-\(UUID().uuidString)")!
        let relayClient = ActivityTestRelayClient(eventsByRelay: initialRelayEvents)
        let profileSnapshotStore = ProfileSnapshotStore(fileManager: fileManager)
        let profileCache = ProfileCache(snapshotStore: profileSnapshotStore)
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        let seenEventStore = SeenEventStore(fileManager: fileManager)
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: profileCache,
            relayHintCache: ProfileRelayHintCache(),
            followListCache: followListCache,
            seenEventStore: seenEventStore,
            presentationCache: FeedPresentationCache()
        )

        viewModel = ActivityViewModel(
            service: service,
            liveSubscriber: NostrLiveFeedSubscriber(
                session: .shared,
                liveEventFallbackDelayNanoseconds: 1,
                receiveIdleTimeoutNanoseconds: 1_000_000,
                pingTimeoutNanoseconds: 1_000_000
            ),
            defaults: defaults,
            mutedThreadStore: MutedThreadStore(defaults: defaults)
        )

        _ = relayURL
    }

    func waitUntilIdle(timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !viewModel.isLoading && !viewModel.isRefreshing {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for activity view model to become idle")
    }
}

private final class ActivityTestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        [rootURL]
    }
}

private func makeReactionEvent(targetEventID: String) -> NostrEvent {
    makeEvent(
        id: hex("9"),
        pubkey: hex("e"),
        kind: 7,
        tags: [
            ["e", targetEventID],
            ["p", hex("f")]
        ],
        content: "+"
    )
}

private func makeEvent(
    id: String,
    pubkey: String,
    kind: Int,
    tags: [[String]],
    content: String,
    createdAt: Int = 1_700_000_000
) -> NostrEvent {
    NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
        sig: String(repeating: "f", count: 128)
    )
}

private func hex(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func canonicalRelayString(_ relayURL: URL) -> String {
    let value = relayURL.absoluteString.lowercased()
    return value.hasSuffix("/") ? String(value.dropLast()) : value
}
