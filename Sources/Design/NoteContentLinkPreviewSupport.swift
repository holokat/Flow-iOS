import LinkPresentation
import SwiftUI
import WebKit

struct WebsiteLinkCardView: View {
    private static let cornerRadius: CGFloat = 14
    private static let horizontalImageAspectRatio: CGFloat = 16.0 / 9.0
    private static let maximumFeedColumnWidth: CGFloat = 360
    private static let maximumDetailColumnWidth: CGFloat = 620
    private static let compactFeedChromeAllowance: CGFloat = 118
    private static let detailChromeAllowance: CGFloat = 48

    @EnvironmentObject private var appSettings: AppSettingsStore
    let url: URL
    let backgroundColor: Color
    let borderColor: Color
    let layout: NoteContentMediaLayout
    @StateObject private var loader: LinkMetadataLoader

    init(
        url: URL,
        backgroundColor: Color,
        borderColor: Color,
        layout: NoteContentMediaLayout = .feed
    ) {
        self.url = url
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.layout = layout
        _loader = StateObject(wrappedValue: LinkMetadataLoader(url: url))
    }

    var body: some View {
        WebsiteLinkCardWidthLayout(
            maximumWidth: maximumCardWidth,
            fallbackWidth: fallbackCardWidth
        ) {
            Link(destination: url) {
                cardContent
            }
            .buttonStyle(.plain)
        }
        .task(id: url) {
            await loader.startIfNeeded()
        }
        .onDisappear {
            loader.cancelPendingLoad()
        }
        .frame(maxWidth: maximumCardWidth, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private var cardContent: some View {
        if shouldUseLargeImagePreview {
            VStack(alignment: .leading, spacing: 0) {
                previewImageSlot

                metadataBlock
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
            }
            .frame(maxWidth: boundedCardWidth, alignment: .leading)
            .background(backgroundColor)
            .clipShape(cardShape)
            .overlay(cardShape.stroke(borderColor, lineWidth: 0.7))
        } else {
            compactMetadataBlock
                .padding(12)
                .frame(maxWidth: boundedCardWidth, alignment: .leading)
                .background(backgroundColor)
                .clipShape(cardShape)
                .overlay(cardShape.stroke(borderColor, lineWidth: 0.7))
        }
    }

    @ViewBuilder
    private var previewImageSlot: some View {
        ZStack {
            placeholderImage

            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(maxWidth: boundedCardWidth)
        .aspectRatio(Self.horizontalImageAspectRatio, contentMode: .fit)
        .clipped()
        .accessibilityHidden(true)
    }

    private var compactMetadataBlock: some View {
        HStack(alignment: .center, spacing: 10) {
            if loader.imageKind == .icon, let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.7)
                    }
                    .accessibilityHidden(true)
            }

            metadataBlock
                .layoutPriority(1)
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sourceRow

            Text(FlowLayoutGuardrails.softWrapped(displayTitle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .redacted(reason: loader.hasResolvedMetadata ? [] : .placeholder)
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "link")
                .font(.caption2.weight(.bold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .frame(width: 18, height: 18)
                .background(appSettings.themePalette.secondaryFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(FlowLayoutGuardrails.softWrapped(sourceDisplay, maxNonBreakingRunLength: 18))
                .font(.caption)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .lineLimit(1)
                .redacted(reason: loader.hasResolvedMetadata ? [] : .placeholder)

            Spacer(minLength: 0)
        }
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

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    private var shouldUseLargeImagePreview: Bool {
        loader.imageKind == .hero || loader.isLoadingHeroImage || !loader.hasResolvedMetadata
    }

    private var boundedCardWidth: CGFloat {
        min(fallbackCardWidth, maximumCardWidth)
    }

    private var maximumCardWidth: CGFloat {
        layout == .feed ? Self.maximumFeedColumnWidth : Self.maximumDetailColumnWidth
    }

    private var fallbackCardWidth: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        let chromeAllowance = layout == .feed ? Self.compactFeedChromeAllowance : Self.detailChromeAllowance

        guard screenWidth.isFinite, screenWidth > chromeAllowance else {
            return maximumCardWidth
        }

        return screenWidth - chromeAllowance
    }

    private var displayTitle: String {
        loader.title ?? fallbackTitle
    }

    private var sourceDisplay: String {
        if let siteName = loader.siteName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !siteName.isEmpty {
            return siteName
        }
        let host = loader.hostDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? displayURL : host
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

private struct WebsiteLinkCardWidthLayout: Layout {
    let maximumWidth: CGFloat
    let fallbackWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = resolvedWidth(for: proposal.width)
        let size = subview.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )
        return CGSize(width: min(max(size.width, 0), width), height: max(size.height, 0))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let width = min(max(bounds.width, 1), resolvedWidth(for: bounds.width))

        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }

    private func resolvedWidth(for proposedWidth: CGFloat?) -> CGFloat {
        min(
            FlowLayoutGuardrails.boundedFiniteWidth(
                proposedWidth,
                fallbackWidth: fallbackWidth
            ),
            maximumWidth
        )
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
                borderColor: appSettings.themePalette.linkPreviewBorder,
                layout: layout
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
    static func decision(
        for navigationURL: URL?,
        embedURL: URL,
        isNewWindow: Bool,
        isUserInitiated: Bool = true,
        wrapperBaseURL: URL? = nil
    ) -> YouTubeEmbedNavigationDecision {
        guard let navigationURL else { return .cancel }

        guard let scheme = navigationURL.scheme?.lowercased() else {
            return .cancel
        }

        if scheme == "about" {
            return .allowInWebView
        }

        if isWrapperNavigation(navigationURL, wrapperBaseURL: wrapperBaseURL) {
            return isNewWindow ? .cancel : .allowInWebView
        }

        if scheme != "http" && scheme != "https" {
            return isUserInitiated || isNewWindow ? .openExternally(navigationURL) : .cancel
        }

        if isEmbedNavigation(navigationURL, embedURL: embedURL) {
            return .allowInWebView
        }

        if isNewWindow {
            return .openExternally(navigationURL)
        }

        guard isUserInitiated else { return .cancel }

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

    private static func isWrapperNavigation(_ navigationURL: URL, wrapperBaseURL: URL?) -> Bool {
        guard let wrapperBaseURL else { return false }
        let navigationComponents = URLComponents(url: navigationURL, resolvingAgainstBaseURL: false)
        let wrapperComponents = URLComponents(url: wrapperBaseURL, resolvingAgainstBaseURL: false)
        guard navigationComponents?.scheme?.lowercased() == wrapperComponents?.scheme?.lowercased(),
              navigationComponents?.host?.lowercased() == wrapperComponents?.host?.lowercased() else {
            return false
        }

        let navigationPath = navigationComponents?.path ?? ""
        let wrapperPath = wrapperComponents?.path ?? ""
        return navigationPath == wrapperPath || navigationPath == "/" && wrapperPath.isEmpty
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
                isNewWindow: navigationAction.targetFrame == nil,
                isUserInitiated: navigationAction.navigationType == .linkActivated,
                wrapperBaseURL: YouTubeEmbedWebView.refererBaseURL
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
                isNewWindow: true,
                isUserInitiated: navigationAction.navigationType == .linkActivated,
                wrapperBaseURL: YouTubeEmbedWebView.refererBaseURL
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

    fileprivate static var refererBaseURL: URL? {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.21media.haloapp"
        let safeIdentifier = bundleIdentifier
            .lowercased()
            .filter { character in
                character.isLetter || character.isNumber || character == "." || character == "-"
            }
        return URL(string: "https://\(safeIdentifier.isEmpty ? "com.21media.haloapp" : safeIdentifier)")
    }
}

struct WebsitePreviewHTMLMetadata: Equatable, Sendable {
    let title: String?
    let siteName: String?
    let summary: String?
    let imageURL: URL?
    let iconURL: URL?
    let resolvedURL: URL?

    var hasUsefulContent: Bool {
        title != nil || siteName != nil || summary != nil || imageURL != nil || iconURL != nil
    }
}

enum WebsitePreviewHTMLParser {
    private static let maximumHTMLByteCount = 1_048_576
    private static let maximumTitleLength = 300
    private static let maximumSummaryLength = 1_000
    private static let maximumSiteNameLength = 120
    private static let maximumURLLength = 4_096

    static func parse(data: Data, responseURL: URL) -> WebsitePreviewHTMLMetadata? {
        let boundedData = data.prefix(maximumHTMLByteCount)
        return parse(
            html: String(decoding: boundedData, as: UTF8.self),
            responseURL: responseURL
        )
    }

    static func parse(html: String, responseURL: URL) -> WebsitePreviewHTMLMetadata? {
        let headHTML: String
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            headHTML = String(html[..<headEnd.upperBound])
        } else {
            headHTML = String(html.prefix(maximumHTMLByteCount))
        }

        var metadataValues: [String: String] = [:]
        for tag in tags(named: "meta", in: headHTML) {
            let attributes = attributes(in: tag)
            guard let rawKey = attributes["property"] ?? attributes["name"] else { continue }
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty,
                  metadataValues[key] == nil,
                  let content = attributes["content"],
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            metadataValues[key] = content
        }

        var iconURL: URL?
        var canonicalURL: URL?
        for tag in tags(named: "link", in: headHTML) {
            let attributes = attributes(in: tag)
            let relationships = Set(
                (attributes["rel"] ?? "")
                    .lowercased()
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
            )
            guard let href = attributes["href"] else { continue }

            if canonicalURL == nil, relationships.contains("canonical") {
                canonicalURL = resolvedWebURL(href, relativeTo: responseURL)
            }
            if iconURL == nil,
               relationships.contains("icon") || relationships.contains("apple-touch-icon") {
                iconURL = resolvedWebURL(href, relativeTo: responseURL)
            }
        }

        let title = firstNormalizedValue(
            keys: ["og:title", "twitter:title", "title"],
            values: metadataValues,
            maximumLength: maximumTitleLength
        ) ?? titleElement(in: headHTML)
        let siteName = firstNormalizedValue(
            keys: ["og:site_name", "application-name"],
            values: metadataValues,
            maximumLength: maximumSiteNameLength
        )
        let summary = firstNormalizedValue(
            keys: ["og:description", "twitter:description", "description"],
            values: metadataValues,
            maximumLength: maximumSummaryLength
        )
        let imageURL = firstResolvedURL(
            keys: [
                "og:image:secure_url",
                "og:image:url",
                "og:image",
                "twitter:image",
                "twitter:image:src"
            ],
            values: metadataValues,
            relativeTo: responseURL
        )
        let resolvedURL = firstResolvedURL(
            keys: ["og:url"],
            values: metadataValues,
            relativeTo: responseURL
        ) ?? canonicalURL ?? responseURL

        let metadata = WebsitePreviewHTMLMetadata(
            title: title,
            siteName: siteName,
            summary: summary,
            imageURL: imageURL,
            iconURL: iconURL,
            resolvedURL: resolvedURL
        )
        return metadata.hasUsefulContent ? metadata : nil
    }

    private static func tags(named name: String, in html: String) -> [String] {
        let pattern = "<\(name)\\b[^>]*>"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            return String(html[tagRange])
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return [:]
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            for captureIndex in 2...4 {
                guard match.range(at: captureIndex).location != NSNotFound,
                      let valueRange = Range(match.range(at: captureIndex), in: tag) else {
                    continue
                }
                result[name] = String(tag[valueRange])
                break
            }
        }
        return result
    }

    private static func titleElement(in html: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"<title\b[^>]*>(.*?)</title>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: range),
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return normalizedText(String(html[titleRange]), maximumLength: maximumTitleLength)
    }

    private static func firstNormalizedValue(
        keys: [String],
        values: [String: String],
        maximumLength: Int
    ) -> String? {
        for key in keys {
            if let value = values[key],
               let normalized = normalizedText(value, maximumLength: maximumLength) {
                return normalized
            }
        }
        return nil
    }

    private static func firstResolvedURL(
        keys: [String],
        values: [String: String],
        relativeTo baseURL: URL
    ) -> URL? {
        for key in keys {
            if let value = values[key],
               let url = resolvedWebURL(value, relativeTo: baseURL) {
                return url
            }
        }
        return nil
    }

    private static func resolvedWebURL(_ rawValue: String, relativeTo baseURL: URL) -> URL? {
        let decoded = decodeHTMLEntities(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty, decoded.count <= maximumURLLength,
              let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              FlowURLSafety.isPubliclyLoadableWebURL(url) else {
            return nil
        }
        return url
    }

    private static func normalizedText(_ rawValue: String, maximumLength: Int) -> String? {
        let withoutTags = rawValue.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let decoded = decodeHTMLEntities(withoutTags)
        let normalized = decoded
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumLength))
    }

    private static func decodeHTMLEntities(_ rawValue: String) -> String {
        var decoded = rawValue
        for (entity, replacement) in [
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&amp;", "&")
        ] {
            decoded = decoded.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }

        guard let expression = try? NSRegularExpression(
            pattern: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#,
            options: [.caseInsensitive]
        ) else {
            return decoded
        }

        let mutable = NSMutableString(string: decoded)
        let matches = expression.matches(
            in: decoded,
            range: NSRange(location: 0, length: mutable.length)
        )
        for match in matches.reversed() {
            guard let valueRange = Range(match.range(at: 1), in: decoded) else { continue }
            let rawNumber = String(decoded[valueRange])
            let isHex = rawNumber.lowercased().hasPrefix("x")
            let digits = isHex ? String(rawNumber.dropFirst()) : rawNumber
            guard let scalarValue = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }
            mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
        }
        return mutable as String
    }
}

private actor WebsitePreviewHTMLMetadataService {
    static let shared = WebsitePreviewHTMLMetadataService()

    private let session: URLSession
    private let maximumResponseByteCount = 1_048_576
    private let maximumCacheEntries = 160
    private var cachedMetadata: [URL: WebsitePreviewHTMLMetadata] = [:]
    private var cacheOrder: [URL] = []
    private var inFlight: [URL: Task<WebsitePreviewHTMLMetadata?, Never>] = [:]

    init(session: URLSession = WebsitePreviewHTMLMetadataService.makeSession()) {
        self.session = session
    }

    func metadata(for url: URL) async -> WebsitePreviewHTMLMetadata? {
        guard FlowURLSafety.isPubliclyLoadableWebURL(url) else { return nil }
        if let cached = cachedMetadata[url] {
            return cached
        }
        if let existingTask = inFlight[url] {
            return await existingTask.value
        }

        let session = self.session
        let maximumResponseByteCount = self.maximumResponseByteCount
        let task = Task {
            await Self.fetchMetadata(
                for: url,
                session: session,
                maximumResponseByteCount: maximumResponseByteCount
            )
        }
        inFlight[url] = task
        let metadata = await task.value
        inFlight[url] = nil

        if let metadata {
            cachedMetadata[url] = metadata
            cacheOrder.removeAll { $0 == url }
            cacheOrder.append(url)
            while cacheOrder.count > maximumCacheEntries {
                cachedMetadata.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        return metadata
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    private static func fetchMetadata(
        for url: URL,
        session: URLSession,
        maximumResponseByteCount: Int
    ) async -> WebsitePreviewHTMLMetadata? {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
        )
        request.setValue(
            "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("bytes=0-\(maximumResponseByteCount - 1)", forHTTPHeaderField: "Range")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let responseURL = response.url,
                  FlowURLSafety.isPubliclyLoadableWebURL(responseURL),
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode) else {
                return nil
            }

            if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               !contentType.contains("text/html"),
               !contentType.contains("application/xhtml+xml") {
                return nil
            }

            var data = Data()
            data.reserveCapacity(min(maximumResponseByteCount, 128 * 1_024))
            for try await byte in bytes {
                guard data.count < maximumResponseByteCount else { break }
                data.append(byte)
            }
            guard !data.isEmpty else { return nil }
            return WebsitePreviewHTMLParser.parse(data: data, responseURL: responseURL)
        } catch {
            return nil
        }
    }
}

private actor LinkPreviewLoadCoordinator {
    static let shared = LinkPreviewLoadCoordinator()

    private let maxConcurrentLoads = 4
    private var activeLoads = 0

    func beginLoad() -> Bool {
        guard activeLoads < maxConcurrentLoads else {
            return false
        }
        activeLoads += 1
        return true
    }

    func finishLoad() {
        activeLoads = max(0, activeLoads - 1)
    }
}

private enum WebsitePreviewImageKind: Equatable, Sendable {
    case hero
    case icon
}

private final class CachedWebsitePreviewImage: NSObject {
    let image: UIImage
    let kind: WebsitePreviewImageKind

    init(image: UIImage, kind: WebsitePreviewImageKind) {
        self.image = image
        self.kind = kind
    }
}

@MainActor
private final class LinkMetadataLoader: ObservableObject {
    @Published var title: String?
    @Published var summary: String?
    @Published var siteName: String?
    @Published var image: UIImage?
    @Published private(set) var hasResolvedMetadata = false
    @Published private(set) var isLoadingHeroImage = false
    @Published private(set) var imageKind: WebsitePreviewImageKind?

    let hostDisplay: String
    private let url: URL
    private var metadataProvider: LPMetadataProvider?
    private var isLoading = false
    private static let metadataProviderTimeout: TimeInterval = 30
    private static let imageLoadTimeoutNanoseconds: UInt64 = 10_000_000_000

    private static let metadataCache: NSCache<NSURL, LPLinkMetadata> = {
        let cache = NSCache<NSURL, LPLinkMetadata>()
        cache.countLimit = 96
        return cache
    }()

    private static let imageCache: NSCache<NSURL, CachedWebsitePreviewImage> = {
        let cache = NSCache<NSURL, CachedWebsitePreviewImage>()
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
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage.image
            imageKind = cachedImage.kind
        }
        if let cachedMetadata = Self.metadataCache.object(forKey: cacheKey) {
            apply(metadata: cachedMetadata)
            hasResolvedMetadata = true
            if image == nil {
                await loadImageIfNeeded(metadata: cachedMetadata, cacheKey: cacheKey)
            }
            return
        }

        guard !isLoading else { return }

        var didBeginLoad = await Self.coordinator.beginLoad()
        while !didBeginLoad && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            didBeginLoad = await Self.coordinator.beginLoad()
        }

        guard !Task.isCancelled else { return }
        guard didBeginLoad else { return }

        isLoading = true
        defer {
            isLoading = false
            metadataProvider = nil
            Task {
                await Self.coordinator.finishLoad()
            }
        }

        let provider = LPMetadataProvider()
        provider.timeout = Self.metadataProviderTimeout
        metadataProvider = provider
        async let appleMetadata = fetchMetadata(with: provider)

        var didResolveUsefulMetadata = false
        if let htmlMetadata = await WebsitePreviewHTMLMetadataService.shared.metadata(for: url) {
            apply(htmlMetadata: htmlMetadata)
            hasResolvedMetadata = true
            didResolveUsefulMetadata = htmlMetadata.hasUsefulContent
            await loadImageIfNeeded(htmlMetadata: htmlMetadata, cacheKey: cacheKey)

            if htmlMetadata.title != nil, image != nil {
                provider.cancel()
                _ = await appleMetadata
                return
            }
        }

        let metadata = await appleMetadata

        guard !Task.isCancelled else { return }

        if let metadata {
            Self.metadataCache.setObject(metadata, forKey: cacheKey)
            apply(metadata: metadata)
            didResolveUsefulMetadata = didResolveUsefulMetadata || metadata.title != nil || metadata.imageProvider != nil || metadata.iconProvider != nil
            if image == nil {
                await loadImageIfNeeded(metadata: metadata, cacheKey: cacheKey)
            }
        }
        hasResolvedMetadata = true

        if !didResolveUsefulMetadata {
            title = nil
            summary = nil
            siteName = nil
        }
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

    private func apply(htmlMetadata: WebsitePreviewHTMLMetadata) {
        if let title = htmlMetadata.title {
            self.title = title
        }
        if let summary = htmlMetadata.summary {
            self.summary = summary
        }
        if let siteName = htmlMetadata.siteName {
            self.siteName = siteName
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
                provider.startFetchingMetadata(for: url) { metadata, _ in
                    Task { @MainActor in
                        finish(metadata)
                    }
                }
            }
        } onCancel: {
            provider.cancel()
        }
    }

    private func loadImageIfNeeded(
        htmlMetadata: WebsitePreviewHTMLMetadata,
        cacheKey: NSURL
    ) async {
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            image = cached.image
            imageKind = cached.kind
            return
        }

        if let imageURL = htmlMetadata.imageURL {
            isLoadingHeroImage = true
            let loadedImage = await FlowImageCache.shared.image(
                for: imageURL,
                kind: .feedThumbnail
            )
            isLoadingHeroImage = false
            if let loadedImage, !Task.isCancelled {
                store(image: loadedImage, kind: .hero, cacheKey: cacheKey)
                return
            }
        }

        if let iconURL = htmlMetadata.iconURL,
           let loadedIcon = await FlowImageCache.shared.image(
               for: iconURL,
               kind: .profileImage
           ),
           !Task.isCancelled {
            store(image: loadedIcon, kind: .icon, cacheKey: cacheKey)
        }
    }

    private func loadImageIfNeeded(metadata: LPLinkMetadata, cacheKey: NSURL) async {
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            image = cached.image
            imageKind = cached.kind
            return
        }

        if let provider = metadata.imageProvider,
           provider.canLoadObject(ofClass: UIImage.self) {
            isLoadingHeroImage = true
            let loadedImage = await loadImage(from: provider)
            isLoadingHeroImage = false
            if let loadedImage, !Task.isCancelled {
                store(image: loadedImage, kind: .hero, cacheKey: cacheKey)
                return
            }
        }

        if let provider = metadata.iconProvider,
           provider.canLoadObject(ofClass: UIImage.self),
           let loadedIcon = await loadImage(from: provider),
           !Task.isCancelled {
            store(image: loadedIcon, kind: .icon, cacheKey: cacheKey)
        }
    }

    private func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
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
    }

    private func store(
        image: UIImage,
        kind: WebsitePreviewImageKind,
        cacheKey: NSURL
    ) {
        Self.imageCache.setObject(
            CachedWebsitePreviewImage(image: image, kind: kind),
            forKey: cacheKey,
            cost: Self.imageMemoryCost(for: image)
        )
        self.image = image
        imageKind = kind
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
