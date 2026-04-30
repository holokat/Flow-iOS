import Foundation

struct ProfileSearchResult: Identifiable, Hashable, Sendable {
    let pubkey: String
    let profile: NostrProfile?
    let createdAt: Int

    var id: String { pubkey }
}

enum ProfileSearchSupport {
    static func normalizedPubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func score(profile: NostrProfile, pubkey: String, query: String) -> Int? {
        let searchableFields = fields(for: profile)
        return score(
            searchableFields: searchableFields,
            searchTokens: Set(searchableFields.flatMap(tokens(from:))),
            pubkey: pubkey,
            query: query
        )
    }

    static func score(
        searchableFields: [String],
        searchTokens: Set<String>,
        pubkey: String,
        query: String
    ) -> Int? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }

        if pubkey == normalizedQuery {
            return 1_000
        }

        if pubkey.hasPrefix(normalizedQuery) {
            return 920
        }

        guard !searchableFields.isEmpty else { return nil }

        let queryTokens = tokens(from: normalizedQuery)

        if searchableFields.contains(normalizedQuery) {
            return 900
        }

        if searchTokens.contains(normalizedQuery) {
            return 860
        }

        if searchableFields.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 820
        }

        if searchTokens.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 780
        }

        if queryTokens.count > 1 {
            if queryTokens.allSatisfy(searchTokens.contains) {
                return 760
            }

            if queryTokens.allSatisfy({ queryToken in
                searchTokens.contains(where: { $0.hasPrefix(queryToken) })
            }) {
                return 720
            }
        }

        guard normalizedQuery.count >= 2 else { return nil }

        if searchableFields.contains(where: { $0.contains(normalizedQuery) }) {
            return 700
        }

        if searchTokens.contains(where: { $0.contains(normalizedQuery) }) {
            return 660
        }

        return nil
    }

    static func fields(for profile: NostrProfile) -> [String] {
        let rawFields: [String] = [
            profile.displayName,
            profile.name,
            profile.nip05,
            profile.lud16,
            profile.lud06
        ]
        .compactMap { value in
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return normalized.isEmpty ? nil : normalized
        }

        var expandedFields: [String] = []
        var seen = Set<String>()

        for field in rawFields {
            if seen.insert(field).inserted {
                expandedFields.append(field)
            }

            let compact = field.replacingOccurrences(of: " ", with: "")
            if !compact.isEmpty, seen.insert(compact).inserted {
                expandedFields.append(compact)
            }

            if field.hasPrefix("@") {
                let dropped = String(field.dropFirst())
                if !dropped.isEmpty, seen.insert(dropped).inserted {
                    expandedFields.append(dropped)
                }
            }

            if let atIndex = field.firstIndex(of: "@"), atIndex > field.startIndex {
                let localPart = String(field[..<atIndex])
                if !localPart.isEmpty, seen.insert(localPart).inserted {
                    expandedFields.append(localPart)
                }
            }
        }

        return expandedFields
    }

    static func tokens(from field: String) -> [String] {
        field.split(whereSeparator: { character in
            !character.isLetter && !character.isNumber
        })
        .map(String.init)
        .filter { !$0.isEmpty }
    }
}
