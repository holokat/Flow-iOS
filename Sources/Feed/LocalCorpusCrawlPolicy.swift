import Foundation

enum LocalCorpusCrawlTier: String, CaseIterable, Identifiable, Sendable {
    case tierA
    case tierB
    case tierC

    var id: String { rawValue }

    var kinds: [Int] {
        switch self {
        case .tierA:
            return [0, 3, 10_002, 1, 6, 16, 1_111, 1_244, 30_023]
        case .tierB:
            return [20, 21, 22, 1_222, 1_068, 9_802, 31_987, 36_787]
        case .tierC:
            return [7]
        }
    }
}

struct LocalCorpusCrawlPolicy: Equatable, Sendable {
    let hopCount: Int
    let requiresWiFiForForegroundCrawl: Bool
    let tierAAuthorPageLimit: Int
    let tierBAuthorPageLimit: Int
    let articleAuthorPageLimit: Int
    let extendedGraphAuthorPageLimit: Int
    let extendedGraphArticlePageLimit: Int
    let referenceResolutionBatchSize: Int
    let backgroundRefreshBatchSize: Int
    let replaceableRefreshBatchSize: Int
    let directFollowBurstPassCount: Int
    let directFollowArticleBurstPassCount: Int
    let extendedGraphAuthorBatchSize: Int
    let replaceableAuthorPageLimit: Int
    let foregroundRelayTimeout: TimeInterval
    let backgroundRelayTimeout: TimeInterval

    var tierAKinds: [Int] { LocalCorpusCrawlTier.tierA.kinds }
    var tierBKinds: [Int] { LocalCorpusCrawlTier.tierB.kinds }
    var tierCKinds: [Int] { LocalCorpusCrawlTier.tierC.kinds }
    var replaceableKinds: [Int] { [0, 3, 10_002] }
    var coreContentKinds: [Int] { [1, 6, 16, 1_111, 1_244] }
    var articleKinds: [Int] { [30_023] }
    var relayFetchMode: RelayFetchMode { .allRelays }

    static let `default` = LocalCorpusCrawlPolicy(
        hopCount: 2,
        requiresWiFiForForegroundCrawl: false,
        tierAAuthorPageLimit: 512,
        tierBAuthorPageLimit: 64,
        articleAuthorPageLimit: 128,
        extendedGraphAuthorPageLimit: 128,
        extendedGraphArticlePageLimit: 64,
        referenceResolutionBatchSize: 512,
        backgroundRefreshBatchSize: 128,
        replaceableRefreshBatchSize: 256,
        directFollowBurstPassCount: 6,
        directFollowArticleBurstPassCount: 4,
        extendedGraphAuthorBatchSize: 96,
        replaceableAuthorPageLimit: 32,
        foregroundRelayTimeout: 20,
        backgroundRelayTimeout: 15
    )
}
