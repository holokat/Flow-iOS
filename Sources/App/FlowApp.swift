import CoreMotion
import SwiftUI
import UIKit

enum AppBrand {
    static let displayName = "Halo"
}

@main
struct FlowApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authManager = AuthManager()
    @StateObject private var appSettings = AppSettingsStore.shared
    @StateObject private var relaySettings = RelaySettingsStore.shared
    @StateObject private var followStore = FollowStore.shared
    @StateObject private var toastCenter = AppToastCenter()
    @StateObject private var composeSheetCoordinator = AppComposeSheetCoordinator()
    @StateObject private var composeDraftStore = AppComposeDraftStore()
    @StateObject private var breakReminderCoordinator = BreakReminderCoordinator()
    @State private var launchSplashSelection = WelcomeArtworkSelection.initial()
    @State private var isLaunchSplashVisible = false
    @State private var hasPresentedLaunchSplash = false

    init() {
        FlowMediaCache.configureSharedURLCache()
    }

    var body: some Scene {
        WindowGroup {
            appContent
        }
    }

    private var appContent: some View {
        Group {
            if authManager.isLoggedIn {
                MainTabShellView()
            } else {
                WelcomeOnboardingView()
            }
        }
            .overlay {
                GlobalProfileQRCodeBridge()
            }
            .overlay {
                BreakReminderOverlayHost(coordinator: breakReminderCoordinator)
            }
            .overlay(alignment: .top) {
                AppToastOverlay()
            }
            .overlay {
                if isLaunchSplashVisible, authManager.isLoggedIn {
                    AppLaunchSplashOverlay(selection: launchSplashSelection)
                }
            }
            .environmentObject(authManager)
            .environmentObject(appSettings)
            .environmentObject(relaySettings)
            .environmentObject(followStore)
            .environmentObject(toastCenter)
            .environmentObject(composeSheetCoordinator)
            .environmentObject(composeDraftStore)
            .environmentObject(breakReminderCoordinator)
            .font(appSettings.appFont(.body))
            .tint(appSettings.primaryColor)
            .preferredColorScheme(appSettings.preferredColorScheme)
            .environment(\.dynamicTypeSize, appSettings.dynamicTypeSize)
            .task {
                appSettings.configure(accountPubkey: authManager.currentAccount?.pubkey)
                relaySettings.configure(
                    accountPubkey: authManager.currentAccount?.pubkey,
                    nsec: authManager.currentNsec
                )
                await presentLaunchSplashIfNeeded()
                updateGlobalTypographyAppearance()
                updateBreakReminderMonitoring()
                await MainActor.run {
                    AppIconRotator.rotateWeeklyIfNeeded()
                }

                Task(priority: .utility) {
                    await appSettings.refreshNotificationAuthorizationStatus()
                    await presentPendingSharedComposeDraftIfPossible()
                }
            }
            .onChange(of: authManager.currentAccount?.pubkey) { _, newValue in
                appSettings.configure(accountPubkey: newValue)
                relaySettings.configure(
                    accountPubkey: newValue,
                    nsec: authManager.currentNsec
                )
                updateBreakReminderMonitoring()
                Task {
                    await presentPendingSharedComposeDraftIfPossible()
                }
            }
            .onChange(of: appSettings.breakReminderInterval) { _, _ in
                updateBreakReminderMonitoring()
            }
            .onChange(of: appSettings.activeFontOption.rawValue) { _, _ in
                updateGlobalTypographyAppearance()
            }
            .onChange(of: appSettings.fontSize) { _, _ in
                updateGlobalTypographyAppearance()
            }
            .onChange(of: appSettings.activeTheme.rawValue) { _, _ in
                updateGlobalTypographyAppearance()
            }
            .onChange(of: appSettings.previewTheme?.rawValue) { _, _ in
                updateGlobalTypographyAppearance()
            }
            .onChange(of: composeSheetCoordinator.draft?.id) { _, newValue in
                guard newValue == nil else { return }
                Task {
                    await presentPendingSharedComposeDraftIfPossible()
                }
            }
            .onChange(of: followStore.lastActionFeedback?.id) { _, _ in
                guard let feedback = followStore.lastActionFeedback else { return }
                Task {
                    await presentFollowToast(for: feedback)
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                updateBreakReminderMonitoring()
                guard newValue == .active else { return }
                Task { @MainActor in
                    AppIconRotator.rotateWeeklyIfNeeded()
                }
                Task(priority: .utility) {
                    await presentPendingSharedComposeDraftIfPossible()
                }
            }
            .onOpenURL { url in
                guard FlowSharedComposeDraftStore.canHandleIncomingURL(url) else { return }
                Task {
                    await presentPendingSharedComposeDraftIfPossible()
                }
            }
    }

    @MainActor
    private func presentPendingSharedComposeDraftIfPossible() async {
        guard authManager.currentAccount != nil else { return }
        guard composeSheetCoordinator.draft == nil else { return }
        guard let pendingDraft = FlowSharedComposeDraftStore.takePendingDraft(),
              !pendingDraft.attachments.isEmpty else {
            return
        }

        composeSheetCoordinator.presentSharedMedia(attachments: pendingDraft.attachments)
    }

    @MainActor
    private func updateGlobalTypographyAppearance() {
        let navigationBar = UINavigationBar.appearance()
        let navigationTitleColor = UIColor(appSettings.themePalette.foreground)

        navigationBar.titleTextAttributes = [
            .font: appSettings.appUIFont(.headline, weight: .semibold),
            .foregroundColor: navigationTitleColor
        ]
        navigationBar.largeTitleTextAttributes = [
            .font: appSettings.appUIFont(.largeTitle, weight: .bold),
            .foregroundColor: navigationTitleColor
        ]

        // Scope to UINavigationBar only. UIBarButtonItem.appearance() unscoped
        // applies the custom font to every UIBarButtonItem in the process,
        // including the prediction chips iOS renders inside the keyboard's
        // QuickType bar. Custom fonts without emoji glyphs (and most do not)
        // can cause the keyboard to suppress emoji predictions.
        let barButtonFont = appSettings.appUIFont(.body, weight: .semibold)
        let scopedBarButton = UIBarButtonItem.appearance(whenContainedInInstancesOf: [UINavigationBar.self])
        scopedBarButton.setTitleTextAttributes([.font: barButtonFont], for: .normal)
        scopedBarButton.setTitleTextAttributes([.font: barButtonFont], for: .highlighted)
        scopedBarButton.setTitleTextAttributes([.font: barButtonFont], for: .disabled)
    }

    private func updateBreakReminderMonitoring() {
        breakReminderCoordinator.update(
            isEnabled: authManager.currentAccount != nil,
            interval: appSettings.breakReminderInterval,
            scenePhase: scenePhase
        )
    }

    @MainActor
    private func presentLaunchSplashIfNeeded() async {
        guard authManager.isLoggedIn else { return }
        guard !hasPresentedLaunchSplash else { return }

        hasPresentedLaunchSplash = true
        launchSplashSelection = WelcomeArtworkSelection.initial()
        withAnimation(.easeInOut(duration: 0.20)) {
            isLaunchSplashVisible = true
        }

        try? await Task.sleep(nanoseconds: 4_000_000_000)

        withAnimation(.spring(response: 0.68, dampingFraction: 0.90)) {
            isLaunchSplashVisible = false
        }
    }

    @MainActor
    private func presentFollowToast(for feedback: FollowStore.ActionFeedback) async {
        let message = await followToastMessage(for: feedback)
        toastCenter.show(
            message,
            style: feedback.didFollow ? .success : .info
        )
    }

    private func followToastMessage(for feedback: FollowStore.ActionFeedback) async -> String {
        if feedback.pubkeys.count == 1,
           let pubkey = feedback.pubkeys.first,
           let label = await followToastLabel(for: pubkey) {
            return "\(feedback.didFollow ? "Followed" : "Unfollowed") \(label)"
        }

        if feedback.pubkeys.count > 1 {
            return feedback.didFollow
                ? "Followed \(feedback.pubkeys.count) accounts"
                : "Unfollowed \(feedback.pubkeys.count) accounts"
        }

        return feedback.didFollow ? "Followed account" : "Unfollowed account"
    }

    private func followToastLabel(for pubkey: String) async -> String? {
        let profile = await ProfileCache.shared.cachedProfile(pubkey: pubkey)
        if let displayName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return "@\(name)"
        }
        return nil
    }
}

