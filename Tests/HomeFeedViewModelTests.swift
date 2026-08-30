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

    func testIncrementalSortedMergeUpgradesRowsWithoutDuplicatingOrResortingTheSlice() {
        let newestEvent = makeEvent(
            id: hex("9"),
            pubkey: hex("a"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Newest",
            createdAt: 1_700_000_300
        )
        let repostEvent = makeEvent(
            id: hex("7"),
            pubkey: hex("b"),
            kind: FeedKindFilters.repost,
            tags: [["e", hex("6")]],
            content: "",
            createdAt: 1_700_000_200
        )
        let repostTarget = makeEvent(
            id: hex("6"),
            pubkey: hex("c"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Resolved repost target",
            createdAt: 1_700_000_150
        )
        let oldestEvent = makeEvent(
            id: hex("1"),
            pubkey: hex("d"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Oldest",
            createdAt: 1_700_000_100
        )
        let insertedEvent = makeEvent(
            id: hex("5"),
            pubkey: hex("e"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Inserted",
            createdAt: 1_700_000_175
        )
        let existingItems = [newestEvent, repostEvent, oldestEvent].map {
            FeedItem(event: $0, profile: nil)
        }
        let hydratedRepost = FeedItem(
            event: repostEvent,
            profile: nil,
            displayEventOverride: repostTarget
        )

        let mergedItems = HomeFeedViewModel.mergeSortedItemsIncrementally(
            incomingItems: [hydratedRepost, FeedItem(event: insertedEvent, profile: nil)],
            into: existingItems,
            feedSource: .following
        )

        XCTAssertEqual(
            mergedItems.map(\.id),
            [newestEvent.id, repostEvent.id, insertedEvent.id, oldestEvent.id]
        )
        XCTAssertEqual(mergedItems.filter { $0.id == repostEvent.id }.count, 1)
        XCTAssertEqual(
            mergedItems.first { $0.id == repostEvent.id }?.displayEventID,
            repostTarget.id
        )
    }

    func testDisjointSortedMergeKeepsOrderAndHonorsLimit() {
        let firstItems = [600, 300, 100].enumerated().map { index, createdAt in
            FeedItem(
                event: makeEvent(
                    id: makeHexID(index + 10),
                    pubkey: hex("a"),
                    kind: FeedKindFilters.shortTextNote,
                    tags: [],
                    content: "First \(createdAt)",
                    createdAt: createdAt
                ),
                profile: nil
            )
        }
        let secondItems = [500, 400, 200].enumerated().map { index, createdAt in
            FeedItem(
                event: makeEvent(
                    id: makeHexID(index + 20),
                    pubkey: hex("b"),
                    kind: FeedKindFilters.shortTextNote,
                    tags: [],
                    content: "Second \(createdAt)",
                    createdAt: createdAt
                ),
                profile: nil
            )
        }

        let mergedItems = HomeFeedViewModel.mergeSortedDisjointItems(
            firstItems,
            secondItems,
            feedSource: .following,
            limit: 5
        )

        XCTAssertEqual(mergedItems.map(\.event.createdAt), [600, 500, 400, 300, 200])
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

        XCTAssertEqual(viewModel.feedSource, .following)

        viewModel.updateInterestHashtags(["technology", "ai"])

        XCTAssertEqual(viewModel.feedSource, .interests)
    }

    @MainActor
    func testTrendingPreferenceSurvivesInterestHashtagsFromOnboarding() {
        let currentUserPubkey = hex("e")
        let preferenceKey = HomeFeedViewModel.persistedFeedSourceKey(pubkey: currentUserPubkey)
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        defer {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }

        UserDefaults.standard.set(
            HomePrimaryFeedSource.trending.storageValue,
            forKey: preferenceKey
        )

        let viewModel = HomeFeedViewModel(relayURL: defaultHomeRelayURL)
        viewModel.updateCurrentUserPubkey(currentUserPubkey)
        viewModel.updateInterestHashtags(["technology", "ai"])

        XCTAssertEqual(viewModel.feedSource, .trending)
    }

    @MainActor
    func testFeedSourceOptionsExcludeNetworkArticlesAndNewsAndStartWithFollowing() {
        let viewModel = HomeFeedViewModel(relayURL: defaultHomeRelayURL)

        XCTAssertFalse(viewModel.feedSourceOptions.contains(.network))
        XCTAssertFalse(viewModel.feedSourceOptions.contains(.articles))
        XCTAssertFalse(viewModel.feedSourceOptions.contains(.news))
        XCTAssertEqual(Array(viewModel.feedSourceOptions.prefix(3)), [.following, .polls, .trending])
    }

    @MainActor
    func testLegacyNetworkFeedPreferenceFallsBackToFollowing() {
        let currentUserPubkey = hex("d")
        let preferenceKey = HomeFeedViewModel.persistedFeedSourceKey(pubkey: currentUserPubkey)
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        defer {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }

        UserDefaults.standard.set("network", forKey: preferenceKey)

        let viewModel = HomeFeedViewModel(relayURL: defaultHomeRelayURL)
        viewModel.updateCurrentUserPubkey(currentUserPubkey)

        XCTAssertEqual(viewModel.feedSource, .following)
    }

    @MainActor
    func testUnavailableFeedSourcesFallBackToFollowing() {
        let customFeed = CustomFeedDefinition(
            id: "alerts",
            name: "Alerts",
            hashtags: ["alerts"]
        )
        let viewModel = HomeFeedViewModel(relayURL: defaultHomeRelayURL)

        viewModel.updateFavoriteHashtags(["swift"])
        viewModel.selectFeedSource(.hashtag("swift"))
        viewModel.updateFavoriteHashtags([])
        XCTAssertEqual(viewModel.feedSource, .following)

        viewModel.updateFavoriteRelays(["wss://relay.example.com"])
        viewModel.selectFeedSource(.relay("wss://relay.example.com"))
        viewModel.updateFavoriteRelays([])
        XCTAssertEqual(viewModel.feedSource, .following)

        viewModel.updateCustomFeeds([customFeed])
        viewModel.selectFeedSource(.custom(customFeed.id))
        viewModel.updateCustomFeeds([])
        XCTAssertEqual(viewModel.feedSource, .following)

        viewModel.updatePollsFeedVisibility(true)
        viewModel.selectFeedSource(.polls)
        viewModel.updatePollsFeedVisibility(false)
        XCTAssertEqual(viewModel.feedSource, .following)
    }

    @MainActor
    func testOnlyFollowingFeedSupportsNotesRepliesModeTabs() {
        XCTAssertTrue(HomeFeedViewModel.supportsModeTabsForTesting(source: .following))

        let nonFollowingSources: [HomePrimaryFeedSource] = [
            .network,
            .articles,
            .polls,
            .trending,
            .interests,
            .news,
            .custom("alerts"),
            .hashtag("nostr"),
            .relay("wss://relay.example.com")
        ]

        for source in nonFollowingSources {
            XCTAssertFalse(HomeFeedViewModel.supportsModeTabsForTesting(source: source), "\(source)")
        }
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
    func testNetworkRefreshIncludesResultsFromASlowerRelay() async throws {
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
        await harness.setRelayDelay(450_000_000, for: secondaryHomeRelayURL)
        harness.viewModel.feedSource = .network
        let startedAt = Date()
        await harness.viewModel.refresh()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(
            harness.viewModel.visibleItems.map(\.id),
            [initialNote.id, olderRemoteNote.id]
        )
        XCTAssertLessThan(elapsed, 5)
    }

    @MainActor
    func testLegacyNetworkRefreshDoesNotApplyFollowingModeTabs() async throws {
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

        harness.viewModel.feedSource = .network
        await harness.viewModel.refresh()

        XCTAssertEqual(harness.viewModel.visibleItems.map { $0.id }, newestReplies.prefix(20).map(\.id))
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
    func testArticlesFeedUsesPublishedAtForEditedReplaceableArticles() async throws {
        let currentUserPubkey = hex("d")
        let followedAuthorPubkey = hex("a")
        let relayFollowList = makeEvent(
            id: String(format: "%064x", 0x43),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_950
        )
        let olderArticleOriginal = makeEvent(
            id: String(format: "%064x", 0x44),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [
                ["d", "older-article"],
                ["title", "Older article"],
                ["published_at", "1700000100"]
            ],
            content: "Original text",
            createdAt: 1_700_000_100
        )
        let olderArticleEdit = makeEvent(
            id: String(format: "%064x", 0x45),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [
                ["d", "older-article"],
                ["title", "Older article"],
                ["published_at", "1700000100"]
            ],
            content: "Typo fix",
            createdAt: 1_700_000_900
        )
        let newerArticle = makeEvent(
            id: String(format: "%064x", 0x46),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [
                ["d", "newer-article"],
                ["title", "Newer article"],
                ["published_at", "1700000800"]
            ],
            content: "Newer text",
            createdAt: 1_700_000_800
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [relayFollowList, olderArticleOriginal, newerArticle]
            ],
            pageSize: 20
        )

        harness.selectFeedSource(.articles, for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [newerArticle.id, olderArticleOriginal.id])

        await harness.setRemoteEvents([relayFollowList, olderArticleEdit, newerArticle])
        await harness.viewModel.refresh()

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [newerArticle.id, olderArticleEdit.id])
    }

    @MainActor
    func testArticlesRefreshStaysResponsiveWhenReplacingLargeEditedArticles() async throws {
        let currentUserPubkey = hex("a")
        let followedAuthorPubkey = hex("b")
        let relayFollowList = makeEvent(
            id: String(format: "%064x", 0x50),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedAuthorPubkey]],
            content: "",
            createdAt: 1_700_001_000
        )
        let originalBody = "Original article body"
        let largeBody = (0..<300)
            .map { "Paragraph \($0) with enough words to force repeated article parsing work." }
            .joined(separator: "\n")
        let originals = (0..<36).map { index in
            makeEvent(
                id: makeHexID(index + 0x100),
                pubkey: followedAuthorPubkey,
                kind: FeedKindFilters.longFormArticle,
                tags: [
                    ["d", "article-\(index)"],
                    ["title", "Article \(index)"],
                    ["published_at", "\(1_700_000_000 + index)"]
                ],
                content: originalBody,
                createdAt: 1_700_000_000 + index
            )
        }
        let edits = (0..<36).map { index in
            makeEvent(
                id: makeHexID(index + 0x200),
                pubkey: followedAuthorPubkey,
                kind: FeedKindFilters.longFormArticle,
                tags: [
                    ["d", "article-\(index)"],
                    ["title", "Article \(index)"],
                    ["published_at", "\(1_700_000_000 + index)"]
                ],
                content: largeBody + "\nEdit \(index)",
                createdAt: 1_700_000_500 + index
            )
        }
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [relayFollowList] + originals
            ],
            pageSize: 100
        )

        harness.selectFeedSource(.articles, for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 8)
        XCTAssertEqual(harness.viewModel.visibleItems.count, originals.count)

        await harness.setRemoteEvents([relayFollowList] + edits)

        let startedAt = Date()
        await harness.viewModel.refresh()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 1.75)
        XCTAssertEqual(harness.viewModel.visibleItems.count, edits.count)
        XCTAssertEqual(
            Set(harness.viewModel.visibleItems.map { $0.id }),
            Set(edits.map { $0.id })
        )
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
                source: .trending,
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
    func testTrendingPaginationTraversesArchiveWindows() {
        XCTAssertEqual(
            HomeFeedViewModel.trendingWindowTraversalLimitForTesting(isInitialPage: false),
            NostrFeedService.nostrArchivesTrendingBackfillRelayURLs.count
        )
    }

    @MainActor
    func testTrendingInitialLoadPublishesRowsBeforeProfileHydration() async throws {
        let trendingNote = makeEvent(
            id: hex("8"),
            pubkey: hex("9"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Trending note should not wait for metadata",
            createdAt: 1_700_000_700
        )
        let delayedProfile = makeProfileEvent(
            id: hex("a"),
            pubkey: trendingNote.pubkey,
            displayName: "Slow Profile",
            createdAt: 1_700_000_701
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [delayedProfile],
                NostrFeedService.nostrArchivesTrendingRelayURL: [trendingNote]
            ]
        )
        await harness.setRelayDelay(2_000_000_000, forKind: 0)

        harness.viewModel.feedSource = .trending
        let refreshTask = Task { @MainActor in
            await harness.viewModel.refresh(force: true)
        }

        try await harness.waitForVisibleItem(id: trendingNote.id, timeout: 1.0)
        await refreshTask.value

        XCTAssertEqual(harness.viewModel.visibleItems.first?.displayName, "Slow Profile")
    }

    @MainActor
    func testTrendingIgnoresHiddenFollowingModeSelection() async throws {
        let trendingNote = makeEvent(
            id: hex("7"),
            pubkey: hex("8"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Top-level trending note",
            createdAt: 1_700_000_500
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                NostrFeedService.nostrArchivesTrendingRelayURL: [trendingNote]
            ]
        )

        harness.viewModel.mode = .postsAndReplies
        harness.viewModel.feedSource = .trending
        await harness.viewModel.refresh()

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [trendingNote.id])
    }

    @MainActor
    func testTrendingEmptyInitialLoadRetriesWithoutManualRefresh() async throws {
        let trendingNote = makeEvent(
            id: hex("6"),
            pubkey: hex("5"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Recovered trending note",
            createdAt: 1_700_000_600
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                NostrFeedService.nostrArchivesTrendingRelayURL: []
            ]
        )

        harness.viewModel.feedSource = .trending
        await harness.viewModel.refresh()
        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)

        await harness.setRemoteEvents([trendingNote], for: NostrFeedService.nostrArchivesTrendingRelayURL)

        try await harness.waitForVisibleItem(id: trendingNote.id, timeout: 3)
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

        harness.viewModel.feedSource = .network
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
        harness.viewModel.feedSource = .network
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
    func testRefreshKeepsOptimisticPublishedItemUntilConnectedSourcesEchoItBack() async throws {
        LocalPublicationStore.shared.clearForTesting()
        defer {
            LocalPublicationStore.shared.clearForTesting()
        }

        let harness = try HomeFeedViewModelHarness()
        let remoteNote = makeEvent(
            id: hex("9"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Relay row",
            createdAt: 1_700_000_210
        )
        let optimisticNote = makeEvent(
            id: hex("a"),
            pubkey: hex("c"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Optimistic note",
            createdAt: 1_700_000_320
        )

        await harness.setRemoteEvents([remoteNote])
        harness.viewModel.feedSource = .network
        let optimisticItem = FeedItem(event: optimisticNote, profile: nil)
        LocalPublicationStore.shared.registerPublishing(item: optimisticItem)
        harness.viewModel.insertOptimisticPublishedItem(optimisticItem)

        await harness.viewModel.refresh()

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [optimisticNote.id, remoteNote.id])
    }

    @MainActor
    func testRefreshCommitsFullyHydratedTopBatchBeforePublishingItems() async throws {
        let harness = try HomeFeedViewModelHarness()

        harness.viewModel.feedSource = .network
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
    func testFollowingHydrationRemovesRepostWhoseResolvedAuthorIsNotFollowed() async throws {
        let harness = try HomeFeedViewModelHarness()
        let currentUserPubkey = hex("1")
        let followedReposterPubkey = hex("2")
        let unfollowedTargetAuthorPubkey = hex("3")
        let targetEvent = makeEvent(
            id: hex("4"),
            pubkey: unfollowedTargetAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Target from an unfollowed author",
            createdAt: 1_700_000_600
        )
        let repostEvent = makeEvent(
            id: hex("5"),
            pubkey: followedReposterPubkey,
            kind: FeedKindFilters.repost,
            tags: [
                ["e", targetEvent.id],
                ["p", unfollowedTargetAuthorPubkey]
            ],
            content: "",
            createdAt: 1_700_000_610
        )
        let relayFollowList = makeEvent(
            id: hex("6"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedReposterPubkey]],
            content: "",
            createdAt: 1_700_000_620
        )

        await harness.setRemoteEvents([relayFollowList, repostEvent, targetEvent])
        harness.selectFollowingFeed(for: currentUserPubkey)

        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertTrue(harness.viewModel.items.isEmpty)
        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)
    }

    @MainActor
    func testSilentHydrationRemovesExistingRepostWhoseResolvedAuthorIsNotFollowed() async throws {
        let harness = try HomeFeedViewModelHarness()
        let currentUserPubkey = hex("7")
        let followedReposterPubkey = hex("8")
        let unfollowedTargetAuthorPubkey = hex("9")
        let targetEvent = makeEvent(
            id: hex("a"),
            pubkey: unfollowedTargetAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Resolved later from an unfollowed author",
            createdAt: 1_700_000_700
        )
        let repostEvent = makeEvent(
            id: hex("b"),
            pubkey: followedReposterPubkey,
            kind: FeedKindFilters.repost,
            tags: [
                ["e", targetEvent.id],
                ["p", unfollowedTargetAuthorPubkey]
            ],
            content: "",
            createdAt: 1_700_000_710
        )
        let relayFollowList = makeEvent(
            id: hex("c"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedReposterPubkey]],
            content: "",
            createdAt: 1_700_000_720
        )

        await harness.setRemoteEvents([relayFollowList, repostEvent])
        harness.selectFollowingFeed(for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [repostEvent.id])
        XCTAssertNil(harness.viewModel.visibleItems.first?.displayEventOverride)

        await harness.setRemoteEvents([relayFollowList, repostEvent, targetEvent])
        await harness.viewModel.refresh(silent: true, publishFetchedItems: false)

        XCTAssertTrue(harness.viewModel.items.isEmpty)
        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)
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

