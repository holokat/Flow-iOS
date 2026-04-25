import SwiftUI
import UIKit

struct HomeFeedView: View {
    private static let feedTopAnchorID = "home-feed-top-anchor"
    private static let feedScrollCoordinateSpace = "home-feed-scroll"
    private static let feedHorizontalInset: CGFloat = 14
    private static let autoMergeTopThreshold: CGFloat = 56

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @ObservedObject var viewModel: HomeFeedViewModel
    @Binding var isShowingSideMenu: Bool
    private let reactionStats = NoteReactionStatsService.shared
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var muteStore = MuteStore.shared
    @ObservedObject private var interestFeedStore = InterestFeedStore.shared
    @ObservedObject private var hashtagFavoritesStore = HashtagFavoritesStore.shared
    @ObservedObject private var relayFavoritesStore = RelayFavoritesStore.shared

    @State private var isShowingAuthSheet = false
    @State private var authSheetInitialTab: AuthSheetTab = .signIn
    @State private var isShowingFeedSourcePicker = false
    @State private var isShowingFilterSheet = false
    @State private var isShowingSettings = false
    @StateObject private var settingsSheetState = SettingsSheetState()

    @State private var selectedThreadItem: FeedItem?
    @State private var selectedHashtagRoute: HashtagRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var selectedRelayRoute: RelayRoute?
    @State private var topNavAvatarURL: URL?
    @State private var topNavAvatarImage: UIImage?
    @State private var shouldAutoFocusReplyInThread = false
    @State private var isNearFeedTop = true

    var body: some View {
        let _ = muteStore.filterRevision
        let _ = appSettings.spamFilterLabelSignature

        AnyView(navigationRoot)
            .modifier(sheetsModifier)
            .modifier(lifecycleModifier)
    }

    private var sheetsModifier: HomeFeedSheets {
        HomeFeedSheets(
            isShowingAuthSheet: $isShowingAuthSheet,
            isShowingFeedSourcePicker: $isShowingFeedSourcePicker,
            isShowingFilterSheet: $isShowingFilterSheet,
            isShowingSettings: $isShowingSettings,
            onSettingsDismiss: {
                settingsSheetState.reset()
            },
            authSheet: {
                AnyView(authSheet)
            },
            feedSourcePickerSheet: {
                AnyView(feedSourcePickerSheet)
            },
            filterSheet: {
                AnyView(filterSheet)
            },
            settingsSheet: {
                AnyView(settingsSheet)
            }
        )
    }

    private var navigationDestinationsModifier: HomeFeedNavigationDestinations {
        HomeFeedNavigationDestinations(
            selectedThreadItem: $selectedThreadItem,
            selectedHashtagRoute: $selectedHashtagRoute,
            selectedProfileRoute: $selectedProfileRoute,
            selectedRelayRoute: $selectedRelayRoute,
            primaryRelayURL: effectivePrimaryRelayURL,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs,
            shouldAutoFocusReplyInThread: shouldAutoFocusReplyInThread
        )
    }

    private var lifecycleModifier: HomeFeedLifecycleHandlers {
        HomeFeedLifecycleHandlers(
            authPubkey: auth.currentAccount?.pubkey,
            authPrivateKey: auth.currentNsec,
            readRelays: relaySettings.readRelays,
            writeRelays: relaySettings.writeRelays,
            slowConnectionMode: appSettings.slowConnectionMode,
            newsRelayURLs: appSettings.newsRelayURLs,
            newsAuthorPubkeys: appSettings.newsAuthorPubkeys,
            newsHashtags: appSettings.newsHashtags,
            pollsFeedVisible: appSettings.pollsFeedVisible,
            followedPubkeys: followStore.followedPubkeys,
            interestHashtags: interestFeedStore.hashtags,
            favoriteHashtags: hashtagFavoritesStore.favoriteHashtags,
            favoriteRelayURLs: relayFavoritesStore.favoriteRelayURLs,
            customFeeds: appSettings.customFeeds,
            topNavAvatarLookupID: topNavAvatarLookupID,
            onAuthPubkeyChange: handleAccountPubkeyChange,
            onAuthPrivateKeyChange: handleAuthPrivateKeyChange,
            onReadRelaysChange: handleReadRelaysChange,
            onWriteRelaysChange: {
                configureFollowAndMuteStores()
            },
            onSlowConnectionModeChange: handleSlowConnectionModeChange,
            onNewsFeedSettingChange: refreshNewsFeedIfNeeded,
            onPollsFeedVisibleChange: viewModel.updatePollsFeedVisibility,
            onFollowedPubkeysChange: refreshFollowingOrPollsFeedIfNeeded,
            onInterestHashtagsChange: viewModel.updateInterestHashtags,
            onFavoriteHashtagsChange: viewModel.updateFavoriteHashtags,
            onFavoriteRelaysChange: viewModel.updateFavoriteRelays,
            onCustomFeedsChange: viewModel.updateCustomFeeds,
            onRefreshTopNavAvatar: refreshTopNavAvatar,
            onProfileMetadataUpdated: handleProfileMetadataUpdated
        )
    }

