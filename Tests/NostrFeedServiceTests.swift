import XCTest
import NostrSDK
@testable import Flow

final class NostrFeedServiceTests: XCTestCase {
    func testNostrProfileDecodeReadsBannerMetadataKeys() {
        let bannerJSON = """
        {
          "name": "alice",
          "banner": "https://example.com/banner.jpg"
        }
        """

        let coverJSON = """
        {
          "name": "alice",
          "cover": "https://example.com/cover.jpg"
        }
        """

        XCTAssertEqual(NostrProfile.decode(from: bannerJSON)?.banner, "https://example.com/banner.jpg")
        XCTAssertEqual(NostrProfile.decode(from: coverJSON)?.banner, "https://example.com/cover.jpg")
    }

    func testIngestLiveEventsStoresEventsLocally() async throws {
        let harness = try TestHarness()
        let event = makeEvent(
            id: hex("a"),
            pubkey: hex("b"),
            kind: 1,
            tags: [["t", "flow"]],
            content: "live event"
        )

        await harness.service.ingestLiveEvents([event])

        let resolved = await harness.eventRepository.events(ids: [event.id])
        XCTAssertEqual(resolved[event.id.lowercased()]?.id.lowercased(), event.id.lowercased())
    }

    func testFastRelayModeMergesMultipleRelayResponses() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFastRelayMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let firstRelayEvent = makeEvent(
            id: hex("c"),
            pubkey: hex("d"),
            kind: 1,
            tags: [],
            content: "first relay",
            createdAt: 1_700_000_100
        )
        let secondRelayEvent = makeEvent(
            id: hex("e"),
            pubkey: hex("f"),
            kind: 1,
            tags: [],
            content: "second relay",
            createdAt: 1_700_000_200
        )
        let relayClient = DelayedRelayClient(
            eventsByRelay: [
                relayURL: [firstRelayEvent],
                relayURL2: [secondRelayEvent]
            ],
            delaysByRelay: [:]
        )
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let items = try await service.fetchFeed(
            relayURLs: [relayURL, relayURL2],
            kinds: [1],
            limit: 10,
            until: nil,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.01,
            relayFetchMode: .firstNonEmptyRelay
        )

        let fetchCount = await relayClient.fetchCount()

