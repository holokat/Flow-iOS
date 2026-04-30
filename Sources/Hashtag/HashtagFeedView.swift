import SwiftUI

struct HashtagFeedView: View {
    private static let feedHorizontalInset: CGFloat = 14
    private static let bottomScrollClearance: CGFloat = 110
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @StateObject private var viewModel: HashtagFeedViewModel
    private let reactionStats = NoteReactionStatsService.shared
    @StateObject private var engagementViewport = FeedEngagementViewportCoordinator()
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var muteStore = MuteStore.shared
    @ObservedObject private var hashtagFavoritesStore = HashtagFavoritesStore.shared
    @State private var selectedThreadItem: FeedItem?
    @State private var selectedHashtagRoute: HashtagRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var selectedRelayRoute: RelayRoute?
    @State private var shouldAutoFocusReplyInThread = false

    init(
        hashtag: String,
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        seedItems: [FeedItem] = [],
        service: NostrFeedService = NostrFeedService()
    ) {
        _viewModel = StateObject(
            wrappedValue: HashtagFeedViewModel(
                hashtag: hashtag,
                relayURL: relayURL,
                readRelayURLs: readRelayURLs,
                seedItems: seedItems,
                service: service
            )
        )
    }

    var body: some View {
        let _ = muteStore.filterRevision
        let _ = appSettings.spamFilterLabelSignature
        let visibleItems = viewModel.visibleItems
        let visibleReplyCounts = ReplyCountEstimator.counts(for: visibleItems)

        List {
            if viewModel.isLoading && visibleItems.isEmpty {
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
                }
            } else if visibleItems.isEmpty {
                VStack(spacing: 8) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No posts found for #\(viewModel.normalizedHashtag)")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .listRowInsets(
                    EdgeInsets(
                        top: 0,
                        leading: Self.feedHorizontalInset,
                        bottom: 0,
                        trailing: Self.feedHorizontalInset
                    )
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(visibleItems) { item in
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
                        onOptimisticPublished: { publishedItem in
                            animateFeedInsertion {
                                viewModel.insertOptimisticPublishedItem(publishedItem)
                            }
                        }
                    )
                    .transition(FlowTransitionMotion.feedItemInsertionTransition(reduceMotion: accessibilityReduceMotion))
                    .listRowInsets(
                        EdgeInsets(
                            top: 0,
                            leading: Self.feedHorizontalInset,
                            bottom: 0,
                            trailing: Self.feedHorizontalInset
                        )
                    )
                    .listRowSeparator(.visible)
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
        .animation(
            FlowTransitionMotion.feedInsertionAnimation(reduceMotion: accessibilityReduceMotion),
            value: visibleItems.map(\.id)
        )
        .navigationTitle("#\(viewModel.normalizedHashtag)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hashtagFavoritesStore.toggleFavorite(viewModel.normalizedHashtag)
                } label: {
                    Image(systemName: isCurrentHashtagFavorite ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .imageScale(.small)
                        .foregroundStyle(isCurrentHashtagFavorite ? Color.accentColor : Color.primary)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isCurrentHashtagFavorite
                        ? "Remove hashtag from favorites"
                        : "Add hashtag to favorites"
                )
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            hashtagFavoritesStore.configure(accountPubkey: auth.currentAccount?.pubkey)
            await viewModel.loadIfNeeded()
        }
        .onChange(of: auth.currentAccount?.pubkey) { _, newValue in
            hashtagFavoritesStore.configure(accountPubkey: newValue)
        }
        .navigationDestination(item: $selectedThreadItem) { item in
            ThreadDetailView(
                initialItem: item,
                relayURL: effectiveRelayURL,
                readRelayURLs: effectiveReadRelayURLs,
                initiallyFocusReplyComposer: shouldAutoFocusReplyInThread
            )
        }
        .navigationDestination(item: $selectedHashtagRoute) { route in
            HashtagFeedView(
                hashtag: route.normalizedHashtag,
                relayURL: effectiveRelayURL,
                readRelayURLs: effectiveReadRelayURLs,
                seedItems: route.seedItems
            )
        }
        .navigationDestination(item: $selectedProfileRoute) { route in
            ProfileView(
                pubkey: route.pubkey,
                relayURL: effectiveRelayURL,
                readRelayURLs: effectiveReadRelayURLs,
                writeRelayURLs: effectiveWriteRelayURLs
            )
        }
        .navigationDestination(item: $selectedRelayRoute) { route in
            RelayFeedView(relayURL: route.relayURL, title: route.displayName)
        }
    }

    private var loadingRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color(.secondarySystemFill))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.secondarySystemFill))
                    .frame(width: 150, height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.secondarySystemFill))
                    .frame(height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.secondarySystemFill))
                    .frame(width: 180, height: 14)
            }
        }
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }

    private func openHashtagFeed(hashtag: String) {
        let route = HashtagRoute(
            hashtag: hashtag,
            seedItems: matchingHashtagSeedItems(
                hashtag: hashtag,
                from: viewModel.visibleItems
            )
        )
        guard route.normalizedHashtag != viewModel.normalizedHashtag else { return }
        selectedHashtagRoute = route
    }

    private func openProfile(pubkey: String) {
        selectedProfileRoute = ProfileRoute(pubkey: pubkey)
    }

    private func openRelayFeed(relayURL: URL) {
        selectedRelayRoute = RelayRoute(relayURL: relayURL)
    }

    private var effectiveRelayURL: URL {
        if appSettings.slowConnectionMode {
            return AppSettingsStore.slowModeRelayURL
        }
        return viewModel.relayURL
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(from: relaySettings.writeRelayURLs, fallbackReadRelayURLs: [effectiveRelayURL])
    }

    private var isCurrentHashtagFavorite: Bool {
        hashtagFavoritesStore.isFavorite(viewModel.normalizedHashtag)
    }

    private func animateFeedInsertion(_ updates: () -> Void) {
        if let animation = FlowTransitionMotion.feedInsertionAnimation(reduceMotion: accessibilityReduceMotion) {
            withAnimation(animation) {
                updates()
            }
        } else {
            updates()
        }
    }
}

