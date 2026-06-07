import Foundation

struct HashtagRoute: Identifiable, Hashable {
    let hashtag: String
    let seedItems: [FeedItem]

    init(hashtag: String, seedItems: [FeedItem] = []) {
        self.hashtag = hashtag
        self.seedItems = seedItems
    }

    var normalizedHashtag: String {
        NostrEvent.normalizedHashtagValue(hashtag)
    }

    var id: String {
        normalizedHashtag
    }
}

func matchingHashtagSeedItems(
    hashtag: String,
    from sourceItems: [FeedItem],
    limit: Int = 24
) -> [FeedItem] {
    let normalizedHashtag = NostrEvent.normalizedHashtagValue(hashtag)
    guard !normalizedHashtag.isEmpty else { return [] }

    var itemsByID: [String: FeedItem] = [:]

    for item in sourceItems {
        let canonicalItem = item.canonicalDisplayItem
        guard canonicalItem.displayEvent.containsHashtag(normalizedHashtag) else { continue }
        itemsByID[canonicalItem.id.lowercased()] = canonicalItem
    }

    return itemsByID.values
        .sorted { lhs, rhs in
            if lhs.event.createdAt == rhs.event.createdAt {
                return lhs.id.lowercased() > rhs.id.lowercased()
            }
            return lhs.event.createdAt > rhs.event.createdAt
        }
        .prefix(limit)
        .map { $0 }
}

struct RelayRoute: Identifiable, Hashable {
    let relayURL: URL

    init?(relayURL: URL) {
        guard let normalizedURL = RelayURLSupport.normalizedURL(from: relayURL.absoluteString) else {
            return nil
        }
        self.relayURL = normalizedURL
    }

    init?(value: String) {
        guard let normalizedURL = RelayURLSupport.normalizedURL(from: value) else {
            return nil
        }
        self.relayURL = normalizedURL
    }

    var id: String {
        RelayURLSupport.normalizedRelayURLString(relayURL) ?? relayURL.absoluteString.lowercased()
    }

    var displayName: String {
        RelayURLSupport.displayName(for: relayURL)
    }
}

enum RelayURLSupport {
    private static let relayActionScheme = "x21-relay"
    private static let relayActionHost = "open"
    private static let relayActionURLQueryItemName = "url"

    private static let knownDisplayNames: [String: String] = [
        "relay.damus.io": "Damus Relay",
        "relay.primal.net": "Primal Relay",
        "nos.lol": "Nos Relay",
        "relay.nostr.band": "Nostr.band Relay",
        "nostr.mom": "Nostr.mom Relay",
        "relay.snort.social": "Snort Relay"
    ]

    static func actionURL(for relayURLValue: String) -> URL? {
        guard let relayURL = normalizedURL(from: relayURLValue) else { return nil }

        var components = URLComponents()
        components.scheme = relayActionScheme
        components.host = relayActionHost
        components.queryItems = [
            URLQueryItem(name: relayActionURLQueryItemName, value: relayURL.absoluteString)
        ]
        return components.url
    }

    static func relayURL(fromActionURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == relayActionScheme,
              url.host()?.lowercased() == relayActionHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == relayActionURLQueryItemName })?.value else {
            return nil
        }
        return normalizedURL(from: value)
    }

    static func normalizedURL(from value: String) -> URL? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'.,;!"))

        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        }

        guard let url = components.url,
              FlowURLSafety.isPubliclyLoadableRelayURL(url) else {
            return nil
        }
        return url
    }

    static func normalizedRelayURLString(_ relayURL: URL) -> String? {
        normalizedURL(from: relayURL.absoluteString)?.absoluteString.lowercased()
    }

    static func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            guard let normalizedURL = normalizedURL(from: relayURL.absoluteString),
                  let key = normalizedRelayURLString(normalizedURL),
                  seen.insert(key).inserted else {
                continue
            }
            ordered.append(normalizedURL)
        }

        return ordered
    }

    static func displayName(for relayURL: URL) -> String {
        guard let host = normalizedURL(from: relayURL.absoluteString)?.host()?.lowercased(),
              !host.isEmpty else {
            return "Relay"
        }

        if let knownDisplayName = knownDisplayNames[host] {
            return knownDisplayName
        }

        let hostParts = host.split(separator: ".").map(String.init)
        let meaningfulPart = hostParts.first { part in
            !["relay", "nostr", "www"].contains(part.lowercased())
        } ?? hostParts.first

        guard let meaningfulPart else { return "Relay" }

        let title = meaningfulPart
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")

        return title.isEmpty ? "Relay" : "\(title) Relay"
    }
}
