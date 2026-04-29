import Foundation
import NostrSDK

@MainActor
final class SearchViewModel: ObservableObject {
    private struct VisibleItemsCacheKey: Equatable {
        let trendingRevision: Int
        let searchedRevision: Int
        let hasActiveContentSearch: Bool
        let hideNSFW: Bool
        let filterRevision: Int
        let spamFilterSignature: String
        let mutedConversationRevision: Int
    }

    @Published var searchText = ""
    @Published private(set) var trendingNotes: [FeedItem] = [] {
        didSet {
            trendingNotesRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    @Published private(set) var searchedNotes: [FeedItem] = [] {
        didSet {
            searchedNotesRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    @Published private(set) var profileMatches: [ProfileMatch] = []
    @Published private(set) var popularProfiles: [ProfileMatch] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeContentSearch: SuggestedContentSearch?

    private let service: NostrFeedService
    private let trendingNotesLoader: TrendingNotesLoader
    private let supportsContentSearch: Bool
    private let vertexSearchService = VertexProfileSearchService.shared
    private let pageSize: Int
    private let assetPrefetchItemCount = 18

    private var mutedConversationIDs = Set<String>() {
        didSet {
            mutedConversationRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    private var searchTask: Task<Void, Never>?
    private var latestSearchRequestID = UUID()
    private var trendingNotesRevision = 0
    private var searchedNotesRevision = 0
    private var mutedConversationRevision = 0
    private var visibleItemsCacheKey: VisibleItemsCacheKey?
    private var visibleItemsCache: [FeedItem] = []
    private var followedAuthorPubkeys: [String] = []
    private var currentAccountPubkey: String?
    private var currentNsec: String?

    private(set) var readRelayURLs: [URL]
    private(set) var relayURL: URL

    private static let searchableRelayURLs: [URL] = [
        NostrFeedService.nostrArchivesSearchRelayURL
    ].compactMap { $0 }

    private static let bigRelayURLs: [URL] = [
        URL(string: "wss://relay.damus.io/"),
        URL(string: "wss://nos.lol/"),
        URL(string: "wss://relay.nostr.band/"),
        URL(string: "wss://nostr.mom/")
    ].compactMap { $0 }

    private static let searchFeedKinds = [1, 6, 20, 21, 22, 1063, 1222, 30023, 1111, 1244]
    private static let noteSearchFetchTimeout: TimeInterval = 5
    private static let profileSearchFetchTimeout: TimeInterval = 6
    private static let noteSearchRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let profileSearchRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay

    init(
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        pageSize: Int = 100,
        service: NostrFeedService = NostrFeedService(),
        trendingNotesLoader: @escaping TrendingNotesLoader = SearchViewModel.defaultTrendingNotesLoader,
        supportsContentSearch: Bool = true
    ) {
        let normalizedReadRelayURLs = Self.normalizedRelayURLs(readRelayURLs ?? [relayURL])
        let initialReadRelayURLs = normalizedReadRelayURLs.isEmpty ? [relayURL] : normalizedReadRelayURLs

        self.readRelayURLs = initialReadRelayURLs
        self.relayURL = initialReadRelayURLs.first ?? relayURL
        self.pageSize = pageSize
        self.service = service
        self.trendingNotesLoader = trendingNotesLoader
        self.supportsContentSearch = supportsContentSearch
    }

    deinit {
        searchTask?.cancel()
    }

    var visibleItems: [FeedItem] {
        let key = VisibleItemsCacheKey(
            trendingRevision: trendingNotesRevision,
            searchedRevision: searchedNotesRevision,
            hasActiveContentSearch: activeContentSearch != nil,
            hideNSFW: AppSettingsStore.shared.hideNSFWContent,
            filterRevision: MuteStore.shared.filterRevision,
            spamFilterSignature: AppSettingsStore.shared.spamFilterLabelSignature,
            mutedConversationRevision: mutedConversationRevision
        )

        if visibleItemsCacheKey == key {
            return visibleItemsCache
        }

        let source = activeContentSearch == nil ? [] : searchedNotes
        let filtered = filteredItems(source)
        visibleItemsCacheKey = key
        visibleItemsCache = filtered
        return filtered
    }

    private var muteFilterSnapshot: MuteFilterSnapshot {
        MuteStore.shared.filterSnapshot
    }

    private var searchQuery: SearchQueryDescriptor {
        SearchQueryDescriptor(rawText: searchText)
    }

    var isSearching: Bool {
        !searchQuery.isEmpty
    }

    var displayedProfiles: [ProfileMatch] {
        isSearching ? profileMatches : popularProfiles
    }

    var suggestedContentSearch: SuggestedContentSearch? {
        guard supportsContentSearch else { return nil }
        return searchQuery.suggestedContentSearch
    }

    var hasAnySearchResults: Bool {
        !displayedProfiles.isEmpty || !visibleItems.isEmpty
    }

    var presentationState: PresentationState {
        PresentationState(viewModel: self)
    }

    func updateSearchContext(
        currentAccountPubkey: String?,
        currentNsec: String?,
        followedPubkeys: [String],
        invalidatePopularProfiles: Bool = true
    ) {
        let normalizedAccountPubkey = normalizedPubkey(currentAccountPubkey)
        let nextAccountPubkey = normalizedAccountPubkey.isEmpty ? nil : normalizedAccountPubkey
        let nextNsec = normalizedPrivateKey(currentNsec)
        let nextFollowedPubkeys = normalizedPubkeys(followedPubkeys)

        let didChange =
            self.currentAccountPubkey != nextAccountPubkey ||
            self.currentNsec != nextNsec ||
            self.followedAuthorPubkeys != nextFollowedPubkeys

        self.currentAccountPubkey = nextAccountPubkey
        self.currentNsec = nextNsec
        self.followedAuthorPubkeys = nextFollowedPubkeys

        guard didChange, !isSearching, invalidatePopularProfiles else { return }
        popularProfiles = []
        errorMessage = nil
    }

    func handleSearchTextChanged() {
        searchTask?.cancel()
        activeContentSearch = nil
        searchedNotes = []

        let query = searchQuery
        guard !query.isEmpty else {
            latestSearchRequestID = UUID()
            searchedNotes = []
            profileMatches = []
            errorMessage = nil
            isLoading = false
            return
        }

        profileMatches = []
        errorMessage = nil

        if supportsContentSearch, query.eventReference != nil {
            searchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                await self?.activateSuggestedContentSearch()
            }
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            await self?.performProfileSearch()
        }
    }

    func updateReadRelayURLs(_ newReadRelayURLs: [URL]) {
        let normalized = Self.normalizedRelayURLs(newReadRelayURLs)
        guard !normalized.isEmpty else { return }

        let current = readRelayURLs.map { $0.absoluteString.lowercased() }
        let next = normalized.map { $0.absoluteString.lowercased() }
        guard current != next else { return }

        readRelayURLs = normalized
        relayURL = normalized[0]

        if isSearching {
            handleSearchTextChanged()
        } else {
            trendingNotes.removeAll()
            errorMessage = nil
        }
    }

    func loadIfNeeded() async {
        if isSearching {
            await performProfileSearch()
            return
        }

        if popularProfiles.isEmpty {
            await refreshPopularProfiles()
        }
    }

    func refresh() async {
        if isSearching {
            if activeContentSearch == nil {
                await performProfileSearch()
            } else {
                await activateSuggestedContentSearch()
            }
            return
        }

        await refreshPopularProfiles()
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        // Search and trending are currently loaded in one window.
        _ = currentItem
    }

    func muteConversation(_ conversationID: String) {
        let normalized = conversationID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return }
        guard mutedConversationIDs.insert(normalized).inserted else { return }

        trendingNotes.removeAll { $0.event.conversationID == normalized }
        searchedNotes.removeAll { $0.event.conversationID == normalized }
    }

    func activateSuggestedContentSearch() async {
        guard let suggestion = suggestedContentSearch else { return }
        await performContentSearch(suggestion)
    }

    private func refreshPopularProfiles() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        let requestRelayURLs = readRelayURLs

        let cachedFollowedSuggestions = await buildFollowedSuggestions(
            relayURLs: requestRelayURLs,
            query: nil,
            limit: 12,
            allowProfileFetch: false
        )
        let cachedSecondDegreeSuggestions = await buildSecondDegreeSuggestions(
            relayURLs: requestRelayURLs,
            limit: 10,
            allowProfileFetch: false
        )
        popularProfiles = mergeProfileMatches(
            [cachedFollowedSuggestions, cachedSecondDegreeSuggestions],
            limit: 24
        )

        let followedSuggestions = await buildFollowedSuggestions(
            relayURLs: requestRelayURLs,
            query: nil,
            limit: 12
        )
        let secondDegreeSuggestions = await buildSecondDegreeSuggestions(
            relayURLs: requestRelayURLs,
            limit: 10
        )
        popularProfiles = mergeProfileMatches(
            [followedSuggestions, secondDegreeSuggestions],
            limit: 24
        )

        defer {
            isLoading = false
        }

        do {
            let fetched = try await trendingNotesLoader(
                service,
                requestRelayURLs,
                pageSize,
                nil,
                muteFilterSnapshot
            )

            guard requestRelayURLs == readRelayURLs else { return }
            let merged = deduplicateAndSort([fetched])
            trendingNotes = merged
            scheduleAssetPrefetch(for: merged)
            let trendingProfiles = await buildPopularProfiles(from: merged, relayURLs: requestRelayURLs)
            popularProfiles = mergeProfileMatches(
                [followedSuggestions, secondDegreeSuggestions, trendingProfiles],
                limit: 24
            )
        } catch {
            guard requestRelayURLs == readRelayURLs else { return }
            popularProfiles = mergeProfileMatches(
                [followedSuggestions, secondDegreeSuggestions],
                limit: 24
            )
            errorMessage = popularProfiles.isEmpty
                ? "Couldn't load people to discover. Pull to refresh and try again."
                : nil
        }
    }

    private func performProfileSearch() async {
        let query = searchQuery
        guard !query.isEmpty else {
            profileMatches = []
            errorMessage = nil
            isLoading = false
            return
        }

        if supportsContentSearch, query.normalizedHashtag != nil {
            profileMatches = []
            errorMessage = nil
            isLoading = false
            return
        }

        if supportsContentSearch, query.eventReference != nil {
            profileMatches = []
            errorMessage = nil
            isLoading = false
            return
        }

        let requestID = UUID()
        latestSearchRequestID = requestID
        isLoading = true
        errorMessage = nil
        profileMatches = []

        let profileRelayURLs = profileSearchRelayTargets()
        let normalizedProfileQuery = supportsContentSearch
            ? query.normalizedProfileQuery
            : query.normalizedPeopleOnlyProfileQuery
        let exactPubkey = query.resolvedProfilePubkey

        async let followedProfileMatchesResult = buildFollowedSuggestions(
            relayURLs: profileRelayURLs,
            query: normalizedProfileQuery,
            limit: 20
        )
        async let currentAccountProfileResult = fetchCurrentAccountProfileMatch(
            query: normalizedProfileQuery,
            relayURLs: profileRelayURLs
        )
        async let remoteProfileMatchesResult = fetchRemoteProfileMatches(
            query: normalizedProfileQuery,
            relayURLs: profileRelayURLs
        )
        async let localProfileMatchesResult = fetchLocalProfileMatches(query: normalizedProfileQuery)
        async let exactProfileResult = fetchExactProfile(
            pubkey: exactPubkey,
            relayURLs: profileRelayURLs
        )

        let followedProfileMatches = await followedProfileMatchesResult
        let currentAccountProfile = await currentAccountProfileResult

        guard latestSearchRequestID == requestID else { return }
        guard searchQuery.trimmed == query.trimmed else { return }

        let initialProfileMatches = mergeProfileMatches(
            [
                currentAccountProfile.map {
                    [ProfileMatch(pubkey: $0.pubkey, profile: $0.profile)]
                } ?? [],
                followedProfileMatches
            ],
            limit: 40
        )
        self.profileMatches = Array(
            rankedProfileMatches(query: normalizedProfileQuery, matches: initialProfileMatches)
                .prefix(20)
        )

        let remoteProfileMatches = await remoteProfileMatchesResult

        guard latestSearchRequestID == requestID else { return }
        guard searchQuery.trimmed == query.trimmed else { return }

        let vertexFirstProfiles = mergeProfileMatches(
            [
                currentAccountProfile.map {
                    [ProfileMatch(pubkey: $0.pubkey, profile: $0.profile)]
                } ?? [],
                followedProfileMatches,
                remoteProfileMatches.items.map { ProfileMatch(pubkey: $0.pubkey, profile: $0.profile) }
            ],
            limit: 60
        )

        self.profileMatches = Array(
            rankedProfileMatches(query: normalizedProfileQuery, matches: vertexFirstProfiles)
                .prefix(20)
        )

        let localProfileMatches = await localProfileMatchesResult
        let exactProfile = await exactProfileResult

        guard latestSearchRequestID == requestID else { return }
        guard searchQuery.trimmed == query.trimmed else { return }

        let mergedProfiles = mergeProfileMatches(
            [
                currentAccountProfile.map {
                    [ProfileMatch(pubkey: $0.pubkey, profile: $0.profile)]
                } ?? [],
                followedProfileMatches,
                remoteProfileMatches.items.map { ProfileMatch(pubkey: $0.pubkey, profile: $0.profile) },
                localProfileMatches.map { ProfileMatch(pubkey: $0.pubkey, profile: $0.profile) },
                exactProfile.map { [ProfileMatch(pubkey: $0.pubkey, profile: $0.profile)] } ?? []
            ],
            limit: 60
        )

        self.profileMatches = Array(
            rankedProfileMatches(query: normalizedProfileQuery, matches: mergedProfiles)
                .prefix(20)
        )
        errorMessage = self.profileMatches.isEmpty && remoteProfileMatches.failed
            ? "Couldn't search people right now. Pull to refresh and try again."
            : nil

        isLoading = false
    }

    private func fetchLocalProfileMatches(query: String) async -> [ProfileSearchResult] {
        guard !query.isEmpty else { return [] }
        return await service.searchProfiles(
            query: query,
            limit: 12
        )
    }

    private func fetchKeywordNotes(
        query: String,
        primaryRelayURLs: [URL],
        fallbackRelayURLs: [URL]
    ) async -> FeedFetchResult {
        let primary = await performKeywordNoteSearch(query: query, relayURLs: primaryRelayURLs)
        if !primary.items.isEmpty {
            return primary
        }

        let normalizedFallback = Self.normalizedRelayURLs(fallbackRelayURLs)
        let normalizedPrimary = Self.normalizedRelayURLs(primaryRelayURLs)
        let fallbackKeys = normalizedFallback.map { $0.absoluteString.lowercased() }
        let primaryKeys = normalizedPrimary.map { $0.absoluteString.lowercased() }
        guard fallbackKeys != primaryKeys else {
            return primary
        }

        let fallback = await performKeywordNoteSearch(query: query, relayURLs: normalizedFallback)
        if !fallback.items.isEmpty {
            return fallback
        }

        return FeedFetchResult(
            items: [],
            failed: primary.failed || fallback.failed
        )
    }

    private func fetchLocalKeywordNotes(query: String) async -> FeedFetchResult {
        let items = await service.searchLocalNotes(
            query: query,
            kinds: Self.searchFeedKinds,
            limit: pageSize,
            hydrationMode: .full,
            moderationSnapshot: muteFilterSnapshot
        )
        return FeedFetchResult(items: items, failed: false)
    }

    private func fetchReferencedNote(
        reference: NostrEventReferencePointer
    ) async -> FeedFetchResult {
        let relayURLs = Self.normalizedRelayURLs(readRelayURLs + Self.bigRelayURLs)
        guard let item = await service.fetchReferencedFeedItem(
            reference: reference,
            relayURLs: relayURLs,
            hydrationMode: .full,
            fetchTimeout: Self.noteSearchFetchTimeout,
            moderationSnapshot: muteFilterSnapshot
        ) else {
            return .empty
        }

        return FeedFetchResult(items: [item], failed: false)
    }

    private func performKeywordNoteSearch(query: String, relayURLs: [URL]) async -> FeedFetchResult {
        guard !relayURLs.isEmpty else { return .empty }
        do {
            let items = try await service.searchNotes(
                relayURLs: relayURLs,
                query: query,
                kinds: Self.searchFeedKinds,
                limit: pageSize,
                hydrationMode: .full,
                fetchTimeout: Self.noteSearchFetchTimeout,
                relayFetchMode: Self.noteSearchRelayFetchMode,
                moderationSnapshot: muteFilterSnapshot
            )
            return FeedFetchResult(items: items, failed: false)
        } catch {
            return FeedFetchResult(items: [], failed: true)
        }
    }

    private func fetchHashtagNotes(hashtag: String?, relayURLs: [URL]) async -> FeedFetchResult {
        guard let hashtag, !hashtag.isEmpty else { return .empty }
        do {
            let hashtagRelayURLs = Self.normalizedRelayURLs(relayURLs + Self.bigRelayURLs)
            let items = try await service.fetchHashtagFeed(
                relayURLs: hashtagRelayURLs,
                hashtag: hashtag,
                kinds: Self.searchFeedKinds,
                limit: pageSize,
                until: nil,
                hydrationMode: .full,
                fetchTimeout: Self.noteSearchFetchTimeout,
                relayFetchMode: Self.noteSearchRelayFetchMode,
                moderationSnapshot: muteFilterSnapshot
            )
            return FeedFetchResult(items: items, failed: false)
        } catch {
            return FeedFetchResult(items: [], failed: true)
        }
    }

    private func fetchLocalHashtagNotes(hashtag: String?) async -> FeedFetchResult {
        guard let hashtag, !hashtag.isEmpty else { return .empty }
        let items = await service.fetchLocalHashtagFeed(
            hashtag: hashtag,
            kinds: Self.searchFeedKinds,
            limit: pageSize,
            until: nil,
            hydrationMode: .full,
            moderationSnapshot: muteFilterSnapshot
        )
        return FeedFetchResult(items: items, failed: false)
    }

    private func fetchRemoteProfileMatches(query: String, relayURLs: [URL]) async -> ProfileFetchResult {
        guard query.count >= 2 else { return .empty }
        guard let searchNsec = currentNsec, !searchNsec.isEmpty else { return .empty }
        guard query.count > 3 else { return .empty }

        do {
            let matches = try await vertexSearchService.searchProfiles(
                query: query,
                limit: 12,
                nsec: searchNsec,
                relayURLs: relayURLs,
                feedService: service
            )
            return ProfileFetchResult(items: matches, failed: false)
        } catch {
            return ProfileFetchResult(items: [], failed: true)
        }
    }

    private func performContentSearch(_ target: SuggestedContentSearch) async {
        let query = searchQuery
        guard !query.isEmpty else {
            activeContentSearch = nil
            searchedNotes = []
            errorMessage = nil
            isLoading = false
            return
        }

        let requestID = UUID()
        latestSearchRequestID = requestID
        activeContentSearch = target
        isLoading = true
        errorMessage = nil
        searchedNotes = []

        let keywordRelayURLs = keywordSearchRelayTargets()
        let keywordFallbackRelayURLs = fallbackKeywordSearchRelayTargets()
        let hashtagRelayURLs = hashtagSearchRelayTargets()
        let profileRelayURLs = profileSearchRelayTargets()
        let exactPubkey = query.resolvedProfilePubkey
        let profileAuthorPubkeys = Array(profileMatches.map { $0.pubkey.lowercased() }.prefix(12))

        var hadNetworkFailures = false

        @discardableResult
        func apply(_ result: FeedFetchResult) -> Bool {
            hadNetworkFailures = hadNetworkFailures || result.failed
            guard latestSearchRequestID == requestID else { return false }
            guard searchQuery.trimmed == query.trimmed else { return false }
            guard activeContentSearch == target else { return false }

            let mergedNotes = deduplicateAndSort([searchedNotes, result.items])
            let prefetchedNotes = Array(mergedNotes.prefix(pageSize))
            searchedNotes = prefetchedNotes
            scheduleAssetPrefetch(for: prefetchedNotes)
            errorMessage = nil
            return true
        }

        switch target.kind {
        case .notes(let notesQuery):
            let localKeywordNotes = await fetchLocalKeywordNotes(query: notesQuery)
            guard apply(localKeywordNotes) else { return }

            async let exactAuthorNotesResult = fetchExactAuthorNotes(
                pubkey: exactPubkey,
                relayURLs: profileRelayURLs
            )
            async let profileAuthoredNotesResult: FeedFetchResult = {
                guard !profileAuthorPubkeys.isEmpty else { return .empty }
                return await fetchProfileAuthoredNotes(
                    pubkeys: profileAuthorPubkeys,
                    relayURLs: profileRelayURLs
                )
            }()
            async let remoteKeywordNotesResult = fetchKeywordNotes(
                query: notesQuery,
                primaryRelayURLs: keywordRelayURLs,
                fallbackRelayURLs: keywordFallbackRelayURLs
            )

            let exactAuthorNotes = await exactAuthorNotesResult
            guard apply(exactAuthorNotes) else { return }

            let profileAuthoredNotes = await profileAuthoredNotesResult
            guard apply(profileAuthoredNotes) else { return }

            let remoteKeywordNotes = await remoteKeywordNotesResult
            guard apply(remoteKeywordNotes) else { return }

        case .hashtag(let hashtag):
            let localHashtagNotes = await fetchLocalHashtagNotes(hashtag: hashtag)
            guard apply(localHashtagNotes) else { return }

            let remoteHashtagNotes = await fetchHashtagNotes(hashtag: hashtag, relayURLs: hashtagRelayURLs)
            guard apply(remoteHashtagNotes) else { return }
        case .eventReference(let reference):
            let referencedNote = await fetchReferencedNote(reference: reference)
            guard apply(referencedNote) else { return }
        }

        if searchedNotes.isEmpty && hadNetworkFailures {
            errorMessage = "Couldn't search notes right now. Pull to refresh and try again."
        } else {
            errorMessage = nil
        }

        isLoading = false
    }

    private func fetchExactAuthorNotes(pubkey: String?, relayURLs: [URL]) async -> FeedFetchResult {
        guard let pubkey, !pubkey.isEmpty else { return .empty }
        do {
            let items = try await service.fetchFollowingFeed(
                relayURLs: relayURLs,
                authors: [pubkey],
                kinds: Self.searchFeedKinds,
                limit: pageSize,
                until: nil,
                hydrationMode: .full,
                fetchTimeout: Self.noteSearchFetchTimeout,
                relayFetchMode: Self.noteSearchRelayFetchMode,
                relayOnly: true,
                moderationSnapshot: muteFilterSnapshot
            )
            return FeedFetchResult(items: items, failed: false)
        } catch {
            return FeedFetchResult(items: [], failed: true)
        }
    }

    private func fetchProfileAuthoredNotes(pubkeys: [String], relayURLs: [URL]) async -> FeedFetchResult {
        guard !pubkeys.isEmpty else { return .empty }
        do {
            let items = try await service.fetchFollowingFeed(
                relayURLs: relayURLs,
                authors: pubkeys,
                kinds: Self.searchFeedKinds,
                limit: pageSize,
                until: nil,
                hydrationMode: .full,
                fetchTimeout: Self.noteSearchFetchTimeout,
                relayFetchMode: Self.noteSearchRelayFetchMode,
                relayOnly: true,
                moderationSnapshot: muteFilterSnapshot
            )
            return FeedFetchResult(items: items, failed: false)
        } catch {
            return FeedFetchResult(items: [], failed: true)
        }
    }

    private func fetchExactProfile(pubkey: String?, relayURLs: [URL]) async -> ProfileSearchResult? {
        guard let pubkey, !pubkey.isEmpty else { return nil }
        let profile = await service.fetchProfile(
            relayURLs: relayURLs,
            pubkey: pubkey,
            fetchTimeout: Self.profileSearchFetchTimeout,
            relayFetchMode: Self.profileSearchRelayFetchMode
        )
        return ProfileSearchResult(pubkey: pubkey, profile: profile, createdAt: Int(Date().timeIntervalSince1970))
    }

    private func fetchCurrentAccountProfileMatch(
        query: String,
        relayURLs: [URL]
    ) async -> ProfileSearchResult? {
        guard let currentAccountPubkey, !currentAccountPubkey.isEmpty else { return nil }
        guard !query.isEmpty else { return nil }

        let profile: NostrProfile?
        if let cachedProfile = await service.cachedProfile(pubkey: currentAccountPubkey) {
            profile = cachedProfile
        } else {
            profile = await service.fetchProfile(
                relayURLs: relayURLs,
                pubkey: currentAccountPubkey,
                fetchTimeout: Self.profileSearchFetchTimeout,
                relayFetchMode: .firstNonEmptyRelay
            )
        }

        guard let profile else { return nil }
        guard profileMatchesQuery(profile: profile, pubkey: currentAccountPubkey, query: query) else {
            return nil
        }

        return ProfileSearchResult(
            pubkey: currentAccountPubkey,
            profile: profile,
            createdAt: Int(Date().timeIntervalSince1970)
        )
    }

    private func filteredItems(_ items: [FeedItem]) -> [FeedItem] {
        let hideNSFW = AppSettingsStore.shared.hideNSFWContent
        return items.filter { item in
            if mutedConversationIDs.contains(item.displayEvent.conversationID) {
                return false
            }
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
    }

    private func pruneMutedItems(
        _ items: [FeedItem],
        snapshot: MuteFilterSnapshot? = nil
    ) -> [FeedItem] {
        let snapshot = snapshot ?? muteFilterSnapshot
        let hasMarkedSpam = !AppSettingsStore.shared.spamFilterMarkedPubkeys.isEmpty
        guard snapshot.hasAnyRules || hasMarkedSpam else { return items }

        return items.filter { item in
            !snapshot.shouldHideAny(in: item.moderationEvents)
                && !AppSettingsStore.shared.shouldHideSpamMarkedPubkey(item.displayAuthorPubkey)
        }
    }

    private func scheduleAssetPrefetch(for items: [FeedItem]) {
        let urls = Array(
            items
                .prefix(assetPrefetchItemCount)
                .flatMap(\.prefetchImageURLs)
        )
        guard !urls.isEmpty else { return }

        Task(priority: .utility) {
            await FlowImageCache.shared.prefetch(urls: urls)
        }
    }

    private func clearVisibleItemsCache() {
        visibleItemsCacheKey = nil
        visibleItemsCache = []
    }

    private func deduplicateAndSort(_ groups: [[FeedItem]]) -> [FeedItem] {
        var byID: [String: FeedItem] = [:]

        for group in groups {
            for item in group {
                byID[item.id.lowercased()] = item
            }
        }

        return pruneMutedItems(byID.values.sorted {
            if $0.event.createdAt == $1.event.createdAt {
                return $0.id > $1.id
            }
            return $0.event.createdAt > $1.event.createdAt
        })
    }

    private func buildPopularProfiles(from items: [FeedItem], relayURLs: [URL]) async -> [ProfileMatch] {
        var seen = Set<String>()
        var orderedPubkeys: [String] = []
        var profilesByPubkey: [String: NostrProfile] = [:]

        for item in items {
            let pubkey = item.displayAuthorPubkey.lowercased()
            guard seen.insert(pubkey).inserted else { continue }
            orderedPubkeys.append(pubkey)
            if let profile = item.displayProfile ?? item.profile {
                profilesByPubkey[pubkey] = profile
            }
            if orderedPubkeys.count >= 20 {
                break
            }
        }

        if orderedPubkeys.isEmpty {
            return []
        }

        let missingPubkeys = orderedPubkeys.filter { profilesByPubkey[$0] == nil }
        if !missingPubkeys.isEmpty {
            let fetched = await service.fetchProfiles(
                relayURLs: relayURLs,
                pubkeys: missingPubkeys
            )
            for (pubkey, profile) in fetched {
                profilesByPubkey[pubkey] = profile
            }
        }

        return orderedPubkeys.map { pubkey in
            ProfileMatch(pubkey: pubkey, profile: profilesByPubkey[pubkey])
        }
    }

    private func buildFollowedSuggestions(
        relayURLs: [URL],
        query: String?,
        limit: Int,
        allowProfileFetch: Bool = true
    ) async -> [ProfileMatch] {
        let orderedFollowedPubkeys = await preferredFollowedPubkeys()
        guard !orderedFollowedPubkeys.isEmpty else { return [] }

        let isSearchingSpecificFollowedProfiles = query?.isEmpty == false
        let candidateLimit = max(limit * 3, 36)
        let candidatePubkeys = isSearchingSpecificFollowedProfiles
            ? orderedFollowedPubkeys
            : Array(orderedFollowedPubkeys.prefix(candidateLimit))
        var profilesByPubkey = await service.cachedProfiles(pubkeys: candidatePubkeys)

        let missingFetchLimit = isSearchingSpecificFollowedProfiles
            ? max(limit * 12, 120)
            : limit * 2
        let missingPubkeys = Array(candidatePubkeys.filter { profilesByPubkey[$0] == nil }.prefix(missingFetchLimit))
        if allowProfileFetch, !missingPubkeys.isEmpty {
            let fetchedProfiles = await service.fetchProfiles(
                relayURLs: relayURLs,
                pubkeys: missingPubkeys
            )
            profilesByPubkey.merge(fetchedProfiles, uniquingKeysWith: { _, new in new })
        }

        let matches = candidatePubkeys.compactMap { pubkey -> ProfileMatch? in
            let profile = profilesByPubkey[pubkey]
            if let query, !query.isEmpty,
               profileSearchScore(profile: profile, pubkey: pubkey, query: query) == nil {
                return nil
            }
            return ProfileMatch(pubkey: pubkey, profile: profile)
        }

        guard let query, !query.isEmpty else {
            return Array(matches.prefix(limit))
        }

        return Array(
            rankedProfileMatches(query: query, matches: matches)
                .prefix(limit)
        )
    }

    private func buildSecondDegreeSuggestions(
        relayURLs: [URL],
        limit: Int,
        allowProfileFetch: Bool = true
    ) async -> [ProfileMatch] {
        guard !followedAuthorPubkeys.isEmpty else { return [] }

        let followedSet = Set(followedAuthorPubkeys)
        let orderedFollowedPubkeys = await preferredFollowedPubkeys()
        let seedPubkeys = Array(orderedFollowedPubkeys.prefix(20))

        var mutualCounts: [String: Int] = [:]
        for pubkey in seedPubkeys {
            guard let snapshot = await service.cachedFollowListSnapshot(pubkey: pubkey) else { continue }
            for candidate in snapshot.followedPubkeys {
                let normalizedCandidate = normalizedPubkey(candidate)
                guard !normalizedCandidate.isEmpty else { continue }
                guard normalizedCandidate != currentAccountPubkey else { continue }
                guard !followedSet.contains(normalizedCandidate) else { continue }
                mutualCounts[normalizedCandidate, default: 0] += 1
            }
        }

        let orderedCandidates = mutualCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        guard !orderedCandidates.isEmpty else { return [] }

        let candidatePubkeys = Array(orderedCandidates.prefix(limit * 3))
        var profilesByPubkey = await service.cachedProfiles(pubkeys: candidatePubkeys)
        let missingPubkeys = Array(candidatePubkeys.filter { profilesByPubkey[$0] == nil }.prefix(limit * 2))
        if allowProfileFetch, !missingPubkeys.isEmpty {
            let fetchedProfiles = await service.fetchProfiles(
                relayURLs: relayURLs,
                pubkeys: missingPubkeys
            )
            profilesByPubkey.merge(fetchedProfiles, uniquingKeysWith: { _, new in new })
        }

        return candidatePubkeys.compactMap { pubkey in
            guard let profile = profilesByPubkey[pubkey] else { return nil }
            return ProfileMatch(pubkey: pubkey, profile: profile)
        }
        .prefix(limit)
        .map { $0 }
    }

    private func preferredFollowedPubkeys() async -> [String] {
        if let currentAccountPubkey,
           let snapshot = await service.cachedFollowListSnapshot(pubkey: currentAccountPubkey) {
            let ordered = normalizedPubkeys(snapshot.followedPubkeys)
            if !ordered.isEmpty {
                return ordered
            }
        }

        return followedAuthorPubkeys
    }

    private func mergeProfileMatches(_ groups: [[ProfileMatch]], limit: Int) -> [ProfileMatch] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var ordered: [ProfileMatch] = []

        for group in groups {
            for match in group {
                let normalized = normalizedPubkey(match.pubkey)
                guard !normalized.isEmpty else { continue }
                guard seen.insert(normalized).inserted else { continue }
                ordered.append(ProfileMatch(pubkey: normalized, profile: match.profile))
                if ordered.count >= limit {
                    return ordered
                }
            }
        }

        return ordered
    }

    private func rankedProfileMatches(query: String, matches: [ProfileMatch]) -> [ProfileMatch] {
        let normalizedQuery = SearchQueryDescriptor(rawText: query).normalizedProfileQuery
        guard !normalizedQuery.isEmpty else { return matches }

        let followedSet = Set(followedAuthorPubkeys)
        let scoredMatches: [(match: ProfileMatch, score: Int)] = matches.compactMap { match in
            let normalizedPubkey = normalizedPubkey(match.pubkey)
            guard let baseScore = profileSearchScore(
                profile: match.profile,
                pubkey: normalizedPubkey,
                query: normalizedQuery
            ) else {
                return nil
            }

            var score = baseScore
            if normalizedPubkey == currentAccountPubkey {
                score += 4_000
            } else if followedSet.contains(normalizedPubkey) {
                score += 2_000
            }

            return (match: match, score: score)
        }

        return scoredMatches.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.match.displayName.localizedCaseInsensitiveCompare(rhs.match.displayName) == .orderedAscending
            }
            return lhs.score > rhs.score
        }
        .map(\.match)
    }

    private func mergeProfileResults(_ groups: [[ProfileSearchResult]]) -> [ProfileSearchResult] {
        var seen = Set<String>()
        var ordered: [ProfileSearchResult] = []

        for group in groups {
            for profile in group {
                let normalizedPubkey = profile.pubkey.lowercased()
                guard seen.insert(normalizedPubkey).inserted else { continue }
                ordered.append(profile)
            }
        }

        return ordered
    }

    private func keywordSearchRelayTargets() -> [URL] {
        Self.normalizedRelayURLs(Self.searchableRelayURLs)
    }

    private func fallbackKeywordSearchRelayTargets() -> [URL] {
        Self.normalizedRelayURLs(Self.bigRelayURLs + readRelayURLs)
    }

    private func hashtagSearchRelayTargets() -> [URL] {
        Self.normalizedRelayURLs(readRelayURLs + Self.bigRelayURLs)
    }

    private func profileSearchRelayTargets() -> [URL] {
        Self.normalizedRelayURLs(Self.searchableRelayURLs + [VertexProfileSearchService.relayURL] + Self.bigRelayURLs + readRelayURLs)
    }

    private func profileMatchesQuery(profile: NostrProfile, pubkey: String, query: String) -> Bool {
        profileSearchScore(profile: profile, pubkey: pubkey, query: query) != nil
    }

    private func profileSearchScore(profile: NostrProfile?, pubkey: String, query: String) -> Int? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }

