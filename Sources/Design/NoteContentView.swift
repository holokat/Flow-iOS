
import AVFoundation
import AVKit
import Combine
import ImageIO
import LinkPresentation
import NostrSDK
import SwiftUI
import UIKit


enum FlowLayoutGuardrails {
    private static let softBreakSeparators = CharacterSet(charactersIn: "/._-?&=#:%+")

    static func softWrapped(
        _ value: String,
        maxNonBreakingRunLength: Int = 24,
        minimumLength: Int = 36
    ) -> String {
        guard value.count > minimumLength else { return value }

        let softBreak = "\u{200B}"
        var wrapped = ""
        var nonBreakingRunLength = 0

        for scalar in value.unicodeScalars {
            wrapped.append(String(scalar))

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                nonBreakingRunLength = 0
                continue
            }

            if softBreakSeparators.contains(scalar) {
                wrapped.append(softBreak)
                nonBreakingRunLength = 0
                continue
            }

            nonBreakingRunLength += 1
            if nonBreakingRunLength >= maxNonBreakingRunLength {
                wrapped.append(softBreak)
                nonBreakingRunLength = 0
            }
        }

        return wrapped
    }

    static func clampedAspectRatio(
        _ value: CGFloat?,
        min minRatio: CGFloat = 0.28,
        max maxRatio: CGFloat = 3.2
    ) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Swift.min(Swift.max(value, minRatio), maxRatio)
    }

    static func aspectFitMediaSize(
        availableWidth: CGFloat?,
        aspectRatio: CGFloat?,
        maxHeight: CGFloat,
        fallbackWidth: CGFloat = UIScreen.main.bounds.width
    ) -> CGSize {
        let width = availableWidth.flatMap { value -> CGFloat? in
            guard value.isFinite, value > 0 else { return nil }
            return value
        } ?? fallbackWidth
        let ratio = clampedAspectRatio(aspectRatio) ?? 16.0 / 9.0
        let boundedMaxHeight = maxHeight.isFinite && maxHeight > 0 ? maxHeight : width / ratio
        let heightForFullWidth = width / ratio

        if heightForFullWidth <= boundedMaxHeight {
            return CGSize(width: width, height: heightForFullWidth)
        }

        return CGSize(width: boundedMaxHeight * ratio, height: boundedMaxHeight)
    }
}

enum NoteContentMediaLayout {
    case feed
    case detailCarousel
}

enum NoteContentPollPlacement {
    static func insertionOffsets(
        partCount: Int,
        insertionIndex: Int,
        includesPoll: Bool
    ) -> Set<Int> {
        guard includesPoll else { return [] }

        let normalizedPartCount = max(partCount, 0)
        let normalizedInsertionIndex = min(max(insertionIndex, 0), normalizedPartCount)
        return [normalizedInsertionIndex]
    }
}

enum NoteContentLinkResolver {
    static func linkURL(
        for token: NoteContentToken,
        allowsInAppProfileRouting: Bool
    ) -> URL? {
        switch token.type {
        case .url:
            return NoteContentParser.webURL(from: token.value)
        case .nostrMention:
            let normalized = NoteContentView.normalizeMentionIdentifier(token.value)
            if allowsInAppProfileRouting,
               let pubkey = NoteContentView.mentionedPubkey(from: normalized),
               let actionURL = NoteContentParser.profileActionURL(for: pubkey) {
                return actionURL
            }
            return NoteContentParser.njumpURL(for: normalized)
        case .hashtag:
            return NoteContentParser.hashtagActionURL(for: token.value)
        case .websocketURL:
            return RelayURLSupport.actionURL(for: token.value)
        case .text, .emoji, .nostrEvent, .image, .video, .youtubeVideo, .audio:
            return nil
        }
    }
}

enum AttributedLinkStyler {
    static func applyingLinkColor(_ color: Color, to attributedString: AttributedString) -> AttributedString {
        var styled = attributedString
        let linkedRanges = styled.runs.compactMap { run in
            run.link == nil ? nil : run.range
        }

        for range in linkedRanges {
            styled[range].foregroundColor = color
        }

        return styled
    }
}

