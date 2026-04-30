import Foundation

@MainActor
final class HashtagFeedViewModel: ObservableObject {
    private struct InitialHashtagPageResult {
        let items: [FeedItem]
        let fetchedFullPage: Bool
    }

    private struct VisibleItemsCacheKey: Equatable {
        let itemsRevision: Int
        let hideNSFW: Bool
        let filterRevision: Int
        let spamFilterSignature: String
    }

    @Published private(set) var items: [FeedItem] = [] {
        didSet {
            itemsRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    let relayURL: URL
    let readRelayURLs: [URL]
    let normalizedHashtag: String

    private let pageSize: Int
    private let service: NostrFeedService
    private let requestKinds = FeedKindFilters.supportedKinds
    private static let fastHashtagFetchTimeout: TimeInterval = 3
    private static let fullHashtagFetchTimeout: TimeInterval = 8
    private static let fastHashtagRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let fastInitialPageSize = 24
    private var oldestCreatedAt: Int?
    private var hasReachedEnd = false
    private var hasLoadedInitialState = false
    private var itemHydrationTask: Task<Void, Never>?
    private var relayExpansionTask: Task<Void, Never>?
    private var itemsRevision = 0
    private var visibleItemsCacheKey: VisibleItemsCacheKey?
    private var visibleItemsCache: [FeedItem] = []

    private static let supplementalRelayURLs: [URL] = [
        URL(string: "wss://relay.damus.io/"),
        URL(string: "wss://nos.lol/"),
        URL(string: "wss://relay.nostr.band/"),
        URL(string: "wss://nostr.mom/")
    ].compactMap { $0 }

    init(
        hashtag: String,
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        seedItems: [FeedItem] = [],
        pageSize: Int = 70,
        service: NostrFeedService = NostrFeedService()
    ) {
        let sharedReadRelays = RelaySettingsStore.shared.readRelayURLs
        let normalizedReadRelays = Self.normalizedRelayURLs(
            readRelayURLs ?? (sharedReadRelays.isEmpty ? [relayURL] : sharedReadRelays)
        )

        self.readRelayURLs = normalizedReadRelays.isEmpty ? [relayURL] : normalizedReadRelays
        self.relayURL = self.readRelayURLs.first ?? relayURL
        self.normalizedHashtag = NostrEvent.normalizedHashtagValue(hashtag)
        self.pageSize = pageSize
        self.service = service
        self.items = Self.sortedNewestFirst(
            seedItems.filter { $0.displayEvent.containsHashtag(self.normalizedHashtag) }
        )
    }

    deinit {
        itemHydrationTask?.cancel()
        relayExpansionTask?.cancel()
    }

    var relayLabel: String {
        if readRelayURLs.count > 1 {
            return "\(readRelayURLs.count) relays"
        }
        return relayURL.host() ?? relayURL.absoluteString
    }

    var visibleItems: [FeedItem] {
        let key = VisibleItemsCacheKey(
            itemsRevision: itemsRevision,
            hideNSFW: AppSettingsStore.shared.hideNSFWContent,
            filterRevision: MuteStore.shared.filterRevision,
            spamFilterSignature: AppSettingsStore.shared.spamFilterLabelSignature
        )

        if visibleItemsCacheKey == key {
            return visibleItemsCache
        }

        let hideNSFW = AppSettingsStore.shared.hideNSFWContent
        let filtered = items.filter { item in
            if MuteStore.shared.shouldHideAny(item.moderationEvents) {
                return false
            }
            if AppSettingsStore.shared.shouldHideSpamMarkedPubkey(item.displayAuthorPubkey) {
                return false
            }
            if hideNSFW && item.moderationEvents.contains(where: { $0.containsNSFWHashtag }) {
                return false
            }
            return true
        }

        visibleItemsCacheKey = key
        visibleItemsCache = filtered
        return filtered
    }

    private var muteFilterSnapshot: MuteFilterSnapshot {
        MuteStore.shared.filterSnapshot
    }

    func loadIfNeeded() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        guard !normalizedHashtag.isEmpty else {
            items = []
            errorMessage = "Missing hashtag."
            return
        }

        isLoading = true
        errorMessage = nil
        hasReachedEnd = false
        oldestCreatedAt = nil
        itemHydrationTask?.cancel()
        relayExpansionTask?.cancel()
        itemHydrationTask = nil

        defer {
            isLoading = false
        }

        do {
            let initialPage = try await fetchInitialHashtagPage()
            let initialItems = mergeWithLocalPublicationItems(initialPage.items)
            if items.isEmpty {
                items = initialItems
            } else if !initialItems.isEmpty {
                mergeKeepingNewest(itemsToMerge: initialItems)
            }
            if initialPage.fetchedFullPage {
                oldestCreatedAt = initialItems.last?.event.createdAt
                hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(
                    afterFetchedCount: initialPage.items.count
                )
            } else {
                do {
                    let expandedItems = pruneMutedItems(try await fetchExpandedHashtagPage())
                    if !expandedItems.isEmpty {
                        mergeKeepingNewest(itemsToMerge: expandedItems)
                        oldestCreatedAt = expandedItems.last?.event.createdAt
                        hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(
                            afterFetchedCount: expandedItems.count
                        )
                    } else {
                        oldestCreatedAt = initialItems.last?.event.createdAt
                        hasReachedEnd = false
                    }
                } catch {
                    oldestCreatedAt = initialItems.last?.event.createdAt
                    hasReachedEnd = false
                }
            }
        } catch {
            if items.isEmpty {
                errorMessage = "Couldn't load #\(normalizedHashtag) right now."
            } else {
                errorMessage = "Couldn't refresh #\(normalizedHashtag)."
            }
        }
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        guard !isLoading, !isLoadingMore, !hasReachedEnd else { return }
        guard let lastVisibleID = visibleItems.last?.id, lastVisibleID == currentItem.id else { return }

        let until = max((oldestCreatedAt ?? Int(Date().timeIntervalSince1970)) - 1, 0)
        guard until > 0 else { return }

        isLoadingMore = true
        itemHydrationTask?.cancel()
        relayExpansionTask?.cancel()
        itemHydrationTask = nil
        defer {
            isLoadingMore = false
        }

        do {
            let fetched = try await service.fetchHashtagFeed(
                relayURLs: hashtagRelayURLs,
                hashtag: normalizedHashtag,
                kinds: requestKinds,
                limit: pageSize,
                until: until,
                hydrationMode: .full,
                fetchTimeout: Self.fullHashtagFetchTimeout,
                relayFetchMode: .allRelays,
                moderationSnapshot: muteFilterSnapshot
            )

            if fetched.isEmpty {
                hasReachedEnd = true
                return
            }

            oldestCreatedAt = fetched.last?.event.createdAt
            hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: fetched.count)
            mergeKeepingNewest(itemsToMerge: fetched)
        } catch {
            errorMessage = "Couldn't load more posts."
        }
    }

