import SwiftUI

enum ProfileHeaderBannerMetrics {
    static let height: CGFloat = LongFormArticleReaderLayout.heroMinHeight
    static let fadeHeight: CGFloat = LongFormArticleReaderLayout.heroMinHeight * 0.21
    static let topScrimOpacity: Double = 0.04
    static let bottomFadeMidOpacity: Double = 0.08
    static let bottomFadeStrongOpacity: Double = 0.48
    static let loadedImageOpacity: Double = 1
    static let loadedImageSaturation: Double = 1
}

private let profileHeaderAvatarSize: CGFloat = 104
private let profileHeaderContentHorizontalPadding: CGFloat = 16
private let profileHeaderSkeletonInfoRowWidths: [CGFloat] = [184, 152, 228]

enum ProfileHeaderLayoutGuardrails {
    static func boundedWidth(
        proposedWidth: CGFloat?,
        fallbackWidth: CGFloat = UIScreen.main.bounds.width
    ) -> CGFloat {
        let candidate: CGFloat
        if let proposedWidth, proposedWidth.isFinite, proposedWidth > 0 {
            candidate = proposedWidth
        } else {
            candidate = fallbackWidth
        }

        guard fallbackWidth.isFinite, fallbackWidth > 0 else {
            return candidate
        }

        return min(candidate, fallbackWidth)
    }

    static func trailingControlOriginX(
        parentWidth: CGFloat,
        visibleWidth: CGFloat,
        controlWidth: CGFloat,
        horizontalPadding: CGFloat
    ) -> CGFloat {
        let width = boundedWidth(
            proposedWidth: min(parentWidth, visibleWidth),
            fallbackWidth: visibleWidth
        )
        return max(horizontalPadding, width - horizontalPadding - controlWidth)
    }

    static func topControlsTopPadding(
        safeAreaInset: CGFloat,
        minimumPadding: CGFloat = 12
    ) -> CGFloat {
        minimumPadding + max(0, safeAreaInset)
    }
}

enum ProfileHeaderEntranceElement {
    case avatar
    case identity
}

struct ProfileHeaderEntrancePresentation: Equatable {
    let yOffset: CGFloat
    let scale: CGFloat
    let opacity: Double
}

enum ProfileHeaderEntranceMotion {
    static func springResponse(for element: ProfileHeaderEntranceElement) -> Double {
        switch element {
        case .avatar:
            0.62
        case .identity:
            0.46
        }
    }

    static func dampingFraction(for element: ProfileHeaderEntranceElement) -> Double {
        switch element {
        case .avatar:
            0.8
        case .identity:
            0.88
        }
    }

    static func presentation(
        for element: ProfileHeaderEntranceElement,
        isSettled: Bool,
        reduceMotion: Bool
    ) -> ProfileHeaderEntrancePresentation {
        guard !reduceMotion, !isSettled else {
            return ProfileHeaderEntrancePresentation(yOffset: 0, scale: 1, opacity: 1)
        }

        switch element {
        case .avatar:
            return ProfileHeaderEntrancePresentation(yOffset: 18, scale: 0.9, opacity: 0.86)
        case .identity:
            return ProfileHeaderEntrancePresentation(yOffset: 8, scale: 0.98, opacity: 0.78)
        }
    }

    static func animation(for element: ProfileHeaderEntranceElement, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(
            response: springResponse(for: element),
            dampingFraction: dampingFraction(for: element)
        )
    }
}

struct ProfileHeaderContent {
    let displayName: String
    let handle: String
    let about: String?
    let avatarURL: URL?
    let bannerURL: URL?
    let websiteURL: URL?
    let websiteDisplayText: String?
    let followsCurrentUser: Bool
    let followingCountText: String
    let followStatusIconName: String?
    let knownFollowers: [ProfileKnownFollower]
    let actionMessage: String?

    var hasVisibleInfoRows: Bool {
        if websiteURL != nil {
            return true
        }
        return false
    }
}

struct ProfileHeaderSection<BackButton: View, MenuButton: View, ActionRow: View>: View {
    let isLoading: Bool
    let topSafeAreaInset: CGFloat
    let content: ProfileHeaderContent
    let onFollowingTap: () -> Void
    let onProfileTap: (String) -> Void
    let onHashtagTap: (String) -> Void
    let onRelayTap: (URL) -> Void
    let onAvatarTap: () -> Void

