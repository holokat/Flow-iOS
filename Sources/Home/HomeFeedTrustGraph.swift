import Foundation

protocol WebOfTrustFollowingsProviding: Sendable {
    func directFollowings(for accountPubkey: String) async -> [String]
    func cachedFollowings(for pubkey: String) async -> [String]?
    func fetchFollowings(for pubkey: String, relayURLs: [URL]) async -> [String]
}

struct WebOfTrustExpansionRequest: Equatable, Sendable {
    let accountPubkey: String
    let relayURLs: [URL]
    let hopCount: Int
}

struct WebOfTrustExpander: Sendable {
    let maxTrustedPubkeys: Int
    let expansionBatchSize: Int

    init(
        maxTrustedPubkeys: Int = 1_200,
        expansionBatchSize: Int = 12
    ) {
        self.maxTrustedPubkeys = maxTrustedPubkeys
        self.expansionBatchSize = expansionBatchSize
    }

    func expand(
        request: WebOfTrustExpansionRequest,
        followingsProvider: any WebOfTrustFollowingsProviding
    ) async -> [String] {
        var visited: Set<String> = [normalizePubkey(request.accountPubkey)]
        var trusted: [String] = []

        var frontier = await followingsProvider.directFollowings(for: request.accountPubkey)
        if frontier.isEmpty {
            frontier = await followingsProvider.fetchFollowings(
                for: request.accountPubkey,
                relayURLs: request.relayURLs
            )
        }

        frontier = normalizedOrderedPubkeys(frontier).filter { visited.insert($0).inserted }
        trusted.append(contentsOf: frontier)

        guard request.hopCount > 1, !frontier.isEmpty else {
            return Array(trusted.prefix(maxTrustedPubkeys))
        }

        for _ in 2...request.hopCount {
            guard !Task.isCancelled, !frontier.isEmpty, trusted.count < maxTrustedPubkeys else { break }

            var nextFrontier: [String] = []
            for batch in chunked(frontier, into: expansionBatchSize) {
                guard !Task.isCancelled, trusted.count < maxTrustedPubkeys else { break }

                let fetchedFollowings = await withTaskGroup(of: (Int, [String]).self) { group in
                    for (index, pubkey) in batch.enumerated() {
                        group.addTask {
                            if let cached = await followingsProvider.cachedFollowings(for: pubkey) {
                                return (index, cached)
                            }
                            let fetched = await followingsProvider.fetchFollowings(
                                for: pubkey,
                                relayURLs: request.relayURLs
                            )
                            return (index, fetched)
                        }
                    }

                    var aggregated = Array(repeating: [String](), count: batch.count)
                    for await (index, followings) in group {
                        aggregated[index] = followings
                    }
                    return aggregated
                }

                for followings in fetchedFollowings {
                    for pubkey in followings {
                        let normalized = normalizePubkey(pubkey)
                        guard !normalized.isEmpty, visited.insert(normalized).inserted else { continue }
                        trusted.append(normalized)
                        nextFrontier.append(normalized)

                        if trusted.count >= maxTrustedPubkeys {
                            break
                        }
                    }

                    if trusted.count >= maxTrustedPubkeys {
                        break
                    }
                }
            }

            frontier = nextFrontier
        }

        return trusted
    }

    func normalizedOrderedPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys {
            let normalized = normalizePubkey(pubkey)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func chunked(_ values: [String], into size: Int) -> [[String]] {
        guard size > 0, !values.isEmpty else { return [] }

        var result: [[String]] = []
        result.reserveCapacity((values.count + size - 1) / size)

        var index = 0
        while index < values.count {
            let nextIndex = min(index + size, values.count)
            result.append(Array(values[index..<nextIndex]))
            index = nextIndex
        }

        return result
    }
}

private struct WebOfTrustServiceFollowingsProvider: WebOfTrustFollowingsProviding {
    let service: NostrFeedService
    let expander: WebOfTrustExpander

    func directFollowings(for accountPubkey: String) async -> [String] {
        let followedPubkeys = await MainActor.run {
            Array(FollowStore.shared.followedPubkeys)
        }
        return expander.normalizedOrderedPubkeys(followedPubkeys)
            .filter { $0 != expander.normalizePubkey(accountPubkey) }
    }

