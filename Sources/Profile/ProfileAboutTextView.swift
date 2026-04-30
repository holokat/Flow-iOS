import NostrSDK
import SwiftUI

struct ProfileAboutTextView: View {
    private struct MentionMetadataDecoder: MetadataCoding {}

    @EnvironmentObject private var appSettings: AppSettingsStore

    private let text: String
    private let tokens: [NoteContentToken]
    private let mentionIdentifiers: [String]
    private let onProfileTap: (String) -> Void
    private let onHashtagTap: ((String) -> Void)?
    private let onRelayTap: ((URL) -> Void)?

    @State private var mentionLabels: [String: String] = [:]

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
        Text(attributedString)
            .font(.body)
            .foregroundStyle(appSettings.themePalette.foreground)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
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
            .task(id: text) {
                await resolveMentionLabelsIfNeeded()
            }
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
