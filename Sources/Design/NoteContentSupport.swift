import AVFoundation
import AVKit
import Combine
import ImageIO
import LinkPresentation
import NostrSDK
import SwiftUI
import UIKit

final class NoteParsedContentCache {
    static let shared = NoteParsedContentCache()

    private let maxEntries = 2_000
    private var entries: [String: NoteContentView.ParsedContent] = [:]
    private var recency: [String] = []
    private let lock = NSLock()

    func parsedContent(
        for event: NostrEvent,
        builder: () -> NoteContentView.ParsedContent
    ) -> NoteContentView.ParsedContent {
        let cacheKey = event.id.lowercased()

        lock.lock()
        if let cached = entries[cacheKey] {
            touch(cacheKey)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = builder()

        lock.lock()
        entries[cacheKey] = parsed
        touch(cacheKey)
        if recency.count > maxEntries, let oldest = recency.first {
            recency.removeFirst()
            entries[oldest] = nil
        }
        lock.unlock()

        return parsed
    }

    private func touch(_ key: String) {
        recency.removeAll(where: { $0 == key })
        recency.append(key)
    }
}

final class NoteBlurRevealStateCache {
    static let shared = NoteBlurRevealStateCache()

    private let maxEntries = 2_000
    private var revealedKeys = Set<String>()
    private var recency: [String] = []
    private let lock = NSLock()

    func isRevealed(for key: String) -> Bool {
        guard !key.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }
        return revealedKeys.contains(key)
    }

    func markRevealed(for key: String) {
        guard !key.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        revealedKeys.insert(key)
        touch(key)

        let overflow = recency.count - maxEntries
        guard overflow > 0 else { return }

        for _ in 0..<overflow {
            let removedKey = recency.removeFirst()
            revealedKeys.remove(removedKey)
        }
    }

    private func touch(_ key: String) {
        recency.removeAll(where: { $0 == key })
        recency.append(key)
    }
}

struct NoteMediaPlaceholderView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let systemImage: String
    let text: String
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    placeholderContent(isActionable: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Loads media for this note")
            } else {
                placeholderContent(isActionable: false)
            }
        }
    }

    private func placeholderContent(isActionable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isActionable ? appSettings.themeIconAccentColor : appSettings.themePalette.iconMutedForeground)
            Text(text)
                .font(.footnote.weight(isActionable ? .semibold : .regular))
                .foregroundStyle(isActionable ? appSettings.primaryColor : appSettings.themePalette.secondaryForeground)
                .lineLimit(nil)
            Spacer(minLength: 0)
            if isActionable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appSettings.themeIconAccentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(appSettings.themePalette.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isActionable ? appSettings.primaryColor.opacity(0.35) : appSettings.themeSeparator(defaultOpacity: 0.35),
                    lineWidth: 0.5
                )
        )
    }
}

struct NoteBlurRevealContainer<Content: View>: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let cornerRadius: CGFloat
    let onReveal: () -> Void
    let content: Content

    init(
        cornerRadius: CGFloat,
        onReveal: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.onReveal = onReveal
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .blur(radius: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                }
                .allowsHitTesting(false)

            VStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .font(.headline.weight(.semibold))
                Text("Tap to reveal")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(appSettings.themePalette.modalBackground)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.08),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.18),
                                    Color.clear
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                }
            )
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture(perform: onReveal)
        .accessibilityLabel("Reveal media")
    }
}

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

struct NoteImageFullscreenViewer: View {
    let urls: [URL]
    let sourceEvent: NostrEvent
    let reactionCount: Int
    let commentCount: Int
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var composeSheetCoordinator: AppComposeSheetCoordinator
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reactionStats = NoteReactionStatsService.shared
    @State private var selectedIndex: Int
    @State private var isShowingInlineResharePanel = false
    @State private var isPublishingRepost = false
    @State private var repostStatusMessage: String?
    @State private var repostStatusIsError = false
    @State private var remixSourceImage: UIImage?
    @State private var pendingRemixComposeDraft: NoteImageRemixComposeDraft?
    @State private var isShowingRemixEditor = false
    @State private var isPreparingRemixEditor = false
    @State private var zoomedImageIndices = Set<Int>()
    @State private var swipeDismissOffset: CGSize = .zero
    @State private var isCompletingSwipeDismiss = false
    private let reshareService = ResharePublishService()
    private let reactionPublishService = NoteReactionPublishService()