struct NoteContentView: View {
    private enum RenderPart {
        case inlineTokens([NoteContentToken])
        case imageGallery([URL])
        case video(URL)
        case youtubeVideo(URL)
        case audio(URL)
        case nostrEventReference(String)
    }

    private struct MentionMetadataDecoder: MetadataCoding {}
    struct ParsedContent {
        let tokens: [NoteContentToken]
        let websitePreviewURL: URL?
        let mentionIdentifiers: [String]
        let emojiTagURLs: [String: URL]
    }

    private let tokens: [NoteContentToken]
    private let parts: [RenderPart]
    private let websitePreviewURL: URL?
    private let mediaAspectRatioHints: [String: CGFloat]
    private let gifLikeVideoURLKeys: Set<String>
    private let sourceEvent: NostrEvent
    private let articleMetadata: NostrLongFormArticleMetadata?
    private let articleAuthor: LongFormArticleAuthorSummary?
    private let pollEvent: NostrEvent
    private let pollMetadata: NostrPollMetadata?
    private let onHashtagTap: ((String) -> Void)?
    private let onProfileTap: ((String) -> Void)?
    private let onReferencedEventTap: ((FeedItem) -> Void)?
    private let onRelayTap: ((URL) -> Void)?
    private let trustedMediaSharerPubkey: String?
    private let mediaLayout: NoteContentMediaLayout
    private let reactionCount: Int
    private let commentCount: Int
    private let embedDepth: Int
    private let mentionIdentifiers: [String]
    private let emojiTagURLs: [String: URL]
    private let mediaRevealCacheKey: String
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @ObservedObject private var followStore = FollowStore.shared

    @State private var mentionLabels: [String: String] = [:]
    @State private var emojiImages: [String: UIImage] = [:]
    @State private var isExpanded = false
    @State private var revealsMediaInTextOnlyMode = false
    @State private var revealsBlurredMedia = false

    private static let collapsedPreviewCharacterLimit = 520
    private static let collapsedPreviewLineLimit = 9
    private static let maxEmbeddedReferenceDepth = 1
    private static let maxConcatenatedInlineTokenCount = 64
    private static let parsedContentCache = NoteParsedContentCache.shared
    private static let blurRevealStateCache = NoteBlurRevealStateCache.shared

    init(
        event: NostrEvent,
        mediaLayout: NoteContentMediaLayout = .feed,
        reactionCount: Int = 0,
        commentCount: Int = 0,
        embedDepth: Int = 0,
        trustedMediaSharerPubkey: String? = nil,
        articleAuthor: LongFormArticleAuthorSummary? = nil,
        onHashtagTap: ((String) -> Void)? = nil,
        onProfileTap: ((String) -> Void)? = nil,
        onReferencedEventTap: ((FeedItem) -> Void)? = nil,
        onRelayTap: ((URL) -> Void)? = nil
    ) {
        sourceEvent = event
        let renderEvent = Self.renderEvent(for: event)
        articleMetadata = renderEvent.longFormArticleMetadata
        self.articleAuthor = articleAuthor
        pollEvent = renderEvent
        pollMetadata = renderEvent.pollMetadata
        let parsedContent = Self.parsedContentCache.parsedContent(for: event) {
            let parsedTokens = NoteContentParser.tokenize(event: renderEvent)
            return ParsedContent(
                tokens: parsedTokens,
                websitePreviewURL: NoteContentParser.lastWebsiteURL(in: parsedTokens),
                mentionIdentifiers: Self.collectMentionIdentifiers(tokens: parsedTokens),
                emojiTagURLs: Self.parseEmojiTagURLs(from: renderEvent.tags)
            )
        }

        tokens = parsedContent.tokens
        parts = Self.buildRenderParts(tokens: parsedContent.tokens)
        mentionIdentifiers = parsedContent.mentionIdentifiers
        emojiTagURLs = parsedContent.emojiTagURLs
        websitePreviewURL = parsedContent.websitePreviewURL
        mediaAspectRatioHints = NoteImageLayoutGuide.mediaAspectRatioHints(from: renderEvent.tags)
        gifLikeVideoURLKeys = Self.gifLikeVideoURLKeys(from: renderEvent.tags)
        mediaRevealCacheKey = event.id.lowercased()
        self.onHashtagTap = onHashtagTap
        self.onProfileTap = onProfileTap
        self.onReferencedEventTap = onReferencedEventTap
        self.onRelayTap = onRelayTap
        self.trustedMediaSharerPubkey = trustedMediaSharerPubkey
        self.mediaLayout = mediaLayout
        self.reactionCount = reactionCount
        self.commentCount = commentCount
        self.embedDepth = embedDepth
        _revealsBlurredMedia = State(
            initialValue: Self.blurRevealStateCache.isRevealed(for: event.id.lowercased())
        )
    }

