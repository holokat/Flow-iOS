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

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @Environment(\.flowScrollChromeStore) private var flowScrollChromeStore
    @Environment(\.flowBottomTabBarHeight) private var flowBottomTabBarHeight
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
    @State private var muteReasonEditorMode: MuteReasonEditorMode?
    @State private var isCompactProfileHeaderVisible = false
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
            followsCurrentUser: viewModel.followsCurrentUser,
            followingCountText: profileFollowingCountText,
            knownFollowers: isOwnProfile ? [] : viewModel.knownFollowers,
            actionMessage: actionMessage
        )
    }

    private var primaryActionDisabled: Bool {
        if isOwnProfile {
            return viewModel.isSavingProfile
        }
        return false
    }

    private var isOwnProfile: Bool {
        normalizePubkey(auth.currentAccount?.pubkey) == normalizePubkey(viewModel.pubkey)
    }

    private var actionMessage: String? {
        if let profileSaveError = viewModel.profileSaveError, !profileSaveError.isEmpty, !isShowingProfileEditor {
            return UserFacingCopy.sanitizingTechnicalTerms(profileSaveError)
        }
        if let muteError = muteStore.lastPublishError, !muteError.isEmpty {
            return UserFacingCopy.sanitizingTechnicalTerms(muteError)
        }
        if let followError = followStore.lastPublishError, !followError.isEmpty {
            return UserFacingCopy.sanitizingTechnicalTerms(followError)
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

    private var isProfileMuted: Bool {
        muteStore.isMuted(viewModel.pubkey)
    }

    private var profileMuteReason: String? {
        muteStore.muteReason(for: viewModel.pubkey)
    }

    private var profileMuteButtonTitle: String {
        isProfileMuted ? "Muted" : "Mute"
    }

    private var profileMuteActionTitle: String {
        isProfileMuted ? "Unmute" : "Mute"
    }

    private var profileMuteActionSystemImage: String {
        isProfileMuted ? "speaker.wave.2" : "speaker.slash"
    }

    private var profileMuteActionDisabled: Bool {
        muteStore.isPublishing
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
            let safeAreaBottom = max(0, proxy.safeAreaInsets.bottom)
            let bottomScrollClearance = profileBottomScrollClearance(safeAreaBottom: safeAreaBottom)

            ZStack(alignment: .top) {
                AppThemeBackgroundView()
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

                    if isProfileMuted && !isOwnProfile {
                        Section {
                            MutedProfileReasonCard(
                                reason: profileMuteReason,
                                onEdit: {
                                    muteReasonEditorMode = .edit
                                }
                            )
                        }
                        .listRowInsets(
                            EdgeInsets(
                                top: 10,
                                leading: Self.feedHorizontalInset,
                                bottom: 6,
                                trailing: Self.feedHorizontalInset
                            )
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            FlowNativeGlassSegmentedPicker(
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
                            .frame(height: bottomScrollClearance)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .ignoresSafeArea(edges: [.top, .bottom])
                .refreshable {
                    await refreshProfileScreenData()
                    muteStore.refreshFromRelay()
                }
                .modifier(
                    ProfileScrollChromeModifier(
                        scrollChromeStore: flowScrollChromeStore,
                        bottomTabBarHeight: flowBottomTabBarHeight,
                        safeAreaBottom: safeAreaBottom,
                        compactHeaderThreshold: max(
                            120,
                            ProfileHeaderBannerMetrics.height - topSafeAreaInset - 72
                        ),
                        onCompactHeaderVisibilityChange: { isVisible in
                            isCompactProfileHeaderVisible = isVisible
                        }
                    )
                )

                if isCompactProfileHeaderVisible {
                    compactProfileHeader(topSafeAreaInset: topSafeAreaInset)
                        .transition(
                            accessibilityReduceMotion
                                ? .identity
                                : .opacity.combined(with: .move(edge: .top))
                        )
                        .zIndex(3)
                }
            }
            .animation(
                accessibilityReduceMotion
                    ? nil
                    : .spring(response: 0.38, dampingFraction: 0.88),
                value: isCompactProfileHeaderVisible
            )
            .flowHorizontalPaging(
                selection: $viewModel.mode,
                items: FeedMode.allCases
            )
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .flowInteractiveBackSwipe()
        .task {
            configureStores()
            await loadInitialProfileScreenData()
            await HaloSystemIndexer.recordProfile(
                pubkey: viewModel.pubkey,
                displayName: viewModel.displayName,
                handle: viewModel.handle,
                avatarURL: viewModel.avatarURL
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
        .sheet(item: $muteReasonEditorMode) { mode in
            MuteReasonSheetView(
                displayName: viewModel.displayName,
                initialReason: mode == .edit ? profileMuteReason : nil,
                mode: mode
            ) { reason in
                completeProfileMuteReason(mode: mode, reason: reason)
            }
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
                await refreshProfileScreenData()
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

    private func profileBottomScrollClearance(safeAreaBottom: CGFloat) -> CGFloat {
        return ScrollChromeLayout.feedContentPadding(
            topBarHeight: 0,
            bottomBarHeight: flowBottomTabBarHeight,
            safeAreaBottom: safeAreaBottom
        ).bottom
    }

    private var profileBackButton: some View {
        Button {
            dismiss()
        } label: {
            ProfileBannerCircleIcon(
                systemImage: "chevron.left",
                foreground: profileBannerButtonForeground
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private func compactProfileHeader(topSafeAreaInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: topSafeAreaInset)

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                        .haloNativeGlass(interactive: true, in: Circle())
                }
                .buttonStyle(FlowPressScaleButtonStyle())
                .accessibilityLabel("Back")

                AvatarView(
                    url: viewModel.avatarURL,
                    fallback: viewModel.displayName,
                    size: 32
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.displayName)
                        .font(appSettings.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(1)

                    Text(viewModel.handle)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                profileMenuButton
            }
            .padding(.horizontal, 8)
            .frame(height: 54)
        }
        .frame(maxWidth: .infinity)
        .background(appSettings.themePalette.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(appSettings.themePalette.separator.opacity(0.7))
                .frame(height: 0.7)
        }
        .ignoresSafeArea(edges: .top)
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
            isDisabled: false,
            accessibilityLabel: "Direct Message",
            action: {
                NotificationCenter.default.post(
                    name: .flowOpenHaloLinkConversation,
                    object: nil,
                    userInfo: ["pubkey": viewModel.pubkey]
                )
            }
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
        ProfileActionTextButton(
            title: profileMuteButtonTitle,
            minimumWidth: 40,
            isPrimary: false,
            isSelected: isProfileMuted,
            isDisabled: profileMuteActionDisabled,
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
        let isFollowing = followStore.isFollowing(viewModel.pubkey)

        return ProfileActionTextButton(
            title: isFollowing ? "Following" : "Follow",
            minimumWidth: 60,
            isPrimary: !isFollowing,
            isSelected: isFollowing,
            isDisabled: false,
            action: primaryAction
        )
        .followCelebration(
            trigger: followStore.followCelebrationToken(for: viewModel.pubkey),
            accentColor: appSettings.primaryColor
        )
    }

    private var profileMenuButton: some View {
        Menu {
            if isOwnProfile {
                Button {
                    primaryAction()
                } label: {
                    ProfileMenuOptionLabel(title: "Edit Profile", systemImage: "square.and.pencil")
                }
            } else {
                Button {
                    toggleProfileFollow()
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
                foreground: profileBannerButtonForeground
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile options")
    }

    private func toggleProfileMute() {
        guard auth.currentNsec != nil else {
            requestAccountAccess()
            return
        }

        if isProfileMuted {
            muteStore.toggleMute(viewModel.pubkey)
        } else {
            muteReasonEditorMode = .mute
        }
    }

    private func completeProfileMuteReason(
        mode: MuteReasonEditorMode,
        reason: String?
    ) {
        switch mode {
        case .mute:
            guard !muteStore.isMuted(viewModel.pubkey) else { return }
            muteStore.toggleMute(viewModel.pubkey, reason: reason)
        case .edit:
            guard muteStore.isMuted(viewModel.pubkey) else { return }
            muteStore.setMuteReason(reason, for: viewModel.pubkey)
        }
    }

    private func toggleProfileFollow() {
        guard auth.currentNsec != nil else {
            requestAccountAccess()
            return
        }
        followStore.toggleFollow(viewModel.pubkey)
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
            guard auth.currentNsec != nil else {
                requestAccountAccess()
                return
            }
            isShowingProfileEditor = true
        } else {
            toggleProfileFollow()
        }
    }

    private func requestAccountAccess() {
        NotificationCenter.default.post(name: .flowRequestAccountAccess, object: nil)
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

    private func loadInitialProfileScreenData() async {
        async let loadIfNeeded: Void = viewModel.loadIfNeeded()
        async let refreshFollowRelationship: Void = viewModel.refreshFollowRelationship(
            currentAccountPubkey: auth.currentAccount?.pubkey
        )
        async let refreshKnownFollowers: Void = viewModel.refreshKnownFollowers(
            currentAccountPubkey: auth.currentAccount?.pubkey,
            followedPubkeys: followStore.followedPubkeys
        )

        _ = await (loadIfNeeded, refreshFollowRelationship, refreshKnownFollowers)
    }

    private func refreshProfileScreenData() async {
        async let refreshProfile: Void = viewModel.refresh()
        async let refreshFollowRelationship: Void = viewModel.refreshFollowRelationship(
            currentAccountPubkey: auth.currentAccount?.pubkey
        )
        async let refreshKnownFollowers: Void = viewModel.refreshKnownFollowers(
            currentAccountPubkey: auth.currentAccount?.pubkey,
            followedPubkeys: followStore.followedPubkeys
        )

        _ = await (refreshProfile, refreshFollowRelationship, refreshKnownFollowers)
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
            return "No reading sources found"
        case .publish:
            return "No publishing sources found"
        case .messages:
            return "No messaging sources found"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .receive:
            return "This person hasn’t shared where they read from."
        case .publish:
            return "This person hasn’t shared where they publish."
        case .messages:
            return "This person hasn’t shared their messaging sources."
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
                    Text("Sources for \(displayName)")
                        .font(appSettings.appFont(.title2, weight: .bold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    FlowNativeGlassSegmentedPicker(
                        selection: $selectedTab,
                        items: ProfileConnectionSourceTab.allCases,
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
            Text("Checking sources...")
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

private struct ProfileScrollChromeModifier: ViewModifier {
    let scrollChromeStore: ScrollChromeStore?
    let bottomTabBarHeight: CGFloat
    let safeAreaBottom: CGFloat
    let compactHeaderThreshold: CGFloat
    let onCompactHeaderVisibilityChange: (Bool) -> Void
    @State private var scrollChromeTracker = ScrollChromeTracker()
    @State private var isCompactHeaderVisible = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let scrollChromeStore {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, scrollY in
                    let shouldShowCompactHeader = scrollY >= compactHeaderThreshold
                    if shouldShowCompactHeader != isCompactHeaderVisible {
                        isCompactHeaderVisible = shouldShowCompactHeader
                        onCompactHeaderVisibilityChange(shouldShowCompactHeader)
                    }

                    let updated = scrollChromeTracker.offsetsByApplyingScroll(
                        currentScrollY: scrollY,
                        currentVisualOffsets: scrollChromeStore.offsets,
                        topBarHeight: ScrollChromeLayout.defaultTopBarHeight,
                        bottomBarHeight: bottomTabBarHeight,
                        safeAreaBottom: safeAreaBottom
                    )
                    scrollChromeStore.publishVisualOffsetsIfNeeded(updated)
                }
        } else {
            content
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
            .accessibilityLabel("Open source \(relayName)")

            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appSettings.primaryColor)
                    .accessibilityLabel("Source \(relayName) added")
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appSettings.primaryColor)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add source \(relayName)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}
