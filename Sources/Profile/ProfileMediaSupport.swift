import AVFoundation
import Photos
import SwiftUI
import UIKit

func isProfileLoopingVideoURL(_ url: URL) -> Bool {
    switch url.pathExtension.lowercased() {
    case "mp4", "mov", "m4v", "webm", "mkv":
        return true
    default:
        return false
    }
}

enum ProfileAvatarSwipeDismissBehavior {
    static let dismissalFraction: CGFloat = 0.25

    static func shouldBegin(translation: CGSize) -> Bool {
        translation.height > 8
            && translation.height >= abs(translation.width) * 1.15
    }

    static func offset(for translation: CGSize) -> CGFloat {
        max(0, translation.height)
    }

    static func dismissalDistance(containerHeight: CGFloat) -> CGFloat {
        max(120, containerHeight * dismissalFraction)
    }

    static func shouldDismiss(
        translation: CGFloat,
        predictedEndTranslation: CGFloat,
        containerHeight: CGFloat
    ) -> Bool {
        guard containerHeight > 0 else { return false }
        let threshold = dismissalDistance(containerHeight: containerHeight)
        return max(translation, predictedEndTranslation) >= threshold
    }

    static func scale(
        offset: CGFloat,
        containerHeight: CGFloat,
        reduceMotion: Bool
    ) -> CGFloat {
        guard !reduceMotion, containerHeight > 0 else { return 1 }
        let fraction = min(max(offset / containerHeight, 0), 1)
        return max(0.90, 1 - (fraction * 0.18))
    }

    static func backgroundOpacity(
        offset: CGFloat,
        containerHeight: CGFloat
    ) -> Double {
        guard containerHeight > 0 else { return 1 }
        let fraction = min(max(offset / containerHeight, 0), 1)
        return max(0.18, 1 - Double(fraction * 1.3))
    }
}

struct ProfileAvatarFullscreenViewer: View {
    let url: URL
    let title: String

    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var toastCenter: AppToastCenter

    @State private var isImageZoomed = false
    @State private var swipeDismissOffset: CGFloat = 0
    @State private var isTrackingSwipeDismiss = false
    @State private var isCompletingSwipeDismiss = false
    @State private var hasCrossedDismissThreshold = false

    private var savableImageURL: URL? {
        isProfileLoopingVideoURL(url) ? nil : url
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                ZStack {
                    viewerBackgroundColor
                        .opacity(
                            ProfileAvatarSwipeDismissBehavior.backgroundOpacity(
                                offset: swipeDismissOffset,
                                containerHeight: geometry.size.height
                            )
                        )
                        .ignoresSafeArea()

                    if isProfileLoopingVideoURL(url) {
                        ProfileLoopingVideoView(
                            url: url,
                            videoGravity: .resizeAspect
                        )
                        .padding(16)
                    } else {
                        NoteZoomableFullscreenImageView(
                            url: url,
                            kind: .profileImageFullscreen,
                            chromeForegroundColor: chromeForegroundColor,
                            onZoomStateChange: { isImageZoomed = $0 }
                        )
                        .accessibilityLabel("\(title)'s profile image")
                        .accessibilityHint("Pinch or double-tap to zoom. Swipe down to close when not zoomed in.")
                    }
                }
                .flowRemoteImageSaveContextMenu(url: savableImageURL, kind: .profileImageFullscreen)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ThemedToolbarDoneButton {
                            dismiss()
                        }
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(viewerNavigationBarColor, for: .navigationBar)
                .toolbarColorScheme(effectiveColorScheme == .dark ? .dark : .light, for: .navigationBar)
            }
            .offset(y: swipeDismissOffset)
            .scaleEffect(
                ProfileAvatarSwipeDismissBehavior.scale(
                    offset: swipeDismissOffset,
                    containerHeight: geometry.size.height,
                    reduceMotion: accessibilityReduceMotion
                )
            )
            .simultaneousGesture(
                swipeToDismissGesture(containerHeight: geometry.size.height)
            )
        }
        .presentationBackground(.clear)
        .onChange(of: isImageZoomed) { _, isZoomed in
            if isZoomed, isTrackingSwipeDismiss {
                settleSwipeDismissBack()
            }
        }
    }

    private func swipeToDismissGesture(containerHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard !isImageZoomed, !isCompletingSwipeDismiss else { return }

                if !isTrackingSwipeDismiss {
                    guard ProfileAvatarSwipeDismissBehavior.shouldBegin(
                        translation: value.translation
                    ) else {
                        return
                    }
                    isTrackingSwipeDismiss = true
                }

                let offset = ProfileAvatarSwipeDismissBehavior.offset(
                    for: value.translation
                )
                swipeDismissOffset = offset
                updateDismissThresholdFeedback(
                    offset: offset,
                    containerHeight: containerHeight
                )
            }
            .onEnded { value in
                guard isTrackingSwipeDismiss, !isCompletingSwipeDismiss else { return }
                isTrackingSwipeDismiss = false
                hasCrossedDismissThreshold = false

                let translation = ProfileAvatarSwipeDismissBehavior.offset(
                    for: value.translation
                )
                let predictedEndTranslation = ProfileAvatarSwipeDismissBehavior.offset(
                    for: value.predictedEndTranslation
                )

                if ProfileAvatarSwipeDismissBehavior.shouldDismiss(
                    translation: translation,
                    predictedEndTranslation: predictedEndTranslation,
                    containerHeight: containerHeight
                ) {
                    completeSwipeDismiss(containerHeight: containerHeight)
                } else {
                    settleSwipeDismissBack()
                }
            }
    }

    private func updateDismissThresholdFeedback(
        offset: CGFloat,
        containerHeight: CGFloat
    ) {
        let crossedThreshold = offset >= ProfileAvatarSwipeDismissBehavior.dismissalDistance(
            containerHeight: containerHeight
        )
        guard crossedThreshold != hasCrossedDismissThreshold else { return }

        hasCrossedDismissThreshold = crossedThreshold
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle = crossedThreshold ? .soft : .light
        UIImpactFeedbackGenerator(style: feedbackStyle).impactOccurred()
    }

    private func settleSwipeDismissBack() {
        isTrackingSwipeDismiss = false
        hasCrossedDismissThreshold = false
        let animation: Animation = accessibilityReduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.30, dampingFraction: 0.86)
        withAnimation(animation) {
            swipeDismissOffset = 0
        }
    }

    private func completeSwipeDismiss(containerHeight: CGFloat) {
        isCompletingSwipeDismiss = true
        let duration = accessibilityReduceMotion ? 0.12 : 0.18
        withAnimation(.easeOut(duration: duration)) {
            swipeDismissOffset = max(containerHeight * 1.08, swipeDismissOffset)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1_000)))
            dismiss()
        }
    }

    private var effectiveColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }

    private var viewerBackgroundColor: Color {
        appSettings.themePalette.background
    }

    private var viewerNavigationBarColor: Color {
        appSettings.themePalette.navigationBackground
    }

    private var chromeForegroundColor: Color {
        appSettings.themePalette.foreground
    }
}

