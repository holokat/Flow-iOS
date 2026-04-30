import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct ProfileQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter

    let npub: String
    let displayName: String
    let handle: String?
    let avatarURL: URL?
    var onOpenProfile: ((String) -> Void)? = nil

    @State private var isShowingScanner = false
    @State private var pendingScannedProfilePubkey: String?
    @State private var qrCodeImage: UIImage?

    private var qrPayload: String {
        "nostr:\(npub)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                appSettings.themePalette.sheetBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        profileHeader
                        qrCard
                        actionRow
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 56)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear
                        .frame(height: 24)
                }
            }
            .navigationTitle("Profile QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ThemedToolbarDoneButton {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(appSettings.themePalette.sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.sheetBackground)
        .task(id: qrPayload) {
            let payload = qrPayload
            qrCodeImage = await QRCodeRenderer.renderAsync(payload: payload)
        }
        .fullScreenCover(isPresented: $isShowingScanner) {
            ProfileQRScannerFlowView(
                onOpenProfile: { pubkey in
                    pendingScannedProfilePubkey = pubkey
                    isShowingScanner = false
                }
            )
        }
        .onChange(of: isShowingScanner) { _, isShowing in
            guard !isShowing, let pubkey = pendingScannedProfilePubkey else { return }
            pendingScannedProfilePubkey = nil
            dismiss()
            DispatchQueue.main.async {
                onOpenProfile?(pubkey)
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                if let handle = trimmedNonEmpty(handle) {
                    Text(handle)
                        .font(.subheadline)
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var avatarView: some View {
        Group {
            if let avatarURL {
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
            } else {
                avatarFallback
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(appSettings.themePalette.separator.opacity(0.3), lineWidth: 0.7)
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(appSettings.themePalette.tertiaryFill)
            Text(String(displayName.prefix(1)).uppercased())
                .font(.headline.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            ProfileQRCodeArtwork(
                qrCodeImage: qrCodeImage,
                avatarURL: avatarURL,
                displayName: displayName,
                avatarSize: 54
            )
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("Scan to open this profile")
                .font(.footnote)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            Text(shortNpub)
                .font(.footnote.monospaced())
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .lineLimit(1)

            Text("Flip your phone over from anywhere in the app to present this code full-screen.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(
            appSettings.themePalette.secondaryBackground,
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(appSettings.themePalette.separator.opacity(colorScheme == .dark ? 0.9 : 0.75), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 18, x: 0, y: 8)
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = npub
                    toastCenter.show("Copied ID")
                } label: {
                    Label("Copy ID", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .background(
                            Capsule()
                                .fill(appSettings.themePalette.secondaryBackground)
                        )
                        .overlay(
                            Capsule()
                                .stroke(appSettings.themePalette.separator.opacity(0.6), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)

                ShareLink(item: qrPayload) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(appSettings.buttonTextColor)
                        .background(appSettings.primaryGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                isShowingScanner = true
            } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(appSettings.themePalette.foreground)
                    .background(
                        Capsule()
                            .fill(appSettings.themePalette.secondaryBackground)
                    )
                    .overlay(
                        Capsule()
                            .stroke(appSettings.themePalette.separator.opacity(0.6), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var shortNpub: String {
        guard npub.count > 28 else { return npub }
        return "\(npub.prefix(14))...\(npub.suffix(10))"
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum FullScreenQRCodeTrigger: String, Identifiable {
    case automatic

    var id: String { rawValue }
}

struct ProfileQRCodeArtwork: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let qrCodeImage: UIImage?
    let avatarURL: URL?
    let displayName: String
    let avatarSize: CGFloat

    private var centerBadgeSize: CGFloat {
        avatarSize + 10
    }

    var body: some View {
        ZStack {
            Group {
                if let qrCodeImage {
                    Image(uiImage: qrCodeImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 92, weight: .medium))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }
            }

            Circle()
                .fill(Color.white)
                .frame(width: centerBadgeSize, height: centerBadgeSize)

            ProfileQRCodeAvatarBadge(
                avatarURL: avatarURL,
                displayName: displayName,
                size: avatarSize
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile QR code for \(displayName)")
    }
}

struct ProfileQRCodeAvatarBadge: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let avatarURL: URL?
    let displayName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let avatarURL {
                CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.white, lineWidth: 3)
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(appSettings.themePalette.tertiaryFill)
            Text(String(displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }
}

struct PresentedProfileQRCodeView: View {
    let trigger: FullScreenQRCodeTrigger
    let displayName: String
    let handle: String?
    let avatarURL: URL?
    let qrCodeImage: UIImage?
    let onDismiss: () -> Void

    @State private var automaticEntrancePhase: AutomaticEntrancePhase = .offscreen
    @State private var automaticEntranceTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let rotationDegrees = presentationRotationDegrees
            let contentSize = presentationContentSize(for: proxy.size, rotationDegrees: rotationDegrees)
            let entranceState = automaticEntranceState(for: proxy.size.height)

            ZStack {
                ProfileQRCodeBlurredAvatarBackground(avatarURL: avatarURL)
                    .frame(width: contentSize.width, height: contentSize.height)
                    .rotationEffect(.degrees(rotationDegrees))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .offset(y: entranceState.backgroundOffset)
                    .scaleEffect(entranceState.backgroundScale)
                    .opacity(entranceState.backgroundOpacity)

                portraitPresentation(in: contentSize)
                    .frame(width: contentSize.width, height: contentSize.height)
                    .rotationEffect(.degrees(rotationDegrees))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .offset(y: entranceState.contentOffset)
                    .scaleEffect(entranceState.contentScale)
                    .opacity(entranceState.contentOpacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onAppear {
            guard trigger == .automatic else { return }
            startAutomaticEntranceAnimation()
        }
        .onDisappear {
            automaticEntranceTask?.cancel()
            automaticEntranceTask = nil
            automaticEntrancePhase = .offscreen
        }
        .onTapGesture {
            onDismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard trigger == .automatic else { return }
            switch UIDevice.current.orientation {
            case .portraitUpsideDown, .faceUp, .faceDown, .unknown:
                break
            default:
                onDismiss()
            }
        }
    }

    @ViewBuilder
    private func portraitPresentation(in size: CGSize) -> some View {
        let qrDimension = min(size.width - 88, size.height * 0.5, 384)
        let avatarSize = max(76, min(98, qrDimension * 0.25))

        VStack(spacing: 24) {
            Text(displayName)
                .font(.custom("SF Pro Display", size: 38).weight(.bold))
                .foregroundStyle(.white.opacity(0.97))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .kerning(-0.6)
                .padding(.horizontal, 18)

            ProfileQRCodeArtwork(
                qrCodeImage: qrCodeImage,
                avatarURL: avatarURL,
                displayName: displayName,
                avatarSize: avatarSize
            )
            .frame(width: qrDimension, height: qrDimension)
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1.2)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var presentationRotationDegrees: Double {
        var angle: Double = 0

        switch activeInterfaceOrientation {
        case .landscapeLeft:
            angle += 90
        case .landscapeRight:
            angle -= 90
        default:
            break
        }

        if trigger == .automatic {
            angle += 180
        }

        return angle
    }

    private func presentationContentSize(for size: CGSize, rotationDegrees: Double) -> CGSize {
        let normalized = abs(rotationDegrees).truncatingRemainder(dividingBy: 180)
        guard normalized == 90 else { return size }

        return CGSize(width: size.height, height: size.width)
    }

    private func automaticEntranceState(for containerHeight: CGFloat) -> AutomaticEntranceState {
        guard trigger == .automatic else {
            return AutomaticEntranceState(
                backgroundOffset: 0,
                backgroundScale: 1,
                backgroundOpacity: 1,
                contentOffset: 0,
                contentScale: 1,
                contentOpacity: 1
            )
        }

        let dropDistance = min(260, max(116, containerHeight * 0.26))
        let bounceDistance = min(26, max(12, dropDistance * 0.11))

        switch automaticEntrancePhase {
        case .offscreen:
            return AutomaticEntranceState(
                backgroundOffset: dropDistance * 0.26,
                backgroundScale: 1.06,
                backgroundOpacity: 0.86,
                contentOffset: dropDistance,
                contentScale: 0.94,
                contentOpacity: 0
            )
        case .impact:
            return AutomaticEntranceState(
                backgroundOffset: -bounceDistance * 0.24,
                backgroundScale: 1,
                backgroundOpacity: 1,
                contentOffset: -bounceDistance,
                contentScale: 1.015,
                contentOpacity: 1
            )
        case .settled:
            return AutomaticEntranceState(
                backgroundOffset: 0,
                backgroundScale: 1,
                backgroundOpacity: 1,
                contentOffset: 0,
                contentScale: 1,
                contentOpacity: 1
            )
        }
    }

    @MainActor
    private func startAutomaticEntranceAnimation() {
        automaticEntranceTask?.cancel()
        automaticEntrancePhase = .offscreen

        automaticEntranceTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.34)) {
                automaticEntrancePhase = .impact
            }

            try? await Task.sleep(nanoseconds: 340_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.34, dampingFraction: 0.62, blendDuration: 0.08)) {
                automaticEntrancePhase = .settled
            }
        }
    }

    private var activeInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .unknown
    }
}

private struct AutomaticEntranceState {
    let backgroundOffset: CGFloat
    let backgroundScale: CGFloat
    let backgroundOpacity: Double
    let contentOffset: CGFloat
    let contentScale: CGFloat
    let contentOpacity: Double
}

private enum AutomaticEntrancePhase {
    case offscreen
    case impact
    case settled
}

struct ProfileQRCodePresentationBackground: View {
    static let defaultResourceName = "welcome_intro_unicorn.json"

    let resourceName: String

    static func resourceName(for theme: AppThemeOption) -> String {
        theme.qrShareBackgroundResourceName ?? defaultResourceName
    }

    private var usesLightBackdrop: Bool {
        resourceName == Self.defaultResourceName
    }

    var body: some View {
        ZStack {
            if usesLightBackdrop {
                Color(red: 1.0, green: 0.894, blue: 0.886)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }

            UnicornStudioBackgroundView(
                source: .bundledJSON(resourceName),
                opacity: 1,
                backgroundStyle: usesLightBackdrop ? .light : .dark
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    usesLightBackdrop ? Color.black.opacity(0.04) : Color.black.opacity(0.12),
                    usesLightBackdrop ? Color.black.opacity(0.08) : Color.black.opacity(0.20),
                    usesLightBackdrop ? Color.black.opacity(0.18) : Color.black.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

private struct ProfileQRCodeBlurredAvatarBackground: View {
    let avatarURL: URL?

    var body: some View {
        ZStack {
            Color.black

            if let avatarURL {
                CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(1.18)
                            .blur(radius: 34, opaque: true)
                    default:
                        Color.black
                    }
                }
            }

            Color.black.opacity(0.20)
        }
        .clipped()
        .ignoresSafeArea()
    }
}

enum QRCodeRenderer {
    private static let cache = QRCodeImageCache()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func render(payload: String) -> UIImage? {
        cache.image(for: payload) {
            renderUncached(payload: payload)
        }
    }

    static func renderAsync(payload: String) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: render(payload: payload))
            }
        }
    }

    private static func renderUncached(payload: String) -> UIImage? {
        let data = Data(payload.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "H"

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private final class QRCodeImageCache {
    private var images: [String: UIImage] = [:]
    private let lock = NSLock()

    func image(for payload: String, render: () -> UIImage?) -> UIImage? {
        lock.lock()
        if let cachedImage = images[payload] {
            lock.unlock()
            return cachedImage
        }
        lock.unlock()

        guard let image = render() else { return nil }

        lock.lock()
        if let cachedImage = images[payload] {
            lock.unlock()
            return cachedImage
        }
        images[payload] = image
        lock.unlock()
        return image
    }
}
