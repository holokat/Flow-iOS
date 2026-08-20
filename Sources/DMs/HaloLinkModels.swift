import Foundation

enum HaloLinkInboxTab: String, CaseIterable, Identifiable {
    case conversations
    case requests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversations:
            return "Conversations"
        case .requests:
            return "Requests"
        }
    }
}

struct HaloLinkThreadRoute: Hashable, Identifiable {
    let participantPubkeys: [String]

    var id: String {
        HaloLinkSupport.conversationID(for: participantPubkeys)
    }
}

struct HaloLinkComposerAttachmentPayload: Hashable, Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String
}

struct HaloLinkEncryptedAttachmentUploadMetadata: Hashable, Sendable {
    let encryptedHash: String
    let originalHash: String
    let decryptionKeyBase64: String
    let decryptionNonceBase64: String
    let encryptedSize: Int
}

struct HaloLinkPreparedAttachmentUpload: Hashable, Sendable {
    let remoteURL: URL
    let mimeType: String
    let uploadMetadata: [String]
    let encryptedMetadata: HaloLinkEncryptedAttachmentUploadMetadata?
}

struct HaloLinkPreparedComposerAttachment: Hashable, Sendable {
    let payload: HaloLinkComposerAttachmentPayload
    let upload: HaloLinkPreparedAttachmentUpload
}

struct HaloLinkMessage: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let wrapID: String
    let createdAt: Int
    let senderPubkey: String
    let recipientPubkeys: [String]
    let participantPubkeys: [String]
    let conversationID: String
    let isOutgoing: Bool
    let kind: Int
    let tags: [[String]]
    let content: String
    let subject: String?
    let replyToID: String?
    let isPendingDelivery: Bool

    var createdAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    var isAttachmentMessage: Bool {
        kind == HaloLinkSupport.fileMessageKind || primaryMediaURL != nil
    }

    var primaryMediaURL: URL? {
        if let imetaURLString = HaloLinkSupport.imetaURL(from: tags),
           let url = URL(string: imetaURLString) {
            return url
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        return url
    }

    var previewText: String {
        HaloLinkSupport.previewText(for: self)
    }
}

struct HaloLinkMessageReaction: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let wrapID: String
    let createdAt: Int
    let senderPubkey: String
    let recipientPubkeys: [String]
    let participantPubkeys: [String]
    let conversationID: String
    let isOutgoing: Bool
    let targetMessageID: String
    let emoji: String
}

struct HaloLinkReactionSummary: Hashable, Sendable {
    let emoji: String
    let count: Int
    let includesCurrentUser: Bool
}

struct HaloLinkSnapshot: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let savedAt: Int
    let messages: [HaloLinkMessage]
    let reactions: [HaloLinkMessageReaction]
    let profilesByPubkey: [String: NostrProfile]
    let knownWrapIDs: [String]
    let ownInboxRelayURLStrings: [String]
    let inboxRelayCache: [String: [String]]
}

struct HaloLinkConversation: Identifiable, Hashable, Sendable {
    let id: String
    let participantPubkeys: [String]
    let primaryPubkey: String?
    let isGroup: Bool
    let isRequest: Bool
    let unreadCount: Int
    let lastMessageAt: Int
    let lastMessagePreview: String
    let subject: String?
    let messages: [HaloLinkMessage]
    let reactionsByMessageID: [String: [HaloLinkMessageReaction]]
    let hasOutgoingActivity: Bool

    var lastMessageDate: Date {
        Date(timeIntervalSince1970: TimeInterval(lastMessageAt))
    }

    func reactionSummaries(
        for messageID: String,
        currentAccountPubkey: String?
    ) -> [HaloLinkReactionSummary] {
        let currentAccountPubkey = currentAccountPubkey?.lowercased()
        let grouped = Dictionary(grouping: reactionsByMessageID[messageID] ?? [], by: \.emoji)

        return grouped
            .map { emoji, reactions in
                HaloLinkReactionSummary(
                    emoji: emoji,
                    count: reactions.count,
                    includesCurrentUser: reactions.contains {
                        $0.senderPubkey.lowercased() == currentAccountPubkey
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.emoji < rhs.emoji
                }
                return lhs.count > rhs.count
            }
    }
}

enum HaloLinkSupport {
    static let inboxRelayKind = 10_050
    static let giftWrapKind = 1_059
    static let directMessageKind = 14
    static let fileMessageKind = 15
    static let maxBackfillPages = 8
    static let backfillPageLimit = 140
    static let initialQueryTimeout: TimeInterval = 12
    static let backfillQueryTimeout: TimeInterval = 8
    static let liveReplayLimit = 120
    static let maxPublishedInboxRelays = 3

    static func conversationID(for participantPubkeys: [String]) -> String {
        participantPubkeys
            .map(normalizePubkey)
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ":")
    }

    static func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func normalizedUniquePubkeys(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for value in values {
            let normalized = normalizePubkey(value)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    static func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    static func previewText(for message: HaloLinkMessage) -> String {
        if message.kind == fileMessageKind {
            let fileType = firstTagValue(named: "file-type", from: message.tags)?.lowercased() ?? ""
            if fileType.hasPrefix("image/") {
                return "Photo"
            }
            if fileType.hasPrefix("video/") {
                return "Video"
            }
            if fileType.hasPrefix("audio/") {
                return "Audio"
            }
            return "Attachment"
        }

        let trimmed = message.content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty, message.primaryMediaURL != nil {
            return "Media attachment"
        }

        guard !trimmed.isEmpty else {
            return "Empty message"
        }

        return trimmed.count > 120 ? String(trimmed.prefix(117)) + "..." : trimmed
    }

    static func firstTagValue(named name: String, from tags: [[String]]) -> String? {
        tags.first {
            $0.first?.lowercased() == name.lowercased()
        }?[safe: 1]
    }

    static func tagValues(named name: String, from tags: [[String]]) -> [String] {
        tags.compactMap { tag in
            guard tag.first?.lowercased() == name.lowercased() else { return nil }
            return tag[safe: 1]
        }
    }

    static func imetaURL(from tags: [[String]]) -> String? {
        for tag in tags where tag.first?.lowercased() == "imeta" {
            for part in tag.dropFirst() where part.hasPrefix("url ") {
                let urlString = String(part.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !urlString.isEmpty {
                    return urlString
                }
            }
        }
        return nil
    }
}

enum HaloLinkSyncPolicy {
    // NIP-17/NIP-59 gift wraps intentionally randomize their outer timestamp
    // by as much as two days. A cursor based on the inner rumor timestamp must
    // include that full window or compliant replies disappear from the REQ.
    static let giftWrapRandomizationWindow = 2 * 24 * 60 * 60
    static let clockSkewAllowance = 5 * 60

    static func replaySince(latestRumorTimestamp: Int?) -> Int? {
        guard let latestRumorTimestamp else { return nil }
        return max(
            0,
            latestRumorTimestamp - giftWrapRandomizationWindow - clockSkewAllowance
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