    init(urls: [URL], sourceEvent: NostrEvent, initialIndex: Int, reactionCount: Int, commentCount: Int) {
        self.urls = urls
        self.sourceEvent = sourceEvent
        self.reactionCount = reactionCount
        self.commentCount = commentCount
        _selectedIndex = State(initialValue: max(0, min(initialIndex, max(urls.count - 1, 0))))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                viewerBackgroundColor
                    .opacity(viewerBackgroundOpacity(for: geometry.size))
                    .ignoresSafeArea()

                NavigationStack {
                    TabView(selection: $selectedIndex) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            ZStack {
                                viewerBackgroundColor.ignoresSafeArea()
                                NoteZoomableFullscreenImageView(
                                    url: url,
                                    chromeForegroundColor: chromeForegroundColor,
                                    onZoomStateChange: { isZoomed in
                                        updateZoomState(isZoomed, for: index)
                                    }
                                )
                            }
                            .tag(index)
                            .flowRemoteImageSaveContextMenu(url: url)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(doneButtonForegroundColor)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close")
                        }
                    }
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarBackground(viewerNavigationBarColor, for: .navigationBar)
                    .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
                    .safeAreaInset(edge: .bottom) {
                        mediaActionBar
                    }
                }
                .offset(swipeDismissOffset)
                .scaleEffect(viewerScale(for: geometry.size))
                .rotationEffect(.degrees(viewerRotationDegrees(for: geometry.size)))
                .simultaneousGesture(swipeToDismissGesture(containerSize: geometry.size))
                .allowsHitTesting(!isShowingInlineResharePanel)

                if isShowingInlineResharePanel {
                    fullscreenReshareOverlay
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
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
        .task {
            reactionStats.prefetch(events: [sourceEvent], relayURLs: effectiveReadRelayURLs)
        }
    }

    private var mediaActionBar: some View {
        HStack(spacing: 16) {
            Button {
                presentReplyComposer()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                    if visibleReplyCount > 0 {
                        Text("\(visibleReplyCount)")
                            .font(.footnote)
                    }
                }
                .foregroundStyle(chromeForegroundColor)
                .frame(minWidth: 36, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply")

            Button {
                repostStatusMessage = nil
                repostStatusIsError = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    isShowingInlineResharePanel = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                    if visibleRepostCount > 0 {
                        Text("\(visibleRepostCount)")
                            .font(.footnote)
                    }
                }
                .foregroundStyle(chromeForegroundColor)
                .frame(minWidth: 36, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Re-share")

            ReactionButton(
                isLiked: isLikedByCurrentUser,
                isBonusReaction: isBonusReactionByCurrentUser,
                count: visibleReactionCount,
                bonusActiveColor: appSettings.primaryColor,
                inactiveColor: chromeForegroundColor,
                minWidth: 36
            ) { bonusCount in
                Task {
                    await handleReactionTap(bonusCount: bonusCount)
                }
            }

            ShareLink(item: urls[selectedIndex]) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(chromeForegroundColor)
                    .frame(minWidth: 36, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")

            Button {
                Task {
                    await openRemixEditor()
                }
            } label: {
                Group {
                    if isPreparingRemixEditor {
                        ProgressView()
                            .controlSize(.small)
                            .tint(appSettings.primaryColor)
                            .frame(minWidth: 36, minHeight: 28, alignment: .leading)
                    } else {
                        Image(systemName: "paintbrush.pointed.fill")
                            .foregroundStyle(appSettings.primaryColor)
                            .frame(minWidth: 36, minHeight: 28, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isPreparingRemixEditor)
            .accessibilityLabel("Edit image")
        }
        .font(.headline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var visibleReactionCount: Int {
        reactionStats.reactionCount(for: sourceEvent.id)
    }

    private var visibleReplyCount: Int {
        max(commentCount, reactionStats.replyCount(for: sourceEvent.id))
    }

    private var visibleRepostCount: Int {
        reactionStats.repostCount(for: sourceEvent.id)
    }

    private var isLikedByCurrentUser: Bool {
        reactionStats.isReactedByCurrentUser(
            for: sourceEvent.id,
            currentPubkey: auth.currentAccount?.pubkey
        )
    }

    private var isBonusReactionByCurrentUser: Bool {
        reactionStats.currentUserReaction(
            for: sourceEvent.id,
            currentPubkey: auth.currentAccount?.pubkey
        )?.bonusCount ?? 0 > 0
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: effectiveReadRelayURLs
        )
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

    private var doneButtonForegroundColor: Color {
        appSettings.themePalette.foreground
    }

    private var fullscreenReshareOverlay: some View {
        ZStack(alignment: .bottom) {
            appSettings.themePalette.overlayBackground
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isShowingInlineResharePanel = false
                    }
                }

            VStack(alignment: .leading, spacing: 16) {
                Capsule()
                    .fill(appSettings.themeSeparator(defaultOpacity: 0.82))
                    .frame(width: 42, height: 5)
                    .frame(maxWidth: .infinity)

                HStack {
                    Text("Re-share")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            isShowingInlineResharePanel = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                            .frame(width: 30, height: 30)
                            .background(appSettings.themePalette.tertiaryFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close re-share options")
                }

                VStack(spacing: 0) {
                    inlineReshareActionRow(
                        title: "Repost",
                        systemImage: "arrow.2.squarepath"
                    ) {
                        Task {
                            await publishRepost()
                        }
                    }

                    Divider()
                        .padding(.leading, 18)

                    inlineReshareActionRow(
                        title: "Quote",
                        systemImage: "quote.bubble"
                    ) {
                        presentQuoteComposer()
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(appSettings.themePalette.modalBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(appSettings.themeSeparator(defaultOpacity: 0.35), lineWidth: 0.8)
                        )
                )

                if let repostStatusMessage, !repostStatusMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: repostStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(repostStatusIsError ? .red : .green)
                        Text(repostStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(repostStatusIsError ? .red : appSettings.themePalette.secondaryForeground)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill((repostStatusIsError ? Color.red : Color.green).opacity(0.1))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(appSettings.themePalette.modalBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(appSettings.themeSeparator(defaultOpacity: 0.35), lineWidth: 0.7)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    @MainActor
    private func handleReactionTap(bonusCount: Int = 0) async {
        let eventID = sourceEvent.id
        guard reactionStats.beginPublishingReaction(for: eventID) else { return }
        let existingReaction = reactionStats.currentUserReaction(
            for: eventID,
            currentPubkey: auth.currentAccount?.pubkey
        )
        let optimisticToggle = reactionStats.applyOptimisticToggle(
            for: eventID,
            currentPubkey: auth.currentAccount?.pubkey,
            bonusCount: bonusCount
        )
        defer {
            reactionStats.endPublishingReaction(for: eventID)
        }

        do {
            let result = try await reactionPublishService.toggleReaction(
                for: sourceEvent,
                existingReactionID: existingReaction?.id,
                bonusCount: bonusCount,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                relayHintURL: effectiveReadRelayURLs.first
            )

            switch result {
            case .liked(let reactionEvent):
                reactionStats.registerPublishedReaction(
                    reactionEvent,
                    targetEventID: eventID
                )
            case .unliked(let reactionID):
                reactionStats.registerDeletedReaction(
                    reactionID: reactionID,
                    targetEventID: eventID
                )
            }
        } catch {
            reactionStats.rollbackOptimisticToggle(for: eventID, snapshot: optimisticToggle)
            return
        }
    }

    @ViewBuilder
    private func inlineReshareActionRow(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(appSettings.themePalette.foreground)

                Spacer(minLength: 0)

                if isPublishingRepost && title == "Repost" {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPublishingRepost)
    }

    @MainActor
    private func publishRepost() async {
        guard !isPublishingRepost else { return }
        isPublishingRepost = true
        repostStatusMessage = nil
        repostStatusIsError = false
        defer { isPublishingRepost = false }

        do {
            let relayCount = try await reshareService.publishRepost(
                of: sourceEvent,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                relayHintURL: effectiveReadRelayURLs.first
            )
            repostStatusMessage = "Reposted to \(relayCount) source\(relayCount == 1 ? "" : "s")."
            repostStatusIsError = false

            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                isShowingInlineResharePanel = false
            }
        } catch {
            repostStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            repostStatusIsError = true
        }
    }

    @MainActor
    private func openRemixEditor() async {
        guard !isPreparingRemixEditor else { return }
        isPreparingRemixEditor = true
        defer {
            isPreparingRemixEditor = false
        }

        let currentURL = urls[selectedIndex]
        guard let image = await FlowImageCache.shared.image(for: currentURL) else {
            toastCenter.show("Couldn't load that image for editing.", style: .error, duration: 2.8)
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
            // Dismiss the fullscreen image viewer before asking the app shell to present compose.
            dismiss()
            try? await Task.sleep(nanoseconds: 320_000_000)
            composeSheetCoordinator.presentRemix(
                attachment: draft.attachment,
                replyTargetEvent: draft.replyTargetEvent
            )
        }
    }

    @MainActor
    private func presentReplyComposer() {
        Task { @MainActor in
            dismiss()
            try? await Task.sleep(nanoseconds: 320_000_000)
            composeSheetCoordinator.presentReply(to: sourceEvent)
        }
    }

    @MainActor
    private func presentQuoteComposer() {
        let draft = reshareService.buildQuoteDraft(
            for: sourceEvent,
            relayHintURL: effectiveReadRelayURLs.first
        )

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            isShowingInlineResharePanel = false
        }

        Task { @MainActor in
            dismiss()
            try? await Task.sleep(nanoseconds: 320_000_000)
            composeSheetCoordinator.presentQuote(draft)
        }
    }

    private func swipeToDismissGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard !isShowingInlineResharePanel, !isShowingRemixEditor, !isPreparingRemixEditor else { return }
                guard !isCurrentImageZoomed else { return }
                guard shouldTrackSwipeDismiss(for: value.translation) else { return }
                swipeDismissOffset = value.translation
            }
            .onEnded { value in
                guard !isShowingInlineResharePanel, !isShowingRemixEditor else { return }
                guard !isCurrentImageZoomed else {
                    swipeDismissOffset = .zero
                    return
                }
                guard shouldTrackSwipeDismiss(for: value.translation) else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        swipeDismissOffset = .zero
                    }
                    return
                }

                let finalTranslation = projectedSwipeDismissOffset(for: value)
                if shouldCompleteSwipeDismiss(with: finalTranslation, in: containerSize) {
                    completeSwipeDismiss(using: finalTranslation, in: containerSize)
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        swipeDismissOffset = .zero
                    }
                }
            }
    }

    private func shouldTrackSwipeDismiss(for translation: CGSize) -> Bool {
        guard !isCompletingSwipeDismiss else { return false }
        if urls.count <= 1 {
            return true
        }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        if vertical >= max(horizontal * 0.7, 20) {
            return true
        }

        let isSwipingOutFromLeadingEdge = translation.width > 0 && selectedIndex == 0
        let isSwipingOutFromTrailingEdge = translation.width < 0 && selectedIndex == urls.count - 1
        return horizontal >= max(vertical * 1.25, 44) &&
            (isSwipingOutFromLeadingEdge || isSwipingOutFromTrailingEdge)
    }

    private func projectedSwipeDismissOffset(for value: DragGesture.Value) -> CGSize {
        CGSize(
            width: value.predictedEndTranslation.width,
            height: value.predictedEndTranslation.height
        )
    }

    private func shouldCompleteSwipeDismiss(with translation: CGSize, in size: CGSize) -> Bool {
        let distance = hypot(translation.width, translation.height)
        let threshold = max(150, min(size.width, size.height) * 0.18)
        return distance >= threshold
    }

    private func completeSwipeDismiss(using translation: CGSize, in size: CGSize) {
        guard !isCompletingSwipeDismiss else { return }
        isCompletingSwipeDismiss = true

        let targetOffset = swipeDismissCompletionOffset(for: translation, in: size)
        withAnimation(.easeOut(duration: 0.2)) {
            swipeDismissOffset = targetOffset
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            dismiss()
        }
    }

    private func swipeDismissCompletionOffset(for translation: CGSize, in size: CGSize) -> CGSize {
        let distance = max(hypot(translation.width, translation.height), 1)
        let direction = CGVector(dx: translation.width / distance, dy: translation.height / distance)
        let exitDistance = max(size.width, size.height) * 1.18
        return CGSize(
            width: direction.dx * exitDistance,
            height: direction.dy * exitDistance
        )
    }

    private func viewerBackgroundOpacity(for size: CGSize) -> Double {
        let distance = hypot(swipeDismissOffset.width, swipeDismissOffset.height)
        let maxDistance = max(min(size.width, size.height) * 0.75, 1)
        return max(0.35, 1 - (distance / maxDistance) * 0.75)
    }

    private func viewerScale(for size: CGSize) -> CGFloat {
        let distance = hypot(swipeDismissOffset.width, swipeDismissOffset.height)
        let maxDistance = max(max(size.width, size.height), 1)
        return max(0.9, 1 - (distance / maxDistance) * 0.09)
    }

    private func viewerRotationDegrees(for size: CGSize) -> Double {
        guard size.width > 0 else { return 0 }
        return Double(swipeDismissOffset.width / size.width) * 8
    }

    private var isCurrentImageZoomed: Bool {
        zoomedImageIndices.contains(selectedIndex)
    }

    private func updateZoomState(_ isZoomed: Bool, for index: Int) {
        if isZoomed {
            zoomedImageIndices.insert(index)
        } else {
            zoomedImageIndices.remove(index)
        }
    }
}

struct NoteImageRemixComposeDraft: Identifiable {
    let id = UUID()
    let attachment: ComposeMediaAttachment
    let replyTargetEvent: NostrEvent?
}

private actor NoteVideoAspectRatioCache {
    static let shared = NoteVideoAspectRatioCache()

    private var cachedRatios: [URL: CGFloat] = [:]
    private var inFlight: [URL: Task<CGFloat?, Never>] = [:]

    func ratio(for url: URL) async -> CGFloat? {
        if let persistedRatio = FlowMediaAspectRatioCache.shared.ratio(for: url) {
            cachedRatios[url] = persistedRatio
            return persistedRatio
        }

        if let cached = cachedRatios[url] {
            return cached
        }

        if let existingTask = inFlight[url] {
            return await existingTask.value
        }

        let task = Task(priority: .utility) {
            await Self.loadRatio(for: url)
        }
        inFlight[url] = task

        let ratio = await task.value
        inFlight[url] = nil

        if let ratio {
            cachedRatios[url] = ratio
            FlowMediaAspectRatioCache.shared.insert(ratio, for: url)
        }

        return ratio
    }

    private static func loadRatio(for url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)

        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }

            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)

            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            guard width > 0, height > 0 else { return nil }

            return max(0.4, min(width / height, 3.0))
        } catch {
            return nil
        }
    }
}

actor NoteShortMP4LoopPolicy {
    static let shared = NoteShortMP4LoopPolicy()
    static let maximumLoopingDurationSeconds: TimeInterval = 4

    private var cachedDecisions: [URL: Bool] = [:]
    private var inFlight: [URL: Task<Bool, Never>] = [:]

    static func isCandidateURL(_ url: URL) -> Bool {
        url.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "mp4"
    }

    func shouldLoop(url: URL) async -> Bool {
        guard Self.isCandidateURL(url) else { return false }

        if let cached = cachedDecisions[url] {
            return cached
        }

        if let existingTask = inFlight[url] {
            return await existingTask.value
        }

        let task = Task(priority: .utility) {
            await Self.loadShouldLoop(url: url)
        }
        inFlight[url] = task

        let shouldLoop = await task.value
        inFlight[url] = nil
        cachedDecisions[url] = shouldLoop

        return shouldLoop
    }

    private static func loadShouldLoop(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite &&
                seconds > 0 &&
                seconds <= maximumLoopingDurationSeconds
        } catch {
            return false
        }
    }
}