    private let backButton: BackButton
    private let menuButton: MenuButton
    private let actionRow: ActionRow

    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var entranceSettled = false
    @State private var entranceContentID: String?

    init(
        isLoading: Bool,
        topSafeAreaInset: CGFloat = 0,
        content: ProfileHeaderContent,
        onFollowingTap: @escaping () -> Void,
        onProfileTap: @escaping (String) -> Void,
        onHashtagTap: @escaping (String) -> Void,
        onRelayTap: @escaping (URL) -> Void = { _ in },
        onAvatarTap: @escaping () -> Void,
        @ViewBuilder backButton: () -> BackButton,
        @ViewBuilder menuButton: () -> MenuButton,
        @ViewBuilder actionRow: () -> ActionRow
    ) {
        self.isLoading = isLoading
        self.topSafeAreaInset = topSafeAreaInset
        self.content = content
        self.onFollowingTap = onFollowingTap
        self.onProfileTap = onProfileTap
        self.onHashtagTap = onHashtagTap
        self.onRelayTap = onRelayTap
        self.onAvatarTap = onAvatarTap
        self.backButton = backButton()
        self.menuButton = menuButton()
        self.actionRow = actionRow()
    }

    var body: some View {
        ProfileHeaderWidthBoundaryLayout {
            if isLoading {
                ProfileHeaderSkeleton(
                    topSafeAreaInset: topSafeAreaInset,
                    backButton: backButton,
                    menuButton: menuButton
                )
            } else {
                loadedContent
            }
        }
        .clipped()
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileBannerArtwork(bannerURL: content.bannerURL)
                .overlay(alignment: .topLeading) {
                    ProfileHeaderTopControls(
                        topSafeAreaInset: topSafeAreaInset,
                        backButton: backButton,
                        menuButton: menuButton
                    )
                }

            VStack(alignment: .leading, spacing: 14) {
                ProfileHeaderAvatarActionsLayout {
                    ProfileAvatarView(
                        displayName: content.displayName,
                        avatarURL: content.avatarURL,
                        onTap: onAvatarTap
                    )
                    .modifier(
                        ProfileHeaderEntranceModifier(
                            element: .avatar,
                            isSettled: entranceSettled,
                            reduceMotion: accessibilityReduceMotion
                        )
                    )

                    actionRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ProfileIdentityBlock(
                    displayName: content.displayName,
                    handle: content.handle,
                    followStatusIconName: content.followStatusIconName,
                    followsCurrentUser: content.followsCurrentUser,
                    followingCountText: content.followingCountText,
                    onFollowingTap: onFollowingTap
                )
                .modifier(
                    ProfileHeaderEntranceModifier(
                        element: .identity,
                        isSettled: entranceSettled,
                        reduceMotion: accessibilityReduceMotion
                    )
                )

                if let about = content.about, !about.isEmpty {
                    ProfileAboutTextView(
                        text: about,
                        onProfileTap: onProfileTap,
                        onHashtagTap: onHashtagTap,
                        onRelayTap: onRelayTap
                    )
                }

                if content.hasVisibleInfoRows {
                    ProfileInfoRows(content: content)
                }

                if !content.knownFollowers.isEmpty {
                    ProfileKnownFollowersRow(followers: content.knownFollowers)
                }

                if let actionMessage = content.actionMessage, !actionMessage.isEmpty {
                    Text(actionMessage)
                        .font(appSettings.appFont(.footnote))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, profileHeaderContentHorizontalPadding)
            .padding(.top, -(profileHeaderAvatarSize / 2))
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .onAppear {
            startEntranceIfNeeded(for: loadedContentEntranceID)
        }
        .onChange(of: loadedContentEntranceID) { _, newValue in
            startEntranceIfNeeded(for: newValue)
        }
    }

    private var loadedContentEntranceID: String {
        [
            content.displayName,
            content.handle,
            content.avatarURL?.absoluteString ?? ""
        ].joined(separator: "|")
    }

    private func startEntranceIfNeeded(for contentID: String) {
        guard entranceContentID != contentID else { return }
        entranceContentID = contentID

        if accessibilityReduceMotion {
            entranceSettled = true
            return
        }

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            entranceSettled = false
        }

        Task { @MainActor in
            await Task.yield()
            entranceSettled = true
        }
    }
}

private struct ProfileHeaderEntranceModifier: ViewModifier {
    let element: ProfileHeaderEntranceElement
    let isSettled: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let presentation = ProfileHeaderEntranceMotion.presentation(
            for: element,
            isSettled: isSettled,
            reduceMotion: reduceMotion
        )

