import NostrSDK
import SwiftUI

enum AuthSheetTab: String, CaseIterable, Identifiable {
    case signIn = "Sign In"
    case signUp = "Sign Up"
    case accounts = "Accounts"

    var id: String { rawValue }
}

enum ManageAccountsGlassStyle {
    static let darkSurfaceWhiteOpacity: Double = 0.46
    static let lightSurfaceWhiteOpacity: Double = 0.88
    static let darkBorderWhiteOpacity: Double = 0.28
    static let lightBorderBlackOpacity: Double = 0.04
    static let signInCardDarkSurfaceWhiteOpacity = darkSurfaceWhiteOpacity
    static let signInCardLightSurfaceWhiteOpacity = lightSurfaceWhiteOpacity
    static let signInTabContainerDarkSurfaceWhiteOpacity = darkSurfaceWhiteOpacity
    static let signInTabContainerLightSurfaceWhiteOpacity = lightSurfaceWhiteOpacity
    static let signInPrivateKeyLabelUsesInkColor = true
    static let primaryTextWhiteOpacity: Double = 0.96
    static let secondaryTextWhiteOpacity: Double = 0.80
    static let textShadowOpacity: Double = 0.24
    static let darkShadowOpacity: Double = 0.18
    static let lightShadowOpacity: Double = 0.08
    static let controlWhiteTintOpacity: Double = 0.44
    static let legacyControlWhiteTintDarkOpacity: Double = 0.18
    static let closeButtonUsesGlassSurface = true
    static let closeButtonUsesPrimaryColorFill = false
    static let closeButtonLightWhiteTintOpacity: Double = 0.34
    static let closeButtonDarkWhiteTintOpacity: Double = 0.18
    static let deleteIconUsesPrimaryTextColor = true
}

enum ManageAccountSwitchMotion {
    enum Timing {
        case selection
        case halo
        case toast
    }

    static let activePillTitle = "Active"
    static let pressedScale: CGFloat = 0.975
    static let avatarSelectedScale: CGFloat = 1.06
    static let haloInitialScale: CGFloat = 0.84
    static let haloFinalScale: CGFloat = 1.62
    static let haloInitialOpacity: Double = 0.58
    static let haloFinalOpacity: Double = 0
    static let haloLineWidth: CGFloat = 2
    static let activeRowDarkFillOpacity: Double = 0.18
    static let activeRowLightFillOpacity: Double = 0.10
    static let activeRowDarkStrokeOpacity: Double = 0.34
    static let activeRowLightStrokeOpacity: Double = 0.18

    static func toastText(for displayName: String) -> String {
        "Switched to \(displayName)"
    }

    static func duration(_ timing: Timing, reduceMotion: Bool) -> TimeInterval {
        guard !reduceMotion else { return 0 }

        switch timing {
        case .selection:
            return 0.34
        case .halo:
            return 0.72
        case .toast:
            return 1.65
        }
    }

    static func selectionAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: duration(.selection, reduceMotion: false), dampingFraction: 0.76)
    }

    static func pressAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: 0.12)
    }

    static func haloAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: duration(.halo, reduceMotion: false))
    }

    static func toastAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.32, dampingFraction: 0.82)
    }

    static func activePillTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .scale(scale: 0.88).combined(with: .opacity)
    }

    static func toastTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
    }

    static func nanoseconds(for duration: TimeInterval) -> UInt64 {
        UInt64((max(duration, 0) * 1_000_000_000).rounded())
    }
}

enum AuthSheetChromeLayout {
    static let headerHorizontalPadding: CGFloat = 16
    static let headerTopPadding: CGFloat = 8
    static let headerBottomPadding: CGFloat = 14
    static let sharedContentTopSpacerHeight: CGFloat = 24
    static let sharedContentHorizontalPadding: CGFloat = 20
    static let sharedContentBottomPadding: CGFloat = 48
    static let bottomSafeAreaSpacerHeight: CGFloat = 18
    static let tabCardHorizontalPadding: CGFloat = 10
    static let tabCardVerticalPadding: CGFloat = 10

    static func navigationTitle(for tab: AuthSheetTab) -> String {
        tab == .signUp ? "Create Account" : "Account"
    }

    static func hidesSystemNavigationBar(for tab: AuthSheetTab) -> Bool {
        tab != .signUp
    }

    static func showsCustomHeader(for tab: AuthSheetTab) -> Bool {
        tab == .signIn || tab == .accounts
    }

    static func showsSystemCloseButton(for tab: AuthSheetTab) -> Bool {
        tab == .signUp
    }

    static func contentTopSpacerHeight(for tab: AuthSheetTab) -> CGFloat {
        showsCustomHeader(for: tab) ? sharedContentTopSpacerHeight : 0
    }

