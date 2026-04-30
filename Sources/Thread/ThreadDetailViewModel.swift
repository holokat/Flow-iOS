import Foundation

@MainActor
final class ThreadDetailViewModel: ObservableObject {
    @Published private(set) var rootItem: FeedItem
    @Published private(set) var replies: [FeedItem] = []
    @Published private(set) var spamReplies: [FeedItem] = []
    @Published private(set) var noteActivityRows: [ActivityRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNoteActivity = false
    @Published var isSpamRepliesExpanded = false
    @Published var errorMessage: String?
    @Published var noteActivityErrorMessage: String?

    let relayURL: URL
    let readRelayURLs: [URL]

    private let service: NostrFeedService
    private var hasLoadedInitialState = false
    private var hasLoadedNoteActivityState = false
    private var rootHydrationTask: Task<Void, Never>?
    private var itemHydrationTask: Task<Void, Never>?
    private var replyRefreshTask: Task<Void, Never>?
    private var noteActivityRefreshTask: Task<Void, Never>?
    private var spamScoreTasks: [String: Task<Void, Never>] = [:]
    private var spamScoreAttemptedPubkeys = Set<String>()
    private var rawReplies: [FeedItem] = []
    private var spamFilterCurrentUserPubkey: String?
    private var spamFilterFollowedPubkeys = Set<String>()
    private static let fastThreadFetchTimeout: TimeInterval = 3
    private static let fastThreadRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let fullThreadFetchTimeout: TimeInterval = 8
    private static let fullThreadRelayFetchMode: RelayFetchMode = .allRelays
    private static let fastNoteActivityFetchTimeout: TimeInterval = 3
    private static let fastNoteActivityRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let fullNoteActivityFetchTimeout: TimeInterval = 8
    private static let fullNoteActivityRelayFetchMode: RelayFetchMode = .allRelays

    init(
        rootItem: FeedItem,
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        service: NostrFeedService = NostrFeedService()
    ) {
        self.rootItem = rootItem
        let normalizedReadRelays = Self.normalizedRelayURLs(readRelayURLs ?? [relayURL])
        self.readRelayURLs = normalizedReadRelays.isEmpty ? [relayURL] : normalizedReadRelays
        self.relayURL = self.readRelayURLs.first ?? relayURL
        self.service = service
    }

    deinit {
        rootHydrationTask?.cancel()
        itemHydrationTask?.cancel()
        replyRefreshTask?.cancel()
        noteActivityRefreshTask?.cancel()
        spamScoreTasks.values.forEach { $0.cancel() }
    }

    var repliesHeaderText: String {
        let replyCount = replies.count + spamReplies.count
        if replyCount == 0 {
            return "Replies"
        }
        return "Replies (\(replyCount))"
    }

    var hasLoadedNoteActivity: Bool {
        hasLoadedNoteActivityState
    }

    private var muteFilterSnapshot: MuteFilterSnapshot {
        MuteStore.shared.filterSnapshot
    }

    func loadIfNeeded() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        await refresh()
    }

    func loadNoteActivityIfNeeded() async {
        guard !hasLoadedNoteActivityState else { return }
        hasLoadedNoteActivityState = true
        await refreshNoteActivity()
    }

    func configureSpamFilter(currentUserPubkey: String?, followedPubkeys: Set<String>) {
        let normalizedUser = currentUserPubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedFollowed = Set(
            followedPubkeys.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            .filter { !$0.isEmpty }
        )

        guard spamFilterCurrentUserPubkey != normalizedUser || spamFilterFollowedPubkeys != normalizedFollowed else {
            return
        }

        spamFilterCurrentUserPubkey = normalizedUser
        spamFilterFollowedPubkeys = normalizedFollowed
        Task { [weak self] in
            await self?.rebuildReplyBuckets()
        }
    }

    func spamPreferencesChanged() {
        spamScoreTasks.values.forEach { $0.cancel() }
        spamScoreTasks = [:]
        spamScoreAttemptedPubkeys = []
        Task { [weak self] in
            await self?.rebuildReplyBuckets()
        }
    }

    func toggleSpamRepliesExpanded() {
        isSpamRepliesExpanded.toggle()
    }

    func markSpamReplyAuthorAsNotSpam(_ pubkey: String) {
        AppSettingsStore.shared.addSpamReplySafelistedPubkey(pubkey)
        Task { [weak self] in
            await self?.rebuildReplyBuckets()
        }
    }