        content
            .scaleEffect(presentation.scale, anchor: .center)
            .offset(y: presentation.yOffset)
            .opacity(presentation.opacity)
            .animation(
                ProfileHeaderEntranceMotion.animation(
                    for: element,
                    reduceMotion: reduceMotion
                ),
                value: isSettled
            )
    }
}

private struct ProfileHeaderWidthBoundaryLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }

        let width = ProfileHeaderLayoutGuardrails.boundedWidth(proposedWidth: proposal.width)
        let size = subview.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )

        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }

        let width = ProfileHeaderLayoutGuardrails.boundedWidth(
            proposedWidth: bounds.width > 0 ? bounds.width : proposal.width
        )
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}

private struct ProfileHeaderTopControls<BackButton: View, MenuButton: View>: View {
    let topSafeAreaInset: CGFloat
    let backButton: BackButton
    let menuButton: MenuButton

    var body: some View {
        ProfileHeaderTopControlsLayout(topSafeAreaInset: topSafeAreaInset) {
            backButton
            menuButton
        }
        .zIndex(4)
        .unredacted()
    }
}

private struct ProfileHeaderTopControlsLayout: Layout {
    let topSafeAreaInset: CGFloat

    private let horizontalPadding: CGFloat = 16
    private var topPadding: CGFloat {
        ProfileHeaderLayoutGuardrails.topControlsTopPadding(safeAreaInset: topSafeAreaInset)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 2 else { return .zero }

        let width = ProfileHeaderLayoutGuardrails.boundedWidth(proposedWidth: proposal.width)
        let backSize = subviews[0].sizeThatFits(.unspecified)
        let menuSize = subviews[1].sizeThatFits(.unspecified)

        return CGSize(
            width: width,
            height: topPadding + max(backSize.height, menuSize.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }

        let width = ProfileHeaderLayoutGuardrails.boundedWidth(
            proposedWidth: bounds.width > 0 ? bounds.width : proposal.width
        )
        let backSize = subviews[0].sizeThatFits(.unspecified)
        let menuSize = subviews[1].sizeThatFits(.unspecified)
        let backOrigin = CGPoint(
            x: bounds.minX + horizontalPadding,
            y: bounds.minY + topPadding
        )
        let menuOriginX = ProfileHeaderLayoutGuardrails.trailingControlOriginX(
            parentWidth: bounds.width,
            visibleWidth: width,
            controlWidth: menuSize.width,
            horizontalPadding: horizontalPadding
        )
        let menuOrigin = CGPoint(
            x: bounds.minX + menuOriginX,
            y: bounds.minY + topPadding
        )

        subviews[0].place(
            at: backOrigin,
            proposal: ProposedViewSize(width: backSize.width, height: backSize.height)
        )
        subviews[1].place(
            at: menuOrigin,
            proposal: ProposedViewSize(width: menuSize.width, height: menuSize.height)
        )
    }
}

private struct ProfileHeaderAvatarActionsLayout: Layout {
    private let horizontalSpacing: CGFloat = 16
    private let verticalSpacing: CGFloat = 12
    private var fallbackContentWidth: CGFloat {
        max(0, UIScreen.main.bounds.width - (profileHeaderContentHorizontalPadding * 2))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 2 else { return .zero }

        let availableWidth = ProfileHeaderLayoutGuardrails.boundedWidth(
            proposedWidth: proposal.width,
            fallbackWidth: fallbackContentWidth
        )
        let avatarSize = subviews[0].sizeThatFits(.unspecified)
        let actionsSize = subviews[1].sizeThatFits(.unspecified)
        let horizontalWidth = avatarSize.width + horizontalSpacing + actionsSize.width

        if horizontalWidth <= availableWidth {
            return CGSize(
                width: availableWidth,
                height: max(avatarSize.height, actionsSize.height)
            )
        }

        return CGSize(
            width: availableWidth,
            height: avatarSize.height + verticalSpacing + actionsSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }

        let availableWidth = ProfileHeaderLayoutGuardrails.boundedWidth(
            proposedWidth: bounds.width > 0 ? bounds.width : proposal.width,
            fallbackWidth: fallbackContentWidth
        )
        let placementBounds = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: availableWidth,
            height: bounds.height
        )
        let avatarSize = subviews[0].sizeThatFits(.unspecified)
        let actionsSize = subviews[1].sizeThatFits(.unspecified)
        let horizontalWidth = avatarSize.width + horizontalSpacing + actionsSize.width

