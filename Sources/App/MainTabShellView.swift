import SwiftUI

struct MainTabShellView: View {
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

        var tabBarTitle: String {
            switch self {
            case .home: return "Home"
            case .search: return "Search"
            case .compose: return "Compose"
            case .dms: return "Halo"
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
    @State private var isHomeSideMenuPresented = false
    private let bottomTabBarHeight: CGFloat = FloatingComposeButtonLayout.defaultBottomTabBarHeight
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
        ZStack {
            AppThemeBackgroundView()
                .ignoresSafeArea()

            TabView(selection: tabSelection) {
                HomeFeedView(
                    viewModel: homeViewModel,
                    isShowingSideMenu: $isHomeSideMenuPresented,
                    isRootVisible: $isHomeRootVisible,
                    scrollChromeStore: homeScrollChromeStore,
                    bottomTabBarHeight: bottomTabBarHeight
                )
                    .environment(\.flowScrollChromeStore, homeScrollChromeStore)
                    .environment(\.flowBottomTabBarHeight, bottomTabBarHeight)
                    .id(homeRootResetID)
                    .tag(Tab.home)
                    .tabItem { tabBarLabel(for: .home) }

                SearchView(
                    viewModel: searchViewModel,
                    isActive: selectedTab == .search
                )
                    .id(searchRootResetID)
                    .tag(Tab.search)
                    .tabItem { tabBarLabel(for: .search) }

                if !appSettings.floatingComposeButtonEnabled {
                    Color.clear
                        .tag(Tab.compose)
                        .tabItem { tabBarLabel(for: .compose) }
                }

                DMsView(isRootVisible: $isDMRootVisible)
                    .tag(Tab.dms)
                    .tabItem { tabBarLabel(for: .dms) }

                ActivityView(
                    viewModel: activityViewModel,
                    isRootVisible: $isActivityRootVisible,
                    isTabActive: selectedTab == .activity
                )
                    .id(activityRootResetID)
                    .tag(Tab.activity)
                    .tabItem { tabBarLabel(for: .activity) }
                    .modifier(ActivityTabUnreadBadgeModifier(isVisible: activityViewModel.hasUnread && !isActivityListVisible))
            }
            .toolbar(nativeTabBarVisibility, for: .tabBar)
            .flowNativeTabBarBehavior()
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
                .id(authSheetPresentationID)
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
        .animation(FlowTransitionMotion.sidePanelAnimation(reduceMotion: accessibilityReduceMotion), value: isHomeSideMenuPresented)
        .animation(.easeInOut(duration: 0.2), value: isDMRootVisible)
        .tint(appSettings.primaryColor)
        .statusBarHidden(false)
    }

    @ViewBuilder
    private func tabBarLabel(for tab: Tab) -> some View {
        Label(tab.tabBarTitle, systemImage: tab.symbolName)
            .accessibilityLabel(tab.accessibilityLabel)
    }

    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                AppClickSoundPlayer.play(appSettings.clickSoundEffect)
                guard newValue != .compose else {
                    handleComposeTap()
                    return
                }

                handleTabSelection(newValue)
            }
        )
    }

    private var nativeTabBarVisibility: Visibility {
        isBottomTabBarVisible ? .visible : .hidden
    }

    private var floatingComposeButtonOverlay: some View {
        FloatingComposeButtonChromeOverlay(
            scrollChromeStore: homeScrollChromeStore,
            bottomTabBarHeight: bottomTabBarHeight,
            selectedTab: selectedTab,
            isHomeRootVisible: isHomeRootVisible,
            isBottomTabBarVisible: isBottomTabBarVisible,
            shouldOverlayBottomTabBar: shouldOverlayBottomTabBar,
            composeFloatingButton: { AnyView(composeFloatingButton) }
        )
    }

    private var composeFloatingButton: some View {
        Button {
            AppClickSoundPlayer.play(appSettings.clickSoundEffect)
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
        guard auth.currentAccount != nil else {
            authSheetInitialTab = .signIn
            authSheetPresentationID = UUID()
            isShowingAuthSheet = true
            return
        }

        composeSheetCoordinator.presentNewNote()
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

    private func resetActivityTabToRoot() {
        isActivityRootVisible = true
        activityRootResetID = UUID()
    }

    private func syncActivityTabActiveState() {
        activityViewModel.setActivityTabActive(isActivityListVisible)
    }
}

private struct ActivityTabUnreadBadgeModifier: ViewModifier {
    let isVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            content.badge("")
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func flowNativeTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

struct FloatingComposeButtonLayout {
    static let defaultBottomTabBarHeight: CGFloat = 67
    static let trailingPadding: CGFloat = 26
    private static let visibleBottomBarGap: CGFloat = 14
    private static let hiddenBottomGap: CGFloat = 10
    private static let hiddenVerticalDrop: CGFloat = 24
    private static let visibleVerticalDrop: CGFloat = 60

    static func bottomPadding(
        safeAreaBottom: CGFloat,
        bottomTabBarHeight: CGFloat,
        isBottomTabBarVisible: Bool
    ) -> CGFloat {
        bottomPadding(
            safeAreaBottom: safeAreaBottom,
            bottomTabBarHeight: bottomTabBarHeight,
            hiddenProgress: isBottomTabBarVisible ? 0 : 1
        )
    }

    static func bottomPadding(
        safeAreaBottom: CGFloat,
        bottomTabBarHeight: CGFloat,
        hiddenProgress: CGFloat
    ) -> CGFloat {
        let safeAreaBottom = max(0, safeAreaBottom)
        let hiddenProgress = clamp(hiddenProgress, min: 0, max: 1)
        let hiddenPadding = max(0, safeAreaBottom + hiddenBottomGap - hiddenVerticalDrop)
        let visibleBottomBarHeight = max(bottomTabBarHeight, defaultBottomTabBarHeight)
        let visiblePadding = max(0, safeAreaBottom + visibleBottomBarHeight + visibleBottomBarGap - visibleVerticalDrop)

        return visiblePadding + ((hiddenPadding - visiblePadding) * hiddenProgress)
    }

    private static func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private struct FloatingComposeButtonChromeOverlay: View {
    @ObservedObject var scrollChromeStore: ScrollChromeStore

    let bottomTabBarHeight: CGFloat
    let selectedTab: MainTabShellView.Tab
    let isHomeRootVisible: Bool
    let isBottomTabBarVisible: Bool
    let shouldOverlayBottomTabBar: Bool
    let composeFloatingButton: () -> AnyView

    var body: some View {
        GeometryReader { proxy in
            let bottomPadding = floatingComposeBottomPadding(safeAreaBottom: proxy.safeAreaInsets.bottom)

            composeFloatingButton()
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }
                .padding(.trailing, FloatingComposeButtonLayout.trailingPadding)
                .padding(.bottom, bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func floatingComposeBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        FloatingComposeButtonLayout.bottomPadding(
            safeAreaBottom: safeAreaBottom,
            bottomTabBarHeight: bottomTabBarHeight,
            hiddenProgress: bottomTabBarHiddenProgress(safeAreaBottom: safeAreaBottom)
        )
    }

    private func bottomTabBarHiddenProgress(safeAreaBottom: CGFloat) -> CGFloat {
        guard isBottomTabBarVisible else { return 1 }
        guard selectedTab == .home, isHomeRootVisible else { return 0 }
        guard shouldOverlayBottomTabBar else { return 0 }

        let hiddenOffset = ScrollChromeLayout.bottomHiddenOffset(
            bottomBarHeight: bottomTabBarHeight,
            safeAreaBottom: safeAreaBottom
        )
        return ScrollChromeLayout.hiddenProgress(
            offset: ScrollChromeLayout.bottomBarOffset(
                from: scrollChromeStore.offsets,
                selectedTabIsHome: selectedTab == .home,
                isHomeRootVisible: isHomeRootVisible,
                bottomBarHeight: bottomTabBarHeight,
                safeAreaBottom: safeAreaBottom
            ),
            hiddenOffset: hiddenOffset
        )
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

    func publishVisualOffsetsIfNeeded(_ updated: ScrollChromeOffsets) {
        guard ScrollChromeLayout.shouldPublishVisualOffsets(updated, over: offsets) else { return }
        offsets = ScrollChromeLayout.publishedVisualOffsets(from: updated)
    }
}

final class ScrollChromeTracker {
    private var state = ScrollChromeOffsets()

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
    static let defaultValue = FloatingComposeButtonLayout.defaultBottomTabBarHeight
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

struct ScrollChromeLayout {
    static let defaultTopBarHeight: CGFloat = 55
    static let topOfFeedRestoreThreshold: CGFloat = 8
    static let visualOffsetPublishThreshold: CGFloat = 0.5

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

    static func topHiddenOffset(
        topBarHeight: CGFloat,
        safeAreaTop: CGFloat
    ) -> CGFloat {
        max(0, topBarHeight) + max(0, safeAreaTop)
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

    static func feedContentPadding(
        topBarHeight: CGFloat,
        topBarOffset: CGFloat = 0,
        bottomBarHeight: CGFloat,
        safeAreaBottom: CGFloat,
        bottomBarVisibleFraction: CGFloat = 1
    ) -> ScrollChromeContentPadding {
        let visibleTopBarHeight = max(0, topBarHeight)
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

    static func chromeHitTestingEnabled(
        offset: CGFloat,
        hiddenOffset: CGFloat
    ) -> Bool {
        let hiddenOffset = max(0, hiddenOffset)
        guard hiddenOffset > 0 else { return true }
        return abs(offset) < hiddenOffset * 0.5
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
                (selectedTab != .activity || !wasActivityRootVisible)
        )
    }
}
