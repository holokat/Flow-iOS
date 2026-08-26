import SwiftUI

struct DMsView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @ObservedObject private var followStore = FollowStore.shared

    @StateObject private var store = HaloLinkStore()
    @State private var activeTab: HaloLinkInboxTab = .conversations
    @State private var navigationPath: [HaloLinkThreadRoute] = []
    @State private var isShowingNewConversationSheet = false
    @Binding private var isRootVisible: Bool
    @Binding private var pendingParticipantPubkey: String?
    private let onRequestAccountAccess: () -> Void

    init(
        isRootVisible: Binding<Bool> = .constant(true),
        pendingParticipantPubkey: Binding<String?> = .constant(nil),
        onRequestAccountAccess: @escaping () -> Void = {}
    ) {
        _isRootVisible = isRootVisible
        _pendingParticipantPubkey = pendingParticipantPubkey
        self.onRequestAccountAccess = onRequestAccountAccess
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                appSettings.themePalette.background
                    .ignoresSafeArea()

                if auth.currentAccount == nil {
                    signedOutState
                } else if auth.currentNsec == nil {
                    noSignerState
                } else {
                    mainContent
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: HaloLinkThreadRoute.self) { route in
                HaloLinkThreadView(route: route, store: store)
                    .environmentObject(appSettings)
                    .environmentObject(auth)
            }
        }
        .flowInteractiveBackSwipe()
        .sheet(isPresented: $isShowingNewConversationSheet) {
            HaloLinkNewConversationSheet(store: store) { route in
                openThread(route)
            }
            .environmentObject(appSettings)
            .environmentObject(auth)
            .environmentObject(relaySettings)
        }
        .onAppear {
            notifyRootVisibilityChanged()
            openPendingThreadIfPossible()
        }
        .onChange(of: navigationPath.count) { _, _ in
            notifyRootVisibilityChanged()
        }
        .task {
            configureStore()
        }
        .onChange(of: auth.currentAccount?.pubkey) { _, _ in
            configureStore()
        }
        .onChange(of: auth.currentNsec) { _, _ in
            configureStore()
            openPendingThreadIfPossible()
        }
        .onChange(of: pendingParticipantPubkey) { _, _ in
            openPendingThreadIfPossible()
        }
        .onChange(of: relaySettings.readRelays) { _, _ in
            configureStore()
        }
        .onChange(of: relaySettings.writeRelays) { _, _ in
            configureStore()
        }
        .onChange(of: relaySettings.inboxRelays) { _, _ in
            configureStore()
        }
        .onChange(of: followStore.followedPubkeys) { _, _ in
            configureStore()
        }
        .tint(appSettings.primaryColor)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header

            FlowNativeGlassSegmentedPicker(
                selection: $activeTab,
                items: HaloLinkInboxTab.allCases,
                title: { $0.title }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
                        errorCard(errorMessage)
                    }

                    if store.isLoading && store.conversations.isEmpty {
                        loadingCard
                    } else if visibleConversations.isEmpty {
                        emptyCard
                    } else {
                        conversationList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
                .flowPeerTabContentTransition(selection: activeTab)
            }
        }
        .flowHorizontalPaging(
            selection: $activeTab,
            items: HaloLinkInboxTab.allCases
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Messages")
                .font(appSettings.appFont(.largeTitle, weight: .bold))
                .foregroundStyle(appSettings.themePalette.foreground)

            Spacer(minLength: 12)

            Button {
                store.markAllAsRead()
            } label: {
                Image(systemName: "envelope.open")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        store.unreadMessageCount > 0
                            ? appSettings.themeIconAccentColor
                            : appSettings.themePalette.tertiaryForeground
                    )
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark all as read")
            .disabled(store.unreadMessageCount == 0)

            Button {
                isShowingNewConversationSheet = true
            } label: {
                Label("New", systemImage: "plus")
                    .font(appSettings.appFont(.headline, weight: .semibold))
            }
            .haloNativeGlassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleConversations.enumerated()), id: \.element.id) { index, conversation in
                HaloLinkConversationRow(
                    conversation: conversation,
                    store: store,
                    timestampText: relativeTimestamp(for: conversation.lastMessageDate),
                    onOpen: {
                        openThread(HaloLinkThreadRoute(participantPubkeys: conversation.participantPubkeys))
                    },
                    onMarkAsRead: {
                        store.markConversationAsRead(conversation.id)
                    },
                    onDismiss: {
                        store.dismissConversation(conversation.id)
                    }
                )

                if index < visibleConversations.count - 1 {
                    Divider()
                        .overlay(appSettings.themePalette.separator)
                        .padding(.leading, 78)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
    }

    private var visibleConversations: [HaloLinkConversation] {
        switch activeTab {
        case .conversations:
            return store.activeConversations
        case .requests:
            return store.requests
        }
    }

    private var signedOutState: some View {
        HaloLinkInfoState(
            iconName: "bubble.left.and.bubble.right",
            title: "Sign in to use Halo Link",
            message: "Keep private conversations, reactions, photos, and videos together.",
            actionTitle: "Sign in",
            action: onRequestAccountAccess
        )
    }

    private var noSignerState: some View {
        HaloLinkInfoState(
            iconName: "key.fill",
            title: "Add account access",
            message: "This account can browse. Add access to read and send private messages.",
            actionTitle: "Continue",
            action: onRequestAccountAccess
        )
    }

    private func openPendingThreadIfPossible() {
        guard auth.currentNsec != nil,
              let pendingParticipantPubkey else {
            return
        }

        let normalizedPubkey = pendingParticipantPubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedPubkey.isEmpty else {
            self.pendingParticipantPubkey = nil
            return
        }

        navigationPath.removeAll()
        openThread(HaloLinkThreadRoute(participantPubkeys: [normalizedPubkey]))
        self.pendingParticipantPubkey = nil
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)

            Text("Checking for messages...")
                .font(appSettings.appFont(.headline, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: activeTab == .conversations ? "bubble.left.and.bubble.right" : "tray")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            Text(activeTab == .conversations ? "No conversations yet" : "No requests right now")
                .font(appSettings.appFont(.headline, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)

            Text(
                activeTab == .conversations
                    ? "Start a new Halo Link chat or wait for someone to message you."
                    : "Incoming message requests will show up here until you reply or dismiss them."
            )
            .font(appSettings.appFont(.subheadline))
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(appSettings.themePalette.warningForeground)

            Text(message)
                .font(appSettings.appFont(.footnote))
                .foregroundStyle(appSettings.themePalette.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
    }

    private func configureStore() {
        store.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: relaySettings.readRelayURLs,
            writeRelayURLs: relaySettings.writeRelayURLs,
            inboxRelayURLs: relaySettings.inboxRelayURLs,
            followedPubkeys: followStore.followedPubkeys
        )
    }

    private func openThread(_ route: HaloLinkThreadRoute) {
        store.markConversationAsRead(route.id)
        navigationPath.append(route)
        isShowingNewConversationSheet = false
    }

    private func notifyRootVisibilityChanged() {
        isRootVisible = navigationPath.isEmpty
    }

    private func relativeTimestamp(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct HaloLinkConversationRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let conversation: HaloLinkConversation
    @ObservedObject var store: HaloLinkStore
    let timestampText: String
    let onOpen: () -> Void
    let onMarkAsRead: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 12) {
                    HaloLinkConversationAvatarStrip(
                        participantPubkeys: conversation.participantPubkeys,
                        store: store
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(title)
                                .font(appSettings.appFont(.headline, weight: .semibold))
                                .foregroundStyle(appSettings.themePalette.foreground)
                                .lineLimit(1)

                            if conversation.unreadCount > 0 {
                                Circle()
                                    .fill(appSettings.primaryColor)
                                    .frame(width: 7, height: 7)
                            }
                        }

                        Text(conversation.lastMessagePreview)
                            .font(appSettings.appFont(.subheadline))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(timestampText)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Menu {
                if conversation.unreadCount > 0 {
                    Button("Mark as Read", systemImage: "checkmark") {
                        onMarkAsRead()
                    }
                }

                Button(
                    conversation.isRequest ? "Dismiss Request" : "Hide Conversation",
                    systemImage: "eye.slash"
                ) {
                    onDismiss()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var title: String {
        let names = conversation.participantPubkeys.map(store.displayName(for:))
        if names.isEmpty {
            return "Unknown"
        }
        if names.count == 1 {
            return names[0]
        }
        if names.count == 2 {
            return names.joined(separator: ", ")
        }
        return "\(names[0]), \(names[1]) +\(names.count - 2)"
    }
}

private struct HaloLinkConversationAvatarStrip: View {
    let participantPubkeys: [String]
    @ObservedObject var store: HaloLinkStore

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(Array(participantPubkeys.prefix(2)).enumerated()), id: \.element) { index, pubkey in
                AvatarView(
                    url: store.avatarURL(for: pubkey),
                    fallback: store.displayName(for: pubkey),
                    size: 42
                )
                .offset(x: CGFloat(index) * 20)
            }
        }
        .frame(width: participantPubkeys.count > 1 ? 62 : 42, height: 42, alignment: .leading)
    }
}

private struct HaloLinkInfoState: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let iconName: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        iconName: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.iconName = iconName
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .flowHierarchyEntrance(index: 0)

            VStack(spacing: 8) {
                Text(title)
                    .font(appSettings.appFont(.title3, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)

                Text(message)
                    .font(appSettings.appFont(.subheadline))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .flowHierarchyEntrance(index: 1)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .haloNativeGlassButtonStyle(.prominent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .flowHierarchyEntrance(index: 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct HaloLinkNewConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @ObservedObject private var followStore = FollowStore.shared

    @ObservedObject var store: HaloLinkStore
    let onOpenThread: (HaloLinkThreadRoute) -> Void

    @StateObject private var searchViewModel: SearchViewModel
    @State private var selectedRecipientPubkeys: [String] = []

    @State private var selectedProfilesByPubkey: [String: SearchViewModel.ProfileMatch] = [:]

    init(store: HaloLinkStore, onOpenThread: @escaping (HaloLinkThreadRoute) -> Void) {
        let initialRelayURL = URL(
            string: RelaySettingsStore.defaultReadRelayURLs.first ?? "wss://relay.damus.io/"
        )!
        _searchViewModel = StateObject(
            wrappedValue: SearchViewModel(
                relayURL: initialRelayURL,
                trendingNotesLoader: { _, _, _, _, _ in [] },
                supportsContentSearch: false
            )
        )
        self.store = store
        self.onOpenThread = onOpenThread
    }

    var body: some View {
        let visibleProfiles = displayedProfiles

        NavigationStack {
            List {
                if !selectedRecipientPubkeys.isEmpty {
                    Section("To") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedRecipientPubkeys, id: \.self) { pubkey in
                                    Button {
                                        selectedRecipientPubkeys.removeAll { $0 == pubkey }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(displayName(for: pubkey))
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .font(appSettings.appFont(.subheadline, weight: .medium))
                                    }
                                    .haloNativeGlassButtonStyle()
                                    .buttonBorderShape(.capsule)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(appSettings.themePalette.sheetCardBackground)
                    }
                }

                if searchViewModel.isLoading && visibleProfiles.isEmpty {
                    ForEach(0..<6, id: \.self) { _ in
                        SearchLoadingRow()
                            .searchListRow(horizontalInset: 16, verticalInset: 0)
                    }
                } else if visibleProfiles.isEmpty {
                    SearchEmptyStateSection(
                        errorMessage: searchViewModel.errorMessage,
                        isSearching: searchViewModel.isSearching,
                        searchText: searchViewModel.searchText
                    ) {
                        Task {
                            await searchViewModel.refresh()
                        }
                    }
                    .searchListRow(horizontalInset: 16, verticalInset: 18)
                } else {
                    Section {
                        ForEach(visibleProfiles) { profile in
                            HaloLinkRecipientSearchRow(
                                profile: profile,
                                isSelected: selectedRecipientPubkeys.contains(profile.pubkey.lowercased())
                            ) {
                                toggleSelection(for: profile)
                            }
                            .searchListRow(
                                horizontalInset: 16,
                                separatorVisibility: .visible,
                                separatorTint: appSettings.themePalette.chromeBorder
                            )
                        }
                    } header: {
                        SearchSectionHeader(title: searchViewModel.isSearching ? "People" : "Suggestions")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(appSettings.themePalette.groupedBackground)
            .safeAreaInset(edge: .top, spacing: 0) {
                SearchBarSection(
                    searchText: $searchViewModel.searchText,
                    placeholder: "Search people"
                ) {
                    Task {
                        await searchViewModel.refresh()
                    }
                }
            }
            .refreshable {
                configureSearch()
                await searchViewModel.refresh()
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(actionButtonTitle) {
                        let route = HaloLinkThreadRoute(participantPubkeys: selectedRecipientPubkeys)
                        onOpenThread(route)
                        dismiss()
                    }
                    .disabled(selectedRecipientPubkeys.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            configureSearch()
            await searchViewModel.loadIfNeeded()
        }
        .onChange(of: searchViewModel.searchText) { _, newValue in
            searchViewModel.handleSearchTextChanged()
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task {
                    await searchViewModel.loadIfNeeded()
                }
            }
        }
        .onChange(of: auth.currentAccount?.pubkey) { _, _ in
            configureSearch()
            Task {
                await searchViewModel.loadIfNeeded()
            }
        }
        .onChange(of: auth.currentNsec) { _, _ in
            configureSearch()
        }
        .onChange(of: followStore.followedPubkeys) { _, _ in
            configureSearch(invalidatePopularProfiles: false)
        }
        .onChange(of: relaySettings.readRelays) { _, _ in
            configureSearch()
            Task {
                await searchViewModel.loadIfNeeded()
            }
        }
    }

    private var actionButtonTitle: String {
        store.conversation(for: selectedRecipientPubkeys) == nil ? "Start" : "Open"
    }

    private var displayedProfiles: [SearchViewModel.ProfileMatch] {
        searchViewModel.displayedProfiles.filter { profile in
            let normalizedPubkey = profile.pubkey.lowercased()
            guard !normalizedPubkey.isEmpty else { return false }
            guard normalizedPubkey != auth.currentAccount?.pubkey.lowercased() else { return false }
            return true
        }
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private func configureSearch(invalidatePopularProfiles: Bool = true) {
        searchViewModel.updateSearchContext(
            currentAccountPubkey: auth.currentAccount?.pubkey,
            currentNsec: auth.currentNsec,
            followedPubkeys: Array(followStore.followedPubkeys),
            invalidatePopularProfiles: invalidatePopularProfiles
        )
        searchViewModel.updateReadRelayURLs(effectiveReadRelayURLs)
    }

    private func toggleSelection(for profile: SearchViewModel.ProfileMatch) {
        let normalizedPubkey = profile.pubkey.lowercased()
        if selectedRecipientPubkeys.contains(normalizedPubkey) {
            selectedRecipientPubkeys.removeAll { $0 == normalizedPubkey }
            selectedProfilesByPubkey.removeValue(forKey: normalizedPubkey)
        } else {
            selectedRecipientPubkeys.append(normalizedPubkey)
            selectedProfilesByPubkey[normalizedPubkey] = profile
        }
    }

    private func displayName(for pubkey: String) -> String {
        if let profile = selectedProfilesByPubkey[pubkey]?.displayName {
            return profile
        }
        return store.displayName(for: pubkey)
    }
}

private struct HaloLinkRecipientSearchRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let profile: SearchViewModel.ProfileMatch
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 12) {
                AvatarView(url: profile.avatarURL, fallback: profile.displayName, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(appSettings.appFont(.body, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(1)

                    Text(profile.handle)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? appSettings.themeIconAccentColor
                            : appSettings.themePalette.tertiaryForeground
                    )
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Remove \(profile.displayName)" : "Add \(profile.displayName)")
    }
}
