import Combine
import Foundation

protocol LocalCorpusCrawlingFeedServing: Sendable {
    func fetchFollowings(
        relayURLs: [URL],
        pubkey: String,
        relayFetchMode: RelayFetchMode
    ) async throws -> [String]
    func cachedFollowListSnapshot(pubkey: String) async -> FollowListSnapshot?
    func fetchProfiles(
        relayURLs: [URL],
        pubkeys: [String],
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [String: NostrProfile]
    func refreshLatestReplaceablesForAuthors(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        perAuthorLimit: Int,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [NostrEvent]
    func fetchOlderAuthorWindows(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        untilByAuthor: [String: Int?],
        perAuthorLimit: Int,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [String: [NostrEvent]]
    func fetchReferencedEvents(
        references: [NostrEventReferencePointer],
        baseRelayURLs: [URL],
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode
    ) async -> [NostrEventReferencePointer: NostrEvent]
}

extension NostrFeedService: LocalCorpusCrawlingFeedServing {}

private struct LocalCorpusCrawlerFollowingsProvider: WebOfTrustFollowingsProviding {
    let feedService: any LocalCorpusCrawlingFeedServing
    let expander: WebOfTrustExpander

    func directFollowings(for accountPubkey: String) async -> [String] {
        let followedPubkeys = await MainActor.run {
            Array(FollowStore.shared.followedPubkeys)
        }
        let fallbackFollowedPubkeys: [String]
        if followedPubkeys.isEmpty {
            fallbackFollowedPubkeys = await feedService.cachedFollowListSnapshot(pubkey: accountPubkey)?.followedPubkeys ?? []
        } else {
            fallbackFollowedPubkeys = followedPubkeys
        }
        return expander.normalizedOrderedPubkeys(fallbackFollowedPubkeys)
            .filter { $0 != expander.normalizePubkey(accountPubkey) }
    }

    func cachedFollowings(for pubkey: String) async -> [String]? {
        await feedService.cachedFollowListSnapshot(pubkey: pubkey)?.followedPubkeys
    }

    func fetchFollowings(for pubkey: String, relayURLs: [URL]) async -> [String] {
        (try? await feedService.fetchFollowings(
            relayURLs: relayURLs,
            pubkey: pubkey,
            relayFetchMode: .allRelays
        )) ?? []
    }
}

@MainActor
final class LocalCorpusCrawler: ObservableObject {
    static let shared = LocalCorpusCrawler()

    private enum DefaultsKey {
        static let lastForegroundPassAt = "flow.localCorpus.lastForegroundPassAt"
        static let lastBackgroundRefreshAt = "flow.localCorpus.lastBackgroundRefreshAt"
    }

    struct Settings: Equatable, Sendable {
        var isEnabled: Bool
        var wifiOnly: Bool
        var backgroundRefreshEnabled: Bool
        var hopCount: Int
        var deepMediaBackfillEnabled: Bool

        init(
            isEnabled: Bool = true,
            wifiOnly: Bool = false,
            backgroundRefreshEnabled: Bool = true,
            hopCount: Int = 2,
            deepMediaBackfillEnabled: Bool = true
        ) {
            self.isEnabled = isEnabled
            self.wifiOnly = wifiOnly
            self.backgroundRefreshEnabled = backgroundRefreshEnabled
            self.hopCount = AppSettingsStore.clampedLocalCorpusCrawlHopCount(hopCount)
            self.deepMediaBackfillEnabled = deepMediaBackfillEnabled
        }

        @MainActor
        init(appSettings: AppSettingsStore) {
            self.init(
                isEnabled: appSettings.localCorpusCrawlEnabled,
                wifiOnly: appSettings.localCorpusCrawlWiFiOnly,
                backgroundRefreshEnabled: appSettings.localCorpusBackgroundRefreshEnabled,
                hopCount: appSettings.localCorpusCrawlHopCount,
                deepMediaBackfillEnabled: appSettings.localCorpusDeepMediaBackfillEnabled
            )
        }
    }

    struct Diagnostics: Equatable, Sendable {
        var isForegroundRunning = false
        var isUsingWiFi = false
        var lastForegroundPassAt: Date?
        var lastBackgroundRefreshAt: Date?
        var lastErrorDescription: String?
        var plannedAuthorCount = 0
        var refreshedReplaceableCount = 0
        var tierAEventCount = 0
        var tierBEventCount = 0
        var resolvedReferenceCount = 0
        var queuedReferenceCount = 0
    }

    private struct Session: Equatable {
        let accountPubkey: String
        let readRelayURLs: [URL]
        let settings: Settings
        let isSceneActive: Bool
    }

    enum CrawlMode {
        case foreground
        case backgroundRefresh
    }

    typealias WorkContinuation = @Sendable () -> Bool

    private struct AuthorRelayGroup {
        let relayURLs: [URL]
        let authors: [String]
    }

    private struct PlannedTargets {
        let orderedPubkeys: [String]
        let relayPlan: AuthorRelayPlan
    }

    private enum DiagnosticBucket {
        case tierA
        case tierB
    }

    private let feedService: any LocalCorpusCrawlingFeedServing
    private let relayHintCache: any ProfileRelayHintCaching & AuthorRelayDirectoryCaching
    private let cursorStore: CrawlCursorStore
    private let networkPathMonitor: FlowNetworkPathMonitor
    private let expander: WebOfTrustExpander
    private let followingsProvider: any WebOfTrustFollowingsProviding
    private let relayPlanner: AuthorRelayPlanner
    private let fallbackRelayURLs: [URL]
    private let crawlPolicy: LocalCorpusCrawlPolicy
    private let foregroundInterval: TimeInterval
    private let shouldAutoStartForegroundLoop: Bool
    private let defaults: UserDefaults

    @Published private(set) var diagnostics = Diagnostics()

    private var session: Session?
    private var foregroundTask: Task<Void, Never>?
    private var replaceableOffset = 0
    private var extendedGraphOffset = 0
    private var mediaOffset = 0

    init(
        feedService: any LocalCorpusCrawlingFeedServing = NostrFeedService(),
        relayHintCache: any ProfileRelayHintCaching & AuthorRelayDirectoryCaching = ProfileRelayHintCache.shared,
        cursorStore: CrawlCursorStore = CrawlCursorStore(),
        networkPathMonitor: FlowNetworkPathMonitor = .shared,
        expander: WebOfTrustExpander = WebOfTrustExpander(),
        followingsProvider: (any WebOfTrustFollowingsProviding)? = nil,
        fallbackRelayURLs: [URL] = [
            URL(string: "wss://relay.damus.io/")!,
            URL(string: "wss://relay.primal.net/")!,
            URL(string: "wss://relay.nostr.band/")!,
            URL(string: "wss://relay.snort.social/")!,
            URL(string: "wss://nostr.wine/")!,
            URL(string: "wss://nos.lol/")!
        ],
        crawlPolicy: LocalCorpusCrawlPolicy = .default,
        foregroundInterval: TimeInterval = 5,
        shouldAutoStartForegroundLoop: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.feedService = feedService
        self.relayHintCache = relayHintCache
        self.cursorStore = cursorStore
        self.networkPathMonitor = networkPathMonitor
        self.expander = expander

        let resolvedProvider = followingsProvider ?? LocalCorpusCrawlerFollowingsProvider(
            feedService: feedService,
            expander: expander
        )
        self.followingsProvider = resolvedProvider
        self.relayPlanner = AuthorRelayPlanner()
        self.fallbackRelayURLs = expander.normalizedRelayURLs(fallbackRelayURLs)
        self.crawlPolicy = crawlPolicy
        self.foregroundInterval = max(foregroundInterval, 2)
        self.shouldAutoStartForegroundLoop = shouldAutoStartForegroundLoop
        self.defaults = defaults
        self.diagnostics.isUsingWiFi = networkPathMonitor.isCurrentlyUsingWiFi
        self.diagnostics.lastForegroundPassAt = defaults.object(forKey: DefaultsKey.lastForegroundPassAt) as? Date
        self.diagnostics.lastBackgroundRefreshAt = defaults.object(forKey: DefaultsKey.lastBackgroundRefreshAt) as? Date
    }

    deinit {
        foregroundTask?.cancel()
    }

    func configure(
        accountPubkey: String?,
        readRelayURLs: [URL],
        settings: Settings,
        isSceneActive: Bool
    ) {
        diagnostics.isUsingWiFi = networkPathMonitor.isCurrentlyUsingWiFi

        let normalizedAccountPubkey = expander.normalizePubkey(accountPubkey)
        let normalizedReadRelayURLs = expander.normalizedRelayURLs(readRelayURLs)

        guard !normalizedAccountPubkey.isEmpty, !normalizedReadRelayURLs.isEmpty else {
            session = nil
            stopForegroundLoop()
            resetRotationState()
            return
        }

        let nextSession = Session(
            accountPubkey: normalizedAccountPubkey,
            readRelayURLs: normalizedReadRelayURLs,
            settings: settings,
            isSceneActive: isSceneActive
        )

        let sessionChanged = nextSession != session
        if sessionChanged {
            resetRotationState()
        }

        session = nextSession
        refreshForegroundLoop(restart: sessionChanged)
    }

    func crawlNow(reason: CrawlMode = .foreground) async {
        guard let session else { return }

        switch reason {
        case .foreground:
            guard shouldRunForegroundCrawl(for: session) else {
                diagnostics.isForegroundRunning = false
                diagnostics.isUsingWiFi = networkPathMonitor.isCurrentlyUsingWiFi
                return
            }
            let policy = policy(for: session.settings)
            await runForegroundPass(session: session, policy: policy)
        case .backgroundRefresh:
            _ = await performBackgroundRefresh()
        }
    }

    func performBackgroundRefresh(
        shouldContinue: @escaping WorkContinuation = { !Task.isCancelled }
    ) async -> Bool {
        guard let session else { return false }
        guard session.settings.backgroundRefreshEnabled else { return false }

        diagnostics.isUsingWiFi = networkPathMonitor.isCurrentlyUsingWiFi
        let policy = policy(for: session.settings)
        return await runBackgroundRefresh(
            session: session,
            policy: policy,
            shouldContinue: shouldContinue
        )
    }

    private func refreshForegroundLoop(restart: Bool) {
        guard shouldAutoStartForegroundLoop else {
            diagnostics.isForegroundRunning = false
            return
        }

        if restart {
            stopForegroundLoop()
        }

        guard let session, shouldRunForegroundCrawl(for: session) else {
            stopForegroundLoop()
            return
        }

        guard foregroundTask == nil else {
            diagnostics.isForegroundRunning = true
            return
        }

        diagnostics.isForegroundRunning = true
        foregroundTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.crawlNow(reason: .foreground)
                guard !Task.isCancelled else { break }

                try? await Task.sleep(
                    nanoseconds: UInt64(self.foregroundInterval * 1_000_000_000)
                )

                let shouldContinue = await MainActor.run { [weak self] in
                    guard let self, let currentSession = self.session else { return false }
                    return self.shouldRunForegroundCrawl(for: currentSession)
                }
                guard shouldContinue else { break }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.foregroundTask = nil
                self.diagnostics.isForegroundRunning = false
            }
        }
    }

    private func stopForegroundLoop() {
        foregroundTask?.cancel()
        foregroundTask = nil
        diagnostics.isForegroundRunning = false
    }

    private func shouldRunForegroundCrawl(for session: Session) -> Bool {
        guard session.settings.isEnabled, session.isSceneActive else {
            return false
        }

        if session.settings.wifiOnly {
            return networkPathMonitor.isCurrentlyUsingWiFi
        }

        return true
    }

    private func policy(for settings: Settings) -> LocalCorpusCrawlPolicy {
        LocalCorpusCrawlPolicy(
            hopCount: settings.hopCount,
            requiresWiFiForForegroundCrawl: settings.wifiOnly,
            tierAAuthorPageLimit: crawlPolicy.tierAAuthorPageLimit,
            tierBAuthorPageLimit: crawlPolicy.tierBAuthorPageLimit,
            articleAuthorPageLimit: crawlPolicy.articleAuthorPageLimit,
            extendedGraphAuthorPageLimit: crawlPolicy.extendedGraphAuthorPageLimit,
            extendedGraphArticlePageLimit: crawlPolicy.extendedGraphArticlePageLimit,
            referenceResolutionBatchSize: crawlPolicy.referenceResolutionBatchSize,
            backgroundRefreshBatchSize: crawlPolicy.backgroundRefreshBatchSize,
            replaceableRefreshBatchSize: crawlPolicy.replaceableRefreshBatchSize,
            directFollowBurstPassCount: crawlPolicy.directFollowBurstPassCount,
            directFollowArticleBurstPassCount: crawlPolicy.directFollowArticleBurstPassCount,
            extendedGraphAuthorBatchSize: crawlPolicy.extendedGraphAuthorBatchSize,
            replaceableAuthorPageLimit: crawlPolicy.replaceableAuthorPageLimit,
            foregroundRelayTimeout: crawlPolicy.foregroundRelayTimeout,
            backgroundRelayTimeout: crawlPolicy.backgroundRelayTimeout
        )
    }

    private func runForegroundPass(
        session: Session,
        policy: LocalCorpusCrawlPolicy
    ) async {
        let relayTimeout = policy.foregroundRelayTimeout
        diagnostics.tierAEventCount = 0
        diagnostics.tierBEventCount = 0

        var targets = await planTargets(session: session, policy: policy)
        let prioritizedDirectAuthors = await directFollowAuthors(
            accountPubkey: session.accountPubkey,
            orderedPubkeys: targets.orderedPubkeys
        )
        let directFollowSet = Set(prioritizedDirectAuthors)
        let extendedAuthors = targets.orderedPubkeys.filter { !directFollowSet.contains($0) }
        let replaceableAuthors = prioritizedDirectAuthors + rotatingSlice(
            from: extendedAuthors,
            count: max(policy.replaceableRefreshBatchSize, 0),
            offset: &replaceableOffset
        )
        let replaceableEvents = await refreshReplaceables(
            authors: replaceableAuthors,
            relayPlan: targets.relayPlan,
            policy: policy,
            relayTimeout: relayTimeout
        )
        await recordAuthorRelayDirectoryEntries(from: replaceableEvents)
        targets = await refreshedTargetsIfNeeded(
            session: session,
            orderedPubkeys: targets.orderedPubkeys,
            currentTargets: targets,
            afterRefreshing: replaceableEvents
        )

        let refreshedDirectAuthors = await directFollowAuthors(
            accountPubkey: session.accountPubkey,
            orderedPubkeys: targets.orderedPubkeys
        )
        let refreshedDirectFollowSet = Set(refreshedDirectAuthors)
        let refreshedExtendedAuthors = targets.orderedPubkeys.filter { !refreshedDirectFollowSet.contains($0) }

        let directFollowCoreEvents = await crawlBurst(
            authors: refreshedDirectAuthors,
            kinds: policy.coreContentKinds,
            perAuthorLimit: policy.tierAAuthorPageLimit,
            relayPlan: targets.relayPlan,
            relayTimeout: relayTimeout,
            cursorTier: .tierA,
            passes: policy.directFollowBurstPassCount,
            diagnosticBucket: .tierA
        )
        let directFollowArticleEvents = await crawlBurst(
            authors: refreshedDirectAuthors,
            kinds: policy.articleKinds,
            perAuthorLimit: policy.articleAuthorPageLimit,
            relayPlan: targets.relayPlan,
            relayTimeout: relayTimeout,
            cursorTier: .tierAArticles,
            passes: policy.directFollowArticleBurstPassCount,
            diagnosticBucket: .tierA
        )

        let extendedBatchAuthors = rotatingSlice(
            from: refreshedExtendedAuthors,
            count: max(policy.extendedGraphAuthorBatchSize, 0),
            offset: &extendedGraphOffset
        )
        let extendedCoreEvents = await crawlBurst(
            authors: extendedBatchAuthors,
            kinds: policy.coreContentKinds,
            perAuthorLimit: policy.extendedGraphAuthorPageLimit,
            relayPlan: targets.relayPlan,
            relayTimeout: relayTimeout,
            cursorTier: .tierA,
            passes: 1,
            diagnosticBucket: .tierA
        )
        let extendedArticleEvents = await crawlBurst(
            authors: extendedBatchAuthors,
            kinds: policy.articleKinds,
            perAuthorLimit: policy.extendedGraphArticlePageLimit,
            relayPlan: targets.relayPlan,
            relayTimeout: relayTimeout,
            cursorTier: .tierAArticles,
            passes: 1,
            diagnosticBucket: .tierA
        )

        var tierBEvents: [NostrEvent] = []
        if session.settings.deepMediaBackfillEnabled {
            let tierBAuthors = refreshedDirectAuthors + rotatingSlice(
                from: refreshedExtendedAuthors,
                count: max(policy.extendedGraphAuthorBatchSize / 2, 12),
                offset: &mediaOffset
            )
            tierBEvents = await crawlBurst(
                authors: tierBAuthors,
                kinds: policy.tierBKinds,
                perAuthorLimit: policy.tierBAuthorPageLimit,
                relayPlan: targets.relayPlan,
                relayTimeout: relayTimeout,
                cursorTier: .tierB,
                passes: 1,
                diagnosticBucket: .tierB
            )
        }

        await resolveMissingReferences(
            from: replaceableEvents
                + directFollowCoreEvents
                + directFollowArticleEvents
                + extendedCoreEvents
                + extendedArticleEvents
                + tierBEvents,
            relayPlan: targets.relayPlan,
            policy: policy,
            relayTimeout: relayTimeout
        )
        let completedAt = Date()
        diagnostics.lastForegroundPassAt = completedAt
        defaults.set(completedAt, forKey: DefaultsKey.lastForegroundPassAt)
    }

    private func runBackgroundRefresh(
        session: Session,
        policy: LocalCorpusCrawlPolicy,
        shouldContinue: @escaping WorkContinuation
    ) async -> Bool {
        guard shouldContinueWork(shouldContinue) else { return false }

        let relayTimeout = policy.backgroundRelayTimeout
        diagnostics.tierAEventCount = 0
        diagnostics.tierBEventCount = 0

        var targets = await planTargets(session: session, policy: policy)
        let directFollowAuthors = await directFollowAuthors(
            accountPubkey: session.accountPubkey,
            orderedPubkeys: targets.orderedPubkeys
        )
        let prioritySource = directFollowAuthors.isEmpty ? targets.orderedPubkeys : directFollowAuthors
        let hottestAuthors = Array(prioritySource.prefix(max(policy.backgroundRefreshBatchSize, 1)))
        guard shouldContinueWork(shouldContinue) else { return false }

        let replaceableEvents = await refreshReplaceables(
            authors: hottestAuthors,
            relayPlan: targets.relayPlan,
            policy: policy,
            relayTimeout: relayTimeout
        )
        await recordAuthorRelayDirectoryEntries(from: replaceableEvents)
        targets = await refreshedTargetsIfNeeded(
            session: session,
            orderedPubkeys: targets.orderedPubkeys,
            currentTargets: targets,
            afterRefreshing: replaceableEvents
        )
        guard shouldContinueWork(shouldContinue) else { return false }

        let tierACoreEvents = await crawlBurst(
            authors: hottestAuthors,
            kinds: policy.coreContentKinds,
            perAuthorLimit: policy.extendedGraphAuthorPageLimit,
            relayPlan: targets.relayPlan,
            relayTimeout: relayTimeout,
            cursorTier: nil,
            passes: 1,
            diagnosticBucket: .tierA
        )
        let tierAArticleEvents = await crawlBurst(
            authors: hottestAuthors,
            kinds: policy.articleKinds,
            perAuthorLimit: policy.articleAuthorPageLimit,
            relayPlan: targets.relayPlan,
            relayTimeout: relayTimeout,
            cursorTier: nil,
            passes: 1,
            diagnosticBucket: .tierA
        )
        diagnostics.tierBEventCount = 0
        guard shouldContinueWork(shouldContinue) else { return false }

        await resolveMissingReferences(
            from: replaceableEvents + tierACoreEvents + tierAArticleEvents,
            relayPlan: targets.relayPlan,
            policy: policy,
            relayTimeout: relayTimeout
        )
        guard shouldContinueWork(shouldContinue) else { return false }

        await resolveQueuedMissingReferences(
            relayPlan: targets.relayPlan,
            policy: policy,
            relayTimeout: relayTimeout
        )
        let completedAt = Date()
        diagnostics.lastBackgroundRefreshAt = completedAt
        defaults.set(completedAt, forKey: DefaultsKey.lastBackgroundRefreshAt)
        return true
    }

    private func shouldContinueWork(_ shouldContinue: WorkContinuation) -> Bool {
        shouldContinue() && !Task.isCancelled
    }

    private func planTargets(
        session: Session,
        policy: LocalCorpusCrawlPolicy
    ) async -> PlannedTargets {
        let request = WebOfTrustExpansionRequest(
            accountPubkey: session.accountPubkey,
            relayURLs: session.readRelayURLs,
            hopCount: policy.hopCount
        )
        let orderedPubkeys = await expander.expand(
            request: request,
            followingsProvider: followingsProvider
        )
        let directoryEntries = await relayHintCache.entries(for: orderedPubkeys)
        let relayPlan = relayPlanner.makePlan(
            authors: orderedPubkeys,
            baseReadRelayURLs: session.readRelayURLs,
            directoryEntriesByPubkey: directoryEntries,
            fallbackRelayURLs: fallbackRelayURLs
        )

        diagnostics.plannedAuthorCount = orderedPubkeys.count
        diagnostics.lastErrorDescription = nil
        return PlannedTargets(orderedPubkeys: orderedPubkeys, relayPlan: relayPlan)
    }

    private func refreshedTargetsIfNeeded(
        session: Session,
        orderedPubkeys: [String],
        currentTargets: PlannedTargets,
        afterRefreshing events: [NostrEvent]
    ) async -> PlannedTargets {
        guard !events.isEmpty else { return currentTargets }

        let directoryEntries = await relayHintCache.entries(for: orderedPubkeys)
        let relayPlan = relayPlanner.makePlan(
            authors: orderedPubkeys,
            baseReadRelayURLs: session.readRelayURLs,
            directoryEntriesByPubkey: directoryEntries,
            fallbackRelayURLs: fallbackRelayURLs
        )
        return PlannedTargets(orderedPubkeys: orderedPubkeys, relayPlan: relayPlan)
    }

    private func refreshReplaceables(
        authors: [String],
        relayPlan: AuthorRelayPlan,
        policy: LocalCorpusCrawlPolicy,
        relayTimeout: TimeInterval
    ) async -> [NostrEvent] {
        guard !authors.isEmpty else {
            diagnostics.refreshedReplaceableCount = 0
            return []
        }

        var events: [NostrEvent] = []
        let groups = groupedAuthors(authors: authors, relayPlan: relayPlan)
        for group in groups {
            let refreshed = await feedService.refreshLatestReplaceablesForAuthors(
                relayURLs: group.relayURLs,
                authors: group.authors,
                kinds: policy.replaceableKinds,
                perAuthorLimit: policy.replaceableAuthorPageLimit,
                fetchTimeout: relayTimeout,
                relayFetchMode: policy.relayFetchMode
            )
            events.append(contentsOf: refreshed)
        }

        let deduplicated = deduplicateEvents(events)
        diagnostics.refreshedReplaceableCount = deduplicated.count
        return deduplicated
    }

    private func crawlTier(
        authors: [String],
        kinds: [Int],
        perAuthorLimit: Int,
        relayPlan: AuthorRelayPlan,
        relayTimeout: TimeInterval,
        cursorTier: LocalCorpusCrawlCursorTier?
    ) async -> [NostrEvent] {
        guard !authors.isEmpty, !kinds.isEmpty else { return [] }

        var collected: [NostrEvent] = []
        let groups = groupedAuthors(authors: authors, relayPlan: relayPlan)
        for group in groups {
            var untilByAuthor: [String: Int?] = [:]
            for author in group.authors {
                if let cursorTier {
                    untilByAuthor[author] = await cursorStore.untilCursor(for: author, tier: cursorTier)
                } else {
                    untilByAuthor[author] = nil
                }
            }

            let windows = await feedService.fetchOlderAuthorWindows(
                relayURLs: group.relayURLs,
                authors: group.authors,
                kinds: kinds,
                untilByAuthor: untilByAuthor,
                perAuthorLimit: perAuthorLimit,
                fetchTimeout: relayTimeout,
                relayFetchMode: crawlPolicy.relayFetchMode
            )

            for author in group.authors {
                let events = windows[author] ?? []
                guard !events.isEmpty else { continue }
                if let cursorTier {
                    let oldestCreatedAt = events.map { $0.createdAt }.min() ?? 0
                    let nextCursor = max(oldestCreatedAt - 1, 0)
                    await cursorStore.setUntilCursor(
                        nextCursor,
                        for: author,
                        tier: cursorTier
                    )
                }
                collected.append(contentsOf: events)
            }
        }

        let deduplicated = deduplicateEvents(collected)
        return deduplicated
    }

    private func crawlBurst(
        authors: [String],
        kinds: [Int],
        perAuthorLimit: Int,
        relayPlan: AuthorRelayPlan,
        relayTimeout: TimeInterval,
        cursorTier: LocalCorpusCrawlCursorTier?,
        passes: Int,
        diagnosticBucket: DiagnosticBucket
    ) async -> [NostrEvent] {
        guard !authors.isEmpty, !kinds.isEmpty, passes > 0 else { return [] }

        var collected: [NostrEvent] = []
        for _ in 0..<passes {
            let events = await crawlTier(
                authors: authors,
                kinds: kinds,
                perAuthorLimit: perAuthorLimit,
                relayPlan: relayPlan,
                relayTimeout: relayTimeout,
                cursorTier: cursorTier
            )
            guard !events.isEmpty else { break }
            collected.append(contentsOf: events)
        }

        let deduplicated = deduplicateEvents(collected)
        addDiagnosticEventCount(deduplicated.count, to: diagnosticBucket)
        return deduplicated
    }

    private func resolveMissingReferences(
        from newlyFetchedEvents: [NostrEvent],
        relayPlan: AuthorRelayPlan,
        policy: LocalCorpusCrawlPolicy,
        relayTimeout: TimeInterval
    ) async {
        let queuedIdentifiers = Array(
            await cursorStore.queuedMissingReferenceIdentifiers()
                .prefix(policy.referenceResolutionBatchSize)
        )
        if !queuedIdentifiers.isEmpty {
            await cursorStore.removeMissingReferenceIdentifiers(queuedIdentifiers)
        }

        let discoveredPointers = referencePointers(from: newlyFetchedEvents)
        let queuedPointers = queuedIdentifiers.compactMap(NoteContentParser.eventReferencePointer(from:))
        let discoveredBatch = Array(discoveredPointers.prefix(policy.referenceResolutionBatchSize))
        let candidatePointers = Array(Set(queuedPointers + discoveredBatch))
        guard !candidatePointers.isEmpty else {
            diagnostics.queuedReferenceCount = await cursorStore.queuedMissingReferenceIdentifiers().count
            diagnostics.resolvedReferenceCount = 0
            return
        }

        let resolved = await feedService.fetchReferencedEvents(
            references: candidatePointers,
            baseRelayURLs: relayPlan.broadFallbackRelayURLs,
            fetchTimeout: relayTimeout,
            relayFetchMode: policy.relayFetchMode
        )

        let unresolvedIdentifiers = candidatePointers
            .filter { resolved[$0] == nil }
            .map(\.normalizedIdentifier)
        if !unresolvedIdentifiers.isEmpty {
            await cursorStore.enqueueMissingReferenceIdentifiers(unresolvedIdentifiers)
        }

        diagnostics.resolvedReferenceCount = resolved.count
        diagnostics.queuedReferenceCount = await cursorStore.queuedMissingReferenceIdentifiers().count
    }

    private func resolveQueuedMissingReferences(
        relayPlan: AuthorRelayPlan,
        policy: LocalCorpusCrawlPolicy,
        relayTimeout: TimeInterval
    ) async {
        let queuedIdentifiers = Array(
            await cursorStore.queuedMissingReferenceIdentifiers()
                .prefix(policy.referenceResolutionBatchSize)
        )
        guard !queuedIdentifiers.isEmpty else {
            diagnostics.resolvedReferenceCount = 0
            diagnostics.queuedReferenceCount = await cursorStore.queuedMissingReferenceIdentifiers().count
            return
        }

        await cursorStore.removeMissingReferenceIdentifiers(queuedIdentifiers)
        let queuedPointers = queuedIdentifiers.compactMap(NoteContentParser.eventReferencePointer(from:))
        let resolved = await feedService.fetchReferencedEvents(
            references: queuedPointers,
            baseRelayURLs: relayPlan.broadFallbackRelayURLs,
            fetchTimeout: relayTimeout,
            relayFetchMode: policy.relayFetchMode
        )

        let unresolvedIdentifiers = queuedPointers
            .filter { resolved[$0] == nil }
            .map(\.normalizedIdentifier)
        if !unresolvedIdentifiers.isEmpty {
            await cursorStore.enqueueMissingReferenceIdentifiers(unresolvedIdentifiers)
        }

        diagnostics.resolvedReferenceCount = resolved.count
        diagnostics.queuedReferenceCount = await cursorStore.queuedMissingReferenceIdentifiers().count
    }

    private func groupedAuthors(
        authors: [String],
        relayPlan: AuthorRelayPlan
    ) -> [AuthorRelayGroup] {
        var groupsBySignature: [String: AuthorRelayGroup] = [:]

        for author in authors {
            let relayURLs = relayPlan.relayURLs(for: author)
            let signature = relayURLs.map { $0.absoluteString.lowercased() }.joined(separator: "|")
            if var existing = groupsBySignature[signature] {
                existing = AuthorRelayGroup(relayURLs: existing.relayURLs, authors: existing.authors + [author])
                groupsBySignature[signature] = existing
            } else {
                groupsBySignature[signature] = AuthorRelayGroup(relayURLs: relayURLs, authors: [author])
            }
        }

        return groupsBySignature.values.sorted { lhs, rhs in
            lhs.authors.first ?? "" < rhs.authors.first ?? ""
        }
    }

    private func directFollowAuthors(
        accountPubkey: String,
        orderedPubkeys: [String]
    ) async -> [String] {
        let direct = await followingsProvider.directFollowings(for: accountPubkey)
        let cachedFallback = direct.isEmpty ? (await followingsProvider.cachedFollowings(for: accountPubkey) ?? []) : []
        let orderedDirect = expander
            .normalizedOrderedPubkeys(direct.isEmpty ? cachedFallback : direct)
            .filter { $0 != expander.normalizePubkey(accountPubkey) }
        let allowed = Set(orderedPubkeys)
        return orderedDirect.filter { allowed.contains($0) }
    }

    private func rotatingSlice(
        from values: [String],
        count: Int,
        offset: inout Int
    ) -> [String] {
        guard !values.isEmpty, count > 0 else { return [] }
        if values.count <= count {
            offset = 0
            return values
        }

        let startIndex = min(max(offset, 0), values.count - 1)
        let rotated = Array(values[startIndex...]) + Array(values[..<startIndex])
        offset = (startIndex + count) % values.count
        return Array(rotated.prefix(count))
    }

    private func recordAuthorRelayDirectoryEntries(from events: [NostrEvent]) async {
        for event in events where event.kind == 10_002 {
            let pubkey = AuthorRelayPlanner.normalizePubkey(event.pubkey)
            guard !pubkey.isEmpty else { continue }

            let relayConnections = ProfileEventService.relayListReadWriteURLs(from: event.tags)
            guard !relayConnections.read.isEmpty || !relayConnections.write.isEmpty else { continue }

            await relayHintCache.store(
                entry: AuthorRelayDirectoryEntry(
                    readRelayURLs: relayConnections.read,
                    writeRelayURLs: relayConnections.write,
                    hintRelayURLs: [],
                    refreshedAt: Date()
                ),
                for: pubkey
            )
        }
    }

    private func addDiagnosticEventCount(_ count: Int, to bucket: DiagnosticBucket) {
        guard count > 0 else { return }
        switch bucket {
        case .tierA:
            diagnostics.tierAEventCount += count
        case .tierB:
            diagnostics.tierBEventCount += count
        }
    }

    private func referencePointers(from events: [NostrEvent]) -> [NostrEventReferencePointer] {
        var pointers: [NostrEventReferencePointer] = []
        var seen = Set<String>()

        for event in events {
            for tag in event.tags {
                guard tag.count > 1,
                      let name = tag.first?.lowercased(),
                      name == "e" || name == "a" || name == "q" else {
                    continue
                }

                let rawValue = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawValue.isEmpty else { continue }
                guard let basePointer = NoteContentParser.eventReferencePointer(from: rawValue) else {
                    continue
                }

                let relayHints = expander.normalizedRelayURLs(
                    basePointer.relayHints +
                        [NoteContentParser.relayHintURL(from: tag.count > 2 ? tag[2] : nil)].compactMap { $0 }
                )
                let pointer = NostrEventReferencePointer(
                    normalizedIdentifier: basePointer.normalizedIdentifier,
                    target: basePointer.target,
                    relayHints: relayHints,
                    authorPubkey: basePointer.authorPubkey
                )
                guard seen.insert(pointer.normalizedIdentifier).inserted else { continue }
                pointers.append(pointer)
            }
        }

        return pointers
    }

    private func deduplicateEvents(_ events: [NostrEvent]) -> [NostrEvent] {
        var uniqueEvents: [NostrEvent] = []
        var seen = Set<String>()
        for event in events {
            let normalizedID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty, seen.insert(normalizedID).inserted else { continue }
            uniqueEvents.append(event)
        }
        return uniqueEvents
    }

    private func resetRotationState() {
        replaceableOffset = 0
        extendedGraphOffset = 0
        mediaOffset = 0
    }
}
