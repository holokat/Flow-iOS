import SwiftUI
import UIKit

enum ProfileViewLayout {
    static func followingCountText(
        isOwnProfile: Bool,
        ownFollowingCount: Int,
        remoteFollowingCount: Int,
        hasResolvedRemoteFollowingCount: Bool
    ) -> String {
        if isOwnProfile {
            return "\(max(ownFollowingCount, 0)) following"
        }
        guard hasResolvedRemoteFollowingCount else {
            return "following"
        }
        return "\(max(remoteFollowingCount, 0)) following"
    }
}

struct ProfileView: View {
    private static let feedHorizontalInset: CGFloat = 14
    private static let bottomScrollClearance: CGFloat = 110

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: ProfileViewModel

    private let reactionStats = NoteReactionStatsService.shared
    @StateObject private var engagementViewport = FeedEngagementViewportCoordinator()
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var muteStore = MuteStore.shared

    @State private var selectedThreadItem: FeedItem?
    @State private var selectedHashtagRoute: HashtagRoute?
    @State private var selectedProfileRoute: ProfileRoute?
    @State private var selectedRelayRoute: RelayRoute?
    @State private var selectedFollowingRoute: FollowingListRoute?
    @State private var isShowingProfileEditor = false
    @State private var isShowingConnectionsSheet = false
    @State private var isShowingProfileQR = false
    @State private var isShowingAvatarViewer = false
    @State private var shouldAutoFocusReplyInThread = false

    private var profileHeaderContent: ProfileHeaderContent {
        ProfileHeaderContent(
            displayName: viewModel.displayName,
            handle: viewModel.handle,
            about: viewModel.about,
            avatarURL: viewModel.avatarURL,
            bannerURL: viewModel.bannerURL,
            websiteURL: viewModel.websiteURL,
            websiteDisplayText: viewModel.websiteURL.map(websiteDisplayText(for:)),
            lightningAddress: viewModel.lightningAddress,
            followsCurrentUser: viewModel.followsCurrentUser,
            followingCountText: profileFollowingCountText,
            followStatusIconName: profileFollowStatusIconName,
            knownFollowers: isOwnProfile ? [] : viewModel.knownFollowers,
            actionMessage: actionMessage
        )
    }

    private var primaryActionDisabled: Bool {
        if isOwnProfile {
            return viewModel.isSavingProfile || auth.currentNsec == nil
        }
        return false
    }

    private var isOwnProfile: Bool {
        normalizePubkey(auth.currentAccount?.pubkey) == normalizePubkey(viewModel.pubkey)
    }

    private var actionMessage: String? {
        if let profileSaveError = viewModel.profileSaveError, !profileSaveError.isEmpty, !isShowingProfileEditor {
            return profileSaveError
        }
        if let muteError = muteStore.lastPublishError, !muteError.isEmpty {
            return muteError
        }
        if let followError = followStore.lastPublishError, !followError.isEmpty {
            return followError
        }
        return nil
    }

    private var displayedFollowingCount: Int {
        guard let currentPubkey = auth.currentAccount?.pubkey.lowercased(),
              currentPubkey == viewModel.pubkey.lowercased() else {
            return viewModel.followingCount
        }

        return followStore.followedPubkeys.count
    }

    private var profileFollowingCountText: String {
        ProfileViewLayout.followingCountText(
            isOwnProfile: isOwnProfile,
            ownFollowingCount: followStore.followedPubkeys.count,
            remoteFollowingCount: viewModel.followingCount,
            hasResolvedRemoteFollowingCount: viewModel.hasResolvedFollowingCount
        )
    }

    private var isInitialProfileMetadataLoading: Bool {
        viewModel.profile == nil && !viewModel.hasCompletedInitialLoad
    }

    private var profileBannerButtonForeground: Color {
        appSettings.themePalette.profileActionStyle?.bannerForeground ?? appSettings.themePalette.foreground
    }

