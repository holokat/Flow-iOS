import OSLog
import SwiftUI

struct MainTabShellView: View {
    private static let navigationLogger = Logger(
        subsystem: "com.karnagebitcoin.Flow",
        category: "MainNavigation"
    )

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    enum Tab: String, CaseIterable, Hashable {
        case home
        case search
        case compose
        case dms
        case activity

        var accessibilityLabel: String {
            switch self {
            case .home: return "Home"
            case .search: return "Search"
            case .compose: return "Compose note"
            case .dms: return "Halo Link"
            case .activity: return "Pulse"
            }
        }

        var symbolName: String {
            switch self {
            case .home: return "house"
            case .search: return "magnifyingglass"
            case .compose: return "plus"
            case .dms: return "bubble.left"
            case .activity: return "bell"
            }
        }

        var phosphorIconName: String {
            switch self {
            case .home: return "PhosphorHouse"
            case .search: return "PhosphorMagnifyingGlass"
            case .compose: return "PhosphorPlus"
            case .dms: return "PhosphorPaperPlaneTilt"
            case .activity: return "PhosphorHeart"
            }
        }

        var selectedPhosphorIconName: String {
            switch self {
            case .home: return "PhosphorHouseFill"
            case .search: return "PhosphorMagnifyingGlassFill"
            case .compose: return phosphorIconName
            case .dms: return "PhosphorPaperPlaneTiltFill"
            case .activity: return "PhosphorHeartFill"
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
    @State private var authSheetPresentationID = UUID()
    @State private var isHomeRootVisible = true
    @State private var isActivityRootVisible = true
    @State private var isDMRootVisible = true
    @State private var pendingHaloLinkParticipantPubkey: String?
    @State private var isHomeSideMenuPresented = false
    private let bottomTabBarHeight: CGFloat = ScrollChromeLayout.defaultBottomTabBarHeight
    private static let bottomNavIconSize: CGFloat = 26
    private static let bottomNavButtonSize: CGFloat = 48
    @State private var homeScrollChromeStore = ScrollChromeStore()

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
        eventHandlingShell
    }

    private var baseShell: some View {
        ZStack {
            AppThemeBackgroundView()
                .ignoresSafeArea()

            nativeTabView
                .flowHiddenBottomScrollEdgeEffect()
        }
        .overlay {
            GeometryReader { proxy in
                let bottomAnchor = proxy.safeAreaInsets.bottom + 50
                let fountainHeight = max(proxy.size.height - bottomAnchor, 1)

                LiveReactsOverlayHost(coordinator: liveReactsCoordinator)
                    .frame(width: proxy.size.width, height: fountainHeight, alignment: .bottom)
                    .position(x: proxy.size.width / 2, y: fountainHeight / 2)
            }
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if reservesBottomTabBarInsetSpace {
                customBottomNavBar
            }
        }
        .overlay(alignment: .bottom) {
            if usesOverlayBottomTabBar {
                customBottomNavBar
            }
        }
    }

    private var presentedShell: some View {
        baseShell
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
                .id(authSheetPresentationID)
                .environmentObject(auth)
                .environmentObject(appSettings)
                .environmentObject(relaySettings)
        }
    }

    private var configuredShell: some View {
        presentedShell
        .task {
            homeScrollChromeStore.showChromeAtRest()
            relaySettings.configure(
                accountPubkey: auth.currentAccount?.pubkey,
                nsec: auth.currentNsec
            )
            configureFollowStore()
            configureMuteStore()
            Task { @MainActor in
                await prewarmInitialHomeFeed()
            }
            configureActivityViewModel()
            await activityViewModel.sceneDidChange(isActive: scenePhase == .active)
            configureLiveReactsSubscription()
            syncActivityTabActiveState()
        }
    }

    private var accountObservedShell: some View {
        configuredShell
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
        .onChange(of: auth.currentNsec) { _, newNsec in
            configureFollowStore()
            configureMuteStore()
            if newNsec != nil, pendingHaloLinkParticipantPubkey != nil {
                handleTabSelection(.dms)
            }
        }
    }

    private var settingsObservedShell: some View {
        accountObservedShell
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
    }

    private var activityObservedShell: some View {
        settingsObservedShell
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
        .onChange(of: shouldKeepHomeFeedActive, initial: true) { _, isActive in
            homeViewModel.setBackgroundUpdatesPaused(!isActive)
        }
    }

    private var eventHandlingShell: some View {
        activityObservedShell
        .onChange(of: scenePhase) { _, _ in
            if scenePhase == .active, selectedTab == .home, isHomeRootVisible {
                homeScrollChromeStore.showChromeAtRest()
            }
            Task {
                await activityViewModel.sceneDidChange(isActive: scenePhase == .active)
            }
            configureLiveReactsSubscription()
        }
        .onReceive(NotificationCenter.default.publisher(for: .flowRequestAccountAccess)) { _ in
            showAccountAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: .flowOpenHaloLinkConversation)) { notification in
            guard let pubkey = notification.userInfo?["pubkey"] as? String,
                  !pubkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            pendingHaloLinkParticipantPubkey = pubkey
            if auth.currentNsec == nil {
                showAccountAccess()
            } else {
                handleTabSelection(.dms)
            }
        }
        .animation(FlowTransitionMotion.sidePanelAnimation(reduceMotion: accessibilityReduceMotion), value: isHomeSideMenuPresented)
        .animation(.easeInOut(duration: 0.2), value: isDMRootVisible)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .tint(appSettings.primaryColor)
        .statusBarHidden(false)
    }

