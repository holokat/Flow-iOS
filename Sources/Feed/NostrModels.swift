import Combine
import Foundation
import NostrSDK

enum ProfileAvatarURLResolver {
    static func url(from rawValue: String?) -> URL? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil else {
            return nil
        }

        return thumbnailURLIfNeeded(for: url)
    }

    private static func thumbnailURLIfNeeded(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              shouldUseNostrBuildThumbnail(forHost: host) else {
            return url
        }

        let trimmedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty, !trimmedPath.hasPrefix("thumb/") else {
            return url
        }

        // nostr.build serves smaller avatar images from the same asset path under /thumb/.
        components.percentEncodedPath = "/thumb/\(trimmedPath)"
        return components.url ?? url
    }

    private static func shouldUseNostrBuildThumbnail(forHost host: String) -> Bool {
        host == "nostr.build" || host == "image.nostr.build" || host == "cdn.nostr.build"
    }
}

extension NostrProfile {
    var resolvedAvatarURL: URL? {
        ProfileAvatarURLResolver.url(from: picture)
    }
}

struct NostrFilter: Sendable {
    var ids: [String]? = nil
    var authors: [String]? = nil
    var kinds: [Int]? = nil
    var search: String? = nil
    var limit: Int? = nil
    var since: Int? = nil
    var until: Int? = nil
    var tagFilters: [String: [String]]? = nil

    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        if let ids, !ids.isEmpty {
            object["ids"] = ids
        }
        if let authors, !authors.isEmpty {
            object["authors"] = authors
        }
        if let kinds, !kinds.isEmpty {
            object["kinds"] = kinds
        }
        if let search {
            let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSearch.isEmpty {
                object["search"] = trimmedSearch
            }
        }
        if let limit {
            object["limit"] = limit
        }
        if let since {
            object["since"] = since
        }
        if let until {
            object["until"] = until
        }
        if let tagFilters {
            for (tag, values) in tagFilters where !values.isEmpty {
                let key = tag.hasPrefix("#") ? tag.lowercased() : "#\(tag.lowercased())"
                object[key] = values
            }
        }
        return object
    }
}

struct NostrEvent: Codable, Hashable, Sendable {
    let id: String
    let pubkey: String
    let createdAt: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String

    enum CodingKeys: String, CodingKey {
        case id
        case pubkey
        case createdAt = "created_at"
        case kind
        case tags
        case content
        case sig
    }

    var createdAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    var isRepost: Bool {
        kind == 6 || kind == 16
    }

    var isReplyNote: Bool {
        if [1111, 1244].contains(kind) {
            return true
        }
        guard kind == 1 else { return false }

        var hasNonMentionEventReference = false

        for tag in tags {
            guard let name = tag.first?.lowercased() else { continue }

            if name == "a" {
                return true
            }

            if name == "e" {
                let marker = tag.count > 3 ? tag[3].lowercased() : ""
                if marker == "reply" || marker == "root" {
                    return true
                }
                if marker != "mention" {
                    hasNonMentionEventReference = true
                }
            }
        }

        return hasNonMentionEventReference
    }

    var eventReferenceIDs: [String] {
        tags.compactMap { tag in
            guard let name = tag.first?.lowercased(), name == "e" else {
                return nil
            }
            guard tag.count > 1, !tag[1].isEmpty else { return nil }
            return tag[1]
        }
    }

