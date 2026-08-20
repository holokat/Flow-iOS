import ImageIO
import SwiftUI
import UIKit

enum NoteMediaAsset {
    case still(UIImage)
    case gif(NoteGIFPayload)

    var size: CGSize {
        switch self {
        case .still(let image):
            return image.size
        case .gif(let payload):
            return payload.size
        }
    }

    var aspectRatio: CGFloat? {
        let resolvedSize = size
        guard resolvedSize.width > 0, resolvedSize.height > 0 else { return nil }
        return resolvedSize.width / resolvedSize.height
    }
}

enum NoteMediaScaling {
    case fill
    case fit

    var swiftUIContentMode: ContentMode {
        switch self {
        case .fill:
            return .fill
        case .fit:
            return .fit
        }
    }

    var uiKitContentMode: UIView.ContentMode {
        switch self {
        case .fill:
            return .scaleAspectFill
        case .fit:
            return .scaleAspectFit
        }
    }
}

struct NoteMediaAssetContentView: View {
    let asset: NoteMediaAsset
    let scaling: NoteMediaScaling
    var preservesNaturalAspectRatio = false

    private var boundedAspectRatio: CGFloat? {
        if preservesNaturalAspectRatio {
            return NoteImageLayoutGuide.normalizedSingleImageAspectRatio(asset.aspectRatio)
        }
        return FlowLayoutGuardrails.clampedAspectRatio(asset.aspectRatio)
    }

    var body: some View {
        Group {
            switch asset {
            case .still(let image):
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: scaling.swiftUIContentMode)
            case .gif(let payload):
                NoteAnimatedGIFView(
                    payload: payload,
                    contentMode: scaling.uiKitContentMode
                )
            }
        }
        .aspectRatio(boundedAspectRatio, contentMode: scaling.swiftUIContentMode)
        .frame(maxWidth: .infinity, alignment: .center)
        .clipped()
    }
}

enum NoteImageLayoutGuide {
    static let defaultSingleImageAspectRatio: CGFloat = 4.0 / 3.0
    static let defaultVideoAspectRatio: CGFloat = 16.0 / 9.0
    private static let maximumSingleImageAspectRatio: CGFloat = 24

    private static let aspectRatioBuckets: [CGFloat] = [
        9.0 / 16.0,
        3.0 / 4.0,
        4.0 / 5.0,
        1.0,
        4.0 / 3.0,
        3.0 / 2.0,
        16.0 / 9.0
    ]

