import AVFoundation
import NostrSDK
import SwiftUI
import UIKit

struct ProfileQRScannerFlowView: View {
    private struct MentionMetadataDecoder: MetadataCoding {}

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @ObservedObject private var followStore = FollowStore.shared

    let onOpenProfile: (String) -> Void

    @State private var phase: ScanPhase = .scanner

    private let service = NostrFeedService()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                switch phase {
                case .scanner:
                    scannerContent
                case .loading:
                    loadingContent
                case .loaded(let profile):
                    resultContent(profile)
                case .invalid(let message):
                    feedbackContent(
                        systemImage: "exclamationmark.triangle",
                        title: "Code not recognized",
                        message: message,
                        primaryTitle: "Scan Again",
                        primaryAction: { phase = .scanner }
                    )
                case .cameraDenied:
                    feedbackContent(
                        systemImage: "camera.fill.badge.ellipsis",
                        title: "Camera access is off",
                        message: "Allow camera access in System Settings to scan profile QR codes.",
                        primaryTitle: "Open System Settings",
                        primaryAction: openAppSettings,
                        secondaryTitle: "Try Again",
                        secondaryAction: { phase = .scanner }
                    )
                case .cameraUnavailable:
                    feedbackContent(
                        systemImage: "camera.metering.unknown",
                        title: "Camera unavailable",
                        message: "This device can't access a camera for scanning right now.",
                        primaryTitle: "Close",
                        primaryAction: { dismiss() }
                    )
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(phase.isScannerLike ? "Close" : "Back") {
                        if phase.isScannerLike {
                            dismiss()
                        } else {
                            phase = .scanner
                        }
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .loaded:
            return "Scanned Profile"
        default:
            return "Scan Code"
        }
    }

