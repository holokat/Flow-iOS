import Foundation

@MainActor
final class HomeFeedViewModel: ObservableObject {
    struct FeedRequestStrategy: Equatable {
        let fetchTimeout: TimeInterval
        let relayFetchMode: RelayFetchMode
    }

    private struct TrendingPaginationState {}

    private struct TrendingPageFetchResult {
        let page: HomeFeedPageResult
        let nextState: TrendingPaginationState?
    }

    private struct VisibleItemsCacheKey: Equatable {
        let itemsRevision: Int
        let feedSource: HomePrimaryFeedSource
        let mode: HomeFeedMode
        let showKinds: [Int]
        let mediaOnly: Bool
        let hideNSFW: Bool
        let filterRevision: Int
        let spamFilterSignature: String
        let mutedConversationRevision: Int
        let ignoreMediaOnly: Bool
    }

    @Published private(set) var items: [FeedItem] = [] {
        didSet {
            itemsRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    @Published private(set) var bufferedNewItems: [FeedItem] = []
    @Published var mode: HomeFeedMode = .posts {
        didSet {
            clearVisibleItemsCache()
            guard mode != oldValue else { return }
            Task { [weak self] in
                await self?.prepareForSelectedModeIfNeeded()
            }
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isBootstrappingFeed = false
    @Published private(set) var showKinds: [Int] {
        didSet { clearVisibleItemsCache() }
    }
    @Published private(set) var mediaOnly: Bool {
        didSet { clearVisibleItemsCache() }
    }
    @Published var feedSource: HomePrimaryFeedSource = .network
    @Published private(set) var interestHashtags: [String] = []
    @Published private(set) var favoriteHashtags: [String] = []
    @Published private(set) var favoriteRelayURLs: [String] = []
    @Published private(set) var pollsFeedVisible = true
    @Published private(set) var customFeeds: [CustomFeedDefinition] = []
    @Published var errorMessage: String?
    @Published private(set) var readRelayURLs: [URL]
    @Published private(set) var relayURL: URL

    private let pageSize: Int
    private let service: NostrFeedService
    private let liveSubscriber: NostrLiveFeedSubscriber
    private let filterStore: HomeFeedFilterStore

    private let assetPrefetchItemCount = 24
    private let feedSourceStorage = UserDefaults.standard
    private let feedSourceStoragePrefix = "homeFeedSourcePreference"
    private let mutedConversationStoragePrefix = "homeFeedMutedConversations"
    private static let fastHomeFetchTimeout: TimeInterval = 8
    private static let fastHomeRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let paginationFetchTimeout: TimeInterval = 8
    private static let followingHomeFetchTimeout: TimeInterval = 8
    private static let followingPaginationFetchTimeout: TimeInterval = 8
    private nonisolated static let pollsInitialVisibleTarget = 8
    private static let liveCatchUpFetchTimeout: TimeInterval = 4
    private static let liveCatchUpMinimumInterval: TimeInterval = 15
    private static let liveCatchUpOverlapSeconds = 90
    private static let liveCatchUpLimit = 200
    private static let trendingRelayURL = NostrFeedService.nostrArchivesTrendingRelayURL
    private static let newsFallbackRelayURL = URL(string: "wss://news.utxo.one")!
    private static let customFeedSupplementalRelayURLs: [URL] = [
        URL(string: "wss://relay.damus.io/"),
        URL(string: "wss://nos.lol/"),
        URL(string: "wss://relay.nostr.band/"),
        URL(string: "wss://nostr.mom/"),
        NostrFeedService.nostrArchivesSearchRelayURL
    ].compactMap { $0 }

    private var oldestCreatedAt: Int?
    private var hasReachedEnd = false
    private var isSilentRefreshing = false
    private var needsRefreshAfterCurrentRequest = false
    private var knownEventIDs = Set<String>()
    private var followingPubkeys: [String] = []
    private var currentUserPubkey: String?
    private var mutedConversationIDs = Set<String>() {
        didSet {
            mutedConversationRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    private var itemsRevision = 0
    private var mutedConversationRevision = 0
    private var visibleItemsCacheKey: VisibleItemsCacheKey?
    private var visibleItemsCache: [FeedItem] = []

    private var liveSubscriptionKinds: [Int] = []
    private var liveSubscriptionSource: HomePrimaryFeedSource?
    private var liveSubscriptionConfigurationSignature: String?
    private var liveUpdatesTask: Task<Void, Never>?
    private var liveCatchUpTask: Task<Void, Never>?
    private var liveCatchUpToken = 0
    private var lastLiveCatchUpBySignature: [String: Date] = [:]
    private var resetFeedTask: Task<Void, Never>?
    private var isPrefetchingMore = false
    private var latestRefreshRequestID = 0
    private var trendingPaginationState: TrendingPaginationState?

    nonisolated static var defaultPageSizeForTesting: Int {
        HomeFeedPaginationDefaults.pageSize
    }

    nonisolated static func trendingWindowTraversalLimitForTesting(isInitialPage: Bool) -> Int {
        let _ = isInitialPage
        return 1
    }

    nonisolated static func initialVisibleTargetForTesting(
        source: HomePrimaryFeedSource,
        mode: HomeFeedMode?,
        limit: Int
    ) -> Int {
        initialVisibleTarget(for: source, mode: mode, limit: limit)
    }

    nonisolated static func minimumVisibleItemsForSelectedModeForTesting(
        source: HomePrimaryFeedSource,
        mode: HomeFeedMode,
        pageSize: Int
    ) -> Int {
        minimumVisibleItemsForSelectedMode(
            source: source,
            mode: mode,
            pageSize: pageSize
        )
    }

    init(
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        pageSize: Int = HomeFeedPaginationDefaults.pageSize,
        service: NostrFeedService = NostrFeedService(),
        liveSubscriber: NostrLiveFeedSubscriber = NostrLiveFeedSubscriber(),
        filterStore: HomeFeedFilterStore = .shared
    ) {
        let defaults = filterStore.loadDefaults()

        let normalizedReadRelays = HomeFeedSourceResolver.normalizedRelayURLs(readRelayURLs ?? [relayURL])
        let initialReadRelayURLs = normalizedReadRelays.isEmpty ? [relayURL] : normalizedReadRelays
        let initialRelayURL = initialReadRelayURLs.first ?? relayURL

        self.readRelayURLs = initialReadRelayURLs
        self.relayURL = initialRelayURL
        self.pageSize = pageSize
        self.service = service
        self.liveSubscriber = liveSubscriber
        self.filterStore = filterStore
        self.showKinds = defaults.showKinds
        self.mediaOnly = defaults.mediaOnly
    }

    deinit {
        liveUpdatesTask?.cancel()
        liveCatchUpTask?.cancel()
        resetFeedTask?.cancel()
    }

    var feedSourceOptions: [HomePrimaryFeedSource] {
        let hashtagSources = favoriteHashtags.map { HomePrimaryFeedSource.hashtag($0) }
        let relaySources = favoriteRelayURLs.map { HomePrimaryFeedSource.relay($0) }
        let interestSources: [HomePrimaryFeedSource] = interestHashtags.isEmpty ? [] : [.interests]
        let customSources = customFeeds.map { HomePrimaryFeedSource.custom($0.id) }
        let pollsSources: [HomePrimaryFeedSource] = pollsFeedVisible ? [.polls] : []
        return [.network, .following, .articles] + pollsSources + [.trending] + interestSources + [.news] + customSources + relaySources + hashtagSources
    }

    var kindFilterOptions: [FeedKindFilterOption] {
        FeedKindFilters.options
    }

    var visibleItems: [FeedItem] {
        filteredMainItems()
    }

    private var muteFilterSnapshot: MuteFilterSnapshot {
        MuteStore.shared.filterSnapshot
    }

    var visibleBufferedNewItemsCount: Int {
        filterVisibleItems(bufferedNewItems).count
    }

    var visibleBufferedNewItems: [FeedItem] {
        filterVisibleItems(bufferedNewItems)
    }

    var isUsingCustomFilters: Bool {
        !FeedKindFilters.isSameSelection(showKinds, FeedKindFilters.allOptionKinds) || mediaOnly
    }

    var shouldShowFilteredOutState: Bool {
        !isShowingLoadingPlaceholder && !items.isEmpty && visibleItems.isEmpty && errorMessage == nil
    }

    var mediaOnlyFilteredOutAll: Bool {
        mediaOnly && visibleItems.isEmpty && !filteredMainItems(ignoreMediaOnly: true).isEmpty
    }

    var isShowingLoadingPlaceholder: Bool {
        (isLoading || isBootstrappingFeed) && items.isEmpty
    }

    var relayDisplayName: String {
        if readRelayURLs.count > 1 {
            return "\(readRelayURLs.count) relays"
        }
        return relayURL.host() ?? relayURL.absoluteString
    }

    var followingFeedHasNoFollowings: Bool {
        (feedSource == .following || feedSource == .articles || feedSource == .polls) &&
            !isLoading &&
            followingPubkeys.isEmpty &&
            errorMessage == nil
    }

    var interestsFeedHasNoHashtags: Bool {
        feedSource == .interests && !isLoading && interestHashtags.isEmpty && errorMessage == nil
    }

    var networkFeedHasNoTrustedAuthors: Bool { false }

    var filteredOutMessage: String {
        if mediaOnlyFilteredOutAll {
            return "This feed has posts, but the media-only filter is hiding them."
        }
        return "No posts match the current filters."
    }

    // Network-style feeds can use a fast first non-empty relay grace window.
    // Following now favors completeness on initial load because staged hydration
    // already keeps row rendering lightweight.
    static func requestStrategy(
        for source: HomePrimaryFeedSource,
        isPagination: Bool
    ) -> FeedRequestStrategy {
        switch source {
        case .following, .articles:
            return FeedRequestStrategy(
                fetchTimeout: isPagination ? Self.followingPaginationFetchTimeout : Self.followingHomeFetchTimeout,
                relayFetchMode: .allRelays
            )
        case .polls:
            return FeedRequestStrategy(
                fetchTimeout: isPagination ? Self.followingPaginationFetchTimeout : Self.followingHomeFetchTimeout,
                relayFetchMode: isPagination ? .allRelays : .firstNonEmptyRelay
            )
        default:
            return FeedRequestStrategy(
                fetchTimeout: isPagination ? Self.paginationFetchTimeout : Self.fastHomeFetchTimeout,
                relayFetchMode: isPagination ? .allRelays : Self.fastHomeRelayFetchMode
            )
        }
    }

    private nonisolated static func stagedHydrationMode(
        for source: HomePrimaryFeedSource,
        requestHydrationMode: FeedItemHydrationMode
    ) -> FeedItemHydrationMode {
        switch source {
        case .following, .articles, .polls, .news:
            return .cachedProfilesOnly
        default:
            return requestHydrationMode
        }
    }

    func updateCurrentUserPubkey(_ pubkey: String?) {
        let normalized = pubkey?.lowercased()
        guard currentUserPubkey != normalized else { return }

        currentUserPubkey = normalized
        mutedConversationIDs = loadMutedConversationIDs(pubkey: normalized)
        let preferredSource = loadFeedSourcePreference(pubkey: normalized)
        let resolvedPreferredSource = resolvedFeedSource(preferredSource)
        if feedSource != resolvedPreferredSource {
            feedSource = resolvedPreferredSource
        }

        resetFeedStateAndReload()
    }

    func updateFavoriteHashtags(_ hashtags: [String]) {
        let normalized = HomeFeedSourceResolver.normalizedFavoriteHashtags(hashtags)
        guard favoriteHashtags != normalized else { return }

        favoriteHashtags = normalized

        if case .hashtag(let selectedHashtag) = feedSource,
           !normalized.contains(HomePrimaryFeedSource.normalizeHashtag(selectedHashtag)) {
            feedSource = .network
            storeFeedSourcePreference(feedSource, pubkey: currentUserPubkey)
            resetFeedStateAndReload()
        }
    }

    func updateFavoriteRelays(_ relayURLs: [String]) {
        let normalized = HomeFeedSourceResolver.normalizedFavoriteRelayURLs(relayURLs)
        guard favoriteRelayURLs != normalized else { return }

        favoriteRelayURLs = normalized

        if case .relay(let selectedRelayURL) = feedSource,
           !normalized.contains(HomePrimaryFeedSource.normalizeRelayURLString(selectedRelayURL)) {
            feedSource = .network
            storeFeedSourcePreference(feedSource, pubkey: currentUserPubkey)
            resetFeedStateAndReload()
        }
    }

    func updatePollsFeedVisibility(_ isVisible: Bool) {
        guard pollsFeedVisible != isVisible else { return }

        pollsFeedVisible = isVisible

        if feedSource == .polls && !isVisible {
            feedSource = .network
            storeFeedSourcePreference(feedSource, pubkey: currentUserPubkey)
            resetFeedStateAndReload()
        }
    }

    func updateCustomFeeds(_ feeds: [CustomFeedDefinition]) {
        guard customFeeds != feeds else { return }

        let previousFeeds = customFeeds
        customFeeds = feeds

        guard case .custom(let selectedID) = feedSource else { return }

        guard let updatedSelection = customFeedDefinition(id: selectedID) else {
            feedSource = .network
            storeFeedSourcePreference(feedSource, pubkey: currentUserPubkey)
            resetFeedStateAndReload()
            return
        }

        let previousSelection = previousFeeds.first { $0.id == selectedID }
        if previousSelection != updatedSelection {
            resetFeedStateAndReload()
        }
    }

    func updateInterestHashtags(_ hashtags: [String]) {
        let normalized = HomeFeedSourceResolver.normalizedFavoriteHashtags(hashtags)
        guard interestHashtags != normalized else { return }

        interestHashtags = normalized

        if feedSource == .interests && normalized.isEmpty {
            feedSource = .network
            storeFeedSourcePreference(feedSource, pubkey: currentUserPubkey)
            resetFeedStateAndReload()
            return
        }

        let preferredSource = resolvedFeedSource(loadFeedSourcePreference(pubkey: currentUserPubkey))
        if feedSource != .interests,
           preferredSource == .interests,
           !normalized.isEmpty {
            feedSource = .interests
            resetFeedStateAndReload()
            return
        }

        if feedSource == .interests {
            Task {
                await refresh(silent: true)
            }
        }
    }

    func updateNetworkTrustedPubkeys(_ pubkeys: [String]) {
        // Network is relay-based again, so trusted-pubkey updates are ignored.
    }

    func muteConversation(_ conversationID: String) {
        let normalized = conversationID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return }
        guard mutedConversationIDs.insert(normalized).inserted else { return }

        persistMutedConversationIDs(pubkey: currentUserPubkey)
        items.removeAll { $0.event.referencesConversation(id: normalized) }
        bufferedNewItems.removeAll { $0.event.referencesConversation(id: normalized) }
        knownEventIDs = Set(items.map(\.id))
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
    }

    func insertOptimisticPublishedItem(_ item: FeedItem) {
        guard itemIsAllowedForCurrentSource(item) else { return }
        mergeKeepingNewest(itemsToMerge: [item])
    }

    func selectFeedSource(_ source: HomePrimaryFeedSource) {
        let resolvedSource = resolvedFeedSource(source)
        guard feedSource != resolvedSource else { return }
        feedSource = resolvedSource
        storeFeedSourcePreference(resolvedSource, pubkey: currentUserPubkey)
        resetFeedStateAndReload()
    }

    func updateRelayURL(_ newRelayURL: URL) {
        updateReadRelayURLs([newRelayURL])
    }

    func updateReadRelayURLs(_ newReadRelayURLs: [URL]) {
        let normalized = HomeFeedSourceResolver.normalizedRelayURLs(newReadRelayURLs)
        guard !normalized.isEmpty else { return }

        let existing = readRelayURLs.map { $0.absoluteString.lowercased() }
        let next = normalized.map { $0.absoluteString.lowercased() }
        guard existing != next else {
            return
        }

        readRelayURLs = normalized
        relayURL = normalized[0]
        resetFeedStateAndReload()
    }

    func loadIfNeeded() async {
        if items.isEmpty {
            guard !isLoading, !isSilentRefreshing, !isBootstrappingFeed else { return }
            await refresh()
        } else {
            startLiveUpdatesIfNeeded()
        }
    }

    func prepareForSelectedModeIfNeeded() async {
        guard sourceUsesModeAwareBackfill(feedSource) else { return }
        guard !isLoading, !isSilentRefreshing else { return }
        guard !hasReachedEnd else { return }

        let minimumVisibleItems = Self.minimumVisibleItemsForSelectedMode(
            source: feedSource,
            mode: mode,
            pageSize: pageSize
        )
        guard Self.visibleItemCount(items, mode: mode) < minimumVisibleItems else { return }

        await refresh(silent: true)
    }

    func isKindGroupEnabled(_ option: FeedKindFilterOption) -> Bool {
        let selected = Set(showKinds)
        return option.kinds.allSatisfy { selected.contains($0) }
    }

    func toggleKindGroup(_ option: FeedKindFilterOption) {
        var selected = Set(showKinds)
        let group = Set(option.kinds)

        if group.isSubset(of: selected) {
            selected.subtract(group)
            guard !selected.isEmpty else { return }
        } else {
            selected.formUnion(group)
        }

        applyCurrentFilters(showKinds: Array(selected), mediaOnly: mediaOnly)
    }

    func selectAllKinds() {
        applyCurrentFilters(showKinds: FeedKindFilters.allOptionKinds, mediaOnly: mediaOnly)
    }

    func setMediaOnly(_ enabled: Bool) {
        applyCurrentFilters(showKinds: showKinds, mediaOnly: enabled)
    }

    func disableMediaOnlyFilter() {
        setMediaOnly(false)
    }

    func refresh(
        silent: Bool = false,
        force: Bool = false,
        publishFetchedItems: Bool = true
    ) async {
        if !force && (isLoading || isSilentRefreshing) {
            needsRefreshAfterCurrentRequest = true
            return
        }

        needsRefreshAfterCurrentRequest = false
        if force {
            isLoading = false
            isSilentRefreshing = false
        }
        latestRefreshRequestID += 1
        let refreshRequestID = latestRefreshRequestID
        let requestSource = feedSource
        let requestUserPubkey = currentUserPubkey
        let startedWithEmptyItems = items.isEmpty

        if silent {
            isSilentRefreshing = true
        } else {
            isLoading = true
        }
        if publishFetchedItems {
            errorMessage = nil
            hasReachedEnd = false
            oldestCreatedAt = nil
            trendingPaginationState = nil
        }

        defer {
            if latestRefreshRequestID == refreshRequestID {
                if silent {
                    isSilentRefreshing = false
                } else {
                    isLoading = false
                }

                if requestSource == feedSource, requestUserPubkey == currentUserPubkey {
                    isBootstrappingFeed = false
                }

                if needsRefreshAfterCurrentRequest {
                    needsRefreshAfterCurrentRequest = false
                    Task { [weak self] in
                        await self?.refresh()
                    }
                }
            }
        }

        do {
            var fetched: [FeedItem]
            var sourcePageResult: HomeFeedPageResult?
            let requestRelayURLs = relayURLs(for: requestSource)
            let requestKinds = feedKinds(for: requestSource)
            let requestHydrationMode: FeedItemHydrationMode = .full
            let fastHydrationMode = Self.stagedHydrationMode(
                for: requestSource,
                requestHydrationMode: requestHydrationMode
            )
            let requestStrategy = Self.requestStrategy(for: requestSource, isPagination: false)
            let requestFetchTimeout = requestStrategy.fetchTimeout
            let requestRelayFetchMode = requestStrategy.relayFetchMode
            var stagedHydrationEvents: [NostrEvent] = []

            if requestSource != .following && requestSource != .articles {
                startLiveUpdatesIfNeeded()
            }

            switch requestSource {
            case .network, .relay:
                followingPubkeys = []
                let networkPage = try await fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    mode: mode,
                    minimumVisibleCount: Self.initialVisibleTarget(
                        for: requestSource,
                        mode: mode,
                        limit: pageSize
                    ),
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = networkPage.items
                sourcePageResult = networkPage

            case .interests:
                followingPubkeys = []
                let interestPage = try await fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    mode: mode,
                    minimumVisibleCount: Self.initialVisibleTarget(
                        for: requestSource,
                        mode: mode,
                        limit: pageSize
                    ),
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = interestPage.items
                sourcePageResult = interestPage

            case .trending:
                followingPubkeys = []
                let trendingPage = try await fetchTrendingFeedPage(
                    limit: pageSize,
                    paginationState: nil,
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = trendingPage.page.items
                sourcePageResult = trendingPage.page
                trendingPaginationState = trendingPage.nextState

            case .news:
                followingPubkeys = []
                let newsPage = try await fetchNewsFeedPage(
                    limit: pageSize,
                    until: nil,
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = newsPage.items
                sourcePageResult = newsPage
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = newsPage.items.map(\.event)
                }

            case .custom(let feedID):
                followingPubkeys = []
                guard let feed = customFeedDefinition(id: feedID) else {
                    fetched = []
                    hasReachedEnd = true
                    break
                }
                let customPage = try await fetchCustomFeedPage(
                    feed: feed,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = customPage.items
                sourcePageResult = customPage

            case .hashtag(let hashtag):
                followingPubkeys = []
                let hashtagPage = try await fetchModeAwarePrimaryFeedPage(
                    source: .hashtag(hashtag),
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    mode: mode,
                    minimumVisibleCount: Self.initialVisibleTarget(
                        for: requestSource,
                        mode: mode,
                        limit: pageSize
                    ),
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = hashtagPage.items
                sourcePageResult = hashtagPage

            case .following:
                guard let requestUserPubkey else {
                    throw HomeFeedError.followingRequiresLogin
                }

                let followings = try await resolveFollowingPubkeys(
                    currentUserPubkey: requestUserPubkey,
                    relayURLs: requestRelayURLs,
                    relayFetchMode: requestRelayFetchMode
                )

                if requestSource != feedSource || requestUserPubkey != currentUserPubkey {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    needsRefreshAfterCurrentRequest = true
                    return
                }

                followingPubkeys = followings
                let followingFeedAuthors = Self.followingAuthorPubkeys(
                    followingPubkeys: followings,
                    currentUserPubkey: requestUserPubkey
                )

                if followingFeedAuthors.isEmpty {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    items = []
                    bufferedNewItems = []
                    knownEventIDs = []
                    oldestCreatedAt = nil
                    hasReachedEnd = true
                    startLiveUpdatesIfNeeded(forceRestart: true)
                    return
                }

                startLiveUpdatesIfNeeded(forceRestart: true)

                let followingPage = try await fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: followingFeedAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    mode: mode,
                    minimumVisibleCount: Self.initialVisibleTarget(
                        for: requestSource,
                        mode: mode,
                        limit: pageSize
                    ),
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = followingPage.items
                sourcePageResult = followingPage
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = followingPage.items.map(\.event)
                }

            case .articles:
                guard let requestUserPubkey else {
                    throw HomeFeedError.articlesRequiresLogin
                }

                let followings = try await resolveFollowingPubkeys(
                    currentUserPubkey: requestUserPubkey,
                    relayURLs: requestRelayURLs,
                    relayFetchMode: requestRelayFetchMode
                )

                if requestSource != feedSource || requestUserPubkey != currentUserPubkey {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    needsRefreshAfterCurrentRequest = true
                    return
                }

                followingPubkeys = followings
                let articleAuthors = Self.followingAuthorPubkeys(
                    followingPubkeys: followings,
                    currentUserPubkey: requestUserPubkey
                )

                if articleAuthors.isEmpty {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    items = []
                    bufferedNewItems = []
                    knownEventIDs = []
                    oldestCreatedAt = nil
                    hasReachedEnd = true
                    startLiveUpdatesIfNeeded(forceRestart: true)
                    return
                }

                startLiveUpdatesIfNeeded(forceRestart: true)

                let articlesPage = try await fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: articleAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    minimumVisibleCount: Self.initialVisibleTarget(
                        for: requestSource,
                        mode: nil,
                        limit: pageSize
                    ),
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = articlesPage.items
                sourcePageResult = articlesPage
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = articlesPage.items.map(\.event)
                }

            case .polls:
                guard let requestUserPubkey else {
                    throw HomeFeedError.pollsRequiresLogin
                }

                let followings = try await resolveFollowingPubkeys(
                    currentUserPubkey: requestUserPubkey,
                    relayURLs: requestRelayURLs,
                    relayFetchMode: requestRelayFetchMode
                )

                if requestSource != feedSource || requestUserPubkey != currentUserPubkey {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    needsRefreshAfterCurrentRequest = true
                    return
                }

                followingPubkeys = followings
                let pollAuthors = Self.followingAuthorPubkeys(
                    followingPubkeys: followings,
                    currentUserPubkey: requestUserPubkey
                )

                if pollAuthors.isEmpty {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    items = []
                    bufferedNewItems = []
                    knownEventIDs = []
                    oldestCreatedAt = nil
                    hasReachedEnd = true
                    startLiveUpdatesIfNeeded(forceRestart: true)
                    return
                }

                startLiveUpdatesIfNeeded(forceRestart: true)

                let pollsPage = try await fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: pollAuthors,
                    kinds: FeedKindFilters.pollKinds,
                    limit: pageSize,
                    until: nil,
                    minimumVisibleCount: Self.initialVisibleTarget(
                        for: requestSource,
                        mode: nil,
                        limit: pageSize
                    ),
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = pollsPage.items
                sourcePageResult = pollsPage
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = pollsPage.items.map(\.event)
                }
            }

            if requestSource != feedSource || requestUserPubkey != currentUserPubkey {
                guard latestRefreshRequestID == refreshRequestID else { return }
                needsRefreshAfterCurrentRequest = true
                return
            }

            if requestSource != .news,
               requestSource != .trending,
               requestSource != .articles,
               requestSource != .polls,
               !FeedKindFilters.isSameSelection(requestKinds, showKinds) {
                guard latestRefreshRequestID == refreshRequestID else { return }
                needsRefreshAfterCurrentRequest = true
                return
            }

            guard latestRefreshRequestID == refreshRequestID else { return }

            applyRefreshResults(
                fetched: fetched,
                requestSource: requestSource,
                sourcePageResult: sourcePageResult,
                publishFetchedItems: publishFetchedItems,
                startedWithEmptyItems: startedWithEmptyItems
            )

            if requestHydrationMode != fastHydrationMode,
               !stagedHydrationEvents.isEmpty {
                let upgradedItems = await service.buildFeedItems(
                    relayURLs: requestRelayURLs,
                    events: stagedHydrationEvents,
                    hydrationMode: requestHydrationMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                guard !Task.isCancelled else { return }

                if requestSource != feedSource || requestUserPubkey != currentUserPubkey {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    needsRefreshAfterCurrentRequest = true
                    return
                }

                if requestSource != .news,
                   requestSource != .trending,
                   requestSource != .articles,
                   requestSource != .polls,
                   !FeedKindFilters.isSameSelection(requestKinds, showKinds) {
                    guard latestRefreshRequestID == refreshRequestID else { return }
                    needsRefreshAfterCurrentRequest = true
                    return
                }

                guard latestRefreshRequestID == refreshRequestID else { return }
                applyRefreshResults(
                    fetched: upgradedItems,
                    requestSource: requestSource,
                    sourcePageResult: sourcePageResult,
                    publishFetchedItems: publishFetchedItems,
                    startedWithEmptyItems: startedWithEmptyItems
                )
            }

            startLiveUpdatesIfNeeded()
        } catch {
            guard latestRefreshRequestID == refreshRequestID else { return }
            guard publishFetchedItems else { return }
            switch error {
            case HomeFeedError.followingRequiresLogin:
                errorMessage = "Sign in to view the Following feed."
            case HomeFeedError.articlesRequiresLogin:
                errorMessage = "Sign in to view the Articles feed."
            case HomeFeedError.pollsRequiresLogin:
                errorMessage = "Sign in to view the Polls feed."
            case HomeFeedError.networkRequiresLogin:
                errorMessage = "Sign in to view the Network feed."
            default:
                if items.isEmpty {
                    errorMessage = "Couldn't load the home feed. Pull to refresh and try again."
                } else {
                    errorMessage = "Couldn't refresh right now."
                }
            }
        }
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        guard !isLoading, !hasReachedEnd else { return }

        let currentVisibleItems = visibleItems
        guard let currentIndex = currentVisibleItems.firstIndex(where: { $0.id == currentItem.id }) else { return }
        guard Self.shouldPrefetchMore(
            visibleItemCount: currentVisibleItems.count,
            currentIndex: currentIndex
        ) else {
            return
        }

        let shouldShowLoadingIndicator = Self.shouldShowPaginationSpinner(
            visibleItemCount: currentVisibleItems.count,
            currentIndex: currentIndex
        )

        if isPrefetchingMore {
            if shouldShowLoadingIndicator {
                isLoadingMore = true
            }
            return
        }
        guard !isLoadingMore else { return }

        let until = max((oldestCreatedAt ?? Int(Date().timeIntervalSince1970)) - 1, 0)
        guard until > 0 else { return }

        let requestSource = feedSource
        let requestRefreshID = latestRefreshRequestID
        let requestHydrationMode: FeedItemHydrationMode = .full
        let fastHydrationMode = Self.stagedHydrationMode(
            for: requestSource,
            requestHydrationMode: requestHydrationMode
        )
        let requestStrategy = Self.requestStrategy(for: requestSource, isPagination: true)
        let requestFetchTimeout = requestStrategy.fetchTimeout
        let requestRelayFetchMode = requestStrategy.relayFetchMode

        isPrefetchingMore = true
        if shouldShowLoadingIndicator {
            isLoadingMore = true
        }
        defer {
            isPrefetchingMore = false
            isLoadingMore = false
        }

        do {
            var fetched: [FeedItem]
            var sourcePageResult: HomeFeedPageResult?
            let requestRelayURLs = relayURLs(for: requestSource)
            let requestKinds = feedKinds(for: requestSource)
            var stagedHydrationEvents: [NostrEvent] = []

            switch requestSource {
            case .network, .relay:
                let networkPage = try await fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    mode: mode,
                    minimumVisibleCount: Self.minimumVisibleItemsForSelectedMode(
                        source: requestSource,
                        mode: mode,
                        pageSize: pageSize
                    ),
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = networkPage.items
                sourcePageResult = networkPage

            case .interests:
                let interestPage = try await fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    mode: mode,
                    minimumVisibleCount: Self.minimumVisibleItemsForSelectedMode(
                        source: requestSource,
                        mode: mode,
                        pageSize: pageSize
                    ),
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = interestPage.items
                sourcePageResult = interestPage

            case .trending:
                let trendingPage = try await fetchTrendingFeedPage(
                    limit: pageSize,
                    paginationState: trendingPaginationState,
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = trendingPage.page.items
                sourcePageResult = trendingPage.page
                trendingPaginationState = trendingPage.nextState

            case .news:
                let newsPage = try await fetchNewsFeedPage(
                    limit: pageSize,
                    until: until,
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = newsPage.items
                sourcePageResult = newsPage

            case .custom(let feedID):
                guard let feed = customFeedDefinition(id: feedID) else {
                    hasReachedEnd = true
                    return
                }
                let customPage = try await fetchCustomFeedPage(
                    feed: feed,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = customPage.items
                sourcePageResult = customPage

            case .hashtag(let hashtag):
                let hashtagPage = try await fetchModeAwarePrimaryFeedPage(
                    source: .hashtag(hashtag),
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    mode: mode,
                    minimumVisibleCount: Self.minimumVisibleItemsForSelectedMode(
                        source: requestSource,
                        mode: mode,
                        pageSize: pageSize
                    ),
                    hydrationMode: requestHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = hashtagPage.items
                sourcePageResult = hashtagPage

            case .following:
                let followingFeedAuthors = Self.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                guard !followingFeedAuthors.isEmpty else {
                    hasReachedEnd = true
                    return
                }

                let followingPage = try await fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: followingFeedAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    mode: mode,
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = followingPage.items
                sourcePageResult = followingPage
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = followingPage.items.map(\.event)
                }

            case .articles:
                let articleAuthors = Self.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                guard !articleAuthors.isEmpty else {
                    hasReachedEnd = true
                    return
                }

                let articlesPage = try await fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: articleAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = articlesPage.items
                sourcePageResult = articlesPage
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = articlesPage.items.map(\.event)
                }

            case .polls:
                let pollAuthors = Self.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                guard !pollAuthors.isEmpty else {
                    hasReachedEnd = true
                    return
                }

                let pollsPage = try await fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: pollAuthors,
                    kinds: FeedKindFilters.pollKinds,
                    limit: pageSize,
                    until: until,
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = pollsPage.items
                sourcePageResult = pollsPage
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = pollsPage.items.map(\.event)
                }
            }

            if requestRefreshID != latestRefreshRequestID || requestSource != feedSource {
                return
            }

            if requestSource != .news,
               requestSource != .trending,
               requestSource != .articles,
               requestSource != .polls,
               !FeedKindFilters.isSameSelection(requestKinds, showKinds) {
                return
            }

            if fetched.isEmpty {
                hasReachedEnd = !(sourcePageResult?.hadMoreAvailable ?? false)
                return
            }

            oldestCreatedAt = sourcePageResult?.paginationCursor ?? fetched.last?.event.createdAt
            if let sourcePageResult {
                hasReachedEnd = !sourcePageResult.hadMoreAvailable
            } else {
                hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: fetched.count)
            }
            mergeKeepingNewest(itemsToMerge: fetched)

            if requestHydrationMode != fastHydrationMode,
               !stagedHydrationEvents.isEmpty {
                let upgradedItems = await service.buildFeedItems(
                    relayURLs: requestRelayURLs,
                    events: stagedHydrationEvents,
                    hydrationMode: requestHydrationMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                guard !Task.isCancelled else { return }
                guard requestRefreshID == latestRefreshRequestID, requestSource == feedSource else {
                    return
                }

                if requestSource != .news,
                   requestSource != .trending,
                   requestSource != .articles,
                   requestSource != .polls,
                   !FeedKindFilters.isSameSelection(requestKinds, showKinds) {
                    return
                }

                mergeKeepingNewest(itemsToMerge: upgradedItems)
            }
        } catch {
            errorMessage = "Couldn't load more posts."
        }
    }

    nonisolated static func shouldPrefetchMore(
        visibleItemCount: Int,
        currentIndex: Int
    ) -> Bool {
        guard visibleItemCount > 0 else { return false }
        guard currentIndex >= 0, currentIndex < visibleItemCount else { return false }
        let remainingItemCount = visibleItemCount - currentIndex - 1
        return remainingItemCount <= HomeFeedPaginationDefaults.prefetchTriggerDistance
    }

    nonisolated static func shouldShowPaginationSpinner(
        visibleItemCount: Int,
        currentIndex: Int
    ) -> Bool {
        guard visibleItemCount > 0 else { return false }
        guard currentIndex >= 0, currentIndex < visibleItemCount else { return false }
        let remainingItemCount = visibleItemCount - currentIndex - 1
        return remainingItemCount <= HomeFeedPaginationDefaults.spinnerTriggerDistance
    }

    func showBufferedNewItems() {
        guard !bufferedNewItems.isEmpty else { return }
        mergeKeepingNewest(itemsToMerge: bufferedNewItems)
        bufferedNewItems.removeAll()
    }

    private func applyCurrentFilters(showKinds: [Int], mediaOnly: Bool) {
        let normalizedKinds = FeedKindFilters.normalizedKinds(showKinds)
        let kindsChanged = !FeedKindFilters.isSameSelection(normalizedKinds, self.showKinds)
        let mediaChanged = mediaOnly != self.mediaOnly

        guard kindsChanged || mediaChanged else { return }

        self.showKinds = normalizedKinds
        self.mediaOnly = mediaOnly
        filterStore.saveDefaults(showKinds: normalizedKinds, mediaOnly: mediaOnly)

        if kindsChanged {
            self.bufferedNewItems.removeAll()
            self.liveUpdatesTask?.cancel()
            self.liveUpdatesTask = nil
            self.liveCatchUpTask?.cancel()
            self.liveCatchUpTask = nil
            self.lastLiveCatchUpBySignature.removeAll()
            self.liveSubscriptionKinds = []
            self.liveSubscriptionSource = nil
            self.liveSubscriptionConfigurationSignature = nil

            Task { [weak self] in
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    private func resetFeedStateAndReload() {
        isBootstrappingFeed = true
        bufferedNewItems.removeAll()
        items.removeAll()
        knownEventIDs.removeAll()
        oldestCreatedAt = nil
        hasReachedEnd = false
        trendingPaginationState = nil
        followingPubkeys = []
        errorMessage = nil

        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        liveCatchUpTask?.cancel()
        liveCatchUpTask = nil
        lastLiveCatchUpBySignature.removeAll()
        liveSubscriptionKinds = []
        liveSubscriptionSource = nil
        liveSubscriptionConfigurationSignature = nil

        resetFeedTask?.cancel()
        resetFeedTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(force: true)
        }
    }

    private func startLiveUpdatesIfNeeded(forceRestart: Bool = false) {
        let liveKinds = feedKinds(for: feedSource)
        guard !liveKinds.isEmpty else { return }
        let source = feedSource
        let targets = liveSubscriptionTargets(for: source, kinds: liveKinds)
        guard !targets.isEmpty else {
            liveUpdatesTask?.cancel()
            liveUpdatesTask = nil
            liveCatchUpTask?.cancel()
            liveCatchUpTask = nil
            lastLiveCatchUpBySignature.removeAll()
            liveSubscriptionKinds = []
            liveSubscriptionSource = source
            liveSubscriptionConfigurationSignature = nil
            return
        }

        let configurationSignature = targets
            .map(\.signature)
            .sorted()
            .joined(separator: "||")

        if !forceRestart,
           liveUpdatesTask != nil,
           FeedKindFilters.isSameSelection(liveKinds, liveSubscriptionKinds),
           liveSubscriptionSource == source,
           liveSubscriptionConfigurationSignature == configurationSignature {
            return
        }

        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        liveCatchUpTask?.cancel()
        liveCatchUpTask = nil
        liveSubscriptionKinds = liveKinds
        liveSubscriptionSource = source
        liveSubscriptionConfigurationSignature = configurationSignature

        liveUpdatesTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.liveSubscriber.run(
                            relayURL: target.relayURL,
                            filter: target.filter,
                            onNewEvent: { [weak self] event in
                                guard let self else { return }
                                await self.handleLiveEvent(event)
                            },
                            onStatus: { [weak self] _ in
                                guard let self else { return }
                                await self.handleLiveStatus(target: target)
                            }
                        )
                    }
                }
                await group.waitForAll()
            }
        }

        scheduleLiveCatchUp(for: targets, force: true)
    }

    private func handleLiveStatus(target: HomeFeedLiveSubscriptionTarget) async {
        scheduleLiveCatchUp(for: [target])
    }

    private func scheduleLiveCatchUp(
        for targets: [HomeFeedLiveSubscriptionTarget],
        force: Bool = false
    ) {
        guard liveCatchUpTask == nil else { return }
        guard !targets.isEmpty else { return }

        let now = Date()
        let dueTargets = targets.filter { target in
            guard !force else { return true }
            guard let lastFetch = lastLiveCatchUpBySignature[target.signature] else { return true }
            return now.timeIntervalSince(lastFetch) >= Self.liveCatchUpMinimumInterval
        }
        guard !dueTargets.isEmpty else { return }

        dueTargets.forEach { lastLiveCatchUpBySignature[$0.signature] = now }
        liveCatchUpToken &+= 1
        let token = liveCatchUpToken
        liveCatchUpTask = Task(priority: .utility) { [weak self, dueTargets] in
            guard let self else { return }
            await self.performLiveCatchUp(for: dueTargets)
            await MainActor.run { [weak self] in
                guard let self, self.liveCatchUpToken == token else { return }
                self.liveCatchUpTask = nil
            }
        }
    }

    private func performLiveCatchUp(for targets: [HomeFeedLiveSubscriptionTarget]) async {
        let catchUpSince = max(Int(Date().timeIntervalSince1970) - Self.liveCatchUpOverlapSeconds, 0)
        let catchUpLimit = Self.liveCatchUpLimit
        let catchUpTimeout = Self.liveCatchUpFetchTimeout
        let service = service

        await withTaskGroup(of: [NostrEvent].self) { group in
            for target in targets {
                group.addTask {
                    await service.fetchLiveCatchUpEvents(
                        relayURL: target.relayURL,
                        filter: target.filter,
                        since: catchUpSince,
                        limit: catchUpLimit,
                        timeout: catchUpTimeout
                    )
                }
            }

            for await events in group {
                guard !Task.isCancelled else { return }
                for event in events {
                    await handleLiveEvent(event)
                }
            }
        }
    }

    private func handleLiveEvent(_ event: NostrEvent) async {
        let normalizedEventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard feedKinds(for: feedSource).contains(event.kind) else { return }
        guard !normalizedEventID.isEmpty, !knownEventIDs.contains(normalizedEventID) else { return }

        await service.ingestLiveEvents([event])

        let hydrated = await service.buildFeedItems(
            relayURLs: hydrationRelayURLs(for: feedSource),
            events: [event],
            moderationSnapshot: muteFilterSnapshot
        )
        guard let item = hydrated.first else { return }
        guard !knownEventIDs.contains(item.id) else { return }
        guard itemIsAllowedForCurrentSource(item) else { return }

        knownEventIDs.insert(item.id)
        bufferedNewItems = mergeItemArrays(
            primary: [item],
            secondary: bufferedNewItems
        )
        scheduleAssetPrefetch(for: [item])
    }

    private func mergeKeepingNewest(itemsToMerge: [FeedItem]) {
        items = pruneItemsForSource(
            pruneMutedItems(mergeItemArrays(primary: itemsToMerge, secondary: items))
        )
        scheduleAssetPrefetch(for: items)

        let currentlyVisibleIDs = Set(items.map(\.id))
        bufferedNewItems.removeAll { currentlyVisibleIDs.contains($0.id) }

        knownEventIDs = currentlyVisibleIDs
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
    }

    private func applyRefreshResults(
        fetched: [FeedItem],
        requestSource: HomePrimaryFeedSource,
        sourcePageResult: HomeFeedPageResult?,
        publishFetchedItems: Bool,
        startedWithEmptyItems: Bool
    ) {
        let refreshItems = startedWithEmptyItems
            ? mergeItemArrays(primary: fetched, secondary: bufferedNewItems)
            : fetched
        let shouldKeepVisibleRows = !publishFetchedItems
        let visibleSourceItems = shouldKeepVisibleRows ? items : []
        let mergedItems = pruneItemsForSource(
            pruneMutedItems(
                mergeItemArrays(
                    primary: shouldKeepVisibleRows ? refreshItems : visibleSourceItems,
                    secondary: shouldKeepVisibleRows ? visibleSourceItems : refreshItems
                )
            ),
            feedSource: requestSource,
            followingPubkeys: sourceUsesFollowingAuthors(requestSource) ? followingPubkeys : nil
        )

        let existingBufferedItems = bufferedNewItems
        bufferedNewItems = []
        let nextOldestCreatedAt = sourcePageResult?.paginationCursor ??
            mergedItems.last?.event.createdAt ??
            fetched.last?.event.createdAt
        let nextHasReachedEnd: Bool
        if let sourcePageResult {
            nextHasReachedEnd = !sourcePageResult.hadMoreAvailable
        } else {
            nextHasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: fetched.count)
        }

        if publishFetchedItems {
            items = mergedItems
            knownEventIDs = Set(mergedItems.map(\.id))
            oldestCreatedAt = nextOldestCreatedAt
            hasReachedEnd = nextHasReachedEnd
            scheduleAssetPrefetch(for: mergedItems)
        } else {
            let existingVisibleItems = items
            let existingVisibleIDs = Set(existingVisibleItems.map(\.id))
            let refreshedVisibleItems = pruneItemsForSource(
                pruneMutedItems(
                    mergeItemArrays(
                        primary: mergedItems.filter { existingVisibleIDs.contains($0.id) },
                        secondary: existingVisibleItems
                    )
                ),
                feedSource: requestSource,
                followingPubkeys: sourceUsesFollowingAuthors(requestSource) ? followingPubkeys : nil
            )
            let didUpdateVisibleItems = refreshedVisibleItems != existingVisibleItems
            if didUpdateVisibleItems {
                items = refreshedVisibleItems
            }

            let visibleItemIDs = Set(refreshedVisibleItems.map(\.id))
            let unpublishedItems = mergedItems.filter { !visibleItemIDs.contains($0.id) }
            bufferedNewItems = mergeItemArrays(
                primary: unpublishedItems,
                secondary: existingBufferedItems
            ).filter { !visibleItemIDs.contains($0.id) }
            knownEventIDs = visibleItemIDs
            knownEventIDs.formUnion(bufferedNewItems.map(\.id))
            oldestCreatedAt = nextOldestCreatedAt
            hasReachedEnd = nextHasReachedEnd
            let prefetchedVisibleItems = didUpdateVisibleItems
                ? refreshedVisibleItems.filter { existingVisibleIDs.contains($0.id) }
                : []
            scheduleAssetPrefetch(for: prefetchedVisibleItems + unpublishedItems)
        }
    }

    private func liveSubscriptionTargets(
        for source: HomePrimaryFeedSource,
        kinds: [Int]
    ) -> [HomeFeedLiveSubscriptionTarget] {
        switch source {
        case .network:
            return subscriptionTargets(
                relayURLs: relayURLs(for: .network),
                filter: NostrFilter(kinds: kinds, limit: 100),
                scopeSignature: "network"
            )

        case .relay(let relayURL):
            let normalizedRelayURL = HomePrimaryFeedSource.normalizeRelayURLString(relayURL)
            guard !normalizedRelayURL.isEmpty else { return [] }
            return subscriptionTargets(
                relayURLs: relayURLs(for: source),
                filter: NostrFilter(kinds: kinds, limit: 100),
                scopeSignature: "relay:\(normalizedRelayURL)"
            )

        case .trending:
            return []

        case .interests:
            let hashtags = configuredInterestHashtags()
            guard !hashtags.isEmpty else { return [] }
            return subscriptionTargets(
                relayURLs: relayURLs(for: .interests),
                filter: NostrFilter(kinds: kinds, limit: 100, tagFilters: ["t": hashtags]),
                scopeSignature: "interests:\(hashtags.joined(separator: ","))"
            )

        case .news:
            var targets: [HomeFeedLiveSubscriptionTarget] = []

            let newsRelayTargets = relayURLs(for: .news)
            targets.append(contentsOf: subscriptionTargets(
                relayURLs: newsRelayTargets,
                filter: NostrFilter(kinds: [1], limit: 100),
                scopeSignature: "news-relays"
            ))

            let authors = Array(configuredNewsAuthorPubkeys().prefix(400))
            if !authors.isEmpty {
                let newsAuthorRelayTargets = Self.normalizedRelayURLs(newsRelayTargets + readRelayURLs)
                targets.append(contentsOf: subscriptionTargets(
                    relayURLs: newsAuthorRelayTargets,
                    filter: NostrFilter(authors: authors, kinds: [1], limit: 100),
                    scopeSignature: "news-authors:\(authors.joined(separator: ","))"
                ))
            }

            let hashtags = configuredNewsHashtags()
            if !hashtags.isEmpty {
                targets.append(contentsOf: subscriptionTargets(
                    relayURLs: newsRelayTargets,
                    filter: NostrFilter(kinds: [1], limit: 100, tagFilters: ["t": hashtags]),
                    scopeSignature: "news-hashtags:\(hashtags.joined(separator: ","))"
                ))
            }

            return deduplicatedSubscriptionTargets(targets)

        case .custom(let feedID):
            guard let feed = customFeedDefinition(id: feedID) else { return [] }

            var targets: [HomeFeedLiveSubscriptionTarget] = []
            let relayTargets = relayURLs(for: source)

            let authors = Array(feed.authorPubkeys.prefix(400))
            if !authors.isEmpty {
                targets.append(contentsOf: subscriptionTargets(
                    relayURLs: relayTargets,
                    filter: NostrFilter(authors: authors, kinds: kinds, limit: 100),
                    scopeSignature: "custom-authors:\(feedID):\(authors.joined(separator: ","))"
                ))
            }

            let hashtags = Array(feed.hashtags.prefix(40))
            if !hashtags.isEmpty {
                targets.append(contentsOf: subscriptionTargets(
                    relayURLs: relayTargets,
                    filter: NostrFilter(kinds: kinds, limit: 100, tagFilters: ["t": hashtags]),
                    scopeSignature: "custom-hashtags:\(feedID):\(hashtags.joined(separator: ","))"
                ))
            }

            return deduplicatedSubscriptionTargets(targets)

        case .hashtag(let hashtag):
            let normalizedHashtag = HomePrimaryFeedSource.normalizeHashtag(hashtag)
            guard !normalizedHashtag.isEmpty else { return [] }
            return subscriptionTargets(
                relayURLs: relayURLs(for: source),
                filter: NostrFilter(kinds: kinds, limit: 100, tagFilters: ["t": [normalizedHashtag]]),
                scopeSignature: "hashtag:\(normalizedHashtag)"
            )

        case .following:
            let liveAuthors = Array(
                Self.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                .prefix(400)
            )
            .sorted()
            guard !liveAuthors.isEmpty else { return [] }
            return subscriptionTargets(
                relayURLs: relayURLs(for: .following),
                filter: NostrFilter(authors: liveAuthors, kinds: kinds, limit: 100),
                scopeSignature: "following:\(liveAuthors.joined(separator: ","))"
            )

        case .articles:
            let liveAuthors = Array(
                Self.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                .prefix(400)
            )
            .sorted()
            guard !liveAuthors.isEmpty else { return [] }
            return subscriptionTargets(
                relayURLs: relayURLs(for: .articles),
                filter: NostrFilter(authors: liveAuthors, kinds: [FeedKindFilters.longFormArticle], limit: 100),
                scopeSignature: "articles:\(liveAuthors.joined(separator: ","))"
            )

        case .polls:
            let liveAuthors = Array(
                Self.followingAuthorPubkeys(
                    followingPubkeys: followingPubkeys,
                    currentUserPubkey: currentUserPubkey
                )
                .prefix(400)
            )
            .sorted()
            guard !liveAuthors.isEmpty else { return [] }
            return subscriptionTargets(
                relayURLs: relayURLs(for: .polls),
                filter: NostrFilter(authors: liveAuthors, kinds: FeedKindFilters.pollKinds, limit: 100),
                scopeSignature: "polls:\(liveAuthors.joined(separator: ","))"
            )
        }
    }

    private func subscriptionTargets(
        relayURLs: [URL],
        filter: NostrFilter,
        scopeSignature: String
    ) -> [HomeFeedLiveSubscriptionTarget] {
        Self.normalizedRelayURLs(relayURLs).map { relayURL in
            HomeFeedLiveSubscriptionTarget(
                relayURL: relayURL,
                filter: filter,
                signature: "\(scopeSignature)|\(relayURL.absoluteString.lowercased())"
            )
        }
    }

    private func deduplicatedSubscriptionTargets(_ targets: [HomeFeedLiveSubscriptionTarget]) -> [HomeFeedLiveSubscriptionTarget] {
        var seen = Set<String>()
        var ordered: [HomeFeedLiveSubscriptionTarget] = []

        for target in targets {
            guard seen.insert(target.signature).inserted else { continue }
            ordered.append(target)
        }

        return ordered
    }

    private func mergeItemArrays(primary: [FeedItem], secondary: [FeedItem]) -> [FeedItem] {
        var byID: [String: FeedItem] = Dictionary(uniqueKeysWithValues: secondary.map { ($0.id, $0) })

        for item in primary {
            if let existing = byID[item.id] {
                byID[item.id] = existing.merged(with: item)
            } else {
                byID[item.id] = item
            }
        }

        return byID.values.sorted {
            if $0.event.createdAt == $1.event.createdAt {
                return $0.id > $1.id
            }
            return $0.event.createdAt > $1.event.createdAt
        }
    }

    nonisolated static func prefixForVisibleModeLimitForTesting(
        _ items: [FeedItem],
        mode: HomeFeedMode,
        visibleLimit: Int
    ) -> [FeedItem] {
        prefixForVisibleModeLimit(items, mode: mode, visibleLimit: visibleLimit)
    }

    private nonisolated static func visibleItemCount(_ items: [FeedItem], mode: HomeFeedMode) -> Int {
        items.reduce(into: 0) { count, item in
            if mode.includes(item) {
                count += 1
            }
        }
    }

    private nonisolated static func prefixForVisibleModeLimit(
        _ items: [FeedItem],
        mode: HomeFeedMode,
        visibleLimit: Int
    ) -> [FeedItem] {
        guard visibleLimit > 0 else { return [] }

        var visibleCount = 0
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            result.append(item)
            if mode.includes(item) {
                visibleCount += 1
                if visibleCount >= visibleLimit {
                    break
                }
            }
        }

        return result
    }

    private func filterVisibleItems(_ source: [FeedItem], ignoreMediaOnly: Bool = false) -> [FeedItem] {
        let allowedKinds: Set<Int>
        switch feedSource {
        case .polls:
            allowedKinds = Set(FeedKindFilters.pollKinds)
        case .articles:
            allowedKinds = [FeedKindFilters.longFormArticle]
        default:
            allowedKinds = Set(showKinds)
        }
        let hideNSFW = AppSettingsStore.shared.hideNSFWContent

        return source.filter { item in
            if !itemIsAllowedForCurrentSource(item) {
                return false
            }

            if mutedConversationIDs.contains(item.displayEvent.conversationID) {
                return false
            }

            if MuteStore.shared.shouldHideAny(item.moderationEvents) {
                return false
            }

            if isHiddenByManualSpam(item) {
                return false
            }

            if hideNSFW && item.moderationEvents.contains(where: { $0.containsNSFWHashtag }) {
                return false
            }

            if !allowedKinds.contains(item.event.kind) {
                return false
            }

            if feedSource != .polls && feedSource != .articles && !mode.includes(item) {
                return false
            }

            if feedSource != .polls &&
                feedSource != .articles &&
                !ignoreMediaOnly &&
                mediaOnly &&
                !item.displayEvent.hasMedia {
                return false
            }

            return true
        }
    }

    private func pruneMutedItems(
        _ source: [FeedItem],
        snapshot: MuteFilterSnapshot? = nil
    ) -> [FeedItem] {
        let snapshot = snapshot ?? muteFilterSnapshot
        let hasMarkedSpam = !AppSettingsStore.shared.spamFilterMarkedPubkeys.isEmpty
        guard snapshot.hasAnyRules || hasMarkedSpam else { return source }

        return source.filter { item in
            !snapshot.shouldHideAny(in: item.moderationEvents) && !isHiddenByManualSpam(item)
        }
    }

    private func pruneItemsForSource(
        _ source: [FeedItem],
        feedSource: HomePrimaryFeedSource? = nil,
        followingPubkeys: [String]? = nil
    ) -> [FeedItem] {
        let resolvedSource = feedSource ?? self.feedSource
        switch resolvedSource {
        case .following, .polls, .articles:
            let allowedAuthors = allowedFollowingAuthors(followingPubkeys: followingPubkeys)
            guard !allowedAuthors.isEmpty else { return [] }
            return source.filter { item in
                let isAllowedAuthor = allowedAuthors.contains(self.normalizePubkey(item.displayAuthorPubkey))
                guard isAllowedAuthor else { return false }
                if resolvedSource == .polls {
                    return item.displayEvent.pollMetadata != nil
                }
                if resolvedSource == .articles {
                    return Self.isVisibleArticle(item)
                }
                return true
            }
        default:
            return source
        }
    }

    private func itemIsAllowedForCurrentSource(_ item: FeedItem) -> Bool {
        switch feedSource {
        case .following:
            let allowedAuthors = allowedFollowingAuthors()
            guard !allowedAuthors.isEmpty else { return false }
            return allowedAuthors.contains(self.normalizePubkey(item.displayAuthorPubkey))
        case .articles:
            let allowedAuthors = allowedFollowingAuthors()
            guard !allowedAuthors.isEmpty else { return false }
            guard allowedAuthors.contains(self.normalizePubkey(item.displayAuthorPubkey)) else { return false }
            return Self.isVisibleArticle(item)
        case .polls:
            let allowedAuthors = allowedFollowingAuthors()
            guard !allowedAuthors.isEmpty else { return false }
            guard allowedAuthors.contains(self.normalizePubkey(item.displayAuthorPubkey)) else { return false }
            return item.displayEvent.pollMetadata != nil
        default:
            return true
        }
    }

    private func isHiddenByManualSpam(_ item: FeedItem) -> Bool {
        guard normalizePubkey(item.displayAuthorPubkey) != currentUserPubkey else { return false }
        return AppSettingsStore.shared.shouldHideSpamMarkedPubkey(item.displayAuthorPubkey)
    }

    private func sourceUsesFollowingAuthors(_ source: HomePrimaryFeedSource) -> Bool {
        switch source {
        case .following, .articles, .polls:
            return true
        default:
            return false
        }
    }

    private static func isVisibleArticle(_ item: FeedItem) -> Bool {
        item.event.kind == FeedKindFilters.longFormArticle &&
            !item.event.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func allowedFollowingAuthors(followingPubkeys: [String]? = nil) -> Set<String> {
        let followings = followingPubkeys ?? self.followingPubkeys
        return Set(
            Self.followingAuthorPubkeys(
                followingPubkeys: followings,
                currentUserPubkey: currentUserPubkey
            )
        )
    }

    private func filteredMainItems(ignoreMediaOnly: Bool = false) -> [FeedItem] {
        let key = VisibleItemsCacheKey(
            itemsRevision: itemsRevision,
            feedSource: feedSource,
            mode: mode,
            showKinds: showKinds,
            mediaOnly: mediaOnly,
            hideNSFW: AppSettingsStore.shared.hideNSFWContent,
            filterRevision: MuteStore.shared.filterRevision,
            spamFilterSignature: AppSettingsStore.shared.spamFilterLabelSignature,
            mutedConversationRevision: mutedConversationRevision,
            ignoreMediaOnly: ignoreMediaOnly
        )

        if visibleItemsCacheKey == key {
            return visibleItemsCache
        }

        let filtered = filterVisibleItems(items, ignoreMediaOnly: ignoreMediaOnly)
        visibleItemsCacheKey = key
        visibleItemsCache = filtered
        return filtered
    }

    private func clearVisibleItemsCache() {
        visibleItemsCacheKey = nil
        visibleItemsCache = []
    }

    private func loadFeedSourcePreference(pubkey: String?) -> HomePrimaryFeedSource {
        let key = feedSourceStorageKey(pubkey: pubkey)
        guard let raw = feedSourceStorage.string(forKey: key),
              let source = HomePrimaryFeedSource(storageValue: raw) else {
            return .network
        }
        return source
    }

    private func storeFeedSourcePreference(_ source: HomePrimaryFeedSource, pubkey: String?) {
        let key = feedSourceStorageKey(pubkey: pubkey)
        feedSourceStorage.set(source.storageValue, forKey: key)
    }

    private func feedSourceStorageKey(pubkey: String?) -> String {
        "\(feedSourceStoragePrefix).\(pubkey ?? "anonymous")"
    }

    static func persistedFeedSourceKey(pubkey: String?) -> String {
        "homeFeedSourcePreference.\(pubkey ?? "anonymous")"
    }

    private func mutedConversationStorageKey(pubkey: String?) -> String {
        "\(mutedConversationStoragePrefix).\(pubkey ?? "anonymous")"
    }

    private func loadMutedConversationIDs(pubkey: String?) -> Set<String> {
        let key = mutedConversationStorageKey(pubkey: pubkey)
        guard let raw = feedSourceStorage.stringArray(forKey: key) else { return [] }
        return Set(
            raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private func persistMutedConversationIDs(pubkey: String?) {
        let key = mutedConversationStorageKey(pubkey: pubkey)
        feedSourceStorage.set(Array(mutedConversationIDs).sorted(), forKey: key)
    }

    private func localFollowings() -> [String] {
        Array(FollowStore.shared.followedPubkeys)
            .map(normalizePubkey)
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func resolveFollowingPubkeys(
        currentUserPubkey: String,
        relayURLs: [URL],
        relayFetchMode: RelayFetchMode
    ) async throws -> [String] {
        var followings = localFollowings()
        if followings.isEmpty,
           let cachedSnapshot = await service.cachedFollowListSnapshot(pubkey: currentUserPubkey) {
            followings = cachedSnapshot.followedPubkeys
        }

        do {
            return try await service.fetchFollowings(
                relayURLs: relayURLs,
                pubkey: currentUserPubkey,
                relayFetchMode: relayFetchMode,
                relayOnly: true,
                fallbackToCachedSnapshot: false
            )
        } catch {
            if !followings.isEmpty {
                return followings
            }
            throw error
        }
    }

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func followingAuthorPubkeys(
        followingPubkeys: [String],
        currentUserPubkey: String?
    ) -> [String] {
        var ordered: [String] = []
        if let currentUserPubkey {
            ordered.append(currentUserPubkey)
        }
        ordered.append(contentsOf: followingPubkeys)

        var seen = Set<String>()
        return ordered.compactMap { rawPubkey in
            let normalized = rawPubkey
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    private static func normalizedFavoriteHashtags(_ hashtags: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for hashtag in hashtags {
            let normalized = HomePrimaryFeedSource.normalizeHashtag(hashtag)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func resolvedFeedSource(_ source: HomePrimaryFeedSource) -> HomePrimaryFeedSource {
        switch source {
        case .custom(let feedID):
            return customFeedDefinition(id: feedID) == nil ? .network : .custom(feedID)
        case .hashtag(let hashtag):
            let normalizedHashtag = HomePrimaryFeedSource.normalizeHashtag(hashtag)
            guard favoriteHashtags.contains(normalizedHashtag) else {
                return .network
            }
            return .hashtag(normalizedHashtag)
        case .relay(let relayURL):
            let normalizedRelayURL = HomePrimaryFeedSource.normalizeRelayURLString(relayURL)
            guard favoriteRelayURLs.contains(normalizedRelayURL) else {
                return .network
            }
            return .relay(normalizedRelayURL)
        case .polls:
            return pollsFeedVisible ? .polls : .network
        case .interests:
            return interestHashtags.isEmpty ? .network : .interests
        default:
            return source
        }
    }

    private func relayURLs(for source: HomePrimaryFeedSource) -> [URL] {
        switch source {
        case .trending:
            return [Self.trendingRelayURL]
        case .news:
            let newsRelays = Self.normalizedRelayURLs(AppSettingsStore.shared.newsRelayURLs)
            return newsRelays.isEmpty ? [Self.newsFallbackRelayURL] : newsRelays
        case .custom:
            let combined = Self.normalizedRelayURLs(readRelayURLs + Self.customFeedSupplementalRelayURLs)
            return combined.isEmpty ? readRelayURLs : combined
        case .relay(let relayURL):
            guard let normalizedRelayURL = RelayURLSupport.normalizedURL(from: relayURL) else {
                return readRelayURLs
            }
            return [normalizedRelayURL]
        default:
            return readRelayURLs
        }
    }

    private func hydrationRelayURLs(for source: HomePrimaryFeedSource) -> [URL] {
        switch source {
        case .trending:
            let combined = Self.normalizedRelayURLs(readRelayURLs + relayURLs(for: .trending))
            return combined.isEmpty ? [Self.trendingRelayURL] : combined
        case .news:
            let combined = Self.normalizedRelayURLs(readRelayURLs + relayURLs(for: .news))
            return combined.isEmpty ? [Self.newsFallbackRelayURL] : combined
        case .custom:
            return relayURLs(for: source)
        case .relay:
            let combined = Self.normalizedRelayURLs(readRelayURLs + relayURLs(for: source))
            return combined.isEmpty ? relayURLs(for: source) : combined
        default:
            return relayURLs(for: source)
        }
    }

    private func feedKinds(for source: HomePrimaryFeedSource) -> [Int] {
        switch source {
        case .interests:
            return FeedKindFilters.normalizedKinds(showKinds)
        case .articles:
            return [FeedKindFilters.longFormArticle]
        case .polls:
            return FeedKindFilters.pollKinds
        case .trending:
            return [1]
        case .news:
            return [1]
        case .custom:
            return FeedKindFilters.normalizedKinds(showKinds)
        default:
            return FeedKindFilters.normalizedKinds(showKinds)
        }
    }

    func customFeedDefinition(id: String) -> CustomFeedDefinition? {
        let normalizedID = HomePrimaryFeedSource.normalizeCustomFeedID(id)
        guard !normalizedID.isEmpty else { return nil }
        return customFeeds.first { $0.id == normalizedID }
    }

    private func normalizedOrderedPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys {
            let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func configuredNewsAuthorPubkeys() -> [String] {
        normalizedOrderedPubkeys(AppSettingsStore.shared.newsAuthorPubkeys)
    }

    private func configuredNewsHashtags() -> [String] {
        Self.normalizedFavoriteHashtags(AppSettingsStore.shared.newsHashtags)
    }

    private func configuredInterestHashtags() -> [String] {
        Self.normalizedFavoriteHashtags(interestHashtags)
    }

    private func fetchTrendingFeedPage(
        limit: Int,
        paginationState: TrendingPaginationState?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> TrendingPageFetchResult {
        guard limit > 0 else {
            return TrendingPageFetchResult(
                page: HomeFeedPageResult(items: [], hadMoreAvailable: false),
                nextState: nil
            )
        }

        guard paginationState == nil else {
            return TrendingPageFetchResult(
                page: HomeFeedPageResult(items: [], hadMoreAvailable: false),
                nextState: nil
            )
        }

        let pageItems = try await service.fetchTrendingNotes(
            limit: limit,
            hydrationRelayURLs: hydrationRelayURLs(for: .trending),
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        return TrendingPageFetchResult(
            page: HomeFeedPageResult(
                items: pageItems,
                hadMoreAvailable: false
            ),
            nextState: nil
        )
    }

    private func fetchFollowingFeedPage(
        relayURLs: [URL],
        authors: [String],
        kinds: [Int],
        limit: Int,
        until: Int?,
        mode: HomeFeedMode? = nil,
        minimumVisibleCount: Int? = nil,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        guard limit > 0, !authors.isEmpty else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let targetVisibleCount = max(1, min(limit, minimumVisibleCount ?? limit))
        let maxBackfillRounds = minimumVisibleCount == nil
            ? 6
            : (targetVisibleCount >= limit ? 4 : 2)
        let probeLimit: Int
        if minimumVisibleCount != nil {
            probeLimit = min(max(targetVisibleCount * 4, 80), 160)
        } else {
            probeLimit = min(max(limit * 4, 120), 240)
        }
        var collected: [FeedItem] = []
        var cursor = until
        var exhausted = false
        var lastBatchCount = 0
        var roundsCompleted = 0
        var nextPageCursor: Int?

        while roundsCompleted < maxBackfillRounds {
            let qualifiedCount = mode.map { Self.visibleItemCount(collected, mode: $0) } ?? collected.count
            if qualifiedCount >= targetVisibleCount {
                break
            }

            let fetchedEvents = try await service.fetchFollowingEvents(
                relayURLs: relayURLs,
                authors: authors,
                kinds: kinds,
                limit: probeLimit,
                until: cursor,
                fetchTimeout: fetchTimeout,
                relayFetchMode: relayFetchMode,
                relayOnly: true,
                moderationSnapshot: moderationSnapshot
            )
            lastBatchCount = fetchedEvents.count

            guard !fetchedEvents.isEmpty else {
                exhausted = true
                break
            }

            let fetched = await service.buildFeedItems(
                relayURLs: relayURLs,
                events: fetchedEvents,
                hydrationMode: hydrationMode,
                moderationSnapshot: moderationSnapshot
            )
            collected = mergeItemArrays(primary: collected, secondary: fetched)

            let updatedQualifiedCount = mode.map { Self.visibleItemCount(collected, mode: $0) } ?? collected.count
            if updatedQualifiedCount >= targetVisibleCount {
                break
            }

            guard let paginationCursor = feedPaginationCursor(from: fetchedEvents) else {
                exhausted = true
                break
            }
            nextPageCursor = paginationCursor

            let nextCursor = max(paginationCursor - 1, 0)
            guard nextCursor > 0, nextCursor != cursor else {
                exhausted = true
                break
            }

            cursor = nextCursor
            roundsCompleted += 1
        }

        let qualifiedCount = mode.map { Self.visibleItemCount(collected, mode: $0) } ?? collected.count
        let pageVisibleLimit = min(limit, max(qualifiedCount, 1))
        let pageItems = mode.map {
            Self.prefixForVisibleModeLimit(collected, mode: $0, visibleLimit: pageVisibleLimit)
        } ?? Array(collected.prefix(limit))
        let hadMoreAvailable =
            qualifiedCount > limit ||
            lastBatchCount >= probeLimit ||
            (!exhausted && !pageItems.isEmpty)

        return HomeFeedPageResult(
            items: pageItems,
            hadMoreAvailable: hadMoreAvailable,
            paginationCursor: nextPageCursor ?? pageItems.last?.event.createdAt
        )
    }

    private func fetchModeAwarePrimaryFeedPage(
        source: HomePrimaryFeedSource,
        relayURLs: [URL],
        kinds: [Int],
        limit: Int,
        until: Int?,
        mode: HomeFeedMode,
        minimumVisibleCount: Int,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        guard limit > 0 else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let maxBackfillRounds = minimumVisibleCount >= limit ? 4 : 2
        let targetVisibleCount = max(1, min(limit, minimumVisibleCount))
        let probeLimit = min(max(targetVisibleCount * 4, 60), 240)
        var collected: [FeedItem] = []
        var cursor = until
        var exhausted = false
        var lastBatchCount = 0
        var roundsCompleted = 0

        while roundsCompleted < maxBackfillRounds {
            if Self.visibleItemCount(collected, mode: mode) >= targetVisibleCount {
                break
            }

            let fetched: [FeedItem]
            switch source {
            case .network, .relay:
                fetched = try await service.fetchFeed(
                    relayURLs: relayURLs,
                    kinds: kinds,
                    limit: probeLimit,
                    until: cursor,
                    hydrationMode: hydrationMode,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode,
                    moderationSnapshot: moderationSnapshot
                )
            case .hashtag(let hashtag):
                fetched = try await service.fetchHashtagFeed(
                    relayURLs: relayURLs,
                    hashtag: hashtag,
                    kinds: kinds,
                    limit: probeLimit,
                    until: cursor,
                    hydrationMode: hydrationMode,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode,
                    moderationSnapshot: moderationSnapshot
                )
            case .interests:
                let hashtags = configuredInterestHashtags()
                guard !hashtags.isEmpty else {
                    return HomeFeedPageResult(items: [], hadMoreAvailable: false)
                }
                fetched = try await service.fetchHashtagFeed(
                    relayURLs: relayURLs,
                    hashtags: hashtags,
                    kinds: kinds,
                    limit: probeLimit,
                    until: cursor,
                    hydrationMode: hydrationMode,
                    fetchTimeout: fetchTimeout,
                    relayFetchMode: relayFetchMode,
                    moderationSnapshot: moderationSnapshot
                )
            default:
                return HomeFeedPageResult(items: [], hadMoreAvailable: false)
            }

            lastBatchCount = fetched.count
            guard !fetched.isEmpty else {
                exhausted = true
                break
            }

            collected = mergeItemArrays(primary: collected, secondary: fetched)

            if Self.visibleItemCount(collected, mode: mode) >= targetVisibleCount || fetched.count >= probeLimit {
                break
            }

            guard let oldestFetchedCreatedAt = fetched.last?.event.createdAt else {
                exhausted = true
                break
            }

            let nextCursor = max(oldestFetchedCreatedAt - 1, 0)
            guard nextCursor > 0, nextCursor != cursor else {
                exhausted = true
                break
            }

            cursor = nextCursor
            roundsCompleted += 1
        }

        let qualifiedCount = Self.visibleItemCount(collected, mode: mode)
        let pageVisibleLimit = min(limit, max(qualifiedCount, 1))
        let pageItems = Self.prefixForVisibleModeLimit(
            collected,
            mode: mode,
            visibleLimit: pageVisibleLimit
        )
        let hadMoreAvailable =
            qualifiedCount > limit ||
            lastBatchCount >= probeLimit ||
            (!exhausted && !pageItems.isEmpty)

        return HomeFeedPageResult(
            items: pageItems,
            hadMoreAvailable: hadMoreAvailable
        )
    }

    private nonisolated static func initialVisibleTarget(
        for source: HomePrimaryFeedSource,
        mode: HomeFeedMode?,
        limit: Int
    ) -> Int {
        let baseline: Int
        switch source {
        case .polls:
            baseline = pollsInitialVisibleTarget
        case .following:
            let _ = mode
            baseline = limit
        default:
            baseline = limit
        }

        return max(1, min(limit, baseline))
    }

    private nonisolated static func minimumVisibleItemsForSelectedMode(
        source: HomePrimaryFeedSource,
        mode: HomeFeedMode,
        pageSize: Int
    ) -> Int {
        switch source {
        case .following:
            return initialVisibleTarget(
                for: source,
                mode: mode,
                limit: pageSize
            )
        default:
            return min(max(pageSize / 3, 8), pageSize)
        }
    }

    private func sourceUsesModeAwareBackfill(_ source: HomePrimaryFeedSource) -> Bool {
        switch source {
        case .network, .relay, .following, .hashtag, .interests:
            return true
        default:
            return false
        }
    }

    private func fetchInterestsFeedPage(
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        let hashtags = configuredInterestHashtags()
        guard !hashtags.isEmpty else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let relayTargets = relayURLs(for: .interests)
        let kinds = feedKinds(for: .interests)
        let fetched = try await service.fetchHashtagFeed(
            relayURLs: relayTargets,
            hashtags: hashtags,
            kinds: kinds,
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        return HomeFeedPageResult(
            items: fetched,
            hadMoreAvailable: fetched.count >= limit
        )
    }

    private func fetchNewsFeedPage(
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        let newsRelayURLs = relayURLs(for: .news)
        let hydrationRelayURLs = hydrationRelayURLs(for: .news)
        let authors = configuredNewsAuthorPubkeys()
        let hashtags = configuredNewsHashtags()
        let perHashtagLimit = hashtags.isEmpty ? 0 : max(8, min(18, limit))

        async let relayItemsTask = service.fetchFeed(
            relayURLs: newsRelayURLs,
            kinds: [1],
            limit: limit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        async let authorItemsTask = authors.isEmpty
            ? [FeedItem]()
            : service.fetchFollowingFeedRecoveringWithOutbox(
                baseReadRelayURLs: hydrationRelayURLs,
                authors: authors,
                kinds: [1],
                limit: limit,
                until: until,
                hydrationMode: hydrationMode,
                fetchTimeout: fetchTimeout,
                relayFetchMode: relayFetchMode,
                moderationSnapshot: moderationSnapshot
            )
        async let hashtagItemsTask = fetchNewsHashtagItems(
            relayURLs: newsRelayURLs,
            hashtags: hashtags,
            perHashtagLimit: perHashtagLimit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )

        let relayItems = try await relayItemsTask
        let authorItems = try await authorItemsTask
        let hashtagItems = try await hashtagItemsTask

        var seenEventIDs = Set<String>()
        let mergedEvents = Array(
            (relayItems + authorItems + hashtagItems.flatMap { $0 })
                .map(\.event)
                .sorted(by: { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                })
                .filter { event in
                    seenEventIDs.insert(event.id.lowercased()).inserted
                }
        )

        let limitedEvents = Array(mergedEvents.prefix(limit))
        let hydrated = await service.buildFeedItems(
            relayURLs: hydrationRelayURLs,
            events: limitedEvents,
            hydrationMode: hydrationMode,
            moderationSnapshot: moderationSnapshot
        )

        let hadMoreAvailable =
            relayItems.count >= limit ||
            (!authors.isEmpty && authorItems.count >= limit) ||
            hashtagItems.contains(where: { $0.count >= perHashtagLimit }) ||
            mergedEvents.count > limit

        return HomeFeedPageResult(
            items: hydrated,
            hadMoreAvailable: hadMoreAvailable
        )
    }

    private func fetchNewsHashtagItems(
        relayURLs: [URL],
        hashtags: [String],
        perHashtagLimit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [[FeedItem]] {
        guard !hashtags.isEmpty, perHashtagLimit > 0 else { return [] }

        return try await withThrowingTaskGroup(of: [FeedItem].self) { group in
            for hashtag in hashtags {
                group.addTask { [self] in
                    try await self.service.fetchHashtagFeed(
                        relayURLs: relayURLs,
                        hashtag: hashtag,
                        kinds: [1],
                        limit: perHashtagLimit,
                        until: until,
                        hydrationMode: hydrationMode,
                        fetchTimeout: fetchTimeout,
                        relayFetchMode: relayFetchMode,
                        moderationSnapshot: moderationSnapshot
                    )
                }
            }

            var merged: [[FeedItem]] = []
            for try await items in group {
                merged.append(items)
            }
            return merged
        }
    }

    private func fetchCustomFeedPage(
        feed: CustomFeedDefinition,
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode = .full,
        fetchTimeout: TimeInterval = 12,
        relayFetchMode: RelayFetchMode = .allRelays,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> HomeFeedPageResult {
        guard limit > 0 else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let relayTargets = relayURLs(for: .custom(feed.id))
        let authors = Array(feed.authorPubkeys.prefix(400))
        let hashtags = feed.hashtags
        let phrases = feed.phrases

        guard !authors.isEmpty || !hashtags.isEmpty || !phrases.isEmpty else {
            return HomeFeedPageResult(items: [], hadMoreAvailable: false)
        }

        let perHashtagLimit = hashtags.isEmpty ? 0 : max(8, min(18, limit))
        let perPhraseLimit = phrases.isEmpty ? 0 : max(8, min(18, limit))

        async let authorItemsTask = authors.isEmpty
            ? [FeedItem]()
            : service.fetchFollowingFeed(
                relayURLs: relayTargets,
                authors: authors,
                kinds: kinds,
                limit: limit,
                until: until,
                hydrationMode: hydrationMode,
                fetchTimeout: fetchTimeout,
                relayFetchMode: relayFetchMode,
                relayOnly: true,
                moderationSnapshot: moderationSnapshot
            )
        async let hashtagItemsTask = fetchCustomFeedHashtagItems(
            hashtags: hashtags,
            relayTargets: relayTargets,
            kinds: kinds,
            limit: perHashtagLimit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )
        async let phraseItemsTask = fetchCustomFeedPhraseItems(
            phrases: phrases,
            relayTargets: relayTargets,
            kinds: kinds,
            limit: perPhraseLimit,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: fetchTimeout,
            relayFetchMode: relayFetchMode,
            moderationSnapshot: moderationSnapshot
        )

        let authorItems = try await authorItemsTask
        let hashtagItems = try await hashtagItemsTask
        let phraseItems = try await phraseItemsTask

        let mergedItems = mergeItemArrays(
            primary: authorItems + hashtagItems.flatMap { $0 } + phraseItems.flatMap { $0 },
            secondary: []
        )

        let limitedItems = Array(mergedItems.prefix(limit))
        let hadMoreAvailable =
            (!authors.isEmpty && authorItems.count >= limit) ||
            hashtagItems.contains(where: { $0.count >= perHashtagLimit }) ||
            phraseItems.contains(where: { $0.count >= perPhraseLimit }) ||
            mergedItems.count > limit

        return HomeFeedPageResult(
            items: limitedItems,
            hadMoreAvailable: hadMoreAvailable
        )
    }

    private func fetchCustomFeedHashtagItems(
        hashtags: [String],
        relayTargets: [URL],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [[FeedItem]] {
        guard !hashtags.isEmpty, limit > 0 else { return [] }

        return try await withThrowingTaskGroup(of: [FeedItem].self) { group in
            for hashtag in hashtags {
                group.addTask { [self] in
                    try await self.service.fetchHashtagFeed(
                        relayURLs: relayTargets,
                        hashtag: hashtag,
                        kinds: kinds,
                        limit: limit,
                        until: until,
                        hydrationMode: hydrationMode,
                        fetchTimeout: fetchTimeout,
                        relayFetchMode: relayFetchMode,
                        moderationSnapshot: moderationSnapshot
                    )
                }
            }

            var merged: [[FeedItem]] = []
            for try await items in group {
                merged.append(items)
            }
            return merged
        }
    }

    private func fetchCustomFeedPhraseItems(
        phrases: [String],
        relayTargets: [URL],
        kinds: [Int],
        limit: Int,
        until: Int?,
        hydrationMode: FeedItemHydrationMode,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [[FeedItem]] {
        guard !phrases.isEmpty, limit > 0 else { return [] }

        return try await withThrowingTaskGroup(of: [FeedItem].self) { group in
            for phrase in phrases {
                group.addTask { [self] in
                    let localItems = await self.service.searchLocalNotes(
                        query: phrase,
                        kinds: kinds,
                        limit: limit,
                        until: until,
                        hydrationMode: hydrationMode,
                        moderationSnapshot: moderationSnapshot
                    )

                    let remoteItems: [FeedItem]
                    do {
                        remoteItems = try await self.service.searchNotes(
                            relayURLs: relayTargets,
                            query: phrase,
                            kinds: kinds,
                            limit: limit,
                            until: until,
                            hydrationMode: hydrationMode,
                            fetchTimeout: fetchTimeout,
                            relayFetchMode: relayFetchMode,
                            moderationSnapshot: moderationSnapshot
                        )
                    } catch {
                        remoteItems = []
                    }

                    var byID: [String: FeedItem] = Dictionary(
                        uniqueKeysWithValues: remoteItems.map { ($0.id, $0) }
                    )

                    for item in localItems {
                        if let existing = byID[item.id] {
                            byID[item.id] = existing.merged(with: item)
                        } else {
                            byID[item.id] = item
                        }
                    }

                    return byID.values.sorted {
                        if $0.event.createdAt == $1.event.createdAt {
                            return $0.id > $1.id
                        }
                        return $0.event.createdAt > $1.event.createdAt
                    }
                }
            }

            var merged: [[FeedItem]] = []
            for try await items in group {
                merged.append(items)
            }
            return merged
        }
    }

    private func scheduleAssetPrefetch(for sourceItems: [FeedItem]) {
        let prefetchItems = Array(sourceItems.prefix(assetPrefetchItemCount))
        let urls = Array(
            prefetchItems.flatMap(\.prefetchImageURLs)
        )
        let mediaEvents = prefetchItems.map(\.displayEvent)
        guard !urls.isEmpty || !mediaEvents.isEmpty else { return }

        Task(priority: .utility) {
            async let imagePrefetch: Void = FlowImageCache.shared.prefetch(urls: urls)
            async let geometryPrefetch: Void = NoteMediaGeometryPrefetcher.shared.prefetch(events: mediaEvents)
            _ = await (imagePrefetch, geometryPrefetch)
        }
    }
}
