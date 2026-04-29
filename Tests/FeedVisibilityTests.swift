import XCTest
@testable import Flow

@MainActor
final class FeedVisibilityTests: XCTestCase {
    func testFollowingAuthorPubkeysIncludeCurrentUserLikeX21() {
        let currentUserPubkey = hex("a")
        let followings = [hex("b"), currentUserPubkey.uppercased(), hex("c"), hex("b")]

        let authors = HomeFeedViewModel.followingAuthorPubkeys(
            followingPubkeys: followings,
            currentUserPubkey: currentUserPubkey
        )

        XCTAssertEqual(authors, [currentUserPubkey, hex("b"), hex("c")])
    }

    func testProfileFeedRequestedKindsIncludeStandardPollsAndHideZapPolls() {
        XCTAssertTrue(ProfileViewModel.requestedFeedKinds.contains(FeedKindFilters.poll))
        XCTAssertTrue(ProfileViewModel.requestedFeedKinds.contains(FeedKindFilters.longFormArticle))
        XCTAssertFalse(ProfileViewModel.requestedFeedKinds.contains(FeedKindFilters.legacyZapPoll))
        XCTAssertEqual(FeedKindFilters.pollKinds, [FeedKindFilters.poll])
        XCTAssertFalse(FeedKindFilters.supportedKinds.contains(FeedKindFilters.legacyZapPoll))
        XCTAssertFalse(FeedKindFilters.normalizedKinds([FeedKindFilters.poll, FeedKindFilters.legacyZapPoll]).contains(FeedKindFilters.legacyZapPoll))
    }

    func testProfileFeedModesIncludeArticlesAfterReplies() {
        XCTAssertEqual(FeedMode.allCases, [.posts, .postsAndReplies, .articles])
        XCTAssertEqual(FeedMode.articles.title, "Articles")
    }

    func testProfileArticleModeShowsOnlyDirectLongFormArticles() {
        let author = hex("a")
        let note = makeEvent(id: hex("1"), pubkey: author, kind: FeedKindFilters.shortTextNote, tags: [])
        let reply = makeEvent(
            id: hex("2"),
            pubkey: author,
            kind: FeedKindFilters.shortTextNote,
            tags: [["e", hex("b"), "", "reply"]]
        )
        let article = makeEvent(
            id: hex("3"),
            pubkey: author,
            kind: FeedKindFilters.longFormArticle,
            tags: [["title", "Article"]]
        )
        let articleRepost = FeedItem(
            event: makeEvent(id: hex("4"), pubkey: author, kind: FeedKindFilters.repost, tags: []),
            profile: nil,
            displayEventOverride: article
        )

        XCTAssertTrue(ProfileFeedVisibility.isVisible(FeedItem(event: note, profile: nil), in: .posts))
        XCTAssertFalse(ProfileFeedVisibility.isVisible(FeedItem(event: article, profile: nil), in: .posts))
        XCTAssertTrue(ProfileFeedVisibility.isVisible(FeedItem(event: reply, profile: nil), in: .postsAndReplies))
        XCTAssertTrue(ProfileFeedVisibility.isVisible(FeedItem(event: article, profile: nil), in: .articles))
        XCTAssertFalse(ProfileFeedVisibility.isVisible(articleRepost, in: .articles))
    }

