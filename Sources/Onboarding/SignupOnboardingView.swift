import NostrSDK
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct SignupOnboardingView: View {
    private static let onboardingProfilePublishTimeout: TimeInterval = 3.5
    private static let onboardingFeedPreparationMinimumDuration: TimeInterval = 1.15
    private static let onboardingThemeOptions = AppThemeOption.onboardingOptions

    private enum Step: Int, CaseIterable {
        case name
        case about
        case image
        case interests
        case notifications
    }

    private struct OnboardingButtonStyleOption: Hashable, Identifiable {
        let colorOption: AppPrimaryColorOption

        var id: String { colorOption.id }

        var primaryColor: Color {
            colorOption.color
        }

        var buttonTextColor: Color {
            SignupOnboardingView.contrastingForegroundColor(for: colorOption.color)
        }

        var buttonGradient: LinearGradient {
            LinearGradient(
                colors: [colorOption.color, colorOption.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

    }

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.colorScheme) private var colorScheme

    let canSwitchToSignIn: Bool
    let onSwitchToSignIn: () -> Void
    let onComplete: () -> Void

    init(
        canSwitchToSignIn: Bool,
        onSwitchToSignIn: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        initialPrimaryColorOption: AppPrimaryColorOption = .defaultOption,
        initialThemeOption: AppThemeOption = AppSettingsStore.defaultThemeForCurrentTime()
    ) {
        self.canSwitchToSignIn = canSwitchToSignIn
        self.onSwitchToSignIn = onSwitchToSignIn
        self.onComplete = onComplete

        let resolvedTheme = initialThemeOption.normalizedSelection
        let safeTheme = Self.onboardingThemeOptions.contains(resolvedTheme)
            ? resolvedTheme
            : (Self.onboardingThemeOptions.first ?? .holographicLight)
        _selectedButtonStyleOption = State(initialValue: OnboardingButtonStyleOption(colorOption: initialPrimaryColorOption))
        _selectedThemeOption = State(initialValue: safeTheme)
    }

    @State private var step: Step = .name
    @State private var pendingAccount: GeneratedNostrAccount?
    @State private var displayName = ""
    @State private var handle = ""
    @State private var about = ""
    @State private var selectedButtonStyleOption: OnboardingButtonStyleOption
    @State private var selectedThemeOption: AppThemeOption
    @State private var hasEditedHandle = false
    @State private var selectedTopics = Set<InterestTopic>()
    @State private var signupPrivateKeyBackupEnabled = true
    @State private var signupNotificationsEnabled = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedAvatarData: Data?
    @State private var selectedAvatarPreviewImage: UIImage?
    @State private var selectedAvatarMIMEType = "image/jpeg"
    @State private var selectedAvatarFileExtension = "jpg"
    @State private var selectedBannerItem: PhotosPickerItem?
    @State private var selectedBannerData: Data?
    @State private var selectedBannerPreviewImage: UIImage?
    @State private var selectedBannerMIMEType = "image/jpeg"
    @State private var selectedBannerFileExtension = "jpg"
    @State private var isPreparingAccount = false
    @State private var isLoadingAvatar = false
    @State private var isLoadingBanner = false
    @State private var isFinishing = false
    @State private var errorMessage: String?
    @State private var animateFinishingButton = false

    private let relayClient = NostrRelayClient()

    var body: some View {
        ZStack {
            previewThemePalette.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    content

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }

                    if !isFinishing {
                        footerActions
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
        }
        .toolbarBackground(previewThemePalette.navigationBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(previewColorSchemeOverride)
        .tint(onboardingInputTint)
        .task {
            await preparePendingAccountIfNeeded()
            applyThemePreview()
        }
        .onChange(of: selectedAvatarItem) { _, newValue in
            guard let newValue else { return }
            Task {
                await loadAvatar(from: newValue)
            }
        }
        .onChange(of: selectedBannerItem) { _, newValue in
            guard let newValue else { return }
            Task {
                await loadBanner(from: newValue)
            }
        }
        .onChange(of: displayName) { _, newValue in
            guard !hasEditedHandle else { return }
            handle = suggestedHandle(from: newValue)
        }
        .onChange(of: selectedThemeOption) { _, _ in
            applyThemePreview()
        }
        .onChange(of: isFinishing) { _, isActive in
            guard isActive else {
                animateFinishingButton = false
                return
            }

            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                animateFinishingButton = true
            }
        }
        .onDisappear {
            appSettings.endThemePreview()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isPreparingAccount && pendingAccount == nil {
            VStack(spacing: 14) {
                ProgressView()
                Text("Creating your account…")
                    .font(.subheadline)
                    .foregroundStyle(previewThemePalette.secondaryForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else if isFinishing {
            finishingStep
        } else {
            switch step {
            case .name:
                nameStep
            case .image:
                imageStep
            case .about:
                aboutStep
            case .interests:
                interestsStep
            case .notifications:
                notificationsStep
            }
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntro(
                title: "What should we call you?",
                subtitle: "We’ll use this on your profile. You can change it later."
            )

            onboardingFieldCard {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Name")
                    TextField("Enter your name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .font(.body)
                }
            }

            onboardingFieldCard {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Handle")
                    HStack(spacing: 8) {
                        Text("@")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(previewThemePalette.secondaryForeground)
                        TextField("yourhandle", text: handleBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body)
                    }
                }
            }
        }
    }

    private var imageStep: some View {
        let avatarIsLoading = isLoadingAvatar
        let bannerIsLoading = isLoadingBanner
        let uploadButtonTextColor = selectedButtonStyleOption.buttonTextColor
        let uploadButtonGradient = selectedButtonStyleOption.buttonGradient
        let uploadsDisabled = isFinishing || isLoadingAvatar || isLoadingBanner

        return VStack(alignment: .leading, spacing: 18) {
            stepIntro(
                title: "Customize Profile",
                subtitle: "Pick a primary color and palette, then upload photos if you want. You can change all of this later."
            )

            OnboardingProfilePreviewCard(
                displayName: welcomeName,
                handle: normalizedHandle,
                about: about,
                avatarPreviewImage: selectedAvatarPreviewImage,
                bannerPreviewImage: selectedBannerPreviewImage,
                styleOption: selectedButtonStyleOption,
                themePalette: previewThemePalette,
                selectedAvatarItem: $selectedAvatarItem,
                selectedBannerItem: $selectedBannerItem,
                isLoadingAvatar: avatarIsLoading,
                isLoadingBanner: bannerIsLoading,
                uploadsDisabled: uploadsDisabled,
                uploadButtonTextColor: uploadButtonTextColor,
                uploadButtonGradient: uploadButtonGradient
            )

            onboardingFieldCard {
                VStack(alignment: .leading, spacing: 16) {
                    fieldLabel("Primary Color")

                    HStack(spacing: 10) {
                        ForEach(AppSettingsStore.availablePrimaryColorOptions) { option in
                            primaryColorChip(for: option)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    fieldLabel("Color Palette")

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 140), spacing: 10),
                            GridItem(.flexible(minimum: 140), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ForEach(Self.onboardingThemeOptions) { option in
                            paletteChip(for: option)
                        }
                    }
                }
            }
        }
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntro(
                title: "A preview of you",
                subtitle: "Write a short bio now, or skip and shape this later."
            )

            onboardingFieldCard {
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("About you")

                    ZStack(alignment: .topLeading) {
                        if about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Tell people a little about yourself…")
                                .font(.body)
                                .foregroundStyle(previewThemePalette.tertiaryForeground)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $about)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(false)
                    }
                    .font(.body)
                    .frame(minHeight: 124)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private var interestsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntro(
                title: "Pick your interests",
                subtitle: "Choose a few topics to shape your first feed."
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 140), spacing: 10),
                    GridItem(.flexible(minimum: 140), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(InterestTopic.allCases) { topic in
                    interestChip(for: topic)
                }
            }
        }
    }

    private var notificationsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntro(
                title: "Protect your account",
                subtitle: "Your Interests feed is ready. We’ll save your private key in Keychain. Keep iCloud backup on to restore it on your devices."
            )

            onboardingFieldCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "icloud.and.arrow.up.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(onboardingSecondaryAccent)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("iCloud Keychain Backup")
                                .font(.headline)

                            Text("Keep a private backup so you can restore this account on another device.")
                                .font(.footnote)
                                .foregroundStyle(previewThemePalette.secondaryForeground)
                        }
                    }

                    Toggle("Back Up Private Key", isOn: privateKeyBackupBinding)
                        .tint(onboardingToggleTint)

                    Text(signupPrivateKeyBackupStatusDescription)
                        .font(.footnote)
                        .foregroundStyle(previewThemePalette.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            onboardingFieldCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(onboardingSecondaryAccent)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stay in Halo")
                                .font(.headline)

                            Text("Enable notifications here and iOS will ask for permission right away.")
                                .font(.footnote)
                                .foregroundStyle(previewThemePalette.secondaryForeground)
                        }
                    }

                    Toggle("Enable Notifications", isOn: notificationsBinding)
                        .tint(onboardingToggleTint)

                    Text(signupNotificationsStatusDescription)
                        .font(.footnote)
                        .foregroundStyle(previewThemePalette.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var finishingStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntro(
                title: "Getting your space ready",
                subtitle: "We’re putting together an Interests feed shaped around the topics you picked."
            )

            onboardingFieldCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(selectedButtonStyleOption.primaryColor)

                        Text("This should only take a moment.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(previewThemePalette.foreground)
                    }

                    Text("When this finishes, we’ll open your Interests feed instead of dropping you into the broader network.")
                        .font(.footnote)
                        .foregroundStyle(previewThemePalette.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var footerActions: some View {
        VStack(spacing: 12) {
            Button {
                handlePrimaryAction()
            } label: {
                HStack(spacing: 8) {
                    if isFinishing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(primaryButtonForeground)
                    }
                    Text(primaryButtonTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(primaryButtonBackground, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(primaryButtonBorder, lineWidth: 1)
                }
                .foregroundStyle(primaryButtonForeground)
                .scaleEffect(isFinishing && animateFinishingButton ? 0.985 : 1)
                .shadow(
                    color: primaryButtonShadowColor,
                    radius: primaryButtonShadowRadius,
                    y: primaryButtonShadowYOffset
                )
            }
            .buttonStyle(.plain)
            .disabled(primaryActionDisabled)

            HStack {
                if step != .name {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            errorMessage = nil
                            switch step {
                            case .name:
                                break
                            case .about:
                                step = .name
                            case .image:
                                step = .about
                            case .interests:
                                step = .image
                            case .notifications:
                                step = .interests
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(previewThemePalette.secondaryForeground)
                }

                Spacer()

                if canSkipCurrentStep {
                    Button("Skip for now") {
                        advanceFromOptionalStep()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(previewThemePalette.secondaryForeground)
                }
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 18)
    }

    private func onboardingFieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(previewThemePalette.sheetCardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(previewThemePalette.sheetCardBorder, lineWidth: 1)
            }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(previewThemePalette.mutedForeground)
    }

    private func stepIntro(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.custom("SF Pro Display", size: 31).weight(.bold))
                .foregroundStyle(previewThemePalette.foreground)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(previewThemePalette.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func interestChip(for topic: InterestTopic) -> some View {
        let isSelected = selectedTopics.contains(topic)

        return Button {
            if isSelected {
                selectedTopics.remove(topic)
            } else {
                selectedTopics.insert(topic)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: topic.iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? onboardingChipSelectedForeground : onboardingSecondaryAccent)

                Text(topic.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? onboardingChipSelectedForeground : previewThemePalette.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(onboardingChipSelectedForeground.opacity(0.92))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? onboardingChipSelectedFill : AnyShapeStyle(onboardingChipFill))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isSelected ? onboardingChipSelectedStroke : previewThemePalette.separator.opacity(0.72),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func primaryColorChip(for option: AppPrimaryColorOption) -> some View {
        let isSelected = selectedButtonStyleOption.colorOption == option

        return Button {
            selectedButtonStyleOption = OnboardingButtonStyleOption(colorOption: option)
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 34, height: 34)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(selectedButtonStyleOption.buttonTextColor)
                    }
                }
                .scaleEffect(isSelected ? 1.04 : 1)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Primary color #\(option.hexCode)")
    }

    private func paletteChip(for option: AppThemeOption) -> some View {
        let isSelected = selectedThemeOption == option

        return Button {
            selectedThemeOption = option
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? onboardingChipSelectedForeground : onboardingSecondaryAccent)

                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? onboardingChipSelectedForeground : previewThemePalette.foreground)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(onboardingChipSelectedForeground.opacity(0.92))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? onboardingChipSelectedFill : AnyShapeStyle(onboardingChipFill))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isSelected ? onboardingChipSelectedStroke : previewThemePalette.separator.opacity(0.72),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var handleBinding: Binding<String> {
        Binding(
            get: { handle },
            set: { newValue in
                hasEditedHandle = true
                handle = normalizeHandle(newValue)
            }
        )
    }

    private var primaryButtonTitle: String {
        switch step {
        case .name:
            return "Continue"
        case .image:
            return "Continue"
        case .about:
            return "Continue"
        case .interests:
            return "Continue"
        case .notifications:
            return isFinishing ? "Generating your feed…" : "Finish"
        }
    }

    private var primaryActionDisabled: Bool {
        if isPreparingAccount || isLoadingAvatar || isLoadingBanner || isFinishing || pendingAccount == nil {
            return true
        }

        switch step {
        case .name:
            return normalizedDisplayName.isEmpty || normalizedHandle.isEmpty
        case .image:
            return false
        case .about:
            return false
        case .interests:
            return selectedTopics.isEmpty
        case .notifications:
            return false
        }
    }

    private var primaryButtonBackground: AnyShapeStyle {
        primaryActionDisabled
            ? AnyShapeStyle(previewThemePalette.tertiaryFill)
            : AnyShapeStyle(onboardingPrimaryButtonFill)
    }

    private var primaryButtonForeground: Color {
        primaryActionDisabled ? previewThemePalette.mutedForeground : onboardingPrimaryButtonForeground
    }

    private var primaryButtonBorder: Color {
        if primaryActionDisabled {
            return previewThemePalette.separator.opacity(0.56)
        }

        return effectivePreviewColorScheme == .dark
            ? previewThemePalette.separator.opacity(0.88)
            : previewThemePalette.separator.opacity(0.72)
    }

    private var primaryButtonShadowColor: Color {
        guard !primaryActionDisabled else { return .clear }
        if isFinishing {
            return Color.black.opacity(animateFinishingButton ? 0.18 : 0.10)
        }
        return effectivePreviewColorScheme == .light ? Color.black.opacity(0.08) : .clear
    }

    private var primaryButtonShadowRadius: CGFloat {
        if isFinishing {
            return 18
        }
        return effectivePreviewColorScheme == .light && !primaryActionDisabled ? 10 : 0
    }

    private var primaryButtonShadowYOffset: CGFloat {
        if isFinishing {
            return 8
        }
        return effectivePreviewColorScheme == .light && !primaryActionDisabled ? 5 : 0
    }

    private var onboardingPrimaryButtonFill: LinearGradient {
        selectedButtonStyleOption.buttonGradient
    }

    private var onboardingPrimaryButtonForeground: Color {
        selectedButtonStyleOption.buttonTextColor
    }

    private var onboardingSecondaryAccent: Color {
        previewThemePalette.iconMutedForeground
    }

    private var onboardingToggleTint: Color {
        selectedButtonStyleOption.primaryColor
    }

    private var onboardingInputTint: Color {
        selectedButtonStyleOption.primaryColor
    }

    private var onboardingChipFill: Color {
        previewThemePalette.secondaryBackground
    }

    private var onboardingChipSelectedFill: AnyShapeStyle {
        AnyShapeStyle(selectedButtonStyleOption.buttonGradient)
    }

    private var onboardingChipSelectedForeground: Color {
        selectedButtonStyleOption.buttonTextColor
    }

    private var onboardingChipSelectedStroke: Color {
        selectedButtonStyleOption.primaryColor.opacity(effectivePreviewColorScheme == .dark ? 0.54 : 0.38)
    }

    private var previewThemeOption: AppThemeOption {
        selectedThemeOption.normalizedSelection
    }

    private var previewThemePalette: AppThemePalette {
        let palette = previewThemeOption.palette
        if previewThemeOption == .holographicLight {
            return palette.applyingLightPrimaryAccent(selectedButtonStyleOption.primaryColor)
        }
        return palette
    }

    private var previewColorSchemeOverride: ColorScheme? {
        previewThemeOption.preferredColorScheme
    }

    private var effectivePreviewColorScheme: ColorScheme {
        previewColorSchemeOverride ?? colorScheme
    }

    private var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedHandle: String {
        normalizeHandle(handle.isEmpty ? suggestedHandle(from: displayName) : handle)
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { signupNotificationsEnabled },
            set: { signupNotificationsEnabled = $0 }
        )
    }

    private var privateKeyBackupBinding: Binding<Bool> {
        Binding(
            get: { signupPrivateKeyBackupEnabled },
            set: { signupPrivateKeyBackupEnabled = $0 }
        )
    }

    private var signupPrivateKeyBackupStatusDescription: String {
        signupPrivateKeyBackupEnabled
            ? "On. Your private key will be saved to iCloud Keychain so you can restore it on your devices."
            : "Off. Your private key will stay in this device’s Keychain and will not sync to iCloud."
    }

    private var signupNotificationsStatusDescription: String {
        signupNotificationsEnabled
            ? "iOS will ask for permission when you finish."
            : "Off for now. You can change this later in Settings."
    }

    private var welcomeName: String {
        normalizedDisplayName.isEmpty ? "there" : normalizedDisplayName
    }

    private var canSkipCurrentStep: Bool {
        switch step {
        case .image, .about:
            return true
        case .name, .interests, .notifications:
            return false
        }
    }

    private func handlePrimaryAction() {
        errorMessage = nil

        switch step {
        case .name:
            guard !normalizedDisplayName.isEmpty else {
                errorMessage = "Enter your name to continue."
                return
            }
            guard !normalizedHandle.isEmpty else {
                errorMessage = "Pick a handle to continue."
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                step = .about
            }

        case .about:
            withAnimation(.easeInOut(duration: 0.18)) {
                step = .image
            }

        case .image:
            withAnimation(.easeInOut(duration: 0.18)) {
                step = .interests
            }

        case .interests:
            withAnimation(.easeInOut(duration: 0.18)) {
                step = .notifications
            }

        case .notifications:
            Task {
                await finishSignup()
            }
        }
    }

    private func advanceFromOptionalStep() {
        errorMessage = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            switch step {
            case .about:
                step = .image
            case .image:
                step = .interests
            case .notifications:
                break
            case .name, .interests:
                break
            }
        }
    }

    @MainActor
    private func preparePendingAccountIfNeeded() async {
        guard pendingAccount == nil, !isPreparingAccount else { return }
        isPreparingAccount = true
        defer { isPreparingAccount = false }

        guard let keypair = Keypair() else {
            errorMessage = "Couldn’t generate a new keypair right now."
            return
        }

        pendingAccount = GeneratedNostrAccount(
            pubkey: keypair.publicKey.hex,
            npub: keypair.publicKey.npub,
            nsec: keypair.privateKey.nsec
        )
    }

    @MainActor
    private func loadAvatar(from item: PhotosPickerItem) async {
        guard !isLoadingAvatar else { return }
        isLoadingAvatar = true
        errorMessage = nil

        defer {
            isLoadingAvatar = false
            selectedAvatarItem = nil
        }

        do {
            let preparedMedia = try await MediaUploadPreparation.prepareProfileImageUpload(from: item)
            selectedAvatarData = preparedMedia.data
            selectedAvatarPreviewImage = preparedMedia.previewImage ?? UIImage(data: preparedMedia.data)
            selectedAvatarMIMEType = preparedMedia.mimeType
            selectedAvatarFileExtension = preparedMedia.fileExtension
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func loadBanner(from item: PhotosPickerItem) async {
        guard !isLoadingBanner else { return }
        isLoadingBanner = true
        errorMessage = nil

        defer {
            isLoadingBanner = false
            selectedBannerItem = nil
        }

        do {
            let preparedMedia = try await MediaUploadPreparation.prepareProfileBannerUpload(from: item)
            selectedBannerData = preparedMedia.data
            selectedBannerPreviewImage = preparedMedia.previewImage ?? UIImage(data: preparedMedia.data)
            selectedBannerMIMEType = preparedMedia.mimeType
            selectedBannerFileExtension = preparedMedia.fileExtension
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func finishSignup() async {
        guard !isFinishing, let pendingAccount else { return }
        isFinishing = true
        errorMessage = nil
        let finishStartedAt = Date()

        do {
            let account = try auth.loginWithNsecOrHex(
                pendingAccount.nsec,
                backupPrivateKeyToICloud: signupPrivateKeyBackupEnabled
            )

            appSettings.configure(accountPubkey: account.pubkey)
            appSettings.theme = selectedThemeOption
            applySelectedButtonStyle()

            relaySettings.configure(accountPubkey: account.pubkey, nsec: auth.currentNsec ?? pendingAccount.nsec)
            relaySettings.seedDefaultRelaysForCurrentAccount(publishToBootstrapRelays: true)

            let avatarURL: String?
            do {
                avatarURL = try await uploadAvatarIfNeeded(using: pendingAccount)
            } catch {
                avatarURL = nil
            }

            let bannerURL: String?
            do {
                bannerURL = try await uploadBannerIfNeeded(using: pendingAccount)
            } catch {
                bannerURL = nil
            }

            let interestTopics = InterestTopic.allCases.filter { selectedTopics.contains($0) }
            let interestHashtags = InterestTopic.combinedHashtags(for: interestTopics)

            try? await publishProfileMetadata(
                account: pendingAccount,
                displayName: normalizedDisplayName,
                handle: normalizedHandle,
                about: about.trimmingCharacters(in: .whitespacesAndNewlines),
                avatarURLString: avatarURL,
                bannerURLString: bannerURL
            )

            InterestFeedStore.shared.configure(accountPubkey: account.pubkey)
            InterestFeedStore.shared.seedFromOnboarding(interestTopics)
            if interestHashtags.isEmpty {
                InterestFeedStore.shared.setHashtags([])
            }

            UserDefaults.standard.set(
                HomePrimaryFeedSource.interests.storageValue,
                forKey: HomeFeedViewModel.persistedFeedSourceKey(pubkey: account.pubkey.lowercased())
            )

            await warmInterestsFeed(for: account.pubkey, interestHashtags: interestHashtags)
            await ensureMinimumFeedPreparationDuration(since: finishStartedAt)

            if signupNotificationsEnabled {
                appSettings.notificationsEnabled = true
            }

            appSettings.endThemePreview()
            onComplete()
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isFinishing = false
    }

    private func applyThemePreview() {
        _ = appSettings.beginThemePreview(previewThemeOption)
    }

    @MainActor
    private func warmInterestsFeed(for accountPubkey: String, interestHashtags: [String]) async {
        guard !interestHashtags.isEmpty else { return }

        let readRelayURLs = appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
        guard let primaryRelayURL = readRelayURLs.first else { return }

        let warmupModel = HomeFeedViewModel(
            relayURL: primaryRelayURL,
            readRelayURLs: readRelayURLs
        )
        warmupModel.updateReadRelayURLs(readRelayURLs)
        warmupModel.updateInterestHashtags(interestHashtags)
        warmupModel.updatePollsFeedVisibility(appSettings.pollsFeedVisible)
        warmupModel.updateCustomFeeds(appSettings.customFeeds)
        warmupModel.updateCurrentUserPubkey(accountPubkey)

        await Task.yield()

        let deadline = Date().addingTimeInterval(1.4)
        while Date() < deadline {
            if !warmupModel.isLoading,
               (!warmupModel.items.isEmpty || warmupModel.errorMessage != nil) {
                break
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    @MainActor
    private func ensureMinimumFeedPreparationDuration(since startDate: Date) async {
        let remaining = Self.onboardingFeedPreparationMinimumDuration - Date().timeIntervalSince(startDate)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func uploadAvatarIfNeeded(using account: GeneratedNostrAccount) async throws -> String? {
        guard let selectedAvatarData, !selectedAvatarData.isEmpty else { return nil }

        let filename = "avatar-\(Int(Date().timeIntervalSince1970)).\(selectedAvatarFileExtension)"
        let url = try await ProfileMediaUploadService.shared.uploadProfileImage(
            data: selectedAvatarData,
            mimeType: selectedAvatarMIMEType,
            filename: filename,
            nsec: account.nsec
        )
        return url.absoluteString
    }

    private func uploadBannerIfNeeded(using account: GeneratedNostrAccount) async throws -> String? {
        guard let selectedBannerData, !selectedBannerData.isEmpty else { return nil }

        let filename = "banner-\(Int(Date().timeIntervalSince1970)).\(selectedBannerFileExtension)"
        let url = try await ProfileMediaUploadService.shared.uploadProfileImage(
            data: selectedBannerData,
            mimeType: selectedBannerMIMEType,
            filename: filename,
            nsec: account.nsec
        )
        return url.absoluteString
    }

    private func applySelectedButtonStyle() {
        appSettings.primaryColor = selectedButtonStyleOption.primaryColor
        appSettings.clearButtonGradient()
    }

    private func publishProfileMetadata(
        account: GeneratedNostrAccount,
        displayName: String,
        handle: String,
        about: String,
        avatarURLString: String?,
        bannerURLString: String?
    ) async throws {
        guard let keypair = Keypair(nsec: account.nsec.lowercased()) else {
            throw AuthManagerError.invalidNsecOrHex
        }

        let fields = EditableProfileFields(
            avatarURLString: avatarURLString ?? "",
            bannerURLString: bannerURLString ?? "",
            displayName: displayName,
            handle: handle,
            about: about,
            website: "",
            nip05: "",
            lightningAddress: ""
        )
        let content = try ProfileMetadataEditing.mergedContent(
            fields: fields,
            baseJSON: ["name": handle]
        )
        let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .metadata)
            .content(content)
            .build(signedBy: keypair)

        let eventData = try JSONEncoder().encode(event)

        let relayURLs = appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: relaySettings.readRelayURLs
        )
        let publishCoordinator = OnboardingProfilePublishCoordinator(
            expectedRelayCount: relayURLs.count
        )
        for relayURL in relayURLs {
            let publishEventData = eventData
            let eventID = event.id
            Task.detached(priority: .userInitiated) { [relayClient] in
                do {
                    try await relayClient.publishEvent(
                        relayURL: relayURL,
                        eventData: publishEventData,
                        eventID: eventID,
                        timeout: Self.onboardingProfilePublishTimeout
                    )
                    await publishCoordinator.recordSuccess(relayURL)
                } catch {
                    await publishCoordinator.recordFailure(error)
                }
            }
        }

        _ = try await publishCoordinator.waitForFirstSuccess()

        let localEvent = NostrEvent(
            id: event.id.lowercased(),
            pubkey: event.pubkey.lowercased(),
            createdAt: Int(event.createdAt),
            kind: event.kind.rawValue,
            tags: event.tags.map { [$0.name, $0.value] + $0.otherParameters },
            content: event.content,
            sig: event.signature ?? ""
        )
        await SeenEventStore.shared.store(events: [localEvent])

        if let profile = NostrProfile.decode(from: content) {
            await ProfileCache.shared.store(profiles: [account.pubkey.lowercased(): profile], missed: [])
        }
        NotificationCenter.default.post(
            name: .profileMetadataUpdated,
            object: nil,
            userInfo: ["pubkey": account.pubkey.lowercased()]
        )
    }

    private struct OnboardingProfilePreviewCard: View {
        let displayName: String
        let handle: String
        let about: String
        let avatarPreviewImage: UIImage?
        let bannerPreviewImage: UIImage?
        let styleOption: OnboardingButtonStyleOption
        let themePalette: AppThemePalette
        @Binding var selectedAvatarItem: PhotosPickerItem?
        @Binding var selectedBannerItem: PhotosPickerItem?
        let isLoadingAvatar: Bool
        let isLoadingBanner: Bool
        let uploadsDisabled: Bool
        let uploadButtonTextColor: Color
        let uploadButtonGradient: LinearGradient

        private static let bannerHeight: CGFloat = 132
        private static let avatarSize: CGFloat = 82

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                previewBanner

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom, spacing: 12) {
                        HStack(alignment: .bottom, spacing: 10) {
                            previewAvatar
                            avatarUploadButton
                                .padding(.bottom, 6)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 8) {
                            previewIconCapsule(systemImage: "qrcode")
                            previewIconCapsule(systemImage: "ellipsis")
                            previewFollowCapsule
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(resolvedDisplayName)
                            .font(.system(size: 24, weight: .heavy, design: .default))
                            .foregroundStyle(themePalette.foreground)
                            .lineLimit(2)

                        Text(resolvedHandle)
                            .font(.subheadline)
                            .foregroundStyle(themePalette.secondaryForeground)
                    }

                    Text(resolvedAbout)
                        .font(.body)
                        .foregroundStyle(
                            about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? themePalette.secondaryForeground
                                : themePalette.foreground
                        )
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, -(Self.avatarSize / 2))
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            .background(themePalette.sheetCardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(themePalette.sheetCardBorder, lineWidth: 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 18, y: 8)
        }

        private var resolvedDisplayName: String {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Your Name" : trimmed
        }

        private var resolvedHandle: String {
            let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "@\(trimmed)"
            }

            return "@halo"
        }

        private var resolvedAbout: String {
            let trimmed = about.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Your bio preview will appear here." : trimmed
        }

        private var previewBanner: some View {
            ZStack {
                previewBannerContent

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.08),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0),
                        .init(color: themePalette.sheetCardBackground.opacity(0.30), location: 0.34),
                        .init(color: themePalette.sheetCardBackground.opacity(0.78), location: 0.72),
                        .init(color: themePalette.sheetCardBackground, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .topTrailing) {
                bannerUploadButton
                    .padding(.top, 28)
                    .padding(.trailing, 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.bannerHeight)
            .clipped()
        }

        @ViewBuilder
        private var previewBannerContent: some View {
            if let bannerPreviewImage {
                Image(uiImage: bannerPreviewImage)
                    .resizable()
                    .scaledToFill()
                    .saturation(0.92)
                    .opacity(0.70)
            } else {
                ZStack {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    styleOption.primaryColor.opacity(0.92),
                                    styleOption.primaryColor.opacity(0.54),
                                    themePalette.secondaryBackground
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .background(themePalette.secondaryBackground)

                    Circle()
                        .fill(Color.white.opacity(0.36))
                        .frame(width: 152, height: 152)
                        .blur(radius: 18)
                        .offset(x: 120, y: -40)

                    Circle()
                        .fill(styleOption.primaryColor.opacity(0.16))
                        .frame(width: 188, height: 188)
                        .blur(radius: 28)
                        .offset(x: -132, y: 54)
                }
            }
        }

        private var previewAvatar: some View {
            Group {
                if let avatarPreviewImage {
                    Image(uiImage: avatarPreviewImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle()
                            .fill(styleOption.buttonGradient)

                        Text(String(resolvedDisplayName.prefix(1)).uppercased())
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(styleOption.buttonTextColor)
                    }
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .background(Circle().fill(themePalette.background))
            .clipShape(Circle())
            .overlay {
                Circle().stroke(themePalette.sheetCardBackground, lineWidth: 4)
            }
            .overlay {
                Circle().stroke(themePalette.separator.opacity(0.6), lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 12, y: 7)
        }

        private func previewIconCapsule(systemImage: String) -> some View {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themePalette.foreground)
                .frame(width: 38, height: 36)
                .background(themePalette.tertiaryFill, in: Capsule(style: .continuous))
        }

        private var previewFollowCapsule: some View {
            Text("Follow")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(styleOption.buttonTextColor)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(styleOption.buttonGradient, in: Capsule(style: .continuous))
        }

        private var avatarUploadButton: some View {
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                ZStack {
                    Circle()
                        .fill(uploadButtonGradient)

                    if isLoadingAvatar {
                        ProgressView()
                            .controlSize(.small)
                            .tint(uploadButtonTextColor)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(uploadButtonTextColor)
                    }
                }
                .frame(width: 40, height: 40)
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.8)
                }
                .shadow(color: styleOption.primaryColor.opacity(0.22), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(uploadsDisabled)
            .accessibilityLabel("Upload profile photo")
        }

        private var bannerUploadButton: some View {
            PhotosPicker(selection: $selectedBannerItem, matching: .images) {
                ZStack {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.footnote.weight(.bold))

                        Text("Upload")
                            .font(.caption.weight(.semibold))
                    }
                    .opacity(isLoadingBanner ? 0 : 1)

                    ProgressView()
                        .controlSize(.small)
                        .tint(uploadButtonTextColor)
                        .opacity(isLoadingBanner ? 1 : 0)
                }
                .frame(width: 112, height: 38)
                .foregroundStyle(uploadButtonTextColor)
                .background(uploadButtonGradient, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.8)
                }
            }
            .buttonStyle(.plain)
            .disabled(uploadsDisabled)
            .accessibilityLabel("Upload banner image")
        }
    }

    nonisolated private static func contrastingForegroundColor(for color: Color) -> Color {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .white
        }

        let luminance = (0.299 * Double(red)) + (0.587 * Double(green)) + (0.114 * Double(blue))
        return luminance > 0.68 ? .black : .white
    }

    private func suggestedHandle(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return normalizeHandle(trimmed)
    }

    private func normalizeHandle(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))

        let filtered = trimmed.filter { character in
            if character == "_" || character == "." {
                return true
            }
            return character.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || CharacterSet.letters.contains(scalar)
            }
        }
        return filtered.lowercased()
    }
}

private actor OnboardingProfilePublishCoordinator {
    private let expectedRelayCount: Int
    private var completedFailureCount = 0
    private var firstSuccessfulRelay: URL?
    private var firstError: Error?
    private var continuation: CheckedContinuation<URL, Error>?
    private var isResolved = false

    init(expectedRelayCount: Int) {
        self.expectedRelayCount = expectedRelayCount
    }

    func waitForFirstSuccess() async throws -> URL {
        if let firstSuccessfulRelay {
            return firstSuccessfulRelay
        }

        if completedFailureCount >= expectedRelayCount {
            throw firstError ?? RelayClientError.publishRejected("Couldn’t publish your profile yet.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func recordSuccess(_ relayURL: URL) {
        guard !isResolved else { return }
        firstSuccessfulRelay = relayURL
        isResolved = true
        continuation?.resume(returning: relayURL)
        continuation = nil
    }

    func recordFailure(_ error: Error) {
        guard !isResolved else { return }
        completedFailureCount += 1
        if firstError == nil {
            firstError = error
        }

        guard completedFailureCount >= expectedRelayCount else { return }
        isResolved = true
        continuation?.resume(
            throwing: firstError ?? RelayClientError.publishRejected("Couldn’t publish your profile yet.")
        )
        continuation = nil
    }
}