    static func normalizedAspectRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return min(max(ratio, 0.28), 3.2)
    }

    static func normalizedSingleImageAspectRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return min(max(ratio, 0.28), maximumSingleImageAspectRatio)
    }

    static func reservedSingleImageAspectRatio(
        exactHint: CGFloat?,
        cachedExactRatio: CGFloat?
    ) -> CGFloat {
        normalizedSingleImageAspectRatio(exactHint ?? cachedExactRatio) ?? defaultSingleImageAspectRatio
    }

    static func reservedVideoAspectRatio(
        exactHint: CGFloat?,
        cachedExactRatio: CGFloat?
    ) -> CGFloat {
        normalizedAspectRatio(exactHint ?? cachedExactRatio) ?? defaultVideoAspectRatio
    }

    static func bucketedSingleImageAspectRatio(for exactRatio: CGFloat?) -> CGFloat {
        guard let normalized = normalizedAspectRatio(exactRatio) else {
            return defaultSingleImageAspectRatio
        }

        return aspectRatioBuckets.min(by: { abs($0 - normalized) < abs($1 - normalized) })
            ?? defaultSingleImageAspectRatio
    }

    static func imageAspectRatioHints(from tags: [[String]]) -> [String: CGFloat] {
        aspectRatioHints(from: tags, requiredMimePrefix: "image/")
    }

    static func mediaAspectRatioHints(from tags: [[String]]) -> [String: CGFloat] {
        aspectRatioHints(from: tags, requiredMimePrefix: nil)
    }

    static func aspectRatioHint(for url: URL, in hints: [String: CGFloat]) -> CGFloat? {
        for key in aspectRatioHintKeys(for: url) {
            if let ratio = normalizedAspectRatio(hints[key]) {
                return ratio
            }
        }
        return nil
    }

    static func singleImageAspectRatioHint(for url: URL, in hints: [String: CGFloat]) -> CGFloat? {
        for key in aspectRatioHintKeys(for: url) {
            if let ratio = normalizedSingleImageAspectRatio(hints[key]) {
                return ratio
            }
        }
        return nil
    }

    static func singleImageHeight(width: CGFloat, aspectRatio: CGFloat?) -> CGFloat {
        let safeWidth = width.isFinite && width > 0 ? width : 1
        let ratio = normalizedSingleImageAspectRatio(aspectRatio) ?? defaultSingleImageAspectRatio
        return safeWidth / ratio
    }

    static func naturalHeight(
        width: CGFloat,
        aspectRatio: CGFloat?,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        let ratio = normalizedAspectRatio(aspectRatio) ?? defaultSingleImageAspectRatio
        let naturalHeight = width / ratio
        return min(max(naturalHeight, minHeight), maxHeight)
    }

    private static func aspectRatioHints(
        from tags: [[String]],
        requiredMimePrefix: String?
    ) -> [String: CGFloat] {
        var hints: [String: CGFloat] = [:]

        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "imeta" else { continue }

            var urlString: String?
            var mimeType: String?
            var pixelSize: CGSize?

            for value in tag.dropFirst() {
                if value.hasPrefix("url ") {
                    urlString = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if value.hasPrefix("m ") {
                    mimeType = String(value.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } else if value.hasPrefix("dim ") {
                    pixelSize = Self.pixelSize(fromDimensionString: String(value.dropFirst(4)))
                }
            }

            guard let urlString, !urlString.isEmpty else { continue }
            if let requiredMimePrefix,
               let mimeType,
               !mimeType.isEmpty,
               !mimeType.hasPrefix(requiredMimePrefix) {
                continue
            }
            guard let pixelSize,
                  let aspectRatio = normalizedSingleImageAspectRatio(pixelSize.width / max(pixelSize.height, 1)) else {
                continue
            }

            for key in aspectRatioHintKeys(forURLString: urlString) {
                hints[key] = aspectRatio
            }
        }

        return hints
    }

    private static func aspectRatioHintKeys(for url: URL) -> [String] {
        aspectRatioHintKeys(forURLString: url.absoluteString)
    }

    private static func aspectRatioHintKeys(forURLString urlString: String) -> [String] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys: [String] = []
        func append(_ key: String) {
            guard !key.isEmpty, !keys.contains(key) else { return }
            keys.append(key)
        }

        append(trimmed)
        append(trimmed.lowercased())

        if var components = URLComponents(string: trimmed) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if let normalized = components.url?.absoluteString {
                append(normalized)
                append(normalized.lowercased())
            }
        }

        return keys
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

struct NoteZoomableFullscreenImageView: View {
    let url: URL
    var kind: FlowImageCacheRequestKind = .fullscreen
    let chromeForegroundColor: Color
    let onZoomStateChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        NoteRemoteMediaView(
            url: url,
            kind: kind,
            enforceNetworkByteLimit: false,
            allowsLargeGIFAutoplay: true
        ) { asset in
            switch asset {
            case .still:
                NoteZoomableImageView(
                    asset: asset,
                    reduceMotion: accessibilityReduceMotion,
                    onZoomStateChange: onZoomStateChange
                )
                .padding(16)
            case .gif(let payload):
                NoteAnimatedGIFView(
                    payload: payload,
                    contentMode: .scaleAspectFit
                )
                .padding(16)
                .onAppear {
                    onZoomStateChange(false)
                }
            }
        } placeholder: {
            ProgressView()
                .tint(chromeForegroundColor)
        } failure: {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(chromeForegroundColor.opacity(0.75))
                .onAppear {
                    onZoomStateChange(false)
                }
        }
        .onDisappear {
            onZoomStateChange(false)
        }
    }
}

struct NoteRemoteMediaView<Content: View, Placeholder: View, Failure: View>: View {
    let url: URL
    let kind: FlowImageCacheRequestKind
    let enforceNetworkByteLimit: Bool
    let allowsLargeGIFAutoplay: Bool
    @ViewBuilder let content: (NoteMediaAsset) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var asset: NoteMediaAsset?
    @State private var loadedRequest: LoadRequest?
    @State private var didFailLoading = false

    private struct LoadRequest: Hashable {
        let url: URL
        let kind: FlowImageCacheRequestKind
        let enforceNetworkByteLimit: Bool
        let allowsLargeGIFAutoplay: Bool
    }

