import Foundation

enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case mentions
    case reactions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .mentions:
            return "Mentions"
        case .reactions:
            return "Reactions"
        }
    }

    var eventKinds: [Int] {
        switch self {
        case .all:
            return [1, 6, 7, 16, 1111, 1244]
        case .mentions:
            return [1, 1111, 1244]
        case .reactions:
            return [7]
        }
    }
}

enum ActivityNotificationPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case mentions
    case reactions
    case replies
    case reshares
    case quoteShares

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mentions:
            return "Mentions"
        case .reactions:
            return "Reactions"
        case .replies:
            return "Replies"
        case .reshares:
            return "Reshares"
        case .quoteShares:
            return "Quote Shares"
        }
    }
}

struct ActivityActor: Hashable, Sendable {
    let pubkey: String
    let profile: NostrProfile?

    var displayName: String {
        if let displayName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return shortNostrIdentifier(pubkey)
    }

    var handle: String {
        if let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            let normalized = name.replacingOccurrences(of: " ", with: "")
            return "@\(normalized.lowercased())"
        }
        if let displayName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            let normalized = displayName.replacingOccurrences(of: " ", with: "")
            return "@\(normalized.lowercased())"
        }
        return "@\(shortNostrIdentifier(pubkey).lowercased())"
    }

    var avatarURL: URL? {
        profile?.resolvedAvatarURL
    }
}

struct ActivityReaction: Hashable, Sendable {
    let content: String
    let shortcode: String?
    let customEmojiImageURL: URL?

    var displayValue: String {
        if let shortcode,
           customEmojiImageURL != nil || reactionEmojiShortcode(from: content) != nil || content == "+" {
            return ":\(shortcode):"
        }
        return content
    }

    var isCustomEmoji: Bool {
        customEmojiImageURL != nil
    }
}

enum ActivityAction: Hashable, Sendable {
    case mention(kind: Int)
    case reply(kind: Int)
    case reaction(ActivityReaction)
    case reshare(kind: Int)
    case quoteShare(kind: Int)

    var category: ActivityFilter {
        switch self {
        case .mention, .reply, .quoteShare:
            return .mentions
        case .reaction:
            return .reactions
        case .reshare:
            return .all
        }
    }

    var title: String {
        switch self {
        case .mention:
            return "Mention"
        case .reply:
            return "Reply"
        case .reaction:
            return "Reaction"
        case .reshare:
            return "Reshare"
        case .quoteShare:
            return "Quote share"
        }
    }

    var sourceKind: Int? {
        switch self {
        case .mention(let kind), .reply(let kind), .reshare(let kind), .quoteShare(let kind):
            return kind
        case .reaction:
            return nil
        }
    }

    var reaction: ActivityReaction? {
        if case .reaction(let reaction) = self {
            return reaction
        }
        return nil
    }

    var notificationPreference: ActivityNotificationPreference {
        switch self {
        case .mention:
            return .mentions
        case .reply:
            return .replies
        case .reaction:
            return .reactions
        case .reshare:
            return .reshares
        case .quoteShare:
            return .quoteShares
        }
    }

    func matches(_ filter: ActivityFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .mentions:
            switch self {
            case .mention, .reply, .quoteShare:
                return true
            case .reaction, .reshare:
                return false
            }
        case .reactions:
            if case .reaction = self {
                return true
            }
            return false
        }
    }
}

struct ActivityAddress: Hashable, Sendable {
    let kind: Int
    let pubkey: String
    let identifier: String
}

enum ActivityTargetReference: Hashable, Sendable {
    case eventID(String)
    case address(ActivityAddress)

    var eventID: String? {
        if case .eventID(let value) = self {
            return value
        }
        return nil
    }

    var address: ActivityAddress? {
        if case .address(let value) = self {
            return value
        }
        return nil
    }

    init?(tag: [String]) {
        guard let name = tag.first?.lowercased(), tag.count > 1 else {
            return nil
        }

        let rawValue = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }

        switch name {
        case "e", "q":
            self = .eventID(rawValue.lowercased())

        case "a":
            let pieces = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count == 3, let kind = Int(pieces[0]) else {
                return nil
            }

            let pubkey = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let identifier = String(pieces[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pubkey.isEmpty, !identifier.isEmpty else { return nil }

            self = .address(ActivityAddress(kind: kind, pubkey: pubkey, identifier: identifier))

        default:
            return nil
        }
    }
}

struct ActivityTargetNote: Hashable, Sendable {
    let reference: ActivityTargetReference?
    let event: NostrEvent?
    let profile: NostrProfile?
    let snippet: String

    var eventID: String? {
        event?.id ?? reference?.eventID
    }

    var address: ActivityAddress? {
        reference?.address
    }

    var createdAt: Int? {
        event?.createdAt
    }
}

struct ActivityRow: Identifiable, Hashable, Sendable {
    let event: NostrEvent
    let actor: ActivityActor
    let action: ActivityAction
    let target: ActivityTargetNote

    var id: String {
        event.id
    }

    var createdAt: Int {
        event.createdAt
    }

    var createdAtDate: Date {
        event.createdAtDate
    }

    var actorPubkey: String {
        actor.pubkey
    }

    var actorProfile: NostrProfile? {
        actor.profile
    }

    var targetSnippet: String {
        target.snippet
    }

    var threadMuteIdentifier: String? {
        switch action {
        case .reaction, .reshare:
            return normalizedThreadIdentifier(from: target.event?.conversationID)
                ?? normalizedThreadIdentifier(from: target.eventID)
                ?? normalizedThreadIdentifier(from: event.conversationID)
        case .mention, .reply, .quoteShare:
            return normalizedThreadIdentifier(from: event.conversationID)
                ?? normalizedThreadIdentifier(from: target.event?.conversationID)
                ?? normalizedThreadIdentifier(from: target.eventID)
        }
    }

    var previewDisplay: ActivityRowPreviewDisplay {
        switch action {
        case .mention, .reply, .quoteShare:
            if let sourceText = normalizedPreviewText(
                from: event.activitySnippet(maxLength: 120),
                event: event
            ) {
                return .text(sourceText)
            }

            if let targetText = normalizedPreviewText(
                from: targetSnippet,
                event: target.event
            ) {
                return .text(targetText)
            }

            return mediaPreviewDisplay(for: event)
                ?? mediaPreviewDisplay(for: target.event)
                ?? .none
        case .reaction, .reshare:
            if let targetText = normalizedPreviewText(
                from: targetSnippet,
                event: target.event
            ) {
                return .text(targetText)
            }

            return mediaPreviewDisplay(for: target.event) ?? .none
        }
    }
}

enum ActivityRowPreviewDisplay: Equatable, Sendable {
    case none
    case text(String)
    case image(URL)
    case mediaPlaceholder
}

extension NostrEvent {
    var activityAction: ActivityAction? {
        switch kind {
        case 7:
            return .reaction(activityReaction)
        case 6, 16:
            return .reshare(kind: kind)
        case 1, 1111, 1244:
            if containsActivityQuoteReference {
                return .quoteShare(kind: kind)
            }
            if isReplyNote {
                return .reply(kind: kind)
            }
            return .mention(kind: kind)
        default:
            return nil
        }
    }

    var activityTargetReference: ActivityTargetReference? {
        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "q" else { continue }
            if let reference = ActivityTargetReference(tag: tag) {
                return reference
            }
        }

        var fallback: ActivityTargetReference?

        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "e" || name == "a" else {
                continue
            }

            guard let reference = ActivityTargetReference(tag: tag) else {
                continue
            }

            let marker = tag.count > 3
                ? tag[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                : ""

            if marker == "mention" {
                continue
            }

            if marker == "reply" {
                return reference
            }

            if fallback == nil || marker.isEmpty {
                fallback = reference
            }
        }

        return fallback
    }

