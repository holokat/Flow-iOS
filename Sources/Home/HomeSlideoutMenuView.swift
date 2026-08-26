import SwiftUI

enum HomeSlideoutMenuStyle {
    @MainActor
    static func background(
        appSettings: AppSettingsStore,
        colorScheme: ColorScheme
    ) -> Color {
        let effectiveColorScheme = appSettings.preferredColorScheme ?? colorScheme
        if effectiveColorScheme == .dark {
            return Color(
                red: 17.0 / 255.0,
                green: 17.0 / 255.0,
                blue: 17.0 / 255.0
            )
        }

        return appSettings.themePalette.background
    }
}

struct HomeSlideoutMenuView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.sideMenuPresentationProgress) private var menuPresentationProgress
    @Environment(\.sideMenuSafeAreaInsets) private var menuSafeAreaInsets
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @State private var accountHeaderName: String?
    @State private var accountHeaderHandle: String?
    @State private var accountHeaderAvatarURL: URL?
    @State private var isShowingProfileQR = false

    let onViewProfile: () -> Void
    let onOpenScannedProfile: (String) -> Void
    let onManageSettings: () -> Void
    let onManageAccounts: () -> Void
    let onLogout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let currentAccount = auth.currentAccount {
                        revealedMenuRow(index: 0) {
                            accountProfileHeader(currentAccount)
                        }
                    } else {
                        guestHeader
                    }

                    menuLinks
                        .padding(.top, SideMenuTransitionLayout.profileHeaderLinksTopSpacing)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            menuFooter
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
        HomeSlideoutMenuStyle.background(
            appSettings: appSettings,
            colorScheme: colorScheme
        )
    }

    private var effectiveMenuColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }

    private var menuLinks: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(appSettings.themePalette.chromeBorder.opacity(0.52))
                .frame(height: 0.5)
                .padding(.horizontal, 20)

            if auth.isLoggedIn {
                revealedMenuRow(index: 4) {
                    menuButton(
                        title: "Log Out",
                        icon: "rectangle.portrait.and.arrow.right",
                        tint: appSettings.themePalette.secondaryForeground,
                        action: onLogout
                    )
                }
                .padding(.top, SideMenuTransitionLayout.logoutTopSpacing - 6)
            }
        }
        .padding(.bottom, max(menuSafeAreaInsets.bottom, 12) + 8)
    }

    private func accountProfileHeader(_ account: AuthAccount) -> some View {
        let resolvedName = resolvedAccountName(for: account)
        let accountHandle = resolvedAccountHandle ?? fallbackAccountHandle(for: account)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    onViewProfile()
                } label: {
                    accountHeaderAvatar(fallbackName: resolvedName)
                }
                .buttonStyle(
                    SideMenuPressButtonStyle(reduceMotion: accessibilityReduceMotion)
                )
                .accessibilityLabel("View profile")

                Spacer(minLength: 0)

                profileQRButton
            }

            Text(resolvedName)
                .font(appSettings.appFont(.title3, weight: .bold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 12)

            Text(accountHandle)
                .font(appSettings.appFont(.subheadline))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, max(menuSafeAreaInsets.top, 0) + 14)
    }

    private var guestHeader: some View {
        Text("Halo")
            .font(appSettings.appFont(.title2, weight: .bold))
            .foregroundStyle(appSettings.themePalette.foreground)
            .padding(.horizontal, 20)
            .padding(.top, max(menuSafeAreaInsets.top, 0) + 20)
            .padding(.bottom, 8)
    }

    private var profileQRButton: some View {
        Button {
            isShowingProfileQR = true
        } label: {
            Image(systemName: "qrcode")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground.opacity(0.88))
        }
        .haloNativeGlassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("Show profile QR")
    }

    private func accountHeaderAvatar(fallbackName: String) -> some View {
        AvatarView(
            url: accountHeaderAvatarURL,
            fallback: fallbackName,
            size: SideMenuTransitionLayout.profileHeaderAvatarSize,
            fallbackGradient: appSettings.avatarFallbackGradient(forAccountPubkey: auth.currentAccount?.pubkey),
            fallbackForeground: appSettings.avatarFallbackForeground(forAccountPubkey: auth.currentAccount?.pubkey)
        )
        .overlay {
            Circle()
                .stroke(
                    effectiveMenuColorScheme == .dark
                        ? Color.white.opacity(0.1)
                        : Color.black.opacity(0.1),
                    lineWidth: 1
                )
        }
    }

    private func menuButton(
        title: String,
        icon: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let iconTint = tint ?? appSettings.themePalette.foreground.opacity(0.9)
        let textTint = tint ?? appSettings.themePalette.foreground

        return Button {
            action()
        } label: {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(iconTint)
                    .frame(width: 28, height: 44)

                Text(title)
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .foregroundStyle(textTint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 56)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            SideMenuPressButtonStyle(reduceMotion: accessibilityReduceMotion)
        )
    }

    private func revealedMenuRow<Content: View>(
        index: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rowProgress = accessibilityReduceMotion
            ? (menuPresentationProgress > 0 ? CGFloat(1) : CGFloat(0))
            : SideMenuTransitionLayout.rowPresentationProgress(
                menuProgress: menuPresentationProgress,
                index: index
            )

        return content()
            .opacity(
                SideMenuTransitionLayout.rowClosedOpacity
                    + ((1 - SideMenuTransitionLayout.rowClosedOpacity) * Double(rowProgress))
            )
            .offset(
                x: SideMenuTransitionLayout.rowClosedXOffset * (1 - rowProgress),
                y: SideMenuTransitionLayout.rowClosedYOffset * (1 - rowProgress)
            )
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
            return
        }

        accountHeaderName = nil
        accountHeaderHandle = nil
        accountHeaderAvatarURL = nil

        let normalizedPubkey = account.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheResult = await ProfileCache.shared.resolve(pubkeys: [account.pubkey, normalizedPubkey])
        if let cachedProfile = cacheResult.hits[account.pubkey] ?? cacheResult.hits[normalizedPubkey] {
            accountHeaderName = preferredDisplayName(from: cachedProfile)
            accountHeaderHandle = preferredHandle(from: cachedProfile)
            accountHeaderAvatarURL = preferredAvatarURL(from: cachedProfile)
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

private struct SideMenuPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion && !accessibilityReduceMotion
                    ? 0.96
                    : 1
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion || accessibilityReduceMotion
                    ? nil
                    : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
    }
}