@MainActor
final class AppComposeSheetCoordinator: ObservableObject {
    @Published var draft: AppComposeSheetDraft?

    func presentNewNote() {
        draft = AppComposeSheetDraft()
    }

    func presentRemix(
        attachment: ComposeMediaAttachment,
        replyTargetEvent: NostrEvent?
    ) {
        draft = AppComposeSheetDraft(
            initialUploadedAttachments: [attachment],
            replyTargetEvent: replyTargetEvent
        )
    }

    func presentMediaAttachment(_ attachment: ComposeMediaAttachment) {
        draft = AppComposeSheetDraft(
            initialUploadedAttachments: [attachment]
        )
    }

    func presentReply(
        to event: NostrEvent,
        displayNameHint: String? = nil,
        handleHint: String? = nil,
        avatarURLHint: URL? = nil
    ) {
        draft = AppComposeSheetDraft(
            replyTargetEvent: event,
            replyTargetDisplayNameHint: displayNameHint,
            replyTargetHandleHint: handleHint,
            replyTargetAvatarURLHint: avatarURLHint
        )
    }

    func presentQuote(_ quoteDraft: ReshareQuoteDraft) {
        draft = AppComposeSheetDraft(
            initialText: quoteDraft.initialText,
            initialAdditionalTags: quoteDraft.additionalTags,
            quotedEvent: quoteDraft.quotedEvent,
            quotedDisplayNameHint: quoteDraft.quotedDisplayNameHint,
            quotedHandleHint: quoteDraft.quotedHandleHint,
            quotedAvatarURLHint: quoteDraft.quotedAvatarURLHint
        )
    }

