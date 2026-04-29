import Foundation
import NostrSDK

enum RelayInboundMessage {
    case event(String, NostrEvent)
    case eose(String)
    case notice(String)
    case closed(String, String)
    case ok(String, Bool, String?)
    case auth(String)

    static func parse(_ text: String) -> RelayInboundMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        guard let type = payload.first as? String else { return nil }

        switch type {
        case "EVENT":
            guard payload.count >= 3,
                  let subscriptionID = payload[1] as? String,
                  let eventObject = payload[2] as? [String: Any],
                  let eventData = try? JSONSerialization.data(withJSONObject: eventObject),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) else {
                return nil
            }
            return .event(subscriptionID, event)

        case "EOSE":
            guard payload.count >= 2, let subscriptionID = payload[1] as? String else {
                return nil
            }
            return .eose(subscriptionID)

        case "NOTICE":
            guard payload.count >= 2, let message = payload[1] as? String else {
                return nil
            }
            return .notice(message)

        case "CLOSED":
            guard payload.count >= 3,
                  let subscriptionID = payload[1] as? String,
                  let reason = payload[2] as? String else {
                return nil
            }
            return .closed(subscriptionID, reason)

        case "OK":
            guard payload.count >= 3,
                  let eventID = payload[1] as? String,
                  let accepted = payload[2] as? Bool else {
                return nil
            }
            let message = payload.count > 3 ? payload[3] as? String : nil
            return .ok(eventID, accepted, message)

        case "AUTH":
            guard payload.count >= 2,
                  let challenge = payload[1] as? String else {
                return nil
            }
            return .auth(challenge)

        default:
            return nil
        }
    }
}

enum RelayAuthChallengeError: LocalizedError {
    case missingPrivateKey
    case invalidPrivateKey
    case serializationFailed

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey:
            return "A private key is required to authenticate with this relay."
        case .invalidPrivateKey:
            return "The current private key could not sign a relay authentication event."
        case .serializationFailed:
            return "Couldn't serialize the relay authentication event."
        }
    }
}

func relayAuthRequestString(
    challenge: String,
    relayURL: URL,
    authStore: AuthStore = .shared
) throws -> String {
    let loadResult = authStore.load()
    guard let accountID = loadResult.currentAccountID else {
        throw RelayAuthChallengeError.missingPrivateKey
    }

    let rawPrivateKey = authStore.privateKey(for: accountID) ?? loadResult.transientPrivateKeysByAccountID[accountID]
    let normalizedPrivateKey = rawPrivateKey?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    guard let keypair = Keypair(nsec: normalizedPrivateKey) else {
        throw RelayAuthChallengeError.invalidPrivateKey
    }

    let rawTags = [
        ["relay", relayURL.absoluteString],
        ["challenge", challenge]
    ]
    let sdkTags = rawTags.compactMap(decodeRelayAuthSDKTag(from:))
    let authKind = NostrSDK.EventKind(rawValue: 22_242)
    let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: authKind)
        .content("")
        .appendTags(contentsOf: sdkTags)
        .build(signedBy: keypair)

    guard let eventObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any] else {
        throw RelayAuthChallengeError.serializationFailed
    }

    let requestData = try JSONSerialization.data(withJSONObject: ["AUTH", eventObject], options: [])
    return String(decoding: requestData, as: UTF8.self)
}

private func decodeRelayAuthSDKTag(from raw: [String]) -> NostrSDK.Tag? {
    guard raw.count >= 2 else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: raw),
          let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
        return nil
    }
    return tag
}
