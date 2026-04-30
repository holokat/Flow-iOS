import Foundation
import NostrSDK

struct ReshareQuoteDraft: Identifiable, Hashable {
    let id = UUID()
    let initialText: String
    let additionalTags: [[String]]
    let quotedEvent: NostrEvent
    let quotedDisplayNameHint: String?
    let quotedHandleHint: String?
    let quotedAvatarURLHint: URL?
}

enum ResharePublishError: LocalizedError {
    case missingPrivateKey
    case missingWriteRelays
    case malformedTargetEvent
    case malformedRepost
    case publishFailed

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey:
            return "Sign in with a private key to repost."
        case .missingWriteRelays:
            return "No connected sources are configured."
        case .malformedTargetEvent:
            return "Couldn't prepare this event for reposting."
        case .malformedRepost:
            return "Couldn't build repost event."
        case .publishFailed:
            return "Couldn't publish repost to connected sources right now."
        }
    }
}

final class ResharePublishService {
    private let relayClient: any NostrRelayEventPublishing

    init(relayClient: any NostrRelayEventPublishing = NostrRelayClient()) {
        self.relayClient = relayClient
    }

    func buildQuoteDraft(
        for item: FeedItem,
        relayHintURL: URL?
    ) -> ReshareQuoteDraft {
        buildQuoteDraft(
            for: item.displayEvent,
            relayHintURL: relayHintURL,
            quotedDisplayNameHint: item.displayName,
            quotedHandleHint: item.handle,
            quotedAvatarURLHint: item.avatarURL
        )
    }

    func buildQuoteDraft(
        for event: NostrEvent,
        relayHintURL: URL?,
        quotedDisplayNameHint: String? = nil,
        quotedHandleHint: String? = nil,
        quotedAvatarURLHint: URL? = nil
    ) -> ReshareQuoteDraft {
        let normalizedEventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPubkey = event.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let relayHint = relayHintURL?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var eventTag = ["e", normalizedEventID]
        if !relayHint.isEmpty {
            eventTag.append(relayHint)
        } else {
            eventTag.append("")
        }
        eventTag.append("mention")
        eventTag.append(normalizedPubkey)

        let additionalTags = [
            eventTag,
            ["q", normalizedEventID],
            ["p", normalizedPubkey]
        ]

        return ReshareQuoteDraft(
            initialText: "",
            additionalTags: additionalTags,
            quotedEvent: event,
            quotedDisplayNameHint: normalizedHint(quotedDisplayNameHint),
            quotedHandleHint: normalizedHint(quotedHandleHint),
            quotedAvatarURLHint: quotedAvatarURLHint
        )
    }

    func publishRepost(
        of event: NostrEvent,
        currentNsec: String?,
        writeRelayURLs: [URL],
        relayHintURL: URL?
    ) async throws -> Int {
        guard let normalizedNsec = normalizeNsec(currentNsec),
              let keypair = Keypair(nsec: normalizedNsec.lowercased()) else {
            throw ResharePublishError.missingPrivateKey
        }

        let targets = normalizedRelayURLs(writeRelayURLs)
        guard !targets.isEmpty else {
            throw ResharePublishError.missingWriteRelays
        }

        let normalizedEventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPubkey = event.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEventID.count == 64, normalizedPubkey.count == 64 else {
            throw ResharePublishError.malformedTargetEvent
        }

        let repostKind: NostrSDK.EventKind = (event.kind == NostrSDK.EventKind.textNote.rawValue)
            ? .repost
            : .genericRepost

        let content = try serializedTargetEventContent(event)

        var rawTags: [[String]] = []
        if let relayHintURL {
            rawTags.append(["e", normalizedEventID, relayHintURL.absoluteString])
        } else {
            rawTags.append(["e", normalizedEventID])
        }
        rawTags.append(["p", normalizedPubkey])

        if repostKind == .genericRepost {
            rawTags.append(["k", "\(event.kind)"])
        }

        let sdkTags = FlowClientAttribution.appending(to: rawTags).compactMap(decodeSDKTag(from:))
        let repostEvent = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: repostKind)
            .content(content)
            .appendTags(contentsOf: sdkTags)
            .build(signedBy: keypair)

        let repostData = try JSONEncoder().encode(repostEvent)
        let publishOutcome = await relayClient.publishEvent(
            to: targets,
            eventData: repostData,
            eventID: repostEvent.id,
            successPolicy: .returnAfterFirstSuccess
        )

        if publishOutcome.successfulSourceCount == 0 {
            if let firstFailureMessage = publishOutcome.firstFailureMessage {
                throw SourcePublishTransportError(message: firstFailureMessage)
            }
            throw ResharePublishError.publishFailed
        }

        return publishOutcome.successfulSourceCount
    }

    private func serializedTargetEventContent(_ event: NostrEvent) throws -> String {
        if let sdkEvent = decodeSDKEvent(from: event) {
            let data = try JSONEncoder().encode(sdkEvent)
            if let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            }
        }

        let data = try JSONEncoder().encode(event)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ResharePublishError.malformedTargetEvent
        }
        return jsonString
    }

    private func decodeSDKEvent(from event: NostrEvent) -> NostrSDK.NostrEvent? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        return try? JSONDecoder().decode(NostrSDK.NostrEvent.self, from: data)
    }

    private func normalizedHint(_ value: String?) -> String? {
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

    private func normalizeNsec(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