struct RelayFeedView: View {
    private static let feedHorizontalInset: CGFloat = 14
    private static let bottomScrollClearance: CGFloat = 110

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @StateObject private var viewModel: RelayFeedViewModel
    private let reactionStats = NoteReactionStatsService.shared
    @StateObject private var engagementViewport = FeedEngagementViewportCoordinator()
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var muteStore = MuteStore.shared
    @ObservedObject private var relayFavoritesStore = RelayFavoritesStore.shared
    @State private var selectedThreadItem: FeedItem?
    @State private var selectedHashtagRoute: HashtagRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var selectedRelayRoute: RelayRoute?
    @State private var shouldAutoFocusReplyInThread = false

    init(
        relayURL: URL,
        title: String? = nil,
        service: NostrFeedService = NostrFeedService()
    ) {
        _viewModel = StateObject(
            wrappedValue: RelayFeedViewModel(
                relayURL: relayURL,
                title: title,
                service: service
            )
        )
    }

    var body: some View {
        let _ = muteStore.filterRevision
        let _ = appSettings.spamFilterLabelSignature
        let visibleItems = viewModel.visibleItems
        let visibleReplyCounts = ReplyCountEstimator.counts(for: visibleItems)

        List {
            relayHeader
                .listRowInsets(
                    EdgeInsets(
                        top: 10,
                        leading: Self.feedHorizontalInset,
                        bottom: 8,
                        trailing: Self.feedHorizontalInset
                    )
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if viewModel.isLoading && visibleItems.isEmpty {
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
            } else if visibleItems.isEmpty {
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
            } else {
                ForEach(visibleItems) { item in
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
                        onOptimisticPublished: { publishedItem in
                            animateFeedInsertion {
                                viewModel.insertOptimisticPublishedItem(publishedItem)
                            }
                        }
                    )
                    .transition(FlowTransitionMotion.feedItemInsertionTransition(reduceMotion: accessibilityReduceMotion))
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
        .background(appSettings.themePalette.background)
        .animation(
            FlowTransitionMotion.feedInsertionAnimation(reduceMotion: accessibilityReduceMotion),
            value: visibleItems.map(\.id)
        )
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    relayFavoritesStore.toggleFavorite(viewModel.relayURL)
                } label: {
                    Image(systemName: isCurrentRelayFavorite ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .imageScale(.small)
                        .foregroundStyle(isCurrentRelayFavorite ? Color.accentColor : Color.primary)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isCurrentRelayFavorite
                        ? "Remove relay from Feed Sources"
                        : "Add relay to Feed Sources"
                )
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            relayFavoritesStore.configure(accountPubkey: auth.currentAccount?.pubkey)
            await viewModel.loadIfNeeded()
        }
        .onChange(of: auth.currentAccount?.pubkey) { _, newValue in
            relayFavoritesStore.configure(accountPubkey: newValue)
        }
        .navigationDestination(item: $selectedThreadItem) { item in
            ThreadDetailView(
                initialItem: item,
                relayURL: viewModel.relayURL,
                readRelayURLs: effectiveReadRelayURLs,
                initiallyFocusReplyComposer: shouldAutoFocusReplyInThread
            )
        }
        .navigationDestination(item: $selectedHashtagRoute) { route in
            HashtagFeedView(
                hashtag: route.normalizedHashtag,
                relayURL: viewModel.relayURL,
                readRelayURLs: effectiveReadRelayURLs,
                seedItems: route.seedItems
            )
        }
        .navigationDestination(item: $selectedProfileRoute) { route in
            ProfileView(
                pubkey: route.pubkey,
                relayURL: viewModel.relayURL,
                readRelayURLs: effectiveReadRelayURLs,
                writeRelayURLs: effectiveWriteRelayURLs
            )
        }
        .navigationDestination(item: $selectedRelayRoute) { route in
            RelayFeedView(relayURL: route.relayURL, title: route.displayName)
        }
    }

    private var relayHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.title)
                .font(appSettings.appFont(.title2, weight: .bold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.relayHostLabel)
                .font(appSettings.appFont(.footnote))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(appSettings.appFont(.body))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else {
                Text("No posts found on \(viewModel.relayHostLabel)")
                    .font(appSettings.appFont(.body))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var loadingRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 150, height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 180, height: 14)
            }
        }
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }

    private func openHashtagFeed(hashtag: String) {
        selectedHashtagRoute = HashtagRoute(
            hashtag: hashtag,
            seedItems: matchingHashtagSeedItems(
                hashtag: hashtag,
                from: viewModel.visibleItems
            )
        )
    }

    private func openProfile(pubkey: String) {
        selectedProfileRoute = ProfileRoute(pubkey: pubkey)
    }

    private func openRelayFeed(relayURL: URL) {
        guard let route = RelayRoute(relayURL: relayURL),
              route.id != viewModel.routeID else {
            return
        }
        selectedRelayRoute = route
    }

    private var effectiveReadRelayURLs: [URL] {
        RelayURLSupport.normalizedRelayURLs(
            [viewModel.relayURL] + appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
        )
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: effectiveReadRelayURLs
        )
    }

    private var isCurrentRelayFavorite: Bool {
        relayFavoritesStore.isFavorite(viewModel.relayURL)
    }

    private func animateFeedInsertion(_ updates: () -> Void) {
        if let animation = FlowTransitionMotion.feedInsertionAnimation(reduceMotion: accessibilityReduceMotion) {
            withAnimation(animation) {
                updates()
            }
        } else {
            updates()
        }
    }
}