    @ViewBuilder
    private var nativeTabView: some View {
        if #available(iOS 26.0, *) {
            modernNativeTabView
        } else {
            legacyNativeTabView
        }
    }

    // The native tab bar is hidden on both paths; `customBottomNavBar` (a standard
    // condensed bottom navigation) is overlaid instead. The TabView is retained
    // only to switch content and preserve each tab's navigation state.
    @available(iOS 26.0, *)
    private var modernNativeTabView: some View {
        TabView(selection: tabSelection) {
            SwiftUI.Tab(value: Tab.home) {
                homeTabContent
                    .flowNativeTabBarHidden()
            } label: {
                tabBarIcon(for: .home)
            }

            SwiftUI.Tab(value: Tab.search) {
                searchTabContent
                    .flowNativeTabBarHidden()
            } label: {
                tabBarIcon(for: .search)
            }

            SwiftUI.Tab(value: Tab.dms) {
                directMessagesTabContent
                    .flowNativeTabBarHidden()
            } label: {
                tabBarIcon(for: .dms)
            }

            SwiftUI.Tab(value: Tab.activity) {
                activityTabContent
                    .flowNativeTabBarHidden()
            } label: {
                tabBarIcon(for: .activity)
            }

            SwiftUI.Tab(value: Tab.compose) {
                Color.clear
                    .flowNativeTabBarHidden()
            } label: {
                tabBarIcon(for: .compose)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var legacyNativeTabView: some View {
        TabView(selection: tabSelection) {
            homeTabContent
                .flowNativeTabBarHidden()
                .tag(Tab.home)
                .tabItem { tabBarIcon(for: .home) }

            searchTabContent
                .flowNativeTabBarHidden()
                .tag(Tab.search)
                .tabItem { tabBarIcon(for: .search) }

            directMessagesTabContent
                .flowNativeTabBarHidden()
                .tag(Tab.dms)
                .tabItem { tabBarIcon(for: .dms) }

            activityTabContent
                .flowNativeTabBarHidden()
                .tag(Tab.activity)
                .tabItem { tabBarIcon(for: .activity) }

            Color.clear
                .flowNativeTabBarHidden()
                .tag(Tab.compose)
                .tabItem { tabBarIcon(for: .compose) }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var customBottomNavBar: some View {
        ScrollChromeOpacityReader(
            scrollChromeStore: homeScrollChromeStore,
            isActive: selectedTab == .home && isHomeRootVisible,
            bottomBarHeight: bottomTabBarHeight,
            safeAreaBottom: 0
        ) { chromeOpacity in
            bottomNavigationCapsule
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .opacity(chromeOpacity)
                .allowsHitTesting(chromeOpacity > 0.05)
                .accessibilityHidden(chromeOpacity <= 0.05)
        }
    }

    @ViewBuilder
    private var bottomNavigationCapsule: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                bottomNavigationItems
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            bottomNavigationItems
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(appSettings.themePalette.foreground.opacity(0.12), lineWidth: 0.7)
                }
                .shadow(
                    color: Color.black.opacity(0.12),
                    radius: 14,
                    x: 0,
                    y: 7
                )
        }
    }

    private var bottomNavigationItems: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                bottomNavButton(for: tab)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 56)
    }

    private func bottomNavButton(for tab: Tab) -> some View {
        let isSelected = tab != .compose && selectedTab == tab
        return Button {
            handleTabSelection(tab)
        } label: {
            ZStack {
                Image(isSelected ? tab.selectedPhosphorIconName : tab.phosphorIconName)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.bottomNavIconSize, height: Self.bottomNavIconSize)
                    .foregroundStyle(appSettings.themePalette.foreground.opacity(isSelected ? 1 : 0.9))
                    .contentTransition(.opacity)

                if tab == .activity, activityTabShowsUnreadBadge {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .offset(x: Self.bottomNavIconSize * 0.55, y: -Self.bottomNavIconSize * 0.5)
                }
            }
            .frame(width: Self.bottomNavButtonSize, height: Self.bottomNavButtonSize)
            .background {
                if isSelected {
                    Capsule()
                        .fill(appSettings.themePalette.foreground.opacity(0.08))
                        .padding(.horizontal, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(FlowPressScaleButtonStyle())
        .animation(
            accessibilityReduceMotion ? nil : .smooth(duration: 0.28),
            value: isSelected
        )
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var homeTabContent: some View {
        HomeFeedView(
            viewModel: homeViewModel,
            isShowingSideMenu: $isHomeSideMenuPresented,
            isRootVisible: $isHomeRootVisible,
            scrollChromeStore: homeScrollChromeStore,
            bottomTabBarHeight: bottomTabBarHeight,
            onRequestSearch: {
                handleTabSelection(.search)
            }
        )
        .environment(\.flowScrollChromeStore, homeScrollChromeStore)
        .environment(\.flowBottomTabBarHeight, bottomTabBarHeight)
        .id(homeRootResetID)
    }

    private var searchTabContent: some View {
        SearchView(
            viewModel: searchViewModel,
            isActive: selectedTab == .search
        )
        .id(searchRootResetID)
    }

    private var directMessagesTabContent: some View {
        DMsView(
            isRootVisible: $isDMRootVisible,
            pendingParticipantPubkey: $pendingHaloLinkParticipantPubkey,
            onRequestAccountAccess: showAccountAccess
        )
    }

    private var activityTabContent: some View {
        ActivityView(
            viewModel: activityViewModel,
            isRootVisible: $isActivityRootVisible,
            isTabActive: selectedTab == .activity
        )
        .id(activityRootResetID)
    }

    @ViewBuilder
    private func tabBarIcon(for tab: Tab) -> some View {
        Image(systemName: tab.symbolName)
            .symbolRenderingMode(.monochrome)
            .environment(\.symbolVariants, .none)
            .accessibilityLabel(tab.accessibilityLabel)
    }

    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard newValue != .compose else {
                    handleComposeTap()
                    return
                }

                handleTabSelection(newValue)
            }
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
            isHomeSideMenuPresented: isHomeSideMenuPresented
        )
    }

    private var usesOverlayBottomTabBar: Bool {
        isBottomTabBarVisible && ScrollChromeLayout.usesOverlayBottomTabBar(
            selectedTabIsHome: selectedTab == .home,
            isHomeSideMenuPresented: isHomeSideMenuPresented
        )
    }

    private var reservesBottomTabBarInsetSpace: Bool {
        ScrollChromeLayout.reservesBottomTabBarInsetSpace(
            isBottomTabBarVisible: isBottomTabBarVisible,
            usesOverlayBottomTabBar: usesOverlayBottomTabBar
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
            viewModel: draft.viewModel,
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
            onRequestAccountAccess: requestAccountAccessFromComposer,
            onOptimisticPublished: { item in
                if let onOptimisticPublished = draft.onOptimisticPublished {
                    onOptimisticPublished(item)
                    return
                }
                switch selectedTab {
                case .home:
                    animateFeedInsertion {
                        homeViewModel.insertOptimisticPublishedItem(item)
                    }
                case .search:
                    Task {
                        await searchViewModel.refresh()
                    }
                case .compose, .dms, .activity:
                    break
                }
            },
            onPublished: {
                if let onPublished = draft.onPublished {
                    onPublished()
                    return
                }
                Task {
                    switch selectedTab {
                    case .home:
                        await homeViewModel.refresh()
                    case .search:
                        await searchViewModel.refresh()
                    case .compose, .dms, .activity:
                        break
                    }
                }
            }
        )
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

    private func handleComposeTap() {
        guard auth.currentAccount != nil, auth.currentNsec != nil else {
            showAccountAccess()
            return
        }

        composeSheetCoordinator.presentNewNote()
    }

    private func showAccountAccess() {
        authSheetInitialTab = .signIn
        authSheetPresentationID = UUID()
        isShowingAuthSheet = true
    }

    private func requestAccountAccessFromComposer() {
        composeSheetCoordinator.dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            showAccountAccess()
        }
    }

    private var shouldKeepHomeFeedActive: Bool {
        scenePhase == .active &&
            selectedTab == .home &&
            isHomeRootVisible &&
            composeSheetCoordinator.draft == nil
    }

    private func handleTabSelection(_ tab: Tab) {
        guard tab != .compose else {
            handleComposeTap()
            return
        }

        let previousTab = selectedTab
        let selectionEffects = MainTabSelectionPolicy.effects(
            previousTab: previousTab,
            selectedTab: tab,
            wasActivityRootVisible: isActivityRootVisible
        )

        Self.navigationLogger.debug(
            "Bottom tab selected previous=\(previousTab.rawValue, privacy: .public) target=\(tab.rawValue, privacy: .public) activityRoot=\(self.isActivityRootVisible, privacy: .public) dmRoot=\(self.isDMRootVisible, privacy: .public)"
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

    private var activityTabShowsUnreadBadge: Bool {
        activityViewModel.hasUnread && !isActivityListVisible
    }

    private func resetActivityTabToRoot() {
        isActivityRootVisible = true
        activityRootResetID = UUID()
    }

    private func syncActivityTabActiveState() {
        activityViewModel.setActivityTabActive(isActivityListVisible)
    }
}

extension Notification.Name {
    static let flowRequestAccountAccess = Notification.Name("flow.requestAccountAccess")
    static let flowOpenHaloLinkConversation = Notification.Name("flow.openHaloLinkConversation")
}

private extension View {
    func flowNativeTabBarHidden() -> some View {
        self.toolbar(.hidden, for: .tabBar)
    }

    // Home uses edge-to-edge overlay chrome; the other tabs reserve a safe-area
    // inset for the same custom navigation. Hide the automatic edge fade so the
    // Home feed remains visible beneath its transparent chrome.
    @ViewBuilder
    func flowHiddenBottomScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
    }
}

struct ScrollChromeOffsets: Equatable {
    var previousScrollY: CGFloat = 0
    var topBarOffset: CGFloat = 0
    var bottomBarOffset: CGFloat = 0
    var hasMeasuredScrollY = false
}

@MainActor
final class ScrollChromeStore: ObservableObject {
    @Published private(set) var offsets = ScrollChromeOffsets()

    func showChromeAtRest() {
        offsets = ScrollChromeOffsets()
    }

    func publishVisualOffsetsIfNeeded(_ updated: ScrollChromeOffsets) {
        guard ScrollChromeLayout.shouldPublishVisualOffsets(updated, over: offsets) else { return }
        offsets = ScrollChromeLayout.publishedVisualOffsets(from: updated)
    }

}

final class ScrollChromeTracker {
    private var state = ScrollChromeOffsets()

    func resetBaseline() {
        state = ScrollChromeOffsets()
    }

    func offsetsByApplyingScroll(
        currentScrollY: CGFloat,
        currentVisualOffsets: ScrollChromeOffsets,
        topBarHeight: CGFloat,
        bottomBarHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) -> ScrollChromeOffsets {
        if !state.hasMeasuredScrollY {
            state = ScrollChromeOffsets(
                previousScrollY: max(0, currentScrollY),
                topBarOffset: currentVisualOffsets.topBarOffset,
                bottomBarOffset: currentVisualOffsets.bottomBarOffset,
                hasMeasuredScrollY: true
            )
            return state
        }

        if ScrollChromeLayout.shouldPublishVisualOffsets(currentVisualOffsets, over: state) {
            state.topBarOffset = currentVisualOffsets.topBarOffset
            state.bottomBarOffset = currentVisualOffsets.bottomBarOffset
        }

        let updated = ScrollChromeLayout.offsetsByApplyingScroll(
            currentScrollY: currentScrollY,
            state: state,
            topBarHeight: topBarHeight,
            bottomBarHeight: bottomBarHeight,
            safeAreaBottom: safeAreaBottom
        )
        state = updated
        return updated
    }
}

private struct FlowScrollChromeStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: ScrollChromeStore? = nil
}