actor NoteMediaGeometryPrefetcher {
    static let shared = NoteMediaGeometryPrefetcher()

    private let maxPrefetchedImages = 36
    private let maxPrefetchedVideos = 12

    func prefetch(events: [NostrEvent]) async {
        let candidates = Self.mediaCandidates(in: events)

        for hint in candidates.hints {
            FlowMediaAspectRatioCache.shared.insert(hint.ratio, forURLString: hint.urlString)
        }

        await withTaskGroup(of: Void.self) { group in
            for url in candidates.imageURLs.prefix(maxPrefetchedImages) {
                group.addTask {
                    _ = await FlowImageCache.shared.aspectRatio(for: url)
                }
            }

            for url in candidates.videoURLs.prefix(maxPrefetchedVideos) {
                group.addTask {
                    _ = await NoteVideoAspectRatioCache.shared.ratio(for: url)
                }
            }

            await group.waitForAll()
        }
    }

    private static func mediaCandidates(
        in events: [NostrEvent]
    ) -> (imageURLs: [URL], videoURLs: [URL], hints: [(urlString: String, ratio: CGFloat)]) {
        var imageURLs: [URL] = []
        var videoURLs: [URL] = []
        var hints: [(urlString: String, ratio: CGFloat)] = []
        var seenImageURLs = Set<String>()
        var seenVideoURLs = Set<String>()
        var seenHintURLs = Set<String>()

        for event in events {
            for tag in event.tags where tag.first?.lowercased() == "imeta" {
                var urlString: String?
                var pixelSize: CGSize?

                for value in tag.dropFirst() {
                    if value.hasPrefix("url ") {
                        urlString = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if value.hasPrefix("dim ") {
                        pixelSize = Self.pixelSize(fromDimensionString: String(value.dropFirst(4)))
                    }
                }

                guard let urlString,
                      !urlString.isEmpty,
                      let pixelSize,
                      let ratio = NoteImageLayoutGuide.normalizedAspectRatio(pixelSize.width / max(pixelSize.height, 1)) else {
                    continue
                }

                let key = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard seenHintURLs.insert(key).inserted else { continue }
                hints.append((urlString: urlString, ratio: ratio))
            }

            for token in NoteContentParser.tokenize(event: event) {
                switch token.type {
                case .image:
                    appendURL(
                        token.value,
                        to: &imageURLs,
                        seen: &seenImageURLs
                    )
                case .video:
                    appendURL(
                        token.value,
                        to: &videoURLs,
                        seen: &seenVideoURLs
                    )
                default:
                    continue
                }
            }
        }

        return (imageURLs, videoURLs, hints)
    }

    private static func appendURL(
        _ rawValue: String,
        to urls: inout [URL],
        seen: inout Set<String>
    ) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }

        let key = url.absoluteString.lowercased()
        guard seen.insert(key).inserted else { return }
        urls.append(url)
    }

    private static func pixelSize(fromDimensionString value: String) -> CGSize? {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "X", with: "x")
        let components = sanitized.split(separator: "x", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}