    func insertOptimisticPublishedItem(_ item: FeedItem) {
        guard item.displayEvent.containsHashtag(normalizedHashtag) else { return }
        mergeKeepingNewest(itemsToMerge: [item])
    }

    private func mergeKeepingNewest(itemsToMerge: [FeedItem]) {
        LocalPublicationStore.shared.mergeFetchedItems(itemsToMerge)
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in itemsToMerge {
            byID[item.id] = item
        }
        items = pruneMutedItems(byID.values.sorted {
            if $0.event.createdAt == $1.event.createdAt {
                return $0.id > $1.id
            }
            return $0.event.createdAt > $1.event.createdAt
        })
    }

    private func mergeWithLocalPublicationItems(_ fetchedItems: [FeedItem]) -> [FeedItem] {
        LocalPublicationStore.shared.mergeFetchedItems(fetchedItems)
        return pruneMutedItems(
            HomeFeedPageFetcher.mergeItemArrays(
                primary: fetchedItems,
                secondary: localPublicationItems()
            )
        )
    }

    private func localPublicationItems() -> [FeedItem] {
        LocalPublicationStore.shared.records(matching: { item in
            item.displayEvent.containsHashtag(normalizedHashtag)
        })
        .map(\.item)
    }

    private func pruneMutedItems(
        _ sourceItems: [FeedItem],
        snapshot: MuteFilterSnapshot? = nil
    ) -> [FeedItem] {
        let snapshot = snapshot ?? muteFilterSnapshot
        let hasMarkedSpam = !AppSettingsStore.shared.spamFilterMarkedPubkeys.isEmpty
        guard snapshot.hasAnyRules || hasMarkedSpam else { return sourceItems }

        return sourceItems.filter { item in
            !snapshot.shouldHideAny(in: item.moderationEvents)
                && !AppSettingsStore.shared.shouldHideSpamMarkedPubkey(item.displayAuthorPubkey)
        }
    }

    private func clearVisibleItemsCache() {
        visibleItemsCacheKey = nil
        visibleItemsCache = []
    }