    init(
        url: URL,
        kind: FlowImageCacheRequestKind = .feedThumbnail,
        enforceNetworkByteLimit: Bool = true,
        allowsLargeGIFAutoplay: Bool = true,
        @ViewBuilder content: @escaping (NoteMediaAsset) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.kind = kind
        self.enforceNetworkByteLimit = enforceNetworkByteLimit
        self.allowsLargeGIFAutoplay = allowsLargeGIFAutoplay
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        Group {
            if let asset {
                content(asset)
            } else if didFailLoading {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: loadRequest) {
            await loadIfNeeded(request: loadRequest)
        }
    }

    private var loadRequest: LoadRequest {
        LoadRequest(
            url: url,
            kind: kind,
            enforceNetworkByteLimit: enforceNetworkByteLimit,
            allowsLargeGIFAutoplay: allowsLargeGIFAutoplay
        )
    }

    @MainActor
    private func loadIfNeeded(request: LoadRequest) async {
        if loadedRequest != request {
            loadedRequest = request
            asset = nil
            didFailLoading = false
        }

        guard asset == nil, !didFailLoading else { return }

        if let loadedAsset = await NoteMediaAssetLoader.shared.asset(
            for: request.url,
            kind: request.kind,
            enforceNetworkByteLimit: request.enforceNetworkByteLimit,
            allowsLargeGIFAutoplay: request.allowsLargeGIFAutoplay
        ) {
            asset = loadedAsset
            didFailLoading = false
        } else {
            didFailLoading = true
        }
    }
}

private struct NoteZoomableImageView: UIViewRepresentable {
    let asset: NoteMediaAsset
    let reduceMotion: Bool
    let onZoomStateChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            reduceMotion: reduceMotion,
            onZoomStateChange: onZoomStateChange
        )
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = LayoutAwareZoomScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = context.coordinator.imageView
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = false
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.doubleTapRecognizer = doubleTap
        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.handleLayout(in: scrollView)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.onZoomStateChange = onZoomStateChange
        context.coordinator.updateAsset(asset, in: scrollView)
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.onZoomStateChange(false)
        coordinator.imageView.stopAnimating()
        coordinator.imageView.image = nil
        coordinator.scrollView = nil
        coordinator.doubleTapRecognizer = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        var reduceMotion: Bool
        var onZoomStateChange: (Bool) -> Void

        private var currentAsset: NoteMediaAsset?
        private var currentAssetIdentifier: ObjectIdentifier?
        private var lastReportedZoomedState = false
        private var lastBoundsSize: CGSize = .zero

        init(
            reduceMotion: Bool,
            onZoomStateChange: @escaping (Bool) -> Void
        ) {
            self.reduceMotion = reduceMotion
            self.onZoomStateChange = onZoomStateChange
        }

        func updateAsset(_ asset: NoteMediaAsset, in scrollView: UIScrollView) {
            self.scrollView = scrollView
            currentAsset = asset

            applyLayout(for: asset, in: scrollView)
        }

        func handleLayout(in scrollView: UIScrollView) {
            guard let currentAsset else { return }
            applyLayout(for: currentAsset, in: scrollView)
        }

        private func applyLayout(for asset: NoteMediaAsset, in scrollView: UIScrollView) {
            let assetIdentifier = Self.assetIdentifier(for: asset)
            let boundsSize = scrollView.bounds.size
            let assetChanged = currentAssetIdentifier != assetIdentifier
            if assetChanged {
                currentAssetIdentifier = assetIdentifier
                configureImageView(for: asset)
                scrollView.zoomScale = 1
                reportZoomState(false)
            }

            guard boundsSize.width > 0, boundsSize.height > 0 else { return }

            if assetChanged ||
                lastBoundsSize != boundsSize ||
                scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 {
                imageView.frame = scrollView.bounds
                scrollView.contentSize = scrollView.bounds.size
                lastBoundsSize = boundsSize
            }

            centerImage(in: scrollView)
            updatePanGestureState(for: scrollView)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
            updatePanGestureState(for: scrollView)
            reportZoomState(scrollView.zoomScale > scrollView.minimumZoomScale + 0.01)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportZoomState(scale > scrollView.minimumZoomScale + 0.01)
        }

