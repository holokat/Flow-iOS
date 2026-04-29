import Foundation

struct CrawlRelayPlan: Equatable, Sendable {
    let orderedPubkeys: [String]
    let relayURLsByPubkey: [String: [URL]]
    let broadFallbackRelayURLs: [URL]

    func relayURLs(for pubkey: String) -> [URL] {
        let normalizedPubkey = CrawlRelayPlanner.normalizePubkey(pubkey)
        return relayURLsByPubkey[normalizedPubkey] ?? broadFallbackRelayURLs
    }
}

struct CrawlRelayPlanner {
    private let expander: WebOfTrustExpander
    private let followingsProvider: any WebOfTrustFollowingsProviding

    init(
        expander: WebOfTrustExpander = WebOfTrustExpander(),
        followingsProvider: any WebOfTrustFollowingsProviding
    ) {
        self.expander = expander
        self.followingsProvider = followingsProvider
    }

    func makePlan(
        accountPubkey: String,
        readRelayURLs: [URL],
        hopCount: Int,
        cachedRelayHintsByPubkey: [String: [URL]],
        authorRelayURLsByPubkey: [String: [URL]] = [:],
        fallbackRelayURLs: [URL]
    ) async -> CrawlRelayPlan {
        let request = WebOfTrustExpansionRequest(
            accountPubkey: Self.normalizePubkey(accountPubkey),
            relayURLs: normalizedRelayURLs(readRelayURLs),
            hopCount: hopCount
        )
        let orderedPubkeys = await expander.expand(
            request: request,
            followingsProvider: followingsProvider
        )

        return makePlan(
            orderedPubkeys: orderedPubkeys,
            readRelayURLs: readRelayURLs,
            cachedRelayHintsByPubkey: cachedRelayHintsByPubkey,
            authorRelayURLsByPubkey: authorRelayURLsByPubkey,
            fallbackRelayURLs: fallbackRelayURLs
        )
    }

    func makePlan(
        orderedPubkeys: [String],
        readRelayURLs: [URL],
        cachedRelayHintsByPubkey: [String: [URL]],
        authorRelayURLsByPubkey: [String: [URL]] = [:],
        fallbackRelayURLs: [URL]
    ) -> CrawlRelayPlan {
        let normalizedReadRelayURLs = normalizedRelayURLs(readRelayURLs)
        let normalizedFallbackRelayURLs = normalizedRelayURLs(fallbackRelayURLs)
        let normalizedAuthorRelayURLs = normalizeRelayDictionary(authorRelayURLsByPubkey)
        let normalizedCachedRelayHints = normalizeRelayDictionary(cachedRelayHintsByPubkey)

        var relayURLsByPubkey: [String: [URL]] = [:]
        for pubkey in orderedPubkeys {
            relayURLsByPubkey[pubkey] = normalizedRelayURLs(
                (normalizedAuthorRelayURLs[pubkey] ?? [])
                + (normalizedCachedRelayHints[pubkey] ?? [])
                + normalizedReadRelayURLs
                + normalizedFallbackRelayURLs
            )
        }

        return CrawlRelayPlan(
            orderedPubkeys: orderedPubkeys,
            relayURLsByPubkey: relayURLsByPubkey,
            broadFallbackRelayURLs: normalizedFallbackRelayURLs
        )
    }

    private func normalizeRelayDictionary(_ dictionary: [String: [URL]]) -> [String: [URL]] {
        var normalized: [String: [URL]] = [:]
        for (pubkey, relayURLs) in dictionary {
            let normalizedPubkey = Self.normalizePubkey(pubkey)
            guard !normalizedPubkey.isEmpty else { continue }
            normalized[normalizedPubkey] = normalizedRelayURLs(relayURLs)
        }
        return normalized
    }

    private func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        expander.normalizedRelayURLs(relayURLs)
    }

    static func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
