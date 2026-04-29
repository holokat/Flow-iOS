import Foundation
import NostrSDK

@MainActor
final class FollowStore: ObservableObject {
    struct ActionFeedback: Identifiable, Equatable {
        let id = UUID()
        let pubkeys: [String]
        let didFollow: Bool
    }

    static let shared = FollowStore()

    @Published private(set) var followedPubkeys: Set<String>
    @Published private(set) var lastPublishError: String?
    @Published private(set) var lastActionFeedback: ActionFeedback?

    private let defaults: UserDefaults
    private let authStore: AuthStore
    private let feedService: NostrFeedService
    private let relayClient: any NostrRelayEventPublishing
    private let keyPrefix = "flow.followedPubkeys"
    private let legacyKeyPrefix = "x21.followedPubkeys"
    private let legacyKey = "x21.followedPubkeys"

    private struct Session: Equatable {
        let accountPubkey: String
        let nsec: String?
        let readRelayURLs: [URL]
        let writeRelayURLs: [URL]
    }

    private var session: Session?
    private var syncTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var latestFollowListSnapshot: FollowListSnapshot?
    private var hasInFlightFollowPublish = false

    init(
        defaults: UserDefaults = .standard,
        authStore: AuthStore = .shared,
        feedService: NostrFeedService = NostrFeedService(),
        relayClient: any NostrRelayEventPublishing = NostrRelayClient()
    ) {
        self.defaults = defaults
        self.authStore = authStore
        self.feedService = feedService
        self.relayClient = relayClient
        self.followedPubkeys = []
    }

    deinit {
        syncTask?.cancel()
        publishTask?.cancel()
        prewarmTask?.cancel()
    }

    func configure(accountPubkey: String?, nsec: String?, relayURL: URL) {
        let sharedReadRelays = RelaySettingsStore.shared.readRelayURLs
        let sharedWriteRelays = RelaySettingsStore.shared.writeRelayURLs
        let fallbackTargets = [relayURL]

        configure(
            accountPubkey: accountPubkey,
            nsec: nsec,
            readRelayURLs: sharedReadRelays.isEmpty ? fallbackTargets : sharedReadRelays,
            writeRelayURLs: sharedWriteRelays.isEmpty ? fallbackTargets : sharedWriteRelays
        )
    }

    func configure(accountPubkey: String?, nsec: String?, readRelayURLs: [URL], writeRelayURLs: [URL]) {
        let normalizedAccount = normalizePubkey(accountPubkey)
        let normalizedNsec = normalizeNsec(nsec)
        let normalizedReadRelays = normalizedRelayURLs(readRelayURLs)
        let normalizedWriteRelays = normalizedRelayURLs(writeRelayURLs)

        let effectiveReadRelays = normalizedReadRelays.isEmpty ? normalizedWriteRelays : normalizedReadRelays
        let effectiveWriteRelays = normalizedWriteRelays.isEmpty ? effectiveReadRelays : normalizedWriteRelays

        let nextSession: Session?
        if normalizedAccount.isEmpty || effectiveReadRelays.isEmpty || effectiveWriteRelays.isEmpty {
            nextSession = nil
        } else {
            nextSession = Session(
                accountPubkey: normalizedAccount,
                nsec: normalizedNsec,
                readRelayURLs: effectiveReadRelays,
                writeRelayURLs: effectiveWriteRelays
            )
        }

        guard nextSession != session else { return }

        session = nextSession
        latestFollowListSnapshot = nil
        lastPublishError = nil
        lastActionFeedback = nil
        hasInFlightFollowPublish = false

        syncTask?.cancel()
        publishTask = nil
        prewarmTask?.cancel()

        guard let session = nextSession else {
            followedPubkeys = []
            Task {
                await ProfileCache.shared.setPriorityPubkeys([])
            }
            return
        }

        let allowLegacyGlobalMigration = authStore.hasSingleAccountHint()
        followedPubkeys = loadPersistedFollowings(
            for: session.accountPubkey,
            allowLegacyGlobalMigration: allowLegacyGlobalMigration
        )
        scheduleProfileCacheUpdate(for: session, snapshot: nil)

        syncTask = Task(priority: .utility) { [weak self] in
            await self?.syncFromRelay(for: session)
        }
    }

    func isFollowing(_ pubkey: String) -> Bool {
        followedPubkeys.contains(normalizePubkey(pubkey))
    }