    private func handleAccountPubkeyChange(_ pubkey: String?) {
        appSettings.configure(accountPubkey: pubkey)
        relaySettings.configure(
            accountPubkey: pubkey,
            nsec: auth.currentNsec
        )
        viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
        interestFeedStore.configure(accountPubkey: pubkey)
        viewModel.updateInterestHashtags(interestFeedStore.hashtags)
        hashtagFavoritesStore.configure(accountPubkey: pubkey)
        viewModel.updateFavoriteHashtags(hashtagFavoritesStore.favoriteHashtags)
        relayFavoritesStore.configure(accountPubkey: pubkey)
        viewModel.updateFavoriteRelays(relayFavoritesStore.favoriteRelayURLs)
        viewModel.updatePollsFeedVisibility(appSettings.pollsFeedVisible)
        viewModel.updateCustomFeeds(appSettings.customFeeds)
        configureFollowAndMuteStores(accountPubkey: pubkey, nsec: auth.currentNsec)
        viewModel.updateCurrentUserPubkey(pubkey)
    }

    private func handleAuthPrivateKeyChange(_ nsec: String?) {
        relaySettings.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: nsec
        )
        configureFollowAndMuteStores(accountPubkey: auth.currentAccount?.pubkey, nsec: nsec)
    }

    private func handleReadRelaysChange() {
        viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
        configureFollowAndMuteStores()
    }

    private func handleSlowConnectionModeChange() {
        viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
        configureFollowAndMuteStores()
        refreshFeedSilently()
    }

    private func configureFollowAndMuteStores(
        accountPubkey: String? = nil,
        nsec: String? = nil
    ) {
        let pubkey = accountPubkey ?? auth.currentAccount?.pubkey
        let privateKey = nsec ?? auth.currentNsec
        followStore.configure(
            accountPubkey: pubkey,
            nsec: privateKey,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
        MuteStore.shared.configure(
            accountPubkey: pubkey,
            nsec: privateKey,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
    }

    private func refreshNewsFeedIfNeeded() {
        guard viewModel.feedSource == .news else { return }
        refreshFeedSilently()
    }

    private func refreshFollowingOrPollsFeedIfNeeded() {
        guard viewModel.feedSource == .following || viewModel.feedSource == .polls else { return }
        refreshFeedSilently()
    }

    private func refreshFeedSilently() {
        Task {
            await viewModel.refresh(silent: true)
        }
    }

    private func handleProfileMetadataUpdated(_ notification: Notification) {
        guard let updatedPubkey = (notification.userInfo?["pubkey"] as? String)?.lowercased(),
              let currentPubkey = auth.currentAccount?.pubkey.lowercased(),
              updatedPubkey == currentPubkey else {
            return
        }
        Task {
            await refreshTopNavAvatar()
        }
    }

    private var navigationRoot: some View {
        NavigationStack {
            HomeFeedRootContent(
                isShowingSideMenu: $isShowingSideMenu,
                topNavigationBar: { AnyView(topNavigationBar) },
                feedContent: { AnyView(feedContent) },
                sideMenuOverlay: { AnyView(sideMenuOverlay) }
            )
            .modifier(navigationDestinationsModifier)
        }
    }

    private var feedContent: some View {
        let visibleItems = viewModel.visibleItems
        let visibleReplyCounts = ReplyCountEstimator.counts(for: visibleItems)

        return ScrollViewReader { scrollProxy in
            feedList(
                scrollProxy: scrollProxy,
                visibleItems: visibleItems,
                visibleReplyCounts: visibleReplyCounts
            )
        }
    }

    private func feedList(
        scrollProxy: ScrollViewProxy,
        visibleItems: [FeedItem],
        visibleReplyCounts: [String: Int]
    ) -> some View {
        List {
            feedModeHeaderRow
            feedRows(visibleItems, visibleReplyCounts: visibleReplyCounts)
            loadingMoreRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .coordinateSpace(name: Self.feedScrollCoordinateSpace)
        .overlay(alignment: .top) {
            newNotesOverlay(scrollProxy: scrollProxy)
        }
        .onPreferenceChange(HomeFeedTopOffsetPreferenceKey.self) { newValue in
            let nearTop = newValue >= -Self.autoMergeTopThreshold
            guard isNearFeedTop != nearTop else { return }
            isNearFeedTop = nearTop
            if nearTop {
                autoShowBufferedItemsIfNeeded()
            }
        }
        .onChange(of: viewModel.visibleBufferedNewItemsCount) { _, _ in
            autoShowBufferedItemsIfNeeded()
        }
        .refreshable {
            await refreshFeed(scrollProxy: scrollProxy)
        }
        .task {
            await configureFeedDependenciesAndLoad()
        }
    }

    private var feedModeHeaderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.feedSource != .polls {
                FlowCapsuleTabBar(
                    selection: $viewModel.mode,
                    items: HomeFeedMode.allCases,
                    selectedBackground: topNavigationControlFill,
                    title: { $0.title }
                )

                if viewModel.mediaOnly {
                    Label("Media-only filter enabled", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }
            } else {
                Label("Polls from people you follow", systemImage: "chart.bar.xaxis")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
        .padding(.vertical, 0)
        .listRowInsets(feedListRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .id(Self.feedTopAnchorID)
        .background(feedTopOffsetReader)
    }

    @ViewBuilder
    private func feedRows(
        _ visibleItems: [FeedItem],
        visibleReplyCounts: [String: Int]
    ) -> some View {
        if viewModel.isShowingLoadingPlaceholder {
            ForEach(0..<6, id: \.self) { _ in
                loadingRow
                    .listRowInsets(feedListRowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } else if visibleItems.isEmpty {
            emptyOrFilteredFeedRow
        } else {
            ForEach(visibleItems) { item in
                feedRow(item, visibleReplyCounts: visibleReplyCounts)
            }
        }
    }

    @ViewBuilder
    private var emptyOrFilteredFeedRow: some View {
        if viewModel.shouldShowFilteredOutState {
            filteredOutState
                .listRowInsets(feedListRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            emptyState
                .listRowInsets(feedListRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var loadingMoreRow: some View {
        if viewModel.isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 8)
            .listRowInsets(feedListRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func newNotesOverlay(scrollProxy: ScrollViewProxy) -> some View {
        if viewModel.visibleBufferedNewItemsCount > 0, !isNearFeedTop, !isShowingSideMenu {
            newNotesPill {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showBufferedNewItems()
                    scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)
                }
            }
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var feedListRowInsets: EdgeInsets {
        EdgeInsets(
            top: 0,
            leading: Self.feedHorizontalInset,
            bottom: 0,
            trailing: Self.feedHorizontalInset
        )
    }

    private func refreshFeed(scrollProxy: ScrollViewProxy) async {
        if viewModel.visibleBufferedNewItemsCount > 0 {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.showBufferedNewItems()
                scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)
            }
        } else {
            await viewModel.refresh()
        }
    }

    private func configureFeedDependenciesAndLoad() async {
        appSettings.configure(accountPubkey: auth.currentAccount?.pubkey)
        relaySettings.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec
        )
        viewModel.updateReadRelayURLs(effectiveReadRelayURLs)
        interestFeedStore.configure(accountPubkey: auth.currentAccount?.pubkey)
        viewModel.updateInterestHashtags(interestFeedStore.hashtags)
        hashtagFavoritesStore.configure(accountPubkey: auth.currentAccount?.pubkey)
        viewModel.updateFavoriteHashtags(hashtagFavoritesStore.favoriteHashtags)
        relayFavoritesStore.configure(accountPubkey: auth.currentAccount?.pubkey)
        viewModel.updateFavoriteRelays(relayFavoritesStore.favoriteRelayURLs)
        viewModel.updatePollsFeedVisibility(appSettings.pollsFeedVisible)
        viewModel.updateCustomFeeds(appSettings.customFeeds)
        viewModel.updateCurrentUserPubkey(auth.currentAccount?.pubkey)
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
        await viewModel.loadIfNeeded()
    }

    private var topNavigationBar: some View {
        HStack(spacing: 12) {
            Button {
                isShowingSideMenu = true
            } label: {
                topNavAccountIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open menu")

            Spacer()

            Button {
                isShowingFeedSourcePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: feedSourceIconName(for: viewModel.feedSource))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appSettings.primaryColor)
                    Text(feedSourceLabel(for: viewModel.feedSource))
                        .font(appSettings.appFont(.headline, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(topNavigationControlFill)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose feed source")

            Spacer()

            filterButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(topNavigationBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(appSettings.themePalette.chromeBorder)
                .frame(height: 0.7)
        }
    }

    @ViewBuilder
    private var topNavigationBackground: some View {
        if appSettings.activeTheme == .sakura {
            ZStack {
                appSettings.themePalette.chromeBackground

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.78),
                        Color(red: 1.0, green: 0.960, blue: 0.978).opacity(0.66)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else if appSettings.activeTheme == .gamer {
            appSettings.themePalette.background
        } else if appSettings.activeTheme == .dracula {
            appSettings.themePalette.chromeBackground
        } else {
            appSettings.themePalette.chromeBackground
        }
    }

    private var topNavigationControlFill: Color {
        if appSettings.activeTheme == .sakura {
            return Color.white.opacity(0.88)
        } else if appSettings.activeTheme == .gamer {
            return appSettings.themePalette.chromeBackground.opacity(0.88)
        }
        return appSettings.themePalette.secondaryBackground
    }

    private var feedSourcePickerBackground: Color {
        appSettings.themePalette.sheetBackground
    }

    private var feedSourcePickerSurfaceStyle: SettingsFormSurfaceStyle {
        let effectiveColorScheme = appSettings.preferredColorScheme ?? colorScheme
        return appSettings.settingsFormSurfaceStyle(for: effectiveColorScheme)
    }

    private var sideMenuOverlay: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeSideMenu()
                    }

                HomeSlideoutMenuView(
                    onViewProfile: {
                        if let pubkey = auth.currentAccount?.pubkey {
                            openProfile(pubkey: pubkey)
                        }
                        closeSideMenu()
                    },
                    onOpenScannedProfile: { pubkey in
                        closeSideMenu()
                        openProfile(pubkey: pubkey)
                    },
                    onManageSettings: {
                        closeSideMenu()
                        isShowingSettings = true
                    },
                    onManageAccounts: {
                        closeSideMenu()
                        openAuthSheet(tab: .accounts)
                    },
                    onLogout: {
                        auth.logout()
                        closeSideMenu()
                    },
                    onClose: {
                        closeSideMenu()
                    }
                )
                .environmentObject(auth)
                .frame(width: min(320, geometry.size.width * 0.82))
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .leading))
            }
        }
    }

    private var filterButton: some View {
        Group {
            if viewModel.feedSource == .polls {
                Color.clear
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
            } else {
                Button {
                    isShowingFilterSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(appSettings.themePalette.mutedForeground)
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Feed filters")
                .accessibilityAddTraits(viewModel.isUsingCustomFilters ? [.isSelected] : [])
            }
        }
    }

    private var filterGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 120), spacing: 10),
            GridItem(.flexible(minimum: 120), spacing: 10)
        ]
    }

    private var filterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    kindsFilterSection
                    contentFilterSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 44)
            }
            .navigationTitle("Feed Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ThemedToolbarDoneButton {
                        isShowingFilterSheet = false
                    }
                }
            }
            .background(appSettings.themePalette.sheetBackground)
            .toolbarBackground(appSettings.themePalette.sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.fraction(0.7), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.sheetBackground)
    }

    private var kindsFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: filterGridColumns, spacing: 10) {
                ForEach(viewModel.kindFilterOptions) { option in
                    FilterKindTileView(
                        title: option.title,
                        iconName: filterIconName(for: option),
                        isSelected: viewModel.isKindGroupEnabled(option),
                        action: {
                            viewModel.toggleKindGroup(option)
                        }
                    )
                }
            }

            Button {
                viewModel.selectAllKinds()
            } label: {
                Label("Select All", systemImage: "line.3.horizontal.decrease.circle")
                    .font(appSettings.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        appSettings.themePalette.navigationControlBackground,
                        in: Capsule(style: .continuous)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var contentFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content")
                .font(.headline)

            let mediaOnlyEnabled = viewModel.mediaOnly
            Button {
                viewModel.setMediaOnly(!mediaOnlyEnabled)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: mediaOnlyEnabled ? "photo.on.rectangle.angled" : "rectangle")
                    Text("Only notes with media")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if mediaOnlyEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(appSettings.primaryColor)
                    }
                }
                .foregroundStyle(appSettings.themePalette.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            mediaOnlyEnabled
                                ? appSettings.primaryColor.opacity(0.14)
                                : appSettings.themePalette.secondaryBackground
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func filterIconName(for option: FeedKindFilterOption) -> String {
        switch option.id {
        case "posts":
            return "text.bubble"
        case "reposts":
            return "arrow.triangle.2.circlepath"
        case "articles":
            return "doc.text"
        case "polls":
            return "chart.bar.xaxis"
        case "voice":
            return "waveform"
        case "photos":
            return "photo"
        case "videos":
            return "video"
        default:
            return "line.3.horizontal.decrease.circle"
        }
    }

    private var filteredOutState: some View {
        VStack(spacing: 10) {
            Text(viewModel.filteredOutMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            if viewModel.mediaOnlyFilteredOutAll {
                Button("Show posts without media") {
                    viewModel.disableMediaOnlyFilter()
                }
                .font(appSettings.appFont(.footnote, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    appSettings.themePalette.navigationControlBackground,
                    in: Capsule(style: .continuous)
                )
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else if viewModel.interestsFeedHasNoHashtags {
                Text("No interests selected yet")
                    .font(.headline)
                Text("Add topic hashtags in Core > Feeds > Interests.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else if viewModel.followingFeedHasNoFollowings {
                Text("No followed accounts yet")
                    .font(.headline)
                Text("Follow people or switch to Network from the feed selector.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else if viewModel.feedSource == .polls {
                Text("No polls yet")
                    .font(.headline)
                Text("Follow people who post polls or pull down to refresh.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else {
                Text("No posts yet")
                    .font(.headline)
                Text("Pull down to refresh and try these relays again.")
                    .font(.subheadline)
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

    private func feedRow(_ item: FeedItem, visibleReplyCounts: [String: Int]) -> some View {
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
                viewModel.insertOptimisticPublishedItem(publishedItem)
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
                reactionStats.prefetch(events: [item.displayEvent], relayURLs: effectiveReadRelayURLs)
            }
            Task(priority: .utility) {
                await viewModel.loadMoreIfNeeded(currentItem: item)
            }
        }
    }

    private func openAuthSheet(tab: AuthSheetTab) {
        authSheetInitialTab = tab
        isShowingAuthSheet = true
    }

    private func closeSideMenu() {
        isShowingSideMenu = false
    }

    private var authSheet: some View {
        AuthSheetView(
            initialTab: authSheetInitialTab,
            onSelectedTabChange: { authSheetInitialTab = $0 }
        )
        .environmentObject(auth)
        .environmentObject(appSettings)
        .environmentObject(relaySettings)
    }

    private var settingsSheet: some View {
        SettingsView(sheetState: settingsSheetState)
            .environmentObject(relaySettings)
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
        selectedRelayRoute = RelayRoute(relayURL: relayURL)
    }

    private func feedSourceLabel(for source: HomePrimaryFeedSource) -> String {
        switch source {
        case .network:
            return "Network"
        case .following:
            return "Following"
        case .polls:
            return "Polls"
        case .trending:
            return "Trending"
        case .interests:
            return "Interests"
        case .news:
            return "News"
        case .custom(let feedID):
            return viewModel.customFeedDefinition(id: feedID)?.name ?? "Custom Feed"
        case .hashtag(let hashtag):
            return "#\(HomePrimaryFeedSource.normalizeHashtag(hashtag))"
        case .relay(let relayURL):
            guard let url = RelayURLSupport.normalizedURL(from: relayURL) else { return "Relay" }
            return RelayURLSupport.displayName(for: url)
        }
    }

    private func feedSourceIconName(for source: HomePrimaryFeedSource) -> String {
        switch source {
        case .network:
            return "dot.radiowaves.left.and.right"
        case .following:
            return "person.2"
        case .polls:
            return "chart.bar.xaxis"
        case .trending:
            return "chart.line.uptrend.xyaxis"
        case .interests:
            return "sparkles"
        case .news:
            return "newspaper"
        case .custom(let feedID):
            return viewModel.customFeedDefinition(id: feedID)?.iconSystemName ?? CustomFeedIconCatalog.defaultIcon
        case .hashtag:
            return "number"
        case .relay:
            return "server.rack"
        }
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

    private var topNavAccountIcon: some View {
        Group {
            if appSettings.textOnlyMode {
                topNavAccountFallback
            } else if let topNavAvatarImage {
                Image(uiImage: topNavAvatarImage)
                    .resizable()
                    .scaledToFill()
            } else {
                topNavAccountFallback
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(appSettings.themePalette.separator.opacity(0.35), lineWidth: 0.7)
        }
    }

    private var topNavAccountFallback: some View {
        ZStack {
            Circle()
                .fill(appSettings.avatarFallbackGradient(forAccountPubkey: auth.currentAccount?.pubkey))
            Image(systemName: "person.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(appSettings.avatarFallbackForeground(forAccountPubkey: auth.currentAccount?.pubkey))
        }
    }

    @MainActor
    private var topNavAvatarLookupID: String {
        let accountID = auth.currentAccount?.id ?? "none"
        let relaySignature = effectiveReadRelayURLs
            .map { $0.absoluteString.lowercased() }
            .joined(separator: ",")
        return "\(accountID)|\(relaySignature)"
    }

    @MainActor
    private func refreshTopNavAvatar() async {
        guard let account = auth.currentAccount else {
            topNavAvatarURL = nil
            topNavAvatarImage = nil
            return
        }

        let normalizedPubkey = account.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheResult = await ProfileCache.shared.resolve(pubkeys: [account.pubkey, normalizedPubkey])
        if let cachedProfile = cacheResult.hits[account.pubkey] ?? cacheResult.hits[normalizedPubkey],
           let cachedAvatarURL = preferredAvatarURL(from: cachedProfile) {
            await loadTopNavAvatarImage(from: cachedAvatarURL)
            return
        }

        let fetchedProfile = await NostrFeedService().fetchProfile(
            relayURLs: effectiveReadRelayURLs,
            pubkey: normalizedPubkey
        )
        if let avatarURL = fetchedProfile.flatMap(preferredAvatarURL(from:)) {
            await loadTopNavAvatarImage(from: avatarURL)
        } else {
            topNavAvatarURL = nil
            topNavAvatarImage = nil
        }
    }

    private func preferredAvatarURL(from profile: NostrProfile) -> URL? {
        profile.resolvedAvatarURL
    }

    @MainActor
    private func loadTopNavAvatarImage(from url: URL) async {
        if topNavAvatarURL == url, topNavAvatarImage != nil {
            return
        }

        let previousURL = topNavAvatarURL
        topNavAvatarURL = url

        if let image = await FlowImageCache.shared.profileImage(for: url) {
            guard topNavAvatarURL == url else { return }
            topNavAvatarImage = image
        } else if previousURL != url {
            topNavAvatarImage = nil
        }
    }

    private func newNotesPill(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                newNotesAvatarStack

                Text(newNotesPillLabel)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(appSettings.themePalette.foreground)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(appSettings.themePalette.separator.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .shadow(color: Color.black.opacity(0.09), radius: 6, y: 2)
        .accessibilityLabel("Show latest notes")
    }

    private var newNotesAvatarStack: some View {
        let authors = recentBufferedAuthors

        return HStack(spacing: -10) {
            ForEach(Array(authors.enumerated()), id: \.element.id) { index, item in
                AvatarView(url: item.avatarURL, fallback: item.displayName, size: 24)
                    .padding(2)
                    .background(Circle().fill(appSettings.themePalette.chromeBackground))
                    .overlay {
                        Circle()
                            .stroke(appSettings.themePalette.chromeBackground, lineWidth: 1.2)
                    }
                    .zIndex(Double(authors.count - index))
            }
        }
        .padding(.trailing, authors.count > 1 ? 4 : 0)
    }

    private var newNotesPillLabel: String {
        let count = viewModel.visibleBufferedNewItemsCount
        return count == 1 ? "1 note" : "\(count) notes"
    }

    private var recentBufferedAuthors: [FeedItem] {
        var seenAuthors = Set<String>()
        var authors: [FeedItem] = []

        for item in viewModel.visibleBufferedNewItems {
            let authorKey = item.displayAuthorPubkey.lowercased()
            guard seenAuthors.insert(authorKey).inserted else { continue }
            authors.append(item)
            if authors.count == 3 {
                break
            }
        }

        return authors
    }

    private var feedTopOffsetReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: HomeFeedTopOffsetPreferenceKey.self,
                    value: proxy.frame(in: .named(Self.feedScrollCoordinateSpace)).minY
                )
        }
    }

    private func autoShowBufferedItemsIfNeeded() {
        guard isNearFeedTop else { return }
        guard viewModel.visibleBufferedNewItemsCount > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.showBufferedNewItems()
        }
    }

    private var feedSourcePickerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.feedSourceOptions.enumerated()), id: \.element.id) { index, source in
                        feedSourceOptionButton(source)

                        if index < viewModel.feedSourceOptions.count - 1 {
                            Divider()
                                .overlay(appSettings.themeSeparator(defaultOpacity: 0.18))
                                .padding(.leading, 44)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(feedSourcePickerSurfaceStyle.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(appSettings.themeSeparator(defaultOpacity: 0.18), lineWidth: 0.8)
                )
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 44)
            }
            .background(feedSourcePickerBackground)
            .navigationTitle("Feed Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ThemedToolbarDoneButton {
                        isShowingFeedSourcePicker = false
                    }
                }
            }
            .toolbarBackground(feedSourcePickerBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(feedSourcePickerBackground)
    }

    private func feedSourceOptionButton(_ source: HomePrimaryFeedSource) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                viewModel.selectFeedSource(source)
                isShowingFeedSourcePicker = false
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: feedSourceIconName(for: source))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appSettings.primaryColor)
                        .frame(width: 22, alignment: .center)

                    Text(feedSourceLabel(for: source))
                        .font(appSettings.appFont(.body, weight: .medium))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(1)

                    Spacer()

                    if viewModel.feedSource == source {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(appSettings.primaryColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)

            if isRemovableFeedSource(source) {
                Button {
                    removeFeedSourceFavorite(source)
                } label: {
                    Image(systemName: "bookmark.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(removeFeedSourceAccessibilityLabel(for: source))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func isRemovableFeedSource(_ source: HomePrimaryFeedSource) -> Bool {
        switch source {
        case .hashtag, .relay:
            return true
        default:
            return false
        }
    }

    private func removeFeedSourceFavorite(_ source: HomePrimaryFeedSource) {
        switch source {
        case .hashtag(let hashtag):
            if hashtagFavoritesStore.isFavorite(hashtag) {
                hashtagFavoritesStore.toggleFavorite(hashtag)
            }
        case .relay(let relayURL):
            if relayFavoritesStore.isFavorite(relayURL) {
                relayFavoritesStore.toggleFavorite(relayURL)
            }
        default:
            break
        }
    }

    private func removeFeedSourceAccessibilityLabel(for source: HomePrimaryFeedSource) -> String {
        switch source {
        case .hashtag(let hashtag):
            return "Remove #\(HomePrimaryFeedSource.normalizeHashtag(hashtag)) from Feed Sources"
        case .relay:
            return "Remove \(feedSourceLabel(for: source)) from Feed Sources"
        default:
            return "Remove from Feed Sources"
        }
    }
}

private struct HomeFeedRootContent: View {
    @Binding var isShowingSideMenu: Bool

    let topNavigationBar: () -> AnyView
    let feedContent: () -> AnyView
    let sideMenuOverlay: () -> AnyView

    var body: some View {
        ZStack(alignment: .leading) {
            AppThemeBackgroundView(holographicSpotlight: .feed)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topNavigationBar()
                feedContent()
            }
            .disabled(isShowingSideMenu)

            if isShowingSideMenu {
                sideMenuOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingSideMenu)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct HomeFeedLifecycleHandlers: ViewModifier {
    let authPubkey: String?
    let authPrivateKey: String?
    let readRelays: [String]
    let writeRelays: [String]
    let slowConnectionMode: Bool
    let newsRelayURLs: [URL]
    let newsAuthorPubkeys: [String]
    let newsHashtags: [String]
    let pollsFeedVisible: Bool
    let followedPubkeys: Set<String>
    let interestHashtags: [String]
    let favoriteHashtags: [String]
    let favoriteRelayURLs: [String]
    let customFeeds: [CustomFeedDefinition]
    let topNavAvatarLookupID: String

    let onAuthPubkeyChange: (String?) -> Void
    let onAuthPrivateKeyChange: (String?) -> Void
    let onReadRelaysChange: () -> Void
    let onWriteRelaysChange: () -> Void
    let onSlowConnectionModeChange: () -> Void
    let onNewsFeedSettingChange: () -> Void
    let onPollsFeedVisibleChange: (Bool) -> Void
    let onFollowedPubkeysChange: () -> Void
    let onInterestHashtagsChange: ([String]) -> Void
    let onFavoriteHashtagsChange: ([String]) -> Void
    let onFavoriteRelaysChange: ([String]) -> Void
    let onCustomFeedsChange: ([CustomFeedDefinition]) -> Void
    let onRefreshTopNavAvatar: () async -> Void
    let onProfileMetadataUpdated: (Notification) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: authPubkey) { _, newValue in
                onAuthPubkeyChange(newValue)
            }
            .onChange(of: authPrivateKey) { _, newValue in
                onAuthPrivateKeyChange(newValue)
            }
            .onChange(of: readRelays) { _, _ in
                onReadRelaysChange()
            }
            .onChange(of: writeRelays) { _, _ in
                onWriteRelaysChange()
            }
            .onChange(of: slowConnectionMode) { _, _ in
                onSlowConnectionModeChange()
            }
            .onChange(of: newsRelayURLs) { _, _ in
                onNewsFeedSettingChange()
            }
            .onChange(of: newsAuthorPubkeys) { _, _ in
                onNewsFeedSettingChange()
            }
            .onChange(of: newsHashtags) { _, _ in
                onNewsFeedSettingChange()
            }
            .onChange(of: pollsFeedVisible) { _, newValue in
                onPollsFeedVisibleChange(newValue)
            }
            .onChange(of: followedPubkeys) { _, _ in
                onFollowedPubkeysChange()
            }
            .onChange(of: interestHashtags) { _, newValue in
                onInterestHashtagsChange(newValue)
            }
            .onChange(of: favoriteHashtags) { _, newValue in
                onFavoriteHashtagsChange(newValue)
            }
            .onChange(of: favoriteRelayURLs) { _, newValue in
                onFavoriteRelaysChange(newValue)
            }
            .onChange(of: customFeeds) { _, newValue in
                onCustomFeedsChange(newValue)
            }
            .task(id: topNavAvatarLookupID) {
                await onRefreshTopNavAvatar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .profileMetadataUpdated)) { notification in
                onProfileMetadataUpdated(notification)
            }
    }
}

private struct HomeFeedNavigationDestinations: ViewModifier {
    @Binding var selectedThreadItem: FeedItem?
    @Binding var selectedHashtagRoute: HashtagRoute?
    @Binding var selectedProfileRoute: ProfileRoute?
    @Binding var selectedRelayRoute: RelayRoute?

    let primaryRelayURL: URL
    let readRelayURLs: [URL]
    let writeRelayURLs: [URL]
    let shouldAutoFocusReplyInThread: Bool

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $selectedThreadItem) { item in
                ThreadDetailView(
                    initialItem: item,
                    relayURL: primaryRelayURL,
                    readRelayURLs: readRelayURLs,
                    initiallyFocusReplyComposer: shouldAutoFocusReplyInThread
                )
            }
            .navigationDestination(item: $selectedHashtagRoute) { route in
                HashtagFeedView(
                    hashtag: route.normalizedHashtag,
                    relayURL: primaryRelayURL,
                    readRelayURLs: readRelayURLs,
                    seedItems: route.seedItems
                )
            }
            .navigationDestination(item: $selectedProfileRoute) { route in
                ProfileView(
                    pubkey: route.pubkey,
                    relayURL: primaryRelayURL,
                    readRelayURLs: readRelayURLs,
                    writeRelayURLs: writeRelayURLs
                )
            }
            .navigationDestination(item: $selectedRelayRoute) { route in
                RelayFeedView(relayURL: route.relayURL, title: route.displayName)
            }
    }
}

private struct HomeFeedSheets: ViewModifier {
    @Binding var isShowingAuthSheet: Bool
    @Binding var isShowingFeedSourcePicker: Bool
    @Binding var isShowingFilterSheet: Bool
    @Binding var isShowingSettings: Bool

    let onSettingsDismiss: () -> Void
    let authSheet: () -> AnyView
    let feedSourcePickerSheet: () -> AnyView
    let filterSheet: () -> AnyView
    let settingsSheet: () -> AnyView

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingAuthSheet) {
                authSheet()
            }
            .sheet(isPresented: $isShowingFeedSourcePicker) {
                feedSourcePickerSheet()
            }
            .sheet(isPresented: $isShowingFilterSheet) {
                filterSheet()
            }
            .sheet(isPresented: $isShowingSettings, onDismiss: onSettingsDismiss) {
                settingsSheet()
            }
    }
}

private struct HomeFeedTopOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FilterKindTileView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    let iconName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? appSettings.primaryColor : appSettings.themePalette.secondaryForeground)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(appSettings.primaryColor)
                    }
                }

                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isSelected
                            ? appSettings.primaryColor.opacity(0.14)
                            : appSettings.themePalette.secondaryBackground
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected
                            ? appSettings.primaryColor.opacity(0.75)
                            : appSettings.themeSeparator(defaultOpacity: 0.35),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