    func testProfileArticleModeFetchesArticlesEvenWhenAuthorHasManyNewerNotes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedVisibilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let relayURL = URL(string: "wss://relay.example.com")!
        let fileManager = FeedVisibilityTestFileManager(rootURL: rootURL)
        let nostrDatabase = FlowNostrDB(fileManager: fileManager)
        let seenEventStore = SeenEventStore(fileManager: fileManager)
        let authorPubkey = hex("a")
        let article = makeEvent(
            id: hex("f"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [["title", "Article"]],
            content: "Long form article",
            createdAt: 1_700_000_000
        )
        let newerNotes = (0..<450).map { index in
            makeEvent(
                id: makeHexID(index + 1),
                pubkey: authorPubkey,
                kind: FeedKindFilters.shortTextNote,
                tags: [],
                content: "note \(index)",
                createdAt: 1_700_000_500 - index
            )
        }
        let relayClient = ProfileArticleRelayClient(eventsByRelay: [relayURL: newerNotes + [article]])
        let service = makeProfileFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            nostrDatabase: nostrDatabase,
            seenEventStore: seenEventStore
        )
        let profileEventService = ProfileEventService(
            relayClient: relayClient,
            seenEventStore: seenEventStore
        )
        let viewModel = ProfileViewModel(
            pubkey: authorPubkey,
            relayURL: relayURL,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL],
            pageSize: 70,
            service: service,
            profileEventService: profileEventService,
            relayClient: NoopPublishingRelayClient(),
            seenEventStore: seenEventStore
        )

        viewModel.mode = .articles
        await viewModel.refresh()

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [article.id])
    }

    func testProfilePostsModeUsesConfiguredReadRelaysDirectlyInsteadOfOutboxRecovery() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedVisibilityProfileOutboxPosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let relayURL = URL(string: "wss://relay.example.com")!
        let authorReadRelayURL = URL(string: "wss://author-profile-read.example")!
        let fileManager = FeedVisibilityTestFileManager(rootURL: rootURL)
        let nostrDatabase = FlowNostrDB(fileManager: fileManager)
        let seenEventStore = SeenEventStore(fileManager: fileManager)
        let authorPubkey = hex("b")
        let relayListEvent = makeEvent(
            id: hex("1"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [["r", authorReadRelayURL.absoluteString, "read"]],
            content: "",
            createdAt: 1_700_000_900
        )
        let outboxNote = makeEvent(
            id: hex("2"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Recovered from outbox",
            createdAt: 1_700_000_901
        )
        let relayClient = ProfileArticleRelayClient(eventsByRelay: [
            relayURL: [relayListEvent],
            authorReadRelayURL: [outboxNote]
        ])
        let service = makeProfileFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            nostrDatabase: nostrDatabase,
            seenEventStore: seenEventStore
        )
        let profileEventService = ProfileEventService(
            relayClient: relayClient,
            seenEventStore: seenEventStore
        )
        let viewModel = ProfileViewModel(
            pubkey: authorPubkey,
            relayURL: relayURL,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL],
            pageSize: 20,
            service: service,
            profileEventService: profileEventService,
            relayClient: NoopPublishingRelayClient(),
            seenEventStore: seenEventStore
        )

        await viewModel.refresh()

        XCTAssertTrue(viewModel.visibleItems.isEmpty)
    }

    func testProfilePostsModeBackfillsPastNewerRepliesToRecoverNotes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedVisibilityProfilePostsBackfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let relayURL = URL(string: "wss://relay.example.com")!
        let fileManager = FeedVisibilityTestFileManager(rootURL: rootURL)
        let nostrDatabase = FlowNostrDB(fileManager: fileManager)
        let seenEventStore = SeenEventStore(fileManager: fileManager)
        let authorPubkey = hex("d")
        let replyTargetID = hex("e")
        let olderNote = makeEvent(
            id: hex("6"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Recovered note",
            createdAt: 1_700_000_100
        )
        let newerReplies = (0..<180).map { index in
            makeEvent(
                id: makeHexID(index + 1000),
                pubkey: authorPubkey,
                kind: FeedKindFilters.shortTextNote,
                tags: [
                    ["e", replyTargetID, "", "root"],
                    ["e", replyTargetID, "", "reply"]
                ],
                content: "reply \(index)",
                createdAt: 1_700_000_700 - index
            )
        }
        let relayClient = ProfileArticleRelayClient(eventsByRelay: [
            relayURL: newerReplies + [olderNote]
        ])
        let service = makeProfileFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            nostrDatabase: nostrDatabase,
            seenEventStore: seenEventStore
        )
        let profileEventService = ProfileEventService(
            relayClient: relayClient,
            seenEventStore: seenEventStore
        )
        let viewModel = ProfileViewModel(
            pubkey: authorPubkey,
            relayURL: relayURL,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL],
            pageSize: 70,
            service: service,
            profileEventService: profileEventService,
            relayClient: NoopPublishingRelayClient(),
            seenEventStore: seenEventStore
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [olderNote.id])
    }

    func testProfileRefreshShowsNotesBeforeFullHydrationFinishes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedVisibilityProfileFastPaint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let relayURL = URL(string: "wss://relay.example.com")!
        let fileManager = FeedVisibilityTestFileManager(rootURL: rootURL)
        let nostrDatabase = FlowNostrDB(fileManager: fileManager)
        let seenEventStore = SeenEventStore(fileManager: fileManager)
        let authorPubkey = hex("f")
        let note = makeEvent(
            id: hex("7"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Visible immediately",
            createdAt: 1_700_000_950
        )
        let relayClient = ProfileArticleRelayClient(
            eventsByRelay: [relayURL: [note]],
            delaysByKind: [0: 2_000_000_000]
        )
        let service = makeProfileFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            nostrDatabase: nostrDatabase,
            seenEventStore: seenEventStore
        )
        let profileEventService = ProfileEventService(
            relayClient: relayClient,
            seenEventStore: seenEventStore
        )
        let viewModel = ProfileViewModel(
            pubkey: authorPubkey,
            relayURL: relayURL,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL],
            pageSize: 20,
            service: service,
            profileEventService: profileEventService,
            relayClient: NoopPublishingRelayClient(),
            seenEventStore: seenEventStore
        )

        let refreshTask = Task {
            await viewModel.refresh()
        }

        for _ in 0..<40 where viewModel.visibleItems.isEmpty {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [note.id])
        XCTAssertTrue(viewModel.isLoading)

        await refreshTask.value
    }

    func testProfileArticlesModeUsesConfiguredReadRelaysDirectlyInsteadOfOutboxRecovery() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedVisibilityProfileOutboxArticles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let relayURL = URL(string: "wss://relay.example.com")!
        let authorReadRelayURL = URL(string: "wss://author-article-read.example")!
        let fileManager = FeedVisibilityTestFileManager(rootURL: rootURL)
        let nostrDatabase = FlowNostrDB(fileManager: fileManager)
        let seenEventStore = SeenEventStore(fileManager: fileManager)
        let authorPubkey = hex("c")
        let relayListEvent = makeEvent(
            id: hex("3"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [["r", authorReadRelayURL.absoluteString, "read"]],
            content: "",
            createdAt: 1_700_000_920
        )
        let newerNote = makeEvent(
            id: hex("4"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Newer note",
            createdAt: 1_700_000_930
        )
        let article = makeEvent(
            id: hex("5"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [["title", "Recovered article"]],
            content: "Recovered article",
            createdAt: 1_700_000_910
        )
        let relayClient = ProfileArticleRelayClient(eventsByRelay: [
            relayURL: [relayListEvent],
            authorReadRelayURL: [newerNote, article]
        ])
        let service = makeProfileFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            nostrDatabase: nostrDatabase,
            seenEventStore: seenEventStore
        )
        let profileEventService = ProfileEventService(
            relayClient: relayClient,
            seenEventStore: seenEventStore
        )
        let viewModel = ProfileViewModel(
            pubkey: authorPubkey,
            relayURL: relayURL,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL],
            pageSize: 20,
            service: service,
            profileEventService: profileEventService,
            relayClient: NoopPublishingRelayClient(),
            seenEventStore: seenEventStore
        )

        viewModel.mode = .articles
        await viewModel.refresh()

        XCTAssertTrue(viewModel.visibleItems.isEmpty)
    }

    func testProfileArticlesModeRefreshesAfterInitialNotesLoadReachesEnd() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedVisibilityProfileArticleModeSwitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let relayURL = URL(string: "wss://relay.example.com")!
        let fileManager = FeedVisibilityTestFileManager(rootURL: rootURL)
        let nostrDatabase = FlowNostrDB(fileManager: fileManager)
        let seenEventStore = SeenEventStore(fileManager: fileManager)
        let authorPubkey = hex("d")
        let note = makeEvent(
            id: hex("6"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Newest note",
            createdAt: 1_700_000_300
        )
        let article = makeEvent(
            id: hex("7"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [["title", "Older article"]],
            content: "Older article",
            createdAt: 1_700_000_200
        )
        let relayClient = ProfileArticleRelayClient(eventsByRelay: [
            relayURL: [note, article]
        ])
        let service = makeProfileFeedService(
            relayClient: relayClient,
            fileManager: fileManager,
            nostrDatabase: nostrDatabase,
            seenEventStore: seenEventStore
        )
        let profileEventService = ProfileEventService(
            relayClient: relayClient,
            seenEventStore: seenEventStore
        )
        let viewModel = ProfileViewModel(
            pubkey: authorPubkey,
            relayURL: relayURL,
            readRelayURLs: [relayURL],
            writeRelayURLs: [relayURL],
            pageSize: 20,
            service: service,
            profileEventService: profileEventService,
            relayClient: NoopPublishingRelayClient(),
            seenEventStore: seenEventStore
        )

        await viewModel.refresh()
        XCTAssertEqual(viewModel.visibleItems.map(\.id), [note.id])

        viewModel.mode = .articles
        await viewModel.prepareForSelectedModeIfNeeded()

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [article.id])
    }
}