    func presentSharedMedia(attachments: [SharedComposeAttachment]) {
        draft = AppComposeSheetDraft(
            initialSharedAttachments: attachments
        )
    }

    func dismiss() {
        draft = nil
    }
}

struct AppComposeSheetDraft: Identifiable {
    let id = UUID()
    var initialText: String = ""
    var initialAdditionalTags: [[String]] = []
    var initialUploadedAttachments: [ComposeMediaAttachment] = []
    var initialSharedAttachments: [SharedComposeAttachment] = []
    var initialSelectedMentions: [ComposeSelectedMention] = []
    var initialPollDraft: ComposePollDraft? = nil
    var replyTargetEvent: NostrEvent? = nil
    var replyTargetDisplayNameHint: String? = nil
    var replyTargetHandleHint: String? = nil
    var replyTargetAvatarURLHint: URL? = nil
    var quotedEvent: NostrEvent? = nil
    var quotedDisplayNameHint: String? = nil
    var quotedHandleHint: String? = nil
    var quotedAvatarURLHint: URL? = nil
    var savedDraftID: UUID? = nil

    init(
        initialText: String = "",
        initialAdditionalTags: [[String]] = [],
        initialUploadedAttachments: [ComposeMediaAttachment] = [],
        initialSharedAttachments: [SharedComposeAttachment] = [],
        initialSelectedMentions: [ComposeSelectedMention] = [],
        initialPollDraft: ComposePollDraft? = nil,
        replyTargetEvent: NostrEvent? = nil,
        replyTargetDisplayNameHint: String? = nil,
        replyTargetHandleHint: String? = nil,
        replyTargetAvatarURLHint: URL? = nil,
        quotedEvent: NostrEvent? = nil,
        quotedDisplayNameHint: String? = nil,
        quotedHandleHint: String? = nil,
        quotedAvatarURLHint: URL? = nil,
        savedDraftID: UUID? = nil
    ) {
        self.initialText = initialText
        self.initialAdditionalTags = initialAdditionalTags
        self.initialUploadedAttachments = initialUploadedAttachments
        self.initialSharedAttachments = initialSharedAttachments
        self.initialSelectedMentions = initialSelectedMentions
        self.initialPollDraft = initialPollDraft
        self.replyTargetEvent = replyTargetEvent
        self.replyTargetDisplayNameHint = replyTargetDisplayNameHint
        self.replyTargetHandleHint = replyTargetHandleHint
        self.replyTargetAvatarURLHint = replyTargetAvatarURLHint
        self.quotedEvent = quotedEvent
        self.quotedDisplayNameHint = quotedDisplayNameHint
        self.quotedHandleHint = quotedHandleHint
        self.quotedAvatarURLHint = quotedAvatarURLHint
        self.savedDraftID = savedDraftID
    }

