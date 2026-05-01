import LinkPresentation
import SwiftUI
import WebKit

struct WebsiteLinkCardView: View {
    private static let imageSize: CGFloat = 64

    @EnvironmentObject private var appSettings: AppSettingsStore
    let url: URL
    let backgroundColor: Color
    let borderColor: Color
    @StateObject private var loader: LinkMetadataLoader

    init(url: URL, backgroundColor: Color, borderColor: Color) {
        self.url = url
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        _loader = StateObject(wrappedValue: LinkMetadataLoader(url: url))
    }

    var body: some View {
        Link(destination: url) {
            HStack(alignment: .top, spacing: 10) {
                previewImageSlot

                VStack(alignment: .leading, spacing: 4) {
                    Text(FlowLayoutGuardrails.softWrapped(displayTitle))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .redacted(reason: loader.hasResolvedMetadata ? [] : .placeholder)

                    Text(FlowLayoutGuardrails.softWrapped(displayURL, maxNonBreakingRunLength: 18))
                        .font(.caption)
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .redacted(reason: loader.hasResolvedMetadata ? [] : .placeholder)

                    Text(FlowLayoutGuardrails.softWrapped(loader.hostDisplay, maxNonBreakingRunLength: 18))
                        .font(.caption2)
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: Self.imageSize, alignment: .topLeading)

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .task(id: url) {
            await loader.startIfNeeded()
        }
        .onDisappear {
            loader.cancelPendingLoad()
        }
    }

    @ViewBuilder
    private var previewImageSlot: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderImage
            }
        }
        .frame(width: Self.imageSize, height: Self.imageSize)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(appSettings.themePalette.secondaryFill)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            appSettings.themePalette.tertiaryFill.opacity(0.9),
                            appSettings.themePalette.secondaryFill.opacity(0.65)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "photo")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }

    private var displayTitle: String {
        loader.title ?? fallbackTitle
    }

    private var displayURL: String {
        loader.summary ?? fallbackURL
    }

    private var fallbackTitle: String {
        if let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }
        return "Website preview"
    }

    private var fallbackURL: String {
        let absoluteString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !absoluteString.isEmpty else { return loader.hostDisplay }
        if absoluteString.count > 90 {
            return String(absoluteString.prefix(87)) + "..."
        }
        return absoluteString
    }
}

struct YouTubeInlinePlayerView: View {
    let url: URL
    let layout: NoteContentMediaLayout
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let embed = NoteContentParser.youtubeVideoEmbed(from: url.absoluteString),
           let embedURL = embed.embedURL() {
            YouTubeEmbedWebView(url: embedURL) { externalURL in
                openURL(externalURL)
            }
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: maxVideoHeight, alignment: .leading)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(
                    RoundedRectangle(cornerRadius: mediaCornerRadius, style: .continuous)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: mediaCornerRadius, style: .continuous)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            WebsiteLinkCardView(
                url: url,
                backgroundColor: appSettings.themePalette.linkPreviewBackground,
                borderColor: appSettings.themePalette.linkPreviewBorder
            )
        }
    }

    private var maxVideoHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.72, 620)
    }

    private var mediaCornerRadius: CGFloat {
        layout == .feed ? 18 : 12
    }
}

enum YouTubeEmbedNavigationDecision: Equatable {
    case allowInWebView
    case openExternally(URL)
    case cancel
}

enum YouTubeEmbedNavigationPolicy {
    static func decision(for navigationURL: URL?, embedURL: URL, isNewWindow: Bool) -> YouTubeEmbedNavigationDecision {
        guard let navigationURL else { return .cancel }

        if isNewWindow {
            return .openExternally(navigationURL)
        }

        guard let scheme = navigationURL.scheme?.lowercased() else {
            return .cancel
        }

        if scheme == "about" {
            return .allowInWebView
        }

        if scheme != "http" && scheme != "https" {
            return .openExternally(navigationURL)
        }

        if isEmbedNavigation(navigationURL, embedURL: embedURL) {
            return .allowInWebView
        }

        return .openExternally(navigationURL)
    }

    private static func isEmbedNavigation(_ navigationURL: URL, embedURL: URL) -> Bool {
        guard let host = navigationURL.host?.lowercased(),
              let embedHost = embedURL.host?.lowercased(),
              host == embedHost else {
            return false
        }

        if navigationURL.path == embedURL.path {
            return true
        }

        return navigationURL.path.hasPrefix("/embed/")
    }
}

