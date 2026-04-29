import Foundation
import NostrSDK

enum ThreadReplyPublishError: LocalizedError {
    case emptyContent
    case missingPrivateKey
    case missingWriteRelays
    case malformedEvent
    case publishFailed

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Write a reply or attach media before sending."
        case .missingPrivateKey:
            return "Sign in with a private key to reply."
        case .missingWriteRelays:
            return "No publish sources are configured."
        case .malformedEvent:
            return "Couldn't build reply event."
        case .publishFailed:
            return "Couldn't publish reply right now."
        }
    }
}

struct PreparedThreadReplyPublication: Sendable {
    let item: FeedItem
    let targets: [URL]
    let eventData: Data
    let eventID: String
}

final class ThreadReplyPublishService {
    private let relayClient: any NostrRelayEventPublishing

    init(relayClient: any NostrRelayEventPublishing = NostrRelayClient()) {
        self.relayClient = relayClient
    }

    func publishReply(
        content: String,
        replyingTo rootEvent: NostrEvent,
        currentAccountPubkey: String?,
        currentNsec: String?,
        writeRelayURLs: [URL],
        additionalTags: [[String]] = []
    ) async throws -> FeedItem {
        let prepared = try await prepareReply(
            content: content,
            replyingTo: rootEvent,
            currentAccountPubkey: currentAccountPubkey,
            currentNsec: currentNsec,
            writeRelayURLs: writeRelayURLs,
            additionalTags: additionalTags
        )
        _ = try await publishPrepared(prepared)
        return prepared.item
    }

    func prepareReply(
        content: String,
        replyingTo rootEvent: NostrEvent,
        currentAccountPubkey: String?,
        currentNsec: String?,
        writeRelayURLs: [URL],
        additionalTags: [[String]] = []
    ) async throws -> PreparedThreadReplyPublication {
        let publishedContent = ThreadPublishedMediaContentBuilder.content(
            baseText: content,
            additionalTags: additionalTags
        )
        guard !publishedContent.isEmpty || !additionalTags.isEmpty else {
            throw ThreadReplyPublishError.emptyContent
        }

        guard let normalizedNsec = normalizeNsec(currentNsec),
              let keypair = Keypair(nsec: normalizedNsec.lowercased()) else {
            throw ThreadReplyPublishError.missingPrivateKey
        }

        let targets = normalizedRelayURLs(writeRelayURLs)
        guard !targets.isEmpty else {
            throw ThreadReplyPublishError.missingWriteRelays
        }

        let rootID = normalizedIdentifier(rootEvent.rootEventReferenceID) ?? rootEvent.id.lowercased()
        let replyID = rootEvent.id.lowercased()
        let rootAuthor = normalizePubkey(rootEvent.pubkey)

        var sdkTags: [Tag] = []
        let rootAuthorForTags = rootAuthor.isEmpty ? nil : rootAuthor
        do {
            let rootTag = try EventTag(
                eventId: rootID,
                marker: .root,
                pubkey: rootAuthorForTags
            )
            let replyTag = try EventTag(
                eventId: replyID,
                marker: .reply,
                pubkey: rootAuthorForTags
            )
            sdkTags.append(rootTag.tag)
            sdkTags.append(replyTag.tag)
        } catch {
            throw ThreadReplyPublishError.malformedEvent
        }

        var seenPubkeys = Set<String>()
        func appendPubkey(_ pubkey: String) {
            let normalized = normalizePubkey(pubkey)
            guard !normalized.isEmpty else { return }
            guard seenPubkeys.insert(normalized).inserted else { return }
            guard let tag = try? PubkeyTag(pubkey: normalized).tag else { return }
            sdkTags.append(tag)
        }

        appendPubkey(rootAuthor)
        for referenced in rootEvent.mentionedPubkeys {
            appendPubkey(referenced)
        }
        if let current = normalizedIdentifier(currentAccountPubkey), current != rootAuthor {
            appendPubkey(current)
        }

        for rawTag in FlowClientAttribution.appending(to: additionalTags) {
            guard let tag = decodeSDKTag(from: rawTag) else { continue }
            sdkTags.append(tag)
        }

        let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .textNote)
            .content(publishedContent)
            .appendTags(contentsOf: sdkTags)
            .build(signedBy: keypair)

        let eventData = try JSONEncoder().encode(event)

        let localEvent = NostrEvent(
            id: event.id,
            pubkey: event.pubkey.lowercased(),
            createdAt: Int(event.createdAt),
            kind: event.kind.rawValue,
            tags: event.tags.map { [$0.name, $0.value] + $0.otherParameters },
            content: event.content,
            sig: event.signature ?? ""
        )

        await SeenEventStore.shared.store(events: [localEvent])
        let resolvedProfile = await ProfileCache.shared.resolve(pubkeys: [localEvent.pubkey]).hits[localEvent.pubkey]
        let replyTargetProfile = await ProfileCache.shared
            .resolve(pubkeys: [rootEvent.pubkey.lowercased()])
            .hits[rootEvent.pubkey.lowercased()]
        let item = FeedItem(
            event: localEvent,
            profile: resolvedProfile,
            replyTargetEvent: rootEvent,
            replyTargetProfile: replyTargetProfile
        )

        return PreparedThreadReplyPublication(
            item: item,
            targets: targets,
            eventData: eventData,
            eventID: event.id
        )
    }

    func publishPrepared(_ prepared: PreparedThreadReplyPublication) async throws -> Int {
        let publishOutcome = await relayClient.publishEvent(
            to: prepared.targets,
            eventData: prepared.eventData,
            eventID: prepared.eventID,
            successPolicy: .returnAfterFirstSuccess
        )

        if publishOutcome.successfulSourceCount == 0 {
            if let firstFailureMessage = publishOutcome.firstFailureMessage {
                throw SourcePublishTransportError(message: firstFailureMessage)
            }
            throw ThreadReplyPublishError.publishFailed
        }

        return publishOutcome.successfulSourceCount
    }

    private func normalizeNsec(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []
        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }
        return ordered
    }

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        let normalized = normalizePubkey(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func decodeSDKTag(from raw: [String]) -> NostrSDK.Tag? {
        guard raw.count >= 2 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
            return nil
        }
        return tag
    }
}

private enum ThreadPublishedMediaContentBuilder {
    static func content(baseText: String, additionalTags: [[String]]) -> String {
        let trimmedText = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaURLs = extractedMediaURLs(from: additionalTags).filter { !trimmedText.contains($0) }

        guard !mediaURLs.isEmpty else { return trimmedText }
        if trimmedText.isEmpty {
            return mediaURLs.joined(separator: "\n")
        }

        return ([trimmedText] + mediaURLs).joined(separator: "\n")
    }

    private static func extractedMediaURLs(from tags: [[String]]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "imeta" else { continue }

            for value in tag.dropFirst() {
                guard value.hasPrefix("url ") else { continue }
                let url = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }

                let normalized = url.lowercased()
                guard seen.insert(normalized).inserted else { continue }
                ordered.append(url)
                break
            }
        }

        return ordered
    }
}
