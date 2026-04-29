import XCTest
@testable import Flow

final class LocalCorpusCrawlPolicyTests: XCTestCase {
    func testTierAIncludesDeepTextAndReplaceableKinds() {
        XCTAssertEqual(
            Set(LocalCorpusCrawlTier.tierA.kinds),
            Set([0, 3, 10_002, 1, 6, 16, 1_111, 1_244, 30_023])
        )
    }

    func testTierBIncludesMediumDepthMediaAndDiscoveryKinds() {
        XCTAssertEqual(
            Set(LocalCorpusCrawlTier.tierB.kinds),
            Set([20, 21, 22, 1_222, 1_068, 9_802, 31_987, 36_787])
        )
    }

    func testTierCIncludesShallowReactionKind() {
        XCTAssertEqual(LocalCorpusCrawlTier.tierC.kinds, [7])
    }

    func testDefaultPolicyUsesAggressiveDirectFollowBudgets() {
        let policy = LocalCorpusCrawlPolicy.default

        XCTAssertEqual(policy.hopCount, 2)
        XCTAssertFalse(policy.requiresWiFiForForegroundCrawl)
        XCTAssertEqual(policy.relayFetchMode, .allRelays)
        XCTAssertGreaterThanOrEqual(policy.tierAAuthorPageLimit, 512)
        XCTAssertGreaterThanOrEqual(policy.tierBAuthorPageLimit, 64)
        XCTAssertLessThan(policy.tierBAuthorPageLimit, policy.tierAAuthorPageLimit)
        XCTAssertGreaterThanOrEqual(policy.referenceResolutionBatchSize, 512)
        XCTAssertGreaterThanOrEqual(policy.backgroundRefreshBatchSize, 128)
        XCTAssertGreaterThanOrEqual(policy.foregroundRelayTimeout, 20)
        XCTAssertGreaterThanOrEqual(policy.backgroundRelayTimeout, 15)
    }
}