    var rootEventReferenceID: String? {
        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "e" else { continue }
            guard tag.count > 1, !tag[1].isEmpty else { continue }
            let marker = tag.count > 3 ? tag[3].lowercased() : ""
            if marker == "root" {
                return tag[1]
            }
        }
        return eventReferenceIDs.first
    }

    var lastEventReferenceID: String? {
        for tag in tags.reversed() {
            guard let name = tag.first?.lowercased(), name == "e" else { continue }
            guard tag.count > 1, !tag[1].isEmpty else { continue }
            return tag[1]
        }
        return nil
    }

    var directReplyEventReferenceID: String? {
        for tag in tags.reversed() {
            guard let name = tag.first?.lowercased(), name == "e" else { continue }
            guard tag.count > 1, !tag[1].isEmpty else { continue }
            let marker = tag.count > 3 ? tag[3].lowercased() : ""
            if marker == "reply" {
                return tag[1]
            }
        }
        return lastEventReferenceID
    }

    var conversationID: String {
        if let root = rootEventReferenceID?.lowercased(), !root.isEmpty {
            return root
        }
        if let last = lastEventReferenceID?.lowercased(), !last.isEmpty {
            return last
        }
        return id.lowercased()
    }

    func referencesConversation(id conversationID: String) -> Bool {
        let normalized = conversationID.lowercased()
        if id.lowercased() == normalized {
            return true
        }
        if self.conversationID == normalized {
            return true
        }
        return eventReferenceIDs.contains { $0.lowercased() == normalized }
    }

    func references(eventID: String) -> Bool {
        let target = eventID.lowercased()
        return eventReferenceIDs.contains { $0.lowercased() == target }
    }

    func previewSnippet(maxLength: Int = 80) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalized.isEmpty {
            guard normalized.count > maxLength else { return normalized }
            let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
            return String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        if hasMedia {
            return "media post"
        }

        switch kind {
        case 1111, 1244:
            return "voice note"
        default:
            return "note"
        }
    }

    var hasMedia: Bool {
        if tags.contains(where: { tag in
            guard let name = tag.first?.lowercased() else { return false }
            return name == "imeta"
        }) {
            return true
        }

        guard let detector = MediaDetection.linkDetector else {
            return false
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = detector.matches(in: content, options: [], range: range)
        for match in matches {
            guard let url = match.url else { continue }
            let ext = ".\(url.pathExtension.lowercased())"
            if MediaDetection.mediaExtensions.contains(ext) {
                return true
            }
        }

        return false
    }

    var embeddedRepostEvent: NostrEvent? {
        Self.decodeEmbeddedEvent(from: content)
    }

    var repostTargetEventID: String? {
        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "e" else { continue }
            guard tag.count > 1 else { continue }
            let value = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    var resolvedRepostContentEvent: NostrEvent? {
        guard isRepost else { return nil }

        var current = self
        var remainingDepth = 4
        var seen = Set<String>()

        while remainingDepth > 0 {
            let normalizedID = current.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedID.isEmpty {
                guard seen.insert(normalizedID).inserted else { break }
            }

            guard current.isRepost else { return current }
            guard let embedded = current.embeddedRepostEvent else { return nil }
            current = embedded
            remainingDepth -= 1
        }

        return current.isRepost ? nil : current
    }

    var mentionedPubkeys: [String] {
        tags.compactMap { tag in
            guard let name = tag.first?.lowercased(), name == "p" else { return nil }
            guard tag.count > 1, !tag[1].isEmpty else { return nil }
            return tag[1]
        }
    }

    var containsNSFWHashtag: Bool {
        let tagHashtags = tags.compactMap { tag -> String? in
            guard let name = tag.first?.lowercased(), name == "t" else { return nil }
            guard tag.count > 1 else { return nil }
            return tag[1]
        }

        let inlineHashtags = NSFWHashtagDetection.extractHashtags(from: content)
        return NSFWHashtagDetection.matches(tagHashtags + inlineHashtags)
    }

    var hashtags: [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        let rawHashtags = tags.compactMap { tag -> String? in
            guard let name = tag.first?.lowercased(), name == "t" else { return nil }
            guard tag.count > 1 else { return nil }
            return tag[1]
        } + NSFWHashtagDetection.extractHashtags(from: content)

        for rawHashtag in rawHashtags {
            let normalized = Self.normalizedHashtagValue(rawHashtag)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    func containsHashtag(_ hashtag: String) -> Bool {
        let normalizedHashtag = Self.normalizedHashtagValue(hashtag)
        guard !normalizedHashtag.isEmpty else { return false }
        return hashtags.contains(normalizedHashtag)
    }

    static func normalizedHashtagValue(_ hashtag: String) -> String {
        hashtag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}_+\\-]",
                with: "",
                options: .regularExpression
            )
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
}

struct NostrProfile: Codable, Hashable, Sendable {
    let name: String?
    let displayName: String?
    let picture: String?
    let banner: String?
    let about: String?
    let nip05: String?
    let website: String?
    let lud06: String?
    let lud16: String?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case picture
        case banner
        case about
        case nip05
        case website
        case lud06
        case lud16
    }

    static func decode(from content: String) -> NostrProfile? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        // Real-world kind 0 metadata is often inconsistent (non-string values,
        // alternate keys). Parse leniently first, then fall back to Codable.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let profile = NostrProfile(
                name: normalizedString(object["name"]) ?? normalizedString(object["username"]),
                displayName: normalizedString(object["display_name"]) ??
                    normalizedString(object["displayName"]) ??
                    normalizedString(object["display-name"]),
                picture: normalizedString(object["picture"]) ??
                    normalizedString(object["image"]) ??
                    normalizedString(object["avatar"]) ??
                    normalizedString(object["profile_image"]) ??
                    normalizedString(object["profileImage"]),
                banner: normalizedString(object["banner"]) ?? normalizedString(object["cover"]),
                about: normalizedString(object["about"]) ?? normalizedString(object["description"]),
                nip05: normalizedString(object["nip05"]),
                website: normalizedString(object["website"]) ?? normalizedString(object["url"]),
                lud06: normalizedString(object["lud06"]) ?? normalizedString(object["lnurl"]),
                lud16: normalizedString(object["lud16"]) ?? normalizedString(object["lightning_address"])
            )

            if profile.name != nil ||
                profile.displayName != nil ||
                profile.picture != nil ||
                profile.banner != nil ||
                profile.about != nil ||
                profile.nip05 != nil ||
                profile.website != nil ||
                profile.lud06 != nil ||
                profile.lud16 != nil {
                return profile
            }
        }

        return try? JSONDecoder().decode(NostrProfile.self, from: data)
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let value else { return nil }

        let result: String?
        switch value {
        case let string as String:
            result = string
        case let dictionary as [String: Any]:
            result = normalizedString(
                dictionary["url"] ??
                    dictionary["value"] ??
                    dictionary["text"] ??
                    dictionary["name"]
            )
        case let array as [Any]:
            result = array.compactMap { normalizedString($0) }.first
        case let bool as Bool:
            result = bool ? "true" : "false"
        case let number as NSNumber:
            result = number.stringValue
        default:
            result = nil
        }

        guard let result else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var lightningAddress: String? {
        if let lud16, !lud16.isEmpty {
            return lud16
        }
        if let lud06, !lud06.isEmpty {
            return lud06
        }
        return nil
    }
}

