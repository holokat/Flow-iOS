import SwiftUI

struct MainTabShellView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    enum Tab: String, CaseIterable, Hashable {
        case home
        case search
        case dms
        case activity

        var accessibilityLabel: String {
            switch self {
            case .home: return "Home"
            case .search: return "Search"
            case .dms: return "Halo Link"
            case .activity: return "Pulse"
            }
        }

        var symbolName: String {
            switch self {
            case .home: return "house"
            case .search: return "magnifyingglass"
            case .dms: return "bubble.left"
            case .activity: return "bell"
            }
        }
    }

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var composeSheetCoordinator: AppComposeSheetCoordinator
    @ObservedObject private var muteStore = MuteStore.shared
    @ObservedObject private var followStore = FollowStore.shared

    @State private var selectedTab: Tab = .home
    @State private var homeRootResetID = UUID()
    @State private var searchRootResetID = UUID()
    @State private var activityRootResetID = UUID()
    @State private var isShowingAuthSheet = false
    @State private var authSheetInitialTab: AuthSheetTab = .signIn
    @State private var isActivityRootVisible = true
    @State private var isDMRootVisible = true
    @State private var isHomeSideMenuPresented = false
    @State private var bottomTabBarHeight: CGFloat = FloatingComposeButtonLayout.defaultBottomTabBarHeight

    @StateObject private var homeViewModel = HomeFeedViewModel(
        relayURL: URL(string: RelaySettingsStore.defaultReadRelayURLs.first ?? "wss://relay.damus.io/")!
    )
    @StateObject private var searchViewModel = SearchViewModel(
        relayURL: URL(string: RelaySettingsStore.defaultReadRelayURLs.first ?? "wss://relay.damus.io/")!
    )
    @StateObject private var activityViewModel = ActivityViewModel()
    @StateObject private var liveReactsCoordinator = LiveReactsCoordinator()
    @StateObject private var liveReactsSubscriptionController = LiveReactsSubscriptionController()

    var body: some View {
        ZStack {
            AppThemeBackgroundView()
                .ignoresSafeArea()

            TabView(selection: $selectedTab) {
                HomeFeedView(
                    viewModel: homeViewModel,
                    isShowingSideMenu: $isHomeSideMenuPresented
                )
                    .id(homeRootResetID)
                    .tag(Tab.home)
                    .toolbar(.hidden, for: .tabBar)

                SearchView(
                    viewModel: searchViewModel,
                    isActive: selectedTab == .search
                )
                    .id(searchRootResetID)
                    .tag(Tab.search)
                    .toolbar(.hidden, for: .tabBar)

                DMsView(isRootVisible: $isDMRootVisible)
                    .tag(Tab.dms)
                    .toolbar(.hidden, for: .tabBar)

                ActivityView(
                    viewModel: activityViewModel,
                    isRootVisible: $isActivityRootVisible,
                    isTabActive: selectedTab == .activity
                )
                    .id(activityRootResetID)
                    .tag(Tab.activity)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if shouldReserveBottomTabBarInsetSpace {
                bottomTabBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if appSettings.floatingComposeButtonEnabled {
                floatingComposeButtonOverlay
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            GeometryReader { proxy in
                let horizontalPadding: CGFloat = 10
                let slotWidth = max((proxy.size.width - (horizontalPadding * 2)) / 5, 56)
                let bottomAnchor = proxy.safeAreaInsets.bottom + 50

                LiveReactsOverlayHost(coordinator: liveReactsCoordinator)
                    .frame(width: slotWidth * 1.15, height: 250, alignment: .bottom)
                    .offset(x: -(slotWidth * 0.04), y: -bottomAnchor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .allowsHitTesting(false)
        }
        .sheet(item: composeSheetDraftBinding, onDismiss: {
            composeSheetCoordinator.dismiss()
        }) { draft in
            composeNoteSheet(for: draft)
        }
        .sheet(isPresented: $isShowingAuthSheet) {
            AuthSheetView(
                initialTab: authSheetInitialTab,
                onSelectedTabChange: { authSheetInitialTab = $0 }
            )
                .environmentObject(auth)
                .environmentObject(appSettings)
                .environmentObject(relaySettings)
        }
        .task {
            relaySettings.configure(
                accountPubkey: auth.currentAccount?.pubkey,
                nsec: auth.currentNsec
            )
            Task { @MainActor in
                await prewarmInitialHomeFeed()
            }
            configureFollowStore()
            configureMuteStore()
            configureActivityViewModel()
            await activityViewModel.sceneDidChange(isActive: scenePhase == .active)
            configureLiveReactsSubscription()
            syncActivityTabActiveState()
        }
        .onChange(of: auth.currentAccount?.pubkey) { _, _ in
            relaySettings.configure(
                accountPubkey: auth.currentAccount?.pubkey,
                nsec: auth.currentNsec
            )
            configureFollowStore()
            configureMuteStore()
            configureActivityViewModel()
            configureLiveReactsSubscription()
        }
        .onChange(of: auth.currentNsec) { _, _ in
            configureFollowStore()
            configureMuteStore()
        }
        .onChange(of: relaySettings.readRelays) { _, _ in
            configureFollowStore()
            configureMuteStore()
            configureActivityViewModel()
            configureLiveReactsSubscription()
        }
        .onChange(of: relaySettings.writeRelays) { _, _ in
            configureFollowStore()
            configureMuteStore()
        }
        .onChange(of: appSettings.slowConnectionMode) { _, _ in
            configureFollowStore()
            configureMuteStore()
            configureActivityViewModel()
            configureLiveReactsSubscription()
        }
        .onChange(of: appSettings.liveReactsEnabled) { _, _ in
            configureLiveReactsSubscription()
        }
        .onPreferenceChange(BottomTabBarHeightPreferenceKey.self) { newValue in
            guard newValue > 0, abs(bottomTabBarHeight - newValue) >= 0.5 else { return }
            bottomTabBarHeight = newValue
        }
        .onChange(of: appSettings.activityNotificationPreferenceSignature) { _, _ in
            activityViewModel.notificationPreferencesChanged()
        }
        .onChange(of: appSettings.spamReplyFilterSignature) { _, _ in
            activityViewModel.notificationPreferencesChanged()
        }
        .onChange(of: muteStore.filterRevision) { _, _ in
            activityViewModel.notificationPreferencesChanged()
        }
        .onChange(of: followStore.followedPubkeys) { _, _ in
            activityViewModel.notificationPreferencesChanged()
        }
        .onChange(of: isActivityRootVisible) { _, _ in
            syncActivityTabActiveState()
        }
        .onChange(of: scenePhase) { _, _ in
            Task {
                await activityViewModel.sceneDidChange(isActive: scenePhase == .active)
            }
            configureLiveReactsSubscription()
        }
        .animation(.easeInOut(duration: 0.2), value: isHomeSideMenuPresented)
        .animation(.easeInOut(duration: 0.2), value: isDMRootVisible)
        .tint(appSettings.primaryColor)
        .statusBarHidden(false)
    }

    private var bottomTabBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(appSettings.themePalette.chromeBorder)
                .frame(height: 0.7)

            HStack(spacing: 0) {
                tabBarButton(for: .home)
                tabBarButton(for: .search)
                if !appSettings.floatingComposeButtonEnabled {
                    composeTabButton
                }
                tabBarButton(for: .dms)
                tabBarButton(for: .activity)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background {
            bottomTabBarBackground
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: BottomTabBarHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private var bottomTabBarBackground: some View {
        if effectiveChromeColorScheme == .light {
            Color.white
        } else if appSettings.activeTheme == .gamer {
            appSettings.themePalette.background
        } else {
            appSettings.themePalette.navigationBackground
        }
    }

    private var effectiveChromeColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }

    private func tabBarButton(for tab: Tab) -> some View {
        let isHighlighted = isTabHighlighted(tab)
        let showsUnreadBadge = tab == .activity && activityViewModel.hasUnread && !isActivityListVisible

        return Button {
            handleTabSelection(tab)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(
                        isHighlighted
                            ? appSettings.primaryColor
                            : appSettings.themePalette.iconMutedForeground
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Rectangle())

                if showsUnreadBadge {
                    ActivityUnreadBadgeView()
                        .offset(x: -20, y: 8)
                        .transition(FlowTransitionMotion.notificationBadgeTransition(reduceMotion: accessibilityReduceMotion))
                        .accessibilityHidden(true)
                }
            }
            .animation(FlowTransitionMotion.badgeAnimation(reduceMotion: accessibilityReduceMotion), value: showsUnreadBadge)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }

    private var composeTabButton: some View {
        Button {
            handleComposeTap()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(appSettings.buttonTextColor)
                .frame(width: 54, height: 54)
                .background(appSettings.primaryGradient, in: Circle())
                .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .offset(y: -4)
        .padding(.bottom, -4)
        .accessibilityLabel("Compose note")
    }

    private var floatingComposeButtonOverlay: some View {
        GeometryReader { proxy in
            composeFloatingButton
                .padding(.trailing, 18)
                .padding(.bottom, floatingComposeBottomPadding(safeAreaBottom: proxy.safeAreaInsets.bottom))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9), value: isBottomTabBarVisible)
        }
    }

    private var composeFloatingButton: some View {
        Button {
            handleComposeTap()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(appSettings.buttonTextColor)
                .frame(width: 58, height: 58)
                .background(appSettings.primaryGradient, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compose note")
    }

    private func floatingComposeBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: safeAreaBottom,
            bottomTabBarHeight: bottomTabBarHeight,
            isBottomTabBarVisible: isBottomTabBarVisible
        )
    }

    private var effectiveWriteRelayURLs: [URL] {
        return appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: effectiveReadRelayURLs
        )
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private var isBottomTabBarVisible: Bool {
        ScrollChromeLayout.isBottomTabBarVisible(
            isHomeSideMenuPresented: isHomeSideMenuPresented,
            selectedTabIsDirectMessages: selectedTab == .dms,
            isDirectMessagesRootVisible: isDMRootVisible
        )
    }

    private var shouldReserveBottomTabBarInsetSpace: Bool {
        ScrollChromeLayout.reservesBottomTabBarInsetSpace(
            isBottomTabBarVisible: isBottomTabBarVisible,
            usesOverlayBottomTabBar: shouldOverlayBottomTabBar
        )
    }

    private var shouldOverlayBottomTabBar: Bool {
        ScrollChromeLayout.usesOverlayBottomTabBar(
            selectedTabIsHome: selectedTab == .home,
            isHomeSideMenuPresented: isHomeSideMenuPresented
        )
    }

    private var composeSheetDraftBinding: Binding<AppComposeSheetDraft?> {
        Binding(
            get: { composeSheetCoordinator.draft },
            set: { composeSheetCoordinator.draft = $0 }
        )
    }

    @ViewBuilder
    private func composeNoteSheet(for draft: AppComposeSheetDraft) -> some View {
        ComposeNoteSheet(
            currentAccountPubkey: auth.currentAccount?.pubkey,
            currentNsec: auth.currentNsec,
            writeRelayURLs: effectiveWriteRelayURLs,
            initialText: draft.initialText,
            initialAdditionalTags: draft.initialAdditionalTags,
            initialUploadedAttachments: draft.initialUploadedAttachments,
            initialSharedAttachments: draft.initialSharedAttachments,
            initialSelectedMentions: draft.initialSelectedMentions,
            initialPollDraft: draft.initialPollDraft,
            replyTargetEvent: draft.replyTargetEvent,
            replyTargetDisplayNameHint: draft.replyTargetDisplayNameHint,
            replyTargetHandleHint: draft.replyTargetHandleHint,
            replyTargetAvatarURLHint: draft.replyTargetAvatarURLHint,
            quotedEvent: draft.quotedEvent,
            quotedDisplayNameHint: draft.quotedDisplayNameHint,
            quotedHandleHint: draft.quotedHandleHint,
            quotedAvatarURLHint: draft.quotedAvatarURLHint,
            savedDraftID: draft.savedDraftID,
            onOptimisticPublished: { item in
                switch selectedTab {
                case .home:
                    homeViewModel.insertOptimisticPublishedItem(item)
                case .search:
                    Task {
                        await searchViewModel.refresh()
                    }
                case .dms, .activity:
                    break
                }
            },
            onPublished: {
                Task {
                    switch selectedTab {
                    case .home:
                        await homeViewModel.refresh()
                    case .search:
                        await searchViewModel.refresh()
                    case .dms, .activity:
                        break
                    }
                }
            }
        )
    }

    private func handleComposeTap() {
        guard auth.currentAccount != nil else {
            authSheetInitialTab = .signIn
            isShowingAuthSheet = true
            return
        }

        composeSheetCoordinator.presentNewNote()
    }

    private func handleTabSelection(_ tab: Tab) {
        let previousTab = selectedTab
        let selectionEffects = MainTabSelectionPolicy.effects(
            previousTab: previousTab,
            selectedTab: tab,
            wasActivityRootVisible: isActivityRootVisible
        )

        if tab != .home {
            isHomeSideMenuPresented = false
        }

        if selectionEffects.resetsActivityRoot {
            resetActivityTabToRoot()
        }

        selectedTab = tab
        syncActivityTabActiveState()

        if selectionEffects.resetsHomeRoot {
            homeRootResetID = UUID()
        }

        if selectionEffects.resetsSearchRoot {
            searchRootResetID = UUID()
        }
    }

    private func configureActivityViewModel() {
        activityViewModel.configure(
            currentUserPubkey: auth.currentAccount?.pubkey,
            readRelayURLs: effectiveReadRelayURLs
        )
    }

    @MainActor
    private func prewarmInitialHomeFeed() async {
        let accountPubkey = auth.currentAccount?.pubkey
        let currentNsec = auth.currentNsec
        let interestFeedStore = InterestFeedStore.shared
        let hashtagFavoritesStore = HashtagFavoritesStore.shared
        let relayFavoritesStore = RelayFavoritesStore.shared

        appSettings.configure(accountPubkey: accountPubkey)
        relaySettings.configure(
            accountPubkey: accountPubkey,
            nsec: currentNsec
        )

        interestFeedStore.configure(accountPubkey: accountPubkey)
        hashtagFavoritesStore.configure(accountPubkey: accountPubkey)
        relayFavoritesStore.configure(accountPubkey: accountPubkey)

        homeViewModel.updateReadRelayURLs(effectiveReadRelayURLs)
        homeViewModel.updateInterestHashtags(interestFeedStore.hashtags)
        homeViewModel.updateFavoriteHashtags(hashtagFavoritesStore.favoriteHashtags)
        homeViewModel.updateFavoriteRelays(relayFavoritesStore.favoriteRelayURLs)
        homeViewModel.updatePollsFeedVisibility(appSettings.pollsFeedVisible)
        homeViewModel.updateCustomFeeds(appSettings.customFeeds)
        homeViewModel.updateCurrentUserPubkey(accountPubkey)
        await homeViewModel.loadIfNeeded()
    }

    private func configureLiveReactsSubscription() {
        liveReactsSubscriptionController.update(
            currentUserPubkey: auth.currentAccount?.pubkey,
            readRelayURLs: effectiveReadRelayURLs,
            isEnabled: appSettings.liveReactsEnabled,
            scenePhase: scenePhase,
            onReaction: { reaction in
                liveReactsCoordinator.emit(reaction)
            }
        )
    }

    private func configureMuteStore() {
        muteStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
    }

    private func configureFollowStore() {
        followStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
    }

    private var isActivityListVisible: Bool {
        selectedTab == .activity && isActivityRootVisible
    }

    private func isTabHighlighted(_ tab: Tab) -> Bool {
        switch tab {
        case .activity:
            return isActivityListVisible
        default:
            return selectedTab == tab
        }
    }

    private func resetActivityTabToRoot() {
        isActivityRootVisible = true
        activityRootResetID = UUID()
    }

    private func syncActivityTabActiveState() {
        activityViewModel.setActivityTabActive(isActivityListVisible)
    }
}

private struct ActivityUnreadBadgeView: View {
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
    }
}

struct FloatingComposeButtonLayout {
    static let defaultBottomTabBarHeight: CGFloat = 65
    private static let visibleBottomBarGap: CGFloat = 14
    private static let hiddenBottomGap: CGFloat = 10
    private static let requestedVerticalDrop: CGFloat = 12

    static func bottomPadding(
        safeAreaBottom: CGFloat,
        bottomTabBarHeight: CGFloat,
        isBottomTabBarVisible: Bool
    ) -> CGFloat {
        let safeAreaBottom = max(0, safeAreaBottom)

        guard isBottomTabBarVisible else {
            return max(0, safeAreaBottom + hiddenBottomGap - requestedVerticalDrop)
        }

        let bottomTabBarHeight = max(bottomTabBarHeight, defaultBottomTabBarHeight)
        return max(0, safeAreaBottom + bottomTabBarHeight + visibleBottomBarGap - requestedVerticalDrop)
    }
}

struct ScrollChromeLayout {
    static func isBottomTabBarVisible(
        isHomeSideMenuPresented: Bool,
        selectedTabIsDirectMessages: Bool,
        isDirectMessagesRootVisible: Bool
    ) -> Bool {
        !isHomeSideMenuPresented && (!selectedTabIsDirectMessages || isDirectMessagesRootVisible)
    }

    static func usesOverlayBottomTabBar(
        selectedTabIsHome: Bool,
        isHomeSideMenuPresented: Bool
    ) -> Bool {
        false
    }

    static func reservesBottomTabBarInsetSpace(
        isBottomTabBarVisible: Bool,
        usesOverlayBottomTabBar: Bool
    ) -> Bool {
        isBottomTabBarVisible && !usesOverlayBottomTabBar
    }
}

struct MainTabSelectionEffects: Equatable {
    let resetsHomeRoot: Bool
    let resetsSearchRoot: Bool
    let resetsActivityRoot: Bool
}

enum MainTabSelectionPolicy {
    static func effects(
        previousTab: MainTabShellView.Tab,
        selectedTab: MainTabShellView.Tab,
        wasActivityRootVisible: Bool
    ) -> MainTabSelectionEffects {
        MainTabSelectionEffects(
            resetsHomeRoot: selectedTab == .home,
            resetsSearchRoot: selectedTab == .search,
            resetsActivityRoot: previousTab == .activity &&
                (selectedTab != .activity || !wasActivityRootVisible)
        )
    }
}

private struct BottomTabBarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
