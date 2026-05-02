import Foundation

struct AuthorRelayPlan: Equatable, Sendable {
    let relayURLsByPubkey: [String: [URL]]
    let broadFallbackRelayURLs: [URL]

    func relayURLs(for pubkey: String) -> [URL] {
        let normalizedPubkey = AuthorRelayPlanner.normalizePubkey(pubkey)
        return relayURLsByPubkey[normalizedPubkey] ?? broadFallbackRelayURLs
    }
}

struct AuthorRelayPlanner {
    func makePlan(
        authors: [String],
        baseReadRelayURLs: [URL],
        directoryEntriesByPubkey: [String: AuthorRelayDirectoryEntry],
        fallbackRelayURLs: [URL]
    ) -> AuthorRelayPlan {
        let normalizedBaseReadRelayURLs = RelayURLSupport.normalizedRelayURLs(baseReadRelayURLs)
        let normalizedFallbackRelayURLs = RelayURLSupport.normalizedRelayURLs(fallbackRelayURLs)
        let normalizedDirectoryEntries = normalize(entriesByPubkey: directoryEntriesByPubkey)

        var relayURLsByPubkey: [String: [URL]] = [:]
        for author in authors {
            let normalizedAuthor = Self.normalizePubkey(author)
            guard !normalizedAuthor.isEmpty else { continue }

            let entry = normalizedDirectoryEntries[normalizedAuthor]
            let authorPrimaryRelayURLs: [URL]
            if let entry, !entry.writeRelayURLs.isEmpty {
                authorPrimaryRelayURLs = entry.writeRelayURLs
            } else {
                authorPrimaryRelayURLs = entry?.readRelayURLs ?? []
            }

            relayURLsByPubkey[normalizedAuthor] = RelayURLSupport.normalizedRelayURLs(
                authorPrimaryRelayURLs
                    + (entry?.hintRelayURLs ?? [])
                    + normalizedBaseReadRelayURLs
                    + normalizedFallbackRelayURLs
            )
        }

        return AuthorRelayPlan(
            relayURLsByPubkey: relayURLsByPubkey,
            broadFallbackRelayURLs: normalizedFallbackRelayURLs
        )
    }

    private func normalize(
        entriesByPubkey: [String: AuthorRelayDirectoryEntry]
    ) -> [String: AuthorRelayDirectoryEntry] {
        var normalized: [String: AuthorRelayDirectoryEntry] = [:]

        for (pubkey, entry) in entriesByPubkey {
            let normalizedPubkey = Self.normalizePubkey(pubkey)
            guard !normalizedPubkey.isEmpty else { continue }

            normalized[normalizedPubkey] = AuthorRelayDirectoryEntry(
                readRelayURLs: RelayURLSupport.normalizedRelayURLs(entry.readRelayURLs),
                writeRelayURLs: RelayURLSupport.normalizedRelayURLs(entry.writeRelayURLs),
                hintRelayURLs: RelayURLSupport.normalizedRelayURLs(entry.hintRelayURLs),
                refreshedAt: entry.refreshedAt
            )
        }

        return normalized
    }

    static func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
