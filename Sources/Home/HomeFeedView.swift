import SwiftUI
import UIKit

private final class HomeFeedLegacyScrollCoordinator: ObservableObject {
    var idleTask: Task<Void, Never>?

    deinit {
        idleTask?.cancel()
    }
}

struct HomeFeedView: View {
    private static let feedTopAnchorID = "home-feed-top-anchor"
    private static let feedScrollCoordinateSpace = "home-feed-scroll"
    private static let feedHorizontalInset: CGFloat = 14
    private static let autoMergeTopThreshold: CGFloat = 56

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @ObservedObject var viewModel: HomeFeedViewModel
    @Binding var isShowingSideMenu: Bool
    @Binding var isRootVisible: Bool
    let scrollChromeStore: ScrollChromeStore
    let bottomTabBarHeight: CGFloat
    var onRequestSearch: () -> Void = {}
    private let reactionStats = NoteReactionStatsService.shared
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var muteStore = MuteStore.shared
    @ObservedObject private var interestFeedStore = InterestFeedStore.shared
    @ObservedObject private var hashtagFavoritesStore = HashtagFavoritesStore.shared
    @ObservedObject private var relayFavoritesStore = RelayFavoritesStore.shared

    @State private var isShowingAuthSheet = false
    @State private var authSheetInitialTab: AuthSheetTab = .signIn
    @State private var authSheetPresentationID = UUID()
    @State private var isShowingFilterSheet = false
    @State private var isShowingSettings = false
    @State private var isShowingCatchUp = false
    @State private var isGeneratingCatchUp = false
    @State private var catchUpSummary: HaloFeedCatchUpSummary?
    @State private var catchUpErrorMessage: String?
    @State private var catchUpTask: Task<Void, Never>?
    @StateObject private var settingsSheetState = SettingsSheetState()

    @State private var selectedThreadItem: FeedItem?
    @State private var selectedHashtagRoute: HashtagRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var selectedRelayRoute: RelayRoute?
    @State private var topNavAvatarURL: URL?
    @State private var topNavAvatarImage: UIImage?
    @State private var shouldAutoFocusReplyInThread = false
    @State private var isNearFeedTop = true
    @State private var isFeedScrolling = false
    @State private var isRevealingBufferedItems = false
    @State private var scrollChromeTracker = ScrollChromeTracker()
    @StateObject private var legacyScrollCoordinator = HomeFeedLegacyScrollCoordinator()

    var body: some View {
        let _ = muteStore.filterRevision
        let _ = appSettings.spamFilterLabelSignature

        navigationRoot
            .modifier(sheetsModifier)
            .modifier(lifecycleModifier)
            .sheet(isPresented: $isShowingCatchUp, onDismiss: cancelCatchUp) {
                HaloFeedCatchUpSheet(
                    summary: catchUpSummary,
                    isGenerating: isGeneratingCatchUp,
                    errorMessage: catchUpErrorMessage,
                    onRetry: generateCatchUp
                )
            }
            .onAppear {
                updateRootVisibility()
                showScrollChromeAtRest()
            }
            .onChange(of: selectedThreadItem) { _, _ in
                updateRootVisibility()
            }
            .onChange(of: selectedHashtagRoute) { _, _ in
                updateRootVisibility()
            }
            .onChange(of: selectedProfileRoute) { _, _ in
                updateRootVisibility()
            }
            .onChange(of: selectedRelayRoute) { _, _ in
                updateRootVisibility()
            }
    }

