import Foundation
import NostrSDK

enum NoteContentTokenType: Hashable {
    case text
    case url
    case websocketURL
    case nostrMention
    case nostrEvent
    case hashtag
    case emoji
    case image
    case video
    case youtubeVideo
    case audio
}

struct NoteContentToken: Hashable {
    let type: NoteContentTokenType
    let value: String
}

struct YouTubeVideoEmbed: Hashable, Sendable {
    let videoID: String
    let originalURL: URL
    let startSeconds: Int?

    func embedURL(autoplay: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/embed/\(videoID)"

        var queryItems = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0")
        ]
        if autoplay {
            queryItems.append(URLQueryItem(name: "autoplay", value: "1"))
        }
        if let startSeconds, startSeconds > 0 {
            queryItems.append(URLQueryItem(name: "start", value: "\(startSeconds)"))
        }
        components.queryItems = queryItems

        return components.url
    }
}

struct NostrEventReferencePointer: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case eventID(String)
        case replaceable(kind: Int, pubkey: String, identifier: String)
    }

    let normalizedIdentifier: String
    let target: Target
    let relayHints: [URL]
    let authorPubkey: String?

    var eventID: String? {
        guard case .eventID(let eventID) = target else { return nil }
        return eventID
    }

    var targetPubkey: String? {
        switch target {
        case .eventID:
            return authorPubkey
        case .replaceable(_, let pubkey, _):
            return pubkey
        }
    }
}

enum NoteContentParser {
    private enum CandidateType {
        case httpURL
        case websocketURL
        case nostrURI
        case hashtag
        case emoji
    }

    private struct ReferenceMetadataDecoder: MetadataCoding {}

    private struct Candidate {
        let range: NSRange
        let value: String
        let type: CandidateType
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static let websocketRegex = try? NSRegularExpression(
        pattern: #"wss?:\/\/[^\s]+"#,
        options: [.caseInsensitive]
    )

    // Mirrors Flow web combined matching for both `nostr:` URIs and bare bech32 IDs.
    private static let nostrReferenceRegex = try? NSRegularExpression(
        pattern: #"(?:nostr:)?(npub1[a-z0-9]{58}|nprofile1[a-z0-9]+|note1[a-z0-9]{58}|nevent1[a-z0-9]+|naddr1[a-z0-9]+|nrelay1[a-z0-9]+)"#,
        options: [.caseInsensitive]
    )
    
    private static let hashtagRegex = try? NSRegularExpression(
        pattern: #"#[\p{L}\p{N}\p{M}_]+"#,
        options: []
    )

    private static let emojiShortcodeRegex = try? NSRegularExpression(
        pattern: #":[^\s:]{1,64}:"#,
        options: []
    )

    private static let trailingURLPunctuation = CharacterSet(charactersIn: #".,;:'")]}!?，。；："'！？】）"#)

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "svg"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "webm", "ogg", "mov", "m3u8"
    ]

    private static let hlsMimeTypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "application/mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl"
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "flac", "aac", "m4a", "opus", "wma"
    ]

    static func tokenize(event: NostrEvent) -> [NoteContentToken] {
        let baseTokens = tokenize(content: event.content)
        let mediaAwareTokens = appendImetaMediaIfNeeded(tokens: baseTokens, tags: event.tags)
        return appendQuotedReferencesIfNeeded(tokens: mediaAwareTokens, tags: event.tags)
    }