    func refresh(includeNoteActivity: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        rootHydrationTask?.cancel()
        itemHydrationTask?.cancel()
        replyRefreshTask?.cancel()
        rootHydrationTask = nil
        itemHydrationTask = nil

        defer {
            isLoading = false
        }

        scheduleRootHydration()

        do {
            rawReplies = mergeWithLocalPublicationReplies(try await service.fetchThreadReplies(
                relayURLs: readRelayURLs,
                rootEventID: rootItem.displayEventID,
                includeNestedReplies: false,
                hydrationMode: .cachedProfilesOnly,
                fetchTimeout: Self.fastThreadFetchTimeout,
                relayFetchMode: Self.fastThreadRelayFetchMode,
                moderationSnapshot: muteFilterSnapshot
            ))
            await rebuildReplyBuckets()
            scheduleItemHydration(for: rawReplies)
        } catch {
            if replies.isEmpty {
                errorMessage = "Couldn't load replies right now."
            } else {
                errorMessage = "Couldn't refresh replies."
            }
        }
        scheduleReplyRefresh()

        if includeNoteActivity || hasLoadedNoteActivityState {
            await refreshNoteActivity()
        }
    }

    func refreshNoteActivity() async {
        guard !isLoadingNoteActivity else { return }
        isLoadingNoteActivity = true
        noteActivityErrorMessage = nil
        noteActivityRefreshTask?.cancel()

        defer {
            isLoadingNoteActivity = false
        }

        do {
            noteActivityRows = try await service.fetchThreadNoteActivityRows(
                relayURLs: readRelayURLs,
                rootEventID: rootItem.displayEventID,
                rootAuthorPubkey: rootItem.displayAuthorPubkey,
                fetchTimeout: Self.fastNoteActivityFetchTimeout,
                relayFetchMode: Self.fastNoteActivityRelayFetchMode,
                profileFetchTimeout: Self.fastNoteActivityFetchTimeout,
                profileRelayFetchMode: Self.fastNoteActivityRelayFetchMode
            )
        } catch {
            if noteActivityRows.isEmpty {
                noteActivityErrorMessage = "Couldn't load reactions right now."
            } else {
                noteActivityErrorMessage = "Couldn't refresh reactions."
            }
        }

        scheduleNoteActivityRefresh()
    }

    func appendLocalReply(_ item: FeedItem) {
        guard !pruneMutedItems([item]).isEmpty else { return }
        guard item.event.id.lowercased() != rootItem.displayEventID.lowercased() else { return }
        guard !rawReplies.contains(where: { $0.id.lowercased() == item.id.lowercased() }) else { return }
        rawReplies.append(item)
        rawReplies = Self.sortedReplies(rawReplies)
        Task { [weak self] in
            await self?.rebuildReplyBuckets()
        }
    }

    private func scheduleRootHydration() {
        let sourceEvent = rootItem.event
        let relayTargets = readRelayURLs

        rootHydrationTask = Task { [weak self] in
            guard let self else { return }

            await self.hydrateRootItem(
                sourceEvent: sourceEvent,
                relayURLs: relayTargets,
                hydrationMode: .cachedProfilesOnly
            )
            guard !Task.isCancelled else { return }

            await self.hydrateRootItem(
                sourceEvent: sourceEvent,
                relayURLs: relayTargets,
                hydrationMode: .full
            )
        }
    }

    private func scheduleItemHydration(for sourceItems: [FeedItem]) {
        itemHydrationTask?.cancel()

        let events = sourceItems.map(\.event)
        guard !events.isEmpty else { return }
        let relayTargets = readRelayURLs

        itemHydrationTask = Task { [weak self] in
            guard let self else { return }
            let hydrated = await self.service.buildFeedItems(
                relayURLs: relayTargets,
                events: events,
                hydrationMode: .full,
                moderationSnapshot: self.muteFilterSnapshot
            )
            guard !Task.isCancelled else { return }
            guard !hydrated.isEmpty else { return }

            await MainActor.run {
                self.mergeKeepingThreadOrder(itemsToMerge: hydrated)
            }
        }
    }

    private func scheduleReplyRefresh() {
        replyRefreshTask?.cancel()

        let relayTargets = readRelayURLs
        let rootEventID = rootItem.displayEventID
        let moderationSnapshot = muteFilterSnapshot

        replyRefreshTask = Task { [weak self] in
            guard let self else { return }

            do {
                let refreshedReplies = try await self.service.fetchThreadReplies(
                    relayURLs: relayTargets,
                    rootEventID: rootEventID,
                    hydrationMode: .cachedProfilesOnly,
                    fetchTimeout: Self.fullThreadFetchTimeout,
                    relayFetchMode: Self.fullThreadRelayFetchMode,
                    moderationSnapshot: moderationSnapshot
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.rootItem.displayEventID.lowercased() == rootEventID.lowercased() else { return }
                    let visibleReplies = self.mergeWithLocalPublicationReplies(
                        refreshedReplies,
                        rootEventID: rootEventID,
                        snapshot: moderationSnapshot
                    )
                    guard !visibleReplies.isEmpty || self.rawReplies.isEmpty else { return }
                    self.errorMessage = nil
                    self.rawReplies = visibleReplies
                    Task { [weak self] in
                        await self?.rebuildReplyBuckets()
                    }
                    self.scheduleItemHydration(for: visibleReplies)
                }
            } catch {
                return
            }
        }
    }

