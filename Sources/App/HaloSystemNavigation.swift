import Combine
import Foundation

enum HaloDeepLinkRoute: Hashable, Identifiable, Sendable {
    case profile(pubkey: String)
    case note(reference: String)
    case feed(id: String)
    case hashtag(name: String)
    case search(query: String)
    case compose(text: String)
    case message(pubkey: String, draft: String)

    private static let scheme = "flow"

    var id: String {
        switch self {
        case .profile(let pubkey):
            return "profile:\(pubkey)"
        case .note(let reference):
            return "note:\(reference)"
        case .feed(let id):
            return "feed:\(id)"
        case .hashtag(let name):
            return "hashtag:\(name)"
        case .search(let query):
            return "search:\(query)"
        case .compose(let text):
            return "compose:\(text)"
        case .message(let pubkey, let draft):
            return "message:\(pubkey):\(draft)"
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme

        switch self {
        case .profile(let pubkey):
            components.host = "profile"
            components.path = "/\(pubkey)"
        case .note(let reference):
            components.host = "note"
            components.path = "/\(reference)"
        case .feed(let id):
            components.host = "feed"
            components.path = "/\(id)"
        case .hashtag(let name):
            components.host = "hashtag"
            components.path = "/\(name)"
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .compose(let text):
            components.host = "compose"
            if !text.isEmpty {
                components.queryItems = [URLQueryItem(name: "text", value: text)]
            }
        case .message(let pubkey, let draft):
            components.host = "message"
            components.path = "/\(pubkey)"
            if !draft.isEmpty {
                components.queryItems = [URLQueryItem(name: "text", value: draft)]
            }
        }

        return components.url ?? URL(string: "\(Self.scheme)://search")!
    }

    static func parse(_ url: URL) -> HaloDeepLinkRoute? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host?.lowercased() else {
            return nil
        }

        let pathValue = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch host {
        case "profile":
            guard let pubkey = normalizedHexIdentifier(pathValue) else { return nil }
            return .profile(pubkey: pubkey)
        case "note":
            guard isSupportedEventReference(pathValue) else { return nil }
            return .note(reference: pathValue.lowercased())
        case "feed":
            guard let id = normalizedOpaqueIdentifier(pathValue) else { return nil }
            return .feed(id: id)
        case "hashtag":
            guard let hashtag = normalizedHashtag(pathValue) else { return nil }
            return .hashtag(name: hashtag)
        case "search":
            let query = normalizedText(queryItems.first(where: { $0.name == "q" })?.value, limit: 500)
            return .search(query: query)
        case "compose":
            let text = normalizedText(queryItems.first(where: { $0.name == "text" })?.value, limit: 10_000)
            return .compose(text: text)
        case "message":
            guard let pubkey = normalizedHexIdentifier(pathValue) else { return nil }
            let draft = normalizedText(queryItems.first(where: { $0.name == "text" })?.value, limit: 4_000)
            return .message(pubkey: pubkey, draft: draft)
        default:
            return nil
        }
    }

    private static func normalizedHexIdentifier(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }

    private static func isSupportedEventReference(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalizedHexIdentifier(normalized) != nil {
            return true
        }
        return normalized.hasPrefix("note1") ||
            normalized.hasPrefix("nevent1") ||
            normalized.hasPrefix("naddr1")
    }

    private static func normalizedOpaqueIdentifier(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 200,
              normalized.range(of: "^[a-z0-9._:-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }

    private static func normalizedHashtag(_ value: String) -> String? {
        let withoutHash = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let normalized = withoutHash.lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 100,
              normalized.range(of: "\\s", options: .regularExpression) == nil else {
            return nil
        }
        return normalized
    }

    private static func normalizedText(_ value: String?, limit: Int) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(trimmed.prefix(limit))
    }
}

@MainActor
final class HaloSystemNavigationStore: ObservableObject {
    @Published var presentedContentRoute: HaloDeepLinkRoute?
    @Published private(set) var pendingTabRoute: HaloDeepLinkRoute?

    func accept(_ route: HaloDeepLinkRoute) {
        switch route {
        case .profile, .note, .hashtag:
            presentedContentRoute = route
        case .feed, .search, .compose, .message:
            pendingTabRoute = route
        }
    }

    func accept(_ url: URL) -> Bool {
        guard let route = HaloDeepLinkRoute.parse(url) else { return false }
        accept(route)
        return true
    }

    func consumePendingTabRoute() -> HaloDeepLinkRoute? {
        defer { pendingTabRoute = nil }
        return pendingTabRoute
    }

    func clearPendingTabRoute() {
        pendingTabRoute = nil
    }
}

enum HaloLinkPendingDraftStore {
    private static let storageKey = "halo.pending-halo-link-drafts.v1"

    static func save(_ text: String, recipientPubkey: String) {
        let normalizedPubkey = recipientPubkey.lowercased()
        guard normalizedPubkey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return
        }

        let normalizedText = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !normalizedText.isEmpty else { return }

        var drafts = loadDrafts()
        drafts[normalizedPubkey] = normalizedText
        defaults.set(drafts, forKey: storageKey)
    }

    static func take(recipientPubkey: String) -> String? {
        let normalizedPubkey = recipientPubkey.lowercased()
        var drafts = loadDrafts()
        let value = drafts.removeValue(forKey: normalizedPubkey)
        defaults.set(drafts, forKey: storageKey)
        return value
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: FlowSharedComposeDraftStore.appGroupIdentifier) ?? .standard
    }

    private static func loadDrafts() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}
