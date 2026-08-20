import NostrSDK
import SwiftUI
import UIKit

enum ProfileAboutLayout {
    static let collapsedLineLimit = 3

    static func exceedsCollapsedLineLimit(
        text: String,
        width: CGFloat,
        font: UIFont
    ) -> Bool {
        guard !text.isEmpty, width.isFinite, width > 0 else { return false }

        let textStorage = NSTextStorage(
            string: text,
            attributes: [.font: font]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.maximumNumberOfLines = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, stop in
            lineCount += 1
            if lineCount > collapsedLineLimit {
                stop.pointee = true
            }
        }
        return lineCount > collapsedLineLimit
    }
}

private struct ProfileAboutWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ProfileAboutTextView: View {
    private struct MentionMetadataDecoder: MetadataCoding {}

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var appSettings: AppSettingsStore

    private let text: String
    private let tokens: [NoteContentToken]
    private let mentionIdentifiers: [String]
    private let onProfileTap: (String) -> Void
    private let onHashtagTap: ((String) -> Void)?
    private let onRelayTap: ((URL) -> Void)?

    @State private var mentionLabels: [String: String] = [:]
    @State private var availableTextWidth: CGFloat = 0
    @State private var isExpanded = false

    init(
        text: String,
        onProfileTap: @escaping (String) -> Void,
        onHashtagTap: ((String) -> Void)? = nil,
        onRelayTap: ((URL) -> Void)? = nil
    ) {
        self.text = text
        self.onProfileTap = onProfileTap
        self.onHashtagTap = onHashtagTap
        self.onRelayTap = onRelayTap
        self.tokens = NoteContentParser.tokenize(content: text)
        self.mentionIdentifiers = Self.collectMentionIdentifiers(tokens: tokens)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(attributedString)
                .font(appSettings.appFont(.body))
                .foregroundStyle(appSettings.themePalette.foreground)
                .multilineTextAlignment(.leading)
                .lineLimit(isExpanded ? nil : ProfileAboutLayout.collapsedLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ProfileAboutWidthPreferenceKey.self,
                            value: proxy.size.width
                        )
                    }
                }

            if shouldShowExpansionControl {
                Button(isExpanded ? "Less" : "More") {
                    if accessibilityReduceMotion {
                        isExpanded.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    }
                }
                .font(appSettings.appFont(.footnote, weight: .semibold))
                .foregroundStyle(appSettings.primaryColor)
                .frame(minWidth: 40, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Show less bio" : "Show full bio")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let pubkey = NoteContentParser.profilePubkey(fromActionURL: url) {
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
        .onPreferenceChange(ProfileAboutWidthPreferenceKey.self) { width in
            guard width.isFinite, width > 0, abs(width - availableTextWidth) > 0.5 else { return }
            availableTextWidth = width
        }
        .onChange(of: text) { _, _ in
            isExpanded = false
        }
        .task(id: text) {
            await resolveMentionLabelsIfNeeded()
        }
    }

    private var shouldShowExpansionControl: Bool {
        ProfileAboutLayout.exceedsCollapsedLineLimit(
            text: String(attributedString.characters),
            width: availableTextWidth,
            font: appSettings.appUIFont(.body)
        )
    }

    private var attributedString: AttributedString {
        var output = AttributedString()

        for token in tokens {
            var segment = AttributedString(displayValue(for: token))
            segment.font = .body

            switch token.type {
            case .nostrMention:
                let normalized = Self.normalizeMentionIdentifier(token.value)
                if let pubkey = Self.mentionedPubkey(from: normalized),
                   let actionURL = NoteContentParser.profileActionURL(for: pubkey) {
                    segment.link = actionURL
                } else if let externalURL = NoteContentParser.njumpURL(for: normalized) {
                    segment.link = externalURL
                }
            case .hashtag:
                if let url = NoteContentParser.hashtagActionURL(for: token.value) {
                    segment.link = url
                }
            case .url, .image, .video, .youtubeVideo, .audio:
                if let url = URL(string: token.value) {
                    segment.link = url
                }
            case .websocketURL:
                if let url = RelayURLSupport.actionURL(for: token.value),
                   onRelayTap != nil {
                    segment.link = url
                } else {
                    segment.foregroundColor = appSettings.themePalette.secondaryForeground
                }
            case .text, .emoji, .nostrEvent:
                break
            }

            output += segment
        }

        return AttributedLinkStyler.applyingLinkColor(appSettings.linkColor, to: output)
    }

    private func displayValue(for token: NoteContentToken) -> String {
        guard token.type == .nostrMention else {
            return Self.softWrapValue(token.value)
        }

        let normalized = Self.normalizeMentionIdentifier(token.value)
        if let label = mentionLabels[normalized] {
            return Self.softWrapValue(label)
        }
        return Self.softWrapValue("@\(Self.fallbackMentionToken(for: normalized))")
    }

    private func resolveMentionLabelsIfNeeded() async {
        guard !mentionIdentifiers.isEmpty else {
            await MainActor.run {
                mentionLabels = [:]
            }
            return
        }

        var resolved: [String: String] = [:]
        var pubkeyByIdentifier: [String: String] = [:]
        var pubkeys: [String] = []

        for identifier in mentionIdentifiers {
            resolved[identifier] = "@\(Self.fallbackMentionToken(for: identifier))"
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
                let fetched = await NostrFeedService().fetchProfiles(
                    relayURLs: relayURLs,
                    pubkeys: cached.missing
                )
                profilesByPubkey.merge(fetched, uniquingKeysWith: { existing, _ in existing })
            }

            for (identifier, pubkey) in pubkeyByIdentifier {
                guard let profile = profilesByPubkey[pubkey] else { continue }
                resolved[identifier] = mentionLabel(from: profile, pubkey: pubkey)
            }
        }

        await MainActor.run {
            mentionLabels = resolved
        }
    }

    private func mentionLabel(from profile: NostrProfile, pubkey: String) -> String {
        let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            return "@\(name)"
        }

        let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !displayName.isEmpty {
            return "@\(displayName)"
        }

        return "@\(Self.fallbackMentionToken(for: pubkey))"
    }

    private static let softBreakSeparators = CharacterSet(charactersIn: "/._-?&=#:%+")

    private static func softWrapValue(_ value: String) -> String {
        guard value.count > 36 else { return value }

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
            if nonBreakingRunLength >= 24 {
                wrapped.append(softBreak)
                nonBreakingRunLength = 0
            }
        }

        return wrapped
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

    private static func normalizeMentionIdentifier(_ raw: String) -> String {
        let lowered = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if lowered.hasPrefix("nostr:") {
            return String(lowered.dropFirst("nostr:".count))
        }
        return lowered
    }

    private static func mentionedPubkey(from identifier: String) -> String? {
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