        if horizontalWidth <= availableWidth {
            let avatarOrigin = CGPoint(
                x: placementBounds.minX,
                y: placementBounds.maxY - avatarSize.height
            )
            let actionsOrigin = CGPoint(
                x: placementBounds.maxX - actionsSize.width,
                y: placementBounds.maxY - actionsSize.height
            )

            subviews[0].place(
                at: avatarOrigin,
                proposal: ProposedViewSize(width: avatarSize.width, height: avatarSize.height)
            )
            subviews[1].place(
                at: actionsOrigin,
                proposal: ProposedViewSize(width: actionsSize.width, height: actionsSize.height)
            )
        } else {
            subviews[0].place(
                at: placementBounds.origin,
                proposal: ProposedViewSize(width: avatarSize.width, height: avatarSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: placementBounds.minX, y: placementBounds.minY + avatarSize.height + verticalSpacing),
                proposal: ProposedViewSize(width: min(actionsSize.width, availableWidth), height: actionsSize.height)
            )
        }
    }

    private func horizontalSize(subviews: Subviews) -> CGSize {
        guard subviews.count >= 2 else { return .zero }
        let avatarSize = subviews[0].sizeThatFits(.unspecified)
        let actionsSize = subviews[1].sizeThatFits(.unspecified)

        return CGSize(
            width: avatarSize.width + horizontalSpacing + actionsSize.width,
            height: max(avatarSize.height, actionsSize.height)
        )
    }
}

private struct ProfileBannerArtwork: View {
    let bannerURL: URL?

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        GeometryReader { proxy in
            let width = ProfileHeaderLayoutGuardrails.boundedWidth(
                proposedWidth: proxy.size.width
            )

            Rectangle()
                .fill(appSettings.themePalette.background)
                .frame(width: width, height: ProfileHeaderBannerMetrics.height)
                .overlay(alignment: .topLeading) {
                    bannerContent
                        .frame(width: width, height: ProfileHeaderBannerMetrics.height)
                        .clipped()
                }
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(ProfileHeaderBannerMetrics.topScrimOpacity),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: width, height: ProfileHeaderBannerMetrics.height)
                }
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(
                        stops: [
                            .init(color: Color.clear, location: 0),
                            .init(color: appSettings.themePalette.background.opacity(ProfileHeaderBannerMetrics.bottomFadeMidOpacity), location: 0.42),
                            .init(color: appSettings.themePalette.background.opacity(ProfileHeaderBannerMetrics.bottomFadeStrongOpacity), location: 0.78),
                            .init(color: appSettings.themePalette.background, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: width, height: ProfileHeaderBannerMetrics.fadeHeight)
                }
                .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ProfileHeaderBannerMetrics.height)
        .background(appSettings.themePalette.background)
        .clipped()
    }

    @ViewBuilder
    private var bannerContent: some View {
        if appSettings.textOnlyMode {
            bannerFallback
        } else if let bannerURL {
            CachedAsyncImage(url: bannerURL, kind: .profileBanner) { phase in
                switch phase {
                case .success(let image):
                    loadedBannerImage(image)
                case .empty, .failure:
                    bannerFallback
                }
            }
        } else {
            bannerFallback
        }
    }

    private func loadedBannerImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .saturation(ProfileHeaderBannerMetrics.loadedImageSaturation)
            .opacity(ProfileHeaderBannerMetrics.loadedImageOpacity)
    }

    private var bannerFallback: some View {
        ZStack {
            Rectangle()
                .fill(appSettings.primaryGradient)
                .opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.92 : 0.34)
                .background(appSettings.themePalette.secondaryBackground)

            Circle()
                .fill(Color.white.opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.36 : 0.42))
                .frame(width: 152, height: 152)
                .blur(radius: 18)
                .offset(x: 120, y: -40)

            Circle()
                .fill(appSettings.primaryColor.opacity(0.16))
                .frame(width: 188, height: 188)
                .blur(radius: 28)
                .offset(x: -132, y: 54)
        }
    }
}

