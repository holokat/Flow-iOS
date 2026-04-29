import XCTest
@testable import Flow

final class CrawlRelayPlannerTests: XCTestCase {
    func testDirectFollowsAreAlwaysIncluded() async {
        let provider = FakeWebOfTrustFollowingsProvider(
            directFollowings: ["alice", "bob"]
        )
        let planner = CrawlRelayPlanner(followingsProvider: provider)

        let plan = await planner.makePlan(
            accountPubkey: "self",
            readRelayURLs: [url("wss://read.example")],
            hopCount: 1,
            cachedRelayHintsByPubkey: [:],
            fallbackRelayURLs: [url("wss://fallback.example")]
        )

        XCTAssertEqual(plan.orderedPubkeys, ["alice", "bob"])
    }

    func testTwoHopExpansionUsesCachedFollowSnapshotsBeforeNetworkFetches() async {
        let provider = FakeWebOfTrustFollowingsProvider(
            directFollowings: ["alice", "bob"],
            cachedFollowingsByPubkey: [
                "alice": ["carol"]
            ],
            fetchedFollowingsByPubkey: [
                "bob": ["dave"]
            ]
        )
        let planner = CrawlRelayPlanner(
            expander: WebOfTrustExpander(maxTrustedPubkeys: 50, expansionBatchSize: 2),
            followingsProvider: provider
        )

        let plan = await planner.makePlan(
            accountPubkey: "self",
            readRelayURLs: [url("wss://read.example")],
            hopCount: 2,
            cachedRelayHintsByPubkey: [:],
            fallbackRelayURLs: [url("wss://fallback.example")]
        )

        XCTAssertEqual(plan.orderedPubkeys, ["alice", "bob", "carol", "dave"])
        let fetchedPubkeys = await provider.fetchedPubkeys
        XCTAssertEqual(fetchedPubkeys, ["bob"])
    }

    func testRelayPlanningPrefersAuthorAndCachedHints() async {
        let provider = FakeWebOfTrustFollowingsProvider(
            directFollowings: ["alice"]
        )
        let planner = CrawlRelayPlanner(followingsProvider: provider)

        let plan = await planner.makePlan(
            accountPubkey: "self",
            readRelayURLs: [url("wss://read.example")],
            hopCount: 1,
            cachedRelayHintsByPubkey: [
                "alice": [url("wss://follow-hint.example")]
            ],
            authorRelayURLsByPubkey: [
                "alice": [url("wss://author-hint.example")]
            ],
            fallbackRelayURLs: [url("wss://fallback.example")]
        )

        XCTAssertEqual(
            plan.relayURLs(for: "alice"),
            [
                url("wss://author-hint.example"),
                url("wss://follow-hint.example"),
                url("wss://read.example"),
                url("wss://fallback.example")
            ]
        )
    }

    func testPlannerAppendsBroadFallbackRelaysWhenHintsAreSparse() async {
        let provider = FakeWebOfTrustFollowingsProvider(
            directFollowings: ["alice"]
        )
        let planner = CrawlRelayPlanner(followingsProvider: provider)
        let fallbackRelayURLs = [
            url("wss://fallback-1.example"),
            url("wss://fallback-2.example")
        ]

        let plan = await planner.makePlan(
            accountPubkey: "self",
            readRelayURLs: [],
            hopCount: 1,
            cachedRelayHintsByPubkey: [:],
            fallbackRelayURLs: fallbackRelayURLs
        )

        XCTAssertEqual(plan.relayURLs(for: "alice"), fallbackRelayURLs)
        XCTAssertEqual(plan.broadFallbackRelayURLs, fallbackRelayURLs)
    }

    private func url(_ value: String) -> URL {
        URL(string: value)!
    }
}

private actor FakeWebOfTrustFollowingsProvider: WebOfTrustFollowingsProviding {
    let directFollowings: [String]
    let cachedFollowingsByPubkey: [String: [String]]
    let fetchedFollowingsByPubkey: [String: [String]]
    private(set) var fetchedPubkeys: [String] = []

    init(
        directFollowings: [String],
        cachedFollowingsByPubkey: [String: [String]] = [:],
        fetchedFollowingsByPubkey: [String: [String]] = [:]
    ) {
        self.directFollowings = directFollowings
        self.cachedFollowingsByPubkey = cachedFollowingsByPubkey
        self.fetchedFollowingsByPubkey = fetchedFollowingsByPubkey
    }

    func directFollowings(for accountPubkey: String) async -> [String] {
        directFollowings
    }

    func cachedFollowings(for pubkey: String) async -> [String]? {
        cachedFollowingsByPubkey[pubkey]
    }

    func fetchFollowings(for pubkey: String, relayURLs: [URL]) async -> [String] {
        fetchedPubkeys.append(pubkey)
        return fetchedFollowingsByPubkey[pubkey] ?? []
    }
}