final class NoteVideoThumbnailCache {
    static let shared = NoteVideoThumbnailCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 96
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

private func generateNoteVideoThumbnail(for url: URL, maximumPixelSize: CGSize) async -> UIImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumPixelSize

    do {
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let candidateSeconds = [
            0.15,
            0.8,
            durationSeconds.isFinite && durationSeconds > 0
                ? min(max(durationSeconds * 0.18, 0.25), min(durationSeconds, 2.0))
                : 1.0
        ]

        for seconds in candidateSeconds {
            let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
        }
    } catch {
        for seconds in [0.15, 0.8, 1.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
        }
    }

    return nil
}

struct NoteVideoPlayerView: View {
    let url: URL
    let layout: NoteContentMediaLayout
    let isGIFLike: Bool
    let aspectRatioHint: CGFloat?
    @State private var videoAspectRatio: CGFloat
    @State private var videoThumbnail: UIImage?
    @State private var isPlaying = false
    @State private var shortMP4LoopURL: URL?

    init(
        url: URL,
        layout: NoteContentMediaLayout,
        isGIFLike: Bool = false,
        aspectRatioHint: CGFloat? = nil
    ) {
        self.url = url
        self.layout = layout
        self.isGIFLike = isGIFLike
        let normalizedHint = NoteImageLayoutGuide.normalizedAspectRatio(aspectRatioHint)
        self.aspectRatioHint = normalizedHint
        _videoAspectRatio = State(
            initialValue: NoteImageLayoutGuide.reservedVideoAspectRatio(
                exactHint: normalizedHint,
                cachedExactRatio: FlowMediaAspectRatioCache.shared.ratio(for: url)
            )
        )
    }