    private func scheduleNoteActivityRefresh() {
        noteActivityRefreshTask?.cancel()

        let relayTargets = readRelayURLs
        let rootEventID = rootItem.displayEventID

        noteActivityRefreshTask = Task { [weak self] in
            guard let self else { return }

            do {
                let refreshedRows = try await self.service.fetchThreadNoteActivityRows(
                    relayURLs: relayTargets,
                    rootEventID: rootEventID,
                    rootAuthorPubkey: self.rootItem.displayAuthorPubkey,
                    fetchTimeout: Self.fullNoteActivityFetchTimeout,
                    relayFetchMode: Self.fullNoteActivityRelayFetchMode,
                    profileFetchTimeout: Self.fullNoteActivityFetchTimeout,
                    profileRelayFetchMode: Self.fullNoteActivityRelayFetchMode
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.rootItem.displayEventID.lowercased() == rootEventID.lowercased() else { return }
                    guard !refreshedRows.isEmpty || self.noteActivityRows.isEmpty else { return }
                    self.noteActivityRows = refreshedRows
                    self.noteActivityErrorMessage = nil
                }
            } catch {
                return
            }
        }
    }

    private func hydrateRootItem(
        sourceEvent: NostrEvent,
        relayURLs: [URL],
        hydrationMode: FeedItemHydrationMode
    ) async {
        let hydrated = await service.buildFeedItems(
            relayURLs: relayURLs,
            events: [sourceEvent],
            hydrationMode: hydrationMode
        )
        guard !Task.isCancelled, let hydratedRootItem = hydrated.first else { return }

        await MainActor.run {
            guard self.rootItem.event.id.lowercased() == sourceEvent.id.lowercased() else { return }
            self.rootItem = Self.mergedRootItem(current: self.rootItem, hydrated: hydratedRootItem)
        }
    }

    private func mergeKeepingThreadOrder(itemsToMerge: [FeedItem]) {
        LocalPublicationStore.shared.mergeFetchedItems(itemsToMerge)
        var byID = Dictionary(uniqueKeysWithValues: rawReplies.map { ($0.id.lowercased(), $0) })
        for item in itemsToMerge {
            byID[item.id.lowercased()] = item
        }
        rawReplies = pruneMutedItems(Self.sortedReplies(Array(byID.values)))
        Task { [weak self] in
            await self?.rebuildReplyBuckets()
        }
    }

    private func mergeWithLocalPublicationReplies(
        _ fetchedReplies: [FeedItem],
        rootEventID: String? = nil,
        snapshot: MuteFilterSnapshot? = nil
    ) -> [FeedItem] {
        LocalPublicationStore.shared.mergeFetchedItems(fetchedReplies)
        return pruneMutedItems(
            HomeFeedPageFetcher.mergeItemArrays(
                primary: fetchedReplies,
                secondary: localPublicationReplies(rootEventID: rootEventID)
            ),
            snapshot: snapshot
        )
    }

