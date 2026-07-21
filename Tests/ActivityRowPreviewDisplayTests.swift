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

        XCTAssertEqual(row.previewDisplay, .image(imageURL, authorPubkey: targetEvent.pubkey))
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

    func testImageOnlyReplyPreviewCarriesReplyAuthorPubkey() {
        let imageURL = URL(string: "https://cdn.example.com/reply.jpg")!
        let rootEventID = hex("3")
        let replyAuthorPubkey = hex("4")
        let replyEvent = makeEvent(
            id: hex("5"),
            pubkey: replyAuthorPubkey,
            kind: 1,
            tags: [["e", rootEventID, "", "reply"]],
            content: imageURL.absoluteString
        )
        let row = ActivityRow(
            event: replyEvent,
            actor: ActivityActor(pubkey: replyAuthorPubkey, profile: nil),
            action: .reply(kind: 1),
            target: ActivityTargetNote(
                reference: .eventID(rootEventID),
                event: nil,
                profile: nil,
                snippet: ""
            )
        )

        XCTAssertEqual(row.previewDisplay, .image(imageURL, authorPubkey: replyAuthorPubkey))
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

    @MainActor
    func testLoadIfNeededShowsCachedPulseRowsBeforeRelayRefreshFinishes() async throws {
        let currentUserPubkey = hex("a")
        let cachedMentionEvent = makeEvent(
            id: hex("7"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Cached Pulse mention",
            createdAt: 1_700_000_200
        )
        let cache = ActivityTestEventCache()
        await cache.store(
            events: [cachedMentionEvent],
            for: ActivityViewModel.activityCacheKey(
                currentUserPubkey: currentUserPubkey,
                readRelayURLs: [defaultActivityRelayURL]
            )
        )
        let harness = try ActivityViewModelHarness(
            initialRelayEvents: [:],
            relayDelayNanoseconds: 500_000_000,
            activityEventCache: cache
        )

        harness.viewModel.configure(
            currentUserPubkey: currentUserPubkey,
            readRelayURLs: [defaultActivityRelayURL]
        )
        await harness.viewModel.loadIfNeeded()

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [cachedMentionEvent.id])
        XCTAssertEqual(harness.viewModel.visibleItems.first?.previewDisplay, .text("Cached Pulse mention"))
    }

    @MainActor
    func testLoadIfNeededRetriesAfterInitialRelayFailure() async throws {
        let currentUserPubkey = hex("a")
        let mentionEvent = makeEvent(
            id: hex("8"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Recovered Pulse mention",
            createdAt: 1_700_000_300
        )
        let harness = try ActivityViewModelHarness(
            initialRelayEvents: [defaultActivityRelayURL: [mentionEvent]],
            relayFailuresBeforeSuccess: [defaultActivityRelayURL: 1]
        )

        harness.viewModel.configure(
            currentUserPubkey: currentUserPubkey,
            readRelayURLs: [defaultActivityRelayURL]
        )
        await harness.viewModel.loadIfNeeded()
        XCTAssertEqual(harness.viewModel.errorMessage, "Couldn't load activity right now.")
        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)

        await harness.viewModel.loadIfNeeded()

        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [mentionEvent.id])
    }

    @MainActor
    func testCancelledInitialLoadRetriesWhenPulseOpensAgain() async throws {
        let currentUserPubkey = hex("a")
        let mentionEvent = makeEvent(
            id: hex("9"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Mention after cancellation",
            createdAt: 1_700_000_400
        )
        let harness = try ActivityViewModelHarness(
            initialRelayEvents: [defaultActivityRelayURL: [mentionEvent]],
            relayDelayNanoseconds: 300_000_000
        )

        harness.viewModel.configure(
            currentUserPubkey: currentUserPubkey,
            readRelayURLs: [defaultActivityRelayURL]
        )
        let cancelledLoad = Task { await harness.viewModel.loadIfNeeded() }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelledLoad.cancel()
        await cancelledLoad.value

        await harness.viewModel.loadIfNeeded()

        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [mentionEvent.id])
    }

    @MainActor
    func testLoadIfNeededIncludesMentionFromSlowerRelayAfterFastRelayIsEmpty() async throws {
        let currentUserPubkey = hex("a")
        let fastEmptyRelay = URL(string: "wss://fast-empty.example.com")!
        let slowerMentionRelay = URL(string: "wss://slower-mention.example.com")!
        let mentionEvent = makeEvent(
            id: hex("c"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Mention stored on a slower read relay",
            createdAt: 1_700_000_500
        )
        let harness = try ActivityViewModelHarness(
            initialRelayEvents: [
                fastEmptyRelay: [],
                slowerMentionRelay: [mentionEvent]
            ],
            relayDelayNanosecondsByRelay: [slowerMentionRelay: 500_000_000]
        )

        harness.viewModel.configure(
            currentUserPubkey: currentUserPubkey,
            readRelayURLs: [fastEmptyRelay, slowerMentionRelay]
        )
        await harness.viewModel.loadIfNeeded()

        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [mentionEvent.id])
    }

    @MainActor
    func testRelayResetRetriesFailedPulseHistoryLoad() async throws {
        let currentUserPubkey = hex("a")
        let mentionEvent = makeEvent(
            id: hex("d"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Mention after relay reconnect",
            createdAt: 1_700_000_600
        )
        let harness = try ActivityViewModelHarness(
            initialRelayEvents: [defaultActivityRelayURL: [mentionEvent]],
            relayFailuresBeforeSuccess: [defaultActivityRelayURL: 1]
        )

        harness.viewModel.configure(
            currentUserPubkey: currentUserPubkey,
            readRelayURLs: [defaultActivityRelayURL]
        )
        await harness.viewModel.sceneDidChange(isActive: true)
        XCTAssertEqual(harness.viewModel.errorMessage, "Couldn't load activity right now.")

        await Task.yield()
        harness.notificationCenter.post(name: .relayConnectionsDidReset, object: nil)
        try await harness.waitUntilVisibleItemIDsEqual([mentionEvent.id], timeout: 3)

        XCTAssertNil(harness.viewModel.errorMessage)
    }

    @MainActor
    func testConfigurationChangeCannotPublishStalePulseHistory() async throws {
        let firstUserPubkey = hex("a")
        let secondUserPubkey = hex("c")
        let firstRelay = URL(string: "wss://first-account.example.com")!
        let secondRelay = URL(string: "wss://second-account.example.com")!
        let staleMention = makeEvent(
            id: hex("e"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["p", firstUserPubkey]],
            content: "Stale mention from the previous configuration",
            createdAt: 1_700_000_700
        )
        let currentMention = makeEvent(
            id: hex("f"),
            pubkey: hex("d"),
            kind: 1,
            tags: [["p", secondUserPubkey]],
            content: "Mention for the current configuration",
            createdAt: 1_700_000_800
        )
        let harness = try ActivityViewModelHarness(
            initialRelayEvents: [
                firstRelay: [staleMention],
                secondRelay: [currentMention]
            ],
            relayDelayNanosecondsByRelay: [firstRelay: 300_000_000]
        )

        harness.viewModel.configure(
            currentUserPubkey: firstUserPubkey,
            readRelayURLs: [firstRelay]
        )
        let staleLoad = Task { await harness.viewModel.loadIfNeeded() }
        try await Task.sleep(nanoseconds: 30_000_000)

        harness.viewModel.configure(
            currentUserPubkey: secondUserPubkey,
            readRelayURLs: [secondRelay]
        )
        await harness.viewModel.loadIfNeeded()
        await staleLoad.value

        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [currentMention.id])
    }
}