    var body: some View {
        let rendersAsGIFLikeVideo = isGIFLike || shortMP4LoopURL == url

        NoteAspectRatioMediaLayout(
            aspectRatio: videoAspectRatio,
            maxHeight: maxVideoHeight
        ) {
            ZStack {
                Color.black.opacity(0.08)

                NoteNativeVideoPlayerController(
                    url: url,
                    autoplay: rendersAsGIFLikeVideo,
                    showsPlaybackControls: !rendersAsGIFLikeVideo,
                    isMuted: rendersAsGIFLikeVideo,
                    loops: rendersAsGIFLikeVideo,
                    onPlaybackStateChange: { nextIsPlaying in
                        isPlaying = nextIsPlaying
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isPlaying {
                    thumbnailLayer
                        .allowsHitTesting(false)
                        .transition(.opacity)

                    if !rendersAsGIFLikeVideo {
                        previewPlayAffordance
                    }
                }
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: mediaCornerRadius, style: .continuous)
        )
        .contentShape(
            RoundedRectangle(cornerRadius: mediaCornerRadius, style: .continuous)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url, priority: .utility) {
            await MainActor.run {
                shortMP4LoopURL = nil
                videoThumbnail = NoteVideoThumbnailCache.shared.image(for: url)
            }
            async let shortMP4LoopPolicy: Void = loadShortMP4LoopPolicy()
            async let aspectRatioLoad: Void = loadVideoAspectRatio()
            async let thumbnailLoad: Void = loadVideoThumbnailIfNeeded()
            _ = await (shortMP4LoopPolicy, aspectRatioLoad, thumbnailLoad)
        }
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let videoThumbnail {
            Image(uiImage: videoThumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    private var maxVideoHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.72, 620)
    }

    private var mediaCornerRadius: CGFloat {
        layout == .feed ? 18 : 12
    }

    private var previewPlayAffordance: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 66, height: 66)

            Image(systemName: "play.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 2)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    private func loadVideoAspectRatio() async {
        setVideoAspectRatio(
            NoteImageLayoutGuide.reservedVideoAspectRatio(
                exactHint: aspectRatioHint,
                cachedExactRatio: FlowMediaAspectRatioCache.shared.ratio(for: url)
            )
        )

        guard let ratio = await NoteVideoAspectRatioCache.shared.ratio(for: url) else { return }
        guard !Task.isCancelled else { return }

        setVideoAspectRatio(ratio)
    }

    @MainActor
    private func setVideoAspectRatio(_ nextRatio: CGFloat) {
        guard abs(videoAspectRatio - nextRatio) > 0.02 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            videoAspectRatio = nextRatio
        }
    }

    private func loadVideoThumbnailIfNeeded() async {
        if let cached = NoteVideoThumbnailCache.shared.image(for: url) {
            await MainActor.run {
                videoThumbnail = cached
            }
            return
        }

        let thumbnailPixelSize = await MainActor.run {
            CGSize(
                width: max(UIScreen.main.bounds.width - 28, 1) * UIScreen.main.scale,
                height: max(maxVideoHeight, 1) * UIScreen.main.scale
            )
        }

        let generatedThumbnail: UIImage? = await Task.detached(priority: .utility) {
            await generateNoteVideoThumbnail(for: url, maximumPixelSize: thumbnailPixelSize)
        }.value

        guard !Task.isCancelled else { return }

        await MainActor.run {
            videoThumbnail = generatedThumbnail
        }

        guard let generatedThumbnail else { return }
        NoteVideoThumbnailCache.shared.insert(generatedThumbnail, for: url)
    }

    private func loadShortMP4LoopPolicy() async {
        guard !isGIFLike else { return }

        let shouldLoop = await NoteShortMP4LoopPolicy.shared.shouldLoop(url: url)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            shortMP4LoopURL = shouldLoop ? url : nil
        }
    }
}