        XCTAssertEqual(items.map(\.id), [secondRelayEvent.id, firstRelayEvent.id])
        XCTAssertEqual(fetchCount, 2)
    }

    func testFastRelayModeHonorsTimeoutWhenAnotherRelayStalls() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFastRelayTimeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let fastRelayEvent = makeEvent(
            id: hex("a"),
            pubkey: hex("b"),
            kind: 1,
            tags: [],
            content: "fast relay",
            createdAt: 1_700_000_300
        )
        let slowRelayEvent = makeEvent(
            id: hex("c"),
            pubkey: hex("d"),
            kind: 1,
            tags: [],
            content: "slow relay",
            createdAt: 1_700_000_400
        )
        let relayClient = DelayedRelayClient(
            eventsByRelay: [
                relayURL: [fastRelayEvent],
                relayURL2: [slowRelayEvent]
            ],
            delaysByRelay: [
                relayURL2: 700_000_000
            ]
        )
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let startedAt = Date()
        let items = try await service.fetchFeed(
            relayURLs: [relayURL, relayURL2],
            kinds: [1],
            limit: 10,
            until: nil,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.1,
            relayFetchMode: .firstNonEmptyRelay
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(items.map(\.id), [fastRelayEvent.id])
        XCTAssertLessThan(elapsed, 0.35)
    }

    func testTrendingFetchDoesNotReuseCachedEmptyTimeline() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowTrendingEmptyCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let trendingNote = makeEvent(
            id: hex("a"),
            pubkey: hex("b"),
            kind: 1,
            tags: [],
            content: "Trending recovered after empty response",
            createdAt: 1_700_000_500
        )
        let relayClient = SequencedRelayClient(responses: [[], [trendingNote]])
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let emptyItems = try await service.fetchTrendingNotes(
            limit: 10,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.1
        )
        let recoveredItems = try await service.fetchTrendingNotes(
            limit: 10,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.1
        )

        XCTAssertTrue(emptyItems.isEmpty)
        XCTAssertEqual(recoveredItems.map(\.id), [trendingNote.id])
        let fetchCount = await relayClient.fetchCount()
        XCTAssertEqual(fetchCount, 2)
    }

    func testProfileEventServicePersistsFetchedMetadataSnapshotsLocally() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowProfileEventService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let eventRepository = EventRepository(fileManager: fileManager)
        let pubkey = hex("a")
        let older = makeEvent(
            id: hex("b"),
            pubkey: pubkey,
            kind: 0,
            tags: [],
            content: #"{"name":"older"}"#,
            createdAt: 1_700_000_000
        )
        let newer = makeEvent(
            id: hex("c"),
            pubkey: pubkey,
            kind: 0,
            tags: [],
            content: #"{"name":"newer"}"#,
            createdAt: 1_700_000_100
        )
        let relayClient = ProfileMetadataRelayClient(eventsByRelay: [
            relayURL: [older],
            relayURL2: [newer]
        ])
        let service = ProfileEventService(relayClient: relayClient, eventRepository: eventRepository)

        let snapshot = try await service.fetchProfileMetadataSnapshot(
            relayURLs: [relayURL, relayURL2],
            pubkey: pubkey
        )

        XCTAssertEqual(snapshot?.content, newer.content)
        let resolved = await eventRepository.events(ids: [newer.id])
        XCTAssertEqual(resolved[newer.id.lowercased()]?.content, newer.content)
    }

    func testOutboxRelayPlanStoresFetchedRelayDirectoryEntryAndPrefersWriteRelays() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowOutboxRelayPlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let relayHintCache = ProfileRelayHintCache()
        let authorPubkey = hex("1")
        let authorReadRelayURL = URL(string: "wss://author-read.example")!
        let authorWriteRelayURL = URL(string: "wss://author-write.example")!
        let hintedRelayURL = URL(string: "wss://hinted.example")!

        await relayHintCache.storeHints([authorPubkey: [hintedRelayURL]])

        let relayListEvent = makeEvent(
            id: hex("2"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [
                ["r", authorReadRelayURL.absoluteString, "read"],
                ["r", authorWriteRelayURL.absoluteString, "write"]
            ],
            content: "",
            createdAt: 1_700_000_400
        )
        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [relayListEvent]
        ])
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: relayHintCache,
            followListCache: FollowListSnapshotCache(fileManager: fileManager),
            eventRepository: EventRepository(fileManager: fileManager),
            presentationCache: FeedPresentationCache()
        )

        let plan = await service.outboxBackedRelayPlan(
            authors: [authorPubkey],
            baseReadRelayURLs: [relayURL]
        )
        let storedEntry = await relayHintCache.entry(for: authorPubkey)

        XCTAssertEqual(
            canonicalRelayStrings(plan.relayURLs(for: authorPubkey)),
            [
                "wss://author-write.example",
                "wss://hinted.example",
                "wss://relay.example.com",
                "wss://relay.damus.io",
                "wss://relay.primal.net",
                "wss://relay.nostr.band",
                "wss://relay.snort.social",
                "wss://nostr.wine",
                "wss://nos.lol"
            ]
        )
        XCTAssertEqual(canonicalRelayStrings(storedEntry?.readRelayURLs ?? []), ["wss://author-read.example"])
        XCTAssertEqual(canonicalRelayStrings(storedEntry?.writeRelayURLs ?? []), ["wss://author-write.example"])
        XCTAssertEqual(canonicalRelayStrings(storedEntry?.hintRelayURLs ?? []), ["wss://hinted.example"])
        XCTAssertNotNil(storedEntry?.refreshedAt)
    }

    func testFetchOutboxBackedAuthorFeedUsesWriteRelaysForAuthorContent() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowOutboxAuthorFeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let relayHintCache = ProfileRelayHintCache()
        let authorPubkey = hex("3")
        let authorReadRelayURL = URL(string: "wss://author-feed-read.example")!
        let authorWriteRelayURL = URL(string: "wss://author-feed-write.example")!
        let authoredEvent = makeEvent(
            id: hex("4"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "outbox author event",
            createdAt: 1_700_000_500
        )
        let relayListEvent = makeEvent(
            id: hex("5"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [
                ["r", authorReadRelayURL.absoluteString, "read"],
                ["r", authorWriteRelayURL.absoluteString, "write"]
            ],
            content: "",
            createdAt: 1_700_000_450
        )
        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [relayListEvent],
            authorReadRelayURL: [authoredEvent],
            authorWriteRelayURL: [authoredEvent]
        ])
        let eventRepository = EventRepository(fileManager: fileManager)
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: relayHintCache,
            followListCache: FollowListSnapshotCache(fileManager: fileManager),
            eventRepository: eventRepository,
            presentationCache: FeedPresentationCache()
        )

        let items = try await service.fetchOutboxBackedAuthorFeed(
            baseReadRelayURLs: [relayURL],
            authorPubkey: authorPubkey,
            kinds: [1],
            limit: 10,
            until: nil,
            hydrationMode: .cachedProfilesOnly
        )
        let requestedRelayURLs = await relayClient.requestedRelayURLs()
        let storedEvent = await eventRepository.events(ids: [authoredEvent.id])

        XCTAssertEqual(items.map(\.id), [authoredEvent.id])
        XCTAssertTrue(canonicalRelayStrings(requestedRelayURLs).contains("wss://author-feed-write.example"))
        XCTAssertEqual(storedEvent[authoredEvent.id.lowercased()]?.id.lowercased(), authoredEvent.id.lowercased())
    }

    func testFetchOutboxBackedFollowingFeedGroupsAuthorsByWriteRelay() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowOutboxFollowingGroups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let authorA = hex("a")
        let authorB = hex("b")
        let writeRelayA = URL(string: "wss://author-a-write.example")!
        let writeRelayB = URL(string: "wss://author-b-write.example")!
        let eventA = makeEvent(id: hex("1"), pubkey: authorA, kind: 1, tags: [], content: "a")
        let eventB = makeEvent(id: hex("2"), pubkey: authorB, kind: 1, tags: [], content: "b")
        let relayListA = makeEvent(
            id: hex("3"),
            pubkey: authorA,
            kind: 10_002,
            tags: [["r", writeRelayA.absoluteString, "write"]],
            content: ""
        )
        let relayListB = makeEvent(
            id: hex("4"),
            pubkey: authorB,
            kind: 10_002,
            tags: [["r", writeRelayB.absoluteString, "write"]],
            content: ""
        )
        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [relayListA, relayListB],
            writeRelayA: [eventA],
            writeRelayB: [eventB]
        ])
        let service = makeFeedService(relayClient: relayClient, fileManager: fileManager)

        let items = try await service.fetchOutboxBackedFollowingFeed(
            baseReadRelayURLs: [relayURL],
            authors: [authorA, authorB],
            kinds: [1],
            limit: 10,
            until: nil,
            hydrationMode: .cachedProfilesOnly
        )

        XCTAssertEqual(Set(items.map(\.id)), Set([eventA.id, eventB.id]))
        let requested = Set(await relayClient.requestedRelayURLs().map { canonicalRelayString($0) })
        XCTAssertTrue(requested.contains("wss://author-a-write.example"))
        XCTAssertTrue(requested.contains("wss://author-b-write.example"))
    }

    func testFetchOutboxBackedAuthorFeedDoesNotStopAtFirstRelayWithStaleEvent() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowOutboxAuthorFeedFreshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let authorPubkey = hex("9")
        let fastStaleRelayURL = URL(string: "wss://author-stale.example/")!
        let slowFreshRelayURL = URL(string: "wss://author-fresh.example/")!
        let relayListEvent = makeEvent(
            id: hex("a"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [
                ["r", fastStaleRelayURL.absoluteString, "read"],
                ["r", slowFreshRelayURL.absoluteString, "read"]
            ],
            content: "",
            createdAt: 1_700_000_400
        )
        let staleEvent = makeEvent(
            id: hex("b"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "stale author event",
            createdAt: 1_700_000_410
        )
        let freshEvent = makeEvent(
            id: hex("c"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "fresh author event",
            createdAt: 1_700_000_510
        )
        let relayClient = DelayedRelayClient(
            eventsByRelay: [
                relayURL: [relayListEvent],
                fastStaleRelayURL: [staleEvent],
                slowFreshRelayURL: [freshEvent]
            ],
            delaysByRelay: [
                fastStaleRelayURL: 20_000_000,
                slowFreshRelayURL: 120_000_000
            ]
        )
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let items = try await service.fetchOutboxBackedAuthorFeed(
            baseReadRelayURLs: [relayURL],
            authorPubkey: authorPubkey,
            kinds: [1],
            limit: 10,
            until: nil,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.4,
            relayFetchMode: .firstNonEmptyRelay
        )

        XCTAssertEqual(items.map(\.id), [freshEvent.id, staleEvent.id])
    }

    func testFetchReferencedEventsUseConfiguredReadRelaysAndHintsOnly() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowOutboxReferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let relayHintCache = ProfileRelayHintCache()
        let authorPubkey = hex("6")
        let authorWriteRelayURL = URL(string: "wss://author-reference-write.example")!
        let hintedRelayURL = URL(string: "wss://author-reference-hint.example")!
        let referencedEvent = makeEvent(
            id: hex("7"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "referenced event from write relay",
            createdAt: 1_700_000_600
        )
        let relayListEvent = makeEvent(
            id: hex("8"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [
                ["r", authorWriteRelayURL.absoluteString, "write"]
            ],
            content: "",
            createdAt: 1_700_000_550
        )
        await relayHintCache.storeHints([authorPubkey: [hintedRelayURL]])

        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [relayListEvent],
            authorWriteRelayURL: [referencedEvent],
            hintedRelayURL: [referencedEvent]
        ])
        let eventRepository = EventRepository(fileManager: fileManager)
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: relayHintCache,
            followListCache: FollowListSnapshotCache(fileManager: fileManager),
            eventRepository: eventRepository,
            presentationCache: FeedPresentationCache()
        )
        let reference = NostrEventReferencePointer(
            normalizedIdentifier: referencedEvent.id.lowercased(),
            target: .eventID(referencedEvent.id.lowercased()),
            relayHints: [],
            authorPubkey: authorPubkey
        )

        let resolved = await service.fetchReferencedEvents(
            references: [reference],
            baseRelayURLs: [relayURL]
        )
        let requestedRelayURLs = await relayClient.requestedRelayURLs()
        let storedEvent = await eventRepository.events(ids: [referencedEvent.id])
        let requestedRelayURLStrings = canonicalRelayStrings(requestedRelayURLs)

        XCTAssertNil(resolved[reference])
        XCTAssertEqual(requestedRelayURLStrings, ["wss://relay.example.com"])
        XCTAssertNil(storedEvent[referencedEvent.id.lowercased()])
    }

    func testFetchReferencedFeedItemUsesAuthorRelayDirectoryWhenReferenceIncludesAuthor() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowSingleReferenceOutbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let relayHintCache = ProfileRelayHintCache()
        let authorPubkey = hex("6")
        let authorWriteRelayURL = URL(string: "wss://author-reference-write.example")!
        let referencedEvent = makeEvent(
            id: hex("7"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "referenced event from author write relay",
            createdAt: 1_700_000_600
        )
        let relayListEvent = makeEvent(
            id: hex("8"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [
                ["r", authorWriteRelayURL.absoluteString, "write"]
            ],
            content: "",
            createdAt: 1_700_000_550
        )

        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [relayListEvent],
            authorWriteRelayURL: [referencedEvent]
        ])
        let eventRepository = EventRepository(fileManager: fileManager)
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: relayHintCache,
            followListCache: FollowListSnapshotCache(fileManager: fileManager),
            eventRepository: eventRepository,
            presentationCache: FeedPresentationCache()
        )
        let reference = NostrEventReferencePointer(
            normalizedIdentifier: referencedEvent.id.lowercased(),
            target: .eventID(referencedEvent.id.lowercased()),
            relayHints: [],
            authorPubkey: authorPubkey
        )

        let item = await service.fetchReferencedFeedItem(
            reference: reference,
            relayURLs: [relayURL],
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.4
        )
        let requestedRelayURLStrings = canonicalRelayStrings(await relayClient.requestedRelayURLs())
        let storedEvent = await eventRepository.events(ids: [referencedEvent.id])

        XCTAssertEqual(item?.id, referencedEvent.id)
        XCTAssertTrue(requestedRelayURLStrings.contains("wss://author-reference-write.example"))
        XCTAssertEqual(storedEvent[referencedEvent.id.lowercased()]?.content, referencedEvent.content)
    }

    func testFastFollowingFeedHonorsTimeoutForSlowEmptyAuthorBatch() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFastFollowingFeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)

        let activeAuthor = hex("a")
        let delayedAuthor = hex("b")
        let fillerAuthors = (0..<249).map { index in
            String(format: "%064x", index + 1)
        }
        let authors = [activeAuthor] + fillerAuthors + [delayedAuthor]
        let event = makeEvent(
            id: hex("c"),
            pubkey: activeAuthor,
            kind: 1,
            tags: [],
            content: "Fresh following post",
            createdAt: 1_700_000_250
        )

        let relayClient = AuthorBatchDelayRelayClient(
            events: [event],
            delayedAuthors: [delayedAuthor],
            delayNanoseconds: 2_000_000_000
        )
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            presentationCache: FeedPresentationCache()
        )

        let startedAt = Date()
        let items = try await service.fetchFollowingFeed(
            relayURLs: [relayURL],
            authors: authors,
            kinds: [1],
            limit: 1,
            until: nil,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 1,
            relayFetchMode: .firstRelayWithEvents
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(items.map(\.id), [event.id])
        XCTAssertLessThan(elapsed, 1.2)
    }

    func testFastFollowingFeedHonorsTimeoutForSlowEmptyRelay() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFastFollowingRelayTimeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let author = hex("e")
        let relayClient = DelayedRelayClient(
            eventsByRelay: [
                relayURL: [],
                relayURL2: []
            ],
            delaysByRelay: [
                relayURL2: 700_000_000
            ]
        )
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let startedAt = Date()
        let items = try await service.fetchFollowingFeed(
            relayURLs: [relayURL, relayURL2],
            authors: [author],
            kinds: [1],
            limit: 10,
            until: nil,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.1,
            relayFetchMode: .firstRelayWithEvents
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertTrue(items.isEmpty)
        XCTAssertLessThan(elapsed, 0.35)
    }

    func testSearchProfilesMatchesSingleCharacterPrefixesFromCachedProfiles() async throws {
        let harness = try TestHarness()
        let targetPubkey = String(format: "%064x", 5_000)
        let nonPrefixPubkey = String(format: "%064x", 5_001)

        await harness.profileCache.store(
            profiles: [
                targetPubkey: makeProfile(name: "gigi", displayName: "Gigi"),
                nonPrefixPubkey: makeProfile(name: "meg", displayName: "Meg")
            ],
            missed: []
        )

        let results = await harness.service.searchProfiles(query: "g", limit: 8)

        XCTAssertEqual(results.first?.pubkey, targetPubkey)
        XCTAssertFalse(results.contains { $0.pubkey == nonPrefixPubkey })
    }

    func testSearchProfilesBoostsPreferredCachedPubkeys() async throws {
        let harness = try TestHarness()
        let followedPubkey = String(format: "%064x", 6_000)
        let recentPubkey = String(format: "%064x", 6_001)

        await harness.profileCache.store(
            profiles: [followedPubkey: makeProfile(name: "gale", displayName: "Gale")],
            missed: []
        )
        await harness.profileCache.store(
            profiles: [recentPubkey: makeProfile(name: "gina", displayName: "Gina")],
            missed: []
        )

        let unboostedResults = await harness.service.searchProfiles(query: "g", limit: 8)
        let boostedResults = await harness.service.searchProfiles(
            query: "g",
            limit: 8,
            preferredPubkeys: [followedPubkey]
        )

        XCTAssertEqual(unboostedResults.first?.pubkey, recentPubkey)
        XCTAssertEqual(boostedResults.first?.pubkey, followedPubkey)
    }

    func testStoreFollowListSnapshotLocallyCachesSnapshot() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFollowSnapshotStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        let service = NostrFeedService(
            relayClient: SpyRelayClient(),
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: ProfileRelayHintCache(),
            followListCache: followListCache,
            eventRepository: EventRepository(fileManager: fileManager)
        )

        let authorPubkey = hex("1")
        let followedPubkey = hex("2")
        let snapshot = FollowListSnapshot(
            content: "",
            tags: [["p", followedPubkey, relayURL.absoluteString]]
        )

        await service.storeFollowListSnapshotLocally(snapshot, for: authorPubkey)

        let cached = await followListCache.cachedSnapshot(pubkey: authorPubkey)
        XCTAssertEqual(cached?.followedPubkeys, [followedPubkey])
    }

    func testFetchKnownFollowersUsesPersistedFollowSnapshotsBeforeRelayFetch() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowKnownFollowers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        let relayClient = SpyRelayClient()
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: ProfileRelayHintCache(),
            followListCache: followListCache,
            eventRepository: EventRepository(fileManager: fileManager)
        )

        let profilePubkey = hex("1")
        let knownFollowerPubkey = hex("2")
        let nonFollowerPubkey = hex("3")
        await followListCache.storeSnapshot(
            FollowListSnapshot(content: "", tags: [["p", profilePubkey]]),
            for: knownFollowerPubkey
        )
        await followListCache.storeSnapshot(
            FollowListSnapshot(content: "", tags: [["p", hex("4")]]),
            for: nonFollowerPubkey
        )

        let cached = await service.cachedKnownFollowers(
            profilePubkey: profilePubkey,
            candidatePubkeys: [nonFollowerPubkey, knownFollowerPubkey],
            limit: 5
        )
        XCTAssertEqual(cached, [knownFollowerPubkey])

        let fetched = await service.fetchKnownFollowers(
            relayURLs: [relayURL],
            profilePubkey: profilePubkey,
            candidatePubkeys: [knownFollowerPubkey],
            limit: 1
        )
        XCTAssertEqual(fetched, [knownFollowerPubkey])
        let fetchCount = await relayClient.fetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    @MainActor
    func testFollowStorePreservesSuccessfulPublishAcrossLogout() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFollowStoreLogout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let defaultsSuite = "FlowFollowStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let fileManager = TestFileManager(rootURL: rootURL)
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        let relayClient = FollowPublishRelayClient(publishDelayNanoseconds: 150_000_000)
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: ProfileRelayHintCache(),
            followListCache: followListCache,
            eventRepository: EventRepository(fileManager: fileManager)
        )
        let followStore = FollowStore(
            defaults: defaults,
            authStore: AuthStore(defaults: defaults),
            feedService: service,
            relayClient: relayClient
        )

        let accountKeypair = try XCTUnwrap(Keypair())
        let targetKeypair = try XCTUnwrap(Keypair())
        let accountPubkey = accountKeypair.publicKey.hex.lowercased()
        let targetPubkey = targetKeypair.publicKey.hex.lowercased()

        followStore.configure(
            accountPubkey: accountPubkey,
            nsec: accountKeypair.privateKey.nsec,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL]
        )
        followStore.follow(targetPubkey)

        followStore.configure(
            accountPubkey: nil,
            nsec: nil,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL]
        )

        try await Task.sleep(nanoseconds: 400_000_000)

        let cachedSnapshot = await service.cachedFollowListSnapshot(pubkey: accountPubkey)
        let publishCount = await relayClient.publishCount()
        XCTAssertEqual(cachedSnapshot?.followedPubkeys, [targetPubkey])
        XCTAssertEqual(defaults.stringArray(forKey: "flow.followedPubkeys.\(accountPubkey)"), [targetPubkey])
        XCTAssertEqual(publishCount, 1)
    }

    @MainActor
    func testFollowStorePublishPreservesExistingLocalFollowGraphWhenRelaySnapshotIsTruncated() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFollowStoreGraphPreservation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let defaultsSuite = "FlowFollowStoreGraphPreservation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let fileManager = TestFileManager(rootURL: rootURL)
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        let accountKeypair = try XCTUnwrap(Keypair())
        let existingKeypairA = try XCTUnwrap(Keypair())
        let existingKeypairB = try XCTUnwrap(Keypair())
        let newKeypair = try XCTUnwrap(Keypair())
        let accountPubkey = accountKeypair.publicKey.hex.lowercased()
        let existingPubkeyA = existingKeypairA.publicKey.hex.lowercased()
        let existingPubkeyB = existingKeypairB.publicKey.hex.lowercased()
        let newPubkey = newKeypair.publicKey.hex.lowercased()
        let truncatedRelayEvent = makeEvent(
            id: hex("d"),
            pubkey: accountPubkey,
            kind: 3,
            tags: [["p", existingPubkeyA]],
            content: "",
            createdAt: 1_700_000_500
        )
        let relayClient = FollowGraphRecordingRelayClient(
            eventsByRelay: [relayURL: [truncatedRelayEvent]],
            fetchDelayNanoseconds: 150_000_000,
            fetchDelaysNanoseconds: [300_000_000, 50_000_000]
        )
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: ProfileRelayHintCache(),
            followListCache: followListCache,
            eventRepository: EventRepository(fileManager: fileManager)
        )
        defaults.set(
            [existingPubkeyA, existingPubkeyB],
            forKey: "flow.followedPubkeys.\(accountPubkey)"
        )
        let followStore = FollowStore(
            defaults: defaults,
            authStore: AuthStore(defaults: defaults),
            feedService: service,
            relayClient: relayClient
        )

        followStore.configure(
            accountPubkey: accountPubkey,
            nsec: accountKeypair.privateKey.nsec,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL]
        )
        followStore.follow(newPubkey)

        let deadline = Date().addingTimeInterval(2)
        var publishedFollowings: [String] = []
        while Date() < deadline {
            publishedFollowings = await relayClient.lastPublishedFollowings()
            if followStore.isFollowing(existingPubkeyA),
               followStore.isFollowing(existingPubkeyB),
               followStore.isFollowing(newPubkey),
               Set(publishedFollowings) == Set([existingPubkeyA, existingPubkeyB, newPubkey]) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(followStore.isFollowing(existingPubkeyA))
        XCTAssertTrue(followStore.isFollowing(existingPubkeyB))
        XCTAssertTrue(followStore.isFollowing(newPubkey))
        XCTAssertEqual(
            Set(publishedFollowings),
            Set([existingPubkeyA, existingPubkeyB, newPubkey])
        )
    }

    @MainActor
    func testFollowStoreSyncDoesNotReplaceRicherLocalFollowCacheWithTruncatedRelaySnapshot() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFollowStoreSyncPreservation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let defaultsSuite = "FlowFollowStoreSyncPreservation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let fileManager = TestFileManager(rootURL: rootURL)
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        let accountKeypair = try XCTUnwrap(Keypair())
        let followedKeypairA = try XCTUnwrap(Keypair())
        let followedKeypairB = try XCTUnwrap(Keypair())
        let accountPubkey = accountKeypair.publicKey.hex.lowercased()
        let followedPubkeyA = followedKeypairA.publicKey.hex.lowercased()
        let followedPubkeyB = followedKeypairB.publicKey.hex.lowercased()
        let truncatedRelayEvent = makeEvent(
            id: hex("e"),
            pubkey: accountPubkey,
            kind: 3,
            tags: [["p", followedPubkeyA]],
            content: "",
            createdAt: 1_700_000_500
        )
        let relayClient = FollowGraphRecordingRelayClient(
            eventsByRelay: [relayURL: [truncatedRelayEvent]],
            fetchDelayNanoseconds: 0
        )
        let service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: ProfileCache(snapshotStore: ProfileSnapshotStore(fileManager: fileManager)),
            relayHintCache: ProfileRelayHintCache(),
            followListCache: followListCache,
            eventRepository: EventRepository(fileManager: fileManager)
        )
        defaults.set(
            [followedPubkeyA, followedPubkeyB],
            forKey: "flow.followedPubkeys.\(accountPubkey)"
        )
        await service.storeFollowListSnapshotLocally(
            FollowListSnapshot(
                content: "",
                tags: [["p", followedPubkeyA], ["p", followedPubkeyB]]
            ),
            for: accountPubkey
        )

        let followStore = FollowStore(
            defaults: defaults,
            authStore: AuthStore(defaults: defaults),
            feedService: service,
            relayClient: relayClient
        )

        followStore.configure(
            accountPubkey: accountPubkey,
            nsec: accountKeypair.privateKey.nsec,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL]
        )

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await relayClient.fetchCount() > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(followStore.isFollowing(followedPubkeyA))
        XCTAssertTrue(followStore.isFollowing(followedPubkeyB))
    }

    func testReactionStatsPrefetchSkipsFreshNetworkRefetch() async throws {
        var rootURLBox: URL? = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowReactionStatsTests-\(UUID().uuidString)", isDirectory: true)
        let rootURL = try XCTUnwrap(rootURLBox)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            rootURLBox = nil
            try? FileManager.default.removeItem(at: rootURL)
        }

        let relayClient = SpyRelayClient()
        let fileManager = TestFileManager(rootURL: rootURL)
        let store = NoteReactionStatsStore(fileManager: fileManager)
        let service = await MainActor.run {
            NoteReactionStatsService(relayClient: relayClient, store: store)
        }
        let note = makeEvent(
            id: hex("e"),
            pubkey: hex("f"),
            kind: 1,
            tags: [],
            content: "Hello"
        )

        await MainActor.run {
            service.prefetch(events: [note], relayURLs: [relayURL])
        }
        try await Task.sleep(nanoseconds: 350_000_000)

        await MainActor.run {
            service.prefetch(events: [note], relayURLs: [relayURL])
        }
        try await Task.sleep(nanoseconds: 350_000_000)

        let fetchCount = await relayClient.fetchCount()
        XCTAssertEqual(fetchCount, 1)
    }

    func testFetchThreadRepliesCanSkipNestedRepliesOnFastPath() async throws {
        var rootURLBox: URL? = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowThreadReplyTests-\(UUID().uuidString)", isDirectory: true)
        let rootURL = try XCTUnwrap(rootURLBox)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            rootURLBox = nil
            try? FileManager.default.removeItem(at: rootURL)
        }

        let rootEventID = hex("1")
        let directReply = makeEvent(
            id: hex("2"),
            pubkey: hex("3"),
            kind: 1,
            tags: [["e", rootEventID, "", "reply"]],
            content: "Direct reply",
            createdAt: 1_700_000_001
        )
        let nestedReply = makeEvent(
            id: hex("4"),
            pubkey: hex("5"),
            kind: 1,
            tags: [
                ["e", rootEventID, "", "root"],
                ["e", directReply.id, "", "reply"]
            ],
            content: "Nested reply",
            createdAt: 1_700_000_002
        )
        let quoteMention = makeEvent(
            id: hex("6"),
            pubkey: hex("7"),
            kind: 1,
            tags: [
                ["e", rootEventID, "", "mention", hex("8")],
                ["q", rootEventID],
                ["p", hex("8")]
            ],
            content: "Quote, not a reply",
            createdAt: 1_700_000_003
        )

        let relayClient = ThreadReplyRelayClient(
            rootEventID: rootEventID,
            directReply: directReply,
            nestedReply: nestedReply,
            quoteMention: quoteMention
        )
        let fileManager = TestFileManager(rootURL: rootURL)
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let fastReplies = try await service.fetchThreadReplies(
            relayURLs: [relayURL],
            rootEventID: rootEventID,
            includeNestedReplies: false,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.01,
            relayFetchMode: .firstNonEmptyRelay
        )
        let fullReplies = try await service.fetchThreadReplies(
            relayURLs: [relayURL],
            rootEventID: rootEventID,
            includeNestedReplies: true,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.01,
            relayFetchMode: .firstNonEmptyRelay
        )

        let fetchCount = await relayClient.fetchCount()

        XCTAssertEqual(fastReplies.map(\.id), [directReply.id])
        XCTAssertEqual(fullReplies.map(\.id), [directReply.id, nestedReply.id])
        XCTAssertEqual(fetchCount, 2)
    }

    func testFeedItemMergePreservesRepostDisplayContextAcrossActorOnlyHydration() {
        let originalAuthorPubkey = hex("1")
        let repostActorPubkey = hex("2")
        let originalEvent = makeEvent(
            id: hex("a"),
            pubkey: originalAuthorPubkey,
            kind: 1,
            tags: [],
            content: "Alice note"
        )
        let repostEvent = makeEvent(
            id: hex("b"),
            pubkey: repostActorPubkey,
            kind: 6,
            tags: [["e", originalEvent.id]],
            content: originalEventJSON(for: originalEvent)
        )

        let cachedItem = FeedItem(
            event: repostEvent,
            profile: makeProfile(name: "bob", displayName: "Bob"),
            displayEventOverride: originalEvent,
            displayProfileOverride: makeProfile(name: "alice", displayName: "Alice")
        )
        let actorOnlyHydratedItem = FeedItem(
            event: repostEvent,
            profile: makeProfile(name: "bob", displayName: "Bob")
        )

        let merged = cachedItem.merged(with: actorOnlyHydratedItem)

        XCTAssertEqual(merged.actorDisplayName, "Bob")
        XCTAssertEqual(merged.displayEvent.id, originalEvent.id)
        XCTAssertEqual(merged.displayName, "Alice")
    }

    func testBuildNoteActivityRowsIncludesReactionsResharesAndQuotesForTargetNoteOnly() async throws {
        var harnessBox: TestHarness? = try TestHarness()
        let rootURL = try XCTUnwrap(harnessBox?.rootURL)
        defer {
            harnessBox = nil
            try? FileManager.default.removeItem(at: rootURL)
        }
        let harness = try XCTUnwrap(harnessBox)

        let rootEventID = hex("9")
        let rootAuthorPubkey = hex("8")
        let reactionActorPubkey = hex("1")
        let repostActorPubkey = hex("2")
        let quoteActorPubkey = hex("3")

        let rootEvent = makeEvent(
            id: rootEventID,
            pubkey: rootAuthorPubkey,
            kind: 1,
            tags: [],
            content: "Root note"
        )
        let reactionEvent = makeEvent(
            id: hex("a"),
            pubkey: reactionActorPubkey,
            kind: 7,
            tags: [["e", rootEventID, "", "reply"]],
            content: "+"
        )
        let repostEvent = makeEvent(
            id: hex("b"),
            pubkey: repostActorPubkey,
            kind: 6,
            tags: [["e", rootEventID, "", "mention"]],
            content: ""
        )
        let quoteEvent = makeEvent(
            id: hex("c"),
            pubkey: quoteActorPubkey,
            kind: 1,
            tags: [["q", rootEventID]],
            content: "Quoting this"
        )
        let unrelatedReply = makeEvent(
            id: hex("d"),
            pubkey: hex("4"),
            kind: 1,
            tags: [["e", rootEventID, "", "reply"]],
            content: "A reply should stay out of reactions"
        )

        await harness.eventRepository.store(events: [rootEvent])

        let rows = await harness.service.buildNoteActivityRows(
            relayURLs: [relayURL],
            rootEventID: rootEventID,
            events: [reactionEvent, repostEvent, quoteEvent, unrelatedReply],
            fetchTimeout: 0.01,
            relayFetchMode: .firstNonEmptyRelay,
            profileFetchTimeout: 0.01,
            profileRelayFetchMode: .firstNonEmptyRelay
        )

        XCTAssertEqual(rows.map(\.id), [quoteEvent.id, repostEvent.id, reactionEvent.id])
        XCTAssertEqual(rows.map(\.action.title), ["Quote share", "Reshare", "Reaction"])
        XCTAssertTrue(rows.allSatisfy { $0.target.event?.id.lowercased() == rootEventID })
    }

    func testBuildActivityRowsUsesCachedActorAndTargetProfilesWithoutRelayFetch() async throws {
        var harnessBox: TestHarness? = try TestHarness()
        let rootURL = try XCTUnwrap(harnessBox?.rootURL)
        defer {
            harnessBox = nil
            try? FileManager.default.removeItem(at: rootURL)
        }
        let harness = try XCTUnwrap(harnessBox)

        let currentUserPubkey = hex("1")
        let actorPubkey = hex("2")
        let targetPubkey = hex("3")
        let targetEventID = hex("a")

        let actorProfile = makeProfile(name: "alice", displayName: "Alice")
        let targetProfile = makeProfile(name: "bob", displayName: "Bob")

        let targetEvent = makeEvent(
            id: targetEventID,
            pubkey: targetPubkey,
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Target note"
        )
        let reactionEvent = makeEvent(
            id: hex("b"),
            pubkey: actorPubkey,
            kind: 7,
            tags: [
                ["p", currentUserPubkey],
                ["e", targetEventID, "", "reply"]
            ],
            content: "+"
        )

        await harness.profileCache.store(
            profiles: [
                actorPubkey: actorProfile,
                targetPubkey: targetProfile
            ],
            missed: []
        )
        await harness.eventRepository.store(events: [targetEvent])

        let rows = await harness.service.buildActivityRows(
            relayURLs: [relayURL],
            currentUserPubkey: currentUserPubkey,
            events: [reactionEvent],
            fetchTimeout: 0.01,
            relayFetchMode: RelayFetchMode.firstNonEmptyRelay,
            profileFetchTimeout: 0.01,
            profileRelayFetchMode: RelayFetchMode.firstNonEmptyRelay
        )

        let fetchCount = await harness.relayClient.fetchCount()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.actor.displayName, "Alice")
        XCTAssertEqual(rows.first?.target.profile?.displayName, "Bob")
        XCTAssertEqual(fetchCount, 0)
    }

    func testBuildActivityRowsDoesNotFetchMissingTargetProfilesOnHotPath() async throws {
        var harnessBox: TestHarness? = try TestHarness()
        let rootURL = try XCTUnwrap(harnessBox?.rootURL)
        defer {
            harnessBox = nil
            try? FileManager.default.removeItem(at: rootURL)
        }
        let harness = try XCTUnwrap(harnessBox)

        let currentUserPubkey = hex("4")
        let actorPubkey = hex("5")
        let targetPubkey = hex("6")
        let targetEventID = hex("c")

        let actorProfile = makeProfile(name: "charlie", displayName: "Charlie")
        let targetEvent = makeEvent(
            id: targetEventID,
            pubkey: targetPubkey,
            kind: 1,
            tags: [["p", currentUserPubkey]],
            content: "Another target"
        )
        let reactionEvent = makeEvent(
            id: hex("d"),
            pubkey: actorPubkey,
            kind: 7,
            tags: [
                ["p", currentUserPubkey],
                ["e", targetEventID, "", "reply"]
            ],
            content: "+"
        )

        await harness.profileCache.store(
            profiles: [
                actorPubkey: actorProfile
            ],
            missed: []
        )
        await harness.eventRepository.store(events: [targetEvent])

        let rows = await harness.service.buildActivityRows(
            relayURLs: [relayURL],
            currentUserPubkey: currentUserPubkey,
            events: [reactionEvent],
            fetchTimeout: 0.01,
            relayFetchMode: RelayFetchMode.firstNonEmptyRelay,
            profileFetchTimeout: 0.01,
            profileRelayFetchMode: RelayFetchMode.firstNonEmptyRelay
        )

        let fetchCount = await harness.relayClient.fetchCount()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.actor.displayName, "Charlie")
        XCTAssertNil(rows.first?.target.profile)
        XCTAssertEqual(fetchCount, 0)
    }

    func testFetchAuthorFeedRelayOnlyReturnsRelayResults() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowAuthorFeedDittoRelayOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let authorPubkey = hex("a")
        let relayEvent = makeEvent(
            id: hex("c"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "relay event",
            createdAt: 1_700_000_600
        )

        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [relayEvent]
        ])
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let items = try await service.fetchAuthorFeed(
            relayURLs: [relayURL],
            authorPubkey: authorPubkey,
            kinds: [1],
            limit: 1,
            until: nil,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 0.01,
            relayFetchMode: .allRelays,
            relayOnly: true
        )

        let fetchCount = await relayClient.fetchCount()

        XCTAssertEqual(items.map(\.id), [relayEvent.id])
        XCTAssertEqual(fetchCount, 1)
    }

    func testFetchFollowingsRelayOnlyIgnoresCachedFollowListSnapshot() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFollowingsDittoRelayOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [
                makeEvent(
                    id: hex("3"),
                    pubkey: hex("1"),
                    kind: 3,
                    tags: [["p", hex("b")]],
                    content: "",
                    createdAt: 1_700_000_620
                )
            ]
        ])
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        await service.storeFollowListSnapshotLocally(
            FollowListSnapshot(content: "", tags: [["p", hex("a")]], createdAt: 1_700_000_100),
            for: hex("1")
        )

        let followings = try await service.fetchFollowings(
            relayURLs: [relayURL],
            pubkey: hex("1"),
            relayFetchMode: .allRelays,
            relayOnly: true,
            fallbackToCachedSnapshot: false
        )

        let fetchCount = await relayClient.fetchCount()

        XCTAssertEqual(followings, [hex("b")])
        XCTAssertEqual(fetchCount, 1)
    }

    func testFetchThreadRepliesUseConfiguredReadRelaysOnlyForReplyTargets() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowThreadReplyTargetOutbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let rootAuthorPubkey = hex("1")
        let replyAuthorPubkey = hex("2")
        let authorReadRelayURL = URL(string: "wss://thread-root-read.example")!
        let rootEvent = makeEvent(
            id: hex("3"),
            pubkey: rootAuthorPubkey,
            kind: 1,
            tags: [],
            content: "Root event",
            createdAt: 1_700_000_700
        )
        let relayListEvent = makeEvent(
            id: hex("4"),
            pubkey: rootAuthorPubkey,
            kind: 10_002,
            tags: [["r", authorReadRelayURL.absoluteString, "read"]],
            content: "",
            createdAt: 1_700_000_701
        )
        let replyEvent = makeEvent(
            id: hex("5"),
            pubkey: replyAuthorPubkey,
            kind: 1,
            tags: [
                ["e", rootEvent.id, "", "reply"],
                ["p", rootAuthorPubkey]
            ],
            content: "Reply event",
            createdAt: 1_700_000_702
        )
        let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
            relayURL: [relayListEvent, replyEvent],
            authorReadRelayURL: [rootEvent]
        ])
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let items = try await service.fetchThreadReplies(
            relayURLs: [relayURL],
            rootEventID: rootEvent.id,
            limit: 20,
            includeNestedReplies: false,
            hydrationMode: .full
        )

        XCTAssertEqual(items.map(\.id), [replyEvent.id])
        XCTAssertNil(items.first?.replyTargetEvent)
    }

    func testFetchThreadNoteActivityRowsUseConfiguredReadRelaysOnlyForTargets() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowThreadActivityTargetOutbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let rootAuthorPubkey = hex("6")
        let reactorPubkey = hex("7")
        let authorReadRelayURL = URL(string: "wss://thread-activity-read.example")!
        let rootEvent = makeEvent(
            id: hex("8"),
            pubkey: rootAuthorPubkey,
            kind: 1,
            tags: [],
            content: "Root note",
            createdAt: 1_700_000_720
        )
        let relayListEvent = makeEvent(
            id: hex("9"),
            pubkey: rootAuthorPubkey,
            kind: 10_002,
            tags: [["r", authorReadRelayURL.absoluteString, "read"]],
            content: "",
            createdAt: 1_700_000_721
        )
        let reactionEvent = makeEvent(
            id: hex("a"),
            pubkey: reactorPubkey,
            kind: 7,
            tags: [["e", rootEvent.id], ["p", rootAuthorPubkey]],
            content: "+",
            createdAt: 1_700_000_722
        )
        let service = makeFeedService(
            relayClient: RecordingOutboxRelayClient(eventsByRelay: [
                relayURL: [relayListEvent, reactionEvent],
                authorReadRelayURL: [rootEvent]
            ]),
            fileManager: fileManager
        )

        let rows = try await service.fetchThreadNoteActivityRows(
            relayURLs: [relayURL],
            rootEventID: rootEvent.id,
            rootAuthorPubkey: rootAuthorPubkey,
            limit: 20
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.target.event)
    }

    func testOutboxDiagnosticsTrackDirectoryHitsAndGenericFallbacks() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowOutboxDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let authorPubkey = hex("b")
        let writeOnlyRelayURL = URL(string: "wss://author-write-only.example")!
        let writeOnlyRelayList = makeEvent(
            id: hex("c"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [["r", writeOnlyRelayURL.absoluteString, "write"]],
            content: "",
            createdAt: 1_700_000_740
        )
        let service = makeFeedService(
            relayClient: RecordingOutboxRelayClient(eventsByRelay: [
                relayURL: [writeOnlyRelayList]
            ]),
            fileManager: fileManager
        )

        _ = try await service.fetchOutboxBackedAuthorFeed(
            baseReadRelayURLs: [relayURL],
            authorPubkey: authorPubkey,
            kinds: [1],
            limit: 20,
            until: nil,
            hydrationMode: .cachedProfilesOnly
        )

        let diagnostics = await service.outboxDiagnostics()
        XCTAssertGreaterThanOrEqual(diagnostics.directoryHitCount, 1)
        XCTAssertGreaterThanOrEqual(diagnostics.writeRelayFallbackCount, 1)
        XCTAssertGreaterThanOrEqual(diagnostics.genericReadRelayFallbackCount, 1)
    }

    func testFirstNonEmptyRelayModeReturnsBeforeSlowEmptyRelays() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowFirstNonEmptyRelay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let authorPubkey = hex("a")
        let event = makeEvent(
            id: hex("1"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "fast relay event"
        )
        let relayClient = DelayedRelayClient(
            eventsByRelay: [
                relayURL: [event],
                relayURL2: []
            ],
            delaysByRelay: [
                relayURL: 40_000_000,
                relayURL2: 700_000_000
            ]
        )
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let startedAt = Date()
        let items = try await service.fetchAuthorFeed(
            relayURLs: [relayURL, relayURL2],
            authorPubkey: authorPubkey,
            kinds: [1],
            limit: 1,
            until: nil,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 1,
            relayFetchMode: .firstRelayWithEvents
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(items.map(\.id), [event.id])
        XCTAssertLessThan(elapsed, 0.35)
    }

    func testFeedPresentationCacheEvictsLeastRecentItemsWhenCapacityIsExceeded() async {
        let cache = FeedPresentationCache(capacity: 2)
        let first = FeedItem(event: makeEvent(id: hex("1"), pubkey: hex("a"), kind: 1, tags: [], content: "first"), profile: nil)
        let second = FeedItem(event: makeEvent(id: hex("2"), pubkey: hex("b"), kind: 1, tags: [], content: "second"), profile: nil)
        let third = FeedItem(event: makeEvent(id: hex("3"), pubkey: hex("c"), kind: 1, tags: [], content: "third"), profile: nil)

        await cache.store([first, second])
        await cache.store([third])

        let cached = await cache.cachedItems(for: [first.id, second.id, third.id])

        XCTAssertNil(cached[first.id])
        XCTAssertEqual(cached[second.id]?.id, second.id)
        XCTAssertEqual(cached[third.id]?.id, third.id)
    }

    func testBuildFeedItemsReusesPresentationCacheForRepeatedFullHydration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowPresentationCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let authorPubkey = hex("d")
        let note = makeEvent(
            id: hex("e"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "cached hydration"
        )
        let profile = makeEvent(
            id: hex("f"),
            pubkey: authorPubkey,
            kind: 0,
            tags: [],
            content: #"{"name":"alice","display_name":"Alice"}"#,
            createdAt: note.createdAt + 1
        )
        let relayClient = ProfileMetadataRelayClient(eventsByRelay: [
            relayURL: [note, profile]
        ])
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager
        )

        let firstItems = await service.buildFeedItems(
            relayURLs: [relayURL],
            events: [note],
            hydrationMode: .full
        )
        let firstFetchCount = await relayClient.fetchCount()

        let secondItems = await service.buildFeedItems(
            relayURLs: [relayURL],
            events: [note],
            hydrationMode: .full
        )
        let secondFetchCount = await relayClient.fetchCount()

        XCTAssertEqual(firstItems.first?.profile?.displayName, "Alice")
        XCTAssertEqual(secondItems.first?.profile?.displayName, "Alice")
        XCTAssertGreaterThan(firstFetchCount, 0)
        XCTAssertEqual(secondFetchCount, firstFetchCount)
    }

    func testBuildFeedItemsRefreshesCachedProfilesFromProfileCache() async throws {
        let harness = try TestHarness()
        let authorPubkey = hex("a")
        let note = makeEvent(
            id: hex("1"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [],
            content: "cached profile refresh"
        )

        await harness.profileCache.store(
            profiles: [authorPubkey: makeProfile(name: "alice", displayName: "Alice")],
            missed: []
        )

        let firstItems = await harness.service.buildFeedItems(
            relayURLs: [],
            events: [note],
            hydrationMode: .full
        )

        await harness.profileCache.store(
            profiles: [authorPubkey: makeProfile(name: "bob", displayName: "Bob")],
            missed: []
        )

        let secondItems = await harness.service.buildFeedItems(
            relayURLs: [],
            events: [note],
            hydrationMode: .full
        )

        XCTAssertEqual(firstItems.first?.profile?.displayName, "Alice")
        XCTAssertEqual(secondItems.first?.profile?.displayName, "Bob")
    }

    func testBuildFeedItemsRetriesFullHydrationWhenCachedReplyContextIsMissing() async throws {
        let harness = try TestHarness()
        let authorPubkey = hex("2")
        let parentPubkey = hex("3")
        let parentEvent = makeEvent(
            id: hex("4"),
            pubkey: parentPubkey,
            kind: 1,
            tags: [],
            content: "parent event"
        )
        let replyEvent = makeEvent(
            id: hex("5"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [
                ["e", parentEvent.id, "", "root"],
                ["e", parentEvent.id, "", "reply"]
            ],
            content: "reply event"
        )

        let firstItems = await harness.service.buildFeedItems(
            relayURLs: [],
            events: [replyEvent],
            hydrationMode: .full
        )

        await harness.eventRepository.store(events: [parentEvent])
        let secondItems = await harness.service.buildFeedItems(
            relayURLs: [],
            events: [replyEvent],
            hydrationMode: .full
        )

        XCTAssertNil(firstItems.first?.replyTargetEvent)
        XCTAssertEqual(secondItems.first?.replyTargetEvent?.id, parentEvent.id)
    }

    func testBuildFeedItemsRetriesFullHydrationWhenCachedActorProfileIsMissing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowCachedActorProfileRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let note = makeEvent(
            id: hex("6"),
            pubkey: hex("7"),
            kind: 1,
            tags: [],
            content: "cached actor profile retry"
        )
        let profile = makeEvent(
            id: hex("8"),
            pubkey: note.pubkey,
            kind: 0,
            tags: [],
            content: #"{"name":"bob","display_name":"Bob"}"#,
            createdAt: note.createdAt + 1
        )
        let relayClient = MutableProfileMetadataRelayClient(eventsByRelay: [relayURL: []])
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            presentationCache: FeedPresentationCache()
        )

        let firstItems = await service.buildFeedItems(
            relayURLs: [relayURL],
            events: [note],
            hydrationMode: .full
        )

        await relayClient.setEvents([profile], for: relayURL)

        let secondItems = await service.buildFeedItems(
            relayURLs: [relayURL],
            events: [note],
            hydrationMode: .full
        )

        XCTAssertNil(firstItems.first?.profile)
        XCTAssertEqual(secondItems.first?.profile?.displayName, "Bob")
    }

    func testBuildFeedItemsRetriesFullHydrationWhenCachedReplyProfileIsMissing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowCachedReplyProfileRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = TestFileManager(rootURL: rootURL)
        let eventRepository = EventRepository(fileManager: fileManager)
        let parentEvent = makeEvent(
            id: hex("9"),
            pubkey: hex("a"),
            kind: 1,
            tags: [],
            content: "parent event"
        )
        let replyEvent = makeEvent(
            id: hex("b"),
            pubkey: hex("c"),
            kind: 1,
            tags: [
                ["e", parentEvent.id, "", "root"],
                ["e", parentEvent.id, "", "reply"]
            ],
            content: "reply event"
        )
        let parentProfile = makeEvent(
            id: hex("d"),
            pubkey: parentEvent.pubkey,
            kind: 0,
            tags: [],
            content: #"{"name":"alice","display_name":"Alice"}"#,
            createdAt: parentEvent.createdAt + 1
        )
        let relayClient = MutableProfileMetadataRelayClient(eventsByRelay: [relayURL: []])
        let service = makeFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            eventRepository: eventRepository,
            presentationCache: FeedPresentationCache()
        )

        await eventRepository.store(events: [parentEvent])

        let firstItems = await service.buildFeedItems(
            relayURLs: [relayURL],
            events: [replyEvent],
            hydrationMode: .full
        )

        await relayClient.setEvents([parentProfile], for: relayURL)

        let secondItems = await service.buildFeedItems(
            relayURLs: [relayURL],
            events: [replyEvent],
            hydrationMode: .full
        )

        XCTAssertEqual(firstItems.first?.replyTargetEvent?.id, parentEvent.id)
        XCTAssertNil(firstItems.first?.replyTargetProfile)
        XCTAssertEqual(secondItems.first?.replyTargetProfile?.displayName, "Alice")
    }

    func testReplyContextPreviewPresentationUsesParentSnippetForReplies() {
        let rootEvent = makeEvent(
            id: hex("1"),
            pubkey: hex("a"),
            kind: 1,
            tags: [],
            content: "Alice started the thread with some extra context."
        )
        let replyEvent = makeEvent(
            id: hex("2"),
            pubkey: hex("b"),
            kind: 1,
            tags: [
                ["e", rootEvent.id, "", "root"],
                ["e", rootEvent.id, "", "reply"]
            ],
            content: "Bob replied with the important middle comment."
        )
        let item = FeedItem(
            event: replyEvent,
            profile: makeProfile(name: "bob", displayName: "Bob"),
            replyTargetEvent: rootEvent,
            replyTargetProfile: makeProfile(name: "alice", displayName: "Alice")
        )

        let presentation = ReplyContextPreviewPresentation.make(for: item)

        XCTAssertNotNil(presentation)
        XCTAssertEqual(presentation?.parentItem.displayName, "Alice")
        XCTAssertEqual(presentation?.snippet, "Alice started the thread with some extra context.")
        XCTAssertEqual(presentation?.hasImageBadge, false)
    }

    func testReplyContextPreviewPresentationKeepsMediaOnlyParentsVisible() {
        let mediaURL = "https://example.com/alice.jpg"
        let rootEvent = makeEvent(
            id: hex("3"),
            pubkey: hex("c"),
            kind: 1,
            tags: [],
            content: mediaURL
        )
        let replyEvent = makeEvent(
            id: hex("4"),
            pubkey: hex("d"),
            kind: 1,
            tags: [
                ["e", rootEvent.id, "", "root"],
                ["e", rootEvent.id, "", "reply"]
            ],
            content: "Dan replied to the media post."
        )
        let item = FeedItem(
            event: replyEvent,
            profile: makeProfile(name: "dan", displayName: "Dan"),
            replyTargetEvent: rootEvent,
            replyTargetProfile: makeProfile(name: "alice", displayName: "Alice")
        )

        let presentation = ReplyContextPreviewPresentation.make(for: item)

        XCTAssertNotNil(presentation)
        XCTAssertNil(presentation?.snippet)
        XCTAssertEqual(presentation?.hasImageBadge, true)
    }
}