func shortNostrIdentifier(_ pubkey: String, prefixCount: Int = 10, suffixCount: Int = 6) -> String {
    let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return "" }

    let identifier = PublicKey(hex: normalized)?.npub ?? normalized
    let minimumLength = prefixCount + suffixCount + 1
    guard identifier.count > minimumLength else { return identifier }
    return "\(identifier.prefix(prefixCount))…\(identifier.suffix(suffixCount))"
}

struct FeedItem: Identifiable, Hashable, Sendable {
    let event: NostrEvent
    let profile: NostrProfile?
    let displayEventOverride: NostrEvent?
    let displayProfileOverride: NostrProfile?
    let replyTargetEvent: NostrEvent?
    let replyTargetProfile: NostrProfile?

    init(
        event: NostrEvent,
        profile: NostrProfile?,
        displayEventOverride: NostrEvent? = nil,
        displayProfileOverride: NostrProfile? = nil,
        replyTargetEvent: NostrEvent? = nil,
        replyTargetProfile: NostrProfile? = nil
    ) {
        self.event = event
        self.profile = profile
        self.displayEventOverride = displayEventOverride
        self.displayProfileOverride = displayProfileOverride
        self.replyTargetEvent = replyTargetEvent
        self.replyTargetProfile = replyTargetProfile
    }

    var id: String {
        event.id.lowercased()
    }

    var displayEvent: NostrEvent {
        displayEventOverride ?? event
    }

    var displayProfile: NostrProfile? {
        if displayEventOverride != nil {
            return displayProfileOverride
        }
        return profile
    }

    var displayEventID: String {
        displayEvent.id
    }