private let defaultActivityRelayURL = URL(string: "wss://activity-relay.example.com")!

private actor ActivityTestRelayClient: NostrRelayEventFetching {
    private var eventsByRelay: [String: [NostrEvent]]
    private let delayNanoseconds: UInt64
    private let delayNanosecondsByRelay: [String: UInt64]
    private var failuresBeforeSuccessByRelay: [String: Int]

    init(
        eventsByRelay: [URL: [NostrEvent]],
        delayNanoseconds: UInt64 = 0,
        delayNanosecondsByRelay: [URL: UInt64] = [:],
        failuresBeforeSuccessByRelay: [URL: Int] = [:]
    ) {
        var normalized: [String: [NostrEvent]] = [:]
        for (relayURL, events) in eventsByRelay {
            normalized[canonicalRelayString(relayURL)] = events
        }
        self.eventsByRelay = normalized
        self.delayNanoseconds = delayNanoseconds
        self.delayNanosecondsByRelay = Dictionary(
            uniqueKeysWithValues: delayNanosecondsByRelay.map {
                (canonicalRelayString($0.key), $0.value)
            }
        )
        self.failuresBeforeSuccessByRelay = Dictionary(
            uniqueKeysWithValues: failuresBeforeSuccessByRelay.map {
                (canonicalRelayString($0.key), $0.value)
            }
        )
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        let relayKey = canonicalRelayString(relayURL)
        let relayDelayNanoseconds = delayNanosecondsByRelay[relayKey] ?? delayNanoseconds
        if relayDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: relayDelayNanoseconds)
        }
        if let remainingFailures = failuresBeforeSuccessByRelay[relayKey], remainingFailures > 0 {
            failuresBeforeSuccessByRelay[relayKey] = remainingFailures - 1
            throw ActivityTestRelayError.forcedFailure
        }

        let authors = Set((filter.authors ?? []).map { $0.lowercased() })
        let ids = Set((filter.ids ?? []).map { $0.lowercased() })
        let kinds = Set(filter.kinds ?? [])
        let until = filter.until
        let since = filter.since
        let limit = filter.limit ?? Int.max
        let tagFilters = filter.tagFilters ?? [:]

        return Array(
            (eventsByRelay[relayKey] ?? [])
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
    let notificationCenter: NotificationCenter

    init(
        relayURL: URL = defaultActivityRelayURL,
        initialRelayEvents: [URL: [NostrEvent]],
        relayDelayNanoseconds: UInt64 = 0,
        relayDelayNanosecondsByRelay: [URL: UInt64] = [:],
        relayFailuresBeforeSuccess: [URL: Int] = [:],
        activityEventCache: (any ActivityEventCaching)? = nil
    ) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileManager = ActivityTestFileManager(rootURL: rootURL)
        let defaults = UserDefaults(suiteName: "ActivityViewModelTests-\(UUID().uuidString)")!
        notificationCenter = NotificationCenter()
        let relayClient = ActivityTestRelayClient(
            eventsByRelay: initialRelayEvents,
            delayNanoseconds: relayDelayNanoseconds,
            delayNanosecondsByRelay: relayDelayNanosecondsByRelay,
            failuresBeforeSuccessByRelay: relayFailuresBeforeSuccess
        )
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
            liveSubscriber: ActivityTestLiveSubscriber(),
            defaults: defaults,
            mutedThreadStore: MutedThreadStore(defaults: defaults),
            activityEventCache: activityEventCache ?? ActivityTestEventCache(),
            notificationCenter: notificationCenter
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

    func waitUntilVisibleItemIDsEqual(_ expectedIDs: [String], timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewModel.visibleItems.map(\.id) == expectedIDs {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTFail("Timed out waiting for Pulse items \(expectedIDs)")
    }
}

private enum ActivityTestRelayError: Error {
    case forcedFailure
}

private struct ActivityTestLiveSubscriber: ActivityLiveEventSubscribing {
    func run(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async {}
}

private actor ActivityTestEventCache: ActivityEventCaching {
    private var eventsByKey: [String: [NostrEvent]] = [:]

    func events(for key: String) async -> [NostrEvent]? {
        eventsByKey[key]
    }

    func store(events: [NostrEvent], for key: String) async {
        eventsByKey[key] = events
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