private func hex(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func makeHexID(_ value: Int) -> String {
    String(format: "%064x", value)
}

private func makeEvent(
    id: String,
    pubkey: String,
    kind: Int,
    tags: [[String]],
    content: String = "hello",
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

private actor ProfileArticleRelayClient: NostrRelayEventFetching {
    private let eventsByRelay: [String: [Flow.NostrEvent]]
    private let delaysByKind: [Int: UInt64]

    init(
        eventsByRelay: [URL: [Flow.NostrEvent]],
        delaysByKind: [Int: UInt64] = [:]
    ) {
        var normalized: [String: [Flow.NostrEvent]] = [:]
        for (relayURL, events) in eventsByRelay {
            normalized[canonicalRelayString(relayURL)] = events
        }
        self.eventsByRelay = normalized
        self.delaysByKind = delaysByKind
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        if let requestedKinds = filter.kinds,
           let delay = requestedKinds.compactMap({ delaysByKind[$0] }).max(),
           delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }

        let authors = Set((filter.authors ?? []).map { $0.lowercased() })
        let kinds = Set(filter.kinds ?? [])
        let ids = Set((filter.ids ?? []).map { $0.lowercased() })
        let since = filter.since ?? Int.min
        let until = filter.until ?? Int.max

        let matched = (eventsByRelay[canonicalRelayString(relayURL)] ?? []).filter { event in
            (authors.isEmpty || authors.contains(event.pubkey.lowercased())) &&
                (kinds.isEmpty || kinds.contains(event.kind)) &&
                (ids.isEmpty || ids.contains(event.id.lowercased())) &&
                event.createdAt >= since &&
                event.createdAt <= until
        }
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }

        if let limit = filter.limit {
            return Array(matched.prefix(limit))
        }
        return matched
    }
}

private actor NoopPublishingRelayClient: NostrRelayEventPublishing {
    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async throws {}
}

private final class FeedVisibilityTestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        [rootURL]
    }
}

private func makeProfileFeedService(
    relayClient: any NostrRelayEventFetching,
    fileManager: FeedVisibilityTestFileManager,
    nostrDatabase: FlowNostrDB,
    seenEventStore: SeenEventStore
) -> NostrFeedService {
    let profileSnapshotStore = ProfileSnapshotStore(fileManager: fileManager)
    let profileCache = ProfileCache(snapshotStore: profileSnapshotStore)
    let followListCache = FollowListSnapshotCache(fileManager: fileManager)

    return NostrFeedService(
        relayClient: relayClient,
        timelineCache: TimelineEventCache(),
        profileCache: profileCache,
        relayHintCache: ProfileRelayHintCache(),
        followListCache: followListCache,
        seenEventStore: seenEventStore,
        nostrDatabase: nostrDatabase,
        presentationCache: FeedPresentationCache()
    )
}

private func canonicalRelayString(_ relayURL: URL) -> String {
    let value = relayURL.absoluteString.lowercased()
    return value.hasSuffix("/") ? String(value.dropLast()) : value
}
