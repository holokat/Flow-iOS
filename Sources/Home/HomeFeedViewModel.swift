import Foundation

@MainActor
final class HomeFeedViewModel: ObservableObject {
    @Published private(set) var items: [FeedItem] = [] {
        didSet {
            itemsRevision &+= 1
            clearMainVisibleItemsCache()
        }
    }
    @Published private(set) var bufferedNewItems: [FeedItem] = [] {
        didSet {
            bufferedItemsRevision &+= 1
            clearBufferedVisibleItemsCache()
        }
    }
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

    private let feedSourceStorage = UserDefaults.standard
    private let feedSourceStoragePrefix = "homeFeedSourcePreference"
    private let mutedConversationStoragePrefix = "homeFeedMutedConversations"

    private var oldestCreatedAt: Int?
    private var hasReachedEnd = false
    private var isSilentRefreshing = false
    private var needsRefreshAfterCurrentRequest = false
    private var knownEventIDs = Set<String>()
    private var followingPubkeys: [String] = []
    private var followingAuthorsRevision = 0
    private var currentUserPubkey: String?
    private var mutedConversationIDs = Set<String>() {
        didSet {
            mutedConversationRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    private var itemsRevision = 0
    private var bufferedItemsRevision = 0
    private var mutedConversationRevision = 0
    private var visibleItemsCacheKey: VisibleItemsCacheKey?
    private var visibleItemsCache: [FeedItem] = []
    private var bufferedVisibleItemsCacheKey: VisibleItemsCacheKey?
    private var bufferedVisibleItemsCache: [FeedItem] = []
    private var bufferedRetainedItemsCache: [FeedItem] = []

    private var liveSubscriptionKinds: [Int] = []
    private var liveSubscriptionSource: HomePrimaryFeedSource?
    private var liveSubscriptionConfigurationSignature: String?
    private var liveUpdatesTask: Task<Void, Never>?
    private var liveCatchUpTask: Task<Void, Never>?
    private var liveCatchUpToken = 0
    private var lastLiveCatchUpBySignature: [String: Date] = [:]
    private var resetFeedTask: Task<Void, Never>?
    private var profileUpdatesTask: Task<Void, Never>?
    private var profileApplyTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var pendingResolvedProfiles: [String: NostrProfile] = [:]
    private var backgroundUpdatesPaused = false
    private var isPrefetchingMore = false
    private var latestRefreshRequestID = 0
    private var trendingPaginationState: TrendingPaginationState?
    private var hasRetriedEmptyTrendingLoad = false
    private var trendingEmptyRetryTask: Task<Void, Never>?

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

        startObservingProfileUpdates()
        startObservingConnectionRecovery()
    }

    deinit {
        liveUpdatesTask?.cancel()
        liveCatchUpTask?.cancel()
        resetFeedTask?.cancel()
        trendingEmptyRetryTask?.cancel()
        profileUpdatesTask?.cancel()
        profileApplyTask?.cancel()
        connectionRecoveryTask?.cancel()
    }

    private func startObservingConnectionRecovery() {
        connectionRecoveryTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .relayConnectionsDidReset
            )
            for await _ in notifications {
                guard let self else { return }
                await self.recoverAfterRelayConnectionReset()
            }
        }
    }

    private func recoverAfterRelayConnectionReset() async {
        guard !backgroundUpdatesPaused else { return }

        // Restarting live subscriptions already performs a bounded catch-up.
        // Avoid doing a full feed refresh at the same time; the duplicate
        // hydration and list updates were a major foreground hitch.
        guard !items.isEmpty else {
            await refresh(silent: true, force: true)
            return
        }
        startLiveUpdatesIfNeeded(forceRestart: true)
    }

    private func startObservingProfileUpdates() {
        let stream = service.profileUpdates()
        profileUpdatesTask = Task { [weak self] in
            for await resolved in stream {
                guard let self else { return }
                self.enqueueResolvedProfiles(resolved)
            }
        }
    }

    private func enqueueResolvedProfiles(_ resolved: [String: NostrProfile]) {
        guard !resolved.isEmpty else { return }
        pendingResolvedProfiles.merge(resolved, uniquingKeysWith: { _, incoming in incoming })
        schedulePendingProfileApplicationIfNeeded()
    }

    private func schedulePendingProfileApplicationIfNeeded() {
        guard !backgroundUpdatesPaused else { return }
        guard profileApplyTask == nil else { return }

        profileApplyTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            self.profileApplyTask = nil
            guard !self.backgroundUpdatesPaused else { return }
            let resolved = self.pendingResolvedProfiles
            self.pendingResolvedProfiles.removeAll(keepingCapacity: true)
            self.applyResolvedProfiles(resolved)
        }
    }

    private func applyResolvedProfiles(_ resolved: [String: NostrProfile]) {
        guard !resolved.isEmpty else { return }

        let cachedVisibleItems = currentCachedVisibleItems()
        let cachedBufferedPartition = currentCachedBufferedPartition()
        var itemsChanged = false
        let patchedItems = items.map { item -> FeedItem in
            guard let updated = item.applyingResolvedProfiles(resolved) else { return item }
            itemsChanged = true
            return updated
        }
        if itemsChanged {
            items = patchedItems
            if let cachedVisibleItems {
                let patchedVisibleItems = cachedVisibleItems.map { item in
                    item.applyingResolvedProfiles(resolved) ?? item
                }
                primeVisibleItemsCache(with: patchedVisibleItems)
            }
        }

        var bufferedChanged = false
        let patchedBuffered = bufferedNewItems.map { item -> FeedItem in
            guard let updated = item.applyingResolvedProfiles(resolved) else { return item }
            bufferedChanged = true
            return updated
        }
        if bufferedChanged {
            bufferedNewItems = patchedBuffered
            if let cachedBufferedPartition {
                primeBufferedItemsCache(
                    retained: cachedBufferedPartition.retained.map { item in
                        item.applyingResolvedProfiles(resolved) ?? item
                    },
                    visible: cachedBufferedPartition.visible.map { item in
                        item.applyingResolvedProfiles(resolved) ?? item
                    }
                )
            }
        }
    }

    var feedSourceOptions: [HomePrimaryFeedSource] {
        let hashtagSources = favoriteHashtags.map { HomePrimaryFeedSource.hashtag($0) }
        let relaySources = favoriteRelayURLs.map { HomePrimaryFeedSource.relay($0) }
        let interestSources: [HomePrimaryFeedSource] = interestHashtags.isEmpty ? [] : [.interests]
        let customSources = customFeeds.map { HomePrimaryFeedSource.custom($0.id) }
        let pollsSources: [HomePrimaryFeedSource] = pollsFeedVisible ? [.polls] : []
        return [.following] + pollsSources + [.trending] + interestSources + customSources + relaySources + hashtagSources
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
        filteredBufferedItems().count
    }

    var visibleBufferedNewItems: [FeedItem] {
        filteredBufferedItems()
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

    func setBackgroundUpdatesPaused(_ isPaused: Bool) {
        guard backgroundUpdatesPaused != isPaused else { return }
        backgroundUpdatesPaused = isPaused

        if isPaused {
            profileApplyTask?.cancel()
            profileApplyTask = nil
            liveUpdatesTask?.cancel()
            liveUpdatesTask = nil
            liveCatchUpTask?.cancel()
            liveCatchUpTask = nil
            liveCatchUpToken &+= 1
            return
        }

        schedulePendingProfileApplicationIfNeeded()
        if items.isEmpty {
            Task(priority: .utility) { [weak self] in
                await self?.refresh(silent: true)
            }
        } else {
            startLiveUpdatesIfNeeded(forceRestart: true)
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
                updateFollowingPubkeys([])
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
                updateFollowingPubkeys([])
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
                updateFollowingPubkeys([])
                let trendingPage = try await pageFetcher.fetchTrendingFeedPage(
                    hydrationRelayURLs: hydrationRelayURLs(for: .trending),
                    limit: pageSize,
                    paginationState: nil,
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = trendingPage.page.items
                sourcePageResult = trendingPage.page
                trendingPaginationState = trendingPage.nextState
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = trendingPage.page.items.map(\.event)
                }

            case .news:
                updateFollowingPubkeys([])
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
                updateFollowingPubkeys([])
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
                updateFollowingPubkeys([])
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

                updateFollowingPubkeys(followings)
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

                updateFollowingPubkeys(followings)
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

                updateFollowingPubkeys(followings)
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

            guard !Task.isCancelled, !backgroundUpdatesPaused else { return }

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
                let upgradedItems = await upgradedHydrationItems(
                    for: requestSource,
                    fallbackRelayURLs: requestRelayURLs,
                    events: stagedHydrationEvents,
                    requestHydrationMode: requestHydrationMode
                )
                guard !Task.isCancelled else { return }
                guard !Task.isCancelled, !backgroundUpdatesPaused else { return }

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
                scheduleTrendingRetryAfterEmptyInitialLoadIfNeeded(
                    fetched: upgradedItems,
                    requestSource: requestSource,
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
                    hydrationMode: fastHydrationMode,
                    fetchTimeout: requestFetchTimeout,
                    relayFetchMode: requestRelayFetchMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                fetched = trendingPage.page.items
                sourcePageResult = trendingPage.page
                trendingPaginationState = trendingPage.nextState
                if requestHydrationMode != fastHydrationMode {
                    stagedHydrationEvents = trendingPage.page.items.map(\.event)
                }

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
                let upgradedItems = await upgradedHydrationItems(
                    for: requestSource,
                    fallbackRelayURLs: requestRelayURLs,
                    events: stagedHydrationEvents,
                    requestHydrationMode: requestHydrationMode
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

    func showBufferedNewItems() {
        let bufferedItemsToReveal = bufferedNewItems
        guard !bufferedItemsToReveal.isEmpty else { return }

        _ = visibleBufferedNewItems
        let acceptedCandidates = bufferedRetainedItemsCache
        bufferedNewItems.removeAll()
        guard !acceptedCandidates.isEmpty else {
            knownEventIDs.formUnion(items.map(\.id))
            return
        }

        mergeKeepingNewest(
            itemsToMerge: acceptedCandidates,
            retentionAlreadyValidated: true
        )
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
        hasRetriedEmptyTrendingLoad = false
        updateFollowingPubkeys([])
        errorMessage = nil

        trendingEmptyRetryTask?.cancel()
        trendingEmptyRetryTask = nil
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
        guard !backgroundUpdatesPaused else { return }
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
        guard !backgroundUpdatesPaused else { return }
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

        var catchUpEvents: [NostrEvent] = []
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
                catchUpEvents.append(contentsOf: events)
            }
        }

        guard !Task.isCancelled else { return }
        await handleLiveEvents(catchUpEvents)
    }

    private func handleLiveEvent(_ event: NostrEvent) async {
        await handleLiveEvents([event])
    }

    private func handleLiveEvents(_ events: [NostrEvent]) async {
        guard !backgroundUpdatesPaused, !events.isEmpty else { return }

        let requestSource = feedSource
        let allowedKinds = Set(feedKinds(for: requestSource))
        var seenEventIDs = Set<String>()
        let candidates = events.filter { event in
            let eventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard allowedKinds.contains(event.kind), !eventID.isEmpty else { return false }
            guard !knownEventIDs.contains(eventID) else { return false }
            return seenEventIDs.insert(eventID).inserted
        }
        guard !candidates.isEmpty else { return }

        let requestRelayURLs = hydrationRelayURLs(for: requestSource)
        let moderationSnapshot = muteFilterSnapshot
        await service.ingestLiveEvents(candidates)
        let hydrated = await service.buildFeedItems(
            relayURLs: requestRelayURLs,
            events: candidates,
            moderationSnapshot: moderationSnapshot
        )

        guard !Task.isCancelled,
              !backgroundUpdatesPaused,
              requestSource == feedSource else {
            return
        }

        let newItems = hydrated.filter { item in
            !knownEventIDs.contains(item.id) && itemIsAllowedForCurrentSource(item)
        }
        guard !newItems.isEmpty else { return }

        if requestSource == .articles {
            applyLiveArticleItems(newItems)
        } else {
            mergeBufferedItems(
                itemsToMerge: newItems,
                feedSource: requestSource
            )
            knownEventIDs.formUnion(bufferedNewItems.map(\.id))
        }
    }

    private func applyLiveArticleItems(_ newItems: [FeedItem]) {
        let currentReplacementKeys = Self.articleReplacementKeys(in: items)
        let visibleReplacements = newItems.filter {
            Self.containsArticleReplacement(for: $0, in: currentReplacementKeys)
        }
        let bufferedCandidates = newItems.filter {
            !Self.containsArticleReplacement(for: $0, in: currentReplacementKeys)
        }

        if !visibleReplacements.isEmpty {
            mergeKeepingNewest(itemsToMerge: visibleReplacements)
        }

        let visibleItemIDs = Set(items.map(\.id))
        let visibleReplacementKeys = Self.articleReplacementKeys(in: items)
        mergeBufferedItems(
            itemsToMerge: bufferedCandidates,
            feedSource: .articles,
            excludingItemIDs: visibleItemIDs,
            excludingArticleReplacementKeys: visibleReplacementKeys
        )
        knownEventIDs.formUnion(visibleItemIDs)
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
        knownEventIDs.formUnion(newItems.map(\.id))
    }

    private func mergeKeepingNewest(
        itemsToMerge: [FeedItem],
        retentionAlreadyValidated: Bool = false
    ) {
        LocalPublicationStore.shared.mergeFetchedItems(itemsToMerge)
        let existingVisibleItems = filteredMainItems()
        let affectedItemIDs = Set(itemsToMerge.map(\.id))
        let affectedArticleReplacementKeys = feedSource == .articles
            ? Self.articleReplacementKeys(in: itemsToMerge)
            : []

        func isAffected(_ item: FeedItem) -> Bool {
            affectedItemIDs.contains(item.id) ||
                (feedSource == .articles &&
                    Self.containsArticleReplacement(
                        for: item,
                        in: affectedArticleReplacementKeys
                    ))
        }

        var affectedExistingItems: [FeedItem] = []
        var unaffectedExistingItems: [FeedItem] = []
        affectedExistingItems.reserveCapacity(itemsToMerge.count)
        unaffectedExistingItems.reserveCapacity(items.count)
        for item in items {
            if isAffected(item) {
                affectedExistingItems.append(item)
            } else {
                unaffectedExistingItems.append(item)
            }
        }

        let canonicalAffectedItems = Self.mergeSortedItemsIncrementally(
            incomingItems: itemsToMerge,
            into: affectedExistingItems,
            feedSource: feedSource
        )
        let acceptedItems = retentionAlreadyValidated
            ? canonicalAffectedItems
            : HomeFeedVisibilityFilter.partitionBufferedItems(
                canonicalAffectedItems,
                configuration: visibilityConfiguration()
            ).retained
        let retainedMergedItems = Self.mergeSortedDisjointItems(
            unaffectedExistingItems,
            acceptedItems,
            feedSource: feedSource
        )

        if retainedMergedItems != items {
            items = retainedMergedItems
            primeVisibleItemsCacheAfterMerging(
                existingVisibleItems: existingVisibleItems,
                retainedAffectedItems: acceptedItems,
                affectedItemIDs: affectedItemIDs,
                affectedArticleReplacementKeys: affectedArticleReplacementKeys
            )
        }

        let currentlyVisibleIDs = Set(items.map(\.id))
        let currentArticleReplacementKeys = Self.articleReplacementKeys(in: items)
        mergeBufferedItems(
            itemsToMerge: [],
            feedSource: feedSource,
            excludingItemIDs: currentlyVisibleIDs,
            excludingArticleReplacementKeys: currentArticleReplacementKeys
        )

        knownEventIDs.formUnion(currentlyVisibleIDs)
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
        knownEventIDs.formUnion(itemsToMerge.map(\.id))
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
        let refreshConfiguration = visibilityConfiguration(
            feedSource: requestSource,
            followingPubkeys: sourceUsesFollowingAuthors(requestSource) ? followingPubkeys : nil
        )
        let nextHasReachedEnd: Bool
        if let sourcePageResult {
            nextHasReachedEnd = !sourcePageResult.hadMoreAvailable
        } else {
            nextHasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: fetched.count)
        }

        if publishFetchedItems {
            let acceptedRefreshItems = HomeFeedVisibilityFilter.partitionBufferedItems(
                refreshItemsWithLocalPublications,
                configuration: refreshConfiguration
            ).retained
            items = acceptedRefreshItems
            bufferedNewItems = []
            primeVisibleItemsCache(
                with: HomeFeedVisibilityFilter.visibleRetainedItems(
                    acceptedRefreshItems,
                    configuration: refreshConfiguration
                )
            )
            knownEventIDs = Set(acceptedRefreshItems.map(\.id))
            oldestCreatedAt = sourcePageResult?.paginationCursor ??
                acceptedRefreshItems.last?.event.createdAt ??
                fetched.last?.event.createdAt
            hasReachedEnd = nextHasReachedEnd
        } else {
            let existingItems = items
            let existingVisibleSnapshot = filteredMainItems()
            let existingItemIDs = Set(existingItems.map(\.id))
            let existingArticleReplacementKeys = Self.articleReplacementKeys(in: existingItems)
            let affectedItemIDs = Set(refreshItemsWithLocalPublications.map(\.id))
            let affectedArticleReplacementKeys = requestSource == .articles
                ? Self.articleReplacementKeys(in: refreshItemsWithLocalPublications)
                : []

            func isAffected(_ item: FeedItem) -> Bool {
                affectedItemIDs.contains(item.id) ||
                    (requestSource == .articles &&
                        Self.containsArticleReplacement(
                            for: item,
                            in: affectedArticleReplacementKeys
                        ))
            }

            var affectedExistingItems: [FeedItem] = []
            var unaffectedExistingItems: [FeedItem] = []
            affectedExistingItems.reserveCapacity(refreshItemsWithLocalPublications.count)
            unaffectedExistingItems.reserveCapacity(existingItems.count)
            for item in existingItems {
                if isAffected(item) {
                    affectedExistingItems.append(item)
                } else {
                    unaffectedExistingItems.append(item)
                }
            }

            let canonicalAffectedItems = Self.mergeSortedItemsIncrementally(
                incomingItems: refreshItemsWithLocalPublications,
                into: affectedExistingItems,
                feedSource: requestSource
            )
            let acceptedCanonicalItems = HomeFeedVisibilityFilter.partitionBufferedItems(
                canonicalAffectedItems,
                configuration: refreshConfiguration
            ).retained
            let refreshedItemCandidates = acceptedCanonicalItems.filter { item in
                existingItemIDs.contains(item.id) ||
                    (requestSource == .articles &&
                        Self.containsArticleReplacement(
                            for: item,
                            in: existingArticleReplacementKeys
                        ))
            }
            let refreshedItems = Self.mergeSortedDisjointItems(
                unaffectedExistingItems,
                refreshedItemCandidates,
                feedSource: requestSource
            )
            if refreshedItems != existingItems {
                items = refreshedItems
                primeVisibleItemsCacheAfterMerging(
                    existingVisibleItems: existingVisibleSnapshot,
                    retainedAffectedItems: refreshedItemCandidates,
                    affectedItemIDs: affectedItemIDs,
                    affectedArticleReplacementKeys: affectedArticleReplacementKeys
                )
            }

            let retainedItemIDs = Set(refreshedItems.map(\.id))
            let retainedArticleReplacementKeys = Self.articleReplacementKeys(
                in: refreshedItems
            )
            let unpublishedItems = acceptedCanonicalItems.filter { item in
                !retainedItemIDs.contains(item.id) &&
                    !(requestSource == .articles &&
                        Self.containsArticleReplacement(
                            for: item,
                            in: retainedArticleReplacementKeys
                        ))
            }
            mergeBufferedItems(
                itemsToMerge: unpublishedItems,
                feedSource: requestSource,
                excludingItemIDs: retainedItemIDs,
                excludingArticleReplacementKeys: retainedArticleReplacementKeys
            )
            knownEventIDs.formUnion(retainedItemIDs)
            knownEventIDs.formUnion(bufferedNewItems.map(\.id))
            knownEventIDs.formUnion(refreshItemsWithLocalPublications.map(\.id))
            oldestCreatedAt = sourcePageResult?.paginationCursor ??
                refreshedItems.last?.event.createdAt ??
                fetched.last?.event.createdAt
            hasReachedEnd = nextHasReachedEnd
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
            primary: items.filter { localPublicationIDs.contains($0.id) },
            secondary: bufferedNewItems.filter { localPublicationIDs.contains($0.id) },
            feedSource: requestSource
        )
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
        let key = makeVisibleItemsCacheKey(
            itemsRevision: itemsRevision,
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

    private func filteredBufferedItems() -> [FeedItem] {
        let key = makeVisibleItemsCacheKey(
            itemsRevision: bufferedItemsRevision,
            ignoreMediaOnly: false
        )

        if bufferedVisibleItemsCacheKey == key {
            return bufferedVisibleItemsCache
        }

        let partition = HomeFeedVisibilityFilter.partitionBufferedItems(
            bufferedNewItems,
            configuration: visibilityConfiguration()
        )
        bufferedVisibleItemsCacheKey = key
        bufferedRetainedItemsCache = partition.retained
        bufferedVisibleItemsCache = partition.visible
        return partition.visible
    }

    private func makeVisibleItemsCacheKey(
        itemsRevision: Int,
        ignoreMediaOnly: Bool
    ) -> VisibleItemsCacheKey {
        VisibleItemsCacheKey(
            itemsRevision: itemsRevision,
            feedSource: feedSource,
            mode: mode,
            showKinds: showKinds,
            mediaOnly: mediaOnly,
            hideNSFW: AppSettingsStore.shared.hideNSFWContent,
            filterRevision: MuteStore.shared.filterRevision,
            spamFilterSignature: AppSettingsStore.shared.spamFilterLabelSignature,
            mutedConversationRevision: mutedConversationRevision,
            followingAuthorsRevision: sourceUsesFollowingAuthors(feedSource)
                ? followingAuthorsRevision
                : 0,
            ignoreMediaOnly: ignoreMediaOnly
        )
    }

    private func currentCachedVisibleItems() -> [FeedItem]? {
        let key = makeVisibleItemsCacheKey(
            itemsRevision: itemsRevision,
            ignoreMediaOnly: false
        )
        guard visibleItemsCacheKey == key else { return nil }
        return visibleItemsCache
    }

    private func currentCachedBufferedPartition() -> HomeFeedVisibilityFilter.BufferedItemPartition? {
        let key = makeVisibleItemsCacheKey(
            itemsRevision: bufferedItemsRevision,
            ignoreMediaOnly: false
        )
        guard bufferedVisibleItemsCacheKey == key else { return nil }
        return HomeFeedVisibilityFilter.BufferedItemPartition(
            retained: bufferedRetainedItemsCache,
            visible: bufferedVisibleItemsCache
        )
    }

    private func primeVisibleItemsCache(with visibleItems: [FeedItem]) {
        visibleItemsCacheKey = makeVisibleItemsCacheKey(
            itemsRevision: itemsRevision,
            ignoreMediaOnly: false
        )
        visibleItemsCache = visibleItems
    }

    /// Updates the cached visible slice by replacing only the affected sorted
    /// identities. The expensive retention checks already ran for
    /// `retainedAffectedItems`; only current presentation filters are applied.
    private func primeVisibleItemsCacheAfterMerging(
        existingVisibleItems: [FeedItem],
        retainedAffectedItems: [FeedItem],
        affectedItemIDs: Set<String>,
        affectedArticleReplacementKeys: Set<String>
    ) {
        let unaffectedVisibleItems = existingVisibleItems.filter { item in
            guard !affectedItemIDs.contains(item.id) else { return false }
            guard feedSource == .articles else { return true }
            return !Self.containsArticleReplacement(
                for: item,
                in: affectedArticleReplacementKeys
            )
        }
        let visibleAffectedItems = HomeFeedVisibilityFilter.visibleRetainedItems(
            retainedAffectedItems,
            configuration: visibilityConfiguration()
        )
        primeVisibleItemsCache(
            with: Self.mergeSortedDisjointItems(
                unaffectedVisibleItems,
                visibleAffectedItems,
                feedSource: feedSource
            )
        )
    }

    /// Merges a live or silent-refresh batch into the new-items buffer while
    /// moderating only rows affected by that batch. The published buffer stores
    /// retained rows, while the cached visible slice applies the cheaper current
    /// presentation filters. This prevents rejected events from consuming the
    /// cap and avoids whole-buffer sorts for one-at-a-time relay updates.
    private func mergeBufferedItems(
        itemsToMerge: [FeedItem],
        feedSource source: HomePrimaryFeedSource,
        excludingItemIDs: Set<String> = [],
        excludingArticleReplacementKeys: Set<String> = []
    ) {
        let configuration = visibilityConfiguration(
            feedSource: source,
            followingPubkeys: sourceUsesFollowingAuthors(source) ? followingPubkeys : nil
        )
        let existingPartition = currentCachedBufferedPartition() ??
            HomeFeedVisibilityFilter.partitionBufferedItems(
                bufferedNewItems,
                configuration: configuration
            )
        let affectedItemIDs = Set(itemsToMerge.map(\.id))
        let affectedArticleReplacementKeys = source == .articles
            ? Self.articleReplacementKeys(in: itemsToMerge)
            : []

        func isExcluded(_ item: FeedItem) -> Bool {
            excludingItemIDs.contains(item.id) ||
                (source == .articles &&
                    Self.containsArticleReplacement(
                        for: item,
                        in: excludingArticleReplacementKeys
                    ))
        }

        func isAffected(_ item: FeedItem) -> Bool {
            affectedItemIDs.contains(item.id) ||
                (source == .articles &&
                    Self.containsArticleReplacement(
                        for: item,
                        in: affectedArticleReplacementKeys
                    ))
        }

        let bufferedItemLimit = max(pageSize, HomeFeedPaginationDefaults.pageSize)
        var canonicalItems = Self.mergeSortedItemsIncrementally(
            incomingItems: itemsToMerge,
            into: existingPartition.retained,
            feedSource: source
        )
        canonicalItems.removeAll(where: isExcluded)
        let affectedCanonicalItems = canonicalItems.filter(isAffected)
        let affectedPartition = HomeFeedVisibilityFilter.partitionBufferedItems(
            affectedCanonicalItems,
            configuration: configuration
        )
        let retainedUnaffectedItems = canonicalItems.filter { !isAffected($0) }
        let retainedItems = Self.mergeSortedDisjointItems(
            retainedUnaffectedItems,
            affectedPartition.retained,
            feedSource: source,
            limit: bufferedItemLimit
        )

        let unaffectedVisibleItemIDs = Set(
            existingPartition.visible
                .filter { !isAffected($0) && !isExcluded($0) }
                .map(\.id)
        )
        let affectedVisibleItemIDs = Set(affectedPartition.visible.map(\.id))
        let visibleItemIDs = unaffectedVisibleItemIDs.union(affectedVisibleItemIDs)
        let visibleItems = retainedItems.filter { visibleItemIDs.contains($0.id) }

        if retainedItems != bufferedNewItems {
            bufferedNewItems = retainedItems
        }
        primeBufferedItemsCache(
            retained: retainedItems,
            visible: visibleItems
        )
        knownEventIDs.formUnion(itemsToMerge.map(\.id))
    }

    private func primeBufferedItemsCache(
        retained: [FeedItem],
        visible: [FeedItem]
    ) {
        bufferedVisibleItemsCacheKey = makeVisibleItemsCacheKey(
            itemsRevision: bufferedItemsRevision,
            ignoreMediaOnly: false
        )
        bufferedRetainedItemsCache = retained
        bufferedVisibleItemsCache = visible
    }

    private func clearVisibleItemsCache() {
        clearMainVisibleItemsCache()
        clearBufferedVisibleItemsCache()
    }

    private func clearMainVisibleItemsCache() {
        visibleItemsCacheKey = nil
        visibleItemsCache = []
    }

    private func clearBufferedVisibleItemsCache() {
        bufferedVisibleItemsCacheKey = nil
        bufferedVisibleItemsCache = []
        bufferedRetainedItemsCache = []
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

    private func updateFollowingPubkeys(_ pubkeys: [String]) {
        let normalized = Array(
            Set(
                pubkeys
                    .map(normalizePubkey)
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        guard normalized != followingPubkeys else { return }

        let cachedVisibleItems = currentCachedVisibleItems()
        let cachedBufferedPartition = currentCachedBufferedPartition()
        followingPubkeys = normalized
        followingAuthorsRevision &+= 1

        guard sourceUsesFollowingAuthors(feedSource) else { return }

        let configuration = visibilityConfiguration()
        let sourceAllowedItems = HomeFeedVisibilityFilter.retainedItemsAllowedForCurrentSource(
            items,
            configuration: configuration
        )
        let sourceAllowedBufferedItems = HomeFeedVisibilityFilter.retainedItemsAllowedForCurrentSource(
            bufferedNewItems,
            configuration: configuration
        )

        if sourceAllowedItems != items {
            items = sourceAllowedItems
        }
        if let cachedVisibleItems {
            primeVisibleItemsCache(
                with: HomeFeedVisibilityFilter.retainedItemsAllowedForCurrentSource(
                    cachedVisibleItems,
                    configuration: configuration
                )
            )
        }

        if sourceAllowedBufferedItems != bufferedNewItems {
            bufferedNewItems = sourceAllowedBufferedItems
        }
        if let cachedBufferedPartition {
            primeBufferedItemsCache(
                retained: HomeFeedVisibilityFilter.retainedItemsAllowedForCurrentSource(
                    cachedBufferedPartition.retained,
                    configuration: configuration
                ),
                visible: HomeFeedVisibilityFilter.retainedItemsAllowedForCurrentSource(
                    cachedBufferedPartition.visible,
                    configuration: configuration
                )
            )
        }

        knownEventIDs = Set(items.map(\.id))
        knownEventIDs.formUnion(bufferedNewItems.map(\.id))
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

    private func upgradedHydrationItems(
        for source: HomePrimaryFeedSource,
        fallbackRelayURLs: [URL],
        events: [NostrEvent],
        requestHydrationMode: FeedItemHydrationMode
    ) async -> [FeedItem] {
        guard source == .trending else {
            return await service.buildFeedItems(
                relayURLs: fallbackRelayURLs,
                events: events,
                hydrationMode: requestHydrationMode,
                moderationSnapshot: muteFilterSnapshot
            )
        }

        return await service.buildAuthorHydratedFeedItems(
            relayURLs: hydrationRelayURLs(for: source),
            events: events,
            relayFetchMode: .allRelays,
            moderationSnapshot: muteFilterSnapshot
        )
    }

}