struct ProfileLoopingVideoView: UIViewRepresentable {
    let url: URL
    let videoGravity: AVLayerVideoGravity

    final class Coordinator {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var currentURL: URL?

        init() {
            player.isMuted = true
            player.actionAtItemEnd = .none
        }

        func configure(url: URL) {
            guard currentURL != url else {
                player.play()
                return
            }

            currentURL = url
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }

        func stop() {
            player.pause()
            looper = nil
            currentURL = nil
            player.removeAllItems()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ProfileLoopingVideoPlayerContainerView {
        let view = ProfileLoopingVideoPlayerContainerView()
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = context.coordinator.player
        context.coordinator.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: ProfileLoopingVideoPlayerContainerView, context: Context) {
        uiView.playerLayer.videoGravity = videoGravity
        uiView.playerLayer.player = context.coordinator.player
        context.coordinator.configure(url: url)
    }

    static func dismantleUIView(_ uiView: ProfileLoopingVideoPlayerContainerView, coordinator: Coordinator) {
        uiView.playerLayer.player = nil
        coordinator.stop()
    }
}

final class ProfileLoopingVideoPlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

enum ProfilePhotoLibrarySave {
    private enum SaveError: LocalizedError {
        case failed

        var errorDescription: String? {
            "Couldn't save that image right now."
        }
    }

    static func requestWriteAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
        default:
            return current
        }
    }

    static func save(image: UIImage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: SaveError.failed)
                }
            }
        }
    }
}

enum FlowRemoteImageSave {
    private enum SaveError: LocalizedError {
        case accessDenied
        case loadFailed
        case failed

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Photos access is needed to save."
            case .loadFailed:
                return "Couldn't load that image right now."
            case .failed:
                return "Couldn't save that image right now."
            }
        }
    }

    @MainActor
    static func performSave(
        from url: URL,
        toastCenter: AppToastCenter,
        kind: FlowImageCacheRequestKind = .standard
    ) async {
        do {
            try await saveImage(from: url, kind: kind)
            toastCenter.show("Saved to Photos")
        } catch {
            toastCenter.show(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't save that image right now.",
                style: .error,
                duration: 2.8
            )
        }
    }

    static func saveImage(
        from url: URL,
        kind: FlowImageCacheRequestKind = .standard
    ) async throws {
        let authorizationStatus = await ProfilePhotoLibrarySave.requestWriteAuthorizationIfNeeded()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw SaveError.accessDenied
        }

        let cachedData = await FlowImageCache.shared.data(
            for: url,
            kind: kind,
            enforceNetworkByteLimit: false
        )

        if let data = cachedData {
            do {
                try await save(data: data, originalFilename: originalFilename(for: url))
                return
            } catch {
                // Fall back to decoding through the shared image cache below.
            }
        }

        let loadedImage = await FlowImageCache.shared.image(
            for: url,
            kind: kind,
            enforceNetworkByteLimit: false
        )

        guard let image = loadedImage else {
            throw SaveError.loadFailed
        }

        try await ProfilePhotoLibrarySave.save(image: image)
    }

    private static func originalFilename(for url: URL) -> String? {
        let filename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? nil : filename
    }

    private static func save(data: Data, originalFilename: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = originalFilename
                request.addResource(with: .photo, data: data, options: options)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: SaveError.failed)
                }
            }
        }
    }
}

private struct FlowRemoteImageSaveContextMenuModifier: ViewModifier {
    let url: URL?
    let kind: FlowImageCacheRequestKind

    @EnvironmentObject private var toastCenter: AppToastCenter
    @State private var isSaving = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.contextMenu {
                Button {
                    Task {
                        await saveImage(at: url)
                    }
                } label: {
                    Label("Save Image", systemImage: "square.and.arrow.down")
                }
                .disabled(isSaving)
            }
        } else {
            content
        }
    }

    @MainActor
    private func saveImage(at url: URL) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        await FlowRemoteImageSave.performSave(from: url, toastCenter: toastCenter, kind: kind)
    }
}

extension View {
    func flowRemoteImageSaveContextMenu(
        url: URL?,
        kind: FlowImageCacheRequestKind = .standard
    ) -> some View {
        modifier(FlowRemoteImageSaveContextMenuModifier(url: url, kind: kind))
    }
}