    private func scheduleItemHydration(for sourceItems: [FeedItem]) {
        itemHydrationTask?.cancel()

        let events = sourceItems.map(\.event)
        guard !events.isEmpty else { return }
        let relayTargets = hashtagRelayURLs

        itemHydrationTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.service.buildFeedItems(
                relayURLs: relayTargets,
                events: events,
                hydrationMode: .full,
                moderationSnapshot: self.muteFilterSnapshot
            )
            guard !Task.isCancelled else { return }
        }
    }

    private func fetchInitialHashtagPage() async throws -> InitialHashtagPageResult {
        let fastFetched = try await service.fetchHashtagFeed(
            relayURLs: fastHashtagRelayURLs,
            hashtag: normalizedHashtag,
            kinds: requestKinds,
            limit: min(pageSize, Self.fastInitialPageSize),
            until: nil,
            hydrationMode: .full,
            fetchTimeout: Self.fastHashtagFetchTimeout,
            relayFetchMode: Self.fastHashtagRelayFetchMode,
            moderationSnapshot: muteFilterSnapshot
        )

        if !fastFetched.isEmpty {
            return InitialHashtagPageResult(items: fastFetched, fetchedFullPage: false)
        }

        let fullFetched = try await service.fetchHashtagFeed(
            relayURLs: hashtagRelayURLs,
            hashtag: normalizedHashtag,
            kinds: requestKinds,
            limit: pageSize,
            until: nil,
            hydrationMode: .full,
            fetchTimeout: Self.fullHashtagFetchTimeout,
            relayFetchMode: .allRelays,
            moderationSnapshot: muteFilterSnapshot
        )
        return InitialHashtagPageResult(items: fullFetched, fetchedFullPage: true)
    }

    private func fetchExpandedHashtagPage() async throws -> [FeedItem] {
        try await service.fetchHashtagFeed(
            relayURLs: hashtagRelayURLs,
            hashtag: normalizedHashtag,
            kinds: requestKinds,
            limit: pageSize,
            until: nil,
            hydrationMode: .full,
            fetchTimeout: Self.fullHashtagFetchTimeout,
            relayFetchMode: .allRelays,
            moderationSnapshot: muteFilterSnapshot
        )
    }

    private func scheduleRelayExpansionIfNeeded() {
        guard !hashtagRelayURLs.isEmpty else { return }

        relayExpansionTask?.cancel()
        relayExpansionTask = Task { [weak self] in
            guard let self else { return }

            let expanded = try? await self.service.fetchHashtagFeed(
                relayURLs: self.hashtagRelayURLs,
                hashtag: self.normalizedHashtag,
                kinds: self.requestKinds,
                limit: self.pageSize,
                until: nil,
                hydrationMode: .full,
                fetchTimeout: Self.fullHashtagFetchTimeout,
                relayFetchMode: .allRelays,
                moderationSnapshot: self.muteFilterSnapshot
            )

            guard !Task.isCancelled else { return }
            guard let expanded, !expanded.isEmpty else { return }

            await MainActor.run {
                self.mergeKeepingNewest(itemsToMerge: expanded)
                self.oldestCreatedAt = expanded.last?.event.createdAt
                self.hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(
                    afterFetchedCount: expanded.count
                )
            }
        }
    }

    private var hashtagRelayURLs: [URL] {
        Self.normalizedRelayURLs(readRelayURLs + Self.supplementalRelayURLs)
    }

    private var fastHashtagRelayURLs: [URL] {
        Self.normalizedRelayURLs([relayURL] + Self.supplementalRelayURLs)
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

    private static func sortedNewestFirst(_ items: [FeedItem]) -> [FeedItem] {
        var byID: [String: FeedItem] = [:]
        for item in items {
            byID[item.id.lowercased()] = item
        }

        return byID.values.sorted {
            if $0.event.createdAt == $1.event.createdAt {
                return $0.id.lowercased() > $1.id.lowercased()
            }
            return $0.event.createdAt > $1.event.createdAt
        }
    }
}

@MainActor
final class RelayFeedViewModel: ObservableObject {
    private struct VisibleItemsCacheKey: Equatable {
        let itemsRevision: Int
        let hideNSFW: Bool
        let filterRevision: Int
        let spamFilterSignature: String
    }