private struct FlowBottomTabBarHeightEnvironmentKey: EnvironmentKey {
    static let defaultValue = ScrollChromeLayout.defaultBottomTabBarHeight
}

extension EnvironmentValues {
    var flowScrollChromeStore: ScrollChromeStore? {
        get { self[FlowScrollChromeStoreEnvironmentKey.self] }
        set { self[FlowScrollChromeStoreEnvironmentKey.self] = newValue }
    }

    var flowBottomTabBarHeight: CGFloat {
        get { self[FlowBottomTabBarHeightEnvironmentKey.self] }
        set { self[FlowBottomTabBarHeightEnvironmentKey.self] = newValue }
    }
}

struct ScrollChromeContentPadding: Equatable {
    let top: CGFloat
    let bottom: CGFloat
}

private struct ScrollChromeOpacityReader<Content: View>: View {
    @ObservedObject var scrollChromeStore: ScrollChromeStore

    let isActive: Bool
    let bottomBarHeight: CGFloat
    let safeAreaBottom: CGFloat
    let content: (Double) -> Content

    var body: some View {
        content(chromeOpacity)
    }

    private var chromeOpacity: Double {
        guard isActive else { return 1 }

        return ScrollChromeLayout.chromeOpacity(
            bottomBarOffset: scrollChromeStore.offsets.bottomBarOffset,
            bottomBarHeight: bottomBarHeight,
            safeAreaBottom: safeAreaBottom
        )
    }
}

