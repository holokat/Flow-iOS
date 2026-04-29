import SwiftUI

struct SearchView: View {
    private static let feedHorizontalInset: CGFloat = 14
    private static let bottomScrollClearance: CGFloat = 110
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    private let reactionStats = NoteReactionStatsService.shared
    @StateObject private var engagementViewport = FeedEngagementViewportCoordinator()
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var hashtagFavoritesStore = HashtagFavoritesStore.shared
    @ObservedObject private var muteStore = MuteStore.shared

    @StateObject private var viewModel: SearchViewModel

    @State private var selectedThreadItem: FeedItem?
    @State private var selectedHashtagRoute: HashtagRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var selectedRelayRoute: RelayRoute?
    @State private var shouldAutoFocusReplyInThread = false
    private let isActive: Bool

    init(viewModel: SearchViewModel? = nil, isActive: Bool = true) {
        let initialRelayURL = URL(
            string: RelaySettingsStore.defaultReadRelayURLs.first ?? "wss://relay.damus.io/"
        )!
        _viewModel = StateObject(
            wrappedValue: viewModel ?? SearchViewModel(relayURL: initialRelayURL)
        )
        self.isActive = isActive
    }

    var body: some View {
        let _ = muteStore.filterRevision
        let _ = appSettings.spamFilterLabelSignature
        let visibleItems = viewModel.visibleItems
        let visibleProfiles = viewModel.displayedProfiles
        let visibleReplyCounts = ReplyCountEstimator.counts(for: visibleItems)

        NavigationStack {
            ZStack {
                AppThemeBackgroundView()
                    .ignoresSafeArea()

                List {
                    if let suggestion = viewModel.suggestedContentSearch {
                        searchActionRow(suggestion)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 8,
                                    leading: Self.feedHorizontalInset,
                                    bottom: 8,
                                    trailing: Self.feedHorizontalInset
                                )
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    if viewModel.isLoading && !viewModel.hasAnySearchResults {
                        ForEach(0..<6, id: \.self) { _ in
                            loadingRow
                                .listRowInsets(
                                    EdgeInsets(
                                        top: 0,
                                        leading: Self.feedHorizontalInset,
                                        bottom: 0,
                                        trailing: Self.feedHorizontalInset
                                    )
                                )
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        if !visibleProfiles.isEmpty {
                            Section {
                                ForEach(visibleProfiles) { profile in
                                    profileResultRow(profile)
                                        .listRowInsets(
                                            EdgeInsets(
                                                top: 8,
                                                leading: Self.feedHorizontalInset,
                                                bottom: 8,
                                                trailing: Self.feedHorizontalInset
                                            )
                                        )
                                        .listRowSeparator(.visible)
                                        .listRowSeparatorTint(appSettings.themePalette.chromeBorder)
                                        .listRowBackground(Color.clear)
                                }
                            } header: {
                                Text(viewModel.isSearching ? "People" : "Suggestions")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                                    .textCase(nil)
                            }
                        }

                        if let activeContentSearch = viewModel.activeContentSearch {
                            if visibleItems.isEmpty {
                                notesEmptyState(activeContentSearch)
                                    .listRowInsets(
                                        EdgeInsets(
                                            top: 0,
                                            leading: Self.feedHorizontalInset,
                                            bottom: 0,
                                            trailing: Self.feedHorizontalInset
                                        )
                                    )
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            } else {
                                Section {
                                    ForEach(visibleItems) { item in
                                        noteResultRow(item, visibleReplyCounts: visibleReplyCounts)
                                    }
                                } header: {
                                    Text(activeContentSearch.sectionTitle)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                                        .textCase(nil)
                                }
                            }
                        } else if visibleProfiles.isEmpty {
                            emptyState
                            .listRowInsets(
                                EdgeInsets(
                                    top: 0,
                                    leading: Self.feedHorizontalInset,
                                    bottom: 0,
                                    trailing: Self.feedHorizontalInset
                                )
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }

                    if viewModel.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: Self.feedHorizontalInset,
                                bottom: 0,
                                trailing: Self.feedHorizontalInset
                            )
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    if !visibleItems.isEmpty || viewModel.isLoadingMore {
                        Color.clear
                            .frame(height: Self.bottomScrollClearance)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .safeAreaInset(edge: .top, spacing: 0) {
                    searchBar
                }
                .toolbar(.hidden, for: .navigationBar)
                .refreshable {
                    appSettings.configure(accountPubkey: auth.currentAccount?.pubkey)
                    configureStores()
                    updateSearchContext()
                    viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
                    hashtagFavoritesStore.configure(accountPubkey: auth.currentAccount?.pubkey)
                    await viewModel.refresh()
                    MuteStore.shared.refreshFromRelay()
                }
                .task(id: isActive) {
                    guard isActive else { return }
                    appSettings.configure(accountPubkey: auth.currentAccount?.pubkey)
                    configureStores()
                    updateSearchContext()
                    viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
                    hashtagFavoritesStore.configure(accountPubkey: auth.currentAccount?.pubkey)
                    await viewModel.loadIfNeeded()
                }
                .onChange(of: viewModel.searchText) { _, _ in
                    viewModel.handleSearchTextChanged()
                    if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task {
                            await viewModel.loadIfNeeded()
                        }
                    }
                }
                .navigationDestination(item: $selectedThreadItem) { item in
                    ThreadDetailView(
                        initialItem: item,
                        relayURL: effectivePrimaryRelayURL,
                        readRelayURLs: effectiveReadRelayURLs,
                        initiallyFocusReplyComposer: shouldAutoFocusReplyInThread
                    )
                }
                .navigationDestination(item: $selectedHashtagRoute) { route in
                    HashtagFeedView(
                        hashtag: route.normalizedHashtag,
                        relayURL: effectivePrimaryRelayURL,
                        readRelayURLs: effectiveReadRelayURLs,
                        seedItems: route.seedItems
                    )
                }
                .navigationDestination(item: $selectedProfileRoute) { route in
                    ProfileView(
                        pubkey: route.pubkey,
                        relayURL: effectivePrimaryRelayURL,
                        readRelayURLs: effectiveReadRelayURLs,
                        writeRelayURLs: effectiveWriteRelayURLs
                    )
                }
                .navigationDestination(item: $selectedRelayRoute) { route in
                    RelayFeedView(relayURL: route.relayURL, title: route.displayName)
                }
                .onChange(of: auth.currentAccount?.pubkey) { _, _ in
                    appSettings.configure(accountPubkey: auth.currentAccount?.pubkey)
                    configureStores()
                    updateSearchContext()
                    hashtagFavoritesStore.configure(accountPubkey: auth.currentAccount?.pubkey)
                    guard isActive else { return }
                    Task {
                        await viewModel.loadIfNeeded()
                    }
                }
                .onChange(of: auth.currentNsec) { _, _ in
                    configureStores()
                    updateSearchContext()
                }
                .onChange(of: followStore.followedPubkeys) { _, _ in
                    // Preserve the current suggestion list so an optimistic
                    // follow tap only flips the button state instead of
                    // rebuilding the entire screen.
                    updateSearchContext(invalidatePopularProfiles: false)
                }
                .onChange(of: relaySettings.readRelays) { _, _ in
                    viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
                    guard isActive else { return }
                    Task {
                        await viewModel.loadIfNeeded()
                    }
                }
                .onChange(of: relaySettings.writeRelays) { _, _ in
                    configureStores()
                }
                .onChange(of: appSettings.slowConnectionMode) { _, _ in
                    configureStores()
                    viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
                    guard isActive else { return }
                    Task {
                        await viewModel.refresh()
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        SearchBarSection(searchText: $viewModel.searchText) {
            Task {
                await viewModel.activateSuggestedContentSearch()
            }
        }
    }

    private var emptyState: some View {
        SearchEmptyStateSection(
            errorMessage: viewModel.errorMessage,
            isSearching: viewModel.isSearching,
            searchText: viewModel.searchText
        ) {
            Task {
                await viewModel.refresh()
            }
        }
    }

    private func notesEmptyState(_ activeContentSearch: SearchViewModel.SuggestedContentSearch) -> some View {
        SearchNotesEmptyStateSection(
            errorMessage: viewModel.errorMessage,
            activeContentSearch: activeContentSearch
        )
    }

    private var loadingRow: some View {
        SearchLoadingRow()
    }

    private func profileResultRow(_ profile: SearchViewModel.ProfileMatch) -> some View {
        SearchProfileResultRow(profile: profile) { pubkey in
            openProfile(pubkey: pubkey)
        }
    }

    private func searchActionRow(_ suggestion: SearchViewModel.SuggestedContentSearch) -> some View {
        SearchActionCard(
            suggestion: suggestion,
            isActive: viewModel.activeContentSearch == suggestion,
            isPinned: isPinnedFeedSuggestion(suggestion)
        ) {
            Task {
                await viewModel.activateSuggestedContentSearch()
            }
        } onTogglePinned: {
            togglePinnedFeedSuggestion(suggestion)
        }
    }

    private func noteResultRow(_ item: FeedItem, visibleReplyCounts: [String: Int]) -> some View {
        FeedRowView(
            item: item,
            initialEngagementSnapshot: reactionStats.currentSnapshot(for: item.displayEventID),
            commentCount: visibleReplyCounts[item.displayEventID.lowercased()] ?? 0,
            showReactions: appSettings.reactionsVisibleInFeeds,
            avatarMenuActions: .init(
                followLabel: followStore.isFollowing(item.displayAuthorPubkey) ? "Unfollow" : "Follow",
                onFollowToggle: {
                    followStore.toggleFollow(item.displayAuthorPubkey)
                },
                onViewProfile: {
                    openProfile(pubkey: item.displayAuthorPubkey)
                }
            ),
            onHashtagTap: { hashtag in
                openHashtagFeed(hashtag: hashtag)
            },
            onProfileTap: { pubkey in
                openProfile(pubkey: pubkey)
            },
            onOpenThread: {
                shouldAutoFocusReplyInThread = false
                selectedThreadItem = item.threadNavigationItem
            },
            onRepostActorTap: { pubkey in
                openProfile(pubkey: pubkey)
            },
            onReferencedEventTap: { referencedItem in
                shouldAutoFocusReplyInThread = false
                selectedThreadItem = referencedItem.threadNavigationItem
            },
            onRelayTap: { relayURL in
                openRelayFeed(relayURL: relayURL)
            },
            onMuteConversation: { conversationID in
                viewModel.muteConversation(conversationID)
            }
        )
        .listRowInsets(
            EdgeInsets(
                top: 0,
                leading: Self.feedHorizontalInset,
                bottom: 0,
                trailing: Self.feedHorizontalInset
            )
        )
        .listRowSeparator(appSettings.themePalette.feedCardStyle == nil ? .visible : .hidden)
        .listRowSeparatorTint(appSettings.themePalette.chromeBorder)
        .listRowBackground(Color.clear)
        .onAppear {
            if appSettings.reactionsVisibleInFeeds {
                engagementViewport.noteVisible(
                    event: item.displayEvent,
                    relayURLs: effectiveReadRelayURLs
                )
            }
            Task {
                await viewModel.loadMoreIfNeeded(currentItem: item)
            }
        }
    }

    private func configureStores() {
        relaySettings.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec
        )
        followStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
        MuteStore.shared.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
    }

    private func updateSearchContext(invalidatePopularProfiles: Bool = true) {
        viewModel.updateSearchContext(
            currentAccountPubkey: auth.currentAccount?.pubkey,
            currentNsec: auth.currentNsec,
            followedPubkeys: Array(followStore.followedPubkeys),
            invalidatePopularProfiles: invalidatePopularProfiles
        )
    }

    private func openHashtagFeed(hashtag: String) {
        let route = HashtagRoute(
            hashtag: hashtag,
            seedItems: matchingHashtagSeedItems(
                hashtag: hashtag,
                from: viewModel.visibleItems
            )
        )
        selectedHashtagRoute = route
    }

    private func openProfile(pubkey: String) {
        selectedProfileRoute = ProfileRoute(pubkey: pubkey)
    }

    private func openRelayFeed(relayURL: URL) {
        selectedRelayRoute = RelayRoute(relayURL: relayURL)
    }

    private func isPinnedFeedSuggestion(_ suggestion: SearchViewModel.SuggestedContentSearch) -> Bool {
        switch suggestion.kind {
        case .hashtag(let hashtag):
            return hashtagFavoritesStore.isFavorite(hashtag)
        case .notes(let query):
            return appSettings.customFeed(withID: savedSearchFeedID(for: query)) != nil
        case .eventReference:
            return false
        }
    }

    private func togglePinnedFeedSuggestion(_ suggestion: SearchViewModel.SuggestedContentSearch) {
        switch suggestion.kind {
        case .hashtag(let hashtag):
            hashtagFavoritesStore.toggleFavorite(hashtag)
        case .notes(let query):
            let feedID = savedSearchFeedID(for: query)
            if appSettings.customFeed(withID: feedID) != nil {
                appSettings.removeCustomFeed(id: feedID)
            } else if let feed = savedSearchFeedDefinition(for: query) {
                try? appSettings.saveCustomFeed(feed)
            }
        case .eventReference:
            break
        }
    }

    private func savedSearchFeedDefinition(for query: String) -> CustomFeedDefinition? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        return CustomFeedDefinition(
            id: savedSearchFeedID(for: trimmedQuery),
            name: trimmedQuery,
            iconSystemName: "magnifyingglass",
            phrases: [trimmedQuery]
        )
    }

    private func savedSearchFeedID(for query: String) -> String {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        return "saved-search:\(normalized)"
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: effectiveReadRelayURLs
        )
    }

    private var effectivePrimaryRelayURL: URL {
        effectiveReadRelayURLs.first ?? AppSettingsStore.slowModeRelayURL
    }
}