private struct NoteAspectRatioMediaLayout: Layout {
    let aspectRatio: CGFloat
    let maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        FlowLayoutGuardrails.aspectFitMediaSize(
            availableWidth: proposal.width,
            aspectRatio: aspectRatio,
            maxHeight: maxHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let size = FlowLayoutGuardrails.aspectFitMediaSize(
            availableWidth: bounds.width,
            aspectRatio: aspectRatio,
            maxHeight: maxHeight
        )
        let origin = CGPoint(x: bounds.minX, y: bounds.minY)

        for subview in subviews {
            subview.place(
                at: origin,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }
}

private enum NoteVideoPlaybackAudioSession {
    static func configureForMediaPlayback() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.mixWithOthers]
        )
    }

    static func activateIfNeeded() {
        let audioSession = AVAudioSession.sharedInstance()
        configureForMediaPlayback()
        try? audioSession.setActive(true, options: [])
    }
}

struct NoteInlineFeedVideoPlayer: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let onPlaybackEnded: () -> Void

    final class Coordinator {
        let player = AVPlayer()
        private var currentURL: URL?
        private var playbackEndedObserver: NSObjectProtocol?
        private var onPlaybackEnded: (() -> Void)?

        deinit {
            removePlaybackEndedObserver()
        }

        func configure(
            url: URL,
            in view: NoteInlineFeedVideoPlayerContainerView,
            isPlaying: Bool,
            onPlaybackEnded: @escaping () -> Void
        ) {
            self.onPlaybackEnded = onPlaybackEnded
            view.playerLayer.player = player

            if currentURL != url {
                currentURL = url

                let item = AVPlayerItem(url: url)
                player.actionAtItemEnd = .pause
                player.replaceCurrentItem(with: item)
                observePlaybackEnded(for: item)
            }

            if isPlaying {
                NoteVideoPlaybackAudioSession.activateIfNeeded()
                if player.timeControlStatus != .playing {
                    player.play()
                }
            } else {
                player.pause()
            }
        }

        func stop() {
            removePlaybackEndedObserver()
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentURL = nil
            onPlaybackEnded = nil
        }

        private func observePlaybackEnded(for item: AVPlayerItem) {
            removePlaybackEndedObserver()
            playbackEndedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.player.pause()
                self.player.seek(to: .zero)
                self.onPlaybackEnded?()
            }
        }

        private func removePlaybackEndedObserver() {
            guard let playbackEndedObserver else { return }
            NotificationCenter.default.removeObserver(playbackEndedObserver)
            self.playbackEndedObserver = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NoteInlineFeedVideoPlayerContainerView {
        let view = NoteInlineFeedVideoPlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = context.coordinator.player
        context.coordinator.configure(
            url: url,
            in: view,
            isPlaying: isPlaying,
            onPlaybackEnded: onPlaybackEnded
        )
        return view
    }

    func updateUIView(_ uiView: NoteInlineFeedVideoPlayerContainerView, context: Context) {
        uiView.playerLayer.videoGravity = .resizeAspect
        uiView.playerLayer.player = context.coordinator.player
        context.coordinator.configure(
            url: url,
            in: uiView,
            isPlaying: isPlaying,
            onPlaybackEnded: onPlaybackEnded
        )
    }

    static func dismantleUIView(
        _ uiView: NoteInlineFeedVideoPlayerContainerView,
        coordinator: Coordinator
    ) {
        uiView.playerLayer.player = nil
        coordinator.stop()
    }
}

final class NoteInlineFeedVideoPlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct NoteAudioPlayerView: View {
    let url: URL
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var player: AVPlayer
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var dragProgress: Double?
    @State private var timeObserverToken: Any?
    @State private var timeControlStatusObserver: NSKeyValueObservation?

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(appSettings.buttonTextColor)
                    .offset(x: isPlaying ? 0 : 1.5)
                    .frame(
                        width: NoteAudioPlayerLayout.playButtonDiameter,
                        height: NoteAudioPlayerLayout.playButtonDiameter
                    )
                    .background {
                        Circle()
                            .fill(appSettings.primaryGradient)
                    }
                    .shadow(
                        color: appSettings.primaryColor.opacity(isPlaying ? 0.24 : 0.12),
                        radius: isPlaying ? 12 : 7,
                        x: 0,
                        y: isPlaying ? 7 : 4
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")

            VStack(alignment: .leading, spacing: 8) {
                NoteAudioWaveformScrubber(
                    progress: displayedProgress,
                    isPlaying: isPlaying,
                    isEnabled: hasPlayableDuration,
                    onScrub: { progress in
                        dragProgress = progress
                    },
                    onScrubEnded: { progress in
                        seek(toProgress: progress)
                        dragProgress = nil
                    }
                )

                HStack(spacing: 8) {
                    Text(NoteAudioPlayerLayout.timeText(seconds: displayedTime))
                    Spacer(minLength: 8)
                    Text(durationText)
                }
                .font(appSettings.appFont(.caption2, weight: .medium))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .monospacedDigit()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(audioPlayerBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.72), lineWidth: 0.7)
        )
        .onAppear {
            configurePlaybackObservers()
            updateDurationFromCurrentItem()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
        ) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem == player.currentItem else { return }
            isPlaying = false
            currentTime = 0
            dragProgress = nil
            player.seek(to: .zero)
        }
        .onDisappear {
            player.pause()
            isPlaying = false
            removePlaybackObservers()
        }
    }

    private var audioPlayerBackground: Color {
        if effectiveAudioColorScheme == .light {
            return .white
        }
        return appSettings.themePalette.secondaryBackground.opacity(0.94)
    }

    private var effectiveAudioColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }

    private var hasPlayableDuration: Bool {
        duration.isFinite && duration > 0
    }

    private var displayedProgress: Double {
        dragProgress ?? NoteAudioPlayerLayout.progress(
            currentTime: currentTime,
            duration: duration
        )
    }

    private var displayedTime: Double {
        guard let dragProgress else { return currentTime }
        return NoteAudioPlayerLayout.seekSeconds(
            forProgress: dragProgress,
            duration: duration
        )
    }

    private var durationText: String {
        guard hasPlayableDuration else { return "--:--" }
        return NoteAudioPlayerLayout.timeText(seconds: duration)
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            NoteVideoPlaybackAudioSession.activateIfNeeded()
            player.play()
            isPlaying = true
        }
    }

    private func seek(toProgress progress: Double) {
        guard hasPlayableDuration else { return }
        let seconds = NoteAudioPlayerLayout.seekSeconds(
            forProgress: progress,
            duration: duration
        )
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func configurePlaybackObservers() {
        guard timeObserverToken == nil else { return }

        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { observedPlayer, _ in
            DispatchQueue.main.async {
                isPlaying = observedPlayer.timeControlStatus == .playing
            }
        }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard dragProgress == nil else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                currentTime = seconds
            }
            updateDurationFromCurrentItem()
        }
    }

    private func removePlaybackObservers() {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
    }

    private func updateDurationFromCurrentItem() {
        guard let seconds = player.currentItem?.duration.seconds,
              seconds.isFinite,
              seconds > 0 else {
            return
        }
        duration = seconds
    }
}

enum NoteAudioPlayerLayout {
    static let playButtonDiameter: CGFloat = 54
    static let waveformHeight: CGFloat = 44
    static let waveformBarCount = 40

    static func progress(currentTime: Double, duration: Double) -> Double {
        guard currentTime.isFinite,
              duration.isFinite,
              duration > 0 else {
            return 0
        }
        return min(max(currentTime / duration, 0), 1)
    }

    static func seekSeconds(forProgress progress: Double, duration: Double) -> Double {
        guard progress.isFinite,
              duration.isFinite,
              duration > 0 else {
            return 0
        }
        return min(max(progress, 0), 1) * duration
    }

    static func waveformBarHeight(
        index: Int,
        phase: Double,
        isPlaying: Bool,
        maxHeight: CGFloat = waveformHeight
    ) -> CGFloat {
        let base = 0.34 + (sin(Double(index) * 0.74) + 1) * 0.23
        let motion = isPlaying ? (sin((phase * 4.2) + Double(index) * 0.58) + 1) * 0.18 : 0
        let normalized = min(max(base + motion, 0.18), 0.96)
        return max(8, maxHeight * normalized)
    }

    static func timeText(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct NoteAudioWaveformScrubber: View {
    let progress: Double
    let isPlaying: Bool
    let isEnabled: Bool
    let onScrub: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isPlaying)) { context in
            GeometryReader { proxy in
                let clampedProgress = min(max(progress, 0), 1)
                let phase = isPlaying ? context.date.timeIntervalSinceReferenceDate : 0
                let width = max(proxy.size.width, 1)
                let barCount = NoteAudioPlayerLayout.waveformBarCount
                let spacing: CGFloat = 3
                let barWidth = max(2.5, (width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
                let filledBarCount = Int((clampedProgress * Double(barCount)).rounded(.down))

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(barFill(for: index, filledBarCount: filledBarCount))
                            .frame(
                                width: barWidth,
                                height: NoteAudioPlayerLayout.waveformBarHeight(
                                    index: index,
                                    phase: phase,
                                    isPlaying: isPlaying,
                                    maxHeight: NoteAudioPlayerLayout.waveformHeight
                                )
                            )
                    }
                }
                .frame(width: width, height: NoteAudioPlayerLayout.waveformHeight, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isEnabled else { return }
                            onScrub(progress(forX: value.location.x, width: width))
                        }
                        .onEnded { value in
                            guard isEnabled else { return }
                            onScrubEnded(progress(forX: value.location.x, width: width))
                        }
                )
            }
        }
        .frame(height: NoteAudioPlayerLayout.waveformHeight)
        .accessibilityElement()
        .accessibilityLabel("Audio progress")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
        .accessibilityHint(isEnabled ? "Drag to seek" : "Duration unavailable")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = 0.05
            switch direction {
            case .increment:
                onScrubEnded(min(progress + step, 1))
            case .decrement:
                onScrubEnded(max(progress - step, 0))
            @unknown default:
                break
            }
        }
    }

    private func progress(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }

    private func barFill(for index: Int, filledBarCount: Int) -> Color {
        if index < filledBarCount {
            return appSettings.primaryColor.opacity(isEnabled ? 0.95 : 0.62)
        }

        return appSettings.themePalette.secondaryFill.opacity(isPlaying ? 0.88 : 0.72)
    }
}

