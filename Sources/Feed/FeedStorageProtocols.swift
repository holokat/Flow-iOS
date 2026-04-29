import Foundation

struct AuthorRelayDirectoryEntry: Equatable, Sendable {
    let readRelayURLs: [URL]
    let writeRelayURLs: [URL]
    let hintRelayURLs: [URL]
    let refreshedAt: Date?
}

protocol TimelineEventCaching: Actor, Sendable {
    func events(
        for key: String,
        fetcher: @escaping @Sendable () async throws -> [NostrEvent]
    ) async throws -> [NostrEvent]
}

protocol SeenEventStoring: Actor, Sendable {
    func store(events: [NostrEvent]) async
    func storeRecentFeed(key: String, events: [NostrEvent]) async
    func recentFeed(key: String) async -> [NostrEvent]?
    func events(ids: [String]) async -> [String: NostrEvent]
}

protocol FollowListSnapshotStoring: Actor, Sendable {
    func cachedSnapshot(pubkey: String, maxAge: TimeInterval?) async -> FollowListSnapshot?
    func storeSnapshot(_ snapshot: FollowListSnapshot, for pubkey: String) async
}

extension FollowListSnapshotStoring {
    func cachedSnapshot(pubkey: String) async -> FollowListSnapshot? {
        await cachedSnapshot(pubkey: pubkey, maxAge: nil)
    }
}

protocol ProfileRelayHintCaching: Actor, Sendable {
    func storeHints(_ hintsByPubkey: [String: [URL]])
    func prioritizedRelayURLs(for pubkeys: [String], baseRelayURLs: [URL]) -> [URL]
    func relayHints(for pubkeys: [String]) -> [String: [URL]]
}

protocol AuthorRelayDirectoryCaching: Actor, Sendable {
    func entry(for pubkey: String) -> AuthorRelayDirectoryEntry?
    func entries(for pubkeys: [String]) -> [String: AuthorRelayDirectoryEntry]
    func store(entry: AuthorRelayDirectoryEntry, for pubkey: String)
}

protocol ProfileCaching: Actor, Sendable {
    func resolve(
        pubkeys: [String],
        ignoringKnownMisses: Bool
    ) async -> (hits: [String: NostrProfile], missing: [String])
    func cachedProfile(pubkey: String) async -> NostrProfile?
    func cachedProfiles(pubkeys: [String]) async -> [String: NostrProfile]
    func recentProfilePubkeys(limit: Int) async -> [String]
    func store(profiles newProfiles: [String: NostrProfile], missed: [String]) async
    func setPriorityPubkeys(_ pubkeys: Set<String>)
}