struct ScrollChromeLayout {
    static let defaultTopBarHeight: CGFloat = 66
    static let defaultBottomTabBarHeight: CGFloat = 66
    static let topOfFeedRestoreThreshold: CGFloat = 8
    static let visualOffsetPublishThreshold: CGFloat = 0.5
    static let dimmedChromeOpacity: Double = 0

    static func isBottomTabBarVisible(
        isHomeSideMenuPresented: Bool
    ) -> Bool {
        !isHomeSideMenuPresented
    }

    static func usesOverlayBottomTabBar(
        selectedTabIsHome: Bool,
        isHomeSideMenuPresented: Bool
    ) -> Bool {
        selectedTabIsHome && !isHomeSideMenuPresented
    }

    static func reservesBottomTabBarInsetSpace(
        isBottomTabBarVisible: Bool,
        usesOverlayBottomTabBar: Bool
    ) -> Bool {
        isBottomTabBarVisible && !usesOverlayBottomTabBar
    }

    static func offsetsByApplyingScroll(
        currentScrollY: CGFloat,
        state: ScrollChromeOffsets,
        topBarHeight: CGFloat,
        bottomBarHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) -> ScrollChromeOffsets {
        let currentScrollY = max(0, currentScrollY)
        let topBarHeight = max(0, topBarHeight)
        let bottomHiddenOffset = bottomHiddenOffset(
            bottomBarHeight: bottomBarHeight,
            safeAreaBottom: safeAreaBottom
        )
        let hasScrollBaseline = state.hasMeasuredScrollY
            || state.previousScrollY != 0
            || state.topBarOffset != 0
            || state.bottomBarOffset != 0

        guard hasScrollBaseline else {
            return ScrollChromeOffsets(
                previousScrollY: currentScrollY,
                topBarOffset: state.topBarOffset,
                bottomBarOffset: state.bottomBarOffset,
                hasMeasuredScrollY: true
            )
        }

        guard currentScrollY > topOfFeedRestoreThreshold else {
            return ScrollChromeOffsets(
                previousScrollY: currentScrollY,
                topBarOffset: 0,
                bottomBarOffset: 0,
                hasMeasuredScrollY: true
            )
        }

        let delta = currentScrollY - state.previousScrollY
        let bottomDelta = delta * bottomScrollMultiplier(
            topBarHeight: topBarHeight,
            bottomHiddenOffset: bottomHiddenOffset
        )

        return ScrollChromeOffsets(
            previousScrollY: currentScrollY,
            topBarOffset: clamp(
                state.topBarOffset - delta,
                min: -topBarHeight,
                max: 0
            ),
            bottomBarOffset: clamp(
                state.bottomBarOffset + bottomDelta,
                min: 0,
                max: bottomHiddenOffset
            ),
            hasMeasuredScrollY: true
        )
    }