    private var sheetsModifier: HomeFeedSheets {
        HomeFeedSheets(
            isShowingAuthSheet: $isShowingAuthSheet,
            isShowingFilterSheet: $isShowingFilterSheet,
            isShowingSettings: $isShowingSettings,
            onSettingsDismiss: {
                settingsSheetState.reset()
            },
            authSheet: {
                AnyView(authSheet)
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

    private func updateRootVisibility() {
        isRootVisible = selectedThreadItem == nil
            && selectedHashtagRoute == nil
            && selectedProfileRoute == nil
            && selectedRelayRoute == nil
    }

    private func showScrollChromeAtRest() {
        scrollChromeTracker.resetBaseline()
        scrollChromeStore.showChromeAtRest()
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
                allowsSideMenuOpeningGesture: !viewModel.supportsModeTabsForCurrentSource
                    || viewModel.mode == HomeFeedMode.allCases.first,
                scrollChromeStore: scrollChromeStore,
                bottomTabBarHeight: bottomTabBarHeight,
                topNavigationBar: { topNavigationBar },
                feedContent: { bottomPadding, topBarHeight, topContentPadding, safeAreaBottom in
                    feedContent(
                        bottomContentPadding: bottomPadding,
                        topBarHeight: topBarHeight,
                        topContentPadding: topContentPadding,
                        safeAreaBottom: safeAreaBottom
                    )
                },
                sideMenuContent: { sideMenuContent }
            )
            .modifier(navigationDestinationsModifier)
        }
        .flowInteractiveBackSwipe()
    }

    private func feedContent(
        bottomContentPadding: CGFloat,
        topBarHeight: CGFloat,
        topContentPadding: CGFloat,
        safeAreaBottom: CGFloat
    ) -> some View {
        let visibleItems = viewModel.visibleItems

        return ScrollViewReader { scrollProxy in
            feedList(
                scrollProxy: scrollProxy,
                visibleItems: visibleItems,
                bottomContentPadding: bottomContentPadding,
                topBarHeight: topBarHeight,
                topContentPadding: topContentPadding,
                safeAreaBottom: safeAreaBottom
            )
        }
    }

    @ViewBuilder
    private func feedList(
        scrollProxy: ScrollViewProxy,
        visibleItems: [FeedItem],
        bottomContentPadding: CGFloat,
        topBarHeight: CGFloat,
        topContentPadding: CGFloat,
        safeAreaBottom: CGFloat
    ) -> some View {
        let list = List {
            feedTopAnchor
                .homeFeedListRow()
                .environment(\.defaultMinListRowHeight, 0)

            if showsFeedModeHeader {
                topTrackedRow(feedModeHeaderRow.homeFeedListRow(), isFirst: true)
            }

            feedRows(
                visibleItems,
                tracksFirstRowTop: !showsFeedModeHeader
            )

            loadingMoreRow
                .homeFeedListRow()

            feedBottomPadding(height: bottomContentPadding)
                .homeFeedListRow()
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.top, max(0, topContentPadding), for: .scrollContent)
        .contentMargins(.bottom, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .homeFeedNativeTabBarMinimizeBehavior()
        .coordinateSpace(name: Self.feedScrollCoordinateSpace)
        .overlay(alignment: .top) {
            newNotesOverlay(
                scrollProxy: scrollProxy,
                topBarHeight: topBarHeight
            )
        }
        .onChange(of: viewModel.visibleBufferedNewItemsCount) { _, _ in
            autoShowBufferedItemsIfNeeded()
        }
        .refreshable {
            await refreshFeed()
        }
        .task {
            await configureFeedDependenciesAndLoad()
        }
        .onDisappear {
            legacyScrollCoordinator.idleTask?.cancel()
            legacyScrollCoordinator.idleTask = nil
        }
        .flowHorizontalPaging(
            selection: $viewModel.mode,
            items: HomeFeedMode.allCases,
            isEnabled: viewModel.supportsModeTabsForCurrentSource,
            handsLeadingBoundaryToParent: true
        )

        if #available(iOS 18.0, *) {
            list
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, scrollY in
                    handleScroll(currentScrollY: scrollY, topBarHeight: topBarHeight, safeAreaBottom: safeAreaBottom)
                    handleNearTopChange(currentScrollY: scrollY)
                }
                .onScrollPhaseChange { _, newPhase in
                    let wasScrolling = isFeedScrolling
                    isFeedScrolling = newPhase.isScrolling
                    if wasScrolling, !newPhase.isScrolling {
                        autoShowBufferedItemsIfNeeded()
                    }
                }
        } else {
            list
                .onPreferenceChange(HomeFeedTopOffsetPreferenceKey.self) { newValue in
                    let currentScrollY = max(0, -newValue)
                    handleLegacyScrollActivity()
                    handleScroll(currentScrollY: currentScrollY, topBarHeight: topBarHeight, safeAreaBottom: safeAreaBottom)
                    handleNearTopChange(currentScrollY: currentScrollY)
                }
        }
    }