    static func contentHorizontalPadding(for tab: AuthSheetTab) -> CGFloat {
        showsCustomHeader(for: tab) ? sharedContentHorizontalPadding : 0
    }

    static func customHeaderTopPadding(safeAreaInset: CGFloat) -> CGFloat {
        max(0, safeAreaInset) + headerTopPadding
    }
}

private struct AccountSwitchPulse: Equatable {
    let id: UUID
    let accountID: String

    init(accountID: String) {
        id = UUID()
        self.accountID = accountID
    }
}

struct AuthSheetView: View {
    private enum PostAuthDestination {
        case dismiss
        case accounts
    }

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dismiss) private var dismiss

    private let initialTab: AuthSheetTab
    private let availableTabs: [AuthSheetTab]
    private let signUpSeedPrimaryColorOption: AppPrimaryColorOption
    private let signUpSeedTheme: AppThemeOption
    private let onSelectedTabChange: (AuthSheetTab) -> Void
    @State private var selectedTab: AuthSheetTab
    @State private var privateKeyInput = ""
    @State private var signInError: String?
    @State private var accountProfiles: [String: NostrProfile] = [:]
    @State private var pendingAccountRemoval: AuthAccount?
    @State private var accountSwitchPulse: AccountSwitchPulse?
    @State private var accountSwitchToastText: String?
    @State private var accountSwitchFeedbackTask: Task<Void, Never>?
    @State private var postAuthDestination: PostAuthDestination

    init(
        initialTab: AuthSheetTab = .signIn,
        availableTabs: [AuthSheetTab] = AuthSheetTab.allCases,
        signUpSeedPrimaryColorOption: AppPrimaryColorOption = .defaultOption,
        signUpSeedTheme: AppThemeOption = AppSettingsStore.defaultThemeForCurrentTime(),
        onSelectedTabChange: @escaping (AuthSheetTab) -> Void = { _ in }
    ) {
        let validTabs = availableTabs.isEmpty ? [.signIn] : availableTabs
        self.initialTab = initialTab
        self.availableTabs = validTabs
        self.signUpSeedPrimaryColorOption = signUpSeedPrimaryColorOption
        self.signUpSeedTheme = signUpSeedTheme
        self.onSelectedTabChange = onSelectedTabChange
        let resolvedInitialTab = validTabs.contains(initialTab) ? initialTab : validTabs[0]
        _selectedTab = State(initialValue: resolvedInitialTab)
        _postAuthDestination = State(initialValue: resolvedInitialTab == .accounts ? .accounts : .dismiss)
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectedTab == .signUp {
                    SignupOnboardingView(
                        canSwitchToSignIn: availableTabs.contains(.signIn),
                        onSwitchToSignIn: {
                            postAuthDestination = auth.accounts.isEmpty ? .dismiss : .accounts
                            selectedTab = .signIn
                        },
                        onComplete: {
                            handlePostAuthenticationCompletion()
                        },
                        initialPrimaryColorOption: resolvedSignUpSeedPrimaryColorOption,
                        initialThemeOption: resolvedSignUpSeedTheme
                    )
                } else if selectedTab == .signIn {
                    signInExperience
                } else {
                    accountsExperience
                }
            }
            .navigationTitle(AuthSheetChromeLayout.navigationTitle(for: selectedTab))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(
                AuthSheetChromeLayout.hidesSystemNavigationBar(for: selectedTab) ? .hidden : .visible,
                for: .navigationBar
            )
            .onChange(of: selectedTab) { _, newValue in
                onSelectedTabChange(newValue)
                switch newValue {
                case .accounts:
                    postAuthDestination = .accounts
                case .signIn, .signUp:
                    postAuthDestination = auth.accounts.isEmpty ? .dismiss : .accounts
                }
            }
            .task(id: accountsProfileLookupID) {
                await refreshSavedAccountProfiles()
            }
            .onReceive(NotificationCenter.default.publisher(for: .profileMetadataUpdated)) { _ in
                Task {
                    await refreshSavedAccountProfiles()
                }
            }
            .toolbar {
                if AuthSheetChromeLayout.showsSystemCloseButton(for: selectedTab) {
                    ToolbarItem(placement: .topBarTrailing) {
                        closeToolbarButton
                    }
                }
            }
            .confirmationDialog(
                "Remove account?",
                isPresented: Binding(
                    get: { pendingAccountRemoval != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingAccountRemoval = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let pendingAccountRemoval {
                    Button("Remove Account", role: .destructive) {
                        auth.removeAccount(pendingAccountRemoval)
                        if auth.accounts.isEmpty {
                            dismiss()
                        }
                        self.pendingAccountRemoval = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingAccountRemoval = nil
                }
            } message: {
                if let pendingAccountRemoval {
                    Text("Remove \(accountDisplayName(for: pendingAccountRemoval)) from this device?")
                }
            }
        }
    }

    private var signInExperience: some View {
        GeometryReader { geometry in
            ZStack {
                signInBackdrop
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        Color.clear.frame(height: AuthSheetChromeLayout.contentTopSpacerHeight(for: .signIn))

                        if availableTabs.count > 1 {
                            authTabBarCard
                        }

                        if #available(iOS 26.0, *) {
                            VStack(spacing: 24) {
                                signInGlassCard
                                signInRestoreCard
                            }
                        } else {
                            VStack(spacing: 18) {
                                legacySignInCard
                                legacyRestoreCard
                            }
                        }

                    }
                    .padding(.horizontal, AuthSheetChromeLayout.contentHorizontalPadding(for: .signIn))
                    .padding(.bottom, AuthSheetChromeLayout.sharedContentBottomPadding)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    authSheetHeader
                        .padding(.horizontal, AuthSheetChromeLayout.headerHorizontalPadding)
                        .padding(
                            .top,
                            AuthSheetChromeLayout.customHeaderTopPadding(safeAreaInset: geometry.safeAreaInsets.top)
                        )
                        .padding(.bottom, AuthSheetChromeLayout.headerBottomPadding)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: AuthSheetChromeLayout.bottomSafeAreaSpacerHeight)
                }
            }
        }
    }

    private var authSheetHeader: some View {
        ZStack {
            Text("Account")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)

            HStack {
                Spacer()
                closeToolbarButton
            }
        }
    }

    private var signInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in to your account")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                SecureField("Account access", text: $privateKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(.separator).opacity(0.42), lineWidth: 1.15)
                    }

                if let signInError {
                    Text(signInError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    handleSignIn()
                } label: {
                    Text("Sign In")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .foregroundStyle(authPrimaryButtonForeground)
                        .background(
                            Capsule(style: .continuous)
                                .fill(authPrimaryButtonFill)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(authPrimaryButtonBorder, lineWidth: 1)
                        }
                        .shadow(
                            color: colorScheme == .light ? Color.black.opacity(0.08) : .clear,
                            radius: colorScheme == .light ? 10 : 0,
                            y: colorScheme == .light ? 5 : 0
                        )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ICloudKeyRestoreView {
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore from iCloud")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Use an account already backed up to iCloud Keychain.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(.separator).opacity(0.28), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @available(iOS 26.0, *)
    private var signInGlassCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to your account")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(authInk)

            signInPrivateKeyField

            if let signInError {
                Text(signInError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            signInPrimaryButton
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(authBlurCardBackground(cornerRadius: 28))
    }

    private var authTabBarCard: some View {
        Group {
            if #available(iOS 26.0, *) {
                FlowCapsuleTabBar(
                    selection: $selectedTab,
                    items: availableTabs,
                    selectedBackground: Color.white.opacity(0.98),
                    selectedForeground: authInk,
                    selectedStroke: Color.white.opacity(0.72),
                    title: { $0.rawValue }
                )
                .padding(.horizontal, AuthSheetChromeLayout.tabCardHorizontalPadding)
                .padding(.vertical, AuthSheetChromeLayout.tabCardVerticalPadding)
                .background(authTabBarBackground)
            } else {
                FlowCapsuleTabBar(
                    selection: $selectedTab,
                    items: availableTabs,
                    selectedBackground: Color.white.opacity(0.98),
                    selectedForeground: authInk,
                    selectedStroke: Color.white.opacity(0.72),
                    title: { $0.rawValue }
                )
                .padding(.horizontal, AuthSheetChromeLayout.tabCardHorizontalPadding)
                .padding(.vertical, AuthSheetChromeLayout.tabCardVerticalPadding)
                .background(authTabBarBackground)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var accountsExperience: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                accountsBackdrop
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        Color.clear.frame(height: AuthSheetChromeLayout.contentTopSpacerHeight(for: .accounts))

                        if availableTabs.count > 1 {
                            authTabBarCard
                        }

                        accountsListCard

                        if auth.isLoggedIn {
                            accountsLogoutCard
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AuthSheetChromeLayout.contentHorizontalPadding(for: .accounts))
                    .padding(.bottom, AuthSheetChromeLayout.sharedContentBottomPadding)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    authSheetHeader
                        .padding(.horizontal, AuthSheetChromeLayout.headerHorizontalPadding)
                        .padding(
                            .top,
                            AuthSheetChromeLayout.customHeaderTopPadding(safeAreaInset: geometry.safeAreaInsets.top)
                        )
                        .padding(.bottom, AuthSheetChromeLayout.headerBottomPadding)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: AuthSheetChromeLayout.bottomSafeAreaSpacerHeight)
                }

                accountSwitchToastOverlay
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .onDisappear {
            accountSwitchFeedbackTask?.cancel()
        }
    }

    private var signInBackdrop: some View {
        authBackdrop(using: signInBackdropArtwork, showsBottomFade: false)
    }

    private var accountsBackdrop: some View {
        authBackdrop(using: accountsBackdropArtwork, showsBottomFade: false)
    }

    private func authBackdrop<Artwork: View>(
        using artwork: Artwork,
        showsBottomFade: Bool = true
    ) -> some View {
        ZStack {
            artwork

            LinearGradient(
                colors: showsBottomFade
                    ? [
                        Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08),
                        .clear,
                        Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10)
                    ]
                    : [
                        Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06),
                        .clear
                    ],
                startPoint: .top,
                endPoint: .bottom
            )

            if showsBottomFade {
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0),
                        .init(color: appSettings.themePalette.background.opacity(0.18), location: 0.38),
                        .init(color: appSettings.themePalette.background.opacity(0.52), location: 0.66),
                        .init(color: appSettings.themePalette.background.opacity(0.82), location: 0.84),
                        .init(color: appSettings.themePalette.background, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private var signInPrivateKeyField: some View {
        SecureField("Account access", text: $privateKeyInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.22))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(authBorderColor(darkOpacity: 0.18), lineWidth: 1.15)
            }
    }

    private var signInPrimaryButton: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button {
                    handleSignIn()
                } label: {
                    Text("Sign In")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .foregroundStyle(signInPrimaryButtonForeground)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular
                        .tint(signInPrimaryButtonFill)
                        .interactive(),
                    in: Capsule(style: .continuous)
                )
                .disabled(!canSubmitSignIn)
                .opacity(canSubmitSignIn ? 1 : 0.78)
            } else {
                Button {
                    handleSignIn()
                } label: {
                    Text("Sign In")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .foregroundStyle(signInPrimaryButtonForeground)
                        .background(
                            Capsule(style: .continuous)
                                .fill(signInPrimaryButtonFill)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(signInPrimaryButtonBorder, lineWidth: 1)
                        }
                        .shadow(
                            color: colorScheme == .light && canSubmitSignIn
                                ? Color.black.opacity(0.08)
                                : .clear,
                            radius: colorScheme == .light && canSubmitSignIn ? 10 : 0,
                            y: colorScheme == .light && canSubmitSignIn ? 5 : 0
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitSignIn)
            }
        }
    }

    private var signInRestoreCard: some View {
        Group {
            if #available(iOS 26.0, *) {
                NavigationLink {
                    ICloudKeyRestoreView {
                        dismiss()
                    }
                } label: {
                    signInRestoreLabel
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .background(authBlurCardBackground(cornerRadius: 24))
            } else {
                legacyRestoreCard
            }
        }
    }

    private var signInRestoreLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore from iCloud")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Use an account already backed up to iCloud Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var legacySignInCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to your account")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(authInk)

            signInPrivateKeyField

            if let signInError {
                Text(signInError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            signInPrimaryButton
        }
        .padding(18)
        .background(authBlurCardBackground(cornerRadius: 28))
    }

    private var legacyRestoreCard: some View {
        NavigationLink {
            ICloudKeyRestoreView {
                dismiss()
            }
        } label: {
            signInRestoreLabel
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(authBlurCardBackground(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private func authBlurCardBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape
                    .fill(Color.white.opacity(
                        colorScheme == .dark
                            ? ManageAccountsGlassStyle.signInCardDarkSurfaceWhiteOpacity
                            : ManageAccountsGlassStyle.signInCardLightSurfaceWhiteOpacity
                    ))
            }
            .overlay {
                shape
                    .stroke(
                        authBorderColor(darkOpacity: ManageAccountsGlassStyle.darkBorderWhiteOpacity),
                        lineWidth: 1.1
                    )
            }
            .shadow(
                color: Color.black.opacity(
                    colorScheme == .dark
                        ? ManageAccountsGlassStyle.darkShadowOpacity
                        : ManageAccountsGlassStyle.lightShadowOpacity
                ),
                radius: colorScheme == .dark ? 20 : 16,
                y: colorScheme == .dark ? 10 : 8
            )
    }

    private func accountsSurfaceBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape
                    .fill(Color.white.opacity(
                        colorScheme == .dark
                            ? ManageAccountsGlassStyle.darkSurfaceWhiteOpacity
                            : ManageAccountsGlassStyle.lightSurfaceWhiteOpacity
                    ))
            }
            .overlay {
                shape
                    .stroke(
                        authBorderColor(darkOpacity: ManageAccountsGlassStyle.darkBorderWhiteOpacity),
                        lineWidth: 1.1
                    )
            }
            .shadow(
                color: Color.black.opacity(
                    colorScheme == .dark
                        ? ManageAccountsGlassStyle.darkShadowOpacity
                        : ManageAccountsGlassStyle.lightShadowOpacity
                ),
                radius: colorScheme == .dark ? 20 : 16,
                y: colorScheme == .dark ? 10 : 8
            )
    }

    private var authBlurCapsuleBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(
                        colorScheme == .dark
                            ? ManageAccountsGlassStyle.signInTabContainerDarkSurfaceWhiteOpacity
                            : ManageAccountsGlassStyle.signInTabContainerLightSurfaceWhiteOpacity
                    ))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        authBorderColor(darkOpacity: ManageAccountsGlassStyle.darkBorderWhiteOpacity),
                        lineWidth: 1.1
                    )
            }
            .shadow(
                color: Color.black.opacity(
                    colorScheme == .dark
                        ? ManageAccountsGlassStyle.darkShadowOpacity
                        : ManageAccountsGlassStyle.lightShadowOpacity
                ),
                radius: colorScheme == .dark ? 20 : 16,
                y: colorScheme == .dark ? 10 : 8
            )
    }

    private var authTabBarBackground: some View {
        Group {
            if selectedTab == .accounts {
                accountsCapsuleBackground
            } else {
                authBlurCapsuleBackground
            }
        }
    }

    private var accountsCapsuleBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(
                        colorScheme == .dark
                            ? ManageAccountsGlassStyle.darkSurfaceWhiteOpacity
                            : ManageAccountsGlassStyle.lightSurfaceWhiteOpacity
                    ))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        authBorderColor(darkOpacity: ManageAccountsGlassStyle.darkBorderWhiteOpacity),
                        lineWidth: 1.1
                    )
            }
            .shadow(
                color: Color.black.opacity(
                    colorScheme == .dark
                        ? ManageAccountsGlassStyle.darkShadowOpacity
                        : ManageAccountsGlassStyle.lightShadowOpacity
                ),
                radius: colorScheme == .dark ? 20 : 16,
                y: colorScheme == .dark ? 10 : 8
            )
    }

    private var authInk: Color {
        Color(red: 0.06, green: 0.10, blue: 0.18)
    }

    private var accountsPrimaryTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(ManageAccountsGlassStyle.primaryTextWhiteOpacity)
            : authInk
    }

    private var accountsSecondaryTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(ManageAccountsGlassStyle.secondaryTextWhiteOpacity)
            : authInk.opacity(0.62)
    }

    private var accountsTextShadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(ManageAccountsGlassStyle.textShadowOpacity)
            : .clear
    }

    private var accountsTextShadowRadius: CGFloat {
        colorScheme == .dark ? 5 : 0
    }

    private var accountsTextShadowYOffset: CGFloat {
        colorScheme == .dark ? 2 : 0
    }

    private var authPrimaryButtonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.96) : authInk
    }

    private var authPrimaryButtonForeground: Color {
        colorScheme == .dark ? authInk : .white
    }

    private var authPrimaryButtonBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : authInk.opacity(0.16)
    }

    private var normalizedPrivateKeyInput: String {
        privateKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitSignIn: Bool {
        !normalizedPrivateKeyInput.isEmpty
    }

    private var signInAccentColor: Color {
        resolvedSignUpSeedPrimaryColorOption.color
    }

    private var signInPrimaryButtonFill: Color {
        signInAccentColor.opacity(canSubmitSignIn ? 0.96 : 0.42)
    }

    private var signInPrimaryButtonForeground: Color {
        let resolved = UIColor(signInAccentColor)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .white
        }
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        let baseForeground: Color = luminance > 0.68 ? .black : .white
        return baseForeground.opacity(canSubmitSignIn ? 1 : 0.74)
    }

    private var signInPrimaryButtonBorder: Color {
        signInAccentColor.opacity(canSubmitSignIn ? 0.20 : 0.14)
    }

    private var closeButtonForeground: Color {
        colorScheme == .dark ? .white.opacity(0.92) : authInk
    }

    private var closeButtonBackground: Color {
        Color.white.opacity(
            colorScheme == .dark
                ? ManageAccountsGlassStyle.closeButtonDarkWhiteTintOpacity
                : ManageAccountsGlassStyle.closeButtonLightWhiteTintOpacity
        )
    }

    private var closeButtonBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(ManageAccountsGlassStyle.darkBorderWhiteOpacity)
            : Color.black.opacity(0.08)
    }

    private var closeButtonGlassBackground: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay {
                Circle()
                    .fill(closeButtonBackground)
            }
            .overlay {
                Circle()
                    .stroke(closeButtonBorder, lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08),
                radius: colorScheme == .dark ? 18 : 14,
                y: colorScheme == .dark ? 8 : 6
            )
    }

    private var closeToolbarButton: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(closeButtonForeground)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular
                        .tint(closeButtonBackground)
                        .interactive(),
                    in: Circle()
                )
            } else {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(closeButtonForeground)
                        .frame(width: 36, height: 36)
                        .background {
                            closeButtonGlassBackground
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private var signInBackdropArtwork: some View {
        if appSettings.textOnlyMode {
            authBackdropFallbackArtwork
        } else {
            Image("signin-background")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .clipped()
        }
    }

    @ViewBuilder
    private var accountsBackdropArtwork: some View {
        if appSettings.textOnlyMode {
            authBackdropFallbackArtwork
        } else {
            Image("manage-accounts-background")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .clipped()
        }
    }

    private var authBackdropFallbackArtwork: some View {
        ZStack {
            Rectangle()
                .fill(appSettings.primaryGradient)
                .opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.96 : 0.84)
                .background(appSettings.themePalette.secondaryBackground)

            Circle()
                .fill(Color.white.opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.34 : 0.18))
                .frame(width: 170, height: 170)
                .blur(radius: 20)
                .offset(x: 124, y: -44)

            Circle()
                .fill(appSettings.primaryColor.opacity(0.24))
                .frame(width: 190, height: 190)
                .blur(radius: 28)
                .offset(x: -138, y: 54)
        }
    }

    private var accountsListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if auth.accounts.isEmpty {
                Text("Your saved accounts will show up here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(auth.accounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(for: account)

                    if index < auth.accounts.count - 1 {
                        Divider()
                            .padding(.leading, 82)
                            .padding(.trailing, 18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accountsSurfaceBackground(cornerRadius: 28))
    }

    private func accountRow(for account: AuthAccount) -> some View {
        let isCurrentAccount = auth.currentAccount?.id == account.id
        let isSwitchingAccount = accountSwitchPulse?.accountID == account.id

        return HStack(spacing: 14) {
            Button {
                performAccountSwitch(to: account)
            } label: {
                HStack(spacing: 14) {
                    accountAvatar(for: account, size: 50)
                        .scaleEffect(
                            isSwitchingAccount && !accessibilityReduceMotion
                                ? ManageAccountSwitchMotion.avatarSelectedScale
                                : 1
                        )
                        .overlay {
                            if let pulse = accountSwitchPulse,
                               pulse.accountID == account.id,
                               !accessibilityReduceMotion {
                                ManageAccountSwitchHalo(
                                    color: appSettings.primaryColor,
                                    reduceMotion: accessibilityReduceMotion
                                )
                                .id(pulse.id)
                            }
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountDisplayName(for: account))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let handle = accountHandle(for: account) {
                            Text(handle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)

                    if isCurrentAccount {
                        activeAccountPill
                            .transition(ManageAccountSwitchMotion.activePillTransition(
                                reduceMotion: accessibilityReduceMotion
                            ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ManageAccountSwitchRowButtonStyle(reduceMotion: accessibilityReduceMotion))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Switch to \(accountDisplayName(for: account))")
            .accessibilityHint(isCurrentAccount ? "This is the active account." : "Makes this account active.")

            accountDeleteButton(for: account)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            if isCurrentAccount {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(appSettings.primaryColor.opacity(
                        colorScheme == .dark
                            ? ManageAccountSwitchMotion.activeRowDarkFillOpacity
                            : ManageAccountSwitchMotion.activeRowLightFillOpacity
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(appSettings.primaryColor.opacity(
                                colorScheme == .dark
                                    ? ManageAccountSwitchMotion.activeRowDarkStrokeOpacity
                                    : ManageAccountSwitchMotion.activeRowLightStrokeOpacity
                            ), lineWidth: 1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }
        }
        .animation(
            ManageAccountSwitchMotion.selectionAnimation(reduceMotion: accessibilityReduceMotion),
            value: auth.currentAccount?.id
        )
    }

    private var activeAccountPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appSettings.primaryColor)
                .frame(width: 6, height: 6)

            Text(ManageAccountSwitchMotion.activePillTitle)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(accountsPrimaryTextColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.68))
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    appSettings.primaryColor.opacity(colorScheme == .dark ? 0.46 : 0.20),
                    lineWidth: 1
                )
        }
        .shadow(
            color: accountsTextShadowColor,
            radius: accountsTextShadowRadius,
            y: accountsTextShadowYOffset
        )
        .accessibilityLabel("Active account")
    }

    @ViewBuilder
    private var accountSwitchToastOverlay: some View {
        if let accountSwitchToastText {
            Text(accountSwitchToastText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accountsPrimaryTextColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(accountsSurfaceBackground(cornerRadius: 22))
                .transition(ManageAccountSwitchMotion.toastTransition(
                    reduceMotion: accessibilityReduceMotion
                ))
                .allowsHitTesting(false)
                .accessibilityLabel(accountSwitchToastText)
        }
    }

    @ViewBuilder
    private func accountDeleteButton(for account: AuthAccount) -> some View {
        let label = Image(systemName: "minus")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(accountsPrimaryTextColor)
            .shadow(
                color: accountsTextShadowColor,
                radius: accountsTextShadowRadius,
                y: accountsTextShadowYOffset
            )
            .frame(width: 38, height: 38)
            .overlay {
                Circle()
                    .stroke(
                        authBorderColor(darkOpacity: ManageAccountsGlassStyle.darkBorderWhiteOpacity),
                        lineWidth: 0.95
                    )
            }

        if #available(iOS 26.0, *) {
            Button(role: .destructive) {
                pendingAccountRemoval = account
            } label: {
                label
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular
                    .tint(Color.white.opacity(ManageAccountsGlassStyle.controlWhiteTintOpacity))
                    .interactive(),
                in: Circle()
            )
            .accessibilityLabel("Remove account")
        } else {
            Button(role: .destructive) {
                pendingAccountRemoval = account
            } label: {
                label
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Circle()
                                    .fill(Color.white.opacity(
                                        colorScheme == .dark
                                            ? ManageAccountsGlassStyle.legacyControlWhiteTintDarkOpacity
                                            : 0.10
                                    ))
                            }
                    )
            }
            .buttonStyle(.plain)
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.06),
                radius: colorScheme == .dark ? 16 : 12,
                y: colorScheme == .dark ? 8 : 6
            )
            .accessibilityLabel("Remove account")
        }
    }

    private var accountsLogoutCard: some View {
        Button("Log Out", role: .destructive) {
            auth.logout()
        }
        .font(.headline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(authBlurCardBackground(cornerRadius: 24))
        .buttonStyle(.plain)
    }

    private func performAccountSwitch(to account: AuthAccount) {
        guard auth.currentAccount?.id != account.id else { return }

        let displayName = accountDisplayName(for: account)
        let toastText = ManageAccountSwitchMotion.toastText(for: displayName)
        let pulse = AccountSwitchPulse(accountID: account.id)
        let reduceMotion = accessibilityReduceMotion

        accountSwitchFeedbackTask?.cancel()
        animateAccountSwitch(using: ManageAccountSwitchMotion.selectionAnimation(reduceMotion: reduceMotion)) {
            auth.switchAccount(to: account)
            accountSwitchPulse = reduceMotion ? nil : pulse
            accountSwitchToastText = toastText
        }

        accountSwitchFeedbackTask = Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(nanoseconds: ManageAccountSwitchMotion.nanoseconds(
                    for: ManageAccountSwitchMotion.duration(.halo, reduceMotion: false)
                ))
                guard !Task.isCancelled else { return }
                if accountSwitchPulse?.id == pulse.id {
                    accountSwitchPulse = nil
                }
            }

            let toastDelay = reduceMotion
                ? 1.15
                : max(
                    ManageAccountSwitchMotion.duration(.toast, reduceMotion: false)
                        - ManageAccountSwitchMotion.duration(.halo, reduceMotion: false),
                    0
                )
            try? await Task.sleep(nanoseconds: ManageAccountSwitchMotion.nanoseconds(for: toastDelay))
            guard !Task.isCancelled else { return }

            animateAccountSwitch(using: ManageAccountSwitchMotion.toastAnimation(reduceMotion: reduceMotion)) {
                if accountSwitchToastText == toastText {
                    accountSwitchToastText = nil
                }
            }
        }
    }

    private func animateAccountSwitch(using animation: Animation?, updates: () -> Void) {
        if let animation {
            withAnimation(animation) {
                updates()
            }
        } else {
            updates()
        }
    }

    private func handleSignIn() {
        guard canSubmitSignIn else { return }
        signInError = nil
        do {
            _ = try auth.loginWithNsecOrHex(normalizedPrivateKeyInput)
            privateKeyInput = ""
            handlePostAuthenticationCompletion()
        } catch {
            signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func handlePostAuthenticationCompletion() {
        switch postAuthDestination {
        case .dismiss:
            dismiss()
        case .accounts:
            selectedTab = .accounts
            Task {
                await refreshSavedAccountProfiles()
            }
        }
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    @MainActor
    private var accountsProfileLookupID: String {
        let accountsSignature = auth.accounts
            .map(\.pubkey)
            .sorted()
            .joined(separator: ",")
        let relaySignature = effectiveReadRelayURLs
            .map(\.absoluteString)
            .map { $0.lowercased() }
            .joined(separator: ",")
        return "\(accountsSignature)|\(relaySignature)"
    }

    @MainActor
    private func refreshSavedAccountProfiles() async {
        let pubkeys = auth.accounts.map { $0.pubkey.lowercased() }
        guard !pubkeys.isEmpty else {
            accountProfiles = [:]
            return
        }

        let cacheResult = await ProfileCache.shared.resolve(pubkeys: pubkeys)
        var mergedProfiles = cacheResult.hits

        let fetchedProfiles = await NostrFeedService().fetchProfiles(
            relayURLs: effectiveReadRelayURLs,
            pubkeys: pubkeys
        )
        for (pubkey, profile) in fetchedProfiles {
            mergedProfiles[pubkey.lowercased()] = profile
        }

        accountProfiles = mergedProfiles
    }

    private func profile(for account: AuthAccount) -> NostrProfile? {
        accountProfiles[account.pubkey.lowercased()]
    }

    private func authBorderColor(darkOpacity: Double) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(darkOpacity)
            : Color.black.opacity(ManageAccountsGlassStyle.lightBorderBlackOpacity)
    }

    private var resolvedSignUpSeedPrimaryColorOption: AppPrimaryColorOption {
        auth.currentAccount == nil ? signUpSeedPrimaryColorOption : appSettings.primaryColorOption
    }

    private var resolvedSignUpSeedTheme: AppThemeOption {
        auth.currentAccount == nil ? signUpSeedTheme : appSettings.theme
    }

    private func accountDisplayName(for account: AuthAccount) -> String {
        if let profile = profile(for: account) {
            if let displayName = normalized(profile.displayName), !displayName.isEmpty {
                return displayName
            }
            if let name = normalized(profile.name), !name.isEmpty {
                return name
            }
        }
        return shortNostrIdentifier(account.pubkey)
    }

    private func accountHandle(for account: AuthAccount) -> String? {
        if let profile = profile(for: account) {
            if let name = normalized(profile.name), !name.isEmpty {
                return "@\(name)"
            }
            if let displayName = normalized(profile.displayName), !displayName.isEmpty {
                return "@\(displayName.replacingOccurrences(of: " ", with: "").lowercased())"
            }
        }
        return nil
    }

    private func avatarURL(for account: AuthAccount) -> URL? {
        profile(for: account)?.resolvedAvatarURL
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    @ViewBuilder
    private func accountAvatar(for account: AuthAccount, size: CGFloat = 42) -> some View {
        let fallbackName = accountDisplayName(for: account)
        if let avatarURL = avatarURL(for: account) {
            CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    accountAvatarFallback(name: fallbackName, account: account)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            accountAvatarFallback(name: fallbackName, account: account, size: size)
        }
    }

    private func accountAvatarFallback(name: String, account: AuthAccount, size: CGFloat = 42) -> some View {
        ZStack {
            Circle()
                .fill(appSettings.avatarFallbackGradient(forAccountPubkey: account.pubkey))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: max(16, size * 0.34), weight: .semibold))
                .foregroundStyle(appSettings.avatarFallbackForeground(forAccountPubkey: account.pubkey))
        }
        .frame(width: size, height: size)
    }
}

private struct ManageAccountSwitchRowButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion
                    ? ManageAccountSwitchMotion.pressedScale
                    : 1
            )
            .animation(
                ManageAccountSwitchMotion.pressAnimation(reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

private struct ManageAccountSwitchHalo: View {
    let color: Color
    let reduceMotion: Bool
    @State private var isExpanded = false

    var body: some View {
        Circle()
            .stroke(
                color.opacity(
                    isExpanded
                        ? ManageAccountSwitchMotion.haloFinalOpacity
                        : ManageAccountSwitchMotion.haloInitialOpacity
                ),
                lineWidth: ManageAccountSwitchMotion.haloLineWidth
            )
            .scaleEffect(
                isExpanded
                    ? ManageAccountSwitchMotion.haloFinalScale
                    : ManageAccountSwitchMotion.haloInitialScale
            )
            .opacity(reduceMotion ? 0 : 1)
            .onAppear {
                guard !reduceMotion else { return }

                if let animation = ManageAccountSwitchMotion.haloAnimation(reduceMotion: false) {
                    withAnimation(animation) {
                        isExpanded = true
                    }
                } else {
                    isExpanded = true
                }
            }
    }
}