private struct YouTubeEmbedWebView: UIViewRepresentable {
    let url: URL
    let openExternally: (URL) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedURL: URL?
        var embedURL: URL?
        var openExternally: ((URL) -> Void)?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let embedURL = embedURL ?? loadedURL else {
                decisionHandler(.cancel)
                return
            }
            let decision = YouTubeEmbedNavigationPolicy.decision(
                for: navigationAction.request.url,
                embedURL: embedURL,
                isNewWindow: navigationAction.targetFrame == nil
            )
            handle(decision, decisionHandler: decisionHandler)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let embedURL = embedURL ?? loadedURL else { return nil }
            let decision = YouTubeEmbedNavigationPolicy.decision(
                for: navigationAction.request.url,
                embedURL: embedURL,
                isNewWindow: true
            )
            if case .openExternally(let url) = decision {
                openExternally?(url)
            }
            return nil
        }

        private func handle(
            _ decision: YouTubeEmbedNavigationDecision,
            decisionHandler: (WKNavigationActionPolicy) -> Void
        ) {
            switch decision {
            case .allowInWebView:
                decisionHandler(.allow)
            case .openExternally(let url):
                openExternally?(url)
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.embedURL = url
        context.coordinator.openExternally = openExternally
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.loadHTMLString(Self.embedHTML(for: url), baseURL: Self.refererBaseURL)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = nil
        coordinator.embedURL = nil
        coordinator.openExternally = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private static func embedHTML(for url: URL) -> String {
        let source = htmlEscaped(url.absoluteString)
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <style>
            html, body, iframe {
              width: 100%;
              height: 100%;
              margin: 0;
              padding: 0;
              border: 0;
              overflow: hidden;
              background: #000;
            }
            iframe {
              position: fixed;
              inset: 0;
            }
          </style>
        </head>
        <body>
          <iframe
            src="\(source)"
            title="YouTube video player"
            allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            referrerpolicy="strict-origin-when-cross-origin"
            allowfullscreen>
          </iframe>
        </body>
        </html>
        """
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static var refererBaseURL: URL? {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.21media.haloapp"
        let safeIdentifier = bundleIdentifier
            .lowercased()
            .filter { character in
                character.isLetter || character.isNumber || character == "." || character == "-"
            }
        return URL(string: "https://\(safeIdentifier.isEmpty ? "com.21media.haloapp" : safeIdentifier)")
    }
}

private actor LinkPreviewLoadCoordinator {
    enum BeginDecision: Sendable, Equatable {
        case started
        case atCapacity
        case blockedByBackoff
    }

    enum Completion: Sendable, Equatable {
        case success
        case failure
        case cancelled
    }

    static let shared = LinkPreviewLoadCoordinator()

    private struct FailureEntry {
        var failureCount: Int
        var retryAfter: Date
    }

    private let maxConcurrentLoads = 2
    private let maxTrackedHosts = 256
    private var activeLoads = 0
    private var hostFailures: [String: FailureEntry] = [:]
    private var hostOrder: [String] = []

    func beginLoad(for url: URL, now: Date = Date()) -> BeginDecision {
        clearExpiredFailures(now: now)

        if let host = normalizedHost(for: url),
           let entry = hostFailures[host],
           entry.retryAfter > now {
            return .blockedByBackoff
        }

        guard activeLoads < maxConcurrentLoads else {
            return .atCapacity
        }

        activeLoads += 1
        return .started
    }

    func finishLoad(for url: URL, completion: Completion) {
        activeLoads = max(0, activeLoads - 1)

        guard let host = normalizedHost(for: url) else { return }

        switch completion {
        case .success:
            hostFailures.removeValue(forKey: host)
            hostOrder.removeAll { $0 == host }
        case .failure:
            let nextFailureCount = (hostFailures[host]?.failureCount ?? 0) + 1
            let multiplier = pow(2.0, Double(min(nextFailureCount - 1, 4)))
            let retryDelay = min(90 * multiplier, 30 * 60)
            hostFailures[host] = FailureEntry(
                failureCount: nextFailureCount,
                retryAfter: Date().addingTimeInterval(retryDelay)
            )
            hostOrder.removeAll { $0 == host }
            hostOrder.append(host)
            trimHostsIfNeeded()
        case .cancelled:
            break
        }
    }

    private func clearExpiredFailures(now: Date) {
        let expiredHosts = hostFailures.compactMap { host, entry in
            entry.retryAfter <= now ? host : nil
        }
        guard !expiredHosts.isEmpty else { return }

        let expiredSet = Set(expiredHosts)
        expiredHosts.forEach { hostFailures.removeValue(forKey: $0) }
        hostOrder.removeAll { expiredSet.contains($0) }
    }

    private func trimHostsIfNeeded() {
        while hostOrder.count > maxTrackedHosts {
            let removedHost = hostOrder.removeFirst()
            hostFailures.removeValue(forKey: removedHost)
        }
    }

    private func normalizedHost(for url: URL) -> String? {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host?.isEmpty == false ? host : nil
    }
}

@MainActor
private final class LinkMetadataLoader: ObservableObject {
    @Published var title: String?
    @Published var summary: String?
    @Published var image: UIImage?
    @Published private(set) var hasResolvedMetadata = false

    let hostDisplay: String
    private let url: URL
    private var metadataProvider: LPMetadataProvider?
    private var isLoading = false
    private static let metadataLoadTimeoutNanoseconds: UInt64 = 8_000_000_000
    private static let imageLoadTimeoutNanoseconds: UInt64 = 6_000_000_000

    private static let metadataCache: NSCache<NSURL, LPLinkMetadata> = {
        let cache = NSCache<NSURL, LPLinkMetadata>()
        cache.countLimit = 96
        return cache
    }()

    private static let imageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()

    init(url: URL) {
        self.url = url
        hostDisplay = url.host ?? url.absoluteString
    }

    func startIfNeeded() async {
        let cacheKey = url as NSURL
        if let cachedMetadata = Self.metadataCache.object(forKey: cacheKey) {
            apply(metadata: cachedMetadata)
            hasResolvedMetadata = true
            if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
                image = cachedImage
            } else {
                await loadImageIfNeeded(metadata: cachedMetadata, cacheKey: cacheKey)
            }
            return
        }

        guard !isLoading else { return }

        var decision = await Self.coordinator.beginLoad(for: url)
        while decision == .atCapacity && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            decision = await Self.coordinator.beginLoad(for: url)
        }

        guard !Task.isCancelled else { return }
        guard decision == .started else { return }

        isLoading = true
        var completion: LinkPreviewLoadCoordinator.Completion = .failure
        defer {
            isLoading = false
            metadataProvider = nil
            let url = self.url
            Task {
                await Self.coordinator.finishLoad(for: url, completion: completion)
            }
        }

        let provider = LPMetadataProvider()
        metadataProvider = provider

        guard let metadata = await fetchMetadata(with: provider) else {
            completion = Task.isCancelled ? .cancelled : .failure
            if !Task.isCancelled {
                hasResolvedMetadata = true
            }
            return
        }

        guard !Task.isCancelled else {
            completion = .cancelled
            return
        }

        Self.metadataCache.setObject(metadata, forKey: cacheKey)
        apply(metadata: metadata)
        hasResolvedMetadata = true
        completion = .success
        await loadImageIfNeeded(metadata: metadata, cacheKey: cacheKey)
    }

    private func apply(metadata: LPLinkMetadata) {
        if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            self.title = title
        }
        if let summary = metadata.url?.absoluteString,
           summary != url.absoluteString,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.summary = summary
        }
    }

    func cancelPendingLoad() {
        metadataProvider?.cancel()
    }

    private func fetchMetadata(with provider: LPMetadataProvider) async -> LPLinkMetadata? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LPLinkMetadata?, Never>) in
                var didResume = false
                func finish(_ metadata: LPLinkMetadata?) {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: metadata)
                }
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: Self.metadataLoadTimeoutNanoseconds)
                    await MainActor.run {
                        provider.cancel()
                        finish(nil)
                    }
                }
                provider.startFetchingMetadata(for: url) { metadata, _ in
                    Task { @MainActor in
                        timeoutTask.cancel()
                        finish(metadata)
                    }
                }
            }
        } onCancel: {
            provider.cancel()
        }
    }

    private func loadImageIfNeeded(metadata: LPLinkMetadata, cacheKey: NSURL) async {
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage
            return
        }
        guard let provider = metadata.imageProvider else { return }
        guard provider.canLoadObject(ofClass: UIImage.self) else { return }

        let loadedImage = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            var didResume = false
            func finish(_ image: UIImage?) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: Self.imageLoadTimeoutNanoseconds)
                await MainActor.run {
                    finish(nil)
                }
            }
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                let loadedImage = object as? UIImage
                Task { @MainActor in
                    timeoutTask.cancel()
                    finish(loadedImage)
                }
            }
        }
        guard let loadedImage, !Task.isCancelled else { return }

        Self.imageCache.setObject(
            loadedImage,
            forKey: cacheKey,
            cost: Self.imageMemoryCost(for: loadedImage)
        )
        image = loadedImage
    }

    private static let coordinator = LinkPreviewLoadCoordinator.shared

    private static func imageMemoryCost(for image: UIImage) -> Int {
        let scale = image.scale
        let width = Int(image.size.width * scale)
        let height = Int(image.size.height * scale)
        guard width > 0, height > 0 else { return 1 }
        return width * height * 4
    }
}

actor CustomEmojiImageLoader {
    static let shared = CustomEmojiImageLoader()

    func image(for url: URL) async -> UIImage? {
        await FlowImageCache.shared.image(for: url)
    }
}