        @objc
        func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(
                    scrollView.minimumZoomScale,
                    animated: !reduceMotion
                )
                return
            }

            let tapPoint = gesture.location(in: imageView)
            let targetScale = min(scrollView.maximumZoomScale, 2.5)
            let zoomRect = zoomRect(
                for: targetScale,
                centeredAt: tapPoint,
                in: scrollView
            )
            scrollView.zoom(to: zoomRect, animated: !reduceMotion)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func configureImageView(for asset: NoteMediaAsset) {
            imageView.stopAnimating()
            imageView.image = nil

            switch asset {
            case .still(let image):
                imageView.image = image
            case .gif(let payload):
                imageView.image = payload.previewImage
            }
        }

        private func centerImage(in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frameToCenter = imageView.frame

            frameToCenter.origin.x = frameToCenter.size.width < boundsSize.width
                ? (boundsSize.width - frameToCenter.size.width) / 2
                : 0
            frameToCenter.origin.y = frameToCenter.size.height < boundsSize.height
                ? (boundsSize.height - frameToCenter.size.height) / 2
                : 0

            imageView.frame = frameToCenter
        }

        private func updatePanGestureState(for scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        }

        private func reportZoomState(_ isZoomed: Bool) {
            guard lastReportedZoomedState != isZoomed else { return }
            lastReportedZoomedState = isZoomed
            onZoomStateChange(isZoomed)
        }

        private func zoomRect(for scale: CGFloat, centeredAt center: CGPoint, in scrollView: UIScrollView) -> CGRect {
            let bounds = scrollView.bounds
            let width = bounds.width / scale
            let height = bounds.height / scale
            return CGRect(
                x: center.x - (width / 2),
                y: center.y - (height / 2),
                width: width,
                height: height
            )
        }

        private static func assetIdentifier(for asset: NoteMediaAsset) -> ObjectIdentifier {
            switch asset {
            case .still(let image):
                return ObjectIdentifier(image)
            case .gif(let payload):
                return ObjectIdentifier(payload.previewImage)
            }
        }
    }
}

private final class LayoutAwareZoomScrollView: UIScrollView {
    var onLayout: ((UIScrollView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

struct NoteGIFPayload {
    let url: URL
    let data: Data
    let previewImage: UIImage
    let frameDurations: [TimeInterval]

    var frameCount: Int {
        frameDurations.count
    }

    var size: CGSize {
        previewImage.size
    }

    static func make(from data: Data, url: URL, maxPixelSize: CGFloat = 2_048) -> NoteGIFPayload? {
        guard data.starts(with: [0x47, 0x49, 0x46]),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return nil }

        let previewOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixelSize.rounded()), 1)
        ]

        guard let previewCGImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            previewOptions as CFDictionary
        ) ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let previewImage = UIImage(cgImage: previewCGImage)
        let frameDurations = (0..<frameCount).map {
            Self.frameDuration(forFrameAt: $0, source: source)
        }

        return NoteGIFPayload(
            url: url,
            data: data,
            previewImage: previewImage,
            frameDurations: frameDurations
        )
    }

    private static func frameDuration(forFrameAt index: Int, source: CGImageSource) -> TimeInterval {
        let defaultDelay = 0.1
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return defaultDelay
        }

        let unclampedDelay = (gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let delay = (gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let frameDelay = unclampedDelay ?? delay ?? defaultDelay
        return frameDelay < 0.02 ? defaultDelay : frameDelay
    }
}

private struct NoteAnimatedGIFView: UIViewRepresentable {
    let payload: NoteGIFPayload
    let contentMode: UIView.ContentMode

    func makeUIView(context: Context) -> GIFPlayerImageView {
        let imageView = GIFPlayerImageView(frame: .zero)
        imageView.backgroundColor = UIColor.clear
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        return imageView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GIFPlayerImageView, context: Context) -> CGSize? {
        let aspectRatio = max(payload.size.width / max(payload.size.height, 1), 0.01)

        if let width = proposal.width, let height = proposal.height {
            return CGSize(width: width, height: height)
        }

        if let width = proposal.width {
            return CGSize(width: width, height: width / aspectRatio)
        }

        if let height = proposal.height {
            return CGSize(width: height * aspectRatio, height: height)
        }

        return payload.size
    }

    func updateUIView(_ imageView: GIFPlayerImageView, context: Context) {
        imageView.contentMode = contentMode
        imageView.configure(with: payload)
    }

    static func dismantleUIView(_ imageView: GIFPlayerImageView, coordinator: ()) {
        imageView.stopAnimatingGIF()
        imageView.image = nil
    }
}