    init(savedDraft: SavedComposeDraft) {
        self.init(
            initialText: savedDraft.snapshot.text,
            initialAdditionalTags: savedDraft.snapshot.additionalTags,
            initialUploadedAttachments: savedDraft.snapshot.uploadedAttachments,
            initialSelectedMentions: savedDraft.snapshot.selectedMentions,
            initialPollDraft: savedDraft.snapshot.pollDraft,
            replyTargetEvent: savedDraft.snapshot.replyTargetEvent,
            replyTargetDisplayNameHint: savedDraft.snapshot.replyTargetDisplayNameHint,
            replyTargetHandleHint: savedDraft.snapshot.replyTargetHandleHint,
            replyTargetAvatarURLHint: savedDraft.snapshot.replyTargetAvatarURLHint,
            quotedEvent: savedDraft.snapshot.quotedEvent,
            quotedDisplayNameHint: savedDraft.snapshot.quotedDisplayNameHint,
            quotedHandleHint: savedDraft.snapshot.quotedHandleHint,
            quotedAvatarURLHint: savedDraft.snapshot.quotedAvatarURLHint,
            savedDraftID: savedDraft.id
        )
    }
}

private struct GlobalProfileQRCodeBridge: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var auth: AuthManager

    @State private var isMonitoringOrientation = false
    @StateObject private var flipMonitor = QRCodeFlipMonitor()

    private let overlayController = GlobalProfileQRCodeOverlayController.shared

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onAppear {
                guard !isMonitoringOrientation else { return }
                isMonitoringOrientation = true
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                flipMonitor.start()
                syncPresentation()
            }
            .onDisappear {
                guard isMonitoringOrientation else { return }
                isMonitoringOrientation = false
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                flipMonitor.stop()
                overlayController.dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                syncPresentation()
            }
            .onChange(of: flipMonitor.isQRCodeFlipActive) { _, _ in
                syncPresentation()
            }
            .onChange(of: auth.currentAccount?.id) { _, _ in
                syncPresentation(forceRefresh: true)
            }
            .onChange(of: scenePhase) { _, _ in
                syncPresentation(forceRefresh: true)
            }
    }

    private func syncPresentation(forceRefresh: Bool = false) {
        overlayController.update(
            orientation: UIDevice.current.orientation,
            isMotionFlipActive: flipMonitor.isQRCodeFlipActive,
            currentAccount: auth.currentAccount,
            scenePhase: scenePhase,
            forceRefresh: forceRefresh
        )
    }
}

@MainActor
private final class QRCodeFlipMonitor: ObservableObject {
    @Published private(set) var isQRCodeFlipActive = false

    private static let activationGravityYThreshold = 0.82
    private static let sustainGravityYThreshold = 0.62
    private static let activationHorizontalTolerance = 0.45
    private static let sustainHorizontalTolerance = 0.62
    private static let activationDepthTolerance = 0.5
    private static let sustainDepthTolerance = 0.72
    private static let requiredInactiveSamplesForDismissal = 3

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var isMonitoring = false
    private var inactiveSampleCount = 0

    init() {
        motionQueue.name = "com.21media.haloapp.qr-flip-monitor"
        motionQueue.qualityOfService = .userInteractive
    }

