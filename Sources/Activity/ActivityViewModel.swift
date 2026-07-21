import Foundation
import OSLog

protocol ActivityLiveEventSubscribing: Sendable {
    func run(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async
}

extension NostrLiveFeedSubscriber: ActivityLiveEventSubscribing {}

@MainActor
final class ActivityViewModel: ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: "com.karnagebitcoin.Flow",
        category: "PulseLoading"
    )

    @Published private(set) var items: [ActivityRow] = []
    @Published var selectedFilter: ActivityFilter = .all
    @Published private(set) var unreadCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let service: NostrFeedService
    private let liveSubscriber: any ActivityLiveEventSubscribing
    private let defaults: UserDefaults
    private let mutedThreadStore: MutedThreadStore
    private let activityEventCache: any ActivityEventCaching
    private let notificationCenter: NotificationCenter

    private var hasLoadedInitialState = false
    private var configurationGeneration = 0
    private var currentUserPubkey: String?
    private var readRelayURLs: [URL]
    private var requestCounter = 0
    private var liveUpdatesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var liveSubscriptionSignature: String?
    private var activeLoadingRequestIDs = Set<Int>()
    private var activeRefreshingRequestIDs = Set<Int>()
    private var knownEventIDs = Set<String>()
    private var pendingLiveEventIDs = Set<String>()
    private var isActivityTabActive = false
    private var isSceneActive = false
    private var lastReadCreatedAt = 0
    private var onLiveReactionDetected: ((ActivityReaction) -> Void)?
    private var spamAuthorScores: [String: Float] = [:]
    private var spamScoreTasks: [String: Task<Void, Never>] = [:]
    private var spamScoreAttemptedPubkeys = Set<String>()

    private static let fastActivityFetchTimeout: TimeInterval = 3
    private static let activityRelayFetchMode: RelayFetchMode = .allRelays
    private static let fastProfileRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let activityKinds = [1, 6, 7, 16, 1111, 1244]
    private static let lastReadStoragePrefix = "flow.activity.lastRead"
    private static let spamThreshold: Float = 0.5

    init(
        service: NostrFeedService = NostrFeedService(),
        liveSubscriber: any ActivityLiveEventSubscribing = NostrLiveFeedSubscriber(),
        defaults: UserDefaults = .standard,
        mutedThreadStore: MutedThreadStore? = nil,
        activityEventCache: any ActivityEventCaching = ActivityEventCache.shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.service = service
        self.liveSubscriber = liveSubscriber
        self.defaults = defaults
        self.mutedThreadStore = mutedThreadStore ?? MutedThreadStore.shared
        self.activityEventCache = activityEventCache
        self.notificationCenter = notificationCenter
        self.readRelayURLs = RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
        startObservingConnectionRecovery()
    }

    deinit {
        liveUpdatesTask?.cancel()
        refreshTask?.cancel()
        connectionRecoveryTask?.cancel()
        spamScoreTasks.values.forEach { $0.cancel() }
    }

    var visibleItems: [ActivityRow] {
        itemsMatchingSelectedFilter.filter { item in
            AppSettingsStore.shared.isActivityNotificationEnabled(for: item.action.notificationPreference)
                && !isHiddenByManualSpam(item)
                && !isHiddenSpamReply(item)
                && !mutedThreadStore.isMuted(item.threadMuteIdentifier)
        }
    }

    var hasItemsHiddenByNotificationPreferences: Bool {
        !itemsMatchingSelectedFilter.isEmpty && visibleItems.isEmpty
    }

    var hasUnread: Bool {
        unreadCount > 0
    }

    var primaryRelayURL: URL {
        readRelayURLs.first
            ?? URL(string: RelaySettingsStore.defaultReadRelayURLs.first ?? "wss://relay.damus.io/")!
    }

    func configure(
        currentUserPubkey: String?,
        readRelayURLs: [URL],
        onLiveReactionDetected: ((ActivityReaction) -> Void)? = nil
    ) {
        let normalizedUser = normalizePubkey(currentUserPubkey)
        let normalizedRelays = normalizedRelayURLs(readRelayURLs)
        if let onLiveReactionDetected {
            self.onLiveReactionDetected = onLiveReactionDetected
        }

        let relaysChanged = normalizedRelays.map { $0.absoluteString.lowercased() } != self.readRelayURLs.map { $0.absoluteString.lowercased() }
        let userChanged = normalizedUser != self.currentUserPubkey
        let configurationChanged = relaysChanged || userChanged
        let hadLoadedInitialState = hasLoadedInitialState

        if configurationChanged {
            configurationGeneration += 1
            requestCounter += 1
            hasLoadedInitialState = false
            refreshTask?.cancel()
            refreshTask = nil
            stopLiveUpdates()
        }

        if userChanged {
            clearActivityContent()
            self.currentUserPubkey = normalizedUser
            lastReadCreatedAt = normalizedUser.map(loadLastReadCreatedAt(for:)) ?? 0
            resetSpamScores()
        }

        if !normalizedRelays.isEmpty {
            self.readRelayURLs = normalizedRelays
        }

        guard let normalizedUser, !normalizedUser.isEmpty else {
            resetStateForSignedOutUser()
            return
        }

        recomputeUnreadCount()

        guard configurationChanged else { return }
        guard hadLoadedInitialState || isSceneActive else { return }

        let generation = configurationGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let loadedCachedRows = await self.loadCachedActivityRowsIfAvailable(
                expectedGeneration: generation
            )
            guard generation == self.configurationGeneration, !Task.isCancelled else { return }
            if loadedCachedRows {
                self.hasLoadedInitialState = true
                self.startLiveUpdatesIfNeeded()
            }
            await self.refreshForCurrentConfiguration(
                showFullScreenLoading: !loadedCachedRows && self.items.isEmpty
            )
        }
    }

    func loadIfNeeded() async {
        guard !hasLoadedInitialState else {
            startLiveUpdatesIfNeeded()
            return
        }
        let generation = configurationGeneration
        let loadedCachedRows = await loadCachedActivityRowsIfAvailable(
            expectedGeneration: generation
        )
        guard !Task.isCancelled else {
            Self.logger.debug("Initial Pulse load cancelled during cache hydration")
            return
        }
        if loadedCachedRows {
            hasLoadedInitialState = true
            Self.logger.debug("Pulse cache hydrated rows=\(self.items.count, privacy: .public)")
            startLiveUpdatesIfNeeded()
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                await self?.refreshForCurrentConfiguration(showFullScreenLoading: false)
            }
        } else {
            await refreshForCurrentConfiguration(showFullScreenLoading: true)
        }
    }

    func sceneDidChange(isActive: Bool) async {
        let wasSceneActive = isSceneActive
        isSceneActive = isActive

        guard isActive else {
            stopLiveUpdates()
            return
        }

        guard !wasSceneActive else {
            if !hasLoadedInitialState {
                await loadIfNeeded()
            }
            return
        }

        if !hasLoadedInitialState {
            await loadIfNeeded()
            return
        }

        await refreshForCurrentConfiguration(showFullScreenLoading: items.isEmpty)
    }

    func refresh() async {
        await refreshForCurrentConfiguration(showFullScreenLoading: items.isEmpty)
    }

    func selectedFilterChanged() async {
        // Filtering is local now so the segmented control responds instantly.
    }

    func setActivityTabActive(_ isActive: Bool) {
        isActivityTabActive = isActive
        Self.logger.debug(
            "Pulse tab active=\(isActive, privacy: .public) loaded=\(self.hasLoadedInitialState, privacy: .public) rows=\(self.items.count, privacy: .public)"
        )
        if isActive {
            markAllAsRead()
        }
    }

    func notificationPreferencesChanged() {
        resetSpamScores()
        scheduleSpamScoring(for: items)
        recomputeUnreadCount()
    }

    private func refreshForCurrentConfiguration(showFullScreenLoading: Bool) async {
        requestCounter += 1
        let requestID = requestCounter

        if showFullScreenLoading {
            activeLoadingRequestIDs.insert(requestID)
            isLoading = true
        } else {
            activeRefreshingRequestIDs.insert(requestID)
            isRefreshing = true
        }

        errorMessage = nil
        let relays = readRelayURLs
        let user = currentUserPubkey
        let startedAt = Date()

        Self.logger.debug(
            "Pulse history request start id=\(requestID, privacy: .public) relays=\(relays.count, privacy: .public) fullScreen=\(showFullScreenLoading, privacy: .public)"
        )

        defer {
            activeLoadingRequestIDs.remove(requestID)
            activeRefreshingRequestIDs.remove(requestID)
            isLoading = !activeLoadingRequestIDs.isEmpty
            isRefreshing = !activeRefreshingRequestIDs.isEmpty
        }

        guard let user, !user.isEmpty else {
            resetStateForSignedOutUser()
            errorMessage = "Sign in to view activity."
            return
        }

        do {
            let fetched = try await service.fetchActivityRows(
                relayURLs: relays,
                currentUserPubkey: user,
                filter: .all,
                limit: 120,
                fetchTimeout: Self.fastActivityFetchTimeout,
                relayFetchMode: Self.activityRelayFetchMode,
                profileFetchTimeout: Self.fastActivityFetchTimeout,
                profileRelayFetchMode: Self.fastProfileRelayFetchMode
            )
            guard requestID == requestCounter else {
                Self.logger.debug("Pulse history request ignored as stale id=\(requestID, privacy: .public)")
                return
            }

            hasLoadedInitialState = true
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Self.logger.debug(
                "Pulse history request succeeded id=\(requestID, privacy: .public) rows=\(fetched.count, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public)"
            )

            guard !fetched.isEmpty || items.isEmpty else {
                startLiveUpdatesIfNeeded()
                return
            }

            items = sortAndDeduplicate(items: fetched)
            knownEventIDs = Set(items.map { $0.id.lowercased() })
            pendingLiveEventIDs = []
            scheduleSpamScoring(for: items)
            await persistCachedActivityEvents(items.map(\.event), user: user, relays: relays)
            if isActivityTabActive {
                markAllAsRead()
            } else {
                recomputeUnreadCount()
            }
            startLiveUpdatesIfNeeded()
        } catch {
            guard requestID == requestCounter else {
                Self.logger.debug("Pulse history failure ignored as stale id=\(requestID, privacy: .public)")
                return
            }
            let wasCancelled = Task.isCancelled
                || error is CancellationError
                || (error as? URLError)?.code == .cancelled
            if wasCancelled {
                Self.logger.debug("Pulse history request cancelled id=\(requestID, privacy: .public)")
                return
            }
            if items.isEmpty {
                hasLoadedInitialState = false
            }
            if items.isEmpty {
                errorMessage = "Couldn't load activity right now."
            } else {
                errorMessage = "Couldn't refresh activity."
            }
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Self.logger.error(
                "Pulse history request failed id=\(requestID, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            startLiveUpdatesIfNeeded()
        }
    }

    private func startLiveUpdatesIfNeeded(forceRestart: Bool = false) {
        guard hasLoadedInitialState else { return }
        guard isSceneActive else {
            stopLiveUpdates()
            return
        }
        guard let user = currentUserPubkey, !user.isEmpty else {
            stopLiveUpdates()
            return
        }

        let relays = normalizedRelayURLs(readRelayURLs)
        guard !relays.isEmpty else {
            stopLiveUpdates()
            return
        }

        let filter = NostrFilter(
            kinds: Self.activityKinds,
            limit: 100,
            since: currentLiveSubscriptionSince(),
            tagFilters: ["p": [user]]
        )
        let signature = relays
            .map { $0.absoluteString.lowercased() }
            .sorted()
            .joined(separator: "|") + "|\(user)"

        if !forceRestart,
           liveUpdatesTask != nil,
           liveSubscriptionSignature == signature {
            return
        }

        stopLiveUpdates()
        liveSubscriptionSignature = signature

        liveUpdatesTask = Task { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                for relayURL in relays {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.liveSubscriber.run(
                            relayURL: relayURL,
                            filter: filter,
                            onNewEvent: { [weak self] event in
                                guard let self else { return }
                                await self.handleLiveEvent(event)
                            },
                            onStatus: { status in
                                Self.logger.debug(
                                    "Pulse live status relay=\(relayURL.host ?? "unknown", privacy: .public) status=\(status, privacy: .private)"
                                )
                            }
                        )
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func stopLiveUpdates() {
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        liveSubscriptionSignature = nil
    }

    private func handleLiveEvent(_ event: NostrEvent) async {
        guard let user = currentUserPubkey, !user.isEmpty else { return }
        guard event.activityAction != nil else { return }
        guard event.mentionedPubkeys.contains(where: { $0.lowercased() == user }) else { return }
        guard normalizePubkey(event.pubkey) != user else { return }
        let isMutedActor = MuteStore.shared.isMuted(event.pubkey)

        let normalizedEventID = event.id.lowercased()
        guard !knownEventIDs.contains(normalizedEventID) else { return }
        guard !pendingLiveEventIDs.contains(normalizedEventID) else { return }
        pendingLiveEventIDs.insert(normalizedEventID)

        await service.ingestLiveEvents([event])

        if !isMutedActor, let reaction = event.activityAction?.reaction {
            onLiveReactionDetected?(reaction)
        }

        let newRows = await service.buildActivityRows(
            relayURLs: readRelayURLs,
            currentUserPubkey: user,
            events: [event],
            fetchTimeout: Self.fastActivityFetchTimeout,
            relayFetchMode: Self.fastProfileRelayFetchMode,
            profileFetchTimeout: Self.fastActivityFetchTimeout,
            profileRelayFetchMode: Self.fastProfileRelayFetchMode
        )
        pendingLiveEventIDs.remove(normalizedEventID)
        guard !newRows.isEmpty else { return }

        items = sortAndDeduplicate(items: newRows + items)
        knownEventIDs = Set(items.map { $0.id.lowercased() })
        scheduleSpamScoring(for: newRows)
        await persistCachedActivityEvents(items.map(\.event), user: user, relays: readRelayURLs)

        if isActivityTabActive {
            markAllAsRead()
        } else {
            recomputeUnreadCount()
        }
    }

    private func markAllAsRead() {
        guard let user = currentUserPubkey, !user.isEmpty else {
            unreadCount = 0
            return
        }

        lastReadCreatedAt = max(
            Int(Date().timeIntervalSince1970),
            items.first?.createdAt ?? 0
        )
        persistLastReadCreatedAt(lastReadCreatedAt, for: user)
        unreadCount = 0
    }

    private func recomputeUnreadCount() {
        guard !isActivityTabActive else {
            unreadCount = 0
            return
        }

        unreadCount = items.reduce(into: 0) { count, item in
            guard item.createdAt > lastReadCreatedAt else { return }
            guard shouldCountAsUnreadNotification(item) else { return }
            count += 1
        }
    }

    private func shouldCountAsUnreadNotification(_ item: ActivityRow) -> Bool {
        guard AppSettingsStore.shared.isActivityNotificationEnabled(for: item.action.notificationPreference) else {
            return false
        }
        guard !isHiddenSpamReply(item) else {
            return false
        }
        guard !mutedThreadStore.isMuted(item.threadMuteIdentifier) else {
            return false
        }
        return !MuteStore.shared.isMuted(item.actorPubkey)
    }

    private func resetStateForSignedOutUser() {
        hasLoadedInitialState = false
        stopLiveUpdates()
        clearActivityContent()
    }

    private func clearActivityContent() {
        items = []
        knownEventIDs = []
        pendingLiveEventIDs = []
        unreadCount = 0
        errorMessage = nil
        resetSpamScores()
    }

    private func startObservingConnectionRecovery() {
        connectionRecoveryTask = Task { [weak self, notificationCenter = notificationCenter] in
            let notifications = notificationCenter.notifications(named: .relayConnectionsDidReset)
            for await _ in notifications {
                guard let self else { return }
                await self.recoverAfterRelayConnectionReset()
            }
        }
    }

    private func recoverAfterRelayConnectionReset() async {
        Self.logger.notice(
            "Pulse observed relay reset sceneActive=\(self.isSceneActive, privacy: .public) rows=\(self.items.count, privacy: .public)"
        )
        requestCounter += 1
        refreshTask?.cancel()
        refreshTask = nil
        stopLiveUpdates()
        if items.isEmpty {
            hasLoadedInitialState = false
        }
        guard isSceneActive else { return }
        await refreshForCurrentConfiguration(showFullScreenLoading: items.isEmpty)
    }

    private func sortAndDeduplicate(items: [ActivityRow]) -> [ActivityRow] {
        var dedupedByID: [String: ActivityRow] = [:]
        for item in items {
            dedupedByID[item.id.lowercased()] = item
        }

        return dedupedByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func loadLastReadCreatedAt(for user: String) -> Int {
        defaults.integer(forKey: lastReadStorageKey(for: user))
    }

    private func persistLastReadCreatedAt(_ value: Int, for user: String) {
        defaults.set(value, forKey: lastReadStorageKey(for: user))
    }

    private func lastReadStorageKey(for user: String) -> String {
        "\(Self.lastReadStoragePrefix).\(user)"
    }

    private func loadCachedActivityRowsIfAvailable(expectedGeneration: Int) async -> Bool {
        guard let user = currentUserPubkey, !user.isEmpty else { return false }
        let relays = readRelayURLs
        let cacheKey = Self.activityCacheKey(currentUserPubkey: user, readRelayURLs: relays)
        guard let cachedEvents = await activityEventCache.events(for: cacheKey),
              !cachedEvents.isEmpty else {
            return false
        }
        guard expectedGeneration == configurationGeneration else {
            Self.logger.debug("Pulse cache ignored after configuration changed")
            return false
        }

        let cachedRows = await service.buildActivityRows(
            relayURLs: relays,
            currentUserPubkey: user,
            events: cachedEvents,
            fetchTimeout: Self.fastActivityFetchTimeout,
            relayFetchMode: Self.fastProfileRelayFetchMode,
            profileFetchTimeout: Self.fastActivityFetchTimeout,
            profileRelayFetchMode: Self.fastProfileRelayFetchMode,
            resolveRemoteReferences: false
        )
        guard expectedGeneration == configurationGeneration,
              user == currentUserPubkey,
              relays.map(\.absoluteString) == readRelayURLs.map(\.absoluteString) else {
            Self.logger.debug("Pulse cache rows ignored after configuration changed")
            return false
        }
        guard !cachedRows.isEmpty else { return false }

        items = sortAndDeduplicate(items: cachedRows)
        knownEventIDs = Set(items.map { $0.id.lowercased() })
        pendingLiveEventIDs = []
        scheduleSpamScoring(for: items)
        if isActivityTabActive {
            markAllAsRead()
        } else {
            recomputeUnreadCount()
        }
        return true
    }

    private func persistCachedActivityEvents(
        _ events: [NostrEvent],
        user: String,
        relays: [URL]
    ) async {
        let limitedEvents = Array(events.prefix(120))
        let cacheKey = Self.activityCacheKey(currentUserPubkey: user, readRelayURLs: relays)
        await activityEventCache.store(events: limitedEvents, for: cacheKey)
    }

    static func activityCacheKey(
        currentUserPubkey: String,
        readRelayURLs: [URL]
    ) -> String {
        let normalizedUser = currentUserPubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let relaySignature = normalizedRelaySignature(readRelayURLs)
        return "activity-v1|\(normalizedUser)|\(relaySignature)"
    }

    private static func normalizedRelaySignature(_ relayURLs: [URL]) -> String {
        var seen = Set<String>()
        var normalized: [String] = []
        for relayURL in relayURLs {
            let value = relayURL.absoluteString
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            normalized.append(value)
        }
        return normalized.sorted().joined(separator: "|")
    }

    private func normalizePubkey(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func isHiddenSpamReply(_ item: ActivityRow) -> Bool {
        guard case .reply = item.action else { return false }
        guard AppSettingsStore.shared.spamReplyFilterEnabled else { return false }
        guard let pubkey = normalizePubkey(item.actorPubkey) else { return false }
        if pubkey == currentUserPubkey {
            return false
        }
        if FollowStore.shared.isFollowing(pubkey) {
            return false
        }
        if AppSettingsStore.shared.isSpamReplySafelisted(pubkey) {
            return false
        }
        if spamScoreTasks[pubkey] != nil {
            return true
        }
        return (spamAuthorScores[pubkey] ?? 0) >= Self.spamThreshold
    }

    private func isHiddenByManualSpam(_ item: ActivityRow) -> Bool {
        guard let pubkey = normalizePubkey(item.actorPubkey) else { return false }
        guard pubkey != currentUserPubkey else { return false }
        return AppSettingsStore.shared.shouldHideSpamMarkedPubkey(pubkey)
    }

    private func scheduleSpamScoring(for sourceItems: [ActivityRow]) {
        guard AppSettingsStore.shared.spamReplyFilterEnabled else { return }
        let settings = AppSettingsStore.shared
        let markedSpamPubkeys = settings.spamFilterMarkedPubkeys
        let notSpamPubkeys = settings.spamReplyFilterSafelistedPubkeys
        var seedNotesByPubkey: [String: [NSpamNoteInput]] = [:]

        for item in sourceItems {
            guard case .reply = item.action else { continue }
            guard let pubkey = normalizePubkey(item.actorPubkey) else { continue }
            guard pubkey != currentUserPubkey else { continue }
            guard !settings.shouldHideSpamMarkedPubkey(pubkey) else { continue }
            guard !FollowStore.shared.isFollowing(pubkey) else { continue }
            guard !settings.isSpamReplySafelisted(pubkey) else { continue }
            guard spamAuthorScores[pubkey] == nil else { continue }
            guard spamScoreTasks[pubkey] == nil else { continue }
            guard !spamScoreAttemptedPubkeys.contains(pubkey) else { continue }
            seedNotesByPubkey[pubkey, default: []].append(NSpamNoteInput(event: item.event))
        }

        for (pubkey, seedNotes) in seedNotesByPubkey {
            spamScoreAttemptedPubkeys.insert(pubkey)
            let task = Task { [weak self] in
                let score = await NSpamAuthorScorer.shared.scoreAuthor(
                    pubkey: pubkey,
                    markedSpamPubkeys: markedSpamPubkeys,
                    notSpamPubkeys: notSpamPubkeys,
                    seedNotes: seedNotes
                )
                await MainActor.run {
                    guard let self else { return }
                    if let score {
                        self.spamAuthorScores[pubkey] = score
                    }
                    self.spamScoreTasks[pubkey] = nil
                    self.recomputeUnreadCount()
                }
            }
            spamScoreTasks[pubkey] = task
        }
    }

    private func resetSpamScores() {
        spamScoreTasks.values.forEach { $0.cancel() }
        spamScoreTasks = [:]
        spamAuthorScores = [:]
        spamScoreAttemptedPubkeys = []
    }

    private var itemsMatchingSelectedFilter: [ActivityRow] {
        items.filter { $0.action.matches(selectedFilter) }
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

    private func currentLiveSubscriptionSince() -> Int {
        let newestKnownCreatedAt = items.first?.createdAt ?? 0
        if newestKnownCreatedAt > 0 {
            return max(0, newestKnownCreatedAt - 1)
        }

        return max(0, Int(Date().timeIntervalSince1970) - 2)
    }
}