    var displayAuthorPubkey: String {
        displayEvent.pubkey
    }

    var actorPubkey: String {
        event.pubkey
    }

    var actorDisplayName: String {
        Self.displayName(for: event, profile: profile)
    }

    var actorAvatarURL: URL? {
        Self.avatarURL(for: profile)
    }

    var isRepost: Bool {
        event.isRepost
    }

    var moderationEvents: [NostrEvent] {
        if let displayEventOverride {
            return [event, displayEventOverride]
        }
        return [event]
    }

    var threadNavigationItem: FeedItem {
        guard let displayEventOverride else { return self }
        return FeedItem(event: displayEventOverride, profile: displayProfile)
    }

    var canonicalDisplayItem: FeedItem {
        FeedItem(
            event: displayEvent,
            profile: displayProfile,
            replyTargetEvent: replyTargetEvent,
            replyTargetProfile: replyTargetProfile
        )
    }

    var replyTargetSnippet: String? {
        guard let replyTargetEvent else { return nil }
        return replyTargetEvent.previewSnippet(maxLength: 72)
    }

    var replyTargetFeedItem: FeedItem? {
        guard let replyTargetEvent else { return nil }
        return FeedItem(event: replyTargetEvent, profile: replyTargetProfile)
    }

    var displayName: String {
        Self.displayName(for: displayEvent, profile: displayProfile)
    }

    var handle: String {
        Self.handle(for: displayEvent, profile: displayProfile)
    }

    var avatarURL: URL? {
        Self.avatarURL(for: displayProfile)
    }

    var prefetchImageURLs: [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        func append(_ url: URL?) {
            guard let url else { return }
            let normalized = url.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { return }
            ordered.append(url)
        }

        append(avatarURL)
        append(actorAvatarURL)
        append(replyTargetFeedItem?.avatarURL)

        for mediaURL in NoteContentParser.imageURLs(in: displayEvent) {
            append(mediaURL)
        }

        return ordered
    }

    func merged(with incoming: FeedItem) -> FeedItem {
        let mergedDisplayEvent = incoming.displayEventOverride ?? displayEventOverride
        let mergedReplyTargetEvent = incoming.replyTargetEvent ?? replyTargetEvent

        return FeedItem(
            event: incoming.event,
            profile: incoming.profile ?? profile,
            displayEventOverride: mergedDisplayEvent,
            displayProfileOverride: Self.mergedAssociatedProfile(
                selectedEvent: mergedDisplayEvent,
                preferredEvent: incoming.displayEventOverride,
                preferredProfile: incoming.displayProfileOverride,
                fallbackEvent: displayEventOverride,
                fallbackProfile: displayProfileOverride
            ),
            replyTargetEvent: mergedReplyTargetEvent,
            replyTargetProfile: Self.mergedAssociatedProfile(
                selectedEvent: mergedReplyTargetEvent,
                preferredEvent: incoming.replyTargetEvent,
                preferredProfile: incoming.replyTargetProfile,
                fallbackEvent: replyTargetEvent,
                fallbackProfile: replyTargetProfile
            )
        )
    }

    private static func displayName(for event: NostrEvent, profile: NostrProfile?) -> String {
        if let displayName = profile?.displayName?.trimmed, !displayName.isEmpty {
            return displayName
        }
        if let name = profile?.name?.trimmed, !name.isEmpty {
            return name
        }
        return shortNostrIdentifier(event.pubkey)
    }

    private static func handle(for event: NostrEvent, profile: NostrProfile?) -> String {
        if let name = profile?.name?.trimmed, !name.isEmpty {
            let normalized = name.replacingOccurrences(of: " ", with: "")
            return "@\(normalized.lowercased())"
        }
        return "@\(shortNostrIdentifier(event.pubkey).lowercased())"
    }

    private static func avatarURL(for profile: NostrProfile?) -> URL? {
        profile?.resolvedAvatarURL
    }