    static func settledOffsets(
        topBarOffset: CGFloat,
        bottomBarOffset: CGFloat,
        topBarHeight: CGFloat,
        bottomHiddenOffset: CGFloat
    ) -> (topBarOffset: CGFloat, bottomBarOffset: CGFloat) {
        let topBarHeight = max(0, topBarHeight)
        let bottomHiddenOffset = max(0, bottomHiddenOffset)

        return (
            topBarOffset: clamp(topBarOffset, min: -topBarHeight, max: 0),
            bottomBarOffset: clamp(bottomBarOffset, min: 0, max: bottomHiddenOffset)
        )
    }

    static func bottomHiddenOffset(
        bottomBarHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) -> CGFloat {
        max(0, bottomBarHeight) + max(0, safeAreaBottom)
    }

    static func bottomBarOffset(
        from offsets: ScrollChromeOffsets,
        selectedTabIsHome: Bool,
        isHomeRootVisible: Bool,
        bottomBarHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) -> CGFloat {
        guard selectedTabIsHome, isHomeRootVisible else { return 0 }

        let hiddenOffset = bottomHiddenOffset(
            bottomBarHeight: bottomBarHeight,
            safeAreaBottom: safeAreaBottom
        )
        return clamp(offsets.bottomBarOffset, min: 0, max: hiddenOffset)
    }