    private var profileBannerButtonBorder: Color {
        appSettings.themePalette.profileActionStyle?.bannerBorder ?? appSettings.themePalette.separator.opacity(0.88)
    }

    private var profileBannerButtonBackground: Color {
        appSettings.themePalette.profileActionStyle?.bannerBackground ?? appSettings.themePalette.modalBackground
    }

    private var profileFollowStatusIconName: String? {
        guard !isOwnProfile else { return nil }
        return followStore.isFollowing(viewModel.pubkey)
            ? "checkmark.circle.fill"
            : "plus.circle.fill"
    }

    private var isProfileMuted: Bool {
        muteStore.isMuted(viewModel.pubkey)
    }

    private var profileMuteActionTitle: String {
        isProfileMuted ? "Unmute" : "Mute"
    }

    private var profileMuteActionSystemImage: String {
        isProfileMuted ? "speaker.wave.2" : "speaker.slash"
    }

    private var profileMuteActionDisabled: Bool {
        muteStore.isPublishing || auth.currentNsec == nil
    }

    private var isProfileMarkedSpam: Bool {
        appSettings.isSpamFilterMarked(viewModel.pubkey)
    }

    private var profileSpamActionTitle: String {
        isProfileMarkedSpam ? "Remove Spam Mark" : "Mark as Spam"
    }

