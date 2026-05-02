import Foundation
import NostrSDK

struct ProfileKnownFollower: Identifiable, Hashable {
    let pubkey: String
    let profile: NostrProfile?

    var id: String { pubkey }

    var displayName: String {
        if let displayName = profile?.displayName?.trimmed, !displayName.isEmpty {
            return displayName
        }
        if let name = profile?.name?.trimmed, !name.isEmpty {
            return name
        }
        return shortNostrIdentifier(pubkey)
    }

    var avatarURL: URL? {
        profile?.resolvedAvatarURL
    }
}

@MainActor
final class ProfileViewModel: ObservableObject {
    private struct VisibleItemsCacheKey: Equatable {
        let itemsRevision: Int
        let mode: FeedMode
        let hideNSFW: Bool
        let filterRevision: Int
    }

    private struct KnownFollowersLookupKey: Equatable {
        let currentAccountPubkey: String
        let profilePubkey: String
        let candidatePubkeys: [String]
    }

    @Published private(set) var profile: NostrProfile?
    @Published private(set) var metadataSnapshot: ProfileMetadataSnapshot?
    @Published private(set) var followingCount: Int = 0
    @Published private(set) var hasResolvedFollowingCount = false
    @Published private(set) var followsCurrentUser = false
    @Published private(set) var knownFollowers: [ProfileKnownFollower] = []
    @Published private(set) var items: [FeedItem] = [] {
        didSet {
            itemsRevision &+= 1
            clearVisibleItemsCache()
        }
    }
    @Published var mode: FeedMode = .posts {
        didSet { clearVisibleItemsCache() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var hasCompletedInitialLoad = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isSavingProfile = false
    @Published var errorMessage: String?
    @Published var profileSaveError: String?

    let relayURL: URL
    let readRelayURLs: [URL]
    let writeRelayURLs: [URL]
    let pubkey: String

    private let pageSize: Int
    private let service: NostrFeedService
    private let profileEventService: ProfileEventService
    private let relayClient: any NostrRelayEventPublishing
    private let eventRepository: any EventRepositoryStoring
    private let mediaUploadService: ProfileMediaUploadService
    static let requestedFeedKinds = [
        FeedKindFilters.shortTextNote,
        FeedKindFilters.repost,
        16,
        FeedKindFilters.poll,
        FeedKindFilters.comment,
        FeedKindFilters.voiceComment,
        FeedKindFilters.longFormArticle
    ]

    private static let fastProfileFetchTimeout: TimeInterval = 8
    private static let fastProfileRelayFetchMode: RelayFetchMode = .firstNonEmptyRelay
    private static let knownFollowersFetchTimeout: TimeInterval = 4
    private static let knownFollowersDisplayLimit = 5
    private static let knownFollowersCandidateLimit = 240
    private var oldestCreatedAt: Int?
    private var hasReachedEnd = false
    private var loadedModeForCurrentItems: FeedMode?
    private var hasLoadedInitialState = false
    private var itemsRevision = 0
    private var visibleItemsCacheKey: VisibleItemsCacheKey?
    private var visibleItemsCache: [FeedItem] = []
    private var knownFollowersLookupKey: KnownFollowersLookupKey?

    init(
        pubkey: String,
        relayURL: URL,
        readRelayURLs: [URL]? = nil,
        writeRelayURLs: [URL]? = nil,
        pageSize: Int = 70,
        service: NostrFeedService = NostrFeedService(),
        profileEventService: ProfileEventService = ProfileEventService(),
        relayClient: any NostrRelayEventPublishing = NostrRelayClient(),
        eventRepository: any EventRepositoryStoring = EventRepository.shared,
        mediaUploadService: ProfileMediaUploadService = .shared
    ) {
        self.pubkey = pubkey
        let sharedReadRelays = RelaySettingsStore.shared.readRelayURLs
        let sharedWriteRelays = RelaySettingsStore.shared.writeRelayURLs

        let normalizedReadRelays = Self.normalizedRelayURLs(
            readRelayURLs ?? (sharedReadRelays.isEmpty ? [relayURL] : sharedReadRelays)
        )
        let normalizedWriteRelays = Self.normalizedRelayURLs(
            writeRelayURLs ?? (sharedWriteRelays.isEmpty ? [relayURL] : sharedWriteRelays)
        )

        self.readRelayURLs = normalizedReadRelays.isEmpty ? [relayURL] : normalizedReadRelays
        self.writeRelayURLs = normalizedWriteRelays.isEmpty ? self.readRelayURLs : normalizedWriteRelays
        self.relayURL = self.readRelayURLs.first ?? relayURL
        self.pageSize = pageSize
        self.service = service
        self.profileEventService = profileEventService
        self.relayClient = relayClient
        self.eventRepository = eventRepository
        self.mediaUploadService = mediaUploadService
    }

    var relayLabel: String {
        if readRelayURLs.count > 1 {
            return "\(readRelayURLs.count) relays"
        }
        return relayURL.host() ?? relayURL.absoluteString
    }

    var visibleItems: [FeedItem] {
        let key = VisibleItemsCacheKey(
            itemsRevision: itemsRevision,
            mode: mode,
            hideNSFW: AppSettingsStore.shared.hideNSFWContent,
            filterRevision: MuteStore.shared.filterRevision
        )

        if visibleItemsCacheKey == key {
            return visibleItemsCache
        }

        let filtered = filteredItems(items, for: mode)
        visibleItemsCacheKey = key
        visibleItemsCache = filtered
        return filtered
    }

    private var muteFilterSnapshot: MuteFilterSnapshot {
        MuteStore.shared.filterSnapshot
    }

    var displayName: String {
        if let displayName = profile?.displayName?.trimmed, !displayName.isEmpty {
            return displayName
        }
        if let name = profile?.name?.trimmed, !name.isEmpty {
            return name
        }
        return shortNostrIdentifier(pubkey)
    }

    var handle: String {
        if let name = profile?.name?.trimmed, !name.isEmpty {
            return "@\(name.replacingOccurrences(of: " ", with: "").lowercased())"
        }
        if let displayName = profile?.displayName?.trimmed, !displayName.isEmpty {
            return "@\(displayName.replacingOccurrences(of: " ", with: "").lowercased())"
        }
        return "@\(shortNostrIdentifier(pubkey).lowercased())"
    }

    var npub: String {
        if let publicKey = PublicKey(hex: pubkey) {
            return publicKey.npub
        }
        return pubkey
    }

    var avatarURL: URL? {
        profile?.resolvedAvatarURL
    }

    var bannerURL: URL? {
        guard let banner = profile?.banner?.trimmed, let url = URL(string: banner) else { return nil }
        return url
    }

    var about: String? {
        profile?.about?.trimmed
    }

    var nip05: String? {
        profile?.nip05?.trimmed
    }

    var websiteValue: String? {
        guard let website = profile?.website?.trimmed, !website.isEmpty else { return nil }
        return website
    }

    var websiteURL: URL? {
        ProfileMetadataEditing.normalizedWebsiteURL(from: websiteValue)
    }

    var lightningAddress: String? {
        profile?.lightningAddress?.trimmed
    }

    var editableFields: EditableProfileFields {
        EditableProfileFields(profile: profile)
    }

    func loadIfNeeded() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        hasReachedEnd = false
        oldestCreatedAt = nil

        if let cachedProfile = await service.cachedProfile(pubkey: pubkey) {
            profile = cachedProfile
        }
        if let cachedFollowingCount = await service.cachedFollowingCount(pubkey: pubkey) {
            followingCount = cachedFollowingCount
            hasResolvedFollowingCount = true
        }

        let requestHydrationMode: FeedItemHydrationMode = .full
        let fastHydrationMode: FeedItemHydrationMode = .cachedProfilesOnly
        let requestFetchTimeout = Self.fastProfileFetchTimeout
        let requestRelayFetchMode = Self.fastProfileRelayFetchMode

        defer {
            isLoading = false
            hasCompletedInitialLoad = true
        }

        async let fetchedProfile = service.fetchProfile(
            relayURLs: readRelayURLs,
            pubkey: pubkey,
            fetchTimeout: requestFetchTimeout,
            relayFetchMode: requestRelayFetchMode
        )
        async let fetchedFollowListSnapshot: FollowListSnapshot? = {
            try? await service.fetchFollowListSnapshot(
                relayURLs: readRelayURLs,
                pubkey: pubkey,
                fetchTimeout: requestFetchTimeout,
                relayFetchMode: requestRelayFetchMode
            )
        }()
        async let fetchedMetadataResult: Result<ProfileMetadataSnapshot?, Error> = {
            do {
                return .success(try await fetchProfileMetadataSnapshot(relayURLs: readRelayURLs, pubkey: pubkey))
            } catch {
                return .failure(error)
            }
        }()

        var fetchedItems: [FeedItem] = []
        var feedError: Error?
        do {
            let feedWindow = try await fetchModeAwareAuthorEvents(
                until: nil,
                minimumVisibleCount: pageSize,
                fetchTimeout: requestFetchTimeout,
                relayFetchMode: requestRelayFetchMode,
                moderationSnapshot: muteFilterSnapshot
            )
            fetchedItems = await service.buildFeedItems(
                relayURLs: readRelayURLs,
                events: feedWindow.events,
                hydrationMode: fastHydrationMode,
                moderationSnapshot: muteFilterSnapshot
            )
            guard !Task.isCancelled else { return }

            items = mergeWithLocalPublicationItems(fetchedItems)
            oldestCreatedAt = feedWindow.oldestCreatedAt
            hasReachedEnd = feedWindow.hasReachedEnd
            loadedModeForCurrentItems = mode

            if requestHydrationMode != fastHydrationMode {
                fetchedItems = await service.buildFeedItems(
                    relayURLs: readRelayURLs,
                    events: feedWindow.events,
                    hydrationMode: requestHydrationMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                guard !Task.isCancelled else { return }

                items = mergeWithLocalPublicationItems(fetchedItems)
            }
        } catch {
            feedError = error
        }

        if let resolvedProfile = await fetchedProfile {
            profile = resolvedProfile
        }
        if let resolvedFollowListSnapshot = await fetchedFollowListSnapshot {
            followingCount = resolvedFollowListSnapshot.followedPubkeys.count
            hasResolvedFollowingCount = true
        }

        switch await fetchedMetadataResult {
        case .success(let snapshot):
            metadataSnapshot = snapshot
        case .failure:
            break
        }

        if let _ = feedError {
            if items.isEmpty {
                errorMessage = "Couldn't load this profile right now."
            } else {
                errorMessage = "Couldn't refresh this profile."
            }
            return
        }
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        guard !isLoading, !isLoadingMore, !hasReachedEnd else { return }
        guard let lastVisibleID = visibleItems.last?.id, lastVisibleID == currentItem.id else { return }

        let until = max((oldestCreatedAt ?? Int(Date().timeIntervalSince1970)) - 1, 0)
        guard until > 0 else { return }

        let requestHydrationMode: FeedItemHydrationMode = .full
        let fastHydrationMode: FeedItemHydrationMode = .cachedProfilesOnly
        let requestFetchTimeout = Self.fastProfileFetchTimeout
        let requestRelayFetchMode = Self.fastProfileRelayFetchMode

        isLoadingMore = true
        defer {
            isLoadingMore = false
        }

        do {
            let minimumVisibleCount = mode == .postsAndReplies
                ? min(max(pageSize / 2, 10), pageSize)
                : 1
            let feedWindow = try await fetchModeAwareAuthorEvents(
                until: until,
                minimumVisibleCount: minimumVisibleCount,
                fetchTimeout: requestFetchTimeout,
                relayFetchMode: requestRelayFetchMode,
                moderationSnapshot: muteFilterSnapshot
            )

            if feedWindow.events.isEmpty {
                hasReachedEnd = true
                return
            }

            oldestCreatedAt = feedWindow.oldestCreatedAt
            hasReachedEnd = feedWindow.hasReachedEnd
            let fastItems = await service.buildFeedItems(
                relayURLs: readRelayURLs,
                events: feedWindow.events,
                hydrationMode: fastHydrationMode,
                moderationSnapshot: muteFilterSnapshot
            )
            guard !Task.isCancelled else { return }

            mergeKeepingNewest(itemsToMerge: fastItems)

            if requestHydrationMode != fastHydrationMode {
                let upgradedItems = await service.buildFeedItems(
                    relayURLs: readRelayURLs,
                    events: feedWindow.events,
                    hydrationMode: requestHydrationMode,
                    moderationSnapshot: muteFilterSnapshot
                )
                guard !Task.isCancelled else { return }

                mergeKeepingNewest(itemsToMerge: upgradedItems)
            }
        } catch {
            errorMessage = loadMoreErrorMessage(for: mode)
        }
    }

    func insertOptimisticPublishedItem(_ item: FeedItem) {
        guard item.displayAuthorPubkey.lowercased() == pubkey.lowercased() else { return }
        mergeKeepingNewest(itemsToMerge: [item])
    }

    func prepareForSelectedModeIfNeeded() async {
        guard hasCompletedInitialLoad else { return }
        guard loadedModeForCurrentItems == mode else {
            await refresh()
            return
        }
        guard !hasReachedEnd else { return }

        let minimumVisibleItems = min(max(pageSize / 3, 8), pageSize)
        guard filteredItems(items, for: mode).count < minimumVisibleItems else { return }

        await refresh()
    }

    func refreshFollowRelationship(currentAccountPubkey: String?) async {
        let normalizedCurrentPubkey = normalizePubkey(currentAccountPubkey)
        let normalizedProfilePubkey = normalizePubkey(pubkey)

        guard !normalizedCurrentPubkey.isEmpty,
              normalizedCurrentPubkey != normalizedProfilePubkey else {
            followsCurrentUser = false
            return
        }

        var didResolveFromCache = false
        if let cachedSnapshot = await service.cachedFollowListSnapshot(pubkey: pubkey) {
            followsCurrentUser = cachedSnapshot.followedPubkeys.contains(normalizedCurrentPubkey)
            didResolveFromCache = true
        }

        guard let fetchedSnapshot = try? await service.fetchFollowListSnapshot(
            relayURLs: readRelayURLs,
            pubkey: pubkey,
            fetchTimeout: Self.fastProfileFetchTimeout,
            relayFetchMode: Self.fastProfileRelayFetchMode
        ) else {
            if !didResolveFromCache {
                followsCurrentUser = false
            }
            return
        }

        guard !Task.isCancelled else { return }
        followsCurrentUser = fetchedSnapshot.followedPubkeys.contains(normalizedCurrentPubkey)
    }

    func refreshKnownFollowers(
        currentAccountPubkey: String?,
        followedPubkeys: Set<String>
    ) async {
        let normalizedCurrentPubkey = normalizePubkey(currentAccountPubkey)
        let normalizedProfilePubkey = normalizePubkey(pubkey)

        guard !normalizedCurrentPubkey.isEmpty,
              normalizedCurrentPubkey != normalizedProfilePubkey else {
            knownFollowersLookupKey = nil
            knownFollowers = []
            return
        }

        let orderedCandidates = Array(
            normalizedPubkeys(Array(followedPubkeys))
                .filter { $0 != normalizedCurrentPubkey && $0 != normalizedProfilePubkey }
                .prefix(Self.knownFollowersCandidateLimit)
        )

        guard !orderedCandidates.isEmpty else {
            knownFollowersLookupKey = nil
            knownFollowers = []
            return
        }

        let lookupKey = KnownFollowersLookupKey(
            currentAccountPubkey: normalizedCurrentPubkey,
            profilePubkey: normalizedProfilePubkey,
            candidatePubkeys: orderedCandidates
        )
        knownFollowersLookupKey = lookupKey

        let cachedMutualPubkeys = await service.cachedKnownFollowers(
            profilePubkey: normalizedProfilePubkey,
            candidatePubkeys: orderedCandidates,
            limit: Self.knownFollowersDisplayLimit
        )
        guard !Task.isCancelled, knownFollowersLookupKey == lookupKey else { return }
        if !cachedMutualPubkeys.isEmpty {
            let cachedProfiles = await service.cachedProfiles(pubkeys: cachedMutualPubkeys)
            guard !Task.isCancelled, knownFollowersLookupKey == lookupKey else { return }
            knownFollowers = cachedMutualPubkeys.map { pubkey in
                ProfileKnownFollower(pubkey: pubkey, profile: cachedProfiles[pubkey])
            }
        }

        let mutualPubkeys = await service.fetchKnownFollowers(
            relayURLs: readRelayURLs,
            profilePubkey: normalizedProfilePubkey,
            candidatePubkeys: orderedCandidates,
            limit: Self.knownFollowersDisplayLimit,
            fetchTimeout: Self.knownFollowersFetchTimeout,
            relayFetchMode: Self.fastProfileRelayFetchMode
        )

        guard !Task.isCancelled, knownFollowersLookupKey == lookupKey else { return }
        guard !mutualPubkeys.isEmpty else {
            knownFollowers = []
            return
        }

        let cachedProfiles = await service.cachedProfiles(pubkeys: mutualPubkeys)
        guard !Task.isCancelled, knownFollowersLookupKey == lookupKey else { return }
        knownFollowers = mutualPubkeys.map { pubkey in
            ProfileKnownFollower(pubkey: pubkey, profile: cachedProfiles[pubkey])
        }

        let missingProfilePubkeys = mutualPubkeys.filter { cachedProfiles[$0] == nil }
        guard !missingProfilePubkeys.isEmpty else { return }

        let profiles = await service.fetchProfiles(
            relayURLs: readRelayURLs,
            pubkeys: missingProfilePubkeys,
            fetchTimeout: Self.knownFollowersFetchTimeout,
            relayFetchMode: Self.fastProfileRelayFetchMode
        )

        guard !Task.isCancelled, knownFollowersLookupKey == lookupKey else { return }
        knownFollowers = mutualPubkeys.map { pubkey in
            ProfileKnownFollower(pubkey: pubkey, profile: profiles[pubkey] ?? cachedProfiles[pubkey])
        }
    }

    func saveProfile(
        fields: EditableProfileFields,
        currentAccountPubkey: String?,
        currentNsec: String?
    ) async -> Bool {
        guard normalizePubkey(currentAccountPubkey) == normalizePubkey(pubkey) else {
            profileSaveError = "Only the active account can edit this profile."
            return false
        }

        guard let normalizedNsec = normalizeNsec(currentNsec),
              let keypair = Keypair(nsec: normalizedNsec.lowercased()) else {
            profileSaveError = "Sign in with a private key to edit your profile."
            return false
        }

        guard !isSavingProfile else { return false }
        isSavingProfile = true
        profileSaveError = nil

        defer {
            isSavingProfile = false
        }

        do {
            let baseSnapshot = metadataSnapshot
            let content = try ProfileMetadataEditing.mergedContent(
                fields: fields,
                baseJSON: baseSnapshot?.jsonObject ?? [:]
            )
            let sdkTags = (baseSnapshot?.tags ?? []).compactMap(decodeSDKTag(from:))

            let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .metadata)
                .content(content)
                .appendTags(contentsOf: sdkTags)
                .build(signedBy: keypair)

            let eventData = try JSONEncoder().encode(event)

            let targets = Self.normalizedRelayURLs(writeRelayURLs)
            let publishOutcome = await relayClient.publishEvent(
                to: targets,
                eventData: eventData,
                eventID: event.id,
                successPolicy: .returnAfterFirstSuccess
            )

            if publishOutcome.successfulSourceCount == 0 {
                if let firstFailureMessage = publishOutcome.firstFailureMessage {
                    throw SourcePublishTransportError(message: firstFailureMessage)
                }
                throw RelayClientError.publishRejected("Couldn't publish profile metadata")
            }

            let localEvent = Self.localEvent(from: event)
            await eventRepository.store(events: [localEvent])

            let updatedProfile = NostrProfile.decode(from: content)
            metadataSnapshot = ProfileMetadataSnapshot(
                content: content,
                tags: localEvent.tags,
                createdAt: localEvent.createdAt
            )
            profile = updatedProfile
            if let updatedProfile {
                await ProfileCache.shared.store(profiles: [pubkey: updatedProfile], missed: [])
            }
            NotificationCenter.default.post(
                name: .profileMetadataUpdated,
                object: nil,
                userInfo: ["pubkey": pubkey.lowercased()]
            )
            profileSaveError = nil
            return true
        } catch {
            profileSaveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func uploadProfileImage(
        data: Data,
        mimeType: String,
        filename: String,
        currentAccountPubkey: String?,
        currentNsec: String?
    ) async throws -> String {
        guard normalizePubkey(currentAccountPubkey) == normalizePubkey(pubkey) else {
            throw ProfileMediaUploadError.notActiveAccount
        }

        guard let normalizedNsec = normalizeNsec(currentNsec) else {
            throw ProfileMediaUploadError.invalidCredentials
        }

        let uploadedURL = try await mediaUploadService.uploadProfileImage(
            data: data,
            mimeType: mimeType,
            filename: filename,
            nsec: normalizedNsec
        )
        return uploadedURL.absoluteString
    }

    private func fetchProfileMetadataSnapshot(
        relayURLs: [URL],
        pubkey: String
    ) async throws -> ProfileMetadataSnapshot? {
        let targets = Self.normalizedRelayURLs(relayURLs)
        guard !targets.isEmpty else { return nil }
        return try await profileEventService.fetchProfileMetadataSnapshot(relayURLs: targets, pubkey: pubkey)
    }

    private func mergeKeepingNewest(itemsToMerge: [FeedItem]) {
        LocalPublicationStore.shared.mergeFetchedItems(itemsToMerge)
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in itemsToMerge {
            byID[item.id] = item
        }
        items = pruneMutedItems(byID.values.sorted {
            if $0.event.createdAt == $1.event.createdAt {
                return $0.id > $1.id
            }
            return $0.event.createdAt > $1.event.createdAt
        })
    }

    private func mergeWithLocalPublicationItems(_ fetchedItems: [FeedItem]) -> [FeedItem] {
        LocalPublicationStore.shared.mergeFetchedItems(fetchedItems)
        return pruneMutedItems(
            HomeFeedPageFetcher.mergeItemArrays(
                primary: fetchedItems,
                secondary: localPublicationItems()
            )
        )
    }

    private func localPublicationItems() -> [FeedItem] {
        let normalizedProfilePubkey = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return LocalPublicationStore.shared.records(matching: { item in
            item.displayAuthorPubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedProfilePubkey
        })
        .map(\.item)
    }

    private func filteredItems(_ sourceItems: [FeedItem], for mode: FeedMode) -> [FeedItem] {
        let hideNSFW = AppSettingsStore.shared.hideNSFWContent
        return sourceItems.filter { item in
            if MuteStore.shared.shouldHideAny(item.moderationEvents) {
                return false
            }
            if hideNSFW && item.moderationEvents.contains(where: { $0.containsNSFWHashtag }) {
                return false
            }

            return ProfileFeedVisibility.isVisible(item, in: mode)
        }
    }

    private func filteredEvents(_ sourceEvents: [NostrEvent], for mode: FeedMode) -> [NostrEvent] {
        let hideNSFW = AppSettingsStore.shared.hideNSFWContent
        return sourceEvents.filter { event in
            if hideNSFW && event.containsNSFWHashtag {
                return false
            }

            return ProfileFeedVisibility.isVisible(event, in: mode)
        }
    }

    private func loadMoreErrorMessage(for mode: FeedMode) -> String {
        switch mode {
        case .posts:
            return "Couldn't load more posts."
        case .postsAndReplies:
            return "Couldn't load more replies."
        case .articles:
            return "Couldn't load more articles."
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

    private func clearVisibleItemsCache() {
        visibleItemsCacheKey = nil
        visibleItemsCache = []
    }

    private static func localEvent(from event: NostrSDK.NostrEvent) -> NostrEvent {
        NostrEvent(
            id: event.id.lowercased(),
            pubkey: event.pubkey.lowercased(),
            createdAt: Int(event.createdAt),
            kind: event.kind.rawValue,
            tags: event.tags.map { [$0.name, $0.value] + $0.otherParameters },
            content: event.content,
            sig: event.signature ?? ""
        )
    }

    private struct FeedWindow {
        let events: [NostrEvent]
        let oldestCreatedAt: Int?
        let hasReachedEnd: Bool
    }

    private func fetchModeAwareAuthorEvents(
        until: Int?,
        minimumVisibleCount: Int,
        fetchTimeout: TimeInterval,
        relayFetchMode: RelayFetchMode,
        moderationSnapshot: MuteFilterSnapshot? = nil
    ) async throws -> FeedWindow {
        let targetMode = mode
        let requestedKinds = Self.feedKinds(for: targetMode)
        let batchSize = max(pageSize, 100)
        let maxBatches = 4

        var aggregated: [NostrEvent] = []
        var nextUntil = until
        var oldestFetchedCreatedAt: Int?
        var hasReachedEnd = false

        for _ in 0..<maxBatches {
            let fetched = try await service.fetchAuthorEvents(
                relayURLs: readRelayURLs,
                authorPubkey: pubkey,
                kinds: requestedKinds,
                limit: batchSize,
                until: nextUntil,
                fetchTimeout: fetchTimeout,
                relayFetchMode: relayFetchMode,
                relayOnly: true,
                moderationSnapshot: moderationSnapshot
            )

            if fetched.isEmpty {
                hasReachedEnd = true
                break
            }

            let paginationCursor = feedPaginationCursor(from: fetched) ?? fetched.last?.createdAt
            oldestFetchedCreatedAt = paginationCursor
            hasReachedEnd = FeedPaginationHeuristic.shouldStopPaging(afterFetchedCount: fetched.count)
            aggregated = mergedEventsKeepingNewest(existing: aggregated, incoming: fetched)

            if filteredEvents(aggregated, for: targetMode).count >= minimumVisibleCount {
                break
            }

            guard !hasReachedEnd, let oldestFetchedCreatedAt else {
                break
            }

            let candidateUntil = max(oldestFetchedCreatedAt - 1, 0)
            guard candidateUntil > 0 else {
                hasReachedEnd = true
                break
            }
            nextUntil = candidateUntil
        }

        return FeedWindow(
            events: aggregated,
            oldestCreatedAt: oldestFetchedCreatedAt,
            hasReachedEnd: hasReachedEnd
        )
    }

    private func mergedEventsKeepingNewest(existing: [NostrEvent], incoming: [NostrEvent]) -> [NostrEvent] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id.lowercased(), $0) })
        for event in incoming {
            byID[event.id.lowercased()] = event
        }
        return byID.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id > $1.id
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private func mergedItemsKeepingNewest(existing: [FeedItem], incoming: [FeedItem]) -> [FeedItem] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for item in incoming {
            byID[item.id] = item
        }
        return byID.values.sorted {
            if $0.event.createdAt == $1.event.createdAt {
                return $0.id > $1.id
            }
            return $0.event.createdAt > $1.event.createdAt
        }
    }

    private func decodeSDKTag(from raw: [String]) -> NostrSDK.Tag? {
        guard raw.count >= 2 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
            return nil
        }
        return tag
    }

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for pubkey in pubkeys.sorted() {
            let normalized = normalizePubkey(pubkey)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func normalizeNsec(_ value: String?) -> String? {
        guard let trimmed = value?.trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
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

    private static func feedKinds(for mode: FeedMode) -> [Int] {
        switch mode {
        case .posts, .postsAndReplies:
            return requestedFeedKinds.filter { $0 != FeedKindFilters.longFormArticle }
        case .articles:
            return [FeedKindFilters.longFormArticle]
        }
    }
}

enum ProfileFeedVisibility {
    private static func isVisibleArticleContent(_ event: NostrEvent) -> Bool {
        event.kind == FeedKindFilters.longFormArticle &&
            !event.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isVisible(_ event: NostrEvent, in mode: FeedMode) -> Bool {
        switch mode {
        case .posts:
            return event.kind != FeedKindFilters.longFormArticle &&
                !event.isReplyNote
        case .postsAndReplies:
            return event.isReplyNote
        case .articles:
            return isVisibleArticleContent(event)
        }
    }

    static func isVisible(_ item: FeedItem, in mode: FeedMode) -> Bool {
        switch mode {
        case .posts:
            return item.event.kind != FeedKindFilters.longFormArticle &&
                !item.displayEvent.isReplyNote
        case .postsAndReplies:
            return item.displayEvent.isReplyNote
        case .articles:
            return isVisibleArticleContent(item.event)
        }
    }
}

enum ProfileMediaUploadError: LocalizedError {
    case notActiveAccount
    case invalidCredentials
    case invalidUploadService
    case invalidUploadResponse
    case missingUploadedURL
    case uploadFailed(statusCode: Int)
    case uploadFailedWithMessage(String)

    var errorDescription: String? {
        switch self {
        case .notActiveAccount:
            return "Only the active account can edit this profile."
        case .invalidCredentials:
            return "Sign in with a private key to upload profile media."
        case .invalidUploadService:
            return "Media upload service is unavailable right now."
        case .invalidUploadResponse:
            return "Upload completed, but the media URL response was invalid."
        case .missingUploadedURL:
            return "Upload completed, but no media URL was returned."
        case .uploadFailed(let statusCode):
            return "Media upload failed (\(statusCode))."
        case .uploadFailedWithMessage(let message):
            return message
        }
    }
}

actor ProfileMediaUploadService {
    static let shared = ProfileMediaUploadService()
    private let mediaUploadService = MediaUploadService.shared

    func uploadProfileImage(
        data: Data,
        mimeType: String,
        filename: String,
        nsec: String
    ) async throws -> URL {
        do {
            let result = try await mediaUploadService.uploadMedia(
                data: data,
                mimeType: mimeType,
                filename: filename,
                nsec: nsec,
                provider: .blossom
            )
            return result.url
        } catch let uploadError as MediaUploadError {
            switch uploadError {
            case .invalidCredentials:
                throw ProfileMediaUploadError.invalidCredentials
            case .invalidUploadService:
                throw ProfileMediaUploadError.invalidUploadService
            case .missingUploadedURL:
                throw ProfileMediaUploadError.missingUploadedURL
            case .invalidUploadResponse:
                throw ProfileMediaUploadError.invalidUploadResponse
            case .blossomUploadFailed(let statusCode), .nip96UploadFailed(let statusCode):
                throw ProfileMediaUploadError.uploadFailed(statusCode: statusCode)
            case .blossomFallbackFailed(let primaryDescription, let fallbackDescription):
                throw ProfileMediaUploadError.uploadFailedWithMessage(
                    "Blossom failed: \(primaryDescription) Tried Nostr.Build too: \(fallbackDescription)"
                )
            case .unsupportedBlossomPayment, .missingFileData:
                throw uploadError
            }
        } catch {
            throw error
        }
    }
}

extension Notification.Name {
    static let profileMetadataUpdated = Notification.Name("x21.profileMetadataUpdated")
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