    func toggleFollow(_ pubkey: String) {
        let normalizedTarget = normalizePubkey(pubkey)
        guard !normalizedTarget.isEmpty else { return }
        let shouldFollow = !followedPubkeys.contains(normalizedTarget)
        setFollowing([normalizedTarget], shouldFollow: shouldFollow)
    }

    func follow(_ pubkey: String) {
        setFollowing([pubkey], shouldFollow: true)
    }

    func unfollow(_ pubkey: String) {
        setFollowing([pubkey], shouldFollow: false)
    }

    func follow(pubkeys: [String]) {
        setFollowing(pubkeys, shouldFollow: true)
    }

    func unfollow(pubkeys: [String]) {
        setFollowing(pubkeys, shouldFollow: false)
    }

    private func setFollowing(_ pubkeys: [String], shouldFollow: Bool) {
        guard let session else { return }
        guard session.nsec != nil else {
            lastPublishError = "Sign in with a private key to follow accounts."
            return
        }

        let normalizedTargets = normalizedUniquePubkeys(pubkeys)
            .filter { $0 != session.accountPubkey }
        guard !normalizedTargets.isEmpty else { return }

        let previous = followedPubkeys
        var updated = previous
        for target in normalizedTargets {
            if shouldFollow {
                updated.insert(target)
            } else {
                updated.remove(target)
            }
        }

        guard updated != previous else { return }

        followedPubkeys = updated
        persistCurrentFollowings()
        lastPublishError = nil
        scheduleProfileCacheUpdate(for: session, snapshot: latestFollowListSnapshot)

        publishTask?.cancel()
        hasInFlightFollowPublish = true
        publishTask = Task { [weak self] in
            await self?.publishFollowList(
                for: session,
                intendedFollowings: updated,
                targetPubkeys: normalizedTargets,
                shouldFollow: shouldFollow,
                rollbackFollowings: previous
            )
        }
    }

