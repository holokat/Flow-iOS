import Combine
import Foundation

struct NoteReactionEventSnapshot: Equatable, Sendable {
    static let empty = NoteReactionEventSnapshot(stats: NoteReactionStats(), isPublishing: false)

    let stats: NoteReactionStats
    let isPublishing: Bool

    var reactionCount: Int {
        stats.reactions.reduce(0) { partialResult, reaction in
            partialResult + reaction.totalWeight
        }
    }

    var replyCount: Int {
        stats.replyIDs.count
    }

    var repostCount: Int {
        stats.repostIDs.count
    }

    func currentUserReaction(currentPubkey: String?) -> NoteReaction? {
        guard let normalizedCurrentPubkey = Self.normalizePubkey(currentPubkey) else { return nil }
        return stats.reactions.first(where: { reaction in
            Self.normalizePubkey(reaction.pubkey) == normalizedCurrentPubkey
        })
    }

    func isReactedByCurrentUser(currentPubkey: String?) -> Bool {
        currentUserReaction(currentPubkey: currentPubkey) != nil
    }

    private static func normalizePubkey(_ value: String?) -> String? {
        let trimmed = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class NoteReactionStatsService: ObservableObject {
    static let shared = NoteReactionStatsService()

    struct OptimisticToggleState {
        let previousReaction: NoteReaction?
        let optimisticReactionID: String?
    }

    @Published private(set) var statsByEventID: [String: NoteReactionStats] = [:]
    @Published private(set) var publishingEventIDs = Set<String>()

    private struct PendingRequest {
        let eventID: String
        let relayURL: URL
    }

    private let relayClient: any NostrRelayEventFetching
    private let store: NoteReactionStatsStore

    private let fetchDebounceNanos: UInt64 = 40_000_000
    private let persistDebounceNanos: UInt64 = 80_000_000
    private let batchMaxNotes = 60
    private let optimisticReactionPrefix = "optimistic-reaction-"
    private let statsFreshnessInterval: TimeInterval = 45
    private let fetchRetryCooldownInterval: TimeInterval = 15
    private let engagementFetchKinds = [
        FeedKindFilters.shortTextNote,
        FeedKindFilters.repost,
        7,
        16,
        FeedKindFilters.comment,
        FeedKindFilters.voiceComment
    ]

    private var hydratedEventIDs = Set<String>()
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingPersistEventIDs = Set<String>()
    private var suppressedReactionIDs = Set<String>()
    private var lastFetchAttemptByRequestKey: [String: Date] = [:]
    private var eventSnapshotPublishers: [String: CurrentValueSubject<NoteReactionEventSnapshot, Never>] = [:]

    private var fetchTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?

    init(
        relayClient: any NostrRelayEventFetching = NostrRelayClient(),
        store: NoteReactionStatsStore = .shared
    ) {
        self.relayClient = relayClient
        self.store = store
    }

    func prefetch(events: [NostrEvent], relayURL: URL) {
        let noteIDs = events.map(\.id)
        guard !noteIDs.isEmpty else { return }

        Task { @MainActor [weak self] in
            await self?.prepareAndQueue(noteIDs: noteIDs, relayURL: relayURL)
        }
    }

    func prefetch(events: [NostrEvent], relayURLs: [URL]) {
        let noteIDs = events.map(\.id)
        guard !noteIDs.isEmpty else { return }

        let normalizedRelayURLs = normalizedRelayTargets(relayURLs)
        guard !normalizedRelayURLs.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for relayURL in normalizedRelayURLs {
                await self.prepareAndQueue(noteIDs: noteIDs, relayURL: relayURL)
            }
        }
    }

    func publisher(for eventID: String) -> AnyPublisher<NoteReactionEventSnapshot, Never> {
        let normalizedTargetEventID = normalizedEventID(eventID)
        guard !normalizedTargetEventID.isEmpty else {
            return Just(.empty).eraseToAnyPublisher()
        }

        return snapshotPublisher(for: normalizedTargetEventID)
            .eraseToAnyPublisher()
    }

    func currentSnapshot(for eventID: String) -> NoteReactionEventSnapshot {
        snapshot(for: eventID)
    }

    func reactionCount(for eventID: String) -> Int {
        snapshot(for: eventID).reactionCount
    }

    func replyCount(for eventID: String) -> Int {
        snapshot(for: eventID).replyCount
    }

    func repostCount(for eventID: String) -> Int {
        snapshot(for: eventID).repostCount
    }

    func currentUserReaction(for eventID: String, currentPubkey: String?) -> NoteReaction? {
        snapshot(for: eventID).currentUserReaction(currentPubkey: currentPubkey)
    }

    func isReactedByCurrentUser(for eventID: String, currentPubkey: String?) -> Bool {
        snapshot(for: eventID).isReactedByCurrentUser(currentPubkey: currentPubkey)
    }

    func isPublishingReaction(for eventID: String) -> Bool {
        snapshot(for: eventID).isPublishing
    }

    func beginPublishingReaction(for eventID: String) -> Bool {
        let normalizedEventID = normalizedEventID(eventID)
        guard !normalizedEventID.isEmpty else { return false }
        guard !publishingEventIDs.contains(normalizedEventID) else { return false }
        setPublishing(true, for: normalizedEventID)
        return true
    }

    func endPublishingReaction(for eventID: String) {
        setPublishing(false, for: normalizedEventID(eventID))
    }

    func applyOptimisticToggle(
        for eventID: String,
        currentPubkey: String?,
        bonusCount: Int = 0
    ) -> OptimisticToggleState? {
        let normalizedTargetEventID = normalizedEventID(eventID)
        guard !normalizedTargetEventID.isEmpty,
              let normalizedCurrentPubkey = normalizePubkey(currentPubkey) else {
            return nil
        }

        let previousReaction = currentUserReaction(
            for: normalizedTargetEventID,
            currentPubkey: normalizedCurrentPubkey
        )

        var stats = statsByEventID[normalizedTargetEventID] ?? NoteReactionStats()
        let now = Int(Date().timeIntervalSince1970)

        if let previousReaction {
            suppressedReactionIDs.insert(normalizedEventID(previousReaction.id))
            removeReaction(id: previousReaction.id, from: &stats)
            if ReactionBonusTag.normalizedBonusCount(bonusCount) == 0 {
                stats.updatedAt = now
                setStats(stats, for: normalizedTargetEventID)
                return OptimisticToggleState(previousReaction: previousReaction, optimisticReactionID: nil)
            }
        }

        let optimisticReactionID = "\(optimisticReactionPrefix)\(UUID().uuidString.lowercased())"
        removeOptimisticReactions(for: normalizedCurrentPubkey, from: &stats)
        upsertReaction(
            NoteReaction(
                id: optimisticReactionID,
                pubkey: normalizedCurrentPubkey,
                createdAt: now,
                emoji: "+",
                bonusCount: bonusCount
            ),
            in: &stats
        )
        stats.updatedAt = now
        setStats(stats, for: normalizedTargetEventID)
        return OptimisticToggleState(previousReaction: nil, optimisticReactionID: optimisticReactionID)
    }

    func rollbackOptimisticToggle(for eventID: String, snapshot: OptimisticToggleState?) {
        guard let snapshot else { return }

        let normalizedTargetEventID = normalizedEventID(eventID)
        guard !normalizedTargetEventID.isEmpty else { return }

        var stats = statsByEventID[normalizedTargetEventID] ?? NoteReactionStats()
        if let optimisticReactionID = snapshot.optimisticReactionID {
            removeReaction(id: optimisticReactionID, from: &stats)
        }
        if let previousReaction = snapshot.previousReaction {
            suppressedReactionIDs.remove(normalizedEventID(previousReaction.id))
            upsertReaction(previousReaction, in: &stats)
        }
        stats.updatedAt = Int(Date().timeIntervalSince1970)
        setStats(stats, for: normalizedTargetEventID)
    }

    func registerPublishedReaction(_ event: NostrEvent, targetEventID: String) {
        let normalizedTargetEventID = normalizedEventID(targetEventID)
        guard !normalizedTargetEventID.isEmpty else { return }

        suppressedReactionIDs.remove(normalizedEventID(event.id))
        var pendingStatsUpdates: [String: NoteReactionStats] = [:]
        let touchedIDs = mergeReactionEvents(
            [event],
            trackedEventIDs: Set([normalizedTargetEventID]),
            pendingStatsUpdates: &pendingStatsUpdates
        )
        guard !touchedIDs.isEmpty else { return }

        let now = Int(Date().timeIntervalSince1970)
        for eventID in touchedIDs {
            var stats = pendingStats(for: eventID, pendingStatsUpdates: pendingStatsUpdates)
            stats.updatedAt = now
            pendingStatsUpdates[eventID] = stats
        }
        commitPendingStats(pendingStatsUpdates)
        schedulePersist(eventIDs: Array(touchedIDs))
    }

    func registerDeletedReaction(reactionID: String, targetEventID: String) {
        let normalizedTargetEventID = normalizedEventID(targetEventID)
        let normalizedReactionID = normalizedEventID(reactionID)
        guard !normalizedTargetEventID.isEmpty, !normalizedReactionID.isEmpty else { return }

        suppressedReactionIDs.insert(normalizedReactionID)
        var stats = statsByEventID[normalizedTargetEventID] ?? NoteReactionStats()
        let priorReactionCount = stats.reactions.count
        let removedReactionID = stats.reactionIDs.remove(normalizedReactionID) != nil
        stats.reactions.removeAll { normalizedEventID($0.id) == normalizedReactionID }
        guard removedReactionID || stats.reactions.count != priorReactionCount else { return }

        stats.updatedAt = Int(Date().timeIntervalSince1970)
        setStats(stats, for: normalizedTargetEventID)
        schedulePersist(eventIDs: [normalizedTargetEventID])
    }

    private func prepareAndQueue(noteIDs: [String], relayURL: URL) async {
        await hydrateFromStoreIfNeeded(noteIDs: noteIDs)

        let now = Date()
        let uniqueIDs = Set(noteIDs.map { normalizedEventID($0) }.filter { !$0.isEmpty })
        for noteID in uniqueIDs {
            guard shouldQueueFetch(for: noteID, relayURL: relayURL, now: now) else { continue }
            let key = pendingKey(eventID: noteID, relayURL: relayURL)
            pendingRequests[key] = PendingRequest(eventID: noteID, relayURL: relayURL)
            lastFetchAttemptByRequestKey[key] = now
        }

        scheduleBatchFetch()
    }

    private func hydrateFromStoreIfNeeded(noteIDs: [String]) async {
        let normalizedNoteIDs = Set(noteIDs.map { normalizedEventID($0) }.filter { !$0.isEmpty })
        let idsToHydrate = normalizedNoteIDs.filter { !hydratedEventIDs.contains($0) }
        guard !idsToHydrate.isEmpty else { return }

        idsToHydrate.forEach { hydratedEventIDs.insert($0) }
        let cached = await store.getMany(noteIDs: Array(idsToHydrate))

        for (eventID, stats) in cached {
            let existingUpdatedAt = statsByEventID[eventID]?.updatedAt ?? 0
            let incomingUpdatedAt = stats.updatedAt ?? 0
            if incomingUpdatedAt >= existingUpdatedAt {
                setStats(stats, for: eventID)
            }
        }
    }

    private func scheduleBatchFetch() {
        guard fetchTask == nil else { return }
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.fetchDebounceNanos)
            await self.flushBatchFetches()
        }
    }

    private func flushBatchFetches() async {
        fetchTask = nil
        guard !pendingRequests.isEmpty else { return }

        let batch = Array(pendingRequests.values.prefix(batchMaxNotes))
        batch.forEach { pendingRequests.removeValue(forKey: pendingKey(eventID: $0.eventID, relayURL: $0.relayURL)) }

        let requestsByRelay = Dictionary(grouping: batch, by: { $0.relayURL.absoluteString.lowercased() })
        struct RelayEngagementFetchPlan {
            let relayURL: URL
            let eventIDs: [String]
            let since: Int?
            let engagementLimit: Int
        }

        struct RelayEngagementFetchResult {
            let relayURL: URL
            let eventIDs: [String]
            let events: [NostrEvent]?
        }

        var plans: [RelayEngagementFetchPlan] = []
        plans.reserveCapacity(requestsByRelay.count)

        for (_, relayRequests) in requestsByRelay {
            guard let relayURL = relayRequests.first?.relayURL else { continue }
            let eventIDs = Array(Set(relayRequests.map(\.eventID)))
            guard !eventIDs.isEmpty else { continue }

            let since = eventIDs.compactMap { statsByEventID[$0]?.updatedAt }.min()
            let engagementLimit = min(2_400, max(240, eventIDs.count * 48))
            plans.append(
                RelayEngagementFetchPlan(
                    relayURL: relayURL,
                    eventIDs: eventIDs,
                    since: since,
                    engagementLimit: engagementLimit
                )
            )
        }

        let plannedFetchCountByEventID = plans.reduce(into: [String: Int]()) { counts, plan in
            for eventID in plan.eventIDs {
                counts[eventID, default: 0] += 1
            }
        }

        let engagementFetchKinds = self.engagementFetchKinds
        let fetchResults = await withTaskGroup(of: RelayEngagementFetchResult.self, returning: [RelayEngagementFetchResult].self) { group in
            for plan in plans {
                group.addTask { [relayClient, engagementFetchKinds] in
                    let filter = NostrFilter(
                        kinds: engagementFetchKinds,
                        limit: plan.engagementLimit,
                        since: plan.since,
                        tagFilters: ["e": plan.eventIDs]
                    )

                    do {
                        let engagementEvents = try await relayClient.fetchEvents(
                            relayURL: plan.relayURL,
                            filter: filter,
                            timeout: 12
                        )
                        return RelayEngagementFetchResult(
                            relayURL: plan.relayURL,
                            eventIDs: plan.eventIDs,
                            events: engagementEvents
                        )
                    } catch {
                        return RelayEngagementFetchResult(
                            relayURL: plan.relayURL,
                            eventIDs: plan.eventIDs,
                            events: nil
                        )
                    }
                }
            }

            var results: [RelayEngagementFetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        var successfulFetchCountByEventID: [String: Int] = [:]
        var touchedEventIDs = Set<String>()
        var persistedEventIDs = Set<String>()
        var pendingStatsUpdates: [String: NoteReactionStats] = [:]

        for result in fetchResults {
            guard let engagementEvents = result.events else { continue }

            let touchedIDs = mergeEngagementEvents(
                engagementEvents,
                trackedEventIDs: Set(result.eventIDs),
                pendingStatsUpdates: &pendingStatsUpdates
            )
            for eventID in result.eventIDs {
                successfulFetchCountByEventID[eventID, default: 0] += 1
            }

            touchedEventIDs.formUnion(touchedIDs)
            persistedEventIDs.formUnion(touchedIDs)
        }

        let now = Int(Date().timeIntervalSince1970)
        for (eventID, successfulFetchCount) in successfulFetchCountByEventID {
            let plannedFetchCount = plannedFetchCountByEventID[eventID] ?? successfulFetchCount
            let hasFreshEngagementEvent = touchedEventIDs.contains(eventID)
            let hasCorroboratedEmptyResult = successfulFetchCount >= min(plannedFetchCount, 2)
            guard hasFreshEngagementEvent || hasCorroboratedEmptyResult else { continue }

            var stats = pendingStats(for: eventID, pendingStatsUpdates: pendingStatsUpdates)
            stats.updatedAt = now
            pendingStatsUpdates[eventID] = stats
            persistedEventIDs.insert(eventID)
        }

        commitPendingStats(pendingStatsUpdates)

        if !persistedEventIDs.isEmpty {
            schedulePersist(eventIDs: Array(persistedEventIDs))
        }

        if !pendingRequests.isEmpty {
            scheduleBatchFetch()
        }
    }

    private func mergeEngagementEvents(
        _ events: [NostrEvent],
        trackedEventIDs: Set<String>,
        pendingStatsUpdates: inout [String: NoteReactionStats]
    ) -> Set<String> {
        var touched = mergeReactionEvents(
            events,
            trackedEventIDs: trackedEventIDs,
            pendingStatsUpdates: &pendingStatsUpdates
        )
        touched.formUnion(
            mergeReplyEvents(
                events,
                trackedEventIDs: trackedEventIDs,
                pendingStatsUpdates: &pendingStatsUpdates
            )
        )
        touched.formUnion(
            mergeRepostEvents(
                events,
                trackedEventIDs: trackedEventIDs,
                pendingStatsUpdates: &pendingStatsUpdates
            )
        )
        return touched
    }

    private func mergeReactionEvents(
        _ events: [NostrEvent],
        trackedEventIDs: Set<String>,
        pendingStatsUpdates: inout [String: NoteReactionStats]
    ) -> Set<String> {
        var touched = Set<String>()

        for event in events where event.kind == 7 {
            guard let lastEventReferenceID = event.lastEventReferenceID else { continue }
            let targetEventID = normalizedEventID(lastEventReferenceID)
            guard !targetEventID.isEmpty else { continue }
            guard trackedEventIDs.contains(targetEventID) else { continue }
            guard let emoji = normalizedReactionEmoji(from: event.content) else { continue }
            let normalizedReactionID = normalizedEventID(event.id)
            guard !suppressedReactionIDs.contains(normalizedReactionID) else { continue }
            let normalizedPubkey = normalizePubkey(event.pubkey) ?? event.pubkey.lowercased()

            var stats = pendingStats(for: targetEventID, pendingStatsUpdates: pendingStatsUpdates)
            removeOptimisticReactions(for: normalizedPubkey, from: &stats)
            guard !stats.reactionIDs.contains(normalizedReactionID) else { continue }

            upsertReaction(
                NoteReaction(
                    id: normalizedReactionID,
                    pubkey: normalizedPubkey,
                    createdAt: event.createdAt,
                    emoji: emoji,
                    bonusCount: ReactionBonusTag.bonusCount(in: event.tags)
                ),
                in: &stats
            )

            pendingStatsUpdates[targetEventID] = stats
            touched.insert(targetEventID)
        }

        return touched
    }

    private func mergeReplyEvents(
        _ events: [NostrEvent],
        trackedEventIDs: Set<String>,
        pendingStatsUpdates: inout [String: NoteReactionStats]
    ) -> Set<String> {
        var touched = Set<String>()

        for event in events where event.isReplyNote {
            guard let targetEventID = ReplyCountEstimator.repliedEventID(
                for: event,
                validEventIDs: trackedEventIDs
            ) else { continue }
            let replyID = normalizedEventID(event.id)
            guard !replyID.isEmpty else { continue }

            var stats = pendingStats(for: targetEventID, pendingStatsUpdates: pendingStatsUpdates)
            guard stats.replyIDs.insert(replyID).inserted else { continue }
            pendingStatsUpdates[targetEventID] = stats
            touched.insert(targetEventID)
        }

        return touched
    }

    private func mergeRepostEvents(
        _ events: [NostrEvent],
        trackedEventIDs: Set<String>,
        pendingStatsUpdates: inout [String: NoteReactionStats]
    ) -> Set<String> {
        var touched = Set<String>()

        for event in events where event.isRepost {
            guard let repostTargetEventID = event.repostTargetEventID else { continue }
            let targetEventID = normalizedEventID(repostTargetEventID)
            guard !targetEventID.isEmpty else { continue }
            guard trackedEventIDs.contains(targetEventID) else { continue }
            let repostID = normalizedEventID(event.id)
            guard !repostID.isEmpty else { continue }

            var stats = pendingStats(for: targetEventID, pendingStatsUpdates: pendingStatsUpdates)
            guard stats.repostIDs.insert(repostID).inserted else { continue }
            pendingStatsUpdates[targetEventID] = stats
            touched.insert(targetEventID)
        }

        return touched
    }

    private func normalizedReactionEmoji(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Match web fallback: shortcode reactions become generic "+" if not directly resolvable.
        if trimmed.hasPrefix(":"), trimmed.hasSuffix(":"), trimmed.count > 2 {
            return "+"
        }

        return trimmed
    }

    private func schedulePersist(eventIDs: [String]) {
        guard !eventIDs.isEmpty else { return }
        pendingPersistEventIDs.formUnion(eventIDs)
        guard persistTask == nil else { return }

        persistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.persistDebounceNanos)
            await self.flushPersist()
        }
    }

    private func flushPersist() async {
        persistTask = nil
        let ids = Array(pendingPersistEventIDs)
        pendingPersistEventIDs.removeAll()
        guard !ids.isEmpty else { return }

        var entries: [String: NoteReactionStats] = [:]
        for eventID in ids {
            guard let stats = statsByEventID[eventID] else { continue }
            entries[eventID] = stats
        }

        if !entries.isEmpty {
            await store.putMany(entries: entries)
        }

        if !pendingPersistEventIDs.isEmpty {
            schedulePersist(eventIDs: Array(pendingPersistEventIDs))
        }
    }

    private func pendingKey(eventID: String, relayURL: URL) -> String {
        "\(relayURL.absoluteString.lowercased())|\(normalizedEventID(eventID))"
    }

    private func snapshot(for eventID: String) -> NoteReactionEventSnapshot {
        let normalizedTargetEventID = normalizedEventID(eventID)
        guard !normalizedTargetEventID.isEmpty else { return .empty }
        return buildSnapshot(for: normalizedTargetEventID)
    }

    private func pendingStats(
        for eventID: String,
        pendingStatsUpdates: [String: NoteReactionStats]
    ) -> NoteReactionStats {
        pendingStatsUpdates[eventID] ?? statsByEventID[eventID] ?? NoteReactionStats()
    }

    private func commitPendingStats(_ pendingStatsUpdates: [String: NoteReactionStats]) {
        guard !pendingStatsUpdates.isEmpty else { return }

        for (eventID, stats) in pendingStatsUpdates {
            setStats(stats, for: eventID)
        }
    }

    private func buildSnapshot(for eventID: String) -> NoteReactionEventSnapshot {
        NoteReactionEventSnapshot(
            stats: statsByEventID[eventID] ?? NoteReactionStats(),
            isPublishing: publishingEventIDs.contains(eventID)
        )
    }

    private func snapshotPublisher(for eventID: String) -> CurrentValueSubject<NoteReactionEventSnapshot, Never> {
        if let existingPublisher = eventSnapshotPublishers[eventID] {
            return existingPublisher
        }

        let publisher = CurrentValueSubject<NoteReactionEventSnapshot, Never>(buildSnapshot(for: eventID))
        eventSnapshotPublishers[eventID] = publisher
        return publisher
    }

    private func publishSnapshot(for eventID: String) {
        let normalizedTargetEventID = normalizedEventID(eventID)
        guard !normalizedTargetEventID.isEmpty else { return }

        let snapshot = buildSnapshot(for: normalizedTargetEventID)
        let publisher = snapshotPublisher(for: normalizedTargetEventID)
        guard publisher.value != snapshot else { return }
        publisher.send(snapshot)
    }

    private func setStats(_ stats: NoteReactionStats, for eventID: String) {
        let normalizedTargetEventID = normalizedEventID(eventID)
        guard !normalizedTargetEventID.isEmpty else { return }
        statsByEventID[normalizedTargetEventID] = stats
        publishSnapshot(for: normalizedTargetEventID)
    }

    private func setPublishing(_ isPublishing: Bool, for eventID: String) {
        let normalizedTargetEventID = normalizedEventID(eventID)
        guard !normalizedTargetEventID.isEmpty else { return }

        let didChange: Bool
        if isPublishing {
            didChange = publishingEventIDs.insert(normalizedTargetEventID).inserted
        } else {
            didChange = publishingEventIDs.remove(normalizedTargetEventID) != nil
        }

        guard didChange else { return }
        publishSnapshot(for: normalizedTargetEventID)
    }

    private func normalizedRelayTargets(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    private func shouldQueueFetch(for eventID: String, relayURL: URL, now: Date) -> Bool {
        let key = pendingKey(eventID: eventID, relayURL: relayURL)
        if pendingRequests[key] != nil {
            return false
        }

        if let updatedAt = statsByEventID[eventID]?.updatedAt {
            let updatedDate = Date(timeIntervalSince1970: TimeInterval(updatedAt))
            if now.timeIntervalSince(updatedDate) < statsFreshnessInterval {
                return false
            }
        }

        if let lastAttempt = lastFetchAttemptByRequestKey[key],
           now.timeIntervalSince(lastAttempt) < fetchRetryCooldownInterval {
            return false
        }

        return true
    }

    private func removeReaction(id reactionID: String, from stats: inout NoteReactionStats) {
        let normalizedReactionID = normalizedEventID(reactionID)
        stats.reactionIDs.remove(normalizedReactionID)
        stats.reactions.removeAll { normalizedEventID($0.id) == normalizedReactionID }
    }

    private func removeOptimisticReactions(for pubkey: String, from stats: inout NoteReactionStats) {
        let reactionIDsToRemove = stats.reactions
            .filter { reaction in
                normalizePubkey(reaction.pubkey) == pubkey && isOptimisticReactionID(reaction.id)
            }
            .map(\.id)

        guard !reactionIDsToRemove.isEmpty else { return }
        for reactionID in reactionIDsToRemove {
            removeReaction(id: reactionID, from: &stats)
        }
    }

    private func upsertReaction(_ reaction: NoteReaction, in stats: inout NoteReactionStats) {
        removeReaction(id: reaction.id, from: &stats)
        stats.reactionIDs.insert(normalizedEventID(reaction.id))
        stats.reactions.append(reaction)
        stats.reactions.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func normalizedEventID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isOptimisticReactionID(_ value: String) -> Bool {
        normalizedEventID(value).hasPrefix(optimisticReactionPrefix)
    }

    private func normalizePubkey(_ value: String?) -> String? {
        let trimmed = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