    var containsActivityQuoteReference: Bool {
        tags.contains { tag in
            guard let name = tag.first?.lowercased(), name == "q" else { return false }
            return tag.count > 1 && !tag[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var activityReaction: ActivityReaction {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let reactionContent = trimmedContent.isEmpty ? "+" : trimmedContent
        let contentShortcode = reactionEmojiShortcode(from: trimmedContent)
        let emojiURLs = activityEmojiURLs(from: tags)
        let shortcodeFromContentValue = normalizedEmojiIdentifier(from: reactionContent)
        let shortcode =
            contentShortcode
            ?? (shortcodeFromContentValue.flatMap { emojiURLs[$0] != nil ? $0 : nil })
            ?? ((trimmedContent.isEmpty || reactionContent == "+") ? firstActivityEmojiShortcode(from: tags) : nil)
        let emojiURL = shortcode.flatMap {
            emojiURLs[$0] ?? emojiURLs[$0.lowercased()]
        }

        return ActivityReaction(
            content: reactionContent,
            shortcode: shortcode,
            customEmojiImageURL: emojiURL
        )
    }

    func activitySnippet(maxLength: Int = 160) -> String {
        makeActivitySnippet(from: content, maxLength: maxLength)
    }
}

private func makeActivitySnippet(from content: String, maxLength: Int) -> String {
    let normalized = content
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !normalized.isEmpty else { return "" }
    guard normalized.count > maxLength else { return normalized }

    let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
    return String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
}

private func activityEmojiURLs(from tags: [[String]]) -> [String: URL] {
    var result: [String: URL] = [:]

    for tag in tags {
        guard tag.count >= 3 else { continue }
        guard tag.first?.lowercased() == "emoji" else { continue }

        guard let shortcode = normalizedEmojiIdentifier(from: tag[1]) else { continue }
        let urlString = tag[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString), url.scheme != nil else {
            continue
        }

        result[shortcode] = url
        result[shortcode.lowercased()] = url
    }

    return result
}

private func firstActivityEmojiShortcode(from tags: [[String]]) -> String? {
    for tag in tags {
        guard tag.count >= 2 else { continue }
        guard tag.first?.lowercased() == "emoji" else { continue }
        if let shortcode = normalizedEmojiIdentifier(from: tag[1]) {
            return shortcode
        }
    }
    return nil
}

private func reactionEmojiShortcode(from value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix(":"), trimmed.hasSuffix(":"), trimmed.count >= 3 {
        let inner = trimmed.dropFirst().dropLast()
        let shortcode = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return shortcode.isEmpty ? nil : shortcode
    }

    return nil
}

private func normalizedEmojiIdentifier(from value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix(":"), trimmed.hasSuffix(":"), trimmed.count >= 3 {
        let inner = trimmed.dropFirst().dropLast()
        let shortcode = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return shortcode.isEmpty ? nil : shortcode
    }

    return trimmed
}

private func mediaPreviewDisplay(for event: NostrEvent?) -> ActivityRowPreviewDisplay? {
    guard let event else { return nil }

    if let imageURL = NoteContentParser.imageURLs(in: event).first {
        return .image(imageURL)
    }

    if event.hasMedia {
        return .mediaPlaceholder
    }

    return nil
}

private func normalizedPreviewText(from value: String?, event: NostrEvent?) -> String? {
    guard let normalized = normalizedSnippet(value) else {
        return nil
    }

    if let event, event.hasMedia, looksLikeStandaloneMediaLink(normalized) {
        return nil
    }

    return normalized
}

private func normalizedSnippet(_ value: String?) -> String? {
    let normalized = (value ?? "")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

private func looksLikeStandaloneMediaLink(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let tokens = trimmed.split(whereSeparator: \.isWhitespace)
    guard tokens.count == 1 else { return false }
    guard let url = URL(string: String(tokens[0])),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        return false
    }

    let path = url.path.lowercased()
    return activityMediaPreviewExtensions.contains { path.hasSuffix($0) }
}

private func normalizedThreadIdentifier(from value: String?) -> String? {
    guard let value else { return nil }

    let normalized = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    return normalized.isEmpty ? nil : normalized
}

private let activityMediaPreviewExtensions: Set<String> = [
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".svg",
    ".mp4", ".webm", ".ogg", ".mov", ".mp3", ".wav", ".flac",
    ".aac", ".m4a", ".opus", ".wma"
]