    var body: some View {
        Group {
            if let articleMetadata {
                LongFormArticlePreviewView(
                    article: articleMetadata,
                    author: articleAuthor ?? .fallback(pubkey: pollEvent.pubkey)
                )
            } else {
                let pollInsertionOffsets = NoteContentPollPlacement.insertionOffsets(
                    partCount: renderedParts.count,
                    insertionIndex: pollInsertionIndex,
                    includesPoll: pollMetadata != nil
                )

                VStack(alignment: .leading, spacing: 10) {
                    if let pollMetadata, pollInsertionOffsets.contains(0) {
                        pollCard(for: pollMetadata)
                    }

                    ForEach(Array(renderedParts.enumerated()), id: \.offset) { index, part in
                        switch part {
                        case .inlineTokens(let inlineTokens):
                            if mediaLayout == .detailCarousel {
                                inlineText(from: inlineTokens)
                                    .font(appSettings.appFont(.body))
                                    .lineLimit(isCollapsedPreviewActive ? Self.collapsedPreviewLineLimit : nil)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(1)
                                    .textSelection(.enabled)
                            } else {
                                inlineText(from: inlineTokens)
                                    .font(appSettings.appFont(.body))
                                    .lineLimit(isCollapsedPreviewActive ? Self.collapsedPreviewLineLimit : nil)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(1)
                                    .textSelection(.disabled)
                            }
                        case .imageGallery(let imageURLs):
                            if appSettings.textOnlyMode && !revealsMediaInTextOnlyMode {
                                NoteMediaPlaceholderView(
                                    systemImage: "photo.on.rectangle.angled",
                                    text: imageURLs.count == 1 ? "Tap to load image" : "Tap to load \(imageURLs.count) images",
                                    action: {
                                        revealsMediaInTextOnlyMode = true
                                    }
                                )
                            } else {
                                restrictedMediaView {
                                    NoteImageGalleryView(
                                        imageURLs: imageURLs,
                                        layout: mediaLayout,
                                        sourceEvent: sourceEvent,
                                        mediaAspectRatioHints: mediaAspectRatioHints,
                                        reactionCount: reactionCount,
                                        commentCount: commentCount
                                    )
                                }
                            }
                        case .video(let url):
                            if appSettings.textOnlyMode {
                                NoteMediaPlaceholderView(
                                    systemImage: "video.slash",
                                    text: "Video hidden in Text Only Mode"
                                )
                            } else {
                                restrictedMediaView {
                                    NoteVideoPlayerView(
                                        url: url,
                                        layout: mediaLayout,
                                        isGIFLike: Self.isGIFLikeVideoURL(
                                            url,
                                            in: gifLikeVideoURLKeys
                                        ),
                                        aspectRatioHint: NoteImageLayoutGuide.aspectRatioHint(
                                            for: url,
                                            in: mediaAspectRatioHints
                                        )
                                    )
                                }
                            }
                        case .youtubeVideo(let url):
                            if appSettings.textOnlyMode {
                                NoteMediaPlaceholderView(
                                    systemImage: "play.rectangle",
                                    text: "YouTube video hidden in Text Only Mode"
                                )
                            } else {
                                restrictedMediaView {
                                    YouTubeInlinePlayerView(
                                        url: url,
                                        layout: mediaLayout
                                    )
                                }
                            }
                        case .audio(let url):
                            if appSettings.textOnlyMode {
                                NoteMediaPlaceholderView(
                                    systemImage: "speaker.slash",
                                    text: "Audio hidden in Text Only Mode"
                                )
                            } else {
                                NoteAudioPlayerView(url: url)
                            }
                        case .nostrEventReference(let nostrURI):
                            if embedDepth < Self.maxEmbeddedReferenceDepth {
                                NostrEventReferenceCardView(
                                    nostrURI: nostrURI,
                                    embedDepth: embedDepth + 1,
                                    onHashtagTap: onHashtagTap,
                                    onProfileTap: onProfileTap,
                                    onOpenThread: onReferencedEventTap,
                                    onRelayTap: onRelayTap
                                )
                            } else {
                                NostrEventReferenceFallbackView(
                                    nostrURI: nostrURI,
                                    onOpenThread: onReferencedEventTap
                                )
                            }
                        }

                        if let pollMetadata, pollInsertionOffsets.contains(index + 1) {
                            pollCard(for: pollMetadata)
                        }
                    }

                    if !isCollapsedPreviewActive, let websitePreviewURL, !appSettings.textOnlyMode {
                        WebsiteLinkCardView(
                            url: websitePreviewURL,
                            backgroundColor: appSettings.themePalette.linkPreviewBackground,
                            borderColor: appSettings.themePalette.linkPreviewBorder
                        )
                    }

                    if isCollapsedPreviewActive {
                        collapseMoreOverlay
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let pubkey = NoteContentParser.profilePubkey(fromActionURL: url),
               let onProfileTap {
                onProfileTap(pubkey)
                return .handled
            }
            if let hashtag = NoteContentParser.hashtagFromActionURL(url) {
                onHashtagTap?(hashtag)
                return .handled
            }
            if let relayURL = RelayURLSupport.relayURL(fromActionURL: url) {
                if let onRelayTap {
                    onRelayTap(relayURL)
                }
                return .handled
            }
            return .systemAction(url)
        })
        .task {
            async let mentionsTask: Void = resolveMentionLabelsIfNeeded()
            async let emojiTask: Void = loadCustomEmojiImagesIfNeeded()
            _ = await (mentionsTask, emojiTask)
        }
    }

    @ViewBuilder
    private func restrictedMediaView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if shouldBlurMediaFromUnfollowedAuthors {
            NoteBlurRevealContainer(
                cornerRadius: restrictedMediaCornerRadius,
                onReveal: {
                    revealsBlurredMedia = true
                    Self.blurRevealStateCache.markRevealed(for: mediaRevealCacheKey)
                }
            ) {
                content()
            }
        } else {
            content()
        }
    }

    private var collapseMoreOverlay: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                isExpanded = true
            }
        } label: {
            Text("More")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(appSettings.themePalette.tertiaryFill))
                .overlay(Capsule().stroke(appSettings.themeSeparator(defaultOpacity: 0.3), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show full note")
        .padding(.top, 10)
    }

    private var isCollapsedPreviewActive: Bool {
        shouldCollapseLongNote && !isExpanded
    }

    private var shouldCollapseLongNote: Bool {
        inlineCharacterCount > Self.collapsedPreviewCharacterLimit
    }

    private var restrictedMediaCornerRadius: CGFloat {
        mediaLayout == .feed ? 18 : 12
    }

    private var pollInsertionIndex: Int {
        Self.pollInsertionIndex(in: renderedParts)
    }

    private var shouldBlurMediaFromUnfollowedAuthors: Bool {
        guard appSettings.blurMediaFromUnfollowedAuthors else { return false }
        guard !revealsBlurredMedia else { return false }
        guard let currentPubkey = auth.currentAccount?.pubkey else { return false }

        let authorPubkey = normalizedMediaAuthorPubkey(sourceEvent.pubkey)
        let normalizedCurrentPubkey = normalizedMediaAuthorPubkey(currentPubkey)
        guard !authorPubkey.isEmpty, authorPubkey != normalizedCurrentPubkey else { return false }
        guard !isTrustedMediaSharerFollowed(by: normalizedCurrentPubkey) else { return false }

        return !followStore.isFollowing(authorPubkey)
    }

    private func normalizedMediaAuthorPubkey(_ pubkey: String?) -> String {
        pubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func isTrustedMediaSharerFollowed(by currentPubkey: String) -> Bool {
        let sharerPubkey = normalizedMediaAuthorPubkey(trustedMediaSharerPubkey)
        guard !sharerPubkey.isEmpty, sharerPubkey != currentPubkey else { return true }
        return followStore.isFollowing(sharerPubkey)
    }

    private var inlineCharacterCount: Int {
        tokens.reduce(into: 0) { partialResult, token in
            switch token.type {
            case .image, .video, .youtubeVideo, .audio, .nostrEvent:
                break
            case .text, .url, .websocketURL, .nostrMention, .hashtag, .emoji:
                partialResult += token.value.count
            }
        }
    }

    private func pollCard(for metadata: NostrPollMetadata) -> some View {
        PollNoteView(event: pollEvent, poll: metadata)
    }

    private var renderedParts: [RenderPart] {
        guard isCollapsedPreviewActive else { return parts }
        return Self.previewParts(
            from: parts,
            maxCharacters: Self.collapsedPreviewCharacterLimit
        )
    }

    private static func previewParts(
        from parts: [RenderPart],
        maxCharacters: Int
    ) -> [RenderPart] {
        var output: [RenderPart] = []
        var remaining = maxCharacters
        var renderedAny = false
        var shouldOnlyLookForReference = false

        for part in parts {
            switch part {
            case .inlineTokens(let inlineTokens):
                guard !shouldOnlyLookForReference else { continue }
                guard remaining > 0 else {
                    shouldOnlyLookForReference = true
                    continue
                }

                let preview = previewInlineTokens(inlineTokens, remainingCharacters: remaining)
                if !preview.tokens.isEmpty {
                    output.append(.inlineTokens(preview.tokens))
                    renderedAny = true
                    remaining -= preview.charactersUsed
                }
                if preview.didTruncate {
                    shouldOnlyLookForReference = true
                }
            case .imageGallery, .video, .youtubeVideo, .audio:
                if !renderedAny {
                    output.append(part)
                    renderedAny = true
                }
                shouldOnlyLookForReference = true
            case .nostrEventReference:
                output.append(part)
                return output
            }
        }

        return output
    }

    private static func previewInlineTokens(
        _ tokens: [NoteContentToken],
        remainingCharacters: Int
    ) -> (tokens: [NoteContentToken], charactersUsed: Int, didTruncate: Bool) {
        guard remainingCharacters > 0 else {
            return ([], 0, true)
        }

        var output: [NoteContentToken] = []
        var used = 0

        for token in tokens {
            let count = token.value.count
            guard count > 0 else { continue }

            if used + count <= remainingCharacters {
                output.append(token)
                used += count
                continue
            }

            let remaining = max(remainingCharacters - used, 0)
            if remaining > 0 {
                let prefix = String(token.value.prefix(remaining))
                let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPrefix.isEmpty {
                    output.append(NoteContentToken(type: .text, value: "\(trimmedPrefix)…"))
                    used = remainingCharacters
                }
            }

            return (output, used, true)
        }

        return (output, used, false)
    }

    private static func pollInsertionIndex(in parts: [RenderPart]) -> Int {
        var index = 0

        while index < parts.count {
            guard case .inlineTokens = parts[index] else { break }
            index += 1
        }

        return index
    }

    private static func buildRenderParts(tokens: [NoteContentToken]) -> [RenderPart] {
        var parts: [RenderPart] = []
        var inlineBuffer: [NoteContentToken] = []
        var index = 0

        func flushInlineBuffer(trimTrailingWhitespace: Bool = false) {
            guard !inlineBuffer.isEmpty else { return }
            let outputTokens = trimTrailingWhitespace
                ? trimTrailingInlineWhitespace(inlineBuffer)
                : inlineBuffer
            guard !outputTokens.isEmpty else {
                inlineBuffer.removeAll(keepingCapacity: true)
                return
            }
            parts.append(.inlineTokens(outputTokens))
            inlineBuffer.removeAll(keepingCapacity: true)
        }

        while index < tokens.count {
            let token = tokens[index]

            switch token.type {
            case .image:
                flushInlineBuffer(trimTrailingWhitespace: true)
                var imageURLs: [URL] = []
                while index < tokens.count {
                    let currentToken = tokens[index]

                    if currentToken.type == .image,
                       let url = NoteContentParser.webURL(from: currentToken.value) {
                        imageURLs.append(url)
                        index += 1
                        continue
                    }

                    if currentToken.type == .text,
                       currentToken.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       index + 1 < tokens.count,
                       tokens[index + 1].type == .image {
                        index += 1
                        continue
                    }

                    break
                }
                if !imageURLs.isEmpty {
                    parts.append(.imageGallery(imageURLs))
                }
                continue
            case .video:
                flushInlineBuffer(trimTrailingWhitespace: true)
                if let url = NoteContentParser.webURL(from: token.value) {
                    parts.append(.video(url))
                }
            case .youtubeVideo:
                flushInlineBuffer(trimTrailingWhitespace: true)
                if let url = NoteContentParser.webURL(from: token.value) {
                    parts.append(.youtubeVideo(url))
                }
            case .audio:
                flushInlineBuffer(trimTrailingWhitespace: true)
                if let url = NoteContentParser.webURL(from: token.value) {
                    parts.append(.audio(url))
                }
            case .nostrEvent:
                flushInlineBuffer(trimTrailingWhitespace: true)
                parts.append(.nostrEventReference(token.value))
            case .text, .url, .websocketURL, .nostrMention, .hashtag, .emoji:
                inlineBuffer.append(token)
            }

            index += 1
        }

        flushInlineBuffer()
        return parts
    }

    private static func trimTrailingInlineWhitespace(_ tokens: [NoteContentToken]) -> [NoteContentToken] {
        guard !tokens.isEmpty else { return [] }
        var trimmed = tokens

        while let last = trimmed.last {
            guard last.type == .text else { break }

            let stripped = last.value.replacingOccurrences(
                of: "\\s+$",
                with: "",
                options: .regularExpression
            )

            if stripped.isEmpty {
                trimmed.removeLast()
                continue
            }

            if stripped != last.value {
                trimmed[trimmed.count - 1] = NoteContentToken(type: .text, value: stripped)
            }
            break
        }

        return trimmed
    }

    private func inlineText(from tokens: [NoteContentToken]) -> Text {
        if Self.shouldUseAttributedInlineText(for: tokens) {
            return Text(attributedInlineString(from: tokens))
        }

        return tokens.reduce(Text("")) { partial, token in
            partial + textSegment(for: token)
        }
    }

    static func shouldUseAttributedInlineText(for tokens: [NoteContentToken]) -> Bool {
        if tokens.count > maxConcatenatedInlineTokenCount {
            return true
        }

        return tokens.contains { token in
            switch token.type {
            case .url, .nostrMention, .hashtag, .websocketURL:
                return true
            case .text, .emoji, .nostrEvent, .image, .video, .youtubeVideo, .audio:
                return false
            }
        }
    }

    private func attributedInlineString(from tokens: [NoteContentToken]) -> AttributedString {
        let unstyled = tokens.reduce(into: AttributedString()) { partial, token in
            partial += attributedSegment(for: token)
        }
        return AttributedLinkStyler.applyingLinkColor(appSettings.linkColor, to: unstyled)
    }

    private func textSegment(for token: NoteContentToken) -> Text {
        if token.type == .emoji, let inlineEmoji = emojiInlineText(for: token.value) {
            return inlineEmoji
        }

        return Text(attributedSegment(for: token))
    }

    private func attributedSegment(for token: NoteContentToken) -> AttributedString {
        var segment = AttributedString(displayValue(for: token))

        switch token.type {
        case .url:
            if let url = NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: onProfileTap != nil
            ) {
                segment.link = url
            }
        case .nostrMention:
            if let url = NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: onProfileTap != nil
            ) {
                segment.link = url
            }
        case .hashtag:
            if let url = NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: onProfileTap != nil
            ) {
                segment.link = url
            }
        case .websocketURL:
            if onRelayTap != nil,
               let url = NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: onProfileTap != nil
            ) {
                segment.link = url
            } else {
                segment.foregroundColor = .secondary
            }
        case .text:
            break
        case .emoji:
            break
        case .nostrEvent, .image, .video, .youtubeVideo, .audio:
            break
        }

        return segment
    }

    private func displayValue(for token: NoteContentToken) -> String {
        guard token.type == .nostrMention else { return Self.softWrapValue(token.value) }

        let normalized = Self.normalizeMentionIdentifier(token.value)
        if let label = mentionLabels[normalized] {
            return Self.softWrapValue(label)
        }
        return Self.softWrapValue("@\(Self.fallbackMentionToken(for: normalized))")
    }

    private static func softWrapValue(_ value: String) -> String {
        FlowLayoutGuardrails.softWrapped(value)
    }

    private func resolveMentionLabelsIfNeeded() async {
        guard !mentionIdentifiers.isEmpty else {
            await MainActor.run {
                mentionLabels = [:]
            }
            return
        }

        var resolvedLabels: [String: String] = [:]
        var pubkeyByIdentifier: [String: String] = [:]
        var pubkeys: [String] = []

        for identifier in mentionIdentifiers {
            resolvedLabels[identifier] = "@\(Self.fallbackMentionToken(for: identifier))"

            if let pubkey = Self.mentionedPubkey(from: identifier) {
                pubkeyByIdentifier[identifier] = pubkey
                pubkeys.append(pubkey)
            }
        }

        let uniquePubkeys = Array(Set(pubkeys))
        if !uniquePubkeys.isEmpty {
            var profilesByPubkey: [String: NostrProfile] = [:]
            let cached = await ProfileCache.shared.resolve(pubkeys: uniquePubkeys)
            profilesByPubkey.merge(cached.hits, uniquingKeysWith: { _, latest in latest })

            if !cached.missing.isEmpty {
                let relayURLs = await MainActor.run {
                    let relays = RelaySettingsStore.shared.readRelayURLs
                    return relays.isEmpty
                        ? RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
                        : relays
                }

                let fetchedProfiles = await NostrFeedService().fetchProfiles(
                    relayURLs: relayURLs,
                    pubkeys: cached.missing
                )
                profilesByPubkey.merge(fetchedProfiles, uniquingKeysWith: { existing, _ in existing })
            }

            for (identifier, pubkey) in pubkeyByIdentifier {
                guard let profile = profilesByPubkey[pubkey] else { continue }
                resolvedLabels[identifier] = mentionLabel(from: profile, pubkey: pubkey)
            }
        }

        await MainActor.run {
            mentionLabels = resolvedLabels
        }
    }

    private func mentionLabel(from profile: NostrProfile, pubkey: String) -> String {
        if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "@\(name)"
        }
        if let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return "@\(displayName)"
        }
        return "@\(Self.fallbackMentionToken(for: pubkey))"
    }

    private static func collectMentionIdentifiers(tokens: [NoteContentToken]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for token in tokens where token.type == .nostrMention {
            let normalized = normalizeMentionIdentifier(token.value)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private static func parseEmojiTagURLs(from tags: [[String]]) -> [String: URL] {
        var result: [String: URL] = [:]

        for tag in tags {
            guard tag.count >= 3 else { continue }
            guard tag[0].lowercased() == "emoji" else { continue }

            let rawShortcode = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let urlString = tag[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let shortcode = normalizedEmojiShortcode(from: rawShortcode), !urlString.isEmpty else { continue }
            guard let url = URL(string: urlString), url.scheme != nil else { continue }

            result[shortcode] = url
            result[shortcode.lowercased()] = url
        }

        return result
    }

    private static func gifLikeVideoURLKeys(from tags: [[String]]) -> Set<String> {
        var keys = Set<String>()

        for tag in tags {
            guard tag.first?.lowercased() == "imeta" else { continue }

            var urlString: String?
            var mimeType: String?
            var hasGIFLoopHint = false

            for value in tag.dropFirst() {
                let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let loweredValue = normalizedValue.lowercased()

                if loweredValue.hasPrefix("url ") {
                    urlString = String(normalizedValue.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if loweredValue.hasPrefix("m ") {
                    mimeType = String(normalizedValue.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } else if loweredValue == "flow-gif-loop 1" ||
                            loweredValue == "flow-gif-loop true" ||
                            loweredValue == "flow-gif-loop yes" {
                    hasGIFLoopHint = true
                }
            }

            guard hasGIFLoopHint, let urlString, !urlString.isEmpty else { continue }
            if let mimeType, !mimeType.hasPrefix("video/") {
                continue
            }

            keys.formUnion(normalizedVideoURLKeys(for: urlString))
        }

        return keys
    }

    private static func isGIFLikeVideoURL(_ url: URL, in keys: Set<String>) -> Bool {
        !keys.isDisjoint(with: normalizedVideoURLKeys(for: url.absoluteString))
    }

    private static func normalizedVideoURLKeys(for rawValue: String) -> Set<String> {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys = Set<String>()
        keys.insert(trimmed)
        keys.insert(trimmed.lowercased())

        if var components = URLComponents(string: trimmed) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if let normalized = components.url?.absoluteString {
                keys.insert(normalized)
                keys.insert(normalized.lowercased())
            }
        }

        return keys
    }

    private func loadCustomEmojiImagesIfNeeded() async {
        guard !emojiTagURLs.isEmpty else {
            await MainActor.run {
                emojiImages = [:]
            }
            return
        }

        var nextImages = emojiImages
        for (shortcode, url) in emojiTagURLs where nextImages[shortcode] == nil {
            if let image = await CustomEmojiImageLoader.shared.image(for: url) {
                nextImages[shortcode] = image
            }
        }

        await MainActor.run {
            emojiImages = nextImages
        }
    }

    private func emojiInlineText(for tokenValue: String) -> Text? {
        guard let shortcode = Self.shortcode(from: tokenValue) else { return nil }

        let lowered = shortcode.lowercased()
        guard let baseImage = emojiImages[shortcode] ?? emojiImages[lowered] else { return nil }

        let lineHeight = appSettings.appUIFont(.body).lineHeight
        let emojiSize = max(16, floor(lineHeight * 0.95))
        let scaledImage = baseImage.preparingThumbnail(
            of: CGSize(width: emojiSize, height: emojiSize)
        ) ?? baseImage
        return Text(Image(uiImage: scaledImage).renderingMode(.original))
            .baselineOffset(-2)
    }

    private static func shortcode(from tokenValue: String) -> String? {
        normalizedEmojiShortcode(from: tokenValue)
    }

    private static func normalizedEmojiShortcode(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix(":"), trimmed.hasSuffix(":"), trimmed.count >= 3 {
            let inner = trimmed.dropFirst().dropLast()
            let shortcode = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            return shortcode.isEmpty ? nil : shortcode
        }

        return trimmed
    }

    private static func renderEvent(for event: NostrEvent) -> NostrEvent {
        // Kind 6 reposts often carry a full JSON event in `content` (NIP-18).
        // We render the embedded event body/media so users don't see raw JSON text.
        guard event.kind == 6 || event.kind == 16 else { return event }
        guard let embedded = decodeEmbeddedEvent(from: event.content) else { return event }
        guard embedded.kind != 6 && embedded.kind != 16 else { return event }
        return embedded
    }

    private static func decodeEmbeddedEvent(from content: String) -> NostrEvent? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let id = object["id"] as? String,
              let pubkey = object["pubkey"] as? String,
              let createdAt = object["created_at"] as? Int,
              let kind = object["kind"] as? Int,
              let content = object["content"] as? String,
              let sig = object["sig"] as? String else {
            return nil
        }

        let rawTags = object["tags"] as? [[Any]] ?? []
        let tags = rawTags.map { tag in
            tag.map { element in
                if let string = element as? String {
                    return string
                }
                return String(describing: element)
            }
        }

        return NostrEvent(
            id: id,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: sig
        )
    }

    fileprivate static func normalizeMentionIdentifier(_ raw: String) -> String {
        let lowered = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if lowered.hasPrefix("nostr:") {
            return String(lowered.dropFirst("nostr:".count))
        }
        return lowered
    }

    fileprivate static func mentionedPubkey(from identifier: String) -> String? {
        let normalized = normalizeMentionIdentifier(identifier)
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

    private static func fallbackMentionToken(for identifier: String) -> String {
        if let pubkey = mentionedPubkey(from: identifier) {
            return String(pubkey.prefix(8))
        }

        let normalized = normalizeMentionIdentifier(identifier)
        if normalized.count > 14 {
            return "\(normalized.prefix(10))...\(normalized.suffix(4))"
        }
        return normalized
    }
}
