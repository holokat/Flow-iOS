import Foundation

@MainActor
final class HomeFeedViewModel: ObservableObject {
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
    @Published var feedSource: HomePrimaryFeedSource = .following
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
    private let pageFetcher: HomeFeedPageFetching
    private let liveSubscriber: NostrLiveFeedSubscriber
    private let filterStore: HomeFeedFilterStore

    private let assetPrefetchItemCount = 24
    private let feedSourceStorage = UserDefaults.standard
    private let feedSourceStoragePrefix = "homeFeedSourcePreference"
    private let mutedConversationStoragePrefix = "homeFeedMutedConversations"

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
    private var pendingLiveEventsByID: [String: NostrEvent] = [:]
    private var liveEventFlushTask: Task<Void, Never>?
    private var hydrationUpgradeTasks: [UUID: Task<Void, Never>] = [:]
    private var liveEventGeneration = 0
    private var liveCatchUpToken = 0
    private var lastLiveCatchUpBySignature: [String: Date] = [:]
    private var resetFeedTask: Task<Void, Never>?
    private var isPrefetchingMore = false
    private var latestRefreshRequestID = 0
    private var trendingPaginationState: TrendingPaginationState?
    private var hasRetriedEmptyTrendingLoad = false
    private var trendingEmptyRetryTask: Task<Void, Never>?
    private static let liveEventFlushDelayNanoseconds: UInt64 = 50_000_000

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
        self.pageFetcher = HomeFeedPageFetching(service: service)
        self.liveSubscriber = liveSubscriber
        self.filterStore = filterStore
        self.showKinds = defaults.showKinds
        self.mediaOnly = defaults.mediaOnly
    }

    deinit {
        liveUpdatesTask?.cancel()
        liveCatchUpTask?.cancel()
        liveEventFlushTask?.cancel()
        hydrationUpgradeTasks.values.forEach { $0.cancel() }
        liveEventGeneration &+= 1
        resetFeedTask?.cancel()
        trendingEmptyRetryTask?.cancel()
    }

    var feedSourceOptions: [HomePrimaryFeedSource] {
        let hashtagSources = favoriteHashtags.map { HomePrimaryFeedSource.hashtag($0) }
        let relaySources = favoriteRelayURLs.map { HomePrimaryFeedSource.relay($0) }
        let interestSources: [HomePrimaryFeedSource] = interestHashtags.isEmpty ? [] : [.interests]
        let customSources = customFeeds.map { HomePrimaryFeedSource.custom($0.id) }
        let pollsSources: [HomePrimaryFeedSource] = pollsFeedVisible ? [.polls] : []
        return [.following, .articles] + pollsSources + [.trending] + interestSources + [.news] + customSources + relaySources + hashtagSources
    }

    var supportsModeTabsForCurrentSource: Bool {
        Self.supportsModeTabs(for: feedSource)
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
            feedSource = .following
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
            feedSource = .following
            storeFeedSourcePreference(feedSource, pubkey: currentUserPubkey)
            resetFeedStateAndReload()
        }
    }

    func updatePollsFeedVisibility(_ isVisible: Bool) {
        guard pollsFeedVisible != isVisible else { return }

        pollsFeedVisible = isVisible

        if feedSource == .polls && !isVisible {
            feedSource = .following
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
            feedSource = .following
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
            feedSource = .following
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

        if requestSource == .trending, !silent {
            hasRetriedEmptyTrendingLoad = false
        }

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
                let networkPage = try await pageFetcher.fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    interestHashtags: configuredInterestHashtags(),
                    limit: pageSize,
                    until: nil,
                    mode: Self.modeForFetch(source: requestSource, selectedMode: mode),
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
                let interestPage = try await pageFetcher.fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    interestHashtags: configuredInterestHashtags(),
                    limit: pageSize,
                    until: nil,
                    mode: Self.modeForFetch(source: requestSource, selectedMode: mode),
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
                let trendingPage = try await pageFetcher.fetchTrendingFeedPage(
                    hydrationRelayURLs: hydrationRelayURLs(for: .trending),
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
                let newsPage = try await pageFetcher.fetchNewsFeedPage(
                    newsRelayURLs: relayURLs(for: .news),
                    hydrationRelayURLs: hydrationRelayURLs(for: .news),
                    authors: configuredNewsAuthorPubkeys(),
                    hashtags: configuredNewsHashtags(),
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
                let customPage = try await pageFetcher.fetchCustomFeedPage(
                    feed: feed,
                    relayTargets: relayURLs(for: .custom(feed.id)),
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
                let hashtagPage = try await pageFetcher.fetchModeAwarePrimaryFeedPage(
                    source: .hashtag(hashtag),
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    interestHashtags: configuredInterestHashtags(),
                    limit: pageSize,
                    until: nil,
                    mode: Self.modeForFetch(source: requestSource, selectedMode: mode),
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

                let followingPage = try await pageFetcher.fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: followingFeedAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    feedSource: requestSource,
                    mode: Self.modeForFetch(source: requestSource, selectedMode: mode),
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

                let articlesPage = try await pageFetcher.fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: articleAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: nil,
                    feedSource: requestSource,
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

                let pollsPage = try await pageFetcher.fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: pollAuthors,
                    kinds: FeedKindFilters.pollKinds,
                    limit: pageSize,
                    until: nil,
                    feedSource: requestSource,
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
            scheduleTrendingRetryAfterEmptyInitialLoadIfNeeded(
                fetched: fetched,
                requestSource: requestSource,
                publishFetchedItems: publishFetchedItems,
                startedWithEmptyItems: startedWithEmptyItems
            )

            if Self.shouldRunImmediateHydrationUpgrade(
                for: requestSource,
                requestHydrationMode: requestHydrationMode,
                fastHydrationMode: fastHydrationMode
            ),
               !stagedHydrationEvents.isEmpty {
                scheduleHydrationUpgrade(
                    relayURLs: requestRelayURLs,
                    events: stagedHydrationEvents,
                    hydrationMode: requestHydrationMode,
                    requestSource: requestSource,
                    requestUserPubkey: requestUserPubkey,
                    requestKinds: requestKinds,
                    requestID: refreshRequestID
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
                errorMessage = "Sign in to view this feed."
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
                let networkPage = try await pageFetcher.fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    interestHashtags: configuredInterestHashtags(),
                    limit: pageSize,
                    until: until,
                    mode: Self.modeForFetch(source: requestSource, selectedMode: mode),
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
                let interestPage = try await pageFetcher.fetchModeAwarePrimaryFeedPage(
                    source: requestSource,
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    interestHashtags: configuredInterestHashtags(),
                    limit: pageSize,
                    until: until,
                    mode: Self.modeForFetch(source: requestSource, selectedMode: mode),
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
                let trendingPage = try await pageFetcher.fetchTrendingFeedPage(
                    hydrationRelayURLs: hydrationRelayURLs(for: .trending),
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
                let newsPage = try await pageFetcher.fetchNewsFeedPage(
                    newsRelayURLs: relayURLs(for: .news),
                    hydrationRelayURLs: hydrationRelayURLs(for: .news),
                    authors: configuredNewsAuthorPubkeys(),
                    hashtags: configuredNewsHashtags(),
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
                let customPage = try await pageFetcher.fetchCustomFeedPage(
                    feed: feed,
                    relayTargets: relayURLs(for: .custom(feed.id)),
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
                let hashtagPage = try await pageFetcher.fetchModeAwarePrimaryFeedPage(
                    source: .hashtag(hashtag),
                    relayURLs: requestRelayURLs,
                    kinds: requestKinds,
                    interestHashtags: configuredInterestHashtags(),
                    limit: pageSize,
                    until: until,
                    mode: Self.modeForFetch(source: requestSource, selectedMode: mode),
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

                let followingPage = try await pageFetcher.fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: followingFeedAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    feedSource: requestSource,
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

                let articlesPage = try await pageFetcher.fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: articleAuthors,
                    kinds: requestKinds,
                    limit: pageSize,
                    until: until,
                    feedSource: requestSource,
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

                let pollsPage = try await pageFetcher.fetchFollowingFeedPage(
                    relayURLs: requestRelayURLs,
                    authors: pollAuthors,
                    kinds: FeedKindFilters.pollKinds,
                    limit: pageSize,
                    until: until,
                    feedSource: requestSource,
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

            if Self.shouldRunImmediateHydrationUpgrade(
                for: requestSource,
                requestHydrationMode: requestHydrationMode,
                fastHydrationMode: fastHydrationMode
            ),
               !stagedHydrationEvents.isEmpty {
                scheduleHydrationUpgrade(
                    relayURLs: requestRelayURLs,
                    events: stagedHydrationEvents,
                    hydrationMode: requestHydrationMode,
                    requestSource: requestSource,
                    requestUserPubkey: currentUserPubkey,
                    requestKinds: requestKinds,
                    requestID: requestRefreshID
                )
            }
        } catch {
            errorMessage = "Couldn't load more posts."
        }
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
            self.clearPendingLiveEvents()
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
        hasRetriedEmptyTrendingLoad = false
        followingPubkeys = []
        errorMessage = nil

        trendingEmptyRetryTask?.cancel()
        trendingEmptyRetryTask = nil
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        liveCatchUpTask?.cancel()
        liveCatchUpTask = nil
        hydrationUpgradeTasks.values.forEach { $0.cancel() }
        hydrationUpgradeTasks.removeAll()
        clearPendingLiveEvents()
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
        guard !liveKinds.isEmpty else {
            liveUpdatesTask?.cancel()
            liveUpdatesTask = nil
            liveCatchUpTask?.cancel()
            liveCatchUpTask = nil
            clearPendingLiveEvents()
            return
        }
        let source = feedSource
        let targets = liveSubscriptionTargets(for: source, kinds: liveKinds)
        guard !targets.isEmpty else {
            liveUpdatesTask?.cancel()
            liveUpdatesTask = nil
            liveCatchUpTask?.cancel()
            liveCatchUpTask = nil
            clearPendingLiveEvents()
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
        clearPendingLiveEvents()
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

    private func scheduleHydrationUpgrade(
        relayURLs: [URL],
        events: [NostrEvent],
        hydrationMode: FeedItemHydrationMode,
        requestSource: HomePrimaryFeedSource,
        requestUserPubkey: String?,
        requestKinds: [Int],
        requestID: Int
    ) {
        let taskID = UUID()
        let service = service
        let moderationSnapshot = muteFilterSnapshot

        hydrationUpgradeTasks[taskID] = Task(priority: .utility) { [weak self] in
            let upgradedItems = await service.buildFeedItems(
                relayURLs: relayURLs,
                events: events,
                hydrationMode: hydrationMode,
                moderationSnapshot: moderationSnapshot
            )
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.hydrationUpgradeTasks[taskID] = nil }

                guard self.latestRefreshRequestID == requestID,
                      self.feedSource == requestSource,
                      self.currentUserPubkey == requestUserPubkey else { return }

                if requestSource != .news,
                   requestSource != .trending,
                   requestSource != .articles,
                   requestSource != .polls,
                   !FeedKindFilters.isSameSelection(requestKinds, self.showKinds) {
                    return
                }

                self.applyHydrationUpgrade(
                    fetched: upgradedItems,
                    requestSource: requestSource
                )
            }
        }
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

        pendingLiveEventsByID[normalizedEventID] = event
        guard liveEventFlushTask == nil else { return }

        liveEventFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveEventFlushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.flushPendingLiveEvents()
            }
        }
    }

    private func flushPendingLiveEvents() {
        let events = pendingLiveEventsByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
        pendingLiveEventsByID.removeAll()
        liveEventFlushTask = nil
        guard !events.isEmpty else { return }
        Task {
            await WispParityDiagnosticsStore.shared.recordLiveBatchFlushed()
        }

        let service = service
        let relayURLs = hydrationRelayURLs(for: feedSource)
        let moderationSnapshot = muteFilterSnapshot
        let source = feedSource
        let generation = liveEventGeneration

        Task { [weak self, events, relayURLs, moderationSnapshot, service, source, generation] in
            await service.ingestLiveEvents(events)

            let hydrated = await service.buildFeedItems(
                relayURLs: relayURLs,
                events: events,
                moderationSnapshot: moderationSnapshot
            )

            await MainActor.run { [weak self] in
                guard let self,
                      self.liveEventGeneration == generation,
                      self.feedSource == source else { return }
                self.applyLiveItems(hydrated)
            }
        }
    }

    private func applyLiveItems(_ hydrated: [FeedItem]) {
        let liveItems = hydrated.filter { item in
            !knownEventIDs.contains(item.id) && itemIsAllowedForCurrentSource(item)
        }
        guard !liveItems.isEmpty else { return }

        let currentArticleReplacementKeys = feedSource == .articles
            ? Self.articleReplacementKeys(in: items)
            : []
        let articleReplacementItems = feedSource == .articles
            ? liveItems.filter { Self.containsArticleReplacement(for: $0, in: currentArticleReplacementKeys) }
            : []
        if feedSource == .articles, !articleReplacementItems.isEmpty {
            items = pruneItemsForSource(
                pruneMutedItems(
                    mergeItemArrays(
                        primary: articleReplacementItems,
                        secondary: items,
                        feedSource: feedSource
                    )
                )
            )
            let visibleItemIDs = Set(items.map(\.id))
            let visibleArticleReplacementKeys = Self.articleReplacementKeys(in: items)
            bufferedNewItems = mergeItemArrays(
                primary: bufferedNewItems,
                secondary: [],
                feedSource: feedSource
            ).filter {
                !visibleItemIDs.contains($0.id) &&
                    !Self.containsArticleReplacement(for: $0, in: visibleArticleReplacementKeys)
            }
            knownEventIDs = visibleItemIDs
            knownEventIDs.formUnion(bufferedNewItems.map(\.id))
            scheduleAssetPrefetch(for: articleReplacementItems)
        }

        let bufferedItems = liveItems.filter { item in
            !(feedSource == .articles &&
                Self.containsArticleReplacement(for: item, in: currentArticleReplacementKeys))
        }
        guard !bufferedItems.isEmpty else { return }

        bufferedNewItems = mergeItemArrays(
            primary: bufferedItems,
            secondary: bufferedNewItems,
            feedSource: feedSource
        )
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
        scheduleAssetPrefetch(for: bufferedItems)
    }

    private func clearPendingLiveEvents() {
        liveEventFlushTask?.cancel()
        liveEventFlushTask = nil
        pendingLiveEventsByID.removeAll()
        liveEventGeneration &+= 1
    }

    private func mergeKeepingNewest(itemsToMerge: [FeedItem]) {
        LocalPublicationStore.shared.mergeFetchedItems(itemsToMerge)
        items = pruneItemsForSource(
            pruneMutedItems(
                mergeItemArrays(
                    primary: itemsToMerge,
                    secondary: items,
                    feedSource: feedSource
                )
            )
        )
        scheduleAssetPrefetch(for: items)

        let currentlyVisibleIDs = Set(items.map(\.id))
        let currentArticleReplacementKeys = Self.articleReplacementKeys(in: items)
        bufferedNewItems.removeAll {
            currentlyVisibleIDs.contains($0.id) ||
                (feedSource == .articles &&
                    Self.containsArticleReplacement(for: $0, in: currentArticleReplacementKeys))
        }

        knownEventIDs = currentlyVisibleIDs
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
    }

    private func applyHydrationUpgrade(
        fetched: [FeedItem],
        requestSource: HomePrimaryFeedSource
    ) {
        guard !fetched.isEmpty else { return }

        LocalPublicationStore.shared.mergeFetchedItems(fetched)
        let normalizedFetched = mergeItemArrays(
            primary: fetched,
            secondary: [],
            feedSource: requestSource
        )

        let existingVisibleItems = items
        let existingVisibleIDs = Set(existingVisibleItems.map(\.id))
        let existingVisibleArticleReplacementKeys = Self.articleReplacementKeys(in: existingVisibleItems)
        let refreshedVisibleCandidates = normalizedFetched.filter { item in
            existingVisibleIDs.contains(item.id) ||
                (requestSource == .articles &&
                    Self.containsArticleReplacement(
                        for: item,
                        in: existingVisibleArticleReplacementKeys
                    ))
        }
        let refreshedVisibleItems = pruneItemsForSource(
            pruneMutedItems(
                mergeItemArrays(
                    primary: refreshedVisibleCandidates,
                    secondary: existingVisibleItems,
                    feedSource: requestSource
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
        let refreshedVisibleArticleReplacementKeys = Self.articleReplacementKeys(in: refreshedVisibleItems)
        let existingBufferedItems = bufferedNewItems
        let existingBufferedIDs = Set(existingBufferedItems.map(\.id))
        let existingBufferedArticleReplacementKeys = Self.articleReplacementKeys(in: existingBufferedItems)
        let refreshedBufferedCandidates = normalizedFetched.filter { item in
            existingBufferedIDs.contains(item.id) ||
                (requestSource == .articles &&
                    Self.containsArticleReplacement(
                        for: item,
                        in: existingBufferedArticleReplacementKeys
                    ))
        }
        bufferedNewItems = mergeItemArrays(
            primary: refreshedBufferedCandidates,
            secondary: existingBufferedItems,
            feedSource: requestSource
        ).filter {
            !visibleItemIDs.contains($0.id) &&
                !(requestSource == .articles &&
                    Self.containsArticleReplacement(
                        for: $0,
                        in: refreshedVisibleArticleReplacementKeys
                    ))
        }

        knownEventIDs = visibleItemIDs
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
        let prefetchedVisibleItems = didUpdateVisibleItems
            ? refreshedVisibleItems.filter { existingVisibleIDs.contains($0.id) }
            : []
        scheduleAssetPrefetch(for: prefetchedVisibleItems + refreshedBufferedCandidates)
    }

    private func applyRefreshResults(
        fetched: [FeedItem],
        requestSource: HomePrimaryFeedSource,
        sourcePageResult: HomeFeedPageResult?,
        publishFetchedItems: Bool,
        startedWithEmptyItems: Bool
    ) {
        LocalPublicationStore.shared.mergeFetchedItems(fetched)
        let normalizedFetched = mergeItemArrays(
            primary: fetched,
            secondary: [],
            feedSource: requestSource
        )

        let refreshItems = startedWithEmptyItems
            ? mergeItemArrays(
                primary: normalizedFetched,
                secondary: bufferedNewItems,
                feedSource: requestSource
            )
            : normalizedFetched
        let refreshItemsWithLocalPublications = mergeItemArrays(
            primary: refreshItems,
            secondary: localPublicationItems(for: requestSource),
            feedSource: requestSource
        )
        let shouldKeepVisibleRows = !publishFetchedItems
        let visibleSourceItems = shouldKeepVisibleRows ? items : []
        let mergedItems = pruneItemsForSource(
            pruneMutedItems(
                mergeItemArrays(
                    primary: shouldKeepVisibleRows ? refreshItemsWithLocalPublications : visibleSourceItems,
                    secondary: shouldKeepVisibleRows ? visibleSourceItems : refreshItemsWithLocalPublications,
                    feedSource: requestSource
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
            let existingVisibleArticleReplacementKeys = Self.articleReplacementKeys(in: existingVisibleItems)
            let refreshedVisibleCandidates = mergedItems.filter { item in
                existingVisibleIDs.contains(item.id) ||
                    (requestSource == .articles &&
                        Self.containsArticleReplacement(
                            for: item,
                            in: existingVisibleArticleReplacementKeys
                        ))
            }
            let refreshedVisibleItems = pruneItemsForSource(
                pruneMutedItems(
                    mergeItemArrays(
                        primary: refreshedVisibleCandidates,
                        secondary: existingVisibleItems,
                        feedSource: requestSource
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
            let refreshedVisibleArticleReplacementKeys = Self.articleReplacementKeys(
                in: refreshedVisibleItems
            )
            let unpublishedItems = mergedItems.filter { item in
                !visibleItemIDs.contains(item.id) &&
                    !(requestSource == .articles &&
                        Self.containsArticleReplacement(
                            for: item,
                            in: refreshedVisibleArticleReplacementKeys
                        ))
            }
            bufferedNewItems = mergeItemArrays(
                primary: unpublishedItems,
                secondary: existingBufferedItems,
                feedSource: requestSource
            ).filter {
                !visibleItemIDs.contains($0.id) &&
                    !(requestSource == .articles &&
                        Self.containsArticleReplacement(
                            for: $0,
                            in: refreshedVisibleArticleReplacementKeys
                        ))
            }
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

    private func scheduleTrendingRetryAfterEmptyInitialLoadIfNeeded(
        fetched: [FeedItem],
        requestSource: HomePrimaryFeedSource,
        publishFetchedItems: Bool,
        startedWithEmptyItems: Bool
    ) {
        guard requestSource == .trending else { return }

        if !fetched.isEmpty {
            trendingEmptyRetryTask?.cancel()
            trendingEmptyRetryTask = nil
            return
        }

        guard publishFetchedItems,
              startedWithEmptyItems,
              items.isEmpty,
              !hasRetriedEmptyTrendingLoad else {
            return
        }

        hasRetriedEmptyTrendingLoad = true
        trendingEmptyRetryTask?.cancel()
        trendingEmptyRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.trendingEmptyRetryDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.retryTrendingIfStillEmpty()
        }
    }

    private func retryTrendingIfStillEmpty() async {
        guard feedSource == .trending else { return }
        guard items.isEmpty, visibleItems.isEmpty else { return }

        await refresh(silent: true, force: true)
    }

    private func localPublicationItems(for requestSource: HomePrimaryFeedSource) -> [FeedItem] {
        let localPublicationIDs = Set(LocalPublicationStore.shared.records.map(\.id))
        let currentLocalItems = mergeItemArrays(
            primary: items,
            secondary: bufferedNewItems,
            feedSource: requestSource
        )
            .filter { localPublicationIDs.contains($0.id) }
        return pruneItemsForSource(
            pruneMutedItems(currentLocalItems),
            feedSource: requestSource,
            followingPubkeys: sourceUsesFollowingAuthors(requestSource) ? followingPubkeys : nil
        )
    }

    private func liveSubscriptionTargets(
        for source: HomePrimaryFeedSource,
        kinds: [Int]
    ) -> [HomeFeedLiveSubscriptionTarget] {
        HomeFeedLiveUpdatePlanner.subscriptionTargets(
            for: source,
            kinds: kinds,
            readRelayURLs: readRelayURLs,
            interestHashtags: interestHashtags,
            customFeeds: customFeeds,
            followingPubkeys: followingPubkeys,
            currentUserPubkey: currentUserPubkey
        )
    }

    private func mergeItemArrays(
        primary: [FeedItem],
        secondary: [FeedItem],
        feedSource: HomePrimaryFeedSource? = nil
    ) -> [FeedItem] {
        var byID: [String: FeedItem] = Dictionary(uniqueKeysWithValues: secondary.map { ($0.id, $0) })

        for item in primary {
            if let existing = byID[item.id] {
                byID[item.id] = existing.merged(with: item)
            } else {
                byID[item.id] = item
            }
        }

        return Self.sortedMergedItems(Array(byID.values), feedSource: feedSource)
    }

    private func filterVisibleItems(_ source: [FeedItem], ignoreMediaOnly: Bool = false) -> [FeedItem] {
        HomeFeedVisibilityFilter.visibleItems(
            source,
            configuration: visibilityConfiguration(ignoreMediaOnly: ignoreMediaOnly)
        )
    }

    private func pruneMutedItems(
        _ source: [FeedItem],
        snapshot: MuteFilterSnapshot? = nil
    ) -> [FeedItem] {
        HomeFeedVisibilityFilter.pruneMutedItems(
            source,
            configuration: visibilityConfiguration(muteSnapshot: snapshot)
        )
    }

    private func pruneItemsForSource(
        _ source: [FeedItem],
        feedSource: HomePrimaryFeedSource? = nil,
        followingPubkeys: [String]? = nil
    ) -> [FeedItem] {
        HomeFeedVisibilityFilter.pruneItemsForSource(
            source,
            configuration: visibilityConfiguration(
                feedSource: feedSource,
                followingPubkeys: followingPubkeys
            )
        )
    }

    private func itemIsAllowedForCurrentSource(_ item: FeedItem) -> Bool {
        HomeFeedVisibilityFilter.isAllowedForCurrentSource(
            item,
            configuration: visibilityConfiguration()
        )
    }

    private func sourceUsesFollowingAuthors(_ source: HomePrimaryFeedSource) -> Bool {
        HomeFeedVisibilityFilter.sourceUsesFollowingAuthors(source)
    }

    private func allowedFollowingAuthors(followingPubkeys: [String]? = nil) -> Set<String> {
        HomeFeedVisibilityFilter.allowedFollowingAuthors(
            configuration: visibilityConfiguration(followingPubkeys: followingPubkeys)
        )
    }

    private func visibilityConfiguration(
        feedSource: HomePrimaryFeedSource? = nil,
        followingPubkeys: [String]? = nil,
        muteSnapshot: MuteFilterSnapshot? = nil,
        ignoreMediaOnly: Bool = false
    ) -> HomeFeedVisibilityFilter.Configuration {
        let settings = AppSettingsStore.shared
        return HomeFeedVisibilityFilter.Configuration(
            feedSource: feedSource ?? self.feedSource,
            mode: mode,
            showKinds: showKinds,
            mediaOnly: mediaOnly,
            ignoreMediaOnly: ignoreMediaOnly,
            followingPubkeys: followingPubkeys ?? self.followingPubkeys,
            currentUserPubkey: currentUserPubkey,
            mutedConversationIDs: mutedConversationIDs,
            muteSnapshot: muteSnapshot ?? muteFilterSnapshot,
            hideNSFW: settings.hideNSFWContent,
            spamMarkedPubkeys: Set(settings.spamFilterMarkedPubkeys),
            spamSafelistedPubkeys: Set(settings.spamReplyFilterSafelistedPubkeys)
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
            return .following
        }
        return source == .network ? .following : source
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

    private func resolvedFeedSource(_ source: HomePrimaryFeedSource) -> HomePrimaryFeedSource {
        switch source {
        case .custom(let feedID):
            return customFeedDefinition(id: feedID) == nil ? .following : .custom(feedID)
        case .hashtag(let hashtag):
            let normalizedHashtag = HomePrimaryFeedSource.normalizeHashtag(hashtag)
            guard favoriteHashtags.contains(normalizedHashtag) else {
                return .following
            }
            return .hashtag(normalizedHashtag)
        case .relay(let relayURL):
            let normalizedRelayURL = HomePrimaryFeedSource.normalizeRelayURLString(relayURL)
            guard favoriteRelayURLs.contains(normalizedRelayURL) else {
                return .following
            }
            return .relay(normalizedRelayURL)
        case .polls:
            return pollsFeedVisible ? .polls : .following
        case .interests:
            return interestHashtags.isEmpty ? .following : .interests
        case .network:
            return .following
        default:
            return source
        }
    }

    private func relayURLs(for source: HomePrimaryFeedSource) -> [URL] {
        HomeFeedSourceResolver.relayURLs(for: source, readRelayURLs: readRelayURLs)
    }

    private func hydrationRelayURLs(for source: HomePrimaryFeedSource) -> [URL] {
        HomeFeedSourceResolver.hydrationRelayURLs(for: source, readRelayURLs: readRelayURLs)
    }

    private func feedKinds(for source: HomePrimaryFeedSource) -> [Int] {
        HomeFeedSourceResolver.feedKinds(for: source, showKinds: showKinds)
    }

    func customFeedDefinition(id: String) -> CustomFeedDefinition? {
        HomeFeedSourceResolver.customFeedDefinition(id: id, customFeeds: customFeeds)
    }

    private func configuredNewsAuthorPubkeys() -> [String] {
        HomeFeedSourceResolver.configuredNewsAuthorPubkeys()
    }

    private func configuredNewsHashtags() -> [String] {
        HomeFeedSourceResolver.configuredNewsHashtags()
    }

    private func configuredInterestHashtags() -> [String] {
        HomeFeedSourceResolver.configuredInterestHashtags(interestHashtags)
    }

    private func sourceUsesModeAwareBackfill(_ source: HomePrimaryFeedSource) -> Bool {
        Self.supportsModeTabs(for: source)
    }

    private func scheduleAssetPrefetch(for sourceItems: [FeedItem]) {
        let prefetchItems = Array(sourceItems.prefix(assetPrefetchItemCount))
        guard !prefetchItems.isEmpty else { return }

        Task(priority: .utility) {
            let urls = Array(
                prefetchItems.flatMap(\.prefetchImageURLs)
            )
            let mediaEvents = prefetchItems.map(\.displayEvent)
            guard !urls.isEmpty || !mediaEvents.isEmpty else { return }

            async let imagePrefetch: Void = FlowImageCache.shared.prefetch(urls: urls)
            async let geometryPrefetch: Void = NoteMediaGeometryPrefetcher.shared.prefetch(events: mediaEvents)
            _ = await (imagePrefetch, geometryPrefetch)
        }
    }
}

#if DEBUG
extension HomeFeedViewModel {
    func handleLiveEventForTesting(_ event: NostrEvent) async {
        await handleLiveEvent(event)
    }

    func flushLiveEventsForTesting() {
        liveEventFlushTask?.cancel()
        liveEventFlushTask = nil
        flushPendingLiveEvents()
    }
}
#endif