        if pubkey == normalizedQuery {
            return 1_000
        }

        if pubkey.hasPrefix(normalizedQuery) {
            return 920
        }

        guard let profile else { return nil }

        let searchableFields = profileSearchFields(for: profile)
        guard !searchableFields.isEmpty else { return nil }

        let tokenSet = Set(searchableFields.flatMap(profileSearchTokens(from:)))

        if searchableFields.contains(normalizedQuery) {
            return 900
        }

        if tokenSet.contains(normalizedQuery) {
            return 860
        }

        if searchableFields.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 820
        }

        if tokenSet.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 780
        }

        guard normalizedQuery.count >= 2 else { return nil }

        if searchableFields.contains(where: { $0.contains(normalizedQuery) }) {
            return 700
        }

        if tokenSet.contains(where: { $0.contains(normalizedQuery) }) {
            return 660
        }

        return nil
    }

    private func profileSearchFields(for profile: NostrProfile) -> [String] {
        let rawFields: [String] = [
            profile.displayName,
            profile.name,
            profile.nip05,
            profile.lud16,
            profile.lud06
        ]
        .compactMap { value in
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return normalized.isEmpty ? nil : normalized
        }

        var expandedFields: [String] = []
        var seen = Set<String>()

        for field in rawFields {
            if seen.insert(field).inserted {
                expandedFields.append(field)
            }

            let compact = field.replacingOccurrences(of: " ", with: "")
            if !compact.isEmpty, seen.insert(compact).inserted {
                expandedFields.append(compact)
            }

            if field.hasPrefix("@") {
                let dropped = String(field.dropFirst())
                if !dropped.isEmpty, seen.insert(dropped).inserted {
                    expandedFields.append(dropped)
                }
            }

            if let atIndex = field.firstIndex(of: "@"), atIndex > field.startIndex {
                let localPart = String(field[..<atIndex])
                if !localPart.isEmpty, seen.insert(localPart).inserted {
                    expandedFields.append(localPart)
                }
            }
        }

        return expandedFields
    }

    private func profileSearchTokens(from field: String) -> [String] {
        field.split(whereSeparator: { character in
            !character.isLetter && !character.isNumber
        })
        .map(String.init)
        .filter { !$0.isEmpty }
    }

    private func normalizedPrivateKey(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys {
            let normalized = normalizedPubkey(pubkey)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func normalizedPubkey(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func defaultTrendingNotesLoader(
        service: NostrFeedService,
        relayURLs: [URL],
        limit: Int,
        until: Int?,
        moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [FeedItem] {
        return try await service.fetchTrendingNotes(
            limit: min(limit, 100),
            until: until,
            hydrationRelayURLs: relayURLs,
            moderationSnapshot: moderationSnapshot
        )
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
}