private let relayURL = URL(string: "wss://relay.example.com")!
private let relayURL2 = URL(string: "wss://relay-two.example.com")!

private actor SpyRelayClient: NostrRelayEventFetching {
    private var fetchCallCount = 0

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        fetchCallCount += 1
        return []
    }

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private actor DelayedRelayClient: NostrRelayEventFetching {
    private let eventsByRelay: [URL: [Flow.NostrEvent]]
    private let delaysByRelay: [URL: UInt64]
    private var fetchCallCount = 0

    init(eventsByRelay: [URL: [Flow.NostrEvent]], delaysByRelay: [URL: UInt64]) {
        self.eventsByRelay = eventsByRelay
        self.delaysByRelay = delaysByRelay
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        fetchCallCount += 1
        if let delay = delaysByRelay[relayURL] {
            try await Task.sleep(nanoseconds: delay)
        }

        let authors = Set(filter.authors ?? [])
        let kinds = Set(filter.kinds ?? [])
        return (eventsByRelay[relayURL] ?? []).filter { event in
            (authors.isEmpty || authors.contains(event.pubkey)) &&
                (kinds.isEmpty || kinds.contains(event.kind))
        }
    }

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private actor SequencedRelayClient: NostrRelayEventFetching {
    private var responses: [[Flow.NostrEvent]]
    private var fetchCallCount = 0

    init(responses: [[Flow.NostrEvent]]) {
        self.responses = responses
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        let _ = relayURL
        let _ = timeout
        fetchCallCount += 1
        let response = responses.isEmpty ? [] : responses.removeFirst()
        let kinds = Set(filter.kinds ?? [])
        let limit = filter.limit ?? Int.max

        return Array(
            response
                .filter { event in
                    kinds.isEmpty || kinds.contains(event.kind)
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

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private final class AuthorBatchDelayRelayClient: NostrRelayEventFetching, @unchecked Sendable {
    private let events: [Flow.NostrEvent]
    private let delayedAuthors: Set<String>
    private let delayNanoseconds: UInt64

    init(events: [Flow.NostrEvent], delayedAuthors: [String], delayNanoseconds: UInt64) {
        self.events = events
        self.delayedAuthors = Set(delayedAuthors)
        self.delayNanoseconds = delayNanoseconds
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        let authors = Set(filter.authors ?? [])
        let kinds = Set(filter.kinds ?? [])

        if !authors.isDisjoint(with: delayedAuthors) {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        return events.filter { event in
            (authors.isEmpty || authors.contains(event.pubkey)) &&
                (kinds.isEmpty || kinds.contains(event.kind))
        }
    }
}

private actor FollowPublishRelayClient: NostrRelayEventFetching, NostrRelayEventPublishing {
    private let publishDelayNanoseconds: UInt64
    private var publishCallCount = 0

    init(publishDelayNanoseconds: UInt64) {
        self.publishDelayNanoseconds = publishDelayNanoseconds
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        []
    }

    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async throws {
        publishCallCount += 1
        try await Task.sleep(nanoseconds: publishDelayNanoseconds)
    }

    func publishCount() -> Int {
        publishCallCount
    }
}

private actor FollowGraphRecordingRelayClient: NostrRelayEventFetching, NostrRelayEventPublishing {
    private let eventsByRelay: [URL: [Flow.NostrEvent]]
    private let fetchDelayNanoseconds: UInt64
    private let fetchDelaysNanoseconds: [UInt64]
    private var lastPublishedEventData: Data?
    private var fetchCallCount = 0

    init(
        eventsByRelay: [URL: [Flow.NostrEvent]],
        fetchDelayNanoseconds: UInt64,
        fetchDelaysNanoseconds: [UInt64] = []
    ) {
        self.eventsByRelay = eventsByRelay
        self.fetchDelayNanoseconds = fetchDelayNanoseconds
        self.fetchDelaysNanoseconds = fetchDelaysNanoseconds
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        let delay = fetchCallCount < fetchDelaysNanoseconds.count
            ? fetchDelaysNanoseconds[fetchCallCount]
            : fetchDelayNanoseconds
        fetchCallCount += 1

        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }

        let authors = Set(filter.authors ?? [])
        let kinds = Set(filter.kinds ?? [])
        return (eventsByRelay[relayURL] ?? []).filter { event in
            (authors.isEmpty || authors.contains(event.pubkey)) &&
                (kinds.isEmpty || kinds.contains(event.kind))
        }
    }

    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async throws {
        lastPublishedEventData = eventData
    }

    func lastPublishedFollowings() -> [String] {
        guard let lastPublishedEventData,
              let eventObject = try? JSONSerialization.jsonObject(with: lastPublishedEventData) as? [String: Any],
              let tags = eventObject["tags"] as? [Any] else {
            return []
        }

        return tags.compactMap { tag in
            guard let values = tag as? [Any],
                  values.count > 1,
                  let name = values[0] as? String,
                  name.lowercased() == "p",
                  let pubkey = values[1] as? String else {
                return nil
            }
            return pubkey.lowercased()
        }
    }

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private actor ProfileMetadataRelayClient: NostrRelayEventFetching {
    private let eventsByRelay: [URL: [Flow.NostrEvent]]
    private var fetchCallCount = 0

    init(eventsByRelay: [URL: [Flow.NostrEvent]]) {
        self.eventsByRelay = eventsByRelay
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        fetchCallCount += 1

        let authors = Set(filter.authors ?? [])
        let kinds = Set(filter.kinds ?? [])
        let events = eventsByRelay[relayURL] ?? []
        return events.filter { event in
            (authors.isEmpty || authors.contains(event.pubkey)) &&
            (kinds.isEmpty || kinds.contains(event.kind))
        }
    }

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private actor MutableProfileMetadataRelayClient: NostrRelayEventFetching {
    private var eventsByRelay: [URL: [Flow.NostrEvent]]

    init(eventsByRelay: [URL: [Flow.NostrEvent]]) {
        self.eventsByRelay = eventsByRelay
    }

    func setEvents(_ events: [Flow.NostrEvent], for relayURL: URL) {
        eventsByRelay[relayURL] = events
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        let authors = Set(filter.authors ?? [])
        let kinds = Set(filter.kinds ?? [])
        let events = eventsByRelay[relayURL] ?? []
        return events.filter { event in
            (authors.isEmpty || authors.contains(event.pubkey)) &&
            (kinds.isEmpty || kinds.contains(event.kind))
        }
    }
}

private actor RecordingOutboxRelayClient: NostrRelayEventFetching {
    private let eventsByRelay: [String: [Flow.NostrEvent]]
    private var requestedRelayURLLog: [URL] = []

    init(eventsByRelay: [URL: [Flow.NostrEvent]]) {
        var normalized: [String: [Flow.NostrEvent]] = [:]
        for (relayURL, events) in eventsByRelay {
            normalized[canonicalRelayString(relayURL)] = events
        }
        self.eventsByRelay = normalized
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        requestedRelayURLLog.append(relayURL)

        let authors = Set(filter.authors ?? [])
        let kinds = Set(filter.kinds ?? [])
        let ids = Set((filter.ids ?? []).map { $0.lowercased() })
        let dTags = Set(filter.tagFilters?["d"] ?? [])

        return (eventsByRelay[canonicalRelayString(relayURL)] ?? []).filter { event in
            if !authors.isEmpty && !authors.contains(event.pubkey.lowercased()) {
                return false
            }
            if !kinds.isEmpty && !kinds.contains(event.kind) {
                return false
            }
            if !ids.isEmpty && !ids.contains(event.id.lowercased()) {
                return false
            }
            if !dTags.isEmpty {
                return event.tags.contains { tag in
                    tag.count > 1 &&
                        tag.first?.lowercased() == "d" &&
                        dTags.contains(tag[1])
                }
            }
            return true
        }
    }

    func requestedRelayURLs() -> [URL] {
        requestedRelayURLLog
    }

    func fetchCount() -> Int {
        requestedRelayURLLog.count
    }
}

private func canonicalRelayStrings(_ relayURLs: [URL]) -> [String] {
    relayURLs.map(canonicalRelayString)
}

private func canonicalRelayString(_ relayURL: URL) -> String {
    let value = relayURL.absoluteString.lowercased()
    return value.hasSuffix("/") ? String(value.dropLast()) : value
}

private actor ThreadReplyRelayClient: NostrRelayEventFetching {
    private let rootEventID: String
    private let directReply: Flow.NostrEvent
    private let nestedReply: Flow.NostrEvent
    private let quoteMention: Flow.NostrEvent
    private var fetchCallCount = 0

    init(
        rootEventID: String,
        directReply: Flow.NostrEvent,
        nestedReply: Flow.NostrEvent,
        quoteMention: Flow.NostrEvent
    ) {
        self.rootEventID = rootEventID
        self.directReply = directReply
        self.nestedReply = nestedReply
        self.quoteMention = quoteMention
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        fetchCallCount += 1

        let referencedEventIDs = Set(filter.tagFilters?["e"] ?? [])
        if referencedEventIDs.contains(rootEventID) {
            return [directReply, quoteMention]
        }
        if referencedEventIDs.contains(directReply.id) {
            return [nestedReply]
        }

        return []
    }

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private actor FailingRelayClient: NostrRelayEventFetching {
    private var fetchCallCount = 0

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        fetchCallCount += 1
        throw RelayClientError.closed("test failure")
    }

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private final class TestHarness {
    let rootURL: URL
    let relayClient: SpyRelayClient
    let profileCache: ProfileCache
    let eventRepository: EventRepository
    let service: NostrFeedService

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileManager = TestFileManager(rootURL: rootURL)
        let profileSnapshotStore = ProfileSnapshotStore(fileManager: fileManager)
        let relayHintCache = ProfileRelayHintCache()
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)

        relayClient = SpyRelayClient()
        profileCache = ProfileCache(snapshotStore: profileSnapshotStore)
        eventRepository = EventRepository(fileManager: fileManager)
        service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: profileCache,
            relayHintCache: relayHintCache,
            followListCache: followListCache,
            eventRepository: eventRepository,
            presentationCache: FeedPresentationCache()
        )
    }
}

private func makeFeedService(
    relayClient: any NostrRelayEventFetching,
    fileManager: TestFileManager,
    eventRepository customEventRepository: EventRepository? = nil,
    presentationCache: FeedPresentationCache = .shared
) -> NostrFeedService {
    let profileSnapshotStore = ProfileSnapshotStore(fileManager: fileManager)
    let profileCache = ProfileCache(snapshotStore: profileSnapshotStore)
    let followListCache = FollowListSnapshotCache(fileManager: fileManager)
    let eventRepository = customEventRepository ?? EventRepository(fileManager: fileManager)

    return NostrFeedService(
        relayClient: relayClient,
        timelineCache: TimelineEventCache(),
        profileCache: profileCache,
        relayHintCache: ProfileRelayHintCache(),
        followListCache: followListCache,
        eventRepository: eventRepository,
        presentationCache: presentationCache
    )
}

private final class TestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        [rootURL]
    }
}

private func makeProfile(name: String, displayName: String) -> NostrProfile {
    NostrProfile(
        name: name,
        displayName: displayName,
        picture: nil,
        banner: nil,
        about: nil,
        nip05: nil,
        website: nil,
        lud06: nil,
        lud16: nil
    )
}

private func makeEvent(
    id: String,
    pubkey: String,
    kind: Int,
    tags: [[String]],
    content: String,
    createdAt: Int = 1_700_000_000
) -> Flow.NostrEvent {
    Flow.NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
        sig: String(Array(repeating: "f", count: 128))
    )
}

private func originalEventJSON(for event: Flow.NostrEvent) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try? encoder.encode(event)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

private func hex(_ character: Character) -> String {
    String(Array(repeating: character, count: 64))
}
