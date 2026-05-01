import NostrSDK
import SwiftUI
import UIKit

struct NoteImageGalleryView: View {
    private struct SelectedImage: Identifiable {
        let id: Int
    }

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var composeSheetCoordinator: AppComposeSheetCoordinator
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter

    let imageURLs: [URL]
    let layout: NoteContentMediaLayout
    let sourceEvent: NostrEvent
    let mediaAspectRatioHints: [String: CGFloat]
    let reactionCount: Int
    let commentCount: Int
    @State private var selectedImage: SelectedImage?
    @State private var visibleImageIndex = 0
    @State private var remixSourceImage: UIImage?
    @State private var pendingRemixComposeDraft: NoteImageRemixComposeDraft?
    @State private var isShowingRemixEditor = false
    @State private var isPreparingRemixEditor = false

    var body: some View {
        Group {
            if imageURLs.count == 1 {
                singleImageCell(url: imageURLs[0], index: 0)
            } else if layout == .feed {
                feedGallery
            } else {
                pagedGallery
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fullScreenCover(item: $selectedImage) { selected in
            NoteImageFullscreenViewer(
                urls: imageURLs,
                sourceEvent: sourceEvent,
                initialIndex: selected.id,
                reactionCount: reactionCount,
                commentCount: commentCount
            )
        }
        .fullScreenCover(
            isPresented: $isShowingRemixEditor,
            onDismiss: handleRemixEditorDismissed
        ) {
            if let remixSourceImage {
                ImageRemixEditorView(
                    sourceImage: remixSourceImage,
                    sourceEvent: sourceEvent,
                    currentAccountPubkey: auth.currentAccount?.pubkey,
                    currentNsec: auth.currentNsec,
                    writeRelayURLs: effectiveWriteRelayURLs,
                    onComposeRequested: { attachment, replyTargetEvent in
                        pendingRemixComposeDraft = NoteImageRemixComposeDraft(
                            attachment: attachment,
                            replyTargetEvent: replyTargetEvent
                        )
                        isShowingRemixEditor = false
                    }
                )
            }
        }
    }

    private var multiImageHeight: CGFloat {
        layout == .detailCarousel ? 460 : 340
    }

    private var mediaCornerRadius: CGFloat {
        layout == .feed ? 18 : 12
    }

    private var feedGalleryHeight: CGFloat {
        let availableWidth = max(UIScreen.main.bounds.width - 92, 220)
        let width = imageURLs.count == 1 ? availableWidth : feedTileWidth(availableWidth: availableWidth)
        let ratio = imageURLs.first.flatMap { aspectRatioHint(for: $0) }
        return NoteImageLayoutGuide.naturalHeight(
            width: width,
            aspectRatio: ratio,
            minHeight: 170,
            maxHeight: 340
        )
    }

    private var feedGallerySpacing: CGFloat {
        6
    }

    private var feedGallery: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let tileWidth = feedTileWidth(availableWidth: width)

            if imageURLs.count == 1, let url = imageURLs.first {
                feedTile(
                    url: url,
                    index: 0,
                    width: width,
                    height: feedGalleryHeight
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: feedGallerySpacing) {
                        ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                            feedTile(
                                url: url,
                                index: index,
                                width: tileWidth,
                                height: feedGalleryHeight
                            )
                        }
                    }
                    .frame(height: feedGalleryHeight, alignment: .leading)
                }
            }
        }
        .frame(height: feedGalleryHeight)
    }

    private func feedTileWidth(availableWidth: CGFloat) -> CGFloat {
        let proposedWidth = availableWidth * 0.74
        return max(min(proposedWidth, 360), 220)
    }

    private func feedTile(url: URL, index: Int, width: CGFloat, height: CGFloat) -> some View {
        NoteFeedImageTileView(
            url: url,
            cornerRadius: mediaCornerRadius,
            width: width,
            height: height,
            onTap: {
                selectedImage = SelectedImage(id: index)
            },
            isRemixDisabled: isPreparingRemixEditor,
            onRemix: {
                Task {
                    await openRemixEditor(for: url)
                }
            },
            onSave: {
                await saveImage(url: url)
            },
            onAddToNote: {
                addImageToNewNote(url: url)
            }
        )
    }

    private var pagedGallery: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            TabView(selection: $visibleImageIndex) {
                ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                    NoteSingleImageCellView(
                        url: url,
                        cornerRadius: mediaCornerRadius,
                        aspectRatioHint: aspectRatioHint(for: url),
                        maxHeight: multiImageHeight,
                        onTap: {
                            selectedImage = SelectedImage(id: index)
                        },
                        isRemixDisabled: isPreparingRemixEditor,
                        onRemix: {
                            Task {
                                await openRemixEditor(for: url)
                            }
                        },
                        onSave: {
                            await saveImage(url: url)
                        },
                        onAddToNote: {
                            addImageToNewNote(url: url)
                        }
                    )
                    .frame(width: width, height: multiImageHeight)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(width: width, height: multiImageHeight, alignment: .top)
        }
        .frame(height: multiImageHeight)
    }

    private func singleImageCell(url: URL, index: Int) -> some View {
        NoteSingleImageCellView(
            url: url,
            cornerRadius: mediaCornerRadius,
            aspectRatioHint: aspectRatioHint(for: url),
            onTap: {
                selectedImage = SelectedImage(id: index)
            },
            isRemixDisabled: isPreparingRemixEditor,
            onRemix: {
                Task {
                    await openRemixEditor(for: url)
                }
            },
            onSave: {
                await saveImage(url: url)
            },
            onAddToNote: {
                addImageToNewNote(url: url)
            }
        )
    }

    private func aspectRatioHint(for url: URL) -> CGFloat? {
        NoteImageLayoutGuide.aspectRatioHint(for: url, in: mediaAspectRatioHints)
            ?? FlowMediaAspectRatioCache.shared.ratio(for: url)
    }

    @MainActor
    private func openRemixEditor(for url: URL) async {
        guard !isPreparingRemixEditor else { return }
        isPreparingRemixEditor = true
        defer {
            isPreparingRemixEditor = false
        }

        guard let image = await FlowImageCache.shared.image(for: url) else {
            toastCenter.show("Couldn't load that image for remixing.", style: .error, duration: 2.8)
            return
        }

        composeSheetCoordinator.dismiss()
        pendingRemixComposeDraft = nil
        remixSourceImage = image
        isShowingRemixEditor = true
    }

    @MainActor
    private func handleRemixEditorDismissed() {
        remixSourceImage = nil

        guard let draft = pendingRemixComposeDraft else { return }
        pendingRemixComposeDraft = nil

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            composeSheetCoordinator.presentRemix(
                attachment: draft.attachment,
                replyTargetEvent: draft.replyTargetEvent
            )
        }
    }

    @MainActor
    private func saveImage(url: URL) async {
        await FlowRemoteImageSave.performSave(from: url, toastCenter: toastCenter)
    }

    @MainActor
    private func addImageToNewNote(url: URL) {
        composeSheetCoordinator.presentMediaAttachment(imageAttachment(for: url))
        toastCenter.show("Image added to a new note", style: .info)
    }

    private func imageAttachment(for url: URL) -> ComposeMediaAttachment {
        let preservedTag = sourceIMetaTag(for: url)
        let mimeType = mediaMimeType(in: preservedTag) ?? inferredImageMimeType(for: url)
        var imetaTag = preservedTag ?? ["imeta", "url \(url.absoluteString)"]

        if !imetaTag.contains(where: { $0.lowercased().hasPrefix("m ") }) {
            imetaTag.append("m \(mimeType)")
        }

        return ComposeMediaAttachment(
            url: url,
            imetaTag: imetaTag,
            mimeType: mimeType,
            fileSizeBytes: nil
        )
    }

    private func sourceIMetaTag(for url: URL) -> [String]? {
        let targetURL = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for tag in sourceEvent.tags {
            guard tag.first?.lowercased() == "imeta" else { continue }

            let tagURL = tag.dropFirst()
                .first { $0.lowercased().hasPrefix("url ") }
                .map { String($0.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

            guard let tagURL, tagURL == targetURL else { continue }
            return tag
        }

        return nil
    }

    private func mediaMimeType(in imetaTag: [String]?) -> String? {
        imetaTag?
            .dropFirst()
            .first { $0.lowercased().hasPrefix("m ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func inferredImageMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "svg":
            return "image/svg+xml"
        default:
            return "image/jpeg"
        }
    }

    private var effectiveWriteRelayURLs: [URL] {
        let readRelayURLs = appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
        return appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: readRelayURLs
        )
    }
}

private struct FeedImageContextMenuOverlay: UIViewRepresentable {
    let url: URL
    let cornerRadius: CGFloat
    let isRemixDisabled: Bool
    let onTap: @MainActor () -> Void
    let onRemix: @MainActor () -> Void
    let onSave: @MainActor () async -> Void
    let onAddToNote: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            url: url,
            cornerRadius: cornerRadius,
            isRemixDisabled: isRemixDisabled,
            onTap: onTap,
            onRemix: onRemix,
            onSave: onSave,
            onAddToNote: onAddToNote
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        context.coordinator.update(
            url: url,
            cornerRadius: cornerRadius,
            isRemixDisabled: isRemixDisabled,
            onTap: onTap,
            onRemix: onRemix,
            onSave: onSave,
            onAddToNote: onAddToNote
        )
        context.coordinator.install(on: view)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall(from: uiView)
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        private var url: URL
        private var cornerRadius: CGFloat
        private var isRemixDisabled: Bool
        private var onTap: @MainActor () -> Void
        private var onRemix: @MainActor () -> Void
        private var onSave: @MainActor () async -> Void
        private var onAddToNote: @MainActor () -> Void
        private weak var installedView: UIView?
        private weak var tapGesture: UITapGestureRecognizer?
        private weak var menuInteraction: UIContextMenuInteraction?
        private var highlightedPreviewImage: UIImage?

        init(
            url: URL,
            cornerRadius: CGFloat,
            isRemixDisabled: Bool,
            onTap: @escaping @MainActor () -> Void,
            onRemix: @escaping @MainActor () -> Void,
            onSave: @escaping @MainActor () async -> Void,
            onAddToNote: @escaping @MainActor () -> Void
        ) {
            self.url = url
            self.cornerRadius = cornerRadius
            self.isRemixDisabled = isRemixDisabled
            self.onTap = onTap
            self.onRemix = onRemix
            self.onSave = onSave
            self.onAddToNote = onAddToNote
        }

        func update(
            url: URL,
            cornerRadius: CGFloat,
            isRemixDisabled: Bool,
            onTap: @escaping @MainActor () -> Void,
            onRemix: @escaping @MainActor () -> Void,
            onSave: @escaping @MainActor () async -> Void,
            onAddToNote: @escaping @MainActor () -> Void
        ) {
            let didChangeURL = self.url != url
            self.url = url
            self.cornerRadius = cornerRadius
            self.isRemixDisabled = isRemixDisabled
            self.onTap = onTap
            self.onRemix = onRemix
            self.onSave = onSave
            self.onAddToNote = onAddToNote

            if didChangeURL {
                highlightedPreviewImage = nil
            }
        }

        func install(on view: UIView) {
            guard installedView !== view else { return }
            if let installedView {
                uninstall(from: installedView)
            }

            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tapGesture.cancelsTouchesInView = true
            view.addGestureRecognizer(tapGesture)

            let menuInteraction = UIContextMenuInteraction(delegate: self)
            view.addInteraction(menuInteraction)

            self.installedView = view
            self.tapGesture = tapGesture
            self.menuInteraction = menuInteraction
        }

        func uninstall(from view: UIView) {
            if let tapGesture {
                view.removeGestureRecognizer(tapGesture)
                self.tapGesture = nil
            }

            if let menuInteraction {
                view.removeInteraction(menuInteraction)
                self.menuInteraction = nil
            }

            if installedView === view {
                installedView = nil
            }
        }

        @objc private func handleTap() {
            Task { @MainActor in
                onTap()
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak interaction] _ in
                guard let self else { return nil }

                let shareAction = UIAction(
                    title: "Share",
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self, weak interaction] _ in
                    guard let self, let sourceView = interaction?.view else { return }
                    self.presentShareSheet(from: sourceView)
                }

                let saveAction = UIAction(
                    title: "Save",
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.onSave()
                    }
                }

                let remixAttributes: UIMenuElement.Attributes = self.isRemixDisabled ? [.disabled] : []
                let remixAction = UIAction(
                    title: "Remix",
                    image: UIImage(systemName: "paintbrush.pointed.fill"),
                    attributes: remixAttributes
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.onRemix()
                    }
                }

                let addToNoteAction = UIAction(
                    title: "Add to Note",
                    image: UIImage(systemName: "square.and.pencil")
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.onAddToNote()
                    }
                }

                return UIMenu(children: [shareAction, saveAction, remixAction, addToNoteAction])
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            targetedPreview(for: interaction.view, refreshSnapshot: true)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            targetedPreview(for: interaction.view, refreshSnapshot: false)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            animator?.addCompletion { [weak self] in
                self?.highlightedPreviewImage = nil
            }
        }

        private func targetedPreview(for view: UIView?, refreshSnapshot: Bool) -> UITargetedPreview? {
            guard let view else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(
                roundedRect: view.bounds,
                cornerRadius: cornerRadius
            )

            if refreshSnapshot {
                highlightedPreviewImage = snapshotImage(for: view)
            }

            if let highlightedPreviewImage {
                let previewView = UIImageView(image: highlightedPreviewImage)
                previewView.frame = view.bounds
                previewView.contentMode = .scaleAspectFill
                previewView.clipsToBounds = true
                previewView.layer.cornerRadius = cornerRadius
                previewView.layer.cornerCurve = .continuous
                previewView.layer.masksToBounds = true

                let target = UIPreviewTarget(
                    container: view,
                    center: CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                )
                return UITargetedPreview(
                    view: previewView,
                    parameters: parameters,
                    target: target
                )
            }

            return UITargetedPreview(view: view, parameters: parameters)
        }

        private func snapshotImage(for view: UIView) -> UIImage? {
            guard let window = view.window else { return nil }

            let snapshotRect = view.convert(view.bounds, to: window)
            guard snapshotRect.width > 1, snapshotRect.height > 1 else { return nil }

            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            format.opaque = false

            return UIGraphicsImageRenderer(size: snapshotRect.size, format: format).image { context in
                context.cgContext.translateBy(x: -snapshotRect.minX, y: -snapshotRect.minY)
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
        }

        private func presentShareSheet(from sourceView: UIView) {
            let shareController = UIActivityViewController(
                activityItems: [url],
                applicationActivities: nil
            )
            shareController.popoverPresentationController?.sourceView = sourceView
            shareController.popoverPresentationController?.sourceRect = sourceView.bounds

            guard let presenter = sourceView.flowNearestViewController?.flowTopMostPresentedViewController else {
                return
            }

            presenter.present(shareController, animated: true)
        }
    }
}