    static func tokenize(content: String) -> [NoteContentToken] {
        guard !content.isEmpty else { return [] }
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var candidates: [Candidate] = []

        if let linkDetector {
            let matches = linkDetector.matches(in: content, options: [], range: fullRange)
            for match in matches {
                guard let url = match.url else { continue }
                let scheme = url.scheme?.lowercased() ?? ""
                guard scheme == "http" || scheme == "https" else { continue }
                let raw = nsContent.substring(with: match.range)
                let sanitized = trimTrailingPunctuation(raw)
                let adjustedLength = (sanitized as NSString).length
                guard adjustedLength > 0 else { continue }
                candidates.append(
                    Candidate(
                        range: NSRange(location: match.range.location, length: adjustedLength),
                        value: sanitized,
                        type: .httpURL
                    )
                )
            }
        }

        if let websocketRegex {
            let matches = websocketRegex.matches(in: content, options: [], range: fullRange)
            for match in matches {
                let raw = nsContent.substring(with: match.range)
                let sanitized = trimTrailingPunctuation(raw)
                let adjustedLength = (sanitized as NSString).length
                guard adjustedLength > 0 else { continue }
                candidates.append(
                    Candidate(
                        range: NSRange(location: match.range.location, length: adjustedLength),
                        value: sanitized,
                        type: .websocketURL
                    )
                )
            }
        }

        if let nostrReferenceRegex {
            let matches = nostrReferenceRegex.matches(in: content, options: [], range: fullRange)
            for match in matches {
                candidates.append(
                    Candidate(
                        range: match.range,
                        value: nsContent.substring(with: match.range),
                        type: .nostrURI
                    )
                )
            }
        }
        
        if let hashtagRegex {
            let matches = hashtagRegex.matches(in: content, options: [], range: fullRange)
            for match in matches {
                candidates.append(
                    Candidate(
                        range: match.range,
                        value: nsContent.substring(with: match.range),
                        type: .hashtag
                    )
                )
            }
        }

        if let emojiShortcodeRegex {
            let matches = emojiShortcodeRegex.matches(in: content, options: [], range: fullRange)
            for match in matches {
                candidates.append(
                    Candidate(
                        range: match.range,
                        value: nsContent.substring(with: match.range),
                        type: .emoji
                    )
                )
            }
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }

        var tokens: [NoteContentToken] = []
        var cursor = 0

        for candidate in sortedCandidates {
            guard candidate.range.location >= cursor else {
                continue
            }

            if candidate.range.location > cursor {
                let textRange = NSRange(location: cursor, length: candidate.range.location - cursor)
                let textChunk = nsContent.substring(with: textRange)
                if !textChunk.isEmpty {
                    tokens.append(NoteContentToken(type: .text, value: textChunk))
                }
            }

            if let token = token(from: candidate) {
                tokens.append(token)
            } else {
                tokens.append(NoteContentToken(type: .text, value: candidate.value))
            }
            cursor = candidate.range.location + candidate.range.length
        }

        if cursor < nsContent.length {
            let tail = nsContent.substring(from: cursor)
            if !tail.isEmpty {
                tokens.append(NoteContentToken(type: .text, value: tail))
            }
        }

        return mergeConsecutiveTextTokens(tokens)
    }

    static func njumpURL(for nostrURIOrIdentifier: String) -> URL? {
        guard let identifier = nostrIdentifier(from: nostrURIOrIdentifier) else { return nil }
        guard !identifier.isEmpty else { return nil }
        let shareableIdentifier: String
        if let eventID = canonicalEventID(from: identifier),
           let neventIdentifier = encodedNeventIdentifier(forEventID: eventID) {
            shareableIdentifier = neventIdentifier
        } else {
            shareableIdentifier = identifier
        }
        return URL(string: "https://nlink.to/\(shareableIdentifier)")
    }

    static func neventIdentifier(for event: NostrEvent, relayHints: [URL] = []) -> String? {
        encodedNeventIdentifier(
            forEventID: event.id.lowercased(),
            authorPubkey: event.pubkey.lowercased(),
            kind: event.kind,
            relayHints: relayHints
        )
    }

    static func normalizedNostrReferenceIdentifier(from raw: String) -> String {
        normalizeReferenceValue(raw)
    }

    static func eventReferencePointer(from raw: String) -> NostrEventReferencePointer? {
        let normalized = normalizeReferenceValue(raw)
        guard !normalized.isEmpty else { return nil }

        if isHex64(normalized) {
            return NostrEventReferencePointer(
                normalizedIdentifier: normalized,
                target: .eventID(normalized),
                relayHints: [],
                authorPubkey: nil
            )
        }

        if normalized.hasPrefix("note1"),
           let eventID = decodedNoteIdentifier(normalized) {
            return NostrEventReferencePointer(
                normalizedIdentifier: normalized,
                target: .eventID(eventID),
                relayHints: [],
                authorPubkey: nil
            )
        }

        if let coordinate = parseReplaceableCoordinate(from: normalized) {
            return NostrEventReferencePointer(
                normalizedIdentifier: normalized,
                target: .replaceable(
                    kind: coordinate.kind,
                    pubkey: coordinate.pubkey,
                    identifier: coordinate.identifier
                ),
                relayHints: [],
                authorPubkey: coordinate.pubkey
            )
        }

        if normalized.hasPrefix("nevent1") || normalized.hasPrefix("naddr1") {
            let decoder = ReferenceMetadataDecoder()
            guard let metadata = try? decoder.decodedMetadata(from: normalized) else {
                return nil
            }

            let relayHints = relayHintURLs(from: metadata.relays ?? [])
            let authorPubkey: String?
            if let pubkey = metadata.pubkey?.lowercased(), isHex64(pubkey) {
                authorPubkey = pubkey
            } else {
                authorPubkey = nil
            }

            if let eventID = metadata.eventId?.lowercased(),
               isHex64(eventID) {
                return NostrEventReferencePointer(
                    normalizedIdentifier: normalized,
                    target: .eventID(eventID),
                    relayHints: relayHints,
                    authorPubkey: authorPubkey
                )
            }

            if let kind = metadata.kind,
               let pubkey = authorPubkey,
               let identifier = metadata.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !identifier.isEmpty {
                return NostrEventReferencePointer(
                    normalizedIdentifier: normalized,
                    target: .replaceable(kind: Int(kind), pubkey: pubkey, identifier: identifier),
                    relayHints: relayHints,
                    authorPubkey: pubkey
                )
            }
        }

        return nil
    }