    func cachedFollowings(for pubkey: String) async -> [String]? {
        await service.cachedFollowListSnapshot(pubkey: pubkey)?.followedPubkeys
    }

    func fetchFollowings(for pubkey: String, relayURLs: [URL]) async -> [String] {
        (try? await service.fetchFollowings(relayURLs: relayURLs, pubkey: pubkey)) ?? []
    }
}

@MainActor
final class WebOfTrustStore: ObservableObject {
    static let shared = WebOfTrustStore()

    @Published private(set) var orderedTrustedPubkeys: [String] = []
    @Published private(set) var isLoading = false

    private struct Session: Equatable {
        let accountPubkey: String
        let relayURLs: [URL]
        let hopCount: Int
    }

    private let service: NostrFeedService
    private let cache: WebOfTrustGraphCache
    private let expander: WebOfTrustExpander
    private var session: Session?
    private var rebuildTask: Task<Void, Never>?

    private static let cacheMaxAge: TimeInterval = 60 * 60 * 6

    init(
        service: NostrFeedService = NostrFeedService(),
        cache: WebOfTrustGraphCache = .shared,
        expander: WebOfTrustExpander = WebOfTrustExpander()
    ) {
        self.service = service
        self.cache = cache
        self.expander = expander
    }

    deinit {
        rebuildTask?.cancel()
    }

    func configure(accountPubkey: String?, relayURLs: [URL], hopCount: Int) {
        let normalizedAccount = expander.normalizePubkey(accountPubkey)
        let normalizedRelays = expander.normalizedRelayURLs(relayURLs)
        let clampedHops = AppSettingsStore.clampedWebOfTrustHops(hopCount)

        guard !normalizedAccount.isEmpty, !normalizedRelays.isEmpty else {
            session = nil
            rebuildTask?.cancel()
            orderedTrustedPubkeys = []
            isLoading = false
            return
        }

        let nextSession = Session(
            accountPubkey: normalizedAccount,
            relayURLs: normalizedRelays,
            hopCount: clampedHops
        )

        guard nextSession != session else { return }

        session = nextSession
        orderedTrustedPubkeys = directFollowings(for: normalizedAccount)
        isLoading = true

        Task { [weak self] in
            await self?.applyCachedGraphIfAvailable(for: nextSession)
        }

        rebuildGraph(for: nextSession)
    }

    func refresh() {
        guard let session else { return }
        orderedTrustedPubkeys = directFollowings(for: session.accountPubkey)
        isLoading = true
        rebuildGraph(for: session)
    }

    private func rebuildGraph(for session: Session) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            let graph = await self.buildGraph(for: session)
            guard !Task.isCancelled else { return }

            await self.cache.storePubkeys(graph, for: self.cacheKey(for: session))

            await MainActor.run {
                guard self.session == session else { return }
                self.orderedTrustedPubkeys = graph
                self.isLoading = false
            }
        }
    }

    private func applyCachedGraphIfAvailable(for session: Session) async {
        guard let cached = await cache.cachedPubkeys(
            for: cacheKey(for: session),
            maxAge: Self.cacheMaxAge
        ) else {
            return
        }

        await MainActor.run {
            guard self.session == session else { return }
            if cached.count > self.orderedTrustedPubkeys.count {
                self.orderedTrustedPubkeys = cached
            }
        }
    }

    private func buildGraph(for session: Session) async -> [String] {
        let request = WebOfTrustExpansionRequest(
            accountPubkey: session.accountPubkey,
            relayURLs: session.relayURLs,
            hopCount: session.hopCount
        )
        return await expander.expand(
            request: request,
            followingsProvider: WebOfTrustServiceFollowingsProvider(
                service: service,
                expander: expander
            )
        )
    }

    private func directFollowings(for accountPubkey: String) -> [String] {
        expander.normalizedOrderedPubkeys(Array(FollowStore.shared.followedPubkeys))
            .filter { $0 != accountPubkey }
    }

    private func cacheKey(for session: Session) -> String {
        let relaySignature = session.relayURLs
            .map { $0.absoluteString.lowercased() }
            .joined(separator: ",")
        return "\(session.accountPubkey)|\(session.hopCount)|\(relaySignature)"
    }
}
