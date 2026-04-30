import Foundation

struct FollowListSnapshot: Codable, Sendable {
    let content: String
    let tags: [[String]]
    let createdAt: Int?

    init(content: String, tags: [[String]], createdAt: Int? = nil) {
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }

    var followedPubkeys: [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            guard let name = tag.first?.lowercased(), name == "p" else { return nil }
            guard tag.count > 1 else { return nil }
            let value = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { return nil }
            guard Self.isValidHexPubkey(value) else { return nil }
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    var nonPubkeyTags: [[String]] {
        tags.filter { tag in
            tag.first?.lowercased() != "p"
        }
    }

    var relayHintsByPubkey: [String: [URL]] {
        var hintsByPubkey: [String: [URL]] = [:]
        var seenByPubkey: [String: Set<String>] = [:]

        for tag in tags {
            guard let name = tag.first?.lowercased(), name == "p" else { continue }
            guard tag.count > 1 else { continue }

            let pubkey = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.isValidHexPubkey(pubkey) else { continue }

            for candidate in tag.dropFirst(2) {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard trimmed.lowercased().hasPrefix("ws://") || trimmed.lowercased().hasPrefix("wss://") else {
                    continue
                }
                guard let url = URL(string: trimmed) else { continue }

                let normalizedURL = url.absoluteString.lowercased()
                if seenByPubkey[pubkey, default: []].insert(normalizedURL).inserted {
                    hintsByPubkey[pubkey, default: []].append(url)
                }
            }
        }

        return hintsByPubkey
    }

    private static func isValidHexPubkey(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

func feedPaginationCursor(from events: [NostrEvent]) -> Int? {
    guard !events.isEmpty else { return nil }

    let now = Int(Date().timeIntervalSince1970)
    let validEvents = events.filter { $0.createdAt <= now }
    let timestamps = (validEvents.isEmpty ? events : validEvents)
        .map(\.createdAt)
        .sorted(by: >)

    guard let newestTimestamp = timestamps.first else { return nil }
    guard timestamps.count > 1 else { return newestTimestamp }

    let minimumGapSeconds = 6 * 60 * 60
    for index in 0..<(timestamps.count - 1) {
        let gap = timestamps[index] - timestamps[index + 1]
        if gap >= minimumGapSeconds {
            return timestamps[index]
        }
    }

    return timestamps.last
}

enum FeedItemHydrationMode: Sendable {
    case full
    case cachedProfilesOnly
}

enum RelayFetchMode: Sendable, Equatable {
    case allRelays

    // Fast path for UI surfaces that prefer the first relay with matching data
    // over waiting on the full relay set.
    case firstNonEmptyRelay

    // Stricter latency path for screens where one slow empty relay should not
    // hold up visible content once another relay has matching events.
    case firstRelayWithEvents
}