private extension UIView {
    var flowNearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
}

private extension UIViewController {
    var flowTopMostPresentedViewController: UIViewController {
        if let navigationController = self as? UINavigationController {
            return navigationController.visibleViewController?.flowTopMostPresentedViewController
                ?? navigationController
        }

        if let tabBarController = self as? UITabBarController {
            return tabBarController.selectedViewController?.flowTopMostPresentedViewController
                ?? tabBarController
        }

        if let presentedViewController, !presentedViewController.isBeingDismissed {
            return presentedViewController.flowTopMostPresentedViewController
        }

        return self
    }
}

struct NoteFeedImageTileView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @ObservedObject private var networkPath = FlowNetworkPathMonitor.shared
    let url: URL
    let cornerRadius: CGFloat
    let width: CGFloat
    let height: CGFloat
    let onTap: @MainActor () -> Void
    let isRemixDisabled: Bool
    let onRemix: @MainActor () -> Void
    let onSave: @MainActor () async -> Void
    let onAddToNote: @MainActor () -> Void
    @State private var bypassFileSizeLimits = false
    @State private var isShowingTapToLoadPrompt = false

    var body: some View {
        mediaBody
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                FeedImageContextMenuOverlay(
                    url: url,
                    cornerRadius: cornerRadius,
                    isRemixDisabled: isRemixDisabled,
                    onTap: handleTap,
                    onRemix: onRemix,
                    onSave: onSave,
                    onAddToNote: onAddToNote
                )
            }
        .accessibilityLabel("Open image")
        .accessibilityAddTraits(.isButton)
        .frame(width: width, height: height)
        .task(id: feedImageLimitResetKey) {
            bypassFileSizeLimits = false
            isShowingTapToLoadPrompt = false
        }
    }

    @ViewBuilder
    private var mediaBody: some View {
        NoteRemoteMediaView(
            url: url,
            kind: .feedThumbnail,
            enforceNetworkByteLimit: shouldEnforceFileSizeLimit,
            allowsLargeGIFAutoplay: !appSettings.largeGIFAutoplayLimitEffective
        ) { asset in
            NoteMediaAssetContentView(asset: asset, scaling: .fill)
                .frame(width: width, height: height)
                .onAppear {
                    isShowingTapToLoadPrompt = false
                }
        } placeholder: {
            ZStack {
                appSettings.themePalette.secondaryBackground
                    .frame(width: width, height: height)
                ProgressView()
            }
            .onAppear {
                isShowingTapToLoadPrompt = false
            }
        } failure: {
            feedImageFailurePlaceholder
                .onAppear {
                    isShowingTapToLoadPrompt = shouldOfferTapToLoad
                }
        }
    }

    private var shouldEnforceFileSizeLimit: Bool {
        appSettings.mediaFileSizeLimitsEffective && !networkPath.isUsingWiFi && !bypassFileSizeLimits
    }

    private var shouldOfferTapToLoad: Bool {
        shouldEnforceFileSizeLimit
    }

    private var feedImageLimitResetKey: String {
        "\(url.absoluteString)|wifi:\(networkPath.isUsingWiFi)"
    }

    @MainActor
    private func handleTap() {
        if isShowingTapToLoadPrompt {
            bypassFileSizeLimits = true
            isShowingTapToLoadPrompt = false
        } else {
            onTap()
        }
    }

    private var feedImageFailurePlaceholder: some View {
        ZStack {
            appSettings.themePalette.secondaryBackground
                .frame(width: width, height: height)

            VStack(spacing: 6) {
                Image(systemName: shouldOfferTapToLoad ? "arrow.down.circle" : "photo")
                    .font(.title3)
                if shouldOfferTapToLoad {
                    Text("Tap to load image")
                        .font(appSettings.appFont(.caption1, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }
}

struct NoteSingleImageCellView: View {
    let url: URL
    let cornerRadius: CGFloat
    let aspectRatioHint: CGFloat?
    var maxHeight: CGFloat? = nil
    let onTap: @MainActor () -> Void
    let isRemixDisabled: Bool
    let onRemix: @MainActor () -> Void
    let onSave: @MainActor () async -> Void
    let onAddToNote: @MainActor () -> Void
    @EnvironmentObject private var appSettings: AppSettingsStore
    @ObservedObject private var networkPath = FlowNetworkPathMonitor.shared
    @State private var reservedAspectRatio: CGFloat
    @State private var bypassFileSizeLimits = false
    @State private var isShowingTapToLoadPrompt = false

    init(
        url: URL,
        cornerRadius: CGFloat,
        aspectRatioHint: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        onTap: @escaping @MainActor () -> Void,
        isRemixDisabled: Bool,
        onRemix: @escaping @MainActor () -> Void,
        onSave: @escaping @MainActor () async -> Void,
        onAddToNote: @escaping @MainActor () -> Void
    ) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.aspectRatioHint = NoteImageLayoutGuide.normalizedAspectRatio(aspectRatioHint)
        self.maxHeight = maxHeight
        self.onTap = onTap
        self.isRemixDisabled = isRemixDisabled
        self.onRemix = onRemix
        self.onSave = onSave
        self.onAddToNote = onAddToNote
        _reservedAspectRatio = State(
            initialValue: NoteImageLayoutGuide.reservedSingleImageAspectRatio(
                exactHint: NoteImageLayoutGuide.normalizedAspectRatio(aspectRatioHint),
                cachedExactRatio: FlowMediaAspectRatioCache.shared.ratio(for: url)
            )
        )
    }

    private var placeholderHeight: CGFloat {
        maxHeight ?? 180
    }

    private var mediaBackgroundColor: Color {
        if appSettings.activeTheme == .dracula || appSettings.activeTheme == .gamer {
            return appSettings.themePalette.background
        }
        return appSettings.themePalette.secondaryBackground
    }

    var body: some View {
        imageBody
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                FeedImageContextMenuOverlay(
                    url: url,
                    cornerRadius: cornerRadius,
                    isRemixDisabled: isRemixDisabled,
                    onTap: handleTap,
                    onRemix: onRemix,
                    onSave: onSave,
                    onAddToNote: onAddToNote
                )
            }
        .accessibilityLabel("Open image")
        .accessibilityAddTraits(.isButton)
        .aspectRatio(contextMenuAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: feedImageLimitResetKey) {
            bypassFileSizeLimits = false
            isShowingTapToLoadPrompt = false
            let cachedExactRatio = FlowMediaAspectRatioCache.shared.ratio(for: url)
            setReservedAspectRatio(
                NoteImageLayoutGuide.reservedSingleImageAspectRatio(
                    exactHint: aspectRatioHint,
                    cachedExactRatio: cachedExactRatio
                )
            )

            guard maxHeight == nil else { return }
            guard let resolvedExactRatio = await FlowImageCache.shared.aspectRatio(
                for: url,
                enforceNetworkByteLimit: shouldEnforceFileSizeLimit
            ) else { return }
            guard let normalizedRatio = NoteImageLayoutGuide.normalizedAspectRatio(resolvedExactRatio) else { return }
            guard !Task.isCancelled else { return }

            setReservedAspectRatio(normalizedRatio)
        }
    }

    @MainActor
    private func handleTap() {
        if isShowingTapToLoadPrompt {
            bypassFileSizeLimits = true
            isShowingTapToLoadPrompt = false
        } else {
            onTap()
        }
    }

    @MainActor
    private func setReservedAspectRatio(_ nextRatio: CGFloat) {
        guard abs(nextRatio - reservedAspectRatio) > 0.01 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reservedAspectRatio = nextRatio
        }
    }

    private var contextMenuAspectRatio: CGFloat? {
        maxHeight == nil ? reservedAspectRatio : nil
    }

    @ViewBuilder
    private func mediaContent(asset: NoteMediaAsset) -> some View {
        let base = NoteMediaAssetContentView(asset: asset, scaling: .fit)

        if let maxHeight {
            base
                .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .center)
                .background(mediaBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .center)
        } else {
            base
                .background(mediaBackgroundColor)
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if maxHeight == nil {
            stableSingleImageBody
        } else {
            fixedHeightImageBody
        }
    }

    private var stableSingleImageBody: some View {
        ZStack {
            NoteRemoteMediaView(
                url: url,
                kind: .feedThumbnail,
                enforceNetworkByteLimit: shouldEnforceFileSizeLimit,
                allowsLargeGIFAutoplay: !appSettings.largeGIFAutoplayLimitEffective
            ) { asset in
                mediaContent(asset: asset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .onAppear {
                        isShowingTapToLoadPrompt = false
                    }
            } placeholder: {
                loadingPlaceholder
                    .onAppear {
                        isShowingTapToLoadPrompt = false
                    }
            } failure: {
                failurePlaceholder
                    .onAppear {
                        isShowingTapToLoadPrompt = shouldOfferTapToLoad
                    }
            }
        }
        .aspectRatio(reservedAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mediaBackgroundColor)
    }

    private var fixedHeightImageBody: some View {
        NoteRemoteMediaView(
            url: url,
            kind: .feedThumbnail,
            enforceNetworkByteLimit: shouldEnforceFileSizeLimit,
            allowsLargeGIFAutoplay: !appSettings.largeGIFAutoplayLimitEffective
        ) { asset in
            mediaContent(asset: asset)
                .onAppear {
                    isShowingTapToLoadPrompt = false
                }
        } placeholder: {
            loadingPlaceholder
                .onAppear {
                    isShowingTapToLoadPrompt = false
                }
        } failure: {
            failurePlaceholder
                .onAppear {
                    isShowingTapToLoadPrompt = shouldOfferTapToLoad
                }
        }
    }

    private var loadingPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    mediaBackgroundColor.opacity(0.92),
                    mediaBackgroundColor.opacity(0.74)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight == nil ? .infinity : placeholderHeight, alignment: .center)
        .frame(minHeight: maxHeight == nil ? 0 : 180, maxHeight: maxHeight == nil ? .infinity : placeholderHeight, alignment: .center)
        .background(mediaBackgroundColor)
    }

    private var failurePlaceholder: some View {
        ZStack {
            mediaBackgroundColor

            VStack(spacing: 6) {
                Image(systemName: shouldOfferTapToLoad ? "arrow.down.circle" : "photo")
                    .font(.title3)

                if shouldOfferTapToLoad {
                    Text("Tap to load image")
                        .font(appSettings.appFont(.caption1, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight == nil ? .infinity : placeholderHeight, alignment: .center)
        .frame(minHeight: maxHeight == nil ? 0 : 180, maxHeight: maxHeight == nil ? .infinity : placeholderHeight, alignment: .center)
    }

    private var shouldEnforceFileSizeLimit: Bool {
        appSettings.mediaFileSizeLimitsEffective && !networkPath.isUsingWiFi && !bypassFileSizeLimits
    }

    private var shouldOfferTapToLoad: Bool {
        shouldEnforceFileSizeLimit
    }

    private var feedImageLimitResetKey: String {
        "\(url.absoluteString)|wifi:\(networkPath.isUsingWiFi)"
    }
}