    private var profileSpamActionSystemImage: String {
        isProfileMarkedSpam ? "checkmark.shield" : "exclamationmark.shield"
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: viewModel.readRelayURLs)
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(from: viewModel.writeRelayURLs, fallbackReadRelayURLs: effectiveReadRelayURLs)
    }

    private var effectivePrimaryRelayURL: URL {
        effectiveReadRelayURLs.first ?? AppSettingsStore.slowModeRelayURL
    }

    private var profileConnectionLookupRelayURLs: [URL] {
        let defaultRelays = (RelaySettingsStore.defaultReadRelayURLs + RelaySettingsStore.defaultWriteRelayURLs)
            .compactMap(URL.init(string:))
        return RelayURLSupport.normalizedRelayURLs(
            viewModel.readRelayURLs +
            viewModel.writeRelayURLs +
            effectiveReadRelayURLs +
            effectiveWriteRelayURLs +
            defaultRelays
        )
    }

    init(
        pubkey: String,
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        writeRelayURLs: [URL]? = nil,
        service: NostrFeedService = NostrFeedService()
    ) {
        _viewModel = StateObject(
            wrappedValue: ProfileViewModel(
                pubkey: pubkey,
                relayURL: relayURL,
                readRelayURLs: readRelayURLs,
                writeRelayURLs: writeRelayURLs,
                service: service
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let visibleItems = viewModel.visibleItems
            let visibleReplyCounts = ReplyCountEstimator.counts(for: visibleItems)
            let topSafeAreaInset = proxy.safeAreaInsets.top

            ZStack {
                AppThemeBackgroundView(holographicSpotlight: .profile)
                    .ignoresSafeArea()

                List {
                    Section {
                        ProfileHeaderSection(
                            isLoading: isInitialProfileMetadataLoading,
                            topSafeAreaInset: topSafeAreaInset,
                            content: profileHeaderContent,
                            onFollowingTap: {
                                selectedFollowingRoute = FollowingListRoute(pubkey: viewModel.pubkey)
                            },
                            onProfileTap: { pubkey in
                                openProfile(pubkey: pubkey)
                            },
                            onHashtagTap: { hashtag in
                                openHashtagFeed(hashtag: hashtag)
                            },
                            onRelayTap: { relayURL in
                                openRelayFeed(relayURL: relayURL)
                            },
                            onAvatarTap: {
                                isShowingAvatarViewer = true
                            },
                            backButton: {
                                profileBackButton
                            },
                            menuButton: {
                                profileMenuButton
                            },
                            actionRow: {
                                actionRow
                            }
                        )
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(
                        EdgeInsets(
                            top: 0,
                            leading: 0,
                            bottom: 0,
                            trailing: 0
                        )
                    )
                    .listRowBackground(Color.clear)

                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            FlowCapsuleTabBar(
                                selection: $viewModel.mode,
                                items: FeedMode.allCases,
                                title: { $0.title }
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    if viewModel.isLoading && visibleItems.isEmpty {
                        ForEach(0..<6, id: \.self) { _ in
                            ProfileFeedLoadingRow()
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
                        VStack(spacing: 8) {
                            if let errorMessage = viewModel.errorMessage {
                                Text(errorMessage)
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            } else {
                                Text(emptyStateText(for: viewModel.mode))
                                    .font(.body)
                                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
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
                                    viewModel.insertOptimisticPublishedItem(publishedItem)
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
                            .listRowSeparatorTint(appSettings.themePalette.separator)
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
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    await viewModel.refresh()
                    await viewModel.refreshFollowRelationship(currentAccountPubkey: auth.currentAccount?.pubkey)
                    await viewModel.refreshKnownFollowers(
                        currentAccountPubkey: auth.currentAccount?.pubkey,
                        followedPubkeys: followStore.followedPubkeys
                    )
                    muteStore.refreshFromRelay()
                }
            }
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .task {
            configureStores()
            await viewModel.loadIfNeeded()
            await viewModel.refreshFollowRelationship(currentAccountPubkey: auth.currentAccount?.pubkey)
            await viewModel.refreshKnownFollowers(
                currentAccountPubkey: auth.currentAccount?.pubkey,
                followedPubkeys: followStore.followedPubkeys
            )
        }
        .sheet(isPresented: $isShowingProfileEditor) {
            ProfileEditorSheet(
                initialFields: viewModel.editableFields,
                previewHandle: viewModel.handle,
                followingCount: viewModel.followingCount,
                isSaving: viewModel.isSavingProfile,
                errorMessage: viewModel.profileSaveError,
                onSave: { fields in
                    await viewModel.saveProfile(
                        fields: fields,
                        currentAccountPubkey: auth.currentAccount?.pubkey,
                        currentNsec: auth.currentNsec
                    )
                },
                onUploadAvatar: { data, mimeType, filename in
                    try await viewModel.uploadProfileImage(
                        data: data,
                        mimeType: mimeType,
                        filename: filename,
                        currentAccountPubkey: auth.currentAccount?.pubkey,
                        currentNsec: auth.currentNsec
                    )
                },
                onUploadBanner: { data, mimeType, filename in
                    try await viewModel.uploadProfileImage(
                        data: data,
                        mimeType: mimeType,
                        filename: filename,
                        currentAccountPubkey: auth.currentAccount?.pubkey,
                        currentNsec: auth.currentNsec
                    )
                }
            )
        }
        .sheet(isPresented: $isShowingConnectionsSheet) {
            ProfileConnectionsSheet(
                pubkey: viewModel.pubkey,
                displayName: viewModel.displayName,
                lookupRelayURLs: profileConnectionLookupRelayURLs,
                onOpenRelay: { relayURL in
                    isShowingConnectionsSheet = false
                    openRelayFeed(relayURL: relayURL)
                }
            )
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
        .navigationDestination(item: $selectedFollowingRoute) { route in
            FollowingListView(
                pubkey: route.pubkey,
                readRelayURLs: effectiveReadRelayURLs
            )
        }
        .sheet(isPresented: $isShowingProfileQR) {
            ProfileQRCodeSheet(
                npub: viewModel.npub,
                displayName: viewModel.displayName,
                handle: viewModel.handle,
                avatarURL: viewModel.avatarURL,
                onOpenProfile: { pubkey in
                    openProfile(pubkey: pubkey)
                }
            )
        }
        .fullScreenCover(isPresented: $isShowingAvatarViewer) {
            if let avatarURL = viewModel.avatarURL {
                ProfileAvatarFullscreenViewer(
                    url: avatarURL,
                    title: viewModel.displayName
                )
            }
        }
        .onChange(of: auth.currentAccount?.pubkey) { _, _ in
            configureStores()
            refreshFollowRelationship()
            refreshKnownFollowers()
        }
        .onChange(of: auth.currentNsec) { _, _ in
            configureStores()
        }
        .onChange(of: relaySettings.readRelays) { _, _ in
            configureStores()
            refreshFollowRelationship()
            refreshKnownFollowers()
        }
        .onChange(of: relaySettings.writeRelays) { _, _ in
            configureStores()
            refreshFollowRelationship()
            refreshKnownFollowers()
        }
        .onChange(of: appSettings.slowConnectionMode) { _, _ in
            configureStores()
            Task {
                await viewModel.refresh()
                await viewModel.refreshFollowRelationship(currentAccountPubkey: auth.currentAccount?.pubkey)
                await viewModel.refreshKnownFollowers(
                    currentAccountPubkey: auth.currentAccount?.pubkey,
                    followedPubkeys: followStore.followedPubkeys
                )
            }
        }
        .onChange(of: followStore.followedPubkeys) { _, _ in
            refreshKnownFollowers()
        }
        .onChange(of: viewModel.mode) { _, _ in
            Task {
                await viewModel.prepareForSelectedModeIfNeeded()
            }
        }
    }

    private var profileBackButton: some View {
        Button {
            dismiss()
        } label: {
            ProfileBannerCircleIcon(
                systemImage: "chevron.left",
                foreground: profileBannerButtonForeground,
                border: profileBannerButtonBorder,
                background: profileBannerButtonBackground
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if isOwnProfile {
                qrActionButton
                editProfileActionButton
            } else {
                muteActionButton
                dmActionButton
                qrActionButton
                followActionButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var dmActionButton: some View {
        ProfileActionIconButton(
            systemImage: "bubble.left.and.bubble.right",
            isPrimary: false,
            isDisabled: true,
            accessibilityLabel: "Direct Message",
            action: {}
        )
    }

    private var qrActionButton: some View {
        ProfileActionIconButton(
            systemImage: "qrcode",
            isPrimary: false,
            isDisabled: false,
            accessibilityLabel: "QR Code",
            action: {
                isShowingProfileQR = true
            }
        )
    }

    private var muteActionButton: some View {
        ProfileActionIconButton(
            systemImage: profileMuteActionSystemImage,
            isPrimary: false,
            isDisabled: profileMuteActionDisabled,
            accessibilityLabel: profileMuteActionTitle,
            action: {
                toggleProfileMute()
            }
        )
    }

    private var editProfileActionButton: some View {
        ProfileActionIconButton(
            systemImage: "square.and.pencil",
            isPrimary: false,
            isDisabled: primaryActionDisabled,
            accessibilityLabel: "Edit profile",
            action: primaryAction
        )
    }

    private var followActionButton: some View {
        ProfileActionIconButton(
            systemImage: followStore.isFollowing(viewModel.pubkey) ? "person.crop.circle.badge.checkmark" : "plus",
            isPrimary: !followStore.isFollowing(viewModel.pubkey),
            isDisabled: false,
            accessibilityLabel: followStore.isFollowing(viewModel.pubkey) ? "Following" : "Follow",
            action: primaryAction
        )
    }

    private var profileMenuButton: some View {
        Menu {
            if isOwnProfile {
                Button {
                    isShowingProfileEditor = true
                } label: {
                    ProfileMenuOptionLabel(title: "Edit Profile", systemImage: "square.and.pencil")
                }
            } else {
                Button {
                    followStore.toggleFollow(viewModel.pubkey)
                } label: {
                    ProfileMenuOptionLabel(
                        title: followStore.isFollowing(viewModel.pubkey) ? "Unfollow" : "Follow",
                        systemImage: followStore.isFollowing(viewModel.pubkey)
                            ? "person.crop.circle.badge.minus"
                            : "person.crop.circle.badge.plus"
                    )
                }

                Button {
                    toggleProfileMute()
                } label: {
                    ProfileMenuOptionLabel(
                        title: profileMuteActionTitle,
                        systemImage: profileMuteActionSystemImage
                    )
                }
                .disabled(profileMuteActionDisabled)

                Button {
                    toggleProfileSpamMark()
                } label: {
                    ProfileMenuOptionLabel(
                        title: profileSpamActionTitle,
                        systemImage: profileSpamActionSystemImage
                    )
                }
            }

            Button {
                isShowingConnectionsSheet = true
            } label: {
                ProfileMenuOptionLabel(title: "Connections", systemImage: "server.rack")
            }

            Button {
                copyNpubToPasteboard()
            } label: {
                ProfileMenuOptionLabel(title: "Copy ID", systemImage: "doc.on.doc")
            }

            if let websiteURL = viewModel.websiteURL {
                Link(destination: websiteURL) {
                    ProfileMenuOptionLabel(title: "Open Website", systemImage: "safari")
                }
            }
        } label: {
            ProfileBannerCircleIcon(
                systemImage: "ellipsis",
                foreground: profileBannerButtonForeground,
                border: profileBannerButtonBorder,
                background: profileBannerButtonBackground
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile options")
    }

    private func toggleProfileMute() {
        muteStore.toggleMute(viewModel.pubkey)
    }

    private func toggleProfileSpamMark() {
        if isProfileMarkedSpam {
            appSettings.removeSpamFilterMarkedPubkey(viewModel.pubkey)
            toastCenter.show("Removed spam mark", style: .info)
        } else {
            appSettings.addSpamFilterMarkedPubkey(viewModel.pubkey)
            toastCenter.show("Marked \(viewModel.displayName) as spam")
        }
    }

    private func primaryAction() {
        if isOwnProfile {
            isShowingProfileEditor = true
        } else {
            followStore.toggleFollow(viewModel.pubkey)
        }
    }

    private func copyNpubToPasteboard() {
        UIPasteboard.general.string = viewModel.npub
        toastCenter.show("Copied")
    }

    private func configureStores() {
        followStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
        muteStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
    }

    private func refreshFollowRelationship() {
        Task {
            await viewModel.refreshFollowRelationship(currentAccountPubkey: auth.currentAccount?.pubkey)
        }
    }

    private func refreshKnownFollowers() {
        Task {
            await viewModel.refreshKnownFollowers(
                currentAccountPubkey: auth.currentAccount?.pubkey,
                followedPubkeys: followStore.followedPubkeys
            )
        }
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

    private func emptyStateText(for mode: FeedMode) -> String {
        switch mode {
        case .posts:
            return "No posts yet"
        case .postsAndReplies:
            return "No replies yet"
        case .articles:
            return "No articles yet"
        }
    }

    private func openProfile(pubkey: String) {
        guard pubkey.lowercased() != viewModel.pubkey.lowercased() else { return }
        selectedProfileRoute = ProfileRoute(pubkey: pubkey)
    }

    private func openRelayFeed(relayURL: URL) {
        selectedRelayRoute = RelayRoute(relayURL: relayURL)
    }

    private func websiteDisplayText(for url: URL) -> String {
        if let host = url.host(), !host.isEmpty {
            return host.lowercased()
        }
        return url.absoluteString
    }

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private enum ProfileConnectionSourceTab: String, CaseIterable, Identifiable {
    case receive
    case publish
    case messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .receive:
            return "Receive"
        case .publish:
            return "Publish"
        case .messages:
            return "Messages"
        }
    }

    var emptyTitle: String {
        switch self {
        case .receive:
            return "No receive relays found"
        case .publish:
            return "No publish relays found"
        case .messages:
            return "No message relays found"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .receive:
            return "This user has not published receive relays yet."
        case .publish:
            return "This user has not published publishing relays yet."
        case .messages:
            return "This user has not published message relays yet."
        }
    }

    var relayScope: RelayScope {
        switch self {
        case .receive:
            return .read
        case .publish:
            return .write
        case .messages:
            return .inbox
        }
    }
}

private struct ProfileConnectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter

    let pubkey: String
    let displayName: String
    let lookupRelayURLs: [URL]
    let onOpenRelay: (URL) -> Void

    @State private var selectedTab: ProfileConnectionSourceTab = .receive
    @State private var snapshot = ProfileRelayConnectionsSnapshot.empty
    @State private var isLoading = false

    private let service = ProfileEventService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Relays for \(displayName)")
                        .font(appSettings.appFont(.title2, weight: .bold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    FlowCapsuleTabBar(
                        selection: $selectedTab,
                        items: ProfileConnectionSourceTab.allCases,
                        selectedBackground: appSettings.themePalette.secondaryBackground,
                        title: { $0.title }
                    )

                    Group {
                        if isLoading && selectedRelays.isEmpty {
                            loadingState
                        } else if selectedRelays.isEmpty {
                            emptyState
                        } else {
                            relayList
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .background(appSettings.themePalette.background)
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ThemedToolbarDoneButton {
                        dismiss()
                    }
                }
            }
            .task(id: loadID) {
                await loadConnections()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.background)
    }

    private var selectedRelays: [URL] {
        switch selectedTab {
        case .receive:
            return snapshot.readRelays
        case .publish:
            return snapshot.writeRelays
        case .messages:
            return snapshot.inboxRelays
        }
    }

    private var loadID: String {
        let relaySignature = lookupRelayURLs
            .compactMap { RelayURLSupport.normalizedRelayURLString($0) }
            .joined(separator: ",")
        return "\(pubkey.lowercased())|\(relaySignature)"
    }

    private var relayList: some View {
        VStack(spacing: 0) {
            ForEach(Array(selectedRelays.enumerated()), id: \.element.absoluteString) { index, relayURL in
                ProfileConnectionRelayRow(
                    relayName: RelayURLSupport.displayName(for: relayURL),
                    isAdded: relayIsAdded(relayURL),
                    onOpen: {
                        onOpenRelay(relayURL)
                    },
                    onAdd: {
                        addRelay(relayURL)
                    }
                )

                if index < selectedRelays.count - 1 {
                    Divider()
                        .overlay(appSettings.themePalette.separator.opacity(0.8))
                        .padding(.leading, 48)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Checking relays...")
                .font(appSettings.appFont(.body, weight: .medium))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedTab.emptyTitle)
                .font(appSettings.appFont(.headline, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)

            Text(selectedTab.emptySubtitle)
                .font(appSettings.appFont(.subheadline))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
    }

    private func loadConnections() async {
        isLoading = true
        let loaded = await service.fetchRelayConnectionsSnapshot(
            relayURLs: lookupRelayURLs,
            pubkey: pubkey
        )
        snapshot = loaded
        isLoading = false
    }

    private func relayIsAdded(_ relayURL: URL) -> Bool {
        guard let key = RelayURLSupport.normalizedRelayURLString(relayURL) else { return false }

        switch selectedTab {
        case .receive:
            return relaySettings.readRelays.contains(key)
        case .publish:
            return relaySettings.writeRelays.contains(key)
        case .messages:
            return relaySettings.inboxRelays.contains(key)
        }
    }

    private func addRelay(_ relayURL: URL) {
        guard let key = RelayURLSupport.normalizedRelayURLString(relayURL) else { return }

        do {
            try relaySettings.addRelay(key, scope: selectedTab.relayScope)
            toastCenter.show("Added")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toastCenter.show(message, style: .error)
        }
    }
}

private struct ProfileConnectionRelayRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let relayName: String
    let isAdded: Bool
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appSettings.primaryColor)
                        .frame(width: 22)

                    Text(relayName)
                        .font(appSettings.appFont(.body, weight: .medium))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(1)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(relayName)")

            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appSettings.primaryColor)
                    .accessibilityLabel("\(relayName) added")
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appSettings.primaryColor)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(relayName)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}