    static func relayHintURL(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isSupportedRelayHint(trimmed) else { return nil }
        return URL(string: trimmed)
    }
    
    static func hashtagActionURL(for tokenValue: String) -> URL? {
        guard let normalized = normalizedHashtag(from: tokenValue), !normalized.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "x21-hashtag"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "t", value: normalized)]
        return components.url
    }
    
    static func hashtagFromActionURL(_ url: URL) -> String? {
        guard url.scheme == "x21-hashtag" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let value = components.queryItems?.first(where: { $0.name == "t" })?.value
        guard let value, !value.isEmpty else { return nil }
        return value.lowercased()
    }

    static func profileActionURL(for pubkey: String) -> URL? {
        let normalized = pubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "x21-profile"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "pubkey", value: normalized)]
        return components.url
    }

    static func profilePubkey(fromActionURL url: URL) -> String? {
        guard url.scheme == "x21-profile" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let pubkey = components.queryItems?.first(where: { $0.name == "pubkey" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let pubkey, !pubkey.isEmpty else { return nil }
        return pubkey
    }

    static func lastWebsiteURL(in tokens: [NoteContentToken]) -> URL? {
        for token in tokens.reversed() where token.type == .url {
            if let url = webURL(from: token.value) {
                return url
            }
        }
        return nil
    }

    static func webURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimTrailingPunctuation(trimmed)
        guard !sanitized.isEmpty else { return nil }

        if let url = URL(string: sanitized),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        return URL(string: "https://\(sanitized)")
    }

    static func youtubeVideoEmbed(from urlString: String) -> YouTubeVideoEmbed? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = webURL(from: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            return nil
        }

        let pathSegments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        let rawVideoID: String?
        if host == "youtu.be" {
            rawVideoID = pathSegments.first
        } else if isYouTubeHost(host) {
            switch pathSegments.first?.lowercased() {
            case "watch":
                rawVideoID = queryValue(named: "v", in: components)
            case "embed", "shorts", "live":
                rawVideoID = pathSegments.dropFirst().first
            default:
                rawVideoID = nil
            }
        } else {
            rawVideoID = nil
        }

        guard let videoID = sanitizedYouTubeVideoID(rawVideoID) else { return nil }
        return YouTubeVideoEmbed(
            videoID: videoID,
            originalURL: url,
            startSeconds: youtubeStartSeconds(in: components)
        )
    }

    static func imageURLs(in event: NostrEvent) -> [URL] {
        let tokens = tokenize(event: event)
        var seen = Set<String>()
        var ordered: [URL] = []

        for token in tokens where token.type == .image {
            guard let url = webURL(from: token.value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }

            let normalized = url.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(url)
        }

        return ordered
    }

    private static func token(from candidate: Candidate) -> NoteContentToken? {
        switch candidate.type {
        case .nostrURI:
            guard let identifier = nostrIdentifier(from: candidate.value) else {
                return NoteContentToken(type: .text, value: candidate.value)
            }
            if isProfileIdentifier(identifier) {
                return NoteContentToken(type: .nostrMention, value: identifier)
            }
            if isEventIdentifier(identifier) {
                return NoteContentToken(type: .nostrEvent, value: identifier)
            }
            if isRelayIdentifier(identifier) {
                // Keep relay references tappable through the same external flow used for other nostr references.
                return NoteContentToken(type: .nostrMention, value: identifier)
            }
            return NoteContentToken(type: .text, value: candidate.value)
        case .hashtag:
            guard let normalized = normalizedHashtag(from: candidate.value), !normalized.isEmpty else {
                return NoteContentToken(type: .text, value: candidate.value)
            }
            return NoteContentToken(type: .hashtag, value: "#\(normalized)")
        case .emoji:
            return NoteContentToken(type: .emoji, value: candidate.value)
        case .websocketURL:
            return NoteContentToken(type: .websocketURL, value: candidate.value)
        case .httpURL:
            if youtubeVideoEmbed(from: candidate.value) != nil {
                return NoteContentToken(type: .youtubeVideo, value: candidate.value)
            }
            let mediaType = classifyMediaType(urlString: candidate.value, mimeType: nil)
            switch mediaType {
            case .image:
                return NoteContentToken(type: .image, value: candidate.value)
            case .video:
                return NoteContentToken(type: .video, value: candidate.value)
            case .audio:
                return NoteContentToken(type: .audio, value: candidate.value)
            case .none:
                return NoteContentToken(type: .url, value: candidate.value)
            }
        }
    }

    private static func mergeConsecutiveTextTokens(_ tokens: [NoteContentToken]) -> [NoteContentToken] {
        var merged: [NoteContentToken] = []

        for token in tokens {
            guard token.type == .text else {
                merged.append(token)
                continue
            }

            if let last = merged.last, last.type == .text {
                merged[merged.count - 1] = NoteContentToken(type: .text, value: last.value + token.value)
            } else {
                merged.append(token)
            }
        }

        return merged
    }

    private static func trimTrailingPunctuation(_ raw: String) -> String {
        var scalarView = raw.unicodeScalars
        while let last = scalarView.last, trailingURLPunctuation.contains(last) {
            scalarView.removeLast()
        }
        return String(String.UnicodeScalarView(scalarView))
    }

    private static func nostrIdentifier(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("nostr:") {
            let identifier = String(lowered.dropFirst("nostr:".count))
            return identifier.isEmpty ? nil : identifier
        }
        return lowered
    }

    private static func isProfileIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("npub1") || identifier.hasPrefix("nprofile1")
    }

    private static func isEventIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("note1") || identifier.hasPrefix("nevent1") || identifier.hasPrefix("naddr1")
    }

    private static func isRelayIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("nrelay1")
    }
    
    private static func normalizedHashtag(from tokenValue: String) -> String? {
        let trimmed = tokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutHash: String
        if trimmed.hasPrefix("#") {
            withoutHash = String(trimmed.dropFirst())
        } else {
            withoutHash = trimmed
        }
        let normalized = withoutHash.lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func appendImetaMediaIfNeeded(
        tokens: [NoteContentToken],
        tags: [[String]]
    ) -> [NoteContentToken] {
        var result = tokens
        var existingURLs = Set(
            tokens.filter { $0.type != .text }.map(\.value)
        )

        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "imeta" else { continue }

            var urlString: String?
            var mimeType: String?
            for value in tag.dropFirst() {
                if value.hasPrefix("url ") {
                    urlString = String(value.dropFirst(4))
                } else if value.hasPrefix("m ") {
                    mimeType = String(value.dropFirst(2)).lowercased()
                }
            }

            guard let urlString, !urlString.isEmpty else { continue }
            guard !existingURLs.contains(urlString) else { continue }

            let tokenType: NoteContentTokenType
            if youtubeVideoEmbed(from: urlString) != nil {
                tokenType = .youtubeVideo
            } else {
                let mediaType = classifyMediaType(urlString: urlString, mimeType: mimeType)
                switch mediaType {
                case .image:
                    tokenType = .image
                case .video:
                    tokenType = .video
                case .audio:
                    tokenType = .audio
                case .none:
                    tokenType = .url
                }
            }

            if let last = result.last, last.type != .text {
                result.append(NoteContentToken(type: .text, value: "\n"))
            }
            result.append(NoteContentToken(type: tokenType, value: urlString))
            existingURLs.insert(urlString)
        }

        return mergeConsecutiveTextTokens(result)
    }

    private static func appendQuotedReferencesIfNeeded(
        tokens: [NoteContentToken],
        tags: [[String]]
    ) -> [NoteContentToken] {
        var result = tokens
        var existingReferences = Set(
            tokens
                .filter { $0.type == .nostrEvent }
                .map { referenceDeduplicationKey(for: $0.value) }
                .filter { !$0.isEmpty }
        )

        for tag in tags {
            guard tag.count > 1 else { continue }
            guard let name = tag.first?.lowercased() else { continue }

            let value = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let marker = tag.count > 3 ? tag[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
            let isQuoteReferenceTag = name == "q"
            let isMentionedEventTag = name == "e" && marker == "mention"
            let isMentionedAddressTag = name == "a" && marker == "mention"
            guard isQuoteReferenceTag || isMentionedEventTag || isMentionedAddressTag else { continue }

            let rawNormalized = normalizeReferenceValue(value)
            let tagRelayHint = relayHintURL(from: tag.count > 2 ? tag[2] : nil)
            let tagAuthorHint = referencedEventAuthorHint(in: tag, tagName: name)
            let normalized: String
            if let eventID = canonicalEventID(from: rawNormalized),
               (tagRelayHint != nil || tagAuthorHint != nil),
               let hintedIdentifier = encodedNeventIdentifier(
                    forEventID: eventID,
                    authorPubkey: tagAuthorHint,
                    relayHints: [tagRelayHint].compactMap { $0 }
               ) {
                normalized = hintedIdentifier
            } else {
                normalized = rawNormalized
            }

            guard isRenderableReference(normalized) else { continue }
            let deduplicationKey = referenceDeduplicationKey(for: normalized)
            guard existingReferences.insert(deduplicationKey).inserted else { continue }

            if let last = result.last, last.type != .text {
                result.append(NoteContentToken(type: .text, value: "\n"))
            }
            result.append(NoteContentToken(type: .nostrEvent, value: normalized))
        }

        return mergeConsecutiveTextTokens(result)
    }

    private static func normalizeReferenceValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("nostr:") {
            return String(trimmed.dropFirst("nostr:".count))
        }
        return trimmed
    }

    private static func referenceDeduplicationKey(for raw: String) -> String {
        let normalized = normalizeReferenceValue(raw)
        guard !normalized.isEmpty else { return normalized }

        if let eventID = canonicalEventID(from: normalized) {
            return "event:\(eventID)"
        }

        if let coordinate = canonicalReplaceableCoordinate(from: normalized) {
            return "replaceable:\(coordinate.kind):\(coordinate.pubkey):\(coordinate.identifier)"
        }

        return normalized
    }

    private static func canonicalEventID(from normalized: String) -> String? {
        if isHex64(normalized) {
            return normalized
        }

        if normalized.hasPrefix("note1") {
            return decodedNoteIdentifier(normalized)
        }

        if normalized.hasPrefix("nevent1") {
            let decoder = ReferenceMetadataDecoder()
            guard let metadata = try? decoder.decodedMetadata(from: normalized),
                  let eventID = metadata.eventId?.lowercased(),
                  isHex64(eventID) else {
                return nil
            }
            return eventID
        }

        return nil
    }

    private static func canonicalReplaceableCoordinate(from normalized: String) -> (kind: Int, pubkey: String, identifier: String)? {
        if let coordinate = parseReplaceableCoordinate(from: normalized) {
            return coordinate
        }

        guard normalized.hasPrefix("naddr1") else { return nil }

        let decoder = ReferenceMetadataDecoder()
        guard let metadata = try? decoder.decodedMetadata(from: normalized),
              let kind = metadata.kind,
              let pubkey = metadata.pubkey?.lowercased(),
              isHex64(pubkey),
              let identifier = metadata.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }

        return (Int(kind), pubkey, identifier)
    }

    private static func parseReplaceableCoordinate(from value: String) -> (kind: Int, pubkey: String, identifier: String)? {
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let kind = Int(parts[0]), kind >= 0 else { return nil }

        let pubkey = String(parts[1]).lowercased()
        guard isHex64(pubkey) else { return nil }

        let identifier = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        return (kind, pubkey, identifier)
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" ||
        host.hasSuffix(".youtube.com") ||
        host == "youtube-nocookie.com" ||
        host.hasSuffix(".youtube-nocookie.com")
    }

    private static func queryValue(named name: String, in components: URLComponents) -> String? {
        components.queryItems?
            .first { $0.name.lowercased() == name.lowercased() }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedYouTubeVideoID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let scalars = trimmed.unicodeScalars.prefix { allowed.contains($0) }
        let videoID = String(String.UnicodeScalarView(scalars))
        guard videoID.count == 11 else { return nil }
        return videoID
    }

    private static func youtubeStartSeconds(in components: URLComponents) -> Int? {
        if let start = queryValue(named: "start", in: components),
           let seconds = Int(start),
           seconds > 0 {
            return seconds
        }
        if let timestamp = queryValue(named: "t", in: components) {
            return parseYouTubeTimestamp(timestamp)
        }
        return nil
    }

    private static func parseYouTubeTimestamp(_ rawValue: String) -> Int? {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        let numericValue = trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
        if let seconds = Int(numericValue), seconds > 0 {
            return seconds
        }

        var total = 0
        var currentNumber = ""
        var consumedUnit = false

        for character in trimmed {
            if character.isNumber {
                currentNumber.append(character)
                continue
            }

            guard let value = Int(currentNumber) else {
                currentNumber = ""
                continue
            }

            switch character {
            case "h":
                total += value * 60 * 60
                consumedUnit = true
            case "m":
                total += value * 60
                consumedUnit = true
            case "s":
                total += value
                consumedUnit = true
            default:
                break
            }
            currentNumber = ""
        }

        if !consumedUnit, let seconds = Int(currentNumber), seconds > 0 {
            return seconds
        }

        return total > 0 ? total : nil
    }

    private static func decodedNoteIdentifier(_ identifier: String) -> String? {
        let normalized = normalizeReferenceValue(identifier)
        guard normalized.hasPrefix("note1") else { return nil }
        guard let separatorIndex = normalized.lastIndex(of: "1") else { return nil }

        let prefix = String(normalized[..<separatorIndex])
        guard prefix == "note" else { return nil }

        let payloadStart = normalized.index(after: separatorIndex)
        let payload = normalized[payloadStart...]
        guard payload.count > 6 else { return nil }

        let checksumlessPayload = payload.dropLast(6)
        let values = checksumlessPayload.compactMap { bech32Alphabet[$0] }
        guard values.count == checksumlessPayload.count else { return nil }
        guard let decoded = dataFromBase32(values), decoded.count == 32 else { return nil }

        return decoded.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodedNeventIdentifier(
        forEventID eventID: String,
        authorPubkey: String? = nil,
        kind: Int? = nil,
        relayHints: [URL] = []
    ) -> String? {
        let normalizedEventID = eventID.lowercased()
        guard isHex64(normalizedEventID), let eventData = dataFromHex(normalizedEventID) else { return nil }

        var tlv = Data()
        appendTLV(type: 0, value: eventData, to: &tlv)

        for relayHint in normalizedRelayHints(relayHints).prefix(3) {
            let relayData = Data(relayHint.utf8)
            appendTLV(type: 1, value: relayData, to: &tlv)
        }

        if let authorPubkey {
            let normalizedAuthorPubkey = authorPubkey.lowercased()
            if isHex64(normalizedAuthorPubkey), let authorData = dataFromHex(normalizedAuthorPubkey) {
                appendTLV(type: 2, value: authorData, to: &tlv)
            }
        }

        if let kind, kind >= 0, let encodedKind = encodedUInt32(kind) {
            appendTLV(type: 3, value: encodedKind, to: &tlv)
        }

        let payload = base32FromBase8Data(tlv)
        return bech32Encode(hrp: "nevent", payload: payload)
    }

    private static func appendTLV(type: UInt8, value: Data, to data: inout Data) {
        guard !value.isEmpty, value.count <= Int(UInt8.max) else { return }
        data.append(type)
        data.append(UInt8(value.count))
        data.append(value)
    }

    private static func normalizedRelayHints(_ relayHints: [URL]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for relayHint in relayHints {
            guard let scheme = relayHint.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else { continue }

            let value = relayHint.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            normalized.append(value)
        }

        return normalized
    }

    private static func relayHintURLs(from rawRelays: [String]) -> [URL] {
        var seen = Set<String>()
        var relayHints: [URL] = []

        for rawRelay in rawRelays {
            guard let relayURL = relayHintURL(from: rawRelay) else { continue }
            let key = relayURL.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            relayHints.append(relayURL)
        }

        return relayHints
    }

    private static func referencedEventAuthorHint(in tag: [String], tagName: String) -> String? {
        let candidate: String?
        switch tagName {
        case "q":
            candidate = tag.count > 3 ? tag[3] : nil
        case "e":
            candidate = tag.count > 4 ? tag[4] : nil
        default:
            candidate = nil
        }

        guard let normalized = candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              isHex64(normalized) else {
            return nil
        }
        return normalized
    }

    private static func isSupportedRelayHint(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("ws://") || normalized.hasPrefix("wss://")
    }

    private static func encodedUInt32(_ value: Int) -> Data? {
        guard value <= Int(UInt32.max) else { return nil }
        let unsignedValue = UInt32(value)
        return Data([
            UInt8((unsignedValue >> 24) & 0xff),
            UInt8((unsignedValue >> 16) & 0xff),
            UInt8((unsignedValue >> 8) & 0xff),
            UInt8(unsignedValue & 0xff)
        ])
    }

    private static func dataFromBase32(_ values: [UInt8]) -> Data? {
        var accumulator: UInt32 = 0
        var bitCount = 0
        var output = Data()

        for value in values {
            accumulator = (accumulator << 5) | UInt32(value)
            bitCount += 5

            while bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((accumulator >> UInt32(bitCount)) & 0xff))
            }
        }

        guard bitCount < 5 else { return nil }
        let remainderMask = bitCount == 0 ? UInt32(0) : (UInt32(1) << UInt32(bitCount)) - 1
        guard (accumulator & remainderMask) == 0 else { return nil }

        return output
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var cursor = hex.startIndex

        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            data.append(byte)
            cursor = next
        }

        return data
    }

    private static func base32FromBase8Data(_ data: Data) -> [UInt8] {
        var accumulator: UInt32 = 0
        var bitCount = 0
        var output: [UInt8] = []

        for byte in data {
            accumulator = (accumulator << 8) | UInt32(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                output.append(UInt8((accumulator >> UInt32(bitCount)) & 0x1f))
            }
        }

        if bitCount > 0 {
            output.append(UInt8((accumulator << UInt32(5 - bitCount)) & 0x1f))
        }

        return output
    }

    private static func bech32Encode(hrp: String, payload: [UInt8]) -> String {
        let checksum = bech32CreateChecksum(hrp: hrp, payload: payload)
        let combined = payload + checksum
        let characters = combined.map { bech32CharacterSet[Int($0)] }
        return hrp + "1" + String(characters)
    }

    private static func bech32CreateChecksum(hrp: String, payload: [UInt8]) -> [UInt8] {
        var values = bech32ExpandHrp(hrp)
        values.append(contentsOf: payload)
        values.append(contentsOf: Array(repeating: 0, count: 6))

        let polymod = bech32Polymod(values) ^ 1
        return (0..<6).map { index in
            UInt8((polymod >> UInt32(5 * (5 - index))) & 0x1f)
        }
    }

    private static func bech32ExpandHrp(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 0x1f }
    }

    private static func bech32Polymod(_ values: [UInt8]) -> UInt32 {
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var checksum: UInt32 = 1

        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ UInt32(value)

            for index in 0..<5 where ((top >> UInt32(index)) & 1) != 0 {
                checksum ^= generators[index]
            }
        }

        return checksum
    }

    private static func isHex64(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static let bech32Alphabet: [Character: UInt8] = {
        let characters = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        return Dictionary(uniqueKeysWithValues: characters.enumerated().map { ($1, UInt8($0)) })
    }()

    private static let bech32CharacterSet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static func isRenderableReference(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        if isEventIdentifier(value) {
            return true
        }

        // Hex event IDs often appear in `q`/`e` tags.
        if value.count == 64,
           value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) {
            return true
        }

        // Replaceable coordinates from `a`/`q` tags: "<kind>:<pubkey>:<identifier>".
        let pieces = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if pieces.count == 3,
           Int(pieces[0]) != nil,
           pieces[1].count == 64 {
            return true
        }

        return false
    }

    private enum ParsedMediaType {
        case image
        case video
        case audio
    }

    private static func classifyMediaType(urlString: String, mimeType: String?) -> ParsedMediaType? {
        if let mimeType {
            let normalizedMIMEType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedMIMEType.hasPrefix("image/") { return .image }
            if normalizedMIMEType.hasPrefix("video/") || hlsMimeTypes.contains(normalizedMIMEType) {
                return .video
            }
            if normalizedMIMEType.hasPrefix("audio/") { return .audio }
        }

        guard let url = webURL(from: urlString) else { return nil }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }
}
