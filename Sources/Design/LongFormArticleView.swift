import NostrSDK
import SwiftUI

struct LongFormArticleAuthorSummary: Hashable, Sendable {
    let pubkey: String
    let displayName: String
    let handle: String?
    let avatarURL: URL?

    init(pubkey: String, displayName: String, handle: String?, avatarURL: URL?) {
        self.pubkey = pubkey
        self.displayName = displayName
        self.handle = handle
        self.avatarURL = avatarURL
    }

    init(item: FeedItem) {
        self.init(
            pubkey: item.displayAuthorPubkey,
            displayName: item.displayName,
            handle: item.handle,
            avatarURL: item.avatarURL
        )
    }

    static func fallback(pubkey: String) -> LongFormArticleAuthorSummary {
        let identifier = shortNostrIdentifier(pubkey)
        let displayName = identifier.isEmpty ? "Author" : identifier
        return LongFormArticleAuthorSummary(
            pubkey: pubkey,
            displayName: displayName,
            handle: identifier.isEmpty ? nil : "@\(identifier.lowercased())",
            avatarURL: nil
        )
    }
}

struct LongFormArticlePreviewView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let article: NostrLongFormArticleMetadata
    let author: LongFormArticleAuthorSummary?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            previewCardScrim

            VStack(alignment: .leading, spacing: 16) {
                previewMetadataRow

                Spacer(minLength: usesCoverImageLayout ? 28 : 12)

                VStack(alignment: .leading, spacing: 10) {
                    Text(FlowLayoutGuardrails.softWrapped(article.title))
                        .font(appSettings.appFont(.title3, weight: .bold))
                        .foregroundStyle(primaryCardForeground)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    authorRow
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 216, alignment: .bottomLeading)
        .background {
            previewCardBackground
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(appSettings.themePalette.articlePreviewBorder, lineWidth: 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var previewDateLabel: String {
        article.publishedDate.formatted(
            Date.FormatStyle()
                .month(.abbreviated)
                .day()
                .year()
        )
    }

    private var usesCoverImageLayout: Bool {
        article.imageURL != nil && !appSettings.textOnlyMode
    }

    private var primaryCardForeground: Color {
        usesCoverImageLayout ? .white : appSettings.themePalette.foreground
    }

    private var secondaryCardForeground: Color {
        usesCoverImageLayout ? .white.opacity(0.82) : appSettings.themePalette.secondaryForeground
    }

    private var metadataBackground: Color {
        usesCoverImageLayout ? .black.opacity(0.28) : appSettings.themePalette.tertiaryFill
    }

    private var previewFallbackBackground: LinearGradient {
        LinearGradient(
            colors: [
                appSettings.themePalette.articlePreviewBackgroundTop,
                appSettings.themePalette.articlePreviewBackgroundBottom
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var previewCardBackground: some View {
        if let imageURL = article.imageURL, !appSettings.textOnlyMode {
            GeometryReader { geometry in
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                            .clipped()
                    default:
                        previewFallbackBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            }
        } else {
            previewFallbackBackground
        }
    }

    private var previewCardScrim: LinearGradient {
        if usesCoverImageLayout {
            LinearGradient(
                colors: [
                    .black.opacity(0.28),
                    .black.opacity(0.10),
                    .black.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                colors: [
                    appSettings.primaryColor.opacity(0.10),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var previewMetadataRow: some View {
        HStack(spacing: 8) {
            metadataBadge(title: "\(article.readingTimeMinutes) min", systemImage: "clock")

            Spacer(minLength: 8)

            Text(previewDateLabel)
                .font(appSettings.appFont(.caption1, weight: .semibold))
                .foregroundStyle(secondaryCardForeground)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var authorRow: some View {
        if let author {
            HStack(spacing: 8) {
                AvatarView(url: author.avatarURL, fallback: author.displayName, size: 26)
                    .overlay {
                        Circle().stroke(primaryCardForeground.opacity(0.42), lineWidth: 0.8)
                    }

                Text(author.displayName)
                    .font(appSettings.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(primaryCardForeground)
                    .lineLimit(1)

                if let handle = author.handle, !handle.isEmpty {
                    Text(handle)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(secondaryCardForeground)
                        .lineLimit(1)
                }
            }
        }
    }

    private func metadataBadge(title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .font(appSettings.appFont(.caption1, weight: .semibold))
        .foregroundStyle(secondaryCardForeground)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(metadataBackground, in: Capsule())
    }

}

enum LongFormArticleReaderLayout {
    static let showsArticleTypeBadge = false
    static let showsBookmarkAction = false
    static let showsShareAction = true
    static let usesRuledAuthorSection = true
    static let heroMinHeight: CGFloat = 460
    static let heroCornerRadius: CGFloat = 0
    static let contentHorizontalPadding: CGFloat = 20
    static let contentMaxWidth: CGFloat = 760
    static let heroHeaderOverlap: CGFloat = 56
    static let heroImageOpacity = 0.82
    static let heroBaseFadeOpacity = 0.12
    static let heroTopFadeOpacity = 0.02
    static let heroMiddleFadeOpacity = 0.24
    static let heroBottomFadeOpacity = 1.0
    static let authorFallbackBlurRadius: CGFloat = 22
    static let shareButtonDiameter: CGFloat = 48
    static let followButtonHorizontalPadding: CGFloat = 20
    static let followButtonVerticalPadding: CGFloat = 11

    static func heroBackgroundURL(
        article: NostrLongFormArticleMetadata,
        authorAvatarURL: URL?
    ) -> URL? {
        article.imageURL ?? authorAvatarURL
    }
}

struct LongFormArticleReaderView: View {
    private struct MentionMetadataDecoder: MetadataCoding {}

    @EnvironmentObject private var appSettings: AppSettingsStore

    let item: FeedItem
    let article: NostrLongFormArticleMetadata
    let isOwnedByCurrentUser: Bool
    let isFollowingAuthor: Bool
    let shareLink: String
    let onFollowToggle: () -> Void
    let onProfileTap: ((String) -> Void)?
    let onHashtagTap: ((String) -> Void)?

    private let blocks: [LongFormArticleBlock]

    init(
        item: FeedItem,
        article: NostrLongFormArticleMetadata,
        isOwnedByCurrentUser: Bool,
        isFollowingAuthor: Bool,
        shareLink: String,
        onFollowToggle: @escaping () -> Void,
        onProfileTap: ((String) -> Void)? = nil,
        onHashtagTap: ((String) -> Void)? = nil
    ) {
        self.item = item
        self.article = article
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.isFollowingAuthor = isFollowingAuthor
        self.shareLink = shareLink
        self.onFollowToggle = onFollowToggle
        self.onProfileTap = onProfileTap
        self.onHashtagTap = onHashtagTap
        let parsedBlocks = LongFormArticleMarkdownParser.parseBlocks(from: item.displayEvent.content)
        if article.imageIsContentFallback, let imageURL = article.imageURL {
            self.blocks = Self.blocksByRemovingFirstCoverImage(parsedBlocks, coverImageURL: imageURL)
        } else {
            self.blocks = parsedBlocks
        }
    }

    private static func blocksByRemovingFirstCoverImage(
        _ blocks: [LongFormArticleBlock],
        coverImageURL: URL
    ) -> [LongFormArticleBlock] {
        let coverURLString = coverImageURL.absoluteString.lowercased()
        var didRemoveCoverImage = false

        return blocks.compactMap { block in
            guard !didRemoveCoverImage,
                  case .image(let url, _) = block,
                  url.absoluteString.lowercased() == coverURLString else {
                return block
            }

            didRemoveCoverImage = true
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroSection

            VStack(alignment: .leading, spacing: 28) {
                articleHeaderSection
                    .padding(.top, -LongFormArticleReaderLayout.heroHeaderOverlap)
                    .zIndex(1)

                articleBody

                if !article.tags.isEmpty {
                    footerTagsSection
                }
            }
            .frame(maxWidth: LongFormArticleReaderLayout.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, LongFormArticleReaderLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .environment(\.openURL, OpenURLAction { url in
            handleOpenURL(url)
        })
    }

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            heroBackground
            heroFade
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: LongFormArticleReaderLayout.heroMinHeight, alignment: .bottomLeading)
        .background(appSettings.themePalette.background)
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let heroBackgroundURL, !appSettings.textOnlyMode {
            GeometryReader { geometry in
                CachedAsyncImage(url: heroBackgroundURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                            .clipped()
                            .blur(radius: usesAuthorFallbackHero ? LongFormArticleReaderLayout.authorFallbackBlurRadius : 0)
                            .saturation(usesAuthorFallbackHero ? 0.82 : 0.94)
                            .opacity(LongFormArticleReaderLayout.heroImageOpacity)
                    default:
                        heroFallbackBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            }
        } else {
            heroFallbackBackground
        }
    }

    private var heroFallbackBackground: some View {
        LinearGradient(
            colors: [
                appSettings.primaryColor.opacity(0.18),
                appSettings.themePalette.secondaryBackground,
                appSettings.themePalette.background
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var articleHeaderSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    articleMetaBadges
                    Spacer(minLength: 12)
                    articleShareButton
                }

                VStack(alignment: .leading, spacing: 14) {
                    articleMetaBadges

                    HStack {
                        Spacer(minLength: 0)
                        articleShareButton
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(FlowLayoutGuardrails.softWrapped(article.title))
                    .font(appSettings.appFont(.largeTitle, weight: .bold))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = article.summary, !summary.isEmpty {
                    Text(FlowLayoutGuardrails.softWrapped(summary))
                        .font(appSettings.appFont(.title3))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            authorRow
        }
    }

    private var heroFade: some View {
        let fadeColor = appSettings.themePalette.background
        return ZStack {
            fadeColor.opacity(LongFormArticleReaderLayout.heroBaseFadeOpacity)
            LinearGradient(
                colors: [
                    fadeColor.opacity(LongFormArticleReaderLayout.heroTopFadeOpacity),
                    fadeColor.opacity(LongFormArticleReaderLayout.heroMiddleFadeOpacity),
                    fadeColor.opacity(LongFormArticleReaderLayout.heroBottomFadeOpacity)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var articleMetaBadges: some View {
        HStack(spacing: 10) {
            readerMetaBadge(title: "\(article.readingTimeMinutes) min read", systemImage: "clock")
            readerMetaBadge(title: publishedDateLabel, systemImage: "calendar")
        }
    }

    private var articleShareButton: some View {
        ShareLink(item: shareLink) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .frame(
                    width: LongFormArticleReaderLayout.shareButtonDiameter,
                    height: LongFormArticleReaderLayout.shareButtonDiameter
                )
                .background(appSettings.themePalette.secondaryBackground, in: Circle())
                .overlay {
                    Circle()
                        .stroke(appSettings.themeSeparator(defaultOpacity: 0.8), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share article")
    }

    private var heroBackgroundURL: URL? {
        LongFormArticleReaderLayout.heroBackgroundURL(
            article: article,
            authorAvatarURL: item.avatarURL
        )
    }

    private var usesAuthorFallbackHero: Bool {
        article.imageURL == nil && heroBackgroundURL == item.avatarURL
    }

    private var authorRuleColor: Color {
        appSettings.themeSeparator(defaultOpacity: 0.82)
    }

    private var authorRow: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(authorRuleColor)

            HStack(alignment: .center, spacing: 14) {
                authorIdentity

                Spacer(minLength: 12)

                if isOwnedByCurrentUser {
                    Text("You")
                        .font(appSettings.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .padding(.horizontal, LongFormArticleReaderLayout.followButtonHorizontalPadding)
                        .padding(.vertical, LongFormArticleReaderLayout.followButtonVerticalPadding)
                        .background(appSettings.themePalette.tertiaryFill, in: Capsule())
                } else {
                    Button(isFollowingAuthor ? "Following" : "Follow") {
                        onFollowToggle()
                    }
                    .font(appSettings.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(isFollowingAuthor ? appSettings.themePalette.secondaryForeground : appSettings.buttonTextColor)
                    .padding(.horizontal, LongFormArticleReaderLayout.followButtonHorizontalPadding)
                    .padding(.vertical, LongFormArticleReaderLayout.followButtonVerticalPadding)
                    .background(
                        isFollowingAuthor ? AnyShapeStyle(appSettings.themePalette.tertiaryFill) : AnyShapeStyle(appSettings.primaryGradient),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                isFollowingAuthor
                                    ? appSettings.themePalette.separator
                                    : appSettings.primaryColor.opacity(0.7),
                                lineWidth: 0.9
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 16)

            Divider()
                .overlay(authorRuleColor)
        }
    }

    @ViewBuilder
    private var authorIdentity: some View {
        if let onProfileTap {
            Button {
                onProfileTap(item.displayAuthorPubkey)
            } label: {
                authorIdentityContent
            }
            .buttonStyle(.plain)
        } else {
            authorIdentityContent
        }
    }

    private var authorIdentityContent: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(url: item.avatarURL, fallback: item.displayName, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .lineLimit(1)

                Text(item.handle)
                    .font(appSettings.appFont(.subheadline))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .lineLimit(1)

                if let nip05 = item.displayProfile?.nip05?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !nip05.isEmpty {
                    Text(nip05)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var articleBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(for block: LongFormArticleBlock) -> some View {
        switch block {
        case .heading(let level, let markdown):
            ArticleMarkdownText(
                markdown: markdown,
                font: headingFont(for: level)
            )
        case .paragraph(let markdown):
            ArticleMarkdownText(
                markdown: markdown,
                font: appSettings.appFont(.body)
            )
            .lineSpacing(4)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("•")
                            .font(appSettings.appFont(.body, weight: .semibold))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)

                        ArticleMarkdownText(
                            markdown: item,
                            font: appSettings.appFont(.body)
                        )
                        .lineSpacing(4)
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(start + index).")
                            .font(appSettings.appFont(.body, weight: .semibold))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .frame(minWidth: 28, alignment: .leading)

                        ArticleMarkdownText(
                            markdown: item,
                            font: appSettings.appFont(.body)
                        )
                        .lineSpacing(4)
                    }
                }
            }
        case .blockquote(let markdown):
            HStack(alignment: .top, spacing: 14) {
                Capsule()
                    .fill(appSettings.primaryColor.opacity(0.35))
                    .frame(width: 4)

                ArticleMarkdownText(
                    markdown: markdown,
                    font: appSettings.appFont(.body)
                )
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .lineSpacing(4)
            }
            .padding(18)
            .background(appSettings.themePalette.secondaryBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 10) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(appSettings.appFont(.caption1, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(appSettings.themePalette.secondaryBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(appSettings.themePalette.separator, lineWidth: 0.8)
            }
        case .image(let url, let alt):
            VStack(alignment: .leading, spacing: 8) {
                LongFormArticleRemoteImage(url: url, alt: alt, maxHeight: 520)

                if let alt, !alt.isEmpty {
                    Text(alt)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .divider:
            Divider()
                .overlay(appSettings.themePalette.separator)
                .padding(.vertical, 2)
        }
    }

    private var footerTagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Topics")
                .font(appSettings.appFont(.headline, weight: .semibold))

            FlowLayout(spacing: 8) {
                ForEach(article.tags, id: \.self) { tag in
                    if let onHashtagTap {
                        Button {
                            onHashtagTap(tag)
                        } label: {
                            Text(FlowLayoutGuardrails.softWrapped("#\(tag)", maxNonBreakingRunLength: 18))
                                .font(appSettings.appFont(.subheadline, weight: .medium))
                                .foregroundStyle(appSettings.primaryColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(appSettings.primaryColor.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(FlowLayoutGuardrails.softWrapped("#\(tag)", maxNonBreakingRunLength: 18))
                            .font(appSettings.appFont(.subheadline, weight: .medium))
                            .foregroundStyle(appSettings.primaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(appSettings.primaryColor.opacity(0.08), in: Capsule())
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var publishedDateLabel: String {
        article.publishedDate.formatted(
            Date.FormatStyle()
                .month(.abbreviated)
                .day()
                .year()
        )
    }

    private func readerMetaBadge(title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .font(appSettings.appFont(.caption1, weight: .semibold))
        .foregroundStyle(appSettings.themePalette.secondaryForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(appSettings.themePalette.secondaryBackground.opacity(0.82), in: Capsule())
        .overlay {
            Capsule()
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.8), lineWidth: 0.7)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return appSettings.appFont(.title1, weight: .bold)
        case 2:
            return appSettings.appFont(.title2, weight: .bold)
        case 3:
            return appSettings.appFont(.title3, weight: .semibold)
        default:
            return appSettings.appFont(.headline, weight: .semibold)
        }
    }

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        if let pubkey = NoteContentParser.profilePubkey(fromActionURL: url),
           let onProfileTap {
            onProfileTap(pubkey)
            return .handled
        }

        if let hashtag = NoteContentParser.hashtagFromActionURL(url) {
            onHashtagTap?(hashtag)
            return .handled
        }

        if let nostrIdentifier = nostrIdentifier(from: url) {
            if let pubkey = profilePubkey(from: nostrIdentifier),
               let onProfileTap {
                onProfileTap(pubkey)
                return .handled
            }

            if let externalURL = NoteContentParser.njumpURL(for: nostrIdentifier) {
                return .systemAction(externalURL)
            }
        }

        return .systemAction(url)
    }

    private func nostrIdentifier(from url: URL) -> String? {
        let absoluteString = url.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if absoluteString.hasPrefix("nostr:") {
            let identifier = String(absoluteString.dropFirst("nostr:".count))
            return identifier.isEmpty ? nil : identifier
        }

        if absoluteString.hasPrefix("npub1") || absoluteString.hasPrefix("nprofile1") {
            return absoluteString
        }

        return nil
    }

    private func profilePubkey(from identifier: String) -> String? {
        if identifier.hasPrefix("npub1") {
            return PublicKey(npub: identifier)?.hex.lowercased()
        }

        guard identifier.hasPrefix("nprofile1") else { return nil }
        let decoder = MentionMetadataDecoder()
        return try? decoder.decodedMetadata(from: identifier).pubkey?.lowercased()
    }
}

private struct ArticleMarkdownText: View {
    let markdown: String
    let font: Font

    var body: some View {
        Text(attributedString)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributedString: AttributedString {
        if let parsed = try? AttributedString(markdown: markdown) {
            return parsed
        }
        return AttributedString(markdown)
    }
}

private struct LongFormArticleRemoteImage: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let url: URL
    let alt: String?
    var aspectRatio: CGFloat? = nil
    var maxHeight: CGFloat? = nil

    private var boundedAspectRatio: CGFloat? {
        FlowLayoutGuardrails.clampedAspectRatio(aspectRatio)
    }

    var body: some View {
        Group {
            if appSettings.textOnlyMode {
                hiddenImagePlaceholder
            } else {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        renderedImage(image)
                    case .failure:
                        hiddenImagePlaceholder
                    default:
                        loadingPlaceholder
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(appSettings.themePalette.separator, lineWidth: 0.8)
        }
    }

    private func renderedImage(_ image: Image) -> some View {
        Group {
            if let boundedAspectRatio {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(boundedAspectRatio, contentMode: .fill)
                    .frame(maxHeight: maxHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .clipped()
            } else {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight ?? 520)
            }
        }
        .background(appSettings.themePalette.secondaryBackground)
    }

    private var loadingPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(appSettings.themePalette.secondaryBackground)

            ProgressView()
        }
        .frame(maxWidth: .infinity)
        .frame(height: boundedAspectRatio == nil ? 220 : nil)
        .aspectRatio(boundedAspectRatio, contentMode: .fit)
        .frame(maxHeight: maxHeight)
    }

    private var hiddenImagePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: appSettings.textOnlyMode ? "photo.slash" : "photo")
                .font(appSettings.appFont(.title3))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            Text(appSettings.textOnlyMode ? "Image hidden in Text Only Mode" : (alt ?? "Image unavailable"))
                .font(appSettings.appFont(.footnote))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: boundedAspectRatio == nil ? 160 : nil)
        .aspectRatio(boundedAspectRatio, contentMode: .fit)
        .frame(maxHeight: maxHeight)
        .background(appSettings.themePalette.secondaryBackground)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        let measurementProposal = proposal.width.map { ProposedViewSize(width: $0, height: nil) } ?? .unspecified
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(measurementProposal)
            let resolvedWidth = availableWidth.isFinite ? min(size.width, availableWidth) : size.width

            if currentX > 0, currentX + resolvedWidth > availableWidth {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            rowHeight = max(rowHeight, size.height)
            currentX += resolvedWidth + spacing
        }

        return CGSize(
            width: proposal.width ?? currentX,
            height: currentY + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0
        let measurementProposal = bounds.width.isFinite
            ? ProposedViewSize(width: bounds.width, height: nil)
            : .unspecified

        for subview in subviews {
            let size = subview.sizeThatFits(measurementProposal)
            let placementWidth = bounds.width.isFinite ? min(size.width, bounds.width) : size.width

            if currentX > bounds.minX, currentX + placementWidth > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: placementWidth, height: size.height)
            )

            currentX += placementWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