    private func feedBottomPadding(height: CGFloat) -> some View {
        Color.clear
            .frame(height: max(0, height))
            .accessibilityHidden(true)
    }

    private var feedTopAnchor: some View {
        Color.clear
            .frame(height: 0)
            .id(Self.feedTopAnchorID)
            .accessibilityHidden(true)
    }

    private var showsFeedModeHeader: Bool {
        viewModel.supportsModeTabsForCurrentSource ||
            viewModel.mediaOnly ||
            viewModel.feedSource == .articles ||
            viewModel.feedSource == .polls ||
            shouldShowCatchUpButton
    }

    private var feedModeHeaderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if viewModel.feedSource == .articles {
                    Label("Articles from people you follow", systemImage: "doc.text")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                } else if viewModel.feedSource == .polls {
                    Label("Polls from people you follow", systemImage: "chart.bar.xaxis")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                } else if viewModel.supportsModeTabsForCurrentSource {
                    FlowCapsuleTabBar(
                        selection: $viewModel.mode,
                        items: HomeFeedMode.allCases,
                        selectedBackground: FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedBackground,
                        selectedForeground: FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedForeground,
                        selectedStroke: FlowCapsuleTabBarStylePreset.HomeFeedModeTabs.selectedStroke,
                        title: { $0.title }
                    )
                }