private final class GIFPlayerImageView: UIImageView {
    private var payload: NoteGIFPayload?
    private var source: CGImageSource?
    private var displayLink: CADisplayLink?
    private let frameCache = NSCache<NSNumber, UIImage>()
    private var currentFrameIndex = 0
    private var accumulatedTime: TimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    private var maxPixelSize: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        frameCache.countLimit = 24
        frameCache.totalCostLimit = 24 * 1_024 * 1_024
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        frameCache.countLimit = 24
        frameCache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func configure(with payload: NoteGIFPayload) {
        if self.payload?.url != payload.url || self.payload?.data != payload.data {
            self.payload = payload
            source = CGImageSourceCreateWithData(payload.data as CFData, nil)
            currentFrameIndex = 0
            accumulatedTime = 0
            lastTimestamp = nil
            frameCache.removeAllObjects()
            image = payload.previewImage
        } else if image == nil {
            image = payload.previewImage
        }

        updateFrameDecodingScaleIfNeeded()
        restartIfNeeded()
    }

    override var intrinsicContentSize: CGSize {
        .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFrameDecodingScaleIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartIfNeeded()
    }

    func stopAnimatingGIF() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        accumulatedTime = 0
    }

    private func restartIfNeeded() {
        guard window != nil,
              let payload,
              payload.frameCount > 1 else {
            stopAnimatingGIF()
            return
        }

        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func updateFrameDecodingScaleIfNeeded() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let candidate = max(bounds.width, bounds.height) * scale
        let resolved = max(1, min(candidate, 2_048))
        guard abs(resolved - maxPixelSize) > 1 else { return }
        maxPixelSize = resolved
        frameCache.removeAllObjects()
        if let payload {
            image = payload.previewImage
        }
    }

    @objc
    private func step(_ displayLink: CADisplayLink) {
        guard let payload,
              payload.frameCount > 1 else {
            stopAnimatingGIF()
            return
        }

        if lastTimestamp == nil {
            lastTimestamp = displayLink.timestamp
            return
        }

        let elapsed = displayLink.timestamp - (lastTimestamp ?? displayLink.timestamp)
        lastTimestamp = displayLink.timestamp
        accumulatedTime += elapsed

        let frameDuration = payload.frameDurations[currentFrameIndex]
        guard accumulatedTime >= frameDuration else { return }

        accumulatedTime.formTruncatingRemainder(dividingBy: frameDuration)
        currentFrameIndex = (currentFrameIndex + 1) % payload.frameCount
        image = decodedFrame(at: currentFrameIndex) ?? payload.previewImage
    }

    private func decodedFrame(at index: Int) -> UIImage? {
        let key = NSNumber(value: index)
        if let cached = frameCache.object(forKey: key) {
            return cached
        }

        guard let source,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                index,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
                ] as CFDictionary
              ) ?? CGImageSourceCreateImageAtIndex(source, index, nil) else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        frameCache.setObject(image, forKey: key, cost: Self.imageMemoryCost(for: image))
        return image
    }

    private static func imageMemoryCost(for image: UIImage) -> Int {
        let scale = image.scale
        let width = Int(image.size.width * scale)
        let height = Int(image.size.height * scale)
        guard width > 0, height > 0 else { return 1 }
        return width * height * 4
    }
}

private actor NoteMediaAssetLoader {
    static let shared = NoteMediaAssetLoader()

    func asset(
        for url: URL,
        kind: FlowImageCacheRequestKind = .feedThumbnail,
        enforceNetworkByteLimit: Bool = true,
        allowsLargeGIFAutoplay: Bool = true
    ) async -> NoteMediaAsset? {
        if isLikelyGIF(url),
           let data = await FlowImageCache.shared.data(
               for: url,
               kind: kind,
               enforceNetworkByteLimit: enforceNetworkByteLimit
           ),
           let payload = NoteGIFPayload.make(
               from: data,
               url: url,
               maxPixelSize: kind.decodeMaxPixelSize
           ) {
            guard allowsLargeGIFAutoplay || data.count <= FlowImageCacheRequestKind.largeGIFAutoplayByteLimit else {
                return .still(payload.previewImage)
            }
            return .gif(payload)
        }

        guard let image = await FlowImageCache.shared.image(
            for: url,
            kind: kind,
            enforceNetworkByteLimit: enforceNetworkByteLimit
        ) else {
            return nil
        }
        return .still(image)
    }

    private func isLikelyGIF(_ url: URL) -> Bool {
        url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gif"
    }
}