    func start() {
        guard !isMonitoring, motionManager.isDeviceMotionAvailable else { return }

        isMonitoring = true
        motionManager.deviceMotionUpdateInterval = 0.2
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            Task { @MainActor in
                self.updateFlipState(using: motion.gravity)
            }
        }
    }

    func stop() {
        guard isMonitoring else { return }

        isMonitoring = false
        motionManager.stopDeviceMotionUpdates()
        inactiveSampleCount = 0
        isQRCodeFlipActive = false
    }

    private func updateFlipState(using gravity: CMAcceleration) {
        if Self.isStrongQRCodeFlip(gravity: gravity) {
            inactiveSampleCount = 0
            isQRCodeFlipActive = true
            return
        }

        guard isQRCodeFlipActive else {
            inactiveSampleCount = 0
            return
        }

        if Self.shouldKeepQRCodeFlipActive(gravity: gravity) {
            inactiveSampleCount = 0
            return
        }

        inactiveSampleCount += 1
        guard inactiveSampleCount >= Self.requiredInactiveSamplesForDismissal else { return }

        inactiveSampleCount = 0
        isQRCodeFlipActive = false
    }

    // Fallback for devices/OS versions where upside-down orientation notifications are unreliable.
    private static func isStrongQRCodeFlip(gravity: CMAcceleration) -> Bool {
        gravity.y > activationGravityYThreshold &&
            abs(gravity.x) < activationHorizontalTolerance &&
            abs(gravity.z) < activationDepthTolerance
    }

    private static func shouldKeepQRCodeFlipActive(gravity: CMAcceleration) -> Bool {
        gravity.y > sustainGravityYThreshold &&
            abs(gravity.x) < sustainHorizontalTolerance &&
            abs(gravity.z) < sustainDepthTolerance
    }
}

@MainActor
private final class GlobalProfileQRCodeOverlayController {
    static let shared = GlobalProfileQRCodeOverlayController()

    private var overlayWindow: UIWindow?
    private var overlayHostingController: UIHostingController<GlobalPresentedProfileQRCodeContainer>?
    private var pendingPresentationTask: Task<Void, Never>?
    private var presentedPubkey: String?

    func update(
        orientation: UIDeviceOrientation,
        isMotionFlipActive: Bool,
        currentAccount: AuthAccount?,
        scenePhase: ScenePhase,
        forceRefresh: Bool = false
    ) {
        guard scenePhase == .active, let currentAccount else {
            dismiss()
            return
        }

        if orientation == .portraitUpsideDown || isMotionFlipActive {
            presentIfNeeded(for: currentAccount, forceRefresh: forceRefresh)
            return
        }

        switch orientation {
        case .faceUp, .faceDown, .unknown:
            break
        default:
            dismiss()
        }
    }

    func dismiss() {
        pendingPresentationTask?.cancel()
        pendingPresentationTask = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
        overlayHostingController = nil
        presentedPubkey = nil
    }

    private func presentIfNeeded(for account: AuthAccount, forceRefresh: Bool) {
        let shouldRefresh = forceRefresh || presentedPubkey != account.pubkey
        guard shouldRefresh || overlayWindow == nil else { return }

        pendingPresentationTask?.cancel()
        presentedPubkey = account.pubkey

        pendingPresentationTask = Task { [weak self] in
            guard let self else { return }

            let presentation = await self.buildPresentation(for: account)
            guard !Task.isCancelled else { return }
            self.show(presentation)
        }
    }

    private func buildPresentation(for account: AuthAccount) async -> GlobalProfileQRCodePresentation {
        let profile = await ProfileCache.shared.cachedProfile(pubkey: account.pubkey)
        let qrCodeImage = await QRCodeRenderer.renderAsync(payload: "nostr:\(account.npub)")

        return GlobalProfileQRCodePresentation(
            displayName: preferredDisplayName(from: profile, fallbackPubkey: account.pubkey),
            handle: preferredHandle(from: profile, fallbackPubkey: account.pubkey),
            avatarURL: preferredAvatarURL(from: profile),
            qrCodeImage: qrCodeImage
        )
    }