    static func bottomContentVisibleFraction(
        offset: CGFloat,
        bottomBarHeight: CGFloat
    ) -> CGFloat {
        visibleFraction(
            offset: offset,
            hiddenOffset: bottomBarHeight
        )
    }

    static func chromeOpacity(
        bottomBarOffset: CGFloat,
        bottomBarHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) -> Double {
        let hiddenOffset = bottomHiddenOffset(
            bottomBarHeight: bottomBarHeight,
            safeAreaBottom: safeAreaBottom
        )
        let hiddenProgress = hiddenProgress(
            offset: bottomBarOffset,
            hiddenOffset: hiddenOffset
        )
        let visibleOpacity = 1 - hiddenProgress * (1 - CGFloat(dimmedChromeOpacity))

        return Double(clamp(visibleOpacity, min: CGFloat(dimmedChromeOpacity), max: 1))
    }

    static func feedContentPadding(
        topBarHeight: CGFloat,
        safeAreaTop: CGFloat = 0,
        topBarOffset: CGFloat = 0,
        bottomBarHeight: CGFloat,
        safeAreaBottom: CGFloat,
        bottomBarVisibleFraction: CGFloat = 1
    ) -> ScrollChromeContentPadding {
        let visibleTopBarHeight = max(0, topBarHeight) + max(0, safeAreaTop)
        let visibleBottomClearance = max(0, bottomBarHeight) + max(0, safeAreaBottom)
        _ = topBarOffset
        _ = bottomBarVisibleFraction

        return ScrollChromeContentPadding(
            top: visibleTopBarHeight,
            bottom: visibleBottomClearance
        )
    }

    static func publishedVisualOffsets(from offsets: ScrollChromeOffsets) -> ScrollChromeOffsets {
        ScrollChromeOffsets(
            topBarOffset: offsets.topBarOffset,
            bottomBarOffset: offsets.bottomBarOffset,
            hasMeasuredScrollY: offsets.hasMeasuredScrollY
        )
    }

    static func shouldPublishVisualOffsets(
        _ candidate: ScrollChromeOffsets,
        over current: ScrollChromeOffsets,
        threshold: CGFloat = visualOffsetPublishThreshold
    ) -> Bool {
        abs(candidate.topBarOffset - current.topBarOffset) >= threshold
            || abs(candidate.bottomBarOffset - current.bottomBarOffset) >= threshold
    }

    static func visibleFraction(
        offset: CGFloat,
        hiddenOffset: CGFloat
    ) -> CGFloat {
        1 - hiddenProgress(offset: offset, hiddenOffset: hiddenOffset)
    }

    static func hiddenProgress(
        offset: CGFloat,
        hiddenOffset: CGFloat
    ) -> CGFloat {
        let hiddenOffset = max(0, hiddenOffset)
        guard hiddenOffset > 0 else { return 0 }

        return clamp(offset / hiddenOffset, min: 0, max: 1)
    }

    static func newNotesIslandTopPadding(
        topBarHeight: CGFloat,
        topBarOffset: CGFloat
    ) -> CGFloat {
        let visibleTopBarHeight = max(0, topBarHeight + topBarOffset)
        return max(8, visibleTopBarHeight + 8)
    }

    private static func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    private static func bottomScrollMultiplier(
        topBarHeight: CGFloat,
        bottomHiddenOffset: CGFloat
    ) -> CGFloat {
        let topBarHeight = max(0, topBarHeight)
        let bottomHiddenOffset = max(0, bottomHiddenOffset)
        guard topBarHeight > 0, bottomHiddenOffset > 0 else { return 1 }

        return bottomHiddenOffset / topBarHeight
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
                selectedTab != .activity
        )
    }
}
