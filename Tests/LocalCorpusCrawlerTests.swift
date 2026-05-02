import XCTest
@testable import Flow

@MainActor
final class LocalCorpusCrawlerTests: XCTestCase {
    func testCrawlerUsesTwoHopWebOfTrustAndPersistsTierACursors() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerTwoHop")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cursorStore = CrawlCursorStore(rootURL: rootURL)
        let relayHints = FakeRelayHintCache()
        let feedService = FakeLocalCorpusCrawlingFeedService()
        let accountPubkey = hex(1)
        let follow1 = hex(2)
        let follow2 = hex(3)

        await feedService.setTierAWindows([
            follow1: [makeEvent(id: hex(21), pubkey: follow1, kind: 1, createdAt: 1_700_000_100)],
            follow2: [makeEvent(id: hex(22), pubkey: follow2, kind: 30_023, createdAt: 1_700_000_050)]
        ])

        let pathMonitor = FlowNetworkPathMonitor(
            pathMonitor: FakeFlowNetworkPathMonitoring(
                currentPath: .init(isSatisfied: true, usesWiFi: true)
            )
        )
        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: relayHints,
            cursorStore: cursorStore,
            networkPathMonitor: pathMonitor,
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: [follow1]],
                cached: [follow1: [follow2]]
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "two-hop")
        )

        crawler.configure(
            accountPubkey: accountPubkey,
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: true,
                backgroundRefreshEnabled: true,
                hopCount: 2,
                deepMediaBackfillEnabled: false
            ),
            isSceneActive: true
        )

        await crawler.crawlNow()

        let replaceableBatches = await feedService.replaceableAuthorBatches()
        let coreRequests = await feedService.requests(matchingKinds: [1, 6, 16, 1_111, 1_244])
        let articleRequests = await feedService.requests(matchingKinds: [30_023])
        let cursorSnapshot = await cursorStore.snapshot()

        XCTAssertEqual(crawler.diagnostics.plannedAuthorCount, 2)
        XCTAssertEqual(Set(replaceableBatches.flatMap(\.self)), Set([follow1, follow2]))
        XCTAssertTrue(coreRequests.contains(where: { $0.authors == [follow1] }))
        XCTAssertTrue(articleRequests.contains(where: { $0.authors == [follow2] }))
        XCTAssertTrue(coreRequests.allSatisfy { $0.relayFetchMode == .allRelays })
        XCTAssertTrue(articleRequests.allSatisfy { $0.relayFetchMode == .allRelays })
        XCTAssertEqual(
            cursorSnapshot.untilCursorByTierAndPubkey[LocalCorpusCrawlCursorTier.tierA.rawValue]?[follow1],
            1_700_000_099
        )
        XCTAssertEqual(
            cursorSnapshot.untilCursorByTierAndPubkey[LocalCorpusCrawlCursorTier.tierAArticles.rawValue]?[follow2],
            1_700_000_049
        )
    }

    func testCrawlerSkipsForegroundPassWhenWiFiIsRequiredAndUnavailable() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerWiFiGate")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let feedService = FakeLocalCorpusCrawlingFeedService()
        let pathMonitor = FlowNetworkPathMonitor(
            pathMonitor: FakeFlowNetworkPathMonitoring(
                currentPath: .init(isSatisfied: true, usesWiFi: false)
            )
        )
        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: FakeRelayHintCache(),
            cursorStore: CrawlCursorStore(rootURL: rootURL),
            networkPathMonitor: pathMonitor,
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [hex(1): [hex(2)]],
                cached: [:]
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "wifi-gate")
        )

        crawler.configure(
            accountPubkey: hex(1),
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: true,
                backgroundRefreshEnabled: true,
                hopCount: 2,
                deepMediaBackfillEnabled: false
            ),
            isSceneActive: true
        )

        await crawler.crawlNow()

        let replaceableBatches = await feedService.replaceableAuthorBatches()
        let tierARequests = await feedService.tierARequests()

        XCTAssertEqual(replaceableBatches.count, 0)
        XCTAssertEqual(tierARequests.count, 0)
        XCTAssertFalse(crawler.diagnostics.isForegroundRunning)
        XCTAssertFalse(crawler.diagnostics.isUsingWiFi)
    }

    func testCrawlerFallsBackToCachedFollowListForDirectFollowPriority() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerCachedDirectPriority")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let accountPubkey = hex(1)
        let cachedDirectFollow = hex(2)
        let extendedAuthor = hex(3)
        let feedService = FakeLocalCorpusCrawlingFeedService()
        await feedService.setTierAWindows([
            cachedDirectFollow: [makeEvent(id: hex(211), pubkey: cachedDirectFollow, kind: 1, createdAt: 1_700_000_111)],
            extendedAuthor: [makeEvent(id: hex(212), pubkey: extendedAuthor, kind: 1, createdAt: 1_700_000_011)]
        ])

        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: FakeRelayHintCache(),
            cursorStore: CrawlCursorStore(rootURL: rootURL),
            networkPathMonitor: FlowNetworkPathMonitor(
                pathMonitor: FakeFlowNetworkPathMonitoring(
                    currentPath: .init(isSatisfied: true, usesWiFi: true)
                )
            ),
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: []],
                cached: [accountPubkey: [cachedDirectFollow], cachedDirectFollow: [extendedAuthor]]
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "cached-direct-priority")
        )

        crawler.configure(
            accountPubkey: accountPubkey,
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: false,
                backgroundRefreshEnabled: true,
                hopCount: 2,
                deepMediaBackfillEnabled: false
            ),
            isSceneActive: true
        )

        await crawler.crawlNow()

        let coreRequests = await feedService.requests(matchingKinds: [1, 6, 16, 1_111, 1_244])
        XCTAssertTrue(coreRequests.contains(where: { $0.authors == [cachedDirectFollow] }))
    }

    func testCrawlerUsesSharedAuthorRelayPlanAfterRefreshingRelayDirectory() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerRelayDirectory")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let accountPubkey = hex(1)
        let author = hex(2)
        let authorReadRelayURL = URL(string: "wss://author-read.example")!
        let authorWriteRelayURL = URL(string: "wss://author-write.example")!
        let hintRelayURL = URL(string: "wss://hint.example")!
        let fallbackRelayURL = URL(string: "wss://fallback.example")!

        let relayHints = FakeRelayHintCache()
        await relayHints.storeHints([author: [hintRelayURL]])

        let feedService = FakeLocalCorpusCrawlingFeedService()
        await feedService.setReplaceableEventsByAuthor([
            author: [
                makeEvent(
                    id: hex(300),
                    pubkey: author,
                    kind: 10_002,
                    tags: [
                        ["r", authorReadRelayURL.absoluteString, "read"],
                        ["r", authorWriteRelayURL.absoluteString, "write"]
                    ],
                    createdAt: 1_700_000_300
                )
            ]
        ])
        await feedService.setTierAWindows([
            author: [makeEvent(id: hex(301), pubkey: author, kind: 1, createdAt: 1_700_000_200)]
        ])

        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: relayHints,
            cursorStore: CrawlCursorStore(rootURL: rootURL),
            networkPathMonitor: FlowNetworkPathMonitor(
                pathMonitor: FakeFlowNetworkPathMonitoring(
                    currentPath: .init(isSatisfied: true, usesWiFi: true)
                )
            ),
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: [author]],
                cached: [:]
            ),
            fallbackRelayURLs: [fallbackRelayURL],
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "relay-directory")
        )

        crawler.configure(
            accountPubkey: accountPubkey,
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: false,
                backgroundRefreshEnabled: true,
                hopCount: 1,
                deepMediaBackfillEnabled: false
            ),
            isSceneActive: true
        )

        await crawler.crawlNow()

        let coreRequests = await feedService.requests(matchingKinds: [1, 6, 16, 1_111, 1_244])
        let authorRequest = try XCTUnwrap(coreRequests.first(where: { $0.authors == [author] }))

        XCTAssertEqual(
            authorRequest.relayURLs.map(\.absoluteString),
            [
                "wss://author-write.example/",
                "wss://hint.example/",
                "wss://relay.example.com/",
                "wss://fallback.example/"
            ]
        )
    }

    func testCrawlerQueuesMissingReferencesAndClearsThemAfterResolution() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerReferences")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cursorStore = CrawlCursorStore(rootURL: rootURL)
        let feedService = FakeLocalCorpusCrawlingFeedService()
        let missingReferenceID = hex(9_999)
        let author = hex(2)
        await feedService.setTierAWindows([
            author: [
                makeEvent(
                    id: hex(50),
                    pubkey: author,
                    kind: 1,
                    tags: [["e", missingReferenceID]],
                    createdAt: 1_700_000_200
                )
            ]
        ])

        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: FakeRelayHintCache(),
            cursorStore: cursorStore,
            networkPathMonitor: FlowNetworkPathMonitor(
                pathMonitor: FakeFlowNetworkPathMonitoring(
                    currentPath: .init(isSatisfied: true, usesWiFi: true)
                )
            ),
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [hex(1): [author]],
                cached: [:]
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "references")
        )

        crawler.configure(
            accountPubkey: hex(1),
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: true,
                backgroundRefreshEnabled: true,
                hopCount: 1,
                deepMediaBackfillEnabled: false
            ),
            isSceneActive: true
        )

        await crawler.crawlNow()
        let queuedAfterFirstPass = await cursorStore.queuedMissingReferenceIdentifiers()
        XCTAssertEqual(queuedAfterFirstPass, [missingReferenceID])

        await feedService.setResolvedReferenceEvents([
            missingReferenceID: makeEvent(
                id: missingReferenceID,
                pubkey: hex(4),
                kind: 1,
                createdAt: 1_700_000_250
            )
        ])

        await crawler.crawlNow()

        let queuedAfterSecondPass = await cursorStore.queuedMissingReferenceIdentifiers()
        let requestedReferenceIdentifiers = await feedService.referenceRequestIdentifiers()

        XCTAssertEqual(queuedAfterSecondPass, [])
        XCTAssertTrue(requestedReferenceIdentifiers.contains(missingReferenceID))
        XCTAssertEqual(crawler.diagnostics.resolvedReferenceCount, 1)
    }

    func testBackgroundRefreshRunsShortLatestTierAPassAndBoundsQueuedReferences() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerBackgroundRefresh")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cursorStore = CrawlCursorStore(rootURL: rootURL)
        let feedService = FakeLocalCorpusCrawlingFeedService()
        let accountPubkey = hex(1)
        let authors = [hex(2), hex(3), hex(4)]
        let queuedReferenceIdentifiers = [hex(9_001), hex(9_002)]

        await cursorStore.setUntilCursor(1_699_999_999, for: authors[0], tier: .tierA)
        await cursorStore.enqueueMissingReferenceIdentifiers(queuedReferenceIdentifiers)
        await feedService.setTierAWindows([
            authors[0]: [makeEvent(id: hex(101), pubkey: authors[0], kind: 1, createdAt: 1_700_000_300)],
            authors[1]: [makeEvent(id: hex(102), pubkey: authors[1], kind: 30_023, createdAt: 1_700_000_200)],
            authors[2]: [makeEvent(id: hex(103), pubkey: authors[2], kind: 1, createdAt: 1_700_000_100)]
        ])
        await feedService.setResolvedReferenceEvents([
            queuedReferenceIdentifiers[0]: makeEvent(
                id: queuedReferenceIdentifiers[0],
                pubkey: hex(8),
                kind: 1,
                createdAt: 1_700_000_400
            )
        ])

        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: FakeRelayHintCache(),
            cursorStore: cursorStore,
            networkPathMonitor: FlowNetworkPathMonitor(
                pathMonitor: FakeFlowNetworkPathMonitoring(
                    currentPath: .init(isSatisfied: true, usesWiFi: true)
                )
            ),
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: authors],
                cached: [:]
            ),
            crawlPolicy: LocalCorpusCrawlPolicy(
                hopCount: 2,
                requiresWiFiForForegroundCrawl: true,
                tierAAuthorPageLimit: 8,
                tierBAuthorPageLimit: 3,
                articleAuthorPageLimit: 6,
                extendedGraphAuthorPageLimit: 4,
                extendedGraphArticlePageLimit: 3,
                referenceResolutionBatchSize: 1,
                backgroundRefreshBatchSize: 2,
                replaceableRefreshBatchSize: 0,
                directFollowBurstPassCount: 1,
                directFollowArticleBurstPassCount: 1,
                extendedGraphAuthorBatchSize: 0,
                replaceableAuthorPageLimit: 4,
                foregroundRelayTimeout: 12,
                backgroundRelayTimeout: 8
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "background-refresh")
        )

        crawler.configure(
            accountPubkey: accountPubkey,
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: true,
                backgroundRefreshEnabled: true,
                hopCount: 2,
                deepMediaBackfillEnabled: true
            ),
            isSceneActive: false
        )

        let didComplete = await crawler.performBackgroundRefresh()

        let replaceableBatches = await feedService.replaceableAuthorBatches()
        let coreRequests = await feedService.requests(matchingKinds: [1, 6, 16, 1_111, 1_244])
        let articleRequests = await feedService.requests(matchingKinds: [30_023])
        let mediaRequests = await feedService.requests(matchingKinds: LocalCorpusCrawlTier.tierB.kinds)
        let requestedReferenceIdentifiers = await feedService.referenceRequestIdentifiers()
        let remainingQueuedReferences = await cursorStore.queuedMissingReferenceIdentifiers()
        let cursorSnapshot = await cursorStore.snapshot()

        XCTAssertTrue(didComplete)
        XCTAssertEqual(replaceableBatches, [Array(authors.prefix(2))])
        XCTAssertEqual(coreRequests.map(\.authors), [Array(authors.prefix(2))])
        XCTAssertEqual(articleRequests.map(\.authors), [Array(authors.prefix(2))])
        XCTAssertNil(coreRequests.first?.untilByAuthor[authors[0]] ?? nil)
        XCTAssertEqual(mediaRequests.count, 0)
        XCTAssertTrue(requestedReferenceIdentifiers.contains(queuedReferenceIdentifiers[0]))
        XCTAssertEqual(remainingQueuedReferences, [queuedReferenceIdentifiers[1]])
        XCTAssertEqual(
            cursorSnapshot.untilCursorByTierAndPubkey[LocalCorpusCrawlCursorTier.tierA.rawValue]?[authors[0]],
            1_699_999_999
        )
        XCTAssertNotNil(crawler.diagnostics.lastBackgroundRefreshAt)
    }

    func testBackgroundRefreshStopsWhenExpirationTriggers() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerBackgroundExpiration")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let feedService = FakeLocalCorpusCrawlingFeedService()
        let accountPubkey = hex(1)
        let author = hex(2)
        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: FakeRelayHintCache(),
            cursorStore: CrawlCursorStore(rootURL: rootURL),
            networkPathMonitor: FlowNetworkPathMonitor(
                pathMonitor: FakeFlowNetworkPathMonitoring(
                    currentPath: .init(isSatisfied: true, usesWiFi: true)
                )
            ),
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: [author]],
                cached: [:]
            ),
            crawlPolicy: LocalCorpusCrawlPolicy(
                hopCount: 1,
                requiresWiFiForForegroundCrawl: true,
                tierAAuthorPageLimit: 8,
                tierBAuthorPageLimit: 3,
                articleAuthorPageLimit: 6,
                extendedGraphAuthorPageLimit: 4,
                extendedGraphArticlePageLimit: 3,
                referenceResolutionBatchSize: 8,
                backgroundRefreshBatchSize: 1,
                replaceableRefreshBatchSize: 0,
                directFollowBurstPassCount: 1,
                directFollowArticleBurstPassCount: 1,
                extendedGraphAuthorBatchSize: 0,
                replaceableAuthorPageLimit: 4,
                foregroundRelayTimeout: 12,
                backgroundRelayTimeout: 8
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "background-expiration")
        )

        crawler.configure(
            accountPubkey: accountPubkey,
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: true,
                backgroundRefreshEnabled: true,
                hopCount: 1,
                deepMediaBackfillEnabled: true
            ),
            isSceneActive: false
        )

        let expirationGate = ExpirationGate(allowances: 2)
        let didComplete = await crawler.performBackgroundRefresh {
            expirationGate.shouldContinue
        }

        let replaceableBatches = await feedService.replaceableAuthorBatches()
        let coreRequests = await feedService.requests(matchingKinds: [1, 6, 16, 1_111, 1_244])
        let articleRequests = await feedService.requests(matchingKinds: [30_023])
        let mediaRequests = await feedService.requests(matchingKinds: LocalCorpusCrawlTier.tierB.kinds)

        XCTAssertFalse(didComplete)
        XCTAssertEqual(replaceableBatches, [[author]])
        XCTAssertEqual(coreRequests.count, 0)
        XCTAssertEqual(articleRequests.count, 0)
        XCTAssertEqual(mediaRequests.count, 0)
        XCTAssertNil(crawler.diagnostics.lastBackgroundRefreshAt)
    }

    func testForegroundCrawlPrioritizesDirectFollowsWithDedicatedArticleBackfill() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerDirectFollowPriority")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cursorStore = CrawlCursorStore(rootURL: rootURL)
        let feedService = FakeLocalCorpusCrawlingFeedService()
        let accountPubkey = hex(1)
        let directFollowA = hex(2)
        let directFollowB = hex(3)
        let secondHop = hex(4)

        await feedService.setTierAWindows([
            directFollowA: [
                makeEvent(id: hex(101), pubkey: directFollowA, kind: 1, createdAt: 1_700_000_300),
                makeEvent(id: hex(102), pubkey: directFollowA, kind: 30_023, createdAt: 1_700_000_200)
            ],
            directFollowB: [
                makeEvent(id: hex(103), pubkey: directFollowB, kind: 1, createdAt: 1_700_000_150),
                makeEvent(id: hex(104), pubkey: directFollowB, kind: 30_023, createdAt: 1_700_000_125)
            ],
            secondHop: [
                makeEvent(id: hex(105), pubkey: secondHop, kind: 1, createdAt: 1_700_000_100)
            ]
        ])

        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: FakeRelayHintCache(),
            cursorStore: cursorStore,
            networkPathMonitor: FlowNetworkPathMonitor(
                pathMonitor: FakeFlowNetworkPathMonitoring(
                    currentPath: .init(isSatisfied: true, usesWiFi: true)
                )
            ),
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: [directFollowA, directFollowB]],
                cached: [
                    directFollowA: [secondHop],
                    directFollowB: []
                ]
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: makeDefaults(prefix: "direct-follow-priority")
        )

        crawler.configure(
            accountPubkey: accountPubkey,
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: true,
                backgroundRefreshEnabled: true,
                hopCount: 2,
                deepMediaBackfillEnabled: false
            ),
            isSceneActive: true
        )

        await crawler.crawlNow()

        let replaceableBatches = await feedService.replaceableAuthorBatches()
        let directArticleRequests = await feedService.requests(matchingKinds: [30_023])
        let directCoreRequests = await feedService.requests(matchingKinds: [1, 6, 16, 1_111, 1_244])

        XCTAssertEqual(replaceableBatches.first, [directFollowA, directFollowB, secondHop])
        XCTAssertTrue(directCoreRequests.contains(where: { $0.authors == [directFollowA, directFollowB] }))
        XCTAssertTrue(directArticleRequests.contains(where: { $0.authors == [directFollowA, directFollowB] }))
    }

    func testCrawlerPersistsLastForegroundPassAcrossRelaunch() async throws {
        let rootURL = try makeRootURL(prefix: "LocalCorpusCrawlerPersistedPass")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let defaultsSuiteName = "LocalCorpusCrawlerPersistedPass-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let accountPubkey = hex(1)
        let author = hex(2)
        let feedService = FakeLocalCorpusCrawlingFeedService()
        await feedService.setTierAWindows([
            author: [makeEvent(id: hex(501), pubkey: author, kind: 1, createdAt: 1_700_000_400)]
        ])

        let pathMonitor = FlowNetworkPathMonitor(
            pathMonitor: FakeFlowNetworkPathMonitoring(
                currentPath: .init(isSatisfied: true, usesWiFi: true)
            )
        )

        let crawler = LocalCorpusCrawler(
            feedService: feedService,
            relayHintCache: FakeRelayHintCache(),
            cursorStore: CrawlCursorStore(rootURL: rootURL),
            networkPathMonitor: pathMonitor,
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: [author]],
                cached: [:]
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: defaults
        )

        crawler.configure(
            accountPubkey: accountPubkey,
            readRelayURLs: [relayURL],
            settings: .init(
                isEnabled: true,
                wifiOnly: false,
                backgroundRefreshEnabled: true,
                hopCount: 1,
                deepMediaBackfillEnabled: false
            ),
            isSceneActive: true
        )

        await crawler.crawlNow()

        let firstPassDate = try XCTUnwrap(crawler.diagnostics.lastForegroundPassAt)

        let restoredCrawler = LocalCorpusCrawler(
            feedService: FakeLocalCorpusCrawlingFeedService(),
            relayHintCache: FakeRelayHintCache(),
            cursorStore: CrawlCursorStore(rootURL: rootURL),
            networkPathMonitor: pathMonitor,
            followingsProvider: FakeWebOfTrustFollowingsProvider(
                direct: [accountPubkey: [author]],
                cached: [:]
            ),
            shouldAutoStartForegroundLoop: false,
            defaults: defaults
        )

        XCTAssertEqual(restoredCrawler.diagnostics.lastForegroundPassAt, firstPassDate)
    }

    private func makeRootURL(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults(prefix: String) -> UserDefaults {
        let suiteName = "LocalCorpusCrawlerTests-\(prefix)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeEvent(
        id: String,
        pubkey: String,
        kind: Int,
        tags: [[String]] = [],
        content: String = "event",
        createdAt: Int
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

    private func hex(_ value: Int) -> String {
        String(format: "%064x", value)
    }
}

private let relayURL = URL(string: "wss://relay.example.com")!

private actor FakeRelayHintCache: ProfileRelayHintCaching, AuthorRelayDirectoryCaching {
    private var entriesByPubkey: [String: AuthorRelayDirectoryEntry] = [:]

    func storeHints(_ hintsByPubkey: [String : [URL]]) {
        for (pubkey, relayURLs) in hintsByPubkey {
            let normalizedPubkey = pubkey.lowercased()
            let existingEntry = entriesByPubkey[normalizedPubkey] ?? AuthorRelayDirectoryEntry(
                readRelayURLs: [],
                writeRelayURLs: [],
                hintRelayURLs: [],
                refreshedAt: nil
            )
            entriesByPubkey[normalizedPubkey] = AuthorRelayDirectoryEntry(
                readRelayURLs: existingEntry.readRelayURLs,
                writeRelayURLs: existingEntry.writeRelayURLs,
                hintRelayURLs: relayURLs,
                refreshedAt: existingEntry.refreshedAt
            )
        }
    }

    func prioritizedRelayURLs(for pubkeys: [String], baseRelayURLs: [URL]) -> [URL] {
        var ordered = baseRelayURLs
        var seen = Set(baseRelayURLs.map { $0.absoluteString.lowercased() })

        for pubkey in pubkeys {
            for relayURL in entriesByPubkey[pubkey.lowercased()]?.hintRelayURLs ?? [] {
                let key = relayURL.absoluteString.lowercased()
                guard seen.insert(key).inserted else { continue }
                ordered.append(relayURL)
            }
        }

        return ordered
    }

    func relayHints(for pubkeys: [String]) -> [String : [URL]] {
        var results: [String: [URL]] = [:]
        for pubkey in pubkeys {
            let normalized = pubkey.lowercased()
            if let hints = entriesByPubkey[normalized]?.hintRelayURLs {
                results[normalized] = hints
            }
        }
        return results
    }

    func entry(for pubkey: String) -> AuthorRelayDirectoryEntry? {
        entriesByPubkey[pubkey.lowercased()]
    }

    func entries(for pubkeys: [String]) -> [String : AuthorRelayDirectoryEntry] {
        var results: [String: AuthorRelayDirectoryEntry] = [:]
        for pubkey in pubkeys {
            let normalized = pubkey.lowercased()
            if let entry = entriesByPubkey[normalized] {
                results[normalized] = entry
            }
        }
        return results
    }

    func store(entry: AuthorRelayDirectoryEntry, for pubkey: String) {
        let normalizedPubkey = pubkey.lowercased()
        let existingEntry = entriesByPubkey[normalizedPubkey]
        entriesByPubkey[normalizedPubkey] = AuthorRelayDirectoryEntry(
            readRelayURLs: entry.readRelayURLs,
            writeRelayURLs: entry.writeRelayURLs,
            hintRelayURLs: entry.hintRelayURLs.isEmpty
                ? (existingEntry?.hintRelayURLs ?? [])
                : entry.hintRelayURLs,
            refreshedAt: entry.refreshedAt ?? existingEntry?.refreshedAt
        )
    }
}

private struct FakeWebOfTrustFollowingsProvider: WebOfTrustFollowingsProviding {
    let direct: [String: [String]]
    let cached: [String: [String]]

    func directFollowings(for accountPubkey: String) async -> [String] {
        direct[accountPubkey.lowercased()] ?? []
    }

    func cachedFollowings(for pubkey: String) async -> [String]? {
        cached[pubkey.lowercased()]
    }

    func fetchFollowings(for pubkey: String, relayURLs: [URL]) async -> [String] {
        cached[pubkey.lowercased()] ?? []
    }
}

private actor FakeLocalCorpusCrawlingFeedService: LocalCorpusCrawlingFeedServing {
    struct TierRequest: Equatable {
        let relayURLs: [URL]
        let authors: [String]
        let kinds: [Int]
        let untilByAuthor: [String: Int?]
        let relayFetchMode: RelayFetchMode
    }

    private var replaceableEventsByAuthor: [String: [NostrEvent]] = [:]
    private var tierAWindows: [String: [NostrEvent]] = [:]
    private var tierBWindows: [String: [NostrEvent]] = [:]
    private var replaceableBatchesStorage: [[String]] = []
    private var allRequestsStorage: [TierRequest] = []
    private var tierARequestsStorage: [TierRequest] = []
    private var tierBRequestsStorage: [TierRequest] = []
    private var resolvedReferenceEventsByIdentifier: [String: NostrEvent] = [:]
    private var referenceRequestIdentifiersStorage: [String] = []

    func setReplaceableEventsByAuthor(_ eventsByAuthor: [String: [NostrEvent]]) {
        replaceableEventsByAuthor = eventsByAuthor
    }

    func setTierAWindows(_ windows: [String: [NostrEvent]]) {
        tierAWindows = windows
    }

    func setTierBWindows(_ windows: [String: [NostrEvent]]) {
        tierBWindows = windows
    }

    func setResolvedReferenceEvents(_ eventsByIdentifier: [String: NostrEvent]) {
        resolvedReferenceEventsByIdentifier = eventsByIdentifier
    }

    func replaceableAuthorBatches() -> [[String]] {
        replaceableBatchesStorage
    }

    func tierARequests() -> [TierRequest] {
        tierARequestsStorage
    }

    func tierBRequests() -> [TierRequest] {
        tierBRequestsStorage
    }

    func referenceRequestIdentifiers() -> [String] {
        referenceRequestIdentifiersStorage
    }

    func requests(matchingKinds kinds: [Int]) -> [TierRequest] {
        let signature = Set(kinds)
        return allRequestsStorage.filter { Set($0.kinds) == signature }
    }

    func fetchFollowings(
        relayURLs: [URL],
        pubkey: String,
        relayFetchMode: RelayFetchMode
    ) async throws -> [String] {
        []
    }

    func cachedFollowListSnapshot(pubkey: String) async -> FollowListSnapshot? {
        nil
    }

    func fetchProfiles(
        relayURLs: [URL],
        pubkeys: [String],
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [String : NostrProfile] {
        [:]
    }

    func refreshLatestReplaceablesForAuthors(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        perAuthorLimit: Int,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [NostrEvent] {
        replaceableBatchesStorage.append(authors)
        return authors.flatMap { replaceableEventsByAuthor[$0] ?? [] }
    }

    func fetchOlderAuthorWindows(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        untilByAuthor: [String : Int?],
        perAuthorLimit: Int,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [String : [NostrEvent]] {
        let request = TierRequest(
            relayURLs: relayURLs,
            authors: authors,
            kinds: kinds,
            untilByAuthor: untilByAuthor,
            relayFetchMode: relayFetchMode
        )
        allRequestsStorage.append(request)
        if Set(kinds) == Set(LocalCorpusCrawlTier.tierA.kinds) {
            tierARequestsStorage.append(request)
            return tierAWindows.filter { authors.contains($0.key) }
        }

        tierBRequestsStorage.append(request)
        let combined = tierBWindows.filter { authors.contains($0.key) }
        if !combined.isEmpty {
            return combined
        }

        let kindsSet = Set(kinds)
        return Dictionary(uniqueKeysWithValues: authors.map { author in
            let tierAEvents = tierAWindows[author] ?? []
            let tierBEventsForAuthor = tierBWindows[author] ?? []
            let filtered = (tierAEvents + tierBEventsForAuthor)
                .filter { kindsSet.contains($0.kind) }
            return (author, filtered)
        })
    }

    func fetchReferencedEvents(
        references: [NostrEventReferencePointer],
        baseRelayURLs: [URL],
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [NostrEventReferencePointer : NostrEvent] {
        referenceRequestIdentifiersStorage.append(contentsOf: references.map(\.normalizedIdentifier))
        var resolved: [NostrEventReferencePointer: NostrEvent] = [:]
        for reference in references {
            if let event = resolvedReferenceEventsByIdentifier[reference.normalizedIdentifier] {
                resolved[reference] = event
            }
        }
        return resolved
    }
}

private final class FakeFlowNetworkPathMonitoring: FlowNetworkPathMonitoring, @unchecked Sendable {
    var currentPath: FlowNetworkPathSnapshot
    var pathUpdateHandler: (@Sendable (FlowNetworkPathSnapshot) -> Void)?

    init(currentPath: FlowNetworkPathSnapshot) {
        self.currentPath = currentPath
    }

    func start(queue: DispatchQueue) {}
}

private final class ExpirationGate {
    private var remainingAllowances: Int

    init(allowances: Int) {
        self.remainingAllowances = allowances
    }

    var shouldContinue: Bool {
        guard remainingAllowances > 0 else { return false }
        remainingAllowances -= 1
        return true
    }
}