final class HomeFeedLoadingRegressionTests: XCTestCase {
    @MainActor
    func testFollowingNotesModeShowsTopLevelNotesFromFollowedAuthorsOnly() async throws {
        let currentUserPubkey = hex("a")
        let followedAuthorPubkey = hex("b")
        let unfollowedAuthorPubkey = hex("c")
        let replyTargetID = hex("d")
        let relayFollowList = makeEvent(
            id: hex("e"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_400
        )
        let followedReply = makeEvent(
            id: hex("f"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [
                ["e", replyTargetID, "", "root"],
                ["e", replyTargetID, "", "reply"]
            ],
            content: "Followed reply",
            createdAt: 1_700_000_420
        )
        let followedTopLevelNote = makeEvent(
            id: makeHexID(0x10),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Followed note",
            createdAt: 1_700_000_410
        )
        let unfollowedTopLevelNote = makeEvent(
            id: makeHexID(0x11),
            pubkey: unfollowedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Unfollowed note",
            createdAt: 1_700_000_430
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [
                    relayFollowList,
                    unfollowedTopLevelNote,
                    followedReply,
                    followedTopLevelNote
                ]
            ]
        )

        harness.selectFollowingFeed(for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.feedSource, .following)
        XCTAssertEqual(harness.viewModel.mode, .posts)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [followedTopLevelNote.id])
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
    func testInterestsFeedLoadsOnlySelectedHashtagItems() async throws {
        let matchingNote = makeEvent(
            id: hex("1"),
            pubkey: hex("2"),
            kind: FeedKindFilters.shortTextNote,
            tags: [["t", "swift"]],
            content: "Swift interest note",
            createdAt: 1_700_000_510
        )
        let otherNote = makeEvent(
            id: hex("3"),
            pubkey: hex("4"),
            kind: FeedKindFilters.shortTextNote,
            tags: [["t", "nostr"]],
            content: "Other interest note",
            createdAt: 1_700_000_520
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [otherNote, matchingNote]
            ]
        )

        harness.viewModel.updateInterestHashtags(["Swift"])
        harness.viewModel.selectFeedSource(.interests)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.feedSource, .interests)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [matchingNote.id])
    }

    @MainActor
    func testTrendingFeedLoadsRankedItems() async throws {
        let trendingNote = makeEvent(
            id: hex("5"),
            pubkey: hex("6"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Ranked trending note",
            createdAt: 1_700_000_530
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                NostrFeedService.nostrArchivesTrendingRelayURL: [trendingNote]
            ]
        )

        harness.viewModel.selectFeedSource(.trending)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.feedSource, .trending)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [trendingNote.id])
    }

    @MainActor
    func testTrendingPaginationBackfillsFromBroaderArchiveWindow() async throws {
        let todayNote = makeEvent(
            id: hex("5"),
            pubkey: hex("6"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Today trending note",
            createdAt: 1_700_000_530
        )
        let previousWindowNote = makeEvent(
            id: hex("7"),
            pubkey: hex("8"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Earlier trending note",
            createdAt: todayNote.createdAt - 86_400
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                NostrFeedService.nostrArchivesTrendingRelayURL: [todayNote],
                NostrFeedService.nostrArchivesTrendingSevenDayRelayURL: [todayNote, previousWindowNote]
            ]
        )

        harness.viewModel.selectFeedSource(.trending)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [todayNote.id])

        let currentItem = try XCTUnwrap(harness.viewModel.visibleItems.last)
        await harness.viewModel.loadMoreIfNeeded(currentItem: currentItem)

        XCTAssertEqual(
            harness.viewModel.visibleItems.map(\.id),
            [todayNote.id, previousWindowNote.id]
        )
    }

    @MainActor
    func testTrendingPaginationBackfillsWhenArchiveWindowIgnoresUntilCursor() async throws {
        let todayNote = makeEvent(
            id: hex("5"),
            pubkey: hex("6"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Today trending note",
            createdAt: 1_700_000_530
        )
        let previousWindowNote = makeEvent(
            id: hex("7"),
            pubkey: hex("8"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Earlier trending note behind an ignored cursor",
            createdAt: todayNote.createdAt - 86_400
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                NostrFeedService.nostrArchivesTrendingRelayURL: [todayNote],
                NostrFeedService.nostrArchivesTrendingSevenDayRelayURL: [todayNote, previousWindowNote]
            ],
            pageSize: 1
        )
        await harness.setIgnoringUntil(true, for: NostrFeedService.nostrArchivesTrendingSevenDayRelayURL)

        harness.viewModel.selectFeedSource(.trending)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [todayNote.id])

        let currentItem = try XCTUnwrap(harness.viewModel.visibleItems.last)
        await harness.viewModel.loadMoreIfNeeded(currentItem: currentItem)

        XCTAssertEqual(
            harness.viewModel.visibleItems.map(\.id),
            [todayNote.id, previousWindowNote.id]
        )
    }

    @MainActor
    func testPollsFeedShowsOnlyFollowedPolls() async throws {
        let currentUserPubkey = hex("7")
        let followedAuthorPubkey = hex("8")
        let unfollowedAuthorPubkey = hex("9")
        let previousPollsFeedVisible = AppSettingsStore.shared.pollsFeedVisible
        defer {
            AppSettingsStore.shared.pollsFeedVisible = previousPollsFeedVisible
        }
        AppSettingsStore.shared.pollsFeedVisible = true
        let relayFollowList = makeEvent(
            id: hex("a"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_540
        )
        let followedPoll = makeEvent(
            id: hex("b"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.poll,
            tags: [
                ["poll_option", "ios", "iOS"],
                ["poll_option", "android", "Android"],
                ["polltype", "singlechoice"]
            ],
            content: "Favorite client?",
            createdAt: 1_700_000_550
        )
        let followedNote = makeEvent(
            id: hex("c"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Plain note",
            createdAt: 1_700_000_560
        )
        let unfollowedPoll = makeEvent(
            id: hex("d"),
            pubkey: unfollowedAuthorPubkey,
            kind: FeedKindFilters.poll,
            tags: [
                ["poll_option", "tea", "Tea"],
                ["poll_option", "coffee", "Coffee"],
                ["polltype", "singlechoice"]
            ],
            content: "Unfollowed poll",
            createdAt: 1_700_000_570
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [
                    relayFollowList,
                    unfollowedPoll,
                    followedNote,
                    followedPoll
                ]
            ]
        )

        harness.viewModel.updatePollsFeedVisibility(true)
        harness.selectFeedSource(.polls, for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.feedSource, .polls)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [followedPoll.id])
    }

    @MainActor
    func testNewsFeedMergesRelayAuthorAndHashtagSourcesWithoutDuplicates() async throws {
        let currentUserPubkey = hex("d")
        AppSettingsStore.shared.configure(accountPubkey: currentUserPubkey)
        let previousNewsRelayURLs = AppSettingsStore.shared.newsRelayURLs
        let previousNewsAuthorPubkeys = AppSettingsStore.shared.newsAuthorPubkeys
        let previousNewsHashtags = AppSettingsStore.shared.newsHashtags
        defer {
            AppSettingsStore.shared.setNewsRelayURLs(previousNewsRelayURLs)
            AppSettingsStore.shared.setNewsAuthorPubkeys(previousNewsAuthorPubkeys)
            AppSettingsStore.shared.setNewsHashtags(previousNewsHashtags)
        }

        let authorPubkey = hex("e")
        let authorReadRelayURL = URL(string: "wss://merged-news-author.example")!
        let relayListEvent = makeEvent(
            id: hex("f"),
            pubkey: authorPubkey,
            kind: 10_002,
            tags: [["r", authorReadRelayURL.absoluteString, "read"]],
            content: "",
            createdAt: 1_700_000_580
        )
        let relayNewsNote = makeEvent(
            id: makeHexID(0x12),
            pubkey: hex("1"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Relay news note",
            createdAt: 1_700_000_590
        )
        let authorNewsNote = makeEvent(
            id: makeHexID(0x13),
            pubkey: authorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Author news note",
            createdAt: 1_700_000_600
        )
        let hashtagNewsNote = makeEvent(
            id: makeHexID(0x14),
            pubkey: hex("2"),
            kind: FeedKindFilters.shortTextNote,
            tags: [["t", "macro"]],
            content: "Hashtag news note",
            createdAt: 1_700_000_610
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [
                    relayListEvent,
                    relayNewsNote,
                    authorNewsNote,
                    hashtagNewsNote
                ],
                authorReadRelayURL: [authorNewsNote]
            ]
        )

        AppSettingsStore.shared.setNewsRelayURLs([defaultHomeRelayURL])
        AppSettingsStore.shared.setNewsAuthorPubkeys([authorPubkey])
        AppSettingsStore.shared.setNewsHashtags(["macro"])

        harness.viewModel.updateCurrentUserPubkey(currentUserPubkey)
        harness.viewModel.selectFeedSource(.news)
        try await harness.waitUntilIdle(timeout: 4)

        XCTAssertEqual(harness.viewModel.feedSource, .news)
        XCTAssertEqual(
            harness.viewModel.visibleItems.map(\.id),
            [hashtagNewsNote.id, authorNewsNote.id, relayNewsNote.id]
        )
    }

    @MainActor
    func testBufferedRevealMergesAllNewItemsWithoutChoosingAScrollTarget() async throws {
        let initialNote = makeEvent(
            id: hex("1"),
            pubkey: hex("a"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Existing row",
            createdAt: 1_700_000_100
        )
        let newestBufferedNote = makeEvent(
            id: hex("2"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Newest buffered row",
            createdAt: 1_700_000_300
        )
        let earliestBufferedNote = makeEvent(
            id: hex("3"),
            pubkey: hex("c"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Earliest buffered row",
            createdAt: 1_700_000_200
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [initialNote]
            ]
        )

        harness.viewModel.feedSource = .network
        await harness.viewModel.loadIfNeeded()
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [initialNote.id])

        await harness.setRemoteEvents([newestBufferedNote, earliestBufferedNote, initialNote])
        await harness.viewModel.refresh(silent: true, publishFetchedItems: false)

        XCTAssertEqual(
            harness.viewModel.visibleBufferedNewItems.map(\.id),
            [newestBufferedNote.id, earliestBufferedNote.id]
        )

        harness.viewModel.showBufferedNewItems()

        XCTAssertTrue(harness.viewModel.visibleBufferedNewItems.isEmpty)
        XCTAssertEqual(
            harness.viewModel.visibleItems.map(\.id),
            [newestBufferedNote.id, earliestBufferedNote.id, initialNote.id]
        )
    }

    @MainActor
    func testSilentArticleRefreshReplacesVisibleEditEvenWhenReplacementIsHidden() async throws {
        let currentUserPubkey = hex("a")
        let followedAuthorPubkey = hex("b")
        let relayFollowList = makeEvent(
            id: hex("c"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", followedAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_500
        )
        let originalArticle = makeEvent(
            id: hex("d"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [
                ["d", "replaceable-article"],
                ["title", "Original article"]
            ],
            content: "Original body",
            createdAt: 1_700_000_400
        )
        let hiddenEdit = makeEvent(
            id: hex("e"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.longFormArticle,
            tags: [
                ["d", "replaceable-article"],
                ["title", "Hidden edit"],
                ["t", "nsfw"]
            ],
            content: "Edited body",
            createdAt: 1_700_000_600
        )
        let previousHideNSFW = AppSettingsStore.shared.hideNSFWContent
        defer {
            AppSettingsStore.shared.hideNSFWContent = previousHideNSFW
        }
        AppSettingsStore.shared.hideNSFWContent = true

        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [relayFollowList, originalArticle]
            ]
        )
        harness.selectFeedSource(.articles, for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [originalArticle.id])

        await harness.setRemoteEvents([relayFollowList, hiddenEdit])
        await harness.viewModel.refresh(silent: true, publishFetchedItems: false)

        XCTAssertEqual(harness.viewModel.items.map(\.id), [hiddenEdit.id])
        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)
        XCTAssertTrue(harness.viewModel.visibleBufferedNewItems.isEmpty)
    }

    @MainActor
    func testSilentFollowingRefreshDropsUnfollowedRowsAndBuffersNewFollowings() async throws {
        let currentUserPubkey = hex("1")
        let originalAuthorPubkey = hex("2")
        let newlyFollowedAuthorPubkey = hex("3")
        let originalFollowList = makeEvent(
            id: hex("4"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", originalAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_100
        )
        let updatedFollowList = makeEvent(
            id: hex("5"),
            pubkey: currentUserPubkey,
            kind: 3,
            tags: [["p", newlyFollowedAuthorPubkey]],
            content: "",
            createdAt: 1_700_000_400
        )
        let originalNote = makeEvent(
            id: hex("6"),
            pubkey: originalAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "No longer followed",
            createdAt: 1_700_000_200
        )
        let newlyFollowedNote = makeEvent(
            id: hex("7"),
            pubkey: newlyFollowedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "New following",
            createdAt: 1_700_000_300
        )
        let harness = try HomeFeedViewModelHarness(
            initialRelayEvents: [
                defaultHomeRelayURL: [originalFollowList, originalNote, newlyFollowedNote]
            ]
        )
        harness.selectFollowingFeed(for: currentUserPubkey)
        try await harness.waitUntilIdle(timeout: 4)
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [originalNote.id])

        await harness.setRemoteEvents([updatedFollowList, originalNote, newlyFollowedNote])
        await harness.viewModel.refresh(silent: true, publishFetchedItems: false)

        XCTAssertTrue(harness.viewModel.visibleItems.isEmpty)
        XCTAssertEqual(
            harness.viewModel.visibleBufferedNewItems.map(\.id),
            [newlyFollowedNote.id]
        )

        harness.viewModel.showBufferedNewItems()
        XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [newlyFollowedNote.id])
    }

    func testBufferedPartitionRetainsAlternateModeRowsWithoutRepeatingModeration() {
        let currentUserPubkey = hex("a")
        let followedAuthorPubkey = hex("b")
        let mutedAuthorPubkey = hex("c")
        let spamAuthorPubkey = hex("d")
        let rootID = hex("f")
        let visibleNote = makeEvent(
            id: hex("1"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Visible top-level note",
            createdAt: 1_700_000_500
        )
        let alternateModeReply = makeEvent(
            id: hex("2"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [["e", rootID, "", "reply"]],
            content: "Reply retained for Replies mode",
            createdAt: 1_700_000_400
        )
        let nsfwNote = makeEvent(
            id: hex("3"),
            pubkey: followedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [["t", "nsfw"]],
            content: "Hidden by current presentation settings",
            createdAt: 1_700_000_300
        )
        let mutedNote = makeEvent(
            id: hex("4"),
            pubkey: mutedAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Muted author",
            createdAt: 1_700_000_200
        )
        let manualSpamNote = makeEvent(
            id: hex("5"),
            pubkey: spamAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Manual spam author",
            createdAt: 1_700_000_100
        )
        let configuration = HomeFeedVisibilityFilter.Configuration(
            feedSource: .following,
            mode: .posts,
            showKinds: FeedKindFilters.allOptionKinds,
            mediaOnly: false,
            ignoreMediaOnly: false,
            followingPubkeys: [followedAuthorPubkey, mutedAuthorPubkey, spamAuthorPubkey],
            currentUserPubkey: currentUserPubkey,
            mutedConversationIDs: [],
            muteSnapshot: MuteFilterSnapshot(
                mutedPubkeys: [mutedAuthorPubkey],
                exactMutedWords: [],
                phraseMutedWords: [],
                hidesEncodedSpam: true
            ),
            hideNSFW: true,
            spamMarkedPubkeys: [spamAuthorPubkey],
            spamSafelistedPubkeys: []
        )
        let partition = HomeFeedVisibilityFilter.partitionBufferedItems(
            [visibleNote, alternateModeReply, nsfwNote, mutedNote, manualSpamNote]
                .map { FeedItem(event: $0, profile: nil) },
            configuration: configuration
        )

        XCTAssertEqual(
            partition.retained.map(\.id),
            [visibleNote.id, alternateModeReply.id, nsfwNote.id]
        )
        XCTAssertEqual(partition.visible.map(\.id), [visibleNote.id])
        XCTAssertEqual(
            HomeFeedVisibilityFilter.visibleRetainedItems(
                partition.retained,
                configuration: configuration
            ).map(\.id),
            partition.visible.map(\.id)
        )
    }
}

@MainActor
final class ThreadDetailViewModelTests: XCTestCase {
    func testRefreshKeepsLocallyPublishedReplyVisibleWhenSpamContextIsStale() async {
        let settings = AppSettingsStore.shared
        let previousSpamReplyFilterEnabled = settings.spamReplyFilterEnabled
        let localAuthorPubkey = hex("c")

        LocalPublicationStore.shared.clearForTesting()
        settings.spamReplyFilterEnabled = true
        settings.addSpamFilterMarkedPubkey(localAuthorPubkey)
        defer {
            LocalPublicationStore.shared.clearForTesting()
            settings.removeSpamFilterMarkedPubkey(localAuthorPubkey)
            settings.spamReplyFilterEnabled = previousSpamReplyFilterEnabled
        }

        let rootEvent = makeEvent(
            id: hex("3"),
            pubkey: hex("a"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Root note",
            createdAt: 1_700_000_000
        )
        let replyEvent = makeEvent(
            id: hex("4"),
            pubkey: localAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [
                ["e", rootEvent.id, "", "root"],
                ["e", rootEvent.id, "", "reply"]
            ],
            content: "Locally signed reply",
            createdAt: 1_700_000_001
        )
        let viewModel = ThreadDetailViewModel(
            rootItem: FeedItem(event: rootEvent, profile: nil),
            relayURL: defaultHomeRelayURL,
            service: NostrFeedService(relayClient: HomeFeedTestRelayClient(eventsByRelay: [:]))
        )

        // Deliberately leave the current-account spam context unconfigured. A notification-pushed
        // detail can briefly be in this state, but a locally signed publication is still trusted.
        viewModel.appendLocalReply(FeedItem(event: replyEvent, profile: nil))
        LocalPublicationStore.shared.markPosted(eventID: replyEvent.id)
        await viewModel.refresh()

        XCTAssertTrue(
            viewModel.replies.contains { $0.id == replyEvent.id },
            "A locally published reply must never disappear into the spam bucket during refresh."
        )
        XCTAssertFalse(viewModel.spamReplies.contains { $0.id == replyEvent.id })
    }

    func testRefreshKeepsLocalReplyWhenConnectedSourcesHaveNotEchoedIt() async {
        LocalPublicationStore.shared.clearForTesting()
        defer {
            LocalPublicationStore.shared.clearForTesting()
        }

        let rootEvent = makeEvent(
            id: hex("1"),
            pubkey: hex("a"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Root note",
            createdAt: 1_700_000_000
        )
        let replyEvent = makeEvent(
            id: hex("2"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [
                ["e", rootEvent.id, "", "root"],
                ["e", rootEvent.id, "", "reply"]
            ],
            content: "Instant reply",
            createdAt: 1_700_000_001
        )
        let viewModel = ThreadDetailViewModel(
            rootItem: FeedItem(event: rootEvent, profile: nil),
            relayURL: defaultHomeRelayURL,
            service: NostrFeedService(relayClient: HomeFeedTestRelayClient(eventsByRelay: [:]))
        )

        viewModel.configureSpamFilter(currentUserPubkey: replyEvent.pubkey, followedPubkeys: [])
        viewModel.appendLocalReply(FeedItem(event: replyEvent, profile: nil))
        await waitForReply(id: replyEvent.id, in: viewModel)

        await viewModel.refresh()

        XCTAssertTrue(
            viewModel.replies.contains { $0.id == replyEvent.id },
            "A locally appended reply must remain visible when refresh returns no fetched copy yet."
        )
    }

    func testPostedReplySurvivesRepeatedRefreshAndReopeningBeforeRelayEcho() async {
        LocalPublicationStore.shared.clearForTesting()
        defer {
            LocalPublicationStore.shared.clearForTesting()
        }

        let rootEvent = makeEvent(
            id: hex("5"),
            pubkey: hex("a"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Notification thread root",
            createdAt: 1_700_000_100
        )
        let replyEvent = makeEvent(
            id: hex("6"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [
                ["e", rootEvent.id, "", "root"],
                ["e", rootEvent.id, "", "reply"]
            ],
            content: "Posted reply awaiting relay echo",
            createdAt: 1_700_000_101
        )
        let service = NostrFeedService(
            relayClient: HomeFeedTestRelayClient(eventsByRelay: [:])
        )
        let firstViewModel = ThreadDetailViewModel(
            rootItem: FeedItem(event: rootEvent, profile: nil),
            relayURL: defaultHomeRelayURL,
            service: service
        )

        firstViewModel.configureSpamFilter(
            currentUserPubkey: replyEvent.pubkey,
            followedPubkeys: []
        )
        firstViewModel.appendLocalReply(FeedItem(event: replyEvent, profile: nil))
        LocalPublicationStore.shared.markPosted(eventID: replyEvent.id)

        await firstViewModel.refresh()
        await firstViewModel.refresh()

        XCTAssertEqual(
            firstViewModel.replies.filter { $0.id == replyEvent.id }.count,
            1,
            "Publish completion and repeated stale refreshes must keep exactly one visible reply."
        )
        XCTAssertEqual(
            LocalPublicationStore.shared.record(for: replyEvent.id)?.state,
            .posted
        )

        let reopenedViewModel = ThreadDetailViewModel(
            rootItem: FeedItem(event: rootEvent, profile: nil),
            relayURL: defaultHomeRelayURL,
            service: service
        )
        reopenedViewModel.configureSpamFilter(
            currentUserPubkey: replyEvent.pubkey,
            followedPubkeys: []
        )

        await reopenedViewModel.loadIfNeeded()

        XCTAssertEqual(
            reopenedViewModel.replies.filter { $0.id == replyEvent.id }.count,
            1,
            "Reopening the notification thread must retain a posted local reply before relay echo."
        )
    }

    func testRelayEchoMergesWithPostedReplyWithoutDuplicatingIt() async {
        LocalPublicationStore.shared.clearForTesting()
        defer {
            LocalPublicationStore.shared.clearForTesting()
        }

        let rootEvent = makeEvent(
            id: hex("7"),
            pubkey: hex("a"),
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Thread root",
            createdAt: 1_700_000_200
        )
        let replyEvent = makeEvent(
            id: hex("8"),
            pubkey: hex("b"),
            kind: FeedKindFilters.shortTextNote,
            tags: [["e", rootEvent.id, "", "root"]],
            content: "Reply echoed by a source",
            createdAt: 1_700_000_201
        )
        let localItem = FeedItem(event: replyEvent, profile: nil)
        LocalPublicationStore.shared.registerPublishing(item: localItem)
        LocalPublicationStore.shared.markPosted(eventID: replyEvent.id)

        let viewModel = ThreadDetailViewModel(
            rootItem: FeedItem(event: rootEvent, profile: nil),
            relayURL: defaultHomeRelayURL,
            service: NostrFeedService(
                relayClient: HomeFeedTestRelayClient(eventsByRelay: [
                    defaultHomeRelayURL: [replyEvent]
                ])
            )
        )
        viewModel.configureSpamFilter(
            currentUserPubkey: replyEvent.pubkey,
            followedPubkeys: []
        )

        await viewModel.refresh()

        XCTAssertEqual(
            viewModel.replies.filter { $0.id == replyEvent.id }.count,
            1,
            "The fetched source copy must merge into the stable local event ID instead of adding a second row."
        )
        XCTAssertEqual(
            LocalPublicationStore.shared.record(for: replyEvent.id)?.state,
            .posted
        )
    }

    func testInvalidatedSpamScoreIsRescoredWithoutRevealingReply() async {
        let settings = AppSettingsStore.shared
        let previousSpamReplyFilterEnabled = settings.spamReplyFilterEnabled
        settings.spamReplyFilterEnabled = true
        defer {
            settings.spamReplyFilterEnabled = previousSpamReplyFilterEnabled
        }

        let rootAuthorPubkey = makeHexID(9_100)
        let replyAuthorPubkey = makeHexID(9_101)
        let rootEvent = makeEvent(
            id: makeHexID(9_102),
            pubkey: rootAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [],
            content: "Thread root",
            createdAt: 1_700_000_300
        )
        let replyEvent = makeEvent(
            id: makeHexID(9_103),
            pubkey: replyAuthorPubkey,
            kind: FeedKindFilters.shortTextNote,
            tags: [
                ["e", rootEvent.id, "", "root"],
                ["e", rootEvent.id, "", "reply"]
            ],
            content: "Reply classified as spam",
            createdAt: 1_700_000_301
        )
        let scorer = ThreadSpamTestScorer(score: 0.9)
        let viewModel = ThreadDetailViewModel(
            rootItem: FeedItem(event: rootEvent, profile: nil),
            relayURL: defaultHomeRelayURL,
            service: NostrFeedService(
                relayClient: HomeFeedTestRelayClient(eventsByRelay: [
                    defaultHomeRelayURL: [replyEvent]
                ])
            ),
            spamScorer: scorer
        )
        viewModel.configureSpamFilter(
            currentUserPubkey: rootAuthorPubkey,
            followedPubkeys: []
        )

        await viewModel.refresh()
        await waitForSpamScoreCallCount(1, scorer: scorer)
        await waitForSpamReply(id: replyEvent.id, in: viewModel)
        viewModel.toggleSpamRepliesExpanded()

        await scorer.invalidateAndHoldNextScore(pubkey: replyAuthorPubkey)
        await viewModel.refresh()
        await waitForSpamScoreCallCount(2, scorer: scorer)

        XCTAssertFalse(viewModel.replies.contains { $0.id == replyEvent.id })
        XCTAssertTrue(viewModel.spamReplies.contains { $0.id == replyEvent.id })
        XCTAssertTrue(viewModel.isSpamRepliesExpanded)

        await scorer.releaseHeldScores()
        await waitForPostRescoreCacheRead(scorer: scorer)

        XCTAssertFalse(viewModel.replies.contains { $0.id == replyEvent.id })
        XCTAssertTrue(viewModel.spamReplies.contains { $0.id == replyEvent.id })
        XCTAssertTrue(viewModel.isSpamRepliesExpanded)
    }

    private func waitForReply(
        id: String,
        in viewModel: ThreadDetailViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            if viewModel.replies.contains(where: { $0.id == id }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for local reply to appear.", file: file, line: line)
    }

    private func waitForSpamReply(
        id: String,
        in viewModel: ThreadDetailViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if viewModel.spamReplies.contains(where: { $0.id == id }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the reply to enter the spam bucket.", file: file, line: line)
    }

    private func waitForSpamScoreCallCount(
        _ expectedCount: Int,
        scorer: ThreadSpamTestScorer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if await scorer.scoreCallCount() >= expectedCount {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for spam rescoring.", file: file, line: line)
    }

    private func waitForPostRescoreCacheRead(
        scorer: ThreadSpamTestScorer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if await scorer.cachedScoreHitCount() > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the post-rescore bucket rebuild.", file: file, line: line)
    }
}

private let defaultHomeRelayURL = URL(string: "wss://relay.example.com")!
private let secondaryHomeRelayURL = URL(string: "wss://relay-two.example.com")!

private actor ThreadSpamTestScorer: NSpamAuthorScoring {
    private let score: Float
    private var cachedScores: [String: Float] = [:]
    private var callCount = 0
    private var cacheHitCount = 0
    private var shouldHoldNextScore = false
    private var heldScoreContinuations: [CheckedContinuation<Void, Never>] = []

    init(score: Float) {
        self.score = score
    }

    func cachedScore(
        for pubkey: String,
        markedSpamPubkeys: [String],
        notSpamPubkeys: [String]
    ) async -> Float? {
        guard let score = cachedScores[normalized(pubkey)] else { return nil }
        cacheHitCount += 1
        return score
    }

    func scoreAuthor(
        pubkey: String,
        markedSpamPubkeys: [String],
        notSpamPubkeys: [String],
        seedNotes: [NSpamNoteInput]
    ) async -> Float? {
        callCount += 1
        if shouldHoldNextScore {
            shouldHoldNextScore = false
            await withCheckedContinuation { continuation in
                heldScoreContinuations.append(continuation)
            }
        }

        cachedScores[normalized(pubkey)] = score
        return score
    }

    func invalidateAndHoldNextScore(pubkey: String) {
        cachedScores[normalized(pubkey)] = nil
        cacheHitCount = 0
        shouldHoldNextScore = true
    }

    func releaseHeldScores() {
        let continuations = heldScoreContinuations
        heldScoreContinuations = []
        continuations.forEach { $0.resume() }
    }

    func scoreCallCount() -> Int {
        callCount
    }

    func cachedScoreHitCount() -> Int {
        cacheHitCount
    }

    private func normalized(_ pubkey: String) -> String {
        pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private actor HomeFeedTestRelayClient: NostrRelayEventFetching {
    private var eventsByRelay: [String: [Flow.NostrEvent]]
    private var delaysByRelay: [String: UInt64] = [:]
    private var delaysByKind: [Int: UInt64] = [:]
    private var ignoreUntilRelayKeys = Set<String>()

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

    func setIgnoringUntil(_ isIgnoringUntil: Bool, for relayURL: URL) {
        let relayKey = canonicalRelayString(relayURL)
        if isIgnoringUntil {
            ignoreUntilRelayKeys.insert(relayKey)
        } else {
            ignoreUntilRelayKeys.remove(relayKey)
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
        let until = ignoreUntilRelayKeys.contains(canonicalRelayURL) ? nil : filter.until
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
            seenEventStore: seenEventStore
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

    func setIgnoringUntil(_ isIgnoringUntil: Bool, for relayURL: URL) async {
        await relayClient.setIgnoringUntil(isIgnoringUntil, for: relayURL)
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
            if !viewModel.isLoading && !viewModel.isLoadingMore && !viewModel.isBootstrappingFeed {
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