private struct ProfileAvatarView: View {
    let displayName: String
    let avatarURL: URL?
    let onTap: () -> Void

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        let isInteractive = !appSettings.textOnlyMode && avatarURL != nil

        Group {
            if isInteractive {
                Button(action: onTap) {
                    avatarContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View profile image")
            } else {
                avatarContent
            }
        }
    }

    private var avatarContent: some View {
        Group {
            if appSettings.textOnlyMode {
                avatarFallback
            } else if let avatarURL {
                if isProfileLoopingVideoURL(avatarURL) {
                    ZStack {
                        avatarFallback
                        ProfileLoopingVideoView(
                            url: avatarURL,
                            videoGravity: .resizeAspectFill
                        )
                    }
                } else {
                    CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            avatarFallback
                        }
                    }
                }
            } else {
                avatarFallback
            }
        }
        .frame(
            width: profileHeaderAvatarSize,
            height: profileHeaderAvatarSize
        )
        .background(Circle().fill(appSettings.themePalette.background))
        .clipShape(Circle())
        .overlay {
            Circle().stroke(appSettings.themePalette.background, lineWidth: 4)
        }
        .overlay {
            Circle().stroke(appSettings.themePalette.separator.opacity(0.72), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)
    }

    private var avatarFallback: some View {
        ZStack {
            Circle()
                .fill(appSettings.primaryGradient)

            Text(String(displayName.prefix(1)).uppercased())
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(appSettings.buttonTextColor)
        }
    }
}

