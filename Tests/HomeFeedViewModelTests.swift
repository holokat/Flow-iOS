import Combine
import XCTest
@testable import Flow

final class HomeFeedViewModelTests: XCTestCase {
    @MainActor
    func testPaginationDoesNotStopOnShortNonEmptyPage() {
        XCTAssertFalse(FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: 1))
        XCTAssertFalse(FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: 24))
    }

    @MainActor
    func testPaginationStopsOnlyAfterEmptyPage() {
        XCTAssertTrue(FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: 0))
    }

    @MainActor
    func testHomeFeedUsesLargerDefaultPageSize() {
        XCTAssertEqual(HomeFeedViewModel.defaultPageSizeForTesting, 100)
    }

    @MainActor
    func testPaginationPrefetchStartsBeforeLastVisibleItem() {
        XCTAssertTrue(
            HomeFeedViewModel.shouldPrefetchMore(
                visibleItemCount: 100,
                currentIndex: 86
            )
        )
        XCTAssertFalse(
            HomeFeedViewModel.shouldPrefetchMore(
                visibleItemCount: 100,
                currentIndex: 70
            )
        )
    }

    @MainActor
    func testPaginationSpinnerAppearsOnlyNearTheEdge() {
        XCTAssertTrue(
            HomeFeedViewModel.shouldShowPaginationSpinner(
                visibleItemCount: 100,
                currentIndex: 97
            )
        )
        XCTAssertFalse(
            HomeFeedViewModel.shouldShowPaginationSpinner(
                visibleItemCount: 100,
                currentIndex: 90
            )
        )
    }

    @MainActor
    func testInterestHashtagsRestorePreferredInterestsFeedAfterAccountLoads() {
        let currentUserPubkey = hex("c")
        let preferenceKey = HomeFeedViewModel.persistedFeedSourceKey(pubkey: currentUserPubkey)
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        defer {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }

        UserDefaults.standard.set(
            HomePrimaryFeedSource.interests.storageValue,
            forKey: preferenceKey
        )

        let viewModel = HomeFeedViewModel(relayURL: defaultHomeRelayURL)
        viewModel.updateCurrentUserPubkey(currentUserPubkey)

        XCTAssertEqual(viewModel.feedSource, .network)

        viewModel.updateInterestHashtags(["technology", "ai"])

        XCTAssertEqual(viewModel.feedSource, .interests)
    }

    @MainActor
    func testFollowingRefreshUsesDittoRelayStrategy() {
        let strategy = HomeFeedViewModel.requestStrategy(for: .following, isPagination: false)

        XCTAssertEqual(strategy.relayFetchMode, .allRelays)
        XCTAssertEqual(strategy.fetchTimeout, 8)
    }

    @MainActor
    func testFollowingPaginationUsesDittoRelayStrategy() {
        let strategy = HomeFeedViewModel.requestStrategy(for: .following, isPagination: true)

        XCTAssertEqual(strategy.relayFetchMode, .allRelays)
        XCTAssertEqual(strategy.fetchTimeout, 8)
    }

    @MainActor
    func testNonFollowingPaginationUsesExhaustiveRelayStrategy() {
        let strategy = HomeFeedViewModel.requestStrategy(for: .network, isPagination: true)

        XCTAssertEqual(strategy.relayFetchMode, .allRelays)
        XCTAssertEqual(strategy.fetchTimeout, 8)
    }

    @MainActor
    func testNetworkRefreshUsesDittoGraceWindowInsteadOfWaitingForSlowRelay() async throws {
        let initialNote = makeEvent(
            id: hex("d"),
            pubkey: hex("a"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Newest local note",
            createdAt: 1_700_000_300
        )
        let olderRemoteNote = makeEvent(
            id: hex("e"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Older remote note",
            createdAt: 1_700_000_200
        )
        let harness = try HomeFeedViewModelHarness(
            readRelayURLs: [defaultHomeRelayURL, secondaryHomeRelayURL],
            initialRelayEvents: [
                defaultHomeRelayURL: [initialNote],
                secondaryHomeRelayURL: [olderRemoteNote]
            ]
        )
        await harness.setRelayDelay(3_100_000_000, for: secondaryHomeRelayURL)
        let startedAt = Date()
        await harness.viewModel.refresh()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(
            harness.viewModel.visibleItems.map(\.id),
            [initialNote.id]
        )
        XCTAssertLessThan(elapsed, 1.5)
    }

    @MainActor
    func testNetworkRefreshBackfillsPastRepliesToRecoverNotesMode() async throws {
        let replyTargetID = hex("f")
        let newestReplies = (0..<40).map { index in
            makeEvent(
                id: makeHexID(index + 10),
                pubkey: hex("a"),
                kind: FeedKindFilters.shortTextNote,
                tags: [
                    ["e", replyTargetID, "", "root"],
                    ["e", replyTargetID, "", "reply"]
                ],
                content: "reply \(index)",
                createdAt: 1_700_000_500 - index
            )
        }
        let olderTopLevelNote = makeEvent(
            id: hex("9"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Recovered note",
            createdAt: 1_700_000_200
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: newestReplies + [olderTopLevelNote]
            ],
            pageSize: 20
        )

        await harness.viewModel.refresh()

        XCTAssertEqual(harness.viewModel.visibleItems.map { $0.id }, [olderTopLevelNote.id])
    }

    @MainActor
    func testFollowingRefreshBackfillsPastDenseRepliesToRecoverNotesMode() async throws {
        let currentUserPubkey = hex("c")
        let followedAuthorPubkey = hex("a")
        let replyTargetID = hex("f")
        let relayFollowList = makeEvent(
            id: hex("4"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_410
        )
        let newestReplies = (0..<150).map { index in
            makeEvent(
                id: makeHexID(index + 500),
                pubkey: followedAuthorPubkey,
                kind: FeedKindFilters.shortTextNote,
                tags: [
                    ["e", replyTargetID, "", "root"],
                    ["e", replyTargetID, "", "reply"]
                ],
                content: "reply \(index)",
                createdAt: 1_700_001_000 - index
            )
        }
        let olderTopLevelNote = makeEvent(
            id: hex("9"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Recovered following note",
            createdAt: 1_700_000_200
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [relayFollowList] + newestReplies + [olderTopLevelNote]
            ],
            pageSize: 20
        )

        harness.selectFollowingFeed(for: currentUserPubkey)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.visibleItems.map { $0.id }, [olderTopLevelNote.id])
    }

    @MainActor
    func testArticlesFeedShowsFollowedLongFormArticlesOnly() async throws {
        let currentUserPubkey = hex("d")
        let followedAuthorPubkey = hex("a")
        let relayFollowList = makeEvent(
            id: String(format: "%064x", 0x40),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_410
        )
        let article = makeEvent(
            id: String(format: "%064x", 0x41),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [["title", "Followed article"]],
            content: "Long-form article",
            createdAt: 1_700_000_400
        )
        let note = makeEvent(
            id: String(format: "%064x", 0x42),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Plain note",
            createdAt: 1_700_000_420
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [relayFollowList, note, article]
            ],
            pageSize: 20
        )

        harness.selectFeedSource(.articles, for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.feedSource, .articles)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [article.id])
    }

    @MainActor
    func testArticlesFeedTreatsMissingFollowingsAsEmptyStateCondition() async throws {
        let currentUserPubkey = hex("e")
        let harness = try HomeFeedViewModelHarness()

        harness.selectFeedSource(.articles, for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertTrue(harness.viewModel.followingFeedHasNoFollowings)
    }

    @MainActor
    func testFollowingInitialLoadTargetsAFullVisiblePage() {
        XCTAssertEqual(
            HomeFeedViewModel.initialVisibleTargetForTesting(
                source: .following,
                mode: .posts,
                limit: 100
            ),
            100
        )
        XCTAssertEqual(
            HomeFeedViewModel.initialVisibleTargetForTesting(
                source: .following,
                mode: .postsAndReplies,
                limit: 100
            ),
            100
        )
    }

    @MainActor
    func testFollowingModeSwitchOnlyRequiresInitialVisibleSlice() {
        XCTAssertEqual(
            HomeFeedViewModel.minimumVisibleItemsForSelectedModeForTesting(
                source: .following,
                mode: .posts,
                pageSize: 100
            ),
            100
        )
        XCTAssertEqual(
            HomeFeedViewModel.minimumVisibleItemsForSelectedModeForTesting(
                source: .following,
                mode: .postsAndReplies,
                pageSize: 100
            ),
            100
        )
    }

    @MainActor
    func testPaginationKeepsFullVisibleTargetOutsideInitialFollowingPass() {
        XCTAssertEqual(
            HomeFeedViewModel.initialVisibleTargetForTesting(
                source: .network,
                mode: .posts,
                limit: 100
            ),
            100
        )
        XCTAssertEqual(
            HomeFeedViewModel.initialVisibleTargetForTesting(
                source: .polls,
                mode: nil,
                limit: 100
            ),
            8
        )
    }

    @MainActor
    func testTrendingInitialLoadUsesSingleRankedFetch() {
        XCTAssertEqual(
            HomeFeedViewModel.trendingWindowTraversalLimitForTesting(isInitialPage: true),
            1
        )
    }

    @MainActor
    func testTrendingPaginationDoesNotTraverseHistoricalWindows() {
        XCTAssertEqual(
            HomeFeedViewModel.trendingWindowTraversalLimitForTesting(isInitialPage: false),
            1
        )
    }

    @MainActor
    func testLoadIfNeededRefreshesFromRelayInsteadOfRecentSnapshotBootstrap() async throws {
        let harness = try HomeFeedViewModelHarness()
        let refreshedAuthorPubkey = hex("b")
        let refreshedNote = makeEvent(
            id: hex("3"),
            pubkey: refreshedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Remote replacement",
            createdAt: 1_700_000_200
        )
        let refreshedProfile = makeProfileEvent(
            id: hex("4"),
            pubkey: refreshedAuthorPubkey,
            displayName: "Bob",
            createdAt: 1_700_000_201
        )

        await harness.setRemoteEvents([refreshedNote, refreshedProfile])

        await harness.viewModel.loadIfNeeded()
        try await harness.waitForVisibleItem(id: refreshedNote.id)

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [refreshedNote.id])
        XCTAssertEqual(harness.viewModel.visibleItems.first?.profile?.displayName, "Bob")
        XCTAssertTrue(harness.viewModel.visibleBufferedNewItems.isEmpty)
    }

    @MainActor
    func testLoadIfNeededDoesNotPublishRecentSnapshotBeforeRelayResponse() async throws {
        let harness = try HomeFeedViewModelHarness()
        let remoteNote = makeEvent(
            id: hex("8"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Relay row",
            createdAt: 1_700_000_400
        )
        await harness.setRemoteEvents([remoteNote])
        await harness.setRelayDelay(700_000_000)

        let loadTask = Task { await harness.viewModel.loadIfNeeded() }
        defer { loadTask.cancel() }

        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)

        try await harness.waitUntilIdle(timeout: 4)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [remoteNote.id])
    }

    @MainActor
    func testRefreshCommitsFullyHydratedTopBatchBeforePublishingItems() async throws {
        let harness = try HomeFeedViewModelHarness()

        harness.startObservingItemCommits()
        await harness.viewModel.refresh()
        try await harness.finishBackgroundHydration()

        XCTAssertEqual(harness.itemCommitCount, 1)
        XCTAssertEqual(harness.viewModel.items.first?.profile?.displayName, "Alice")
    }

    @MainActor
    func testFollowingRefreshPrefersRelayFollowListOverCachedLocalFollowings() async throws {
        let harness = try HomeFeedViewModelHarness()
        let currentUserPubkey = hex("c")
        let localAuthorPubkey = hex("a")
        let relayAuthorPubkey = hex("b")
        let relayFollowList = makeEvent(
            id: hex("5"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", relayAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_111
        )
        let remoteNote = makeEvent(
            id: hex("6"),
            pubkey: relayAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Relay follow note",
            createdAt: 1_700_000_210
        )
        await harness.configureLocalFollowings([localAuthorPubkey], for: currentUserPubkey)
        await harness.setRemoteEvents([relayFollowList, remoteNote])

        harness.selectFollowingFeed(for: currentUserPubkey)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await harness.waitUntilIdle(timeout: 2.5)

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [remoteNote.id])
    }

    @MainActor
    func testFollowingRefreshDoesNotBootstrapLocalRowsBeforeRelayResponse() async throws {
        let harness = try HomeFeedViewModelHarness()
        let currentUserPubkey = hex("d")
        let localAuthorPubkey = hex("e")
        let localNote = makeEvent(
            id: hex("a"),
            pubkey: localAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Local bootstrap row",
            createdAt: 1_700_000_310
        )
        let relayAuthorPubkey = hex("f")
        let relayFollowList = makeEvent(
            id: hex("b"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", relayAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_311
        )
        let remoteNote = makeEvent(
            id: hex("c"),
            pubkey: relayAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Relay note",
            createdAt: 1_700_000_312
        )

        await harness.storeLocalEvents([localNote])
        await harness.configureLocalFollowings([localAuthorPubkey], for: currentUserPubkey)
        await harness.setRemoteEvents([relayFollowList, remoteNote])
        await harness.setRelayDelay(700_000_000)

        harness.selectFollowingFeed(for: currentUserPubkey)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)

        try await Task.sleep(nanoseconds: 100_000_000)
        try await harness.waitForVisibleItem(id: remoteNote.id, timeout: 4)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [remoteNote.id])
    }

    @MainActor
    func testFollowingRefreshShowsNotesBeforeFullHydrationFinishes() async throws {
        let harness = try HomeFeedViewModelHarness()
        let currentUserPubkey = hex("1")
        let authorPubkey = hex("2")
        let relayFollowList = makeEvent(
            id: hex("3"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", authorPubkey]],
            content: "",
            createdAt: 1_700_000_510
        )
        let remoteNote = makeEvent(
            id: hex("4"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Fast following note",
            createdAt: 1_700_000_511
        )
        let remoteProfile = makeProfileEvent(
            id: hex("5"),
            pubkey: authorPubkey,
            displayName: "Bob",
            createdAt: 1_700_000_512
        )
        await harness.setRemoteEvents([relayFollowList, remoteNote, remoteProfile])
        await harness.setRelayDelay(2_000_000_000, forKind: 0)

        harness.startObservingItemCommits()
        harness.selectFollowingFeed(for: currentUserPubkey)

        let deadline = Date().addingTimeInterval(1)
        var sawFastPaintWhileLoading = false
        while Date() < deadline {
            if harness.viewModel.visibleItems.contains(where: { $0.id == remoteNote.id }),
               harness.viewModel.isLoading {
                sawFastPaintWhileLoading = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertTrue(sawFastPaintWhileLoading)
        XCTAssertNil(harness.viewModel.visibleItems.first?.profile)

        try await harness.waitUntilIdle(timeout: 4)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [remoteNote.id])
        XCTAssertEqual(harness.viewModel.visibleItems.first?.profile?.displayName, "Bob")
        XCTAssertGreaterThanOrEqual(harness.itemCommitCount, 2)
    }

    @MainActor
    func testFollowingFeedUsesConfiguredReadRelaysDirectlyInsteadOfOutboxRecovery() async throws {
        let harness = try HomeFeedViewModelHarness()
        let currentUserPubkey = hex("9")
        let authorPubkey = hex("8")
        let authorReadRelayURL = URL(string: "wss://following-author-read.example")!
        let relayFollowList = makeEvent(
            id: hex("5"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", authorPubkey]],
            content: "",
            createdAt: 1_700_000_329
        )
        let relayListEvent = makeEvent(
            id: hex("7"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [["r", authorReadRelayURL.absoluteString, "read"]],
            content: "",
            createdAt: 1_700_000_330
        )
        let outboxNote = makeEvent(
            id: hex("6"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Followed author outbox note",
            createdAt: 1_700_000_331
        )

        await harness.setRemoteEvents([relayFollowList, relayListEvent], for: defaultHomeRelayURL)
        await harness.setRemoteEvents([outboxNote], for: authorReadRelayURL)

        harness.selectFollowingFeed(for: currentUserPubkey)
        await harness.viewModel.refresh()

        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)
    }

    @MainActor
    func testNewsFeedIncludesAddedAuthorPostsFromAdvertisedReadRelay() async throws {
        let currentUserPubkey = hex("c")
        AppSettingsStore.shared.configure(accountPubkey: currentUserPubkey)
        let previousNewsRelayURLs = AppSettingsStore.shared.newsRelayURLs
        let previousNewsAuthorPubkeys = AppSettingsStore.shared.newsAuthorPubkeys
        let previousNewsHashtags = AppSettingsStore.shared.newsHashtags
        defer {
            AppSettingsStore.shared.setNewsRelayURLs(previousNewsRelayURLs)
            AppSettingsStore.shared.setNewsAuthorPubkeys(previousNewsAuthorPubkeys)
            AppSettingsStore.shared.setNewsHashtags(previousNewsHashtags)
        }

        let authorPubkey = hex("7")
        let authorReadRelayURL = URL(string: "wss://news-author-read.example")!
        let relayListEvent = makeEvent(
            id: hex("1"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [["r", authorReadRelayURL.absoluteString, "read"]],
            content: "",
            createdAt: 1_700_000_330
        )
        let authorNote = makeEvent(
            id: hex("2"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Added News author outbox note",
            createdAt: 1_700_000_331
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [relayListEvent],
                authorReadRelayURL: [authorNote]
            ]
        )

        AppSettingsStore.shared.setNewsRelayURLs([defaultHomeRelayURL])
        AppSettingsStore.shared.setNewsAuthorPubkeys([authorPubkey])
        AppSettingsStore.shared.setNewsHashtags([])

        let directlyFetchedItems = try await harness.fetchOutboxBackedFollowingItems(
            baseReadRelayURLs: [defaultHomeRelayURL],
            authors: [authorPubkey]
        )
        XCTAssertEqual(directlyFetchedItems.map(\.id), [authorNote.id])

        harness.viewModel.updateCurrentUserPubkey(currentUserPubkey)
        harness.viewModel.selectFeedSource(.news)
        XCTAssertEqual(harness.viewModel.feedSource, .news)
        XCTAssertEqual(AppSettingsStore.shared.newsAuthorPubkeys, [authorPubkey])
        try await harness.waitForVisibleItem(id: authorNote.id)

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [authorNote.id])
    }

}

private let defaultHomeRelayURL = URL(string: "wss://relay.example.com")!
private let secondaryHomeRelayURL = URL(string: "wss://relay-two.example.com")!

private actor HomeFeedTestRelayClient: NostrRelayEventFetching {
    private var eventsByRelay: [String: [Flow.NostrEvent]]
    private var delaysByRelay: [String: UInt64] = [:]
    private var delaysByKind: [Int: UInt64] = [:]

    init(eventsByRelay: [URL: [Flow.NostrEvent]]) {
        var normalized: [String: [Flow.NostrEvent]] = [:]
        for (relayURL, events) in eventsByRelay {
            normalized[canonicalRelayString(relayURL)] = events
        }
        self.eventsByRelay = normalized
    }

    func setEvents(_ events: [Flow.NostrEvent], for relayURL: URL) {
        eventsByRelay[canonicalRelayString(relayURL)] = events
    }

    func setDelay(_ delayNanoseconds: UInt64?, for relayURL: URL) {
        if let delayNanoseconds {
            delaysByRelay[canonicalRelayString(relayURL)] = delayNanoseconds
        } else {
            delaysByRelay.removeValue(forKey: canonicalRelayString(relayURL))
        }
    }

    func setDelay(_ delayNanoseconds: UInt64?, for kind: Int) {
        if let delayNanoseconds {
            delaysByKind[kind] = delayNanoseconds
        } else {
            delaysByKind.removeValue(forKey: kind)
        }
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [Flow.NostrEvent] {
        let canonicalRelayURL = canonicalRelayString(relayURL)

        if let delayNanoseconds = delaysByRelay[canonicalRelayURL] {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        if let requestedKinds = filter.kinds,
           let delayNanoseconds = requestedKinds.compactMap({ delaysByKind[$0] }).max(),
           delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let authors = Set(filter.authors ?? [])
        let kinds = Set(filter.kinds ?? [])
        let ids = Set(filter.ids ?? [])
        let until = filter.until
        let since = filter.since
        let limit = filter.limit ?? Int.max

        return Array(
            (eventsByRelay[canonicalRelayURL] ?? [])
                .filter { event in
                    (authors.isEmpty || authors.contains(event.pubkey)) &&
                    (kinds.isEmpty || kinds.contains(event.kind)) &&
                    (ids.isEmpty || ids.contains(event.id)) &&
                    (until == nil || event.createdAt <= until!) &&
                    (since == nil || event.createdAt >= since!)
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
private final class HomeFeedViewModelHarness {
    let viewModel: HomeFeedViewModel
    let homeRelayURL: URL

    private let relayClient: HomeFeedTestRelayClient
    private let service: NostrFeedService
    private let seenEventStore: SeenEventStore
    private var itemCommitCancellable: AnyCancellable?
    private(set) var itemCommitCount = 0

    init(
        relayURL: URL = defaultHomeRelayURL,
        readRelayURLs: [URL]? = nil,
        initialRelayEvents: [URL: [Flow.NostrEvent]]? = nil,
        pageSize: Int = 20
    ) throws {
        self.homeRelayURL = relayURL
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeFeedViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileManager = HomeFeedTestFileManager(rootURL: rootURL)
        let defaults = UserDefaults(suiteName: "HomeFeedViewModelTests-\(UUID().uuidString)")!
        let filterStore = HomeFeedFilterStore(defaults: defaults)
        let nostrDatabase = FlowNostrDB(fileManager: fileManager)
        let profileSnapshotStore = ProfileSnapshotStore(fileManager: fileManager)
        let relayHintCache = ProfileRelayHintCache()
        let followListCache = FollowListSnapshotCache(fileManager: fileManager)
        seenEventStore = SeenEventStore(fileManager: fileManager)
        let profileCache = ProfileCache(snapshotStore: profileSnapshotStore)

        let authorPubkey = hex("a")
        let noteEvent = makeEvent(
            id: hex("1"),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Hello from cache",
            createdAt: 1_700_000_100
        )
        let profileEvent = makeProfileEvent(
            id: hex("2"),
            pubkey: authorPubkey,
            displayName: "Alice",
            createdAt: 1_700_000_101
        )
        let configuredReadRelayURLs = readRelayURLs ?? [relayURL]
        let defaultRelayEvents = [
            relayURL: [noteEvent, profileEvent]
        ]
        relayClient = HomeFeedTestRelayClient(eventsByRelay: initialRelayEvents ?? defaultRelayEvents)
        service = NostrFeedService(
            relayClient: relayClient,
            timelineCache: TimelineEventCache(),
            profileCache: profileCache,
            relayHintCache: relayHintCache,
            followListCache: followListCache,
            seenEventStore: seenEventStore,
            nostrDatabase: nostrDatabase
        )

        viewModel = HomeFeedViewModel(
            relayURL: relayURL,
            readRelayURLs: configuredReadRelayURLs,
            pageSize: pageSize,
            service: service,
            liveSubscriber: NostrLiveFeedSubscriber(
                session: .shared,
                liveEventFallbackDelayNanoseconds: 1,
                receiveIdleTimeoutNanoseconds: 1_000_000,
                pingTimeoutNanoseconds: 1_000_000
            ),
            filterStore: filterStore
        )
    }

    func setRemoteEvents(_ events: [NostrEvent]) async {
        await relayClient.setEvents(events, for: homeRelayURL)
    }

    func setRemoteEvents(_ events: [NostrEvent], for relayURL: URL) async {
        await relayClient.setEvents(events, for: relayURL)
    }

    func setRelayDelay(_ delayNanoseconds: UInt64?) async {
        await relayClient.setDelay(delayNanoseconds, for: homeRelayURL)
    }

    func setRelayDelay(_ delayNanoseconds: UInt64?, for relayURL: URL) async {
        await relayClient.setDelay(delayNanoseconds, for: relayURL)
    }

    func setRelayDelay(_ delayNanoseconds: UInt64?, forKind kind: Int) async {
        await relayClient.setDelay(delayNanoseconds, for: kind)
    }

    func storeLocalEvents(_ events: [NostrEvent]) async {
        await seenEventStore.store(events: events)
    }

    func storeFollowingSnapshot(
        followedPubkeys: [String],
        for currentUserPubkey: String
    ) async {
        let snapshot = FollowListSnapshot(
            content: "",
            tags: followedPubkeys.map { ["p", $0] }
        )
        await service.storeFollowListSnapshotLocally(snapshot, for: currentUserPubkey)
    }

    func configureLocalFollowings(
        _ followedPubkeys: [String],
        for currentUserPubkey: String
    ) async {
        UserDefaults.standard.set(
            followedPubkeys,
            forKey: "flow.followedPubkeys.\(currentUserPubkey)"
        )
        FollowStore.shared.configure(
            accountPubkey: currentUserPubkey,
            nsec: nil,
            readRelayURLs: [homeRelayURL],
            writeRelayURLs: [homeRelayURL]
        )
        await storeFollowingSnapshot(
            followedPubkeys: followedPubkeys,
            for: currentUserPubkey
        )
    }

    func startObservingItemCommits() {
        itemCommitCount = 0
        itemCommitCancellable = viewModel.$items
            .dropFirst()
            .sink { [weak self] items in
                guard !items.isEmpty else { return }
                self?.itemCommitCount += 1
            }
    }

    func selectFeedSource(_ source: HomePrimaryFeedSource, for currentUserPubkey: String) {
        UserDefaults.standard.set(
            source.storageValue,
            forKey: HomeFeedViewModel.persistedFeedSourceKey(pubkey: currentUserPubkey)
        )
        viewModel.updateCurrentUserPubkey(currentUserPubkey)
    }

    func selectFollowingFeed(for currentUserPubkey: String) {
        selectFeedSource(.following, for: currentUserPubkey)
    }

    func waitForVisibleItem(
        id: String,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewModel.visibleItems.contains(where: { $0.id == id }) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for visible item \(id)")
    }

    func waitUntilIdle(timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !viewModel.isLoading && !viewModel.isLoadingMore {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for feed view model to become idle")
    }

    func finishBackgroundHydration() async throws {
        try await Task.sleep(nanoseconds: 700_000_000)
    }

    func fetchOutboxBackedFollowingItems(
        baseReadRelayURLs: [URL],
        authors: [String]
    ) async throws -> [FeedItem] {
        try await service.fetchFollowingFeedRecoveringWithOutbox(
            baseReadRelayURLs: baseReadRelayURLs,
            authors: authors,
            kinds: [FeedKindFilters.shortTextNote],
            limit: 20,
            until: nil,
            hydrationMode: .cachedProfilesOnly
        )
    }
}

private final class HomeFeedTestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        [rootURL]
    }
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

private func makeProfileEvent(
    id: String,
    pubkey: String,
    displayName: String,
    createdAt: Int = 1_700_000_000
) -> Flow.NostrEvent {
    makeEvent(
        id: id,
        pubkey: pubkey,
        kind: 0,
        tags: [],
        content: #"{"name":"\#(displayName.lowercased())","display_name":"\#(displayName)"}"#,
        createdAt: createdAt
    )
}

private func canonicalRelayString(_ relayURL: URL) -> String {
    let value = relayURL.absoluteString.lowercased()
    return value.hasSuffix("/") ? String(value.dropLast()) : value
}

private func hex(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func makeHexID(_ value: Int) -> String {
    String(format: "%064x", value)
}