    @Published private(set) var items: [FeedItem] = [] {
        didSet {
            itemsRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    let relayURL: URL
    let title: String

    private let pageSize: Int
    private let service: NostrFeedService
    private let requestKinds = FeedKindFilters.supportedKinds
    private var oldestCreatedAt: Int?
    private var hasReachedEnd = false
    private var hasLoadedInitialState = false
    private var itemsRevision = 0
    private var visibleItemsCacheKey: VisibleItemsCacheKey?
    private var visibleItemsCache: [FeedItem] = []

    init(
        relayURL: URL,
        title: String? = nil,
        pageSize: Int = 70,
        service: NostrFeedService = NostrFeedService()
    ) {
        let normalizedURL = RelayURLSupport.normalizedURL(from: relayURL.absoluteString) ?? relayURL
        self.relayURL = normalizedURL
        self.title = title ?? RelayURLSupport.displayName(for: normalizedURL)
        self.pageSize = pageSize
        self.service = service
    }

    var relayHostLabel: String {
        relayURL.host()?.lowercased() ?? relayURL.absoluteString
    }

    var routeID: String {
        RelayURLSupport.normalizedRelayURLString(relayURL) ?? relayURL.absoluteString.lowercased()
    }

    var visibleItems: [FeedItem] {
        let key = VisibleItemsCacheKey(
            itemsRevision: itemsRevision,
            hideNSFW: AppSettingsStore.shared.hideNSFWContent,
            filterRevision: MuteStore.shared.filterRevision,
            spamFilterSignature: AppSettingsStore.shared.spamFilterLabelSignature
        )

        if visibleItemsCacheKey == key {
            return visibleItemsCache
        }

        let hideNSFW = AppSettingsStore.shared.hideNSFWContent
        let filtered = items.filter { item in
            if MuteStore.shared.shouldHideAny(item.moderationEvents) {
                return false
            }
            if AppSettingsStore.shared.shouldHideSpamMarkedPubkey(item.displayAuthorPubkey) {
                return false
            }
            if hideNSFW && item.moderationEvents.contains(where: { $0.containsNSFWHashtag }) {
                return false
            }
            return true
        }

        visibleItemsCacheKey = key
        visibleItemsCache = filtered
        return filtered
    }

    private var muteFilterSnapshot: MuteFilterSnapshot {
        MuteStore.shared.filterSnapshot
    }

    func loadIfNeeded() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        hasReachedEnd = false
        oldestCreatedAt = nil

        defer {
            isLoading = false
        }

        do {
            let fetched = try await fetchPage(until: nil, hydrationMode: .full)
            let visibleFetched = pruneMutedItems(fetched)
            items = visibleFetched
            oldestCreatedAt = visibleFetched.last?.event.createdAt
            hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: fetched.count)
        } catch {
            if items.isEmpty {
                errorMessage = "Couldn't load \(title) right now."
            } else {
                errorMessage = "Couldn't refresh \(title)."
            }
        }
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        guard !isLoading, !isLoadingMore, !hasReachedEnd else { return }
        guard let lastVisibleID = visibleItems.last?.id, lastVisibleID == currentItem.id else { return }

        let until = max((oldestCreatedAt ?? Int(Date().timeIntervalSince1970)) - 1, 0)
        guard until > 0 else { return }

        isLoadingMore = true
        defer {
            isLoadingMore = false
        }

        do {
            let fetched = try await fetchPage(until: until, hydrationMode: .full)
            if fetched.isEmpty {
                hasReachedEnd = true
                return
            }

            let visibleFetched = pruneMutedItems(fetched)
            oldestCreatedAt = visibleFetched.last?.event.createdAt ?? fetched.last?.event.createdAt
            hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: fetched.count)
            mergeKeepingNewest(itemsToMerge: visibleFetched)
        } catch {
            errorMessage = "Couldn't load more posts."
        }
    }

    func insertOptimisticPublishedItem(_ item: FeedItem) {
        mergeKeepingNewest(itemsToMerge: [item])
    }

    private func fetchPage(
        until: Int?,
        hydrationMode: FeedItemHydrationMode
    ) async throws -> [FeedItem] {
        try await service.fetchFeed(
            relayURLs: [relayURL],
            kinds: requestKinds,
            limit: pageSize,
            until: until,
            hydrationMode: hydrationMode,
            fetchTimeout: 12,
            relayFetchMode: .allRelays,
            moderationSnapshot: muteFilterSnapshot
        )
    }

    private func mergeKeepingNewest(itemsToMerge: [FeedItem]) {
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id.lowercased(), $0) })
        for item in itemsToMerge {
            byID[item.id.lowercased()] = item
        }

        items = pruneMutedItems(Self.sortedNewestFirst(Array(byID.values)))
    }

    private func pruneMutedItems(
        _ sourceItems: [FeedItem],
        snapshot: MuteFilterSnapshot? = nil
    ) -> [FeedItem] {
        let snapshot = snapshot ?? muteFilterSnapshot
        let hasMarkedSpam = !AppSettingsStore.shared.spamFilterMarkedPubkeys.isEmpty
        guard snapshot.hasAnyRules || hasMarkedSpam else { return sourceItems }

        return sourceItems.filter { item in
            !snapshot.shouldHideAny(in: item.moderationEvents)
                && !AppSettingsStore.shared.shouldHideSpamMarkedPubkey(item.displayAuthorPubkey)
        }
    }

    private func clearVisibleItemsCache() {
        visibleItemsCacheKey = nil
        visibleItemsCache = []
    }

    private static func sortedNewestFirst(_ items: [FeedItem]) -> [FeedItem] {
        var byID: [String: FeedItem] = [:]
        for item in items {
            byID[item.id.lowercased()] = item
        }

        return byID.values.sorted {
            if $0.event.createdAt == $1.event.createdAt {
                return $0.id.lowercased() > $1.id.lowercased()
            }
            return $0.event.createdAt > $1.event.createdAt
        }
    }
}
