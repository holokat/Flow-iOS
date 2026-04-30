import SwiftUI

struct HomeSlideoutMenuView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.sideMenuPresentationIsOpen) private var isMenuPresented
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @State private var accountHeaderName: String?
    @State private var accountHeaderHandle: String?
    @State private var accountHeaderAvatarURL: URL?
    @State private var accountHeaderBannerURL: URL?
    @State private var isShowingProfileQR = false

    let onViewProfile: () -> Void
    let onOpenScannedProfile: (String) -> Void
    let onManageSettings: () -> Void
    let onManageAccounts: () -> Void
    let onLogout: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let currentAccount = auth.currentAccount {
                        revealedMenuRow(index: 0) {
                            accountProfileHeader(currentAccount)
                        }
                    } else {
                        closeOnlyHeader
                    }

                    menuLinks
                        .padding(.top, SideMenuTransitionLayout.profileHeaderLinksTopSpacing)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(menuBackground)
        .sheet(isPresented: $isShowingProfileQR) {
            if let currentAccount = auth.currentAccount {
                ProfileQRCodeSheet(
                    npub: currentAccount.npub,
                    displayName: resolvedAccountName(for: currentAccount),
                    handle: resolvedAccountHandle,
                    avatarURL: accountHeaderAvatarURL,
                    onOpenProfile: { pubkey in
                        onOpenScannedProfile(pubkey)
                    }
                )
                .presentationBackground(menuBackground)
            }
        }
        .task(id: accountHeaderLookupID) {
            await refreshAccountHeaderName()
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileMetadataUpdated)) { notification in
            guard let updatedPubkey = (notification.userInfo?["pubkey"] as? String)?.lowercased(),
                  let currentPubkey = auth.currentAccount?.pubkey.lowercased(),
                  updatedPubkey == currentPubkey else {
                return
            }
            Task {
                await refreshAccountHeaderName()
            }
        }
    }

    private var menuBackground: Color {
        effectiveMenuColorScheme == .light ? .white : appSettings.themePalette.sheetBackground
    }

    private var effectiveMenuColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }

    private var menuLinks: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                revealedMenuRow(index: 1) {
                    menuButton(
                        title: "Profile",
                        icon: "person",
                        action: onViewProfile
                    )
                }

                revealedMenuRow(index: 2) {
                    menuButton(
                        title: "Settings",
                        icon: "gearshape",
                        action: onManageSettings
                    )
                }

                revealedMenuRow(index: 3) {
                    menuButton(
                        title: "Accounts",
                        icon: "arrow.left.arrow.right.circle",
                        action: onManageAccounts
                    )
                }
            }

            if auth.isLoggedIn {
                revealedMenuRow(index: 4) {
                    menuButton(
                        title: "Log Out",
                        icon: "rectangle.portrait.and.arrow.right",
                        tint: .red,
                        action: onLogout
                    )
                }
                .padding(.top, SideMenuTransitionLayout.logoutTopSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountProfileHeader(_ account: AuthAccount) -> some View {
        let resolvedName = resolvedAccountName(for: account)
        let accountHandle = resolvedAccountHandle ?? fallbackAccountHandle(for: account)

        return VStack(alignment: .leading, spacing: 0) {
            SideMenuProfileBannerArtwork(
                bannerURL: accountHeaderBannerURL,
                menuBackground: menuBackground
            )
            .overlay(alignment: .topTrailing) {
                closeMenuButton
                    .padding(.top, 18)
                    .padding(.trailing, 16)
            }

            HStack(alignment: .center, spacing: 12) {
                Button {
                    onViewProfile()
                } label: {
                    accountHeaderAvatar(fallbackName: resolvedName)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View profile")

                VStack(alignment: .leading, spacing: 4) {
                    Text(resolvedName)
                        .font(appSettings.appFont(.headline, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(accountHandle)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, SideMenuTransitionLayout.profileHeaderAvatarSize / 2)

                Spacer(minLength: 0)

                profileQRButton
                    .padding(.top, SideMenuTransitionLayout.profileHeaderAvatarSize / 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, -(SideMenuTransitionLayout.profileHeaderAvatarSize / 2))
            .padding(.bottom, SideMenuTransitionLayout.profileHeaderContentBottomPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var closeOnlyHeader: some View {
        HStack {
            Spacer()
            closeMenuButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var closeMenuButton: some View {
        Button {
            onClose()
        } label: {
            glassMenuControl(systemName: "xmark", size: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close menu")
    }

    private var profileQRButton: some View {
        Button {
            isShowingProfileQR = true
        } label: {
            glassMenuControl(systemName: "qrcode", size: 17)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show profile QR")
    }

    private func glassMenuControl(systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(appSettings.themePalette.foreground.opacity(0.86))
            .frame(width: 36, height: 36)
            .background {
                Circle()
                    .fill(menuCircleBackgroundFill())
            }
            .overlay {
                Circle()
                    .stroke(menuCircleStroke(), lineWidth: 0.8)
            }
            .shadow(
                color: Color.black.opacity(effectiveMenuColorScheme == .dark ? 0.22 : 0.06),
                radius: 10,
                x: 0,
                y: 4
            )
            .clipShape(Circle())
    }

    private func menuCircleBackgroundFill(tint: Color? = nil) -> Color {
        let baseTint = tint ?? appSettings.themePalette.foreground
        return baseTint.opacity(effectiveMenuColorScheme == .light ? 0.08 : 0.16)
    }

    private func menuCircleStroke(tint: Color? = nil) -> Color {
        let baseTint = tint ?? appSettings.themePalette.foreground
        return baseTint.opacity(effectiveMenuColorScheme == .light ? 0.12 : 0.22)
    }

    private func accountHeaderAvatar(fallbackName: String) -> some View {
        AvatarView(
            url: accountHeaderAvatarURL,
            fallback: fallbackName,
            size: SideMenuTransitionLayout.profileHeaderAvatarSize,
            fallbackGradient: appSettings.avatarFallbackGradient(forAccountPubkey: auth.currentAccount?.pubkey),
            fallbackForeground: appSettings.avatarFallbackForeground(forAccountPubkey: auth.currentAccount?.pubkey)
        )
    }

    private func accountHeaderFallbackAvatar(fallbackName: String) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(fallbackName.prefix(1).uppercased())
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private struct SideMenuProfileBannerArtwork: View {
        let bannerURL: URL?
        let menuBackground: Color

        @EnvironmentObject private var appSettings: AppSettingsStore

        var body: some View {
            GeometryReader { proxy in
                let width = max(0, proxy.size.width)

                Rectangle()
                    .fill(menuBackground)
                    .frame(width: width, height: SideMenuTransitionLayout.profileBannerHeight)
                    .overlay(alignment: .topLeading) {
                        bannerContent
                            .frame(width: width, height: SideMenuTransitionLayout.profileBannerHeight)
                            .clipped()
                    }
                    .overlay(alignment: .topLeading) {
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.1),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: width, height: SideMenuTransitionLayout.profileBannerHeight)
                    }
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(
                            stops: [
                                .init(color: Color.clear, location: 0),
                                .init(color: menuBackground.opacity(0.32), location: 0.34),
                                .init(color: menuBackground.opacity(0.8), location: 0.72),
                                .init(color: menuBackground, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: width, height: SideMenuTransitionLayout.profileBannerFadeHeight)
                    }
                    .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SideMenuTransitionLayout.profileBannerHeight)
            .background(menuBackground)
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
                .saturation(SideMenuTransitionLayout.profileBannerLoadedImageSaturation)
                .opacity(SideMenuTransitionLayout.profileBannerLoadedImageOpacity)
        }

        private var bannerFallback: some View {
            ZStack {
                Rectangle()
                    .fill(appSettings.primaryGradient)
                    .opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.9 : 0.34)
                    .background(appSettings.themePalette.secondaryBackground)

                Circle()
                    .fill(Color.white.opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.34 : 0.4))
                    .frame(width: 128, height: 128)
                    .blur(radius: 18)
                    .offset(x: 90, y: -34)

                Circle()
                    .fill(appSettings.primaryColor.opacity(0.16))
                    .frame(width: 156, height: 156)
                    .blur(radius: 28)
                    .offset(x: -106, y: 46)
            }
        }
    }

    private func menuButton(
        title: String,
        icon: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let iconTint = tint ?? appSettings.themePalette.foreground.opacity(0.86)
        let textTint = tint ?? appSettings.themePalette.foreground

        return Button {
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 34, height: 34)
                    .background {
                        Circle()
                            .fill(menuCircleBackgroundFill(tint: tint))
                    }
                    .overlay {
                        Circle()
                            .stroke(menuCircleStroke(tint: tint), lineWidth: 0.8)
                    }

                Text(title)
                    .font(appSettings.appFont(.body))
                    .foregroundStyle(textTint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func revealedMenuRow<Content: View>(
        index: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(isMenuPresented ? 1 : SideMenuTransitionLayout.rowClosedOpacity)
            .offset(
                x: isMenuPresented ? 0 : SideMenuTransitionLayout.rowClosedXOffset,
                y: isMenuPresented ? 0 : SideMenuTransitionLayout.rowClosedYOffset
            )
            .animation(rowAnimation(index: index), value: isMenuPresented)
    }

    private func rowAnimation(index: Int) -> Animation? {
        guard !accessibilityReduceMotion else { return nil }

        let animation = Animation.easeOut(duration: 0.24)
        guard isMenuPresented else { return animation }

        return animation.delay(Double(index) * SideMenuTransitionLayout.rowStaggerDelay)
    }

    @MainActor
    private var accountHeaderLookupID: String {
        let accountID = auth.currentAccount?.id ?? "none"
        let relaySignature = relaySettings.readRelayURLs
            .map { $0.absoluteString.lowercased() }
            .joined(separator: ",")
        return "\(accountID)|\(relaySignature)"
    }

    @MainActor
    private func resolvedAccountName(for account: AuthAccount) -> String {
        guard let accountHeaderName = trimmedNonEmpty(accountHeaderName) else {
            return account.shortLabel
        }
        return accountHeaderName
    }

    @MainActor
    private func refreshAccountHeaderName() async {
        guard let account = auth.currentAccount else {
            accountHeaderName = nil
            accountHeaderHandle = nil
            accountHeaderAvatarURL = nil
            accountHeaderBannerURL = nil
            return
        }

        accountHeaderName = nil
        accountHeaderHandle = nil
        accountHeaderAvatarURL = nil
        accountHeaderBannerURL = nil

        let normalizedPubkey = account.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheResult = await ProfileCache.shared.resolve(pubkeys: [account.pubkey, normalizedPubkey])
        if let cachedProfile = cacheResult.hits[account.pubkey] ?? cacheResult.hits[normalizedPubkey] {
            accountHeaderName = preferredDisplayName(from: cachedProfile)
            accountHeaderHandle = preferredHandle(from: cachedProfile)
            accountHeaderAvatarURL = preferredAvatarURL(from: cachedProfile)
            accountHeaderBannerURL = preferredBannerURL(from: cachedProfile)
        }

        let readRelayURLs = relaySettings.readRelayURLs
        guard !readRelayURLs.isEmpty else {
            return
        }

        let fetchedProfile = await NostrFeedService().fetchProfile(relayURLs: readRelayURLs, pubkey: normalizedPubkey)
        if let fetchedProfile {
            accountHeaderName = preferredDisplayName(from: fetchedProfile)
            accountHeaderHandle = preferredHandle(from: fetchedProfile)
            accountHeaderAvatarURL = preferredAvatarURL(from: fetchedProfile)
            accountHeaderBannerURL = preferredBannerURL(from: fetchedProfile)
        }
    }

    private func preferredDisplayName(from profile: NostrProfile) -> String? {
        if let displayName = trimmedNonEmpty(profile.displayName) {
            return displayName
        }
        return trimmedNonEmpty(profile.name)
    }

    private func preferredAvatarURL(from profile: NostrProfile) -> URL? {
        profile.resolvedAvatarURL
    }

    private func preferredBannerURL(from profile: NostrProfile) -> URL? {
        guard let banner = trimmedNonEmpty(profile.banner),
              let url = URL(string: banner),
              url.scheme != nil else {
            return nil
        }
        return url
    }

    private func preferredHandle(from profile: NostrProfile) -> String? {
        if let name = trimmedNonEmpty(profile.name) {
            return "@\(normalizedHandleComponent(from: name))"
        }
        if let displayName = trimmedNonEmpty(profile.displayName) {
            return "@\(normalizedHandleComponent(from: displayName))"
        }
        return nil
    }

    private var resolvedAccountHandle: String? {
        trimmedNonEmpty(accountHeaderHandle)
    }

    private func fallbackAccountHandle(for account: AuthAccount) -> String {
        let compactLabel = account.shortLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fallback = compactLabel.isEmpty ? account.npub.lowercased() : compactLabel
        return "@\(fallback)"
    }

    private func normalizedHandleComponent(from value: String) -> String {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return compact.isEmpty ? "user" : compact
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