                if shouldShowCatchUpButton {
                    Spacer(minLength: 4)
                    catchUpButton
                }
            }

            if viewModel.mediaOnly {
                Label("Media-only filter enabled", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
        .padding(.vertical, 0)
        .padding(.horizontal, Self.feedHorizontalInset)
    }

    private var shouldShowCatchUpButton: Bool {
        guard #available(iOS 26.0, *) else { return false }
        let readableCount = viewModel.visibleItems.lazy.filter {
            !$0.displayEvent.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.prefix(2).count
        return readableCount >= 2
    }

    private var catchUpButton: some View {
        Button {
            generateCatchUp()
        } label: {
            HStack(spacing: 6) {
                if isGeneratingCatchUp {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("Catch up")
            }
            .font(appSettings.appFont(.footnote, weight: .semibold))
            .foregroundStyle(appSettings.themePalette.foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .haloNativeGlass(
                interactive: true,
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isGeneratingCatchUp)
        .accessibilityHint("Summarizes visible posts on this device")
    }

    private func generateCatchUp() {
        catchUpTask?.cancel()
        let sources = viewModel.visibleItems.compactMap { item in
            HaloFeedSummarySource(
                author: item.displayName,
                content: item.displayEvent.content
            )
        }
        let boundedSources = Array(sources.prefix(8))

        isShowingCatchUp = true
        catchUpSummary = nil
        catchUpErrorMessage = nil

        let availability = HaloOnDeviceAssistant.summaryAvailability
        guard availability == .available else {
            isGeneratingCatchUp = false
            catchUpErrorMessage = availability.message
            return
        }

        isGeneratingCatchUp = true
        catchUpTask = Task {
            do {
                let summary = try await HaloOnDeviceAssistant.summarizeFeed(boundedSources)
                guard !Task.isCancelled else { return }
                catchUpSummary = summary
                isGeneratingCatchUp = false
                catchUpTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                catchUpErrorMessage = (error as? LocalizedError)?.errorDescription ?? "Halo couldn't summarize these posts."
                isGeneratingCatchUp = false
                catchUpTask = nil
            }
        }
    }

    private func cancelCatchUp() {
        catchUpTask?.cancel()
        catchUpTask = nil
        isGeneratingCatchUp = false
    }

    @ViewBuilder
    private func feedRows(
        _ visibleItems: [FeedItem],
        tracksFirstRowTop: Bool
    ) -> some View {
        if viewModel.isShowingLoadingPlaceholder {
            ForEach(0..<6, id: \.self) { index in
                topTrackedRow(
                    loadingRow
                        .padding(.horizontal, Self.feedHorizontalInset)
                        .homeFeedListRow(),
                    isFirst: tracksFirstRowTop && index == 0
                )
            }
        } else if visibleItems.isEmpty {
            topTrackedRow(
                emptyOrFilteredFeedRow
                    .homeFeedListRow(),
                isFirst: tracksFirstRowTop
            )
        } else {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                topTrackedRow(
                    feedRow(item)
                        .transition(FlowTransitionMotion.feedItemInsertionTransition(reduceMotion: accessibilityReduceMotion))
                        .id(item.id)
                        .homeFeedListRow(),
                    isFirst: tracksFirstRowTop && index == 0
                )
            }
        }
    }

    @ViewBuilder
    private func topTrackedRow<Row: View>(_ row: Row, isFirst: Bool) -> some View {
        if isFirst {
            row
                .background(feedTopOffsetReader)
        } else {
            row
        }
    }

    @ViewBuilder
    private var emptyOrFilteredFeedRow: some View {
        if viewModel.shouldShowFilteredOutState {
            filteredOutState
                .padding(.horizontal, Self.feedHorizontalInset)
        } else {
            emptyState
                .padding(.horizontal, Self.feedHorizontalInset)
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
            .padding(.horizontal, Self.feedHorizontalInset)
        }
    }

    @ViewBuilder
    private func newNotesOverlay(
        scrollProxy: ScrollViewProxy,
        topBarHeight: CGFloat
    ) -> some View {
        HomeFeedNewNotesChromeOverlay(
            scrollChromeStore: scrollChromeStore,
            isVisible: viewModel.visibleBufferedNewItemsCount > 0 &&
                !isNearFeedTop &&
                !isShowingSideMenu &&
                !isRevealingBufferedItems,
            topBarHeight: topBarHeight,
            content: {
                newNotesPill {
                    self.revealBufferedNewItems(scrollProxy: scrollProxy)
                }
            }
        )
    }

    private func handleScroll(
        currentScrollY: CGFloat,
        topBarHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) {
        let updated = scrollChromeTracker.offsetsByApplyingScroll(
            currentScrollY: currentScrollY,
            currentVisualOffsets: scrollChromeStore.offsets,
            topBarHeight: topBarHeight,
            bottomBarHeight: bottomTabBarHeight,
            safeAreaBottom: safeAreaBottom
        )

        scrollChromeStore.publishVisualOffsetsIfNeeded(updated)
    }

    private func handleNearTopChange(currentScrollY: CGFloat) {
        let nearTop = currentScrollY <= Self.autoMergeTopThreshold
        guard isNearFeedTop != nearTop else { return }
        isNearFeedTop = nearTop
        if nearTop {
            autoShowBufferedItemsIfNeeded()
        }
    }

    private func handleLegacyScrollActivity() {
        legacyScrollCoordinator.idleTask?.cancel()
        if !isFeedScrolling {
            isFeedScrolling = true
        }
        legacyScrollCoordinator.idleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            legacyScrollCoordinator.idleTask = nil
            isFeedScrolling = false
            autoShowBufferedItemsIfNeeded()
        }
    }

    private func refreshFeed() async {
        // Force so a pull always fetches, even when a background silent
        // refresh is in flight (previously the pull was queued and looked
        // like a no-op).
        await viewModel.refresh(force: true)
    }

    private func revealBufferedNewItems(scrollProxy: ScrollViewProxy) {
        guard viewModel.visibleBufferedNewItemsCount > 0 else { return }
        guard !isRevealingBufferedItems else { return }

        isRevealingBufferedItems = true

        Task { @MainActor in
            viewModel.showBufferedNewItems()

            await Task.yield()

            if let animation = FlowTransitionMotion.feedRevealScrollAnimation(reduceMotion: accessibilityReduceMotion) {
                withAnimation(animation) {
                    scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)
                }
            } else {
                scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)
            }

            // List can preserve its old visual position while reconciling a
            // newly inserted batch. Re-assert the stable top anchor after that
            // transaction settles so the new-notes control always reaches top.
            let settleNanoseconds = UInt64(
                (FlowTransitionMotion.duration(
                    .feedRevealScroll,
                    reduceMotion: accessibilityReduceMotion
                ) + 0.06) * 1_000_000_000
            )
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            guard !Task.isCancelled else { return }
            scrollProxy.scrollTo(Self.feedTopAnchorID, anchor: .top)
            isRevealingBufferedItems = false
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
                openSideMenu()
            } label: {
                topNavAccountIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open menu")

            Spacer()

            feedSourceMenu

            Spacer()

            filterButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var feedSourcePickerLabel: some View {
        ZStack {
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
            .id(viewModel.feedSource.id)
            .transition(FlowTransitionMotion.textStateSwapTransition(reduceMotion: accessibilityReduceMotion))
        }
        .animation(FlowTransitionMotion.textSwapAnimation(reduceMotion: accessibilityReduceMotion), value: viewModel.feedSource.id)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var feedSourceMenu: some View {
        Menu {
            ForEach(viewModel.feedSourceOptions) { source in
                Button {
                    viewModel.selectFeedSource(source)
                } label: {
                    Label(
                        feedSourceLabel(for: source),
                        systemImage: viewModel.feedSource == source
                            ? "checkmark"
                            : feedSourceIconName(for: source)
                    )
                }
            }

            let removableSources = viewModel.feedSourceOptions.filter(isRemovableFeedSource)
            if !removableSources.isEmpty {
                Divider()

                Menu {
                    ForEach(removableSources) { source in
                        Button(role: .destructive) {
                            removeFeedSourceFavorite(source)
                        } label: {
                            Label(feedSourceLabel(for: source), systemImage: "bookmark.slash")
                        }
                    }
                } label: {
                    Label("Remove Feed Source", systemImage: "bookmark.slash")
                }
            }

            Divider()

            Button {
                openFeedsSettingsFromFeedSourceMenu()
            } label: {
                Label("Create Feed", systemImage: "plus.circle.fill")
            }
        } label: {
            feedSourcePickerLabel
        }
        .buttonStyle(.plain)
        .haloNativeGlass(
            interactive: true,
            in: Capsule(style: .continuous)
        )
        .accessibilityLabel("Choose feed source")
    }

    private var sideMenuContent: some View {
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
            }
        )
        .environmentObject(auth)
    }

    private var filterButton: some View {
        Group {
            if viewModel.feedSource == .polls || viewModel.feedSource == .articles {
                Color.clear
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
            } else {
                Button {
                    isShowingFilterSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(
                            viewModel.isUsingCustomFilters
                                ? appSettings.primaryColor
                                : appSettings.themePalette.mutedForeground
                        )
                        .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .haloNativeGlass(
                    tint: viewModel.isUsingCustomFilters ? appSettings.primaryColor.opacity(0.14) : nil,
                    interactive: true,
                    in: Circle()
                )
                .accessibilityLabel("Feed filters")
                .accessibilityAddTraits(viewModel.isUsingCustomFilters ? [.isSelected] : [])
            }
        }
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
            VStack(spacing: 0) {
                ForEach(Array(viewModel.kindFilterOptions.enumerated()), id: \.element.id) { index, option in
                    Toggle(isOn: kindFilterBinding(for: option)) {
                        Label(option.title, systemImage: filterIconName(for: option))
                            .font(appSettings.appFont(.subheadline, weight: .medium))
                            .foregroundStyle(appSettings.themePalette.foreground)
                    }
                    .toggleStyle(.switch)
                    .tint(appSettings.primaryColor)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)

                    if index < viewModel.kindFilterOptions.count - 1 {
                        Divider()
                            .padding(.leading, 48)
                            .foregroundStyle(appSettings.themeSeparator(defaultOpacity: 0.35))
                    }
                }
            }
            .background(
                appSettings.themePalette.secondaryBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            Button {
                viewModel.selectAllKinds()
            } label: {
                Label("Select All", systemImage: "line.3.horizontal.decrease.circle")
                    .font(appSettings.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .haloNativeGlass(
                        interactive: true,
                        in: Capsule(style: .continuous)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func kindFilterBinding(for option: FeedKindFilterOption) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.isKindGroupEnabled(option)
            },
            set: { isEnabled in
                guard isEnabled != viewModel.isKindGroupEnabled(option) else { return }
                viewModel.toggleKindGroup(option)
            }
        )
    }

    private var mediaOnlyBinding: Binding<Bool> {
        Binding(
            get: {
                viewModel.mediaOnly
            },
            set: { isEnabled in
                viewModel.setMediaOnly(isEnabled)
            }
        )
    }

    private var contentFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content")
                .font(.headline)

            Toggle(isOn: mediaOnlyBinding) {
                Text("Only notes with media")
                    .font(appSettings.appFont(.subheadline, weight: .medium))
                    .foregroundStyle(appSettings.themePalette.foreground)
            }
            .toggleStyle(.switch)
            .tint(appSettings.primaryColor)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(
                appSettings.themePalette.secondaryBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
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
                .haloNativeGlass(
                    interactive: true,
                    in: Capsule(style: .continuous)
                )
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if let errorMessage = viewModel.errorMessage {
                emptyStateCopy(title: "Couldn’t refresh", message: errorMessage)
                emptyStateActionButton("Try again", systemImage: "arrow.clockwise") {
                    Task {
                        await viewModel.refresh()
                    }
                }
                .flowHierarchyEntrance(index: 1)
            } else if viewModel.interestsFeedHasNoHashtags {
                emptyStateCopy(
                    title: "No interests selected yet",
                    message: "Choose a few topics to shape this feed."
                )
                emptyStateActionButton("Choose interests", systemImage: "slider.horizontal.3") {
                    isShowingSettings = true
                }
                .flowHierarchyEntrance(index: 1)
            } else if viewModel.followingFeedHasNoFollowings {
                emptyStateCopy(
                    title: viewModel.feedSource == .articles
                        ? "No followed writers yet"
                        : "No followed accounts yet",
                    message: viewModel.feedSource == .articles
                        ? "Find people whose writing you want to see here."
                        : "Find people to follow or browse what’s popular now."
                )

                VStack(spacing: 10) {
                    emptyStateActionButton(
                        "Find people",
                        systemImage: "person.badge.plus",
                        fillsAvailableWidth: true
                    ) {
                        onRequestSearch()
                    }

                    if viewModel.feedSource != .articles {
                        emptyStateActionButton(
                            "Browse popular",
                            systemImage: "flame",
                            fillsAvailableWidth: true
                        ) {
                            if let animation = FlowTransitionMotion.textSwapAnimation(
                                reduceMotion: accessibilityReduceMotion
                            ) {
                                withAnimation(animation) {
                                    viewModel.selectFeedSource(.trending)
                                }
                            } else {
                                viewModel.selectFeedSource(.trending)
                            }
                        }
                    }
                }
                .frame(maxWidth: 260)
                .flowHierarchyEntrance(index: 1)
            } else if viewModel.feedSource == .articles {
                emptyStateCopy(
                    title: "No articles yet",
                    message: "New writing from people you follow will appear here."
                )
                emptyStateActionButton("Refresh", systemImage: "arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
                .flowHierarchyEntrance(index: 1)
            } else if viewModel.feedSource == .polls {
                emptyStateCopy(
                    title: "No polls yet",
                    message: "Follow more people or check again for new polls."
                )
                emptyStateActionButton("Refresh", systemImage: "arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
                .flowHierarchyEntrance(index: 1)
            } else {
                emptyStateCopy(
                    title: "No posts yet",
                    message: "Check for new posts or try again in a moment."
                )
                emptyStateActionButton("Refresh", systemImage: "arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
                .flowHierarchyEntrance(index: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
    }

    private func emptyStateCopy(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(appSettings.themePalette.foreground)

            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
        .flowHierarchyEntrance(index: 0)
    }

    private func emptyStateActionButton(
        _ title: String,
        systemImage: String,
        fillsAvailableWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(appSettings.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(appSettings.buttonTextColor)
                .padding(.horizontal, 16)
                .frame(
                    maxWidth: fillsAvailableWidth ? .infinity : nil,
                    minHeight: 44
                )
                .background(appSettings.primaryGradient, in: Capsule(style: .continuous))
        }
        .buttonStyle(FlowPressScaleButtonStyle())
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

    private func feedRow(_ item: FeedItem) -> some View {
        FeedRowView(
            item: item,
            initialEngagementSnapshot: reactionStats.currentSnapshot(for: item.displayEventID),
            showReactions: appSettings.reactionsVisibleInFeeds,
            engagementMode: .actionsOnly,
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
            },
            onMuteConversation: { conversationID in
                viewModel.muteConversation(conversationID)
            }
        )
        .padding(.horizontal, Self.feedHorizontalInset)
        .overlay(alignment: .bottom) {
            if appSettings.themePalette.feedCardStyle == nil {
                Rectangle()
                    .fill(appSettings.themePalette.chromeBorder)
                    .frame(height: 0.7)
                    .padding(.leading, appSettings.fullWidthNoteRows ? 0 : Self.feedHorizontalInset)
            }
        }
        .onAppear {
            Task(priority: .utility) {
                await viewModel.loadMoreIfNeeded(currentItem: item)
            }
        }
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

    private func openAuthSheet(tab: AuthSheetTab) {
        authSheetInitialTab = tab
        authSheetPresentationID = UUID()
        isShowingAuthSheet = true
    }

    private func openSideMenu() {
        if let animation = FlowTransitionMotion.sidePanelAnimation(reduceMotion: accessibilityReduceMotion) {
            withAnimation(animation) {
                isShowingSideMenu = true
            }
        } else {
            isShowingSideMenu = true
        }
    }

    private func closeSideMenu() {
        if let animation = FlowTransitionMotion.sidePanelAnimation(reduceMotion: accessibilityReduceMotion) {
            withAnimation(animation) {
                isShowingSideMenu = false
            }
        } else {
            isShowingSideMenu = false
        }
    }

    private var authSheet: some View {
        AuthSheetView(
            initialTab: authSheetInitialTab,
            onSelectedTabChange: { authSheetInitialTab = $0 }
        )
        .id(authSheetPresentationID)
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
            return "Following"
        case .following:
            return "Following"
        case .articles:
            return "Articles"
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
            guard let url = RelayURLSupport.normalizedURL(from: relayURL) else { return "Source" }
            return RelayURLSupport.displayName(for: url)
        }
    }

    private func feedSourceIconName(for source: HomePrimaryFeedSource) -> String {
        switch source {
        case .network:
            return "person.2"
        case .following:
            return "person.2"
        case .articles:
            return "doc.text"
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
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.35), lineWidth: 0.7)
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

                Text("posted")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(appSettings.themePalette.foreground)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .haloNativeGlass(interactive: true, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
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
        guard !isFeedScrolling else { return }
        guard !isRevealingBufferedItems else { return }
        guard viewModel.visibleBufferedNewItemsCount > 0 else { return }
        viewModel.showBufferedNewItems()
    }

    private func openFeedsSettingsFromFeedSourceMenu() {
        settingsSheetState.show(.feeds)
        isShowingSettings = true
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

}

private struct HomeFeedRootContent<
    TopNavigationBar: View,
    FeedContent: View,
    SideMenuContent: View
>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Binding var isShowingSideMenu: Bool
    let allowsSideMenuOpeningGesture: Bool

    @ObservedObject var scrollChromeStore: ScrollChromeStore
    let bottomTabBarHeight: CGFloat
    let topNavigationBar: () -> TopNavigationBar
    let feedContent: (
        _ bottomPadding: CGFloat,
        _ topBarHeight: CGFloat,
        _ topContentPadding: CGFloat,
        _ safeAreaBottom: CGFloat
    ) -> FeedContent
    let sideMenuContent: () -> SideMenuContent

    var body: some View {
        GeometryReader { geometry in
            let safeAreaTop = max(0, geometry.safeAreaInsets.top)
            let safeAreaBottom = max(0, geometry.safeAreaInsets.bottom)
            let contentPadding = ScrollChromeLayout.feedContentPadding(
                topBarHeight: ScrollChromeLayout.defaultTopBarHeight,
                safeAreaTop: safeAreaTop,
                bottomBarHeight: bottomTabBarHeight,
                safeAreaBottom: safeAreaBottom
            )
            SideMenuContainer(
                isOpen: $isShowingSideMenu,
                topSafeAreaInset: safeAreaTop,
                menuBackground: HomeSlideoutMenuStyle.background(
                    appSettings: appSettings,
                    colorScheme: colorScheme
                ),
                allowsOpeningGesture: allowsSideMenuOpeningGesture
            ) {
                sideMenuContent()
            } content: {
                primaryContent(
                    contentPadding: contentPadding,
                    safeAreaTop: safeAreaTop,
                    safeAreaBottom: safeAreaBottom
                )
            }
            // Expand the whole scrolling root, not just the List's child frame.
            // This prevents NavigationStack/SideMenuContainer from clipping rows
            // at the Dynamic Island and home-indicator safe-area boundaries.
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func primaryContent(
        contentPadding: ScrollChromeContentPadding,
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat
    ) -> some View {
        ZStack(alignment: .top) {
            AppThemeBackgroundView(holographicSpotlight: .feed)
                .ignoresSafeArea()

            feedContent(
                contentPadding.bottom,
                ScrollChromeLayout.defaultTopBarHeight,
                contentPadding.top,
                safeAreaBottom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)

            HomeFeedTopNavigationChromeView(
                scrollChromeStore: scrollChromeStore,
                topBarHeight: ScrollChromeLayout.defaultTopBarHeight,
                safeAreaTop: safeAreaTop,
                topNavigationBar: topNavigationBar
            )
        }
    }
}

private struct HomeFeedTopNavigationChromeView<TopNavigationBar: View>: View {
    @ObservedObject var scrollChromeStore: ScrollChromeStore

    let topBarHeight: CGFloat
    let safeAreaTop: CGFloat
    let topNavigationBar: () -> TopNavigationBar

    var body: some View {
        topNavigationBar()
            .padding(.top, safeAreaTop)
            .offset(y: topBarOffset)
            .opacity(visibleFraction)
            .allowsHitTesting(visibleFraction > 0.05)
            .accessibilityHidden(visibleFraction <= 0.05)
    }

    private var topBarOffset: CGFloat {
        min(max(scrollChromeStore.offsets.topBarOffset, -max(0, topBarHeight)), 0)
    }

    private var visibleFraction: Double {
        Double(
            ScrollChromeLayout.visibleFraction(
                offset: -topBarOffset,
                hiddenOffset: topBarHeight
            )
        )
    }
}

private struct HomeFeedNewNotesChromeOverlay<Content: View>: View {
    @ObservedObject var scrollChromeStore: ScrollChromeStore

    let isVisible: Bool
    let topBarHeight: CGFloat
    let content: Content

    init(
        scrollChromeStore: ScrollChromeStore,
        isVisible: Bool,
        topBarHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollChromeStore = scrollChromeStore
        self.isVisible = isVisible
        self.topBarHeight = topBarHeight
        self.content = content()
    }

    var body: some View {
        if isVisible {
            content
                .padding(
                    .top,
                    ScrollChromeLayout.newNotesIslandTopPadding(
                        topBarHeight: topBarHeight,
                        topBarOffset: scrollChromeStore.offsets.topBarOffset
                    )
                )
                .transition(.move(edge: .top).combined(with: .opacity))
        }
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
    @Binding var isShowingFilterSheet: Bool
    @Binding var isShowingSettings: Bool

    let onSettingsDismiss: () -> Void
    let authSheet: () -> AnyView
    let filterSheet: () -> AnyView
    let settingsSheet: () -> AnyView

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingAuthSheet) {
                authSheet()
            }
            .sheet(isPresented: $isShowingFilterSheet) {
                filterSheet()
            }
            .sheet(isPresented: $isShowingSettings, onDismiss: onSettingsDismiss) {
                settingsSheet()
            }
    }
}

private extension View {
    // The custom bottom navigation is opaque and sits over the feed, so the iOS 26
    // automatic scroll edge effect renders a soft shadow/fade at the bar's top edge.
    // Hide the bottom scroll edge effect so the bar reads as flat.
    @ViewBuilder
    func homeFeedNativeTabBarMinimizeBehavior() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
    }

    func homeFeedListRow() -> some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct HomeFeedTopOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
