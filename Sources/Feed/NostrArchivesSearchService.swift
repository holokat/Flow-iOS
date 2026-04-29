import Foundation
import NostrSDK

actor NostrArchivesSearchService {
    static let shared = NostrArchivesSearchService()

    private static let defaultBaseURL = URL(string: "https://api.nostrarchives.com")!

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(
        baseURL: URL = NostrArchivesSearchService.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func searchProfiles(query: String, limit: Int) async -> [ProfileSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2 else { return [] }

        let clampedLimit = min(max(limit, 1), 100)
        let suggestionResults = (try? await fetchProfileSuggestions(
            query: normalizedQuery,
            limit: min(clampedLimit, 10)
        )) ?? []

        if suggestionResults.count >= clampedLimit {
            return Array(suggestionResults.prefix(clampedLimit))
        }

        let searchResults = (try? await fetchProfiles(
            query: normalizedQuery,
            limit: clampedLimit
        )) ?? []

        return deduplicatedProfiles(
            suggestionResults + searchResults,
            limit: clampedLimit
        )
    }

    func searchNotes(
        query: String,
        kinds: [Int],
        limit: Int,
        offset: Int = 0
    ) async throws -> [NostrEvent] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, limit > 0 else { return [] }

        var components = URLComponents(
            url: endpoint("v1", "search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: normalizedQuery),
            URLQueryItem(name: "type", value: "notes"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "offset", value: String(max(offset, 0)))
        ]

        let response: NostrArchivesNotesSearchResponse = try await fetch(components)
        let kindSet = Set(kinds)
        return response.notes.compactMap { record in
            let event = record.event
            guard kindSet.isEmpty || kindSet.contains(event.kind) else { return nil }
            return event
        }
    }

    private func fetchProfileSuggestions(
        query: String,
        limit: Int
    ) async throws -> [ProfileSearchResult] {
        var components = URLComponents(
            url: endpoint("v1", "search", "suggest"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let response: NostrArchivesSuggestResponse = try await fetch(components)
        return profileResults(from: response.suggestions)
    }

    private func fetchProfiles(
        query: String,
        limit: Int
    ) async throws -> [ProfileSearchResult] {
        var components = URLComponents(
            url: endpoint("v1", "search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "profiles"),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let response: NostrArchivesProfilesSearchResponse = try await fetch(components)
        return profileResults(from: response.profiles)
    }

    private func fetch<Response: Decodable>(_ components: URLComponents?) async throws -> Response {
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try decoder.decode(Response.self, from: data)
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func endpoint(_ pathComponents: String...) -> URL {
        pathComponents.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private func profileResults(from profiles: [NostrArchivesSearchProfileRecord]) -> [ProfileSearchResult] {
        let referenceTime = Int(Date().timeIntervalSince1970)

        return profiles.enumerated().compactMap { index, profile in
            let pubkey = profile.normalizedPubkey
            guard pubkey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                return nil
            }

            return ProfileSearchResult(
                pubkey: pubkey,
                profile: profile.nostrProfile,
                createdAt: profile.lastActiveAt ?? referenceTime - index
            )
        }
    }

    private func deduplicatedProfiles(
        _ results: [ProfileSearchResult],
        limit: Int
    ) -> [ProfileSearchResult] {
        var seen = Set<String>()
        var ordered: [ProfileSearchResult] = []

        for result in results {
            let normalizedPubkey = result.pubkey.lowercased()
            guard seen.insert(normalizedPubkey).inserted else { continue }
            ordered.append(result)
            if ordered.count >= limit {
                break
            }
        }

        return ordered
    }
}

private struct NostrArchivesSuggestResponse: Decodable, Sendable {
    let suggestions: [NostrArchivesSearchProfileRecord]
}

private struct NostrArchivesProfilesSearchResponse: Decodable, Sendable {
    let profiles: [NostrArchivesSearchProfileRecord]
}

private struct NostrArchivesNotesSearchResponse: Decodable, Sendable {
    let notes: [NostrArchivesNoteRecord]
}

private struct NostrArchivesNoteRecord: Decodable, Sendable {
    let event: NostrEvent
}

private struct NostrArchivesSearchProfileRecord: Decodable, Sendable {
    let pubkey: String
    let name: String?
    let displayName: String?
    let preferredName: String?
    let picture: String?
    let about: String?
    let nip05: String?
    let lud06: String?
    let lud16: String?
    let website: String?
    let lastActiveAt: Int?

    enum CodingKeys: String, CodingKey {
        case pubkey
        case name
        case displayName = "display_name"
        case preferredName = "preferred_name"
        case picture
        case about
        case nip05
        case lud06
        case lud16
        case website
        case lastActiveAt = "last_active_at"
    }

    var normalizedPubkey: String {
        pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var nostrProfile: NostrProfile {
        NostrProfile(
            name: name ?? preferredName,
            displayName: displayName ?? preferredName,
            picture: picture,
            banner: nil,
            about: about,
            nip05: nip05,
            website: website,
            lud06: lud06,
            lud16: lud16
        )
    }
}
