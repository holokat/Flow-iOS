import NostrSDK
import SwiftUI

struct ActivityView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore

    @ObservedObject var viewModel: ActivityViewModel
    @ObservedObject private var muteStore = MuteStore.shared
    @ObservedObject private var mutedThreadStore = MutedThreadStore.shared
    @ObservedObject private var followStore = FollowStore.shared
    @State private var isShowingAuthSheet = false
    @State private var authSheetInitialTab: AuthSheetTab = .signIn
    @State private var authSheetPresentationID = UUID()
    @State private var isShowingSideMenu = false
    @State private var isShowingSettings = false
    @State private var isShowingNotificationSettings = false
    @State private var selectedThreadRoute: ActivityThreadRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var topNavAvatarURL: URL?
    @State private var topNavAvatarImage: UIImage?
    @StateObject private var settingsSheetState = SettingsSheetState()
    @Binding private var isRootVisible: Bool
    private let isTabActive: Bool

    init(
        viewModel: ActivityViewModel,
        isRootVisible: Binding<Bool> = .constant(true),
        isTabActive: Bool = true
    ) {
        self.viewModel = viewModel
        _isRootVisible = isRootVisible
        self.isTabActive = isTabActive
    }

    var body: some View {
        let _ = appSettings.activityNotificationPreferenceSignature
        let _ = appSettings.spamReplyFilterSignature

        NavigationStack {
            GeometryReader { geometry in
                let safeAreaTop = max(0, geometry.safeAreaInsets.top)

                SideMenuContainer(
                    isOpen: $isShowingSideMenu,
                    topSafeAreaInset: safeAreaTop,
                    menuBackground: HomeSlideoutMenuStyle.background(
                        appSettings: appSettings,
                        colorScheme: colorScheme
                    ),
                    allowsOpeningGesture: viewModel.selectedFilter == ActivityFilter.allCases.first
                ) {
                    sideMenuContent
                } content: {
                    ZStack(alignment: .leading) {
                        AppThemeBackgroundView()
                            .ignoresSafeArea()

                        VStack(spacing: 0) {
                            topNavigationBar

                            List {
                                Section {
                                    FlowCapsuleTabBar(
                                        selection: $viewModel.selectedFilter,
                                        items: ActivityFilter.allCases,
                                        title: { $0.title }
                                    )
                                    .accessibilityLabel("Pulse filter")
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)

                                if viewModel.isLoading && viewModel.items.isEmpty {
                                    ForEach(0..<5, id: \.self) { _ in
                                        loadingRow
                                            .listRowSeparator(.hidden)
                                            .listRowBackground(Color.clear)
                                    }
                                } else if viewModel.visibleItems.isEmpty {
                                    emptyStateRow
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                } else {
                                    ForEach(Array(viewModel.visibleItems.enumerated()), id: \.element.id) { index, item in
                                        let isMutedNotification = viewModel.isMutedNotification(item)
                                        ActivityRowCell(
                                            item: item,
                                            isMuted: isMutedNotification,
                                            onTap: {
                                                selectedThreadRoute = ActivityThreadRouting.route(
                                                    for: item,
                                                    revealMutedContent: isMutedNotification
                                                )
                                            },
                                            onAvatarTap: {
                                                selectedProfileRoute = ProfileRoute(pubkey: item.actorPubkey)
                                            }
                                        )
                                        .flowHierarchyEntrance(index: index)
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                        .listRowSeparatorTint(appSettings.themePalette.chromeBorder)
                                        .listRowBackground(Color.clear)
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .refreshable {
                                relaySettings.configure(
                                    accountPubkey: auth.currentAccount?.pubkey,
                                    nsec: auth.currentNsec
                                )
                                configureFollowStore()
                                configureMuteStore()
                                viewModel.configure(
                                    currentUserPubkey: auth.currentAccount?.pubkey,
                                    readRelayURLs: effectiveReadRelayURLs
                                )
                                await viewModel.refresh()
                            }
                        }
                        .padding(.top, safeAreaTop)
                    }
                    .flowHorizontalPaging(
                        selection: $viewModel.selectedFilter,
                        items: ActivityFilter.allCases,
                        handsLeadingBoundaryToParent: true
                    )
                }
                .toolbar(.hidden, for: .navigationBar)
                .task(id: isTabActive) {
                    guard isTabActive else { return }
                    relaySettings.configure(
                        accountPubkey: auth.currentAccount?.pubkey,
                        nsec: auth.currentNsec
                    )
                    configureFollowStore()
                    configureMuteStore()
                    configureMutedThreadStore()
                    viewModel.configure(
                        currentUserPubkey: auth.currentAccount?.pubkey,
                        readRelayURLs: effectiveReadRelayURLs
                    )
                    await viewModel.loadIfNeeded()
                }
                .onChange(of: auth.currentAccount?.pubkey) { _, newValue in
                    configureFollowStore()
                    configureMuteStore()
                    configureMutedThreadStore()
                    viewModel.configure(
                        currentUserPubkey: newValue,
                        readRelayURLs: effectiveReadRelayURLs
                    )
                }
                .onChange(of: auth.currentNsec) { _, _ in
                    configureFollowStore()
                    configureMuteStore()
                    configureMutedThreadStore()
                }
                .onChange(of: relaySettings.readRelays) { _, _ in
                    configureFollowStore()
                    configureMuteStore()
                    configureMutedThreadStore()
                    viewModel.configure(
                        currentUserPubkey: auth.currentAccount?.pubkey,
                        readRelayURLs: effectiveReadRelayURLs
                    )
                }
                .onChange(of: relaySettings.writeRelays) { _, _ in
                    configureFollowStore()
                    configureMuteStore()
                    configureMutedThreadStore()
                }
                .onChange(of: appSettings.slowConnectionMode) { _, _ in
                    configureFollowStore()
                    configureMuteStore()
                    configureMutedThreadStore()
                    viewModel.configure(
                        currentUserPubkey: auth.currentAccount?.pubkey,
                        readRelayURLs: effectiveReadRelayURLs
                    )
                    Task {
                        await viewModel.refresh()
                    }
                }
            .sheet(isPresented: $isShowingSettings, onDismiss: {
                settingsSheetState.reset()
            }) {
                SettingsView(sheetState: settingsSheetState)
                    .environmentObject(relaySettings)
            }
            .sheet(isPresented: $isShowingNotificationSettings) {
                notificationSettingsSheet
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
            .navigationDestination(item: $selectedThreadRoute) { route in
                ThreadDetailView(
                    initialItem: route.initialItem,
                    relayURL: viewModel.primaryRelayURL,
                    readRelayURLs: effectiveReadRelayURLs,
                    initialReplyScrollTargetID: route.initialReplyScrollTargetID
                )
            }
            .navigationDestination(item: $selectedProfileRoute) { route in
                ProfileView(
                    pubkey: route.pubkey,
                    relayURL: viewModel.primaryRelayURL,
                    readRelayURLs: effectiveReadRelayURLs,
                    writeRelayURLs: effectiveWriteRelayURLs
                )
            }
            .task(id: topNavAvatarLookupID) {
                await refreshTopNavAvatar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .profileMetadataUpdated)) { notification in
                guard let updatedPubkey = (notification.userInfo?["pubkey"] as? String)?.lowercased(),
                      let currentPubkey = auth.currentAccount?.pubkey.lowercased(),
                      updatedPubkey == currentPubkey else {
                    return
                }
                Task {
                    await refreshTopNavAvatar()
                }
            }
            .onAppear {
                notifyRootVisibilityChanged()
            }
            .onChange(of: selectedThreadRoute) { _, _ in
                notifyRootVisibilityChanged()
            }
            .onChange(of: selectedProfileRoute) { _, _ in
                notifyRootVisibilityChanged()
            }
            .onChange(of: muteStore.filterRevision) { _, _ in
                viewModel.notificationPreferencesChanged()
            }
            .onChange(of: mutedThreadStore.revision) { _, _ in
                viewModel.notificationPreferencesChanged()
            }
            .onChange(of: appSettings.spamReplyFilterSignature) { _, _ in
                viewModel.notificationPreferencesChanged()
            }
            .onChange(of: followStore.followedPubkeys) { _, _ in
                viewModel.notificationPreferencesChanged()
            }
            }
        }
        .flowInteractiveBackSwipe()
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

    private var topNavigationBar: some View {
        ZStack {
            Text("Pulse")
                .font(appSettings.appFont(.headline, weight: .semibold))
                .lineLimit(1)

            HStack {
                Button {
                    openSideMenu()
                } label: {
                    topNavAccountIcon
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open menu")

                Spacer()

                Button {
                    isShowingNotificationSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.mutedForeground)
                        .frame(width: 34, height: 34)
                        .background(topNavigationControlFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notification settings")
            }
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
        if effectiveChromeColorScheme == .light {
            Color.white
        } else if appSettings.activeTheme == .gamer {
            appSettings.themePalette.background
        } else if appSettings.activeTheme == .dracula {
            appSettings.themePalette.background
        } else {
            appSettings.themePalette.chromeBackground
        }
    }

    private var topNavigationControlFill: Color {
        if effectiveChromeColorScheme == .light {
            return Color.black.opacity(0.045)
        } else if appSettings.activeTheme == .gamer {
            return appSettings.themePalette.chromeBackground.opacity(0.84)
        }
        return appSettings.themePalette.navigationControlBackground
    }

    private var effectiveChromeColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
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

    private var notificationSettingsSheet: some View {
        NavigationStack {
            NotificationPreferencesView(
                navigationTitleText: "Pulse Settings",
                showsMutedNotifications: mutedNotificationsVisibilityBinding
            )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ThemedToolbarDoneButton {
                            isShowingNotificationSettings = false
                        }
                    }
                }
                .toolbarBackground(appSettings.themePalette.sheetBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.sheetBackground)
    }

    private var emptyStateRow: some View {
        VStack(spacing: 12) {
            if let errorMessage = viewModel.errorMessage {
                activityEmptyCopy(title: "Couldn’t refresh Pulse", message: errorMessage)
                activityEmptyAction("Try again", systemImage: "arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
            } else if viewModel.hasMutedNotificationsHidden {
                activityEmptyCopy(
                    title: "Some muted activity is hidden",
                    message: "You can review it from Pulse settings."
                )
                activityEmptyAction("Open Pulse settings", systemImage: "slider.horizontal.3") {
                    isShowingNotificationSettings = true
                }
            } else if viewModel.hasItemsHiddenByNotificationPreferences {
                activityEmptyCopy(
                    title: "Nothing matches your Pulse settings",
                    message: "Choose which activity you want to see and count as unread."
                )
                activityEmptyAction("Review settings", systemImage: "slider.horizontal.3") {
                    isShowingNotificationSettings = true
                }
            } else {
                activityEmptyCopy(
                    title: "No activity yet",
                    message: "Mentions, replies, reactions, and reshares will appear here."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private func activityEmptyCopy(title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.foreground)

            Text(message)
                .font(.footnote)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .multilineTextAlignment(.center)
        }
        .flowHierarchyEntrance(index: 0)
    }

    private func activityEmptyAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(appSettings.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(appSettings.buttonTextColor)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(appSettings.primaryGradient, in: Capsule(style: .continuous))
        }
        .buttonStyle(FlowPressScaleButtonStyle())
        .flowHierarchyEntrance(index: 1)
    }

    private var mutedNotificationsVisibilityBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showsMutedNotifications },
            set: { viewModel.setShowsMutedNotifications($0) }
        )
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 30, height: 30)

            Circle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 20, height: 20)

            RoundedRectangle(cornerRadius: 4)
                .fill(appSettings.themePalette.secondaryFill)
                .frame(height: 14)

            RoundedRectangle(cornerRadius: 4)
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 42, height: 12)
        }
        .padding(.vertical, 2)
        .redacted(reason: .placeholder)
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

    private var isShowingActivityRoot: Bool {
        selectedThreadRoute == nil && selectedProfileRoute == nil
    }

    private func notifyRootVisibilityChanged() {
        isRootVisible = isShowingActivityRoot
    }

    private func openProfile(pubkey: String) {
        selectedProfileRoute = ProfileRoute(pubkey: pubkey)
    }

    private func configureMuteStore() {
        muteStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
    }

    private func configureMutedThreadStore() {
        mutedThreadStore.configure(accountPubkey: auth.currentAccount?.pubkey)
    }

    private func configureFollowStore() {
        followStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
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

}

enum ActivityThreadRouting {
    static func route(
        for item: ActivityRow,
        revealMutedContent: Bool
    ) -> ActivityThreadRoute? {
        switch item.action {
        case .mention, .reply, .quoteShare:
            if revealMutedContent {
                return ActivityThreadRoute(
                    initialItem: FeedItem(
                        event: item.event,
                        profile: item.actorProfile,
                        replyTargetEvent: item.target.event,
                        replyTargetProfile: item.target.profile
                    ),
                    initialReplyScrollTargetID: nil
                )
            }

            if item.event.isReplyNote {
                let destinationEvent = item.target.event ?? item.event
                let shouldScrollToReply = destinationEvent.id.lowercased() != item.event.id.lowercased()
                return ActivityThreadRoute(
                    initialItem: FeedItem(
                        event: destinationEvent,
                        profile: profileForThreadDestination(event: destinationEvent, item: item)
                    ),
                    initialReplyScrollTargetID: shouldScrollToReply ? item.event.id.lowercased() : nil
                )
            }

            return ActivityThreadRoute(
                initialItem: FeedItem(event: item.event, profile: item.actorProfile),
                initialReplyScrollTargetID: nil
            )

        case .reaction:
            guard let destinationEvent = item.target.event else { return nil }
            return ActivityThreadRoute(
                initialItem: FeedItem(
                    event: destinationEvent,
                    profile: profileForThreadDestination(event: destinationEvent, item: item)
                ),
                initialReplyScrollTargetID: nil
            )

        case .reshare:
            let destinationEvent = item.target.event ?? item.event
            return ActivityThreadRoute(
                initialItem: FeedItem(
                    event: destinationEvent,
                    profile: profileForThreadDestination(event: destinationEvent, item: item)
                ),
                initialReplyScrollTargetID: nil
            )
        }
    }

    private static func profileForThreadDestination(event: NostrEvent, item: ActivityRow) -> NostrProfile? {
        if event.id.lowercased() == item.event.id.lowercased() {
            return item.actorProfile
        }
        return item.target.profile
    }
}

struct ActivityRowCell: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let item: ActivityRow
    let isMuted: Bool
    let onTap: (() -> Void)?
    let onAvatarTap: (() -> Void)?

    init(
        item: ActivityRow,
        isMuted: Bool = false,
        onTap: (() -> Void)? = nil,
        onAvatarTap: (() -> Void)? = nil
    ) {
        self.item = item
        self.isMuted = isMuted
        self.onTap = onTap
        self.onAvatarTap = onAvatarTap
    }

    var body: some View {
        Group {
            if isMuted {
                mutedRowView
            } else {
                HStack(spacing: 10) {
                    avatarView
                    rowBodyView
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mutedRowView: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    mutedRowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open muted notification")
                .accessibilityValue(
                    "\(RelativeTimestampFormatter.shortString(from: item.createdAtDate)) ago"
                )
                .accessibilityHint("Opens this item once without changing your mute settings.")
            } else {
                mutedRowContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mutedRowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .frame(width: 30, height: 30)
                .background(appSettings.themePalette.secondaryFill, in: Circle())

            HStack(spacing: 8) {
                Text("Muted item")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(RelativeTimestampFormatter.shortString(from: item.createdAtDate))
                    .font(.caption2)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatarView: some View {
        if let onAvatarTap {
            Button(action: onAvatarTap) {
                ActivityAvatarView(url: item.actor.avatarURL, fallback: avatarFallbackCharacter)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(item.actor.displayName)'s profile")
        } else {
            ActivityAvatarView(url: item.actor.avatarURL, fallback: avatarFallbackCharacter)
        }
    }

    @ViewBuilder
    private var rowBodyView: some View {
        if let onTap {
            Button(action: onTap) {
                rowBodyContent
            }
            .buttonStyle(.plain)
        } else {
            rowBodyContent
        }
    }

    private var rowBodyContent: some View {
        HStack(spacing: 10) {
            activityIndicator

            HStack(spacing: 8) {
                previewContent

                Spacer(minLength: 8)

                Text(RelativeTimestampFormatter.shortString(from: item.createdAtDate))
                    .font(.caption2)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch item.action {
        case .mention:
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appSettings.primaryColor)
                .frame(width: 20, height: 20)
                .background(appSettings.primaryColor.opacity(0.14), in: Circle())
        case .reply:
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appSettings.primaryColor)
                .frame(width: 20, height: 20)
                .background(appSettings.primaryColor.opacity(0.14), in: Circle())
        case .reaction(let reaction):
            if let customEmojiURL = reaction.customEmojiImageURL {
                CachedAsyncImage(url: customEmojiURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        fallbackReactionSymbol(for: reaction)
                    }
                }
                .frame(width: 20, height: 20)
            } else {
                fallbackReactionSymbol(for: reaction)
            }
        case .reshare:
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 20, height: 20)
                .background(Color.green.opacity(0.14), in: Circle())
        case .quoteShare:
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.14), in: Circle())
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.previewDisplay {
        case .text(let previewText):
            ActivitySnippetText(text: previewText)
        case .image(let imageURL, let authorPubkey):
            ActivityPreviewThumbnail(url: imageURL, authorPubkey: authorPubkey)
        case .mediaPlaceholder, .none:
            EmptyView()
        }
    }

    private var avatarFallbackCharacter: String {
        String(item.actor.displayName.prefix(1)).uppercased()
    }

    @ViewBuilder
    private func fallbackReactionSymbol(for reaction: ActivityReaction) -> some View {
        let value = reaction.displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "+" {
            Image(systemName: "heart.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 20, height: 20)
                .background(Color.pink.opacity(0.14), in: Circle())
        } else {
            Text(value)
                .font(.system(size: 16))
                .frame(width: 20, height: 20)
        }
    }
}

private struct ActivityPreviewThumbnail: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @ObservedObject private var followStore = FollowStore.shared

    let url: URL
    let authorPubkey: String
    @State private var revealsBlurredThumbnail = false

    var body: some View {
        Group {
            if shouldBlurThumbnail {
                blurredThumbnailContent
            } else {
                thumbnailContent
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(appSettings.themePalette.chromeBorder, lineWidth: 0.7)
        }
    }

    private var blurredThumbnailContent: some View {
        ZStack {
            thumbnailContent
                .compositingGroup()
                .blur(radius: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.2))
                }
                .allowsHitTesting(false)

            Image(systemName: "eye.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            revealsBlurredThumbnail = true
        }
        .accessibilityLabel("Reveal media")
    }

    private var thumbnailContent: some View {
        CachedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(appSettings.themePalette.tertiaryFill)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    }
            }
        }
    }

    private var shouldBlurThumbnail: Bool {
        guard appSettings.blurMediaFromUnfollowedAuthors else { return false }
        guard !revealsBlurredThumbnail else { return false }
        let normalizedAuthor = normalizedPubkey(authorPubkey)
        guard !normalizedAuthor.isEmpty else { return false }
        guard normalizedAuthor != normalizedPubkey(auth.currentAccount?.pubkey) else { return false }
        return !followStore.isFollowing(normalizedAuthor)
    }

    private func normalizedPubkey(_ pubkey: String?) -> String {
        pubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

private struct ActivitySnippetText: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    private struct MentionMetadataDecoder: MetadataCoding {}

    private let text: String
    private let tokens: [NoteContentToken]
    private let mentionIdentifiers: [String]

    @State private var mentionLabels: [String: String] = [:]

    init(text: String) {
        self.text = text
        self.tokens = NoteContentParser.tokenize(content: text)
        self.mentionIdentifiers = Self.collectMentionIdentifiers(tokens: tokens)
    }

    var body: some View {
        Text(attributedString)
            .font(.subheadline)
            .foregroundStyle(appSettings.themePalette.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            .task(id: text) {
                await resolveMentionLabelsIfNeeded()
            }
    }

    private var attributedString: AttributedString {
        var output = AttributedString()

        for token in tokens {
            var segment = AttributedString(displayValue(for: token))
            segment.font = .subheadline

            if token.type == .websocketURL {
                segment.foregroundColor = appSettings.themePalette.secondaryForeground
            }

            output += segment
        }

        return output
    }

    private func displayValue(for token: NoteContentToken) -> String {
        guard token.type == .nostrMention else {
            return token.value
        }

        let normalized = Self.normalizeMentionIdentifier(token.value)
        return mentionLabels[normalized] ?? "@\(Self.fallbackMentionToken(for: normalized))"
    }

    private func resolveMentionLabelsIfNeeded() async {
        guard !mentionIdentifiers.isEmpty else {
            await MainActor.run {
                mentionLabels = [:]
            }
            return
        }

        var resolved: [String: String] = [:]
        var pubkeyByIdentifier: [String: String] = [:]
        var pubkeys: [String] = []

        for identifier in mentionIdentifiers {
            resolved[identifier] = "@\(Self.fallbackMentionToken(for: identifier))"

            if let pubkey = Self.mentionedPubkey(from: identifier) {
                pubkeyByIdentifier[identifier] = pubkey
                pubkeys.append(pubkey)
            }
        }

        let uniquePubkeys = Array(Set(pubkeys))
        if !uniquePubkeys.isEmpty {
            var profilesByPubkey: [String: NostrProfile] = [:]
            let cached = await ProfileCache.shared.resolve(pubkeys: uniquePubkeys)
            profilesByPubkey.merge(cached.hits, uniquingKeysWith: { _, latest in latest })

            if !cached.missing.isEmpty {
                let relayURLs = await MainActor.run {
                    let relays = RelaySettingsStore.shared.readRelayURLs
                    return relays.isEmpty
                        ? RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
                        : relays
                }
                let fetched = await NostrFeedService().fetchProfiles(
                    relayURLs: relayURLs,
                    pubkeys: cached.missing
                )
                profilesByPubkey.merge(fetched, uniquingKeysWith: { existing, _ in existing })
            }

            for (identifier, pubkey) in pubkeyByIdentifier {
                guard let profile = profilesByPubkey[pubkey] else { continue }
                resolved[identifier] = mentionLabel(from: profile, pubkey: pubkey)
            }
        }

        await MainActor.run {
            mentionLabels = resolved
        }
    }

    private func mentionLabel(from profile: NostrProfile, pubkey: String) -> String {
        if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "@\(name)"
        }
        if let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return "@\(displayName)"
        }
        return "@\(Self.fallbackMentionToken(for: pubkey))"
    }

    private static func collectMentionIdentifiers(tokens: [NoteContentToken]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for token in tokens where token.type == .nostrMention {
            let normalized = normalizeMentionIdentifier(token.value)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private static func normalizeMentionIdentifier(_ raw: String) -> String {
        let lowered = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if lowered.hasPrefix("nostr:") {
            return String(lowered.dropFirst("nostr:".count))
        }
        return lowered
    }

    private static func mentionedPubkey(from identifier: String) -> String? {
        let normalized = normalizeMentionIdentifier(identifier)
        if normalized.hasPrefix("npub1") {
            return PublicKey(npub: normalized)?.hex.lowercased()
        }
        if normalized.hasPrefix("nprofile1") {
            let decoder = MentionMetadataDecoder()
            let metadata = try? decoder.decodedMetadata(from: normalized)
            return metadata?.pubkey?.lowercased()
        }
        return nil
    }

    private static func fallbackMentionToken(for identifier: String) -> String {
        if let pubkey = mentionedPubkey(from: identifier) {
            return String(pubkey.prefix(8))
        }

        let normalized = normalizeMentionIdentifier(identifier)
        if normalized.count > 14 {
            return "\(normalized.prefix(10))...\(normalized.suffix(4))"
        }
        return normalized
    }
}

private struct ActivityAvatarView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let url: URL?
    let fallback: String

    var body: some View {
        Group {
            if appSettings.textOnlyMode {
                fallbackAvatar
            } else if let url {
                CachedAsyncImage(url: url, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(appSettings.themePalette.separator, lineWidth: 0.5)
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle().fill(appSettings.themePalette.secondaryFill)
            Text(String(fallback.prefix(1)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }
}

struct ActivityThreadRoute: Identifiable, Hashable {
    let initialItem: FeedItem
    let initialReplyScrollTargetID: String?

    var id: String {
        "\(initialItem.id.lowercased()):\(initialReplyScrollTargetID ?? "")"
    }
}
