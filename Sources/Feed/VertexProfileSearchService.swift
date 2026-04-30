import Foundation
import NostrSDK

enum VertexProfileSearchError: LocalizedError {
    case invalidCredentials
    case queryTooShort
    case invalidRequest
    case invalidResponse
    case untrustedResponse
    case requestRejected(String)
    case serviceUnavailable(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Search requires a signed-in private key right now."
        case .queryTooShort:
            return "Search terms must be longer than three characters."
        case .invalidRequest:
            return "Couldn't prepare the search request."
        case .invalidResponse:
            return "Vertex returned an invalid search response."
        case .untrustedResponse:
            return "Vertex search response could not be trusted."
        case .requestRejected(let message):
            return message
        case .serviceUnavailable(let statusCode):
            return "Vertex search is unavailable right now (\(statusCode))."
        }
    }
}

private struct VertexProfileMatch: Codable, Sendable {
    let pubkey: String
    let rank: Double?
}

actor VertexProfileSearchService {
    static let shared = VertexProfileSearchService()

    nonisolated static let relayURL = URL(string: "wss://relay.vertexlab.io")!

    private static let apiURL = URL(string: "https://relay.vertexlab.io/api/v1/dvms")!
    private static let requestKind = 5_315
    private static let responseKind = 6_315
    private static let errorKind = 7_000
    private static let trustedResponsePubkey = "b0565a0d950477811f35ff76e5981ede67a90469a97feec13dc17f36290debfe"

    private let cacheTTL: TimeInterval = 60 * 15
    private var searchCache: [String: (matches: [VertexProfileMatch], createdAt: Int, storedAt: Date)] = [:]

    func searchProfiles(
        query: String,
        limit: Int,
        nsec: String,
        relayURLs: [URL],
        feedService: NostrFeedService = NostrFeedService()
    ) async throws -> [ProfileSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count > 3 else {
            throw VertexProfileSearchError.queryTooShort
        }

        let normalizedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let keypair = Keypair(nsec: normalizedNsec) else {
            throw VertexProfileSearchError.invalidCredentials
        }

        let clampedLimit = min(max(limit, 1), 100)
        let cacheKey = "\(normalizedQuery.lowercased())|\(clampedLimit)"

        let cached = cachedSearch(for: cacheKey)
        let rawMatches: [VertexProfileMatch]
        let createdAt: Int

        if let cached {
            rawMatches = cached.matches
            createdAt = cached.createdAt
        } else {
            let searchResult = try await performSearchRequest(
                query: normalizedQuery,
                limit: clampedLimit,
                keypair: keypair
            )
            rawMatches = searchResult.matches
            createdAt = searchResult.createdAt
            searchCache[cacheKey] = (matches: rawMatches, createdAt: createdAt, storedAt: Date())
        }

        let pubkeys = normalizedPubkeys(from: rawMatches)
        guard !pubkeys.isEmpty else { return [] }

        let profileRelayTargets = normalizedRelayURLs([Self.relayURL] + relayURLs)
        let profilesByPubkey = await feedService.fetchProfiles(
            relayURLs: profileRelayTargets,
            pubkeys: pubkeys
        )

        return pubkeys.enumerated().map { index, pubkey in
            ProfileSearchResult(
                pubkey: pubkey,
                profile: profilesByPubkey[pubkey],
                createdAt: createdAt - index
            )
        }
    }

    private func performSearchRequest(
        query: String,
        limit: Int,
        keypair: Keypair
    ) async throws -> (matches: [VertexProfileMatch], createdAt: Int) {
        let requestEvent = try makeRequestEvent(query: query, limit: limit, keypair: keypair)

        let requestData = try JSONEncoder().encode(requestEvent)
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.httpBody = requestData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VertexProfileSearchError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw VertexProfileSearchError.serviceUnavailable(statusCode: httpResponse.statusCode)
        }

        let responseEvent = try JSONDecoder().decode(NostrEvent.self, from: responseData)
        try validateResponseEvent(responseEvent, requestID: requestEvent.id, requesterPubkey: keypair.publicKey.hex)

        if responseEvent.kind == Self.errorKind {
            let message = responseStatusMessage(from: responseEvent.tags) ?? "Vertex search failed."
            throw VertexProfileSearchError.requestRejected(message)
        }

        guard responseEvent.kind == Self.responseKind else {
            throw VertexProfileSearchError.invalidResponse
        }

        guard let contentData = responseEvent.content.data(using: .utf8) else {
            throw VertexProfileSearchError.invalidResponse
        }

        let decodedMatches = try JSONDecoder().decode([VertexProfileMatch].self, from: contentData)
        return (decodedMatches, responseEvent.createdAt)
    }

    private func makeRequestEvent(
        query: String,
        limit: Int,
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        let rawTags = [
            ["param", "search", query],
            ["param", "limit", "\(limit)"],
            ["param", "sort", "globalPagerank"]
        ]
        let sdkTags = rawTags.compactMap(decodeSDKTag(from:))

        let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(Self.requestKind))
            .content("")
            .appendTags(contentsOf: sdkTags)
            .build(signedBy: keypair)

        guard !event.id.isEmpty else {
            throw VertexProfileSearchError.invalidRequest
        }
        return event
    }

    private func validateResponseEvent(
        _ responseEvent: NostrEvent,
        requestID: String,
        requesterPubkey: String
    ) throws {
        guard responseEvent.pubkey.lowercased() == Self.trustedResponsePubkey else {
            throw VertexProfileSearchError.untrustedResponse
        }

        let normalizedRequestID = requestID.lowercased()
        let normalizedRequesterPubkey = requesterPubkey.lowercased()

        let referencesRequest = responseEvent.tags.contains { tag in
            guard let name = tag.first?.lowercased(), name == "e", tag.count > 1 else { return false }
            return tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedRequestID
        }
        guard referencesRequest else {
            throw VertexProfileSearchError.invalidResponse
        }

        let referencesRequester = responseEvent.tags.contains { tag in
            guard let name = tag.first?.lowercased(), name == "p", tag.count > 1 else { return false }
            return tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedRequesterPubkey
        }
        guard referencesRequester else {
            throw VertexProfileSearchError.invalidResponse
        }
    }

    private func cachedSearch(for key: String) -> (matches: [VertexProfileMatch], createdAt: Int)? {
        guard let cached = searchCache[key] else { return nil }
        guard Date().timeIntervalSince(cached.storedAt) <= cacheTTL else {
            searchCache.removeValue(forKey: key)
            return nil
        }
        return (cached.matches, cached.createdAt)
    }

    private func normalizedPubkeys(from matches: [VertexProfileMatch]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for match in matches {
            let normalized = match.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
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

    private func responseStatusMessage(from tags: [[String]]) -> String? {
        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "status", tag.count > 2 else { continue }
            let value = tag[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
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