    private static func mergedAssociatedProfile(
        selectedEvent: NostrEvent?,
        preferredEvent: NostrEvent?,
        preferredProfile: NostrProfile?,
        fallbackEvent: NostrEvent?,
        fallbackProfile: NostrProfile?
    ) -> NostrProfile? {
        guard let selectedEvent else { return nil }
        let selectedEventID = normalizedEventID(selectedEvent)

        if let preferredProfile,
           normalizedEventID(preferredEvent) == selectedEventID {
            return preferredProfile
        }

        if let fallbackProfile,
           normalizedEventID(fallbackEvent) == selectedEventID {
            return fallbackProfile
        }

        return nil
    }

    private static func normalizedEventID(_ event: NostrEvent?) -> String? {
        guard let event else { return nil }
        let normalized = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

enum ReplyCountEstimator {
    static func counts(for items: [FeedItem]) -> [String: Int] {
        let candidateEventIDs = Set(items.map { $0.displayEventID.lowercased() })
        guard !candidateEventIDs.isEmpty else { return [:] }

        var counts: [String: Int] = [:]
        for item in items {
            guard item.event.isReplyNote else { continue }
            guard let targetEventID = repliedEventID(for: item.event, validEventIDs: candidateEventIDs) else { continue }
            counts[targetEventID, default: 0] += 1
        }

        return counts
    }

    static func repliedEventID(
        for event: NostrEvent,
        validEventIDs: Set<String>
    ) -> String? {
        if let rootID = normalized(event.rootEventReferenceID),
           validEventIDs.contains(rootID) {
            return rootID
        }

        if let lastID = normalized(event.lastEventReferenceID),
           validEventIDs.contains(lastID) {
            return lastID
        }

        for referenceID in event.eventReferenceIDs {
            let normalizedReferenceID = referenceID.lowercased()
            if validEventIDs.contains(normalizedReferenceID) {
                return normalizedReferenceID
            }
        }

        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum MediaDetection {
    static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static let mediaExtensions: Set<String> = [
        ".jpg",
        ".jpeg",
        ".png",
        ".gif",
        ".webp",
        ".heic",
        ".svg",
        ".mp4",
        ".webm",
        ".ogg",
        ".mov",
        ".m3u8",
        ".mp3",
        ".wav",
        ".flac",
        ".aac",
        ".m4a",
        ".opus",
        ".wma"
    ]
}

private enum NSFWHashtagDetection {
    // Keep this internal and non-user-facing. The settings toggle is intentionally simple.
    static let blockedHashtags: Set<String> = [
        "nsfw", "18plus", "18+", "adult", "xxx", "porn", "pornography", "softporn", "hardcore",
        "explicit", "nude", "nudity", "nudes", "naked", "boobs", "tits", "ass", "booty",
        "bikini", "lingerie", "cameltoe", "upskirt", "downblouse", "underboob", "sideboob",
        "nipples", "areola", "cleavage", "thirsttrap", "sexy", "hotgirls", "hotgirl", "hotwife",
        "milf", "gilf", "cougar", "stepmom", "stepsis", "stepbro", "blowjob", "bj", "deepthroat",
        "handjob", "hjob", "footjob", "rimjob", "anal", "creampie", "cum", "cumming", "squirt",
        "orgasm", "masturbation", "masturbate", "dildo", "vibrator", "fleshlight", "fetish",
        "kink", "kinky", "bdsm", "dom", "dominatrix", "sub", "submission", "bondage", "spanking",
        "choking", "degradation", "voyeur", "exhibitionism", "incest", "hentai", "ecchi",
        "rule34", "onlyfans", "fansly", "camgirl", "cams", "webcam", "escort", "erotic",
        "horny", "slut", "whore", "hookup", "sex", "sexual", "nsfl", "goreporn", "rape", "r34"
    ]

    private static let hashtagRegex = try? NSRegularExpression(pattern: "#([\\p{L}\\p{N}_-]{2,64})")

    static func extractHashtags(from content: String) -> [String] {
        guard let hashtagRegex else { return [] }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = hashtagRegex.matches(in: content, options: [], range: range)

        return matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: content) else {
                return nil
            }
            return String(content[range])
        }
    }

    static func matches(_ hashtags: [String]) -> Bool {
        for hashtag in hashtags {
            let normalized = normalize(hashtag)
            guard !normalized.isEmpty else { continue }

            if blockedHashtags.contains(normalized) {
                return true
            }

            if normalized.hasPrefix("nsfw"),
               normalized.count <= 16 {
                return true
            }

            if normalized.hasPrefix("porn"),
               normalized.count <= 20 {
                return true
            }
        }
        return false
    }

    private static func normalize(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}_+\\-]", with: "", options: .regularExpression)
    }
}