    func refreshFromRelay() {
        guard let session else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.syncFromRelay(for: session)
        }
    }

    private func syncFromRelay(for session: Session) async {
        do {
            let relayTargets = followListRelayTargets(for: session)
            guard !relayTargets.isEmpty else { return }

            let cachedSnapshot = await feedService.cachedFollowListSnapshot(pubkey: session.accountPubkey)
            let currentSnapshot = preferredFollowListSnapshot(
                current: latestFollowListSnapshot,
                candidate: cachedSnapshot
            )

            let fetchedSnapshot = try await feedService.fetchFollowListSnapshot(
                relayURLs: relayTargets,
                pubkey: session.accountPubkey
            )

            guard !Task.isCancelled else { return }
            guard self.session == session else { return }

            let resolvedSnapshot = preferredFollowListSnapshot(
                current: currentSnapshot,
                candidate: fetchedSnapshot
            )

            // Preserve optimistic follow toggles while a publish is in-flight.
            // Relay sync can be stale for a short window and would otherwise make
            // the follow button bounce back to "Follow".
            if hasInFlightFollowPublish {
                latestFollowListSnapshot = resolvedSnapshot
                scheduleProfileCacheUpdate(for: session, snapshot: resolvedSnapshot)
                return
            }

            latestFollowListSnapshot = resolvedSnapshot
            followedPubkeys = Set(resolvedSnapshot?.followedPubkeys ?? [])
            persistCurrentFollowings()
            scheduleProfileCacheUpdate(for: session, snapshot: resolvedSnapshot)
        } catch {
            // Keep the locally persisted cache when relay sync fails.
        }
    }

    private func publishFollowList(
        for session: Session,
        intendedFollowings: Set<String>,
        targetPubkeys: [String],
        shouldFollow: Bool,
        rollbackFollowings: Set<String>
    ) async {
        defer {
            if self.session == session {
                hasInFlightFollowPublish = false
            }
        }

        guard let nsec = session.nsec else { return }
        guard let keypair = Keypair(nsec: nsec.lowercased()) else {
            persistFollowings(rollbackFollowings, for: session.accountPubkey)
            guard self.session == session else { return }
            followedPubkeys = rollbackFollowings
            lastPublishError = "Couldn't sign follow update. Please sign in again."
            return
        }

        do {
            let relayTargets = followListRelayTargets(for: session)
            let relaySnapshot = try? await feedService.fetchFollowListSnapshot(
                relayURLs: relayTargets,
                pubkey: session.accountPubkey
            )
            guard !Task.isCancelled else { return }

            let baseSnapshot = preferredFollowListSnapshot(
                current: latestFollowListSnapshot,
                candidate: relaySnapshot
            )
            let mergedRawTags = reconciledFollowListTags(
                baseTags: baseSnapshot?.tags ?? [],
                followedPubkeys: intendedFollowings
            )
            let mergedContent = baseSnapshot?.content ?? ""

            let sdkTags = mergedRawTags.compactMap(decodeSDKTag(from:))
            let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .followList)
                .content(mergedContent)
                .appendTags(contentsOf: sdkTags)
                .build(signedBy: keypair)

            let eventData = try JSONEncoder().encode(event)

            var successfulPublishes = 0
            var firstPublishError: Error?

            for relayURL in session.writeRelayURLs {
                do {
                    try await relayClient.publishEvent(
                        relayURL: relayURL,
                        eventData: eventData,
                        eventID: event.id,
                        timeout: 10
                    )
                    successfulPublishes += 1
                } catch {
                    if firstPublishError == nil {
                        firstPublishError = error
                    }
                }
            }

            if successfulPublishes == 0 {
                throw firstPublishError ?? RelayClientError.publishRejected("Couldn't publish follow event")
            }

            guard !Task.isCancelled else { return }

            let mergedSnapshot = FollowListSnapshot(
                content: mergedContent,
                tags: mergedRawTags,
                createdAt: Int(event.createdAt)
            )
            await feedService.storeFollowListSnapshotLocally(mergedSnapshot, for: session.accountPubkey)
            persistFollowings(Set(mergedSnapshot.followedPubkeys), for: session.accountPubkey)

            guard self.session == session else { return }

            latestFollowListSnapshot = mergedSnapshot
            followedPubkeys = Set(mergedSnapshot.followedPubkeys)
            lastPublishError = nil
            lastActionFeedback = ActionFeedback(pubkeys: targetPubkeys, didFollow: shouldFollow)
            scheduleProfileCacheUpdate(for: session, snapshot: mergedSnapshot)
        } catch {
            persistFollowings(rollbackFollowings, for: session.accountPubkey)
            guard !Task.isCancelled else { return }
            guard self.session == session else { return }

            followedPubkeys = rollbackFollowings
            lastPublishError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            scheduleProfileCacheUpdate(for: session, snapshot: latestFollowListSnapshot)
        }
    }

    private func scheduleProfileCacheUpdate(for session: Session, snapshot: FollowListSnapshot?) {
        let followed = Array(followedPubkeys)
        let relayURLs = session.readRelayURLs.isEmpty ? session.writeRelayURLs : session.readRelayURLs
        let snapshotHints = snapshot?.relayHintsByPubkey ?? latestFollowListSnapshot?.relayHintsByPubkey ?? [:]

        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            await ProfileCache.shared.setPriorityPubkeys(Set(followed))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !followed.isEmpty else { return }

            let cachedSnapshot = await self.feedService.cachedFollowListSnapshot(pubkey: session.accountPubkey)
            guard !Task.isCancelled else { return }

            let mergedHints = mergeRelayHints(
                primary: snapshotHints,
                secondary: cachedSnapshot?.relayHintsByPubkey ?? [:]
            )

            await self.feedService.prewarmProfiles(
                relayURLs: relayURLs,
                pubkeys: followed,
                relayHintsByPubkey: mergedHints
            )
        }
    }

    private func mergeRelayHints(
        primary: [String: [URL]],
        secondary: [String: [URL]]
    ) -> [String: [URL]] {
        guard !secondary.isEmpty else { return primary }

        var merged = primary
        for (pubkey, relayURLs) in secondary {
            var seen = Set<String>()
            var ordered: [URL] = []

            for relayURL in (merged[pubkey] ?? []) + relayURLs {
                let normalized = relayURL.absoluteString.lowercased()
                guard seen.insert(normalized).inserted else { continue }
                ordered.append(relayURL)
            }

            merged[pubkey] = ordered
        }

        return merged
    }

    private func reconciledFollowListTags(
        baseTags: [[String]],
        followedPubkeys: Set<String>
    ) -> [[String]] {
        let normalizedFollowedPubkeys = Set(normalizedUniquePubkeys(Array(followedPubkeys)))
        guard !normalizedFollowedPubkeys.isEmpty else {
            return baseTags.filter { tag in
                tag.first?.lowercased() != "p"
            }
        }

        var mergedTags: [[String]] = []
        var seenFollowedPubkeys = Set<String>()

        for tag in baseTags {
            guard let tagName = tag.first?.lowercased(), tagName == "p" else {
                mergedTags.append(tag)
                continue
            }

            let value = tag.count > 1 ? normalizePubkey(tag[1]) : ""
            guard normalizedFollowedPubkeys.contains(value) else {
                continue
            }

            guard seenFollowedPubkeys.insert(value).inserted else { continue }
            mergedTags.append(tag)
        }

        for followedPubkey in normalizedFollowedPubkeys.sorted() where !seenFollowedPubkeys.contains(followedPubkey) {
            mergedTags.append(["p", followedPubkey])
        }

        return mergedTags
    }

    private func preferredFollowListSnapshot(
        current: FollowListSnapshot?,
        candidate: FollowListSnapshot?
    ) -> FollowListSnapshot? {
        guard let candidate else { return current }
        guard let current else { return candidate }

        let currentFollowings = Set(current.followedPubkeys)
        let candidateFollowings = Set(candidate.followedPubkeys)

        // Older cached follow snapshots may not have createdAt yet. In that case,
        // prefer the richer local graph over a relay snapshot that would
        // destructively shrink the follow set.
        if current.createdAt == nil,
           !currentFollowings.isEmpty,
           currentFollowings.isSuperset(of: candidateFollowings),
           currentFollowings != candidateFollowings {
            return current
        }

        switch (current.createdAt, candidate.createdAt) {
        case let (currentCreatedAt?, candidateCreatedAt?) where candidateCreatedAt != currentCreatedAt:
            return candidateCreatedAt > currentCreatedAt ? candidate : current
        case (nil, _?):
            return candidate
        case (_?, nil):
            return current
        default:
            break
        }

        if currentFollowings.isSuperset(of: candidateFollowings) && currentFollowings != candidateFollowings {
            return current
        }

        if candidateFollowings.isSuperset(of: currentFollowings) && candidateFollowings != currentFollowings {
            return candidate
        }

        return candidate
    }

    private func followListRelayTargets(for session: Session) -> [URL] {
        normalizedRelayURLs(session.readRelayURLs + session.writeRelayURLs)
    }

    private func decodeSDKTag(from raw: [String]) -> NostrSDK.Tag? {
        guard raw.count >= 2 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
            return nil
        }
        return tag
    }

    private func loadPersistedFollowings(
        for accountPubkey: String,
        allowLegacyGlobalMigration: Bool
    ) -> Set<String> {
        let accountKey = defaultsKey(for: accountPubkey)

        if let saved = defaults.stringArray(forKey: accountKey) {
            return Set(saved.map(normalizePubkey).filter { !$0.isEmpty })
        }

        let legacyAccountKey = legacyDefaultsKey(for: accountPubkey)
        if let legacySaved = defaults.stringArray(forKey: legacyAccountKey), !legacySaved.isEmpty {
            let migrated = Set(legacySaved.map(normalizePubkey).filter { !$0.isEmpty })
            defaults.set(Array(migrated).sorted(), forKey: accountKey)
            return migrated
        }

        // One-time migration from older global cache key.
        if allowLegacyGlobalMigration,
           let legacySaved = defaults.stringArray(forKey: legacyKey),
           !legacySaved.isEmpty {
            let migrated = Set(legacySaved.map(normalizePubkey).filter { !$0.isEmpty })
            defaults.set(Array(migrated).sorted(), forKey: accountKey)
            defaults.removeObject(forKey: legacyKey)
            return migrated
        }

        return []
    }

    private func persistCurrentFollowings() {
        guard let accountPubkey = session?.accountPubkey else { return }
        persistFollowings(followedPubkeys, for: accountPubkey)
    }

    private func persistFollowings(_ followings: Set<String>, for accountPubkey: String) {
        defaults.set(Array(followings).sorted(), forKey: defaultsKey(for: accountPubkey))
    }

    private func defaultsKey(for accountPubkey: String) -> String {
        "\(keyPrefix).\(accountPubkey)"
    }

    private func legacyDefaultsKey(for accountPubkey: String) -> String {
        "\(legacyKeyPrefix).\(accountPubkey)"
    }

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedUniquePubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys {
            let normalized = normalizePubkey(pubkey)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func normalizeNsec(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
}