private final class NoteInlineAVPlayerViewController: AVPlayerViewController {
    override var childForStatusBarHidden: UIViewController? {
        nil
    }

    override var prefersStatusBarHidden: Bool {
        false
    }
}

struct NoteNativeVideoPlayerController: UIViewControllerRepresentable {
    let url: URL
    var autoplay: Bool = true
    var showsPlaybackControls: Bool = true
    var isMuted: Bool = false
    var loops: Bool = false
    var onPlaybackStateChange: ((Bool) -> Void)? = nil

    final class Coordinator {
        let player = AVPlayer()
        private var currentURL: URL?
        private var shouldAutoplayForCurrentURL = true
        private var isMutedForCurrentURL = false
        private var loopsCurrentURL = false
        private var playbackEndedObserver: NSObjectProtocol?
        private var playbackStatusObserver: NSKeyValueObservation?
        private var onPlaybackStateChange: ((Bool) -> Void)?
        private var lastKnownIsPlaying = false

        deinit {
            removePlaybackEndedObserver()
            playbackStatusObserver?.invalidate()
        }

        func configure(
            url: URL,
            autoplay: Bool,
            isMuted: Bool,
            loops: Bool,
            controller: AVPlayerViewController,
            onPlaybackStateChange: ((Bool) -> Void)?
        ) {
            self.onPlaybackStateChange = onPlaybackStateChange
            observePlaybackStateIfNeeded()
            isMutedForCurrentURL = isMuted
            loopsCurrentURL = loops
            player.isMuted = isMuted
            player.volume = isMuted ? 0 : 1

            if currentURL != url || controller.player !== player {
                currentURL = url
                shouldAutoplayForCurrentURL = autoplay
                controller.player = player
                player.automaticallyWaitsToMinimizeStalling = false
                player.actionAtItemEnd = loops ? .none : .pause
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 2
                player.replaceCurrentItem(with: item)
                observePlaybackEnded(for: item)
                publishPlaybackState(false)
            } else {
                shouldAutoplayForCurrentURL = shouldAutoplayForCurrentURL || autoplay
                player.actionAtItemEnd = loops ? .none : .pause
            }

            guard controller.player === player else { return }

            if shouldAutoplayForCurrentURL {
                NoteVideoPlaybackAudioSession.configureForMediaPlayback()
                if !isMuted {
                    NoteVideoPlaybackAudioSession.activateIfNeeded()
                }
                player.play()
                shouldAutoplayForCurrentURL = false
            }
        }

        func stop() {
            removePlaybackEndedObserver()
            playbackStatusObserver?.invalidate()
            playbackStatusObserver = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentURL = nil
            onPlaybackStateChange = nil
            publishPlaybackState(false)
        }

        private func observePlaybackStateIfNeeded() {
            guard playbackStatusObserver == nil else { return }

            playbackStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let isPlaying = player.timeControlStatus == .playing
                DispatchQueue.main.async {
                    guard let self else { return }
                    if isPlaying, !self.isMutedForCurrentURL {
                        NoteVideoPlaybackAudioSession.activateIfNeeded()
                    }
                    self.publishPlaybackState(isPlaying)
                }
            }
        }

        private func observePlaybackEnded(for item: AVPlayerItem) {
            removePlaybackEndedObserver()
            playbackEndedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }

                if self.loopsCurrentURL {
                    self.player.seek(
                        to: .zero,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    ) { [weak self] finished in
                        guard finished, let self else { return }
                        NoteVideoPlaybackAudioSession.configureForMediaPlayback()
                        self.player.play()
                    }
                } else {
                    self.publishPlaybackState(false)
                }
            }
        }

        private func removePlaybackEndedObserver() {
            guard let playbackEndedObserver else { return }
            NotificationCenter.default.removeObserver(playbackEndedObserver)
            self.playbackEndedObserver = nil
        }

        private func publishPlaybackState(_ isPlaying: Bool) {
            guard lastKnownIsPlaying != isPlaying else { return }
            lastKnownIsPlaying = isPlaying
            onPlaybackStateChange?(isPlaying)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = NoteInlineAVPlayerViewController()
        controller.showsPlaybackControls = showsPlaybackControls
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.modalPresentationCapturesStatusBarAppearance = false
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.contentOverlayView?.backgroundColor = .clear
        controller.setNeedsStatusBarAppearanceUpdate()
        context.coordinator.configure(
            url: url,
            autoplay: autoplay,
            isMuted: isMuted,
            loops: loops,
            controller: controller,
            onPlaybackStateChange: onPlaybackStateChange
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.showsPlaybackControls = showsPlaybackControls
        uiViewController.modalPresentationCapturesStatusBarAppearance = false
        uiViewController.view.backgroundColor = .clear
        uiViewController.view.isOpaque = false
        uiViewController.contentOverlayView?.backgroundColor = .clear
        uiViewController.setNeedsStatusBarAppearanceUpdate()
        context.coordinator.configure(
            url: url,
            autoplay: autoplay,
            isMuted: isMuted,
            loops: loops,
            controller: uiViewController,
            onPlaybackStateChange: onPlaybackStateChange
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.player = nil
        coordinator.stop()
    }
}