    private func show(_ presentation: GlobalProfileQRCodePresentation) {
        guard let windowScene = activeWindowScene() else { return }

        let content = GlobalPresentedProfileQRCodeContainer(
            trigger: .automatic,
            displayName: presentation.displayName,
            handle: presentation.handle,
            avatarURL: presentation.avatarURL,
            qrCodeImage: presentation.qrCodeImage,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        if let overlayHostingController {
            overlayHostingController.rootView = content
            overlayWindow?.isHidden = false
            return
        }

        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .black
        overlayHostingController = hostingController

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.windowLevel = .alert + 1
        window.rootViewController = hostingController
        window.isHidden = false

        overlayWindow = window
    }

    private func activeWindowScene() -> UIWindowScene? {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        return windowScenes.first(where: { scene in
            scene.activationState == .foregroundActive &&
                scene.windows.contains(where: \.isKeyWindow)
        }) ?? windowScenes.first(where: { $0.activationState == .foregroundActive })
            ?? windowScenes.first(where: { $0.activationState == .foregroundInactive })
    }

    private func preferredDisplayName(from profile: NostrProfile?, fallbackPubkey: String) -> String {
        if let displayName = trimmedNonEmpty(profile?.displayName) {
            return displayName
        }
        if let name = trimmedNonEmpty(profile?.name) {
            return name
        }
        return shortNostrIdentifier(fallbackPubkey)
    }

    private func preferredHandle(from profile: NostrProfile?, fallbackPubkey: String) -> String {
        if let name = trimmedNonEmpty(profile?.name) {
            return "@\(normalizedHandleComponent(from: name))"
        }
        if let displayName = trimmedNonEmpty(profile?.displayName) {
            return "@\(normalizedHandleComponent(from: displayName))"
        }
        return "@\(shortNostrIdentifier(fallbackPubkey).lowercased())"
    }

    private func preferredAvatarURL(from profile: NostrProfile?) -> URL? {
        profile?.resolvedAvatarURL
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalizedHandleComponent(from value: String) -> String {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return compact.isEmpty ? "user" : compact
    }
}

private struct GlobalPresentedProfileQRCodeContainer: View {
    @ObservedObject private var appSettings = AppSettingsStore.shared

    let trigger: FullScreenQRCodeTrigger
    let displayName: String
    let handle: String?
    let avatarURL: URL?
    let qrCodeImage: UIImage?
    let onDismiss: () -> Void

    var body: some View {
        PresentedProfileQRCodeView(
            trigger: trigger,
            displayName: displayName,
            handle: handle,
            avatarURL: avatarURL,
            qrCodeImage: qrCodeImage,
            onDismiss: onDismiss
        )
        .environmentObject(appSettings)
    }
}

private struct GlobalProfileQRCodePresentation {
    let displayName: String
    let handle: String?
    let avatarURL: URL?
    let qrCodeImage: UIImage?
}

enum AppToastStyle {
    case success
    case info
    case error

    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "checkmark.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .success:
            return .green
        case .info:
            return .accentColor
        case .error:
            return .red
        }
    }
}

struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let style: AppToastStyle
}

@MainActor
final class AppToastCenter: ObservableObject {
    @Published private(set) var toast: AppToast?

    private var dismissalTask: Task<Void, Never>?

    func show(_ message: String, style: AppToastStyle = .success, duration: TimeInterval = 2.2) {
        dismissalTask?.cancel()

        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            toast = AppToast(message: message, style: style)
        }

        dismissalTask = Task { [weak self] in
            let safeDuration = max(duration, 0.8)
            let nanoseconds = UInt64(safeDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    self?.toast = nil
                }
            }
        }
    }

    func dismiss() {
        dismissalTask?.cancel()
        dismissalTask = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            toast = nil
        }
    }
}

struct AppToastOverlay: View {
    @EnvironmentObject private var toastCenter: AppToastCenter

    var body: some View {
        VStack(spacing: 0) {
            if let toast = toastCenter.toast {
                AppToastBanner(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: toastCenter.toast?.id)
    }
}

private struct AppToastBanner: View {
    let toast: AppToast

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: toast.style.iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(toast.style.accentColor)

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(toast.style.accentColor.opacity(0.22), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .combine)
    }
}