private struct ProfileIdentityBlock: View {
    let displayName: String
    let handle: String
    let followStatusIconName: String?
    let followsCurrentUser: Bool
    let followingCountText: String
    let onFollowingTap: () -> Void

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            displayNameText
            ViewThatFits(in: .vertical) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    handleRow
                    Spacer(minLength: 12)
                    followMetadataRow
                }

                VStack(alignment: .leading, spacing: 8) {
                    handleRow
                    followMetadataRow
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var handleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(FlowLayoutGuardrails.softWrapped(handle, maxNonBreakingRunLength: 18, minimumLength: 18))
                .font(appSettings.appFont(.subheadline))
                .foregroundStyle(appSettings.themePalette.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)

            if let followStatusIconName {
                Image(systemName: followStatusIconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appSettings.primaryColor)
                    .accessibilityHidden(true)
            }
        }
        .layoutPriority(1)
    }

    private var followMetadataRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onFollowingTap) {
                HStack(spacing: 4) {
                    Text(followingCountText)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(appSettings.appFont(.footnote, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.mutedForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(appSettings.themePalette.secondaryFill.opacity(0.5))
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(appSettings.themePalette.separator.opacity(0.45), lineWidth: 0.8)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View following list")

            if followsCurrentUser {
                ProfileFollowsYouBadge()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var displayNameText: some View {
        Text(FlowLayoutGuardrails.softWrapped(displayName, maxNonBreakingRunLength: 14, minimumLength: 14))
            .font(appSettings.appFont(size: 30, weight: .heavy))
            .foregroundStyle(appSettings.themePalette.foreground)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProfileFollowsYouBadge: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        Text("Follows you")
            .font(appSettings.appFont(.caption2, weight: .semibold))
            .foregroundStyle(appSettings.primaryColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(appSettings.primaryColor.opacity(0.14))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(appSettings.primaryColor.opacity(0.22), lineWidth: 0.8)
            }
            .accessibilityLabel("Follows you")
    }
}

private struct ProfileInfoRows: View {
    let content: ProfileHeaderContent

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let websiteURL = content.websiteURL {
                Link(destination: websiteURL) {
                    ProfileInfoRow(
                        text: content.websiteDisplayText ?? websiteURL.absoluteString,
                        systemImage: "link"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ProfileKnownFollowersRow: View {
    let followers: [ProfileKnownFollower]

    @EnvironmentObject private var appSettings: AppSettingsStore

    private var visibleFollowers: [ProfileKnownFollower] {
        Array(followers.prefix(5))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProfileKnownFollowersAvatarStack(followers: visibleFollowers)

            Text("Followed by \(softWrappedNamesText)")
                .font(appSettings.appFont(.footnote, weight: .medium))
                .foregroundStyle(appSettings.themePalette.mutedForeground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Followed by \(namesText)")
    }

    private var namesText: String {
        visibleFollowers.map(\.displayName).joined(separator: ", ")
    }

    private var softWrappedNamesText: String {
        FlowLayoutGuardrails.softWrapped(namesText, maxNonBreakingRunLength: 16, minimumLength: 18)
    }
}

private struct ProfileKnownFollowersAvatarStack: View {
    let followers: [ProfileKnownFollower]

    @EnvironmentObject private var appSettings: AppSettingsStore

    private let avatarSize: CGFloat = 34
    private let overlap: CGFloat = 11

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(followers.enumerated()), id: \.element.id) { index, follower in
                ProfileKnownFollowerAvatar(follower: follower, size: avatarSize)
                    .offset(x: CGFloat(index) * (avatarSize - overlap))
                    .zIndex(Double(followers.count - index))
            }
        }
        .frame(width: stackWidth, height: avatarSize, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var stackWidth: CGFloat {
        guard !followers.isEmpty else { return 0 }
        return avatarSize + CGFloat(max(followers.count - 1, 0)) * (avatarSize - overlap)
    }
}

private struct ProfileKnownFollowerAvatar: View {
    let follower: ProfileKnownFollower
    let size: CGFloat

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        Group {
            if appSettings.textOnlyMode {
                fallback
            } else if let avatarURL = follower.avatarURL {
                CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(appSettings.themePalette.background, lineWidth: 2.5)
        }
        .overlay {
            Circle()
                .stroke(appSettings.themePalette.separator.opacity(0.35), lineWidth: 0.7)
        }
    }

    private var fallback: some View {
        ZStack {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)

            Text(String(follower.displayName.prefix(1)).uppercased())
                .font(appSettings.appFont(.caption1, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }
}

private struct ProfileInfoRow: View {
    let text: String
    let systemImage: String

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(iconForegroundStyle)
            Text(text)
                .font(appSettings.appFont(.footnote))
                .foregroundStyle(appSettings.themePalette.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconForegroundStyle: Color {
        systemImage == "link" ? appSettings.themeIconAccentColor : appSettings.themePalette.mutedForeground
    }
}

private struct ProfileHeaderSkeleton<BackButton: View, MenuButton: View>: View {
    let topSafeAreaInset: CGFloat
    let backButton: BackButton
    let menuButton: MenuButton

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(height: ProfileHeaderBannerMetrics.height)
                .overlay(alignment: .topLeading) {
                    ProfileHeaderTopControls(
                        topSafeAreaInset: topSafeAreaInset,
                        backButton: backButton,
                        menuButton: menuButton
                    )
                }

            VStack(alignment: .leading, spacing: 14) {
                ProfileHeaderAvatarActionsLayout {
                    Circle()
                        .fill(appSettings.themePalette.secondaryFill)
                        .frame(
                            width: profileHeaderAvatarSize,
                            height: profileHeaderAvatarSize
                        )

                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in
                            Capsule()
                                .fill(appSettings.themePalette.secondaryFill)
                                .frame(width: 44, height: 40)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appSettings.themePalette.secondaryFill)
                        .frame(width: 210, height: 32)

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(appSettings.themePalette.secondaryFill)
                        .frame(width: 150, height: 20)

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(appSettings.themePalette.secondaryFill)
                        .frame(width: 120, height: 16)
                }

                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(appSettings.themePalette.secondaryFill)
                        .frame(height: 15)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(appSettings.themePalette.secondaryFill)
                        .frame(height: 15)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(appSettings.themePalette.secondaryFill)
                        .frame(width: 236, height: 15)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profileHeaderSkeletonInfoRowWidths, id: \.self) { width in
                        ProfileSkeletonInfoRow(width: width)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, profileHeaderContentHorizontalPadding)
            .padding(.top, -(profileHeaderAvatarSize / 2))
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .redacted(reason: .placeholder)
    }
}

private struct ProfileSkeletonInfoRow: View {
    let width: CGFloat

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 12, height: 12)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: width, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