enum LocalPublicationState: Equatable, Sendable {
    case publishing
    case posted
    case failed(message: String?)

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

struct LocalPublicationRecord: Identifiable, Equatable, Sendable {
    let item: FeedItem
    let state: LocalPublicationState
    let updatedAt: Date

    var id: String {
        item.id
    }

    func merged(with incomingItem: FeedItem) -> LocalPublicationRecord {
        LocalPublicationRecord(
            item: item.merged(with: incomingItem),
            state: state,
            updatedAt: updatedAt
        )
    }
}

@MainActor
final class LocalPublicationStore: ObservableObject {
    static let shared = LocalPublicationStore()

    @Published private(set) var recordsByID: [String: LocalPublicationRecord] = [:]

    var items: [FeedItem] {
        records.sorted { lhs, rhs in
            Self.isOrderedBefore(lhs.item, rhs.item)
        }
        .map(\.item)
    }

    var records: [LocalPublicationRecord] {
        Array(recordsByID.values)
    }

    func record(for eventID: String) -> LocalPublicationRecord? {
        recordsByID[normalizeEventID(eventID)]
    }

    func records(matching predicate: (FeedItem) -> Bool) -> [LocalPublicationRecord] {
        records
            .filter { predicate($0.item) }
            .sorted { lhs, rhs in
                Self.isOrderedBefore(lhs.item, rhs.item)
            }
    }

    func registerPublishing(item: FeedItem) {
        upsert(item: item, state: .publishing)
    }

    func markPosted(eventID: String) {
        update(eventID: eventID) { record in
            LocalPublicationRecord(
                item: record.item,
                state: .posted,
                updatedAt: Date()
            )
        }
    }

    func markFailed(eventID: String, message: String?) {
        update(eventID: eventID) { record in
            LocalPublicationRecord(
                item: record.item,
                state: .failed(message: message),
                updatedAt: Date()
            )
        }
    }

    func mergeFetchedItems(_ items: [FeedItem]) {
        guard !items.isEmpty else { return }

        var nextRecordsByID = recordsByID
        var didChange = false
        for item in items {
            let normalizedID = normalizeEventID(item.id)
            guard let existing = nextRecordsByID[normalizedID] else { continue }
            nextRecordsByID[normalizedID] = existing.merged(with: item)
            didChange = true
        }

        if didChange {
            recordsByID = nextRecordsByID
        }
    }

    func clearForTesting() {
        recordsByID = [:]
    }

    private func upsert(item: FeedItem, state: LocalPublicationState) {
        let normalizedID = normalizeEventID(item.id)
        var nextRecordsByID = recordsByID
        if let existing = nextRecordsByID[normalizedID] {
            nextRecordsByID[normalizedID] = LocalPublicationRecord(
                item: existing.item.merged(with: item),
                state: state,
                updatedAt: Date()
            )
        } else {
            nextRecordsByID[normalizedID] = LocalPublicationRecord(
                item: item,
                state: state,
                updatedAt: Date()
            )
        }
        recordsByID = nextRecordsByID
    }

    private func update(
        eventID: String,
        transform: (LocalPublicationRecord) -> LocalPublicationRecord
    ) {
        let normalizedID = normalizeEventID(eventID)
        guard let existing = recordsByID[normalizedID] else { return }
        var nextRecordsByID = recordsByID
        nextRecordsByID[normalizedID] = transform(existing)
        recordsByID = nextRecordsByID
    }

    private func normalizeEventID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isOrderedBefore(_ lhs: FeedItem, _ rhs: FeedItem) -> Bool {
        if lhs.event.createdAt == rhs.event.createdAt {
            return lhs.id > rhs.id
        }
        return lhs.event.createdAt > rhs.event.createdAt
    }
}