    private func localPublicationReplies(rootEventID: String? = nil) -> [FeedItem] {
        let normalizedRootEventID = (rootEventID ?? rootItem.displayEventID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedRootEventID.isEmpty else { return [] }

        return LocalPublicationStore.shared.records(matching: { item in
            item.id.lowercased() != normalizedRootEventID &&
            item.displayEvent.referencesConversation(id: normalizedRootEventID)
        })
        .map(\.item)
    }

    private func rebuildReplyBuckets() async {
        let allReplies = Self.sortedReplies(rawReplies)
        guard !allReplies.isEmpty else {
            replies = []
            spamReplies = []
            return
        }

        let settings = AppSettingsStore.shared
        let markedSpamPubkeys = settings.spamFilterMarkedPubkeys
        let notSpamPubkeys = settings.spamReplyFilterSafelistedPubkeys

        if !markedSpamPubkeys.isEmpty {
            var visibleReplies: [FeedItem] = []
            var hiddenReplies: [FeedItem] = []
            for item in allReplies {
                let pubkey = normalizedPubkey(item.displayAuthorPubkey)
                if pubkey != spamFilterCurrentUserPubkey, settings.shouldHideSpamMarkedPubkey(pubkey) {
                    hiddenReplies.append(item)
                } else {
                    visibleReplies.append(item)
                }
            }

            if !settings.spamReplyFilterEnabled {
                replies = visibleReplies
                spamReplies = hiddenReplies
                return
            }
        } else if !settings.spamReplyFilterEnabled {
            replies = allReplies
            spamReplies = []
            return
        }

        guard settings.spamReplyFilterEnabled else {
            replies = allReplies
            spamReplies = []
            return
        }

        var visibleReplies: [FeedItem] = []
        var hiddenReplies: [FeedItem] = []
        var pubkeysToScore = Set<String>()

        for item in allReplies {
            let pubkey = normalizedPubkey(item.displayAuthorPubkey)
            if pubkey != spamFilterCurrentUserPubkey, settings.shouldHideSpamMarkedPubkey(pubkey) {
                hiddenReplies.append(item)
                continue
            }
            guard shouldEvaluateForSpam(pubkey: pubkey) else {
                visibleReplies.append(item)
                continue
            }

            if let score = await NSpamAuthorScorer.shared.cachedScore(
                for: pubkey,
                markedSpamPubkeys: markedSpamPubkeys,
                notSpamPubkeys: notSpamPubkeys
            ) {
                if score >= Self.spamThreshold {
                    hiddenReplies.append(item)
                } else {
                    visibleReplies.append(item)
                }
            } else {
                visibleReplies.append(item)
                if spamScoreTasks[pubkey] == nil, !spamScoreAttemptedPubkeys.contains(pubkey) {
                    pubkeysToScore.insert(pubkey)
                }
            }
        }

        replies = visibleReplies
        spamReplies = hiddenReplies

        if hiddenReplies.isEmpty, isSpamRepliesExpanded {
            isSpamRepliesExpanded = false
        }

        scheduleSpamScoring(for: pubkeysToScore)
    }

    private func shouldEvaluateForSpam(pubkey: String) -> Bool {
        guard !pubkey.isEmpty else { return false }
        if pubkey == spamFilterCurrentUserPubkey {
            return false
        }
        if AppSettingsStore.shared.shouldHideSpamMarkedPubkey(pubkey) {
            return false
        }
        if spamFilterFollowedPubkeys.contains(pubkey) {
            return false
        }
        if AppSettingsStore.shared.isSpamReplySafelisted(pubkey) {
            return false
        }
        return true
    }

    private func scheduleSpamScoring(for pubkeys: Set<String>) {
        let settings = AppSettingsStore.shared
        let markedSpamPubkeys = settings.spamFilterMarkedPubkeys
        let notSpamPubkeys = settings.spamReplyFilterSafelistedPubkeys
        for pubkey in pubkeys where !pubkey.isEmpty {
            guard spamScoreTasks[pubkey] == nil else { continue }
            spamScoreAttemptedPubkeys.insert(pubkey)
            let task = Task { [weak self] in
                _ = await NSpamAuthorScorer.shared.scoreAuthor(
                    pubkey: pubkey,
                    markedSpamPubkeys: markedSpamPubkeys,
                    notSpamPubkeys: notSpamPubkeys
                )
                await MainActor.run {
                    guard let self else { return }
                    self.spamScoreTasks[pubkey] = nil
                    Task { [weak self] in
                        await self?.rebuildReplyBuckets()
                    }
                }
            }
            spamScoreTasks[pubkey] = task
        }
    }

    private func pruneMutedItems(
        _ sourceItems: [FeedItem],
        snapshot: MuteFilterSnapshot? = nil
    ) -> [FeedItem] {
        let snapshot = snapshot ?? muteFilterSnapshot
        guard snapshot.hasAnyRules else { return sourceItems }

        return sourceItems.filter { item in
            !snapshot.shouldHideAny(in: item.moderationEvents)
        }
    }

    private func normalizedPubkey(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static let spamThreshold: Float = 0.5

    private static func sortedReplies(_ items: [FeedItem]) -> [FeedItem] {
        items.sorted { lhs, rhs in
            if lhs.event.createdAt == rhs.event.createdAt {
                return lhs.id.lowercased() < rhs.id.lowercased()
            }
            return lhs.event.createdAt < rhs.event.createdAt
        }
    }

    private static func mergedRootItem(current: FeedItem, hydrated: FeedItem) -> FeedItem {
        FeedItem(
            event: hydrated.event,
            profile: hydrated.profile ?? current.profile,
            displayEventOverride: hydrated.displayEventOverride ?? current.displayEventOverride,
            displayProfileOverride: hydrated.displayProfileOverride ?? current.displayProfileOverride,
            replyTargetEvent: hydrated.replyTargetEvent ?? current.replyTargetEvent,
            replyTargetProfile: hydrated.replyTargetProfile ?? current.replyTargetProfile
        )
    }

    private static func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
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