    private var scannerContent: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 18)

            VStack(spacing: 10) {
                Text("Scan a profile QR code")
                    .font(.custom("SF Pro Display", size: 28).weight(.semibold))
                    .foregroundStyle(.white)

                Text("Point your camera at another Halo profile to open or follow them instantly.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            ZStack {
                ProfileQRCodeScannerCameraView(
                    onCodeScanned: { value in
                        Task {
                            await resolveScannedCode(value)
                        }
                    },
                    onPermissionDenied: {
                        phase = .cameraDenied
                    },
                    onCameraUnavailable: {
                        phase = .cameraUnavailable
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)

                scannerGuideOverlay
            }
            .frame(height: 440)
            .padding(.horizontal, 24)
            .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 16)

            Text("Halo and compatible profile codes are supported.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))

            Spacer(minLength: 16)
        }
    }

    private var scannerGuideOverlay: some View {
        GeometryReader { geometry in
            let frameWidth = min(geometry.size.width * 0.62, 250)
            let frameHeight = frameWidth

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [10, 10]))
                .frame(width: frameWidth, height: frameHeight)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private var loadingContent: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .tint(.white)
                .scaleEffect(1.15)
            Text("Loading profile…")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private func resultContent(_ profile: ScannedProfilePreview) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 26)

            scannedAvatarView(for: profile)
                .frame(width: 98, height: 98)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }

            VStack(spacing: 6) {
                Text(profile.displayName)
                    .font(.custom("SF Pro Display", size: 30).weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if let handle = profile.handle, !handle.isEmpty {
                    Text(handle)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text(profile.pubkey == auth.currentAccount?.pubkey ? "This is you." : "Ready to connect.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.56))
            }
            .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Button {
                    onOpenProfile(profile.pubkey)
                } label: {
                    Text("View Profile")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)

                if profile.pubkey != auth.currentAccount?.pubkey {
                    Button {
                        followStore.follow(profile.pubkey)
                        toastCenter.show("Following \(profile.displayName)")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: followStore.isFollowing(profile.pubkey) ? "checkmark" : "plus")
                            Text(followStore.isFollowing(profile.pubkey) ? "Following" : "Follow")
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(Color.white.opacity(followStore.isFollowing(profile.pubkey) ? 0.16 : 0.12))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.9)
                        )
                    }
                    .buttonStyle(.plain)
                    .followCelebration(
                        trigger: followStore.followCelebrationToken(for: profile.pubkey),
                        accentColor: .white
                    )
                    .disabled(followStore.isFollowing(profile.pubkey) || auth.currentNsec == nil)
                }

                Button {
                    phase = .scanner
                } label: {
                    Text("Scan Another")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            if auth.currentNsec == nil, profile.pubkey != auth.currentAccount?.pubkey {
                Text("Sign in to follow people from a scan.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.56))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()
        }
    }

    private func feedbackContent(
        systemImage: String,
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                Text(title)
                    .font(.custom("SF Pro Display", size: 28).weight(.semibold))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                Button(action: primaryAction) {
                    Text(primaryTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)

                if let secondaryTitle, let secondaryAction {
                    Button(action: secondaryAction) {
                        Text(secondaryTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    private func scannedAvatarView(for profile: ScannedProfilePreview) -> some View {
        Group {
            if let avatarURL = profile.avatarURL {
                CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        scannedAvatarFallback(for: profile)
                    }
                }
            } else {
                scannedAvatarFallback(for: profile)
            }
        }
    }

    private func scannedAvatarFallback(for profile: ScannedProfilePreview) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
            Text(String(profile.displayName.prefix(1)).uppercased())
                .font(.custom("SF Pro Display", size: 34).weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private func resolveScannedCode(_ rawValue: String) async {
        guard let pubkey = resolvedProfilePubkey(from: rawValue) else {
            await MainActor.run {
                phase = .invalid("That QR code doesn’t look like a compatible profile.")
            }
            return
        }

        await MainActor.run {
            phase = .loading
        }

        let preview = await loadProfilePreview(pubkey: pubkey)
        await MainActor.run {
            phase = .loaded(preview)
        }
    }

    private func loadProfilePreview(pubkey: String) async -> ScannedProfilePreview {
        let normalizedPubkey = pubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var resolvedProfile = await service.cachedProfile(pubkey: normalizedPubkey)
        if resolvedProfile == nil {
            resolvedProfile = await service.fetchProfile(
                relayURLs: effectiveReadRelayURLs,
                pubkey: normalizedPubkey,
                fetchTimeout: 4,
                relayFetchMode: .firstNonEmptyRelay
            )
        }

        let displayName = preferredDisplayName(from: resolvedProfile, fallbackPubkey: normalizedPubkey)
        return ScannedProfilePreview(
            pubkey: normalizedPubkey,
            displayName: displayName,
            handle: preferredHandle(from: resolvedProfile, fallbackPubkey: normalizedPubkey),
            avatarURL: preferredAvatarURL(from: resolvedProfile)
        )
    }

    private var effectiveReadRelayURLs: [URL] {
        let relayURLs = relaySettings.readRelayURLs
        return relayURLs.isEmpty ? [AppSettingsStore.slowModeRelayURL] : relayURLs
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

    private func resolvedProfilePubkey(from raw: String) -> String? {
        let normalized = normalizedIdentifier(raw)
        guard !normalized.isEmpty else { return nil }

        if normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
            return normalized
        }

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

    private func normalizedIdentifier(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if trimmed.hasPrefix("nostr:") {
            return String(trimmed.dropFirst("nostr:".count))
        }

        return trimmed
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private extension ProfileQRScannerFlowView {
    struct ScannedProfilePreview: Equatable {
        let pubkey: String
        let displayName: String
        let handle: String?
        let avatarURL: URL?
    }

    enum ScanPhase: Equatable {
        case scanner
        case loading
        case loaded(ScannedProfilePreview)
        case invalid(String)
        case cameraDenied
        case cameraUnavailable

        var isScannerLike: Bool {
            switch self {
            case .scanner, .cameraDenied, .cameraUnavailable:
                return true
            case .loading, .loaded, .invalid:
                return false
            }
        }
    }
}

private struct ProfileQRCodeScannerCameraView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    let onPermissionDenied: () -> Void
    let onCameraUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> ProfileQRCodeScannerViewController {
        let controller = ProfileQRCodeScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ProfileQRCodeScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: ProfileQRCodeScannerViewController, coordinator: Coordinator) {
        uiViewController.stopSession()
    }

    final class Coordinator: NSObject, ProfileQRCodeScannerViewControllerDelegate {
        private let parent: ProfileQRCodeScannerCameraView

        init(_ parent: ProfileQRCodeScannerCameraView) {
            self.parent = parent
        }

        func qrScannerViewController(_ controller: ProfileQRCodeScannerViewController, didScan value: String) {
            parent.onCodeScanned(value)
        }

        func qrScannerViewControllerDidDenyPermission(_ controller: ProfileQRCodeScannerViewController) {
            parent.onPermissionDenied()
        }

        func qrScannerViewControllerCameraUnavailable(_ controller: ProfileQRCodeScannerViewController) {
            parent.onCameraUnavailable()
        }
    }
}

private protocol ProfileQRCodeScannerViewControllerDelegate: AnyObject {
    func qrScannerViewController(_ controller: ProfileQRCodeScannerViewController, didScan value: String)
    func qrScannerViewControllerDidDenyPermission(_ controller: ProfileQRCodeScannerViewController)
    func qrScannerViewControllerCameraUnavailable(_ controller: ProfileQRCodeScannerViewController)
}

private final class ProfileQRCodeScannerViewController: UIViewController {
    weak var delegate: ProfileQRCodeScannerViewControllerDelegate?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "flow.profile.qrscanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasConfiguredSession = false
    private var hasScannedCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccessIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    func stopSession() {
        sessionQueue.async {
            guard self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    private func requestCameraAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStartSessionIfNeeded()
                    } else {
                        self.delegate?.qrScannerViewControllerDidDenyPermission(self)
                    }
                }
            }
        case .denied, .restricted:
            delegate?.qrScannerViewControllerDidDenyPermission(self)
        @unknown default:
            delegate?.qrScannerViewControllerDidDenyPermission(self)
        }
    }

    private func configureAndStartSessionIfNeeded() {
        guard !hasConfiguredSession else {
            startSession()
            return
        }
        hasConfiguredSession = true

        sessionQueue.async {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async {
                    self.delegate?.qrScannerViewControllerCameraUnavailable(self)
                }
                return
            }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            guard self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.delegate?.qrScannerViewControllerCameraUnavailable(self)
                }
                return
            }
            self.captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard self.captureSession.canAddOutput(output) else {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.delegate?.qrScannerViewControllerCameraUnavailable(self)
                }
                return
            }
            self.captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            self.captureSession.commitConfiguration()

            DispatchQueue.main.async {
                let previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                previewLayer.videoGravity = .resizeAspectFill
                previewLayer.frame = self.view.bounds
                self.view.layer.insertSublayer(previewLayer, at: 0)
                self.previewLayer = previewLayer
                self.startSession()
            }
        }
    }

    private func startSession() {
        sessionQueue.async {
            guard !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }
}

extension ProfileQRCodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScannedCode else { return }
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty else {
            return
        }

        hasScannedCode = true
        stopSession()
        delegate?.qrScannerViewController(self, didScan: value)
    }
}
