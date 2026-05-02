# Wisp Speed Parity Without NostrDB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `nostrdb` implementation and move Flow toward Wisp's fast path: targeted outbox reads, bounded relay health, selective write-behind persistence, hot in-memory indexes, batched metadata, and coalesced UI updates.

**Architecture:** Use `EventRepository` plus `EventPersistence` over `EventArchiveStore` as the local event layer instead of `FlowNostrDB`. `EventRepository` owns the in-memory event cache, dedup set, and recent feed state; `EventPersistence` owns Wisp-style selective write-behind persistence for useful kinds and own-user events. Keep recent feed IDs pinned, route author content through write relays, and reduce UI churn by batching live event hydration and metadata work.

**Tech Stack:** Swift 5, SwiftUI, Combine, SQLite3, XCTest, XcodeGen, xcodebuild

---

## Scope Decisions

- Delete `Sources/NostrDB` and remove `Vendor/nostrdb` from the build.
- Do not replace `nostrdb` with ObjectBox. Wisp's transferable idea is selective persistence and bounded caches, not the Android database choice.
- Keep `EventArchiveStore` as the durable store because it is already SQLite-backed, byte-budgeted, and tested.
- Make `EventRepository` the in-memory event repository and read-through facade over `EventPersistence`/`EventArchiveStore`.
- Prioritize author write relays for fetching author-authored events, matching Wisp's outbox behavior.
- Keep broad read relays and metadata fallback relays only as safety nets.

## Wisp Parity Targets

- Persistent relay cap: 30 relay connections.
- Ephemeral relay cap: 50 relay connections.
- Ephemeral failure cooldowns: 60 seconds for rejected/4xx style failures, 10 minutes for transport failures.
- Event persistence batch: flush at 50 events or after 200ms.
- Feed/UI coalescing window: 50ms for live event batches.
- Profile batch: flush at 200 pubkeys or after 100ms.
- Engagement batch: flush at 150 event IDs or after 500ms.
- Presentation cache capacity: 15,000 feed rows.
- Seen event dedup cap: 50,000 IDs for relay/live duplicate protection.

## File Map

### Remove NostrDB

- Delete: `Sources/NostrDB/FlowNostrDB.swift`
- Delete: `Sources/NostrDB/FlowNostrDBShim.c`
- Delete: `Sources/NostrDB/FlowNostrDBShim.h`
- Delete: `Sources/NostrDB/Flow-Bridging-Header.h`
- Delete: `Tests/FlowNostrDBTests.swift`
- Modify: `project.yml`
- Regenerate: `Flow.xcodeproj/project.pbxproj`
- Modify: `NOSTRDB_MIGRATION.md` to mark the migration retired and point to this plan.

### Wisp-Style Event Storage

- Create: `Sources/Feed/EventPersistence.swift`
- Modify: `Sources/Feed/EventArchiveStore.swift`
- Modify: `Sources/Feed/EventRepository.swift`
- Modify: `Sources/Feed/RecentFeedStore.swift`
- Test: `Tests/EventArchiveStoreTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

### Outbox Routing

- Modify: `Sources/Feed/AuthorRelayPlanner.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Sources/Home/HomeFeedPageFetching.swift`
- Modify: `Sources/Home/HomeFeedModels.swift`
- Test: `Tests/AuthorRelayPlannerTests.swift`
- Test: `Tests/HomeFeedViewModelTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

### Relay Health And Dedup

- Create: `Sources/Feed/RelayHealthStore.swift`
- Modify: `Sources/Feed/NostrRelayClient.swift`
- Modify: `Sources/Feed/RelayTimelineFetcher.swift`
- Test: `Tests/NostrRelayClientTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

### Live Batching And Metadata Backpressure

- Create: `Sources/Feed/MetadataRequestCoordinator.swift`
- Modify: `Sources/Home/HomeFeedViewModel.swift`
- Modify: `Sources/Feed/NostrProfileResolver.swift`
- Modify: `Sources/Feed/NostrReferenceResolver.swift`
- Modify: `Sources/Feed/FeedPresentationSupport.swift`
- Test: `Tests/HomeFeedViewModelTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

### Instrumentation

- Create: `Sources/Feed/WispParityDiagnostics.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Sources/Home/SettingsFeedsView.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

---

### Task 1: Remove NostrDB Build Wiring

**Files:**
- Modify: `project.yml`
- Regenerate: `Flow.xcodeproj/project.pbxproj`
- Delete: `Sources/NostrDB/FlowNostrDB.swift`
- Delete: `Sources/NostrDB/FlowNostrDBShim.c`
- Delete: `Sources/NostrDB/FlowNostrDBShim.h`
- Delete: `Sources/NostrDB/Flow-Bridging-Header.h`
- Delete: `Tests/FlowNostrDBTests.swift`

- [ ] **Step 1: Remove the vendored nostrdb sources from `project.yml`**

Replace the `Flow` target source list with only the app source tree:

```yaml
    sources:
      - path: Sources
        excludes:
          - ShareExtension/**
```

Remove these `settings.base` keys:

```yaml
        SWIFT_OBJC_BRIDGING_HEADER: Sources/NostrDB/Flow-Bridging-Header.h
        HEADER_SEARCH_PATHS:
          - $(inherited)
          - $(PROJECT_DIR)/Vendor/nostrdb
          - $(PROJECT_DIR)/Vendor/nostrdb/src
          - $(PROJECT_DIR)/Vendor/nostrdb/ccan
          - $(PROJECT_DIR)/Vendor/nostrdb/ccan/ccan/short_types
          - $(PROJECT_DIR)/Vendor/nostrdb/ccan/ccan/compiler
          - $(PROJECT_DIR)/Vendor/nostrdb/flatcc
        GCC_PREPROCESSOR_DEFINITIONS:
          - $(inherited)
          - MDB_SHORT_SEMNAMES=1
          - MDB_SEM_NAME_PREFIX=flow
```

- [ ] **Step 2: Regenerate the Xcode project**

Run:

```bash
xcodegen generate
```

Expected:

```text
Generated project Flow.xcodeproj
```

- [ ] **Step 3: Delete the NostrDB source and test files**

Run:

```bash
git rm -r Sources/NostrDB
git rm Tests/FlowNostrDBTests.swift
```

- [ ] **Step 4: Retire the migration note**

Replace `NOSTRDB_MIGRATION.md` with:

```markdown
# NostrDB Migration Retired

The NostrDB migration was retired on 2026-05-02.

Flow now follows the Wisp-style architecture in `docs/superpowers/plans/2026-05-02-wisp-speed-parity-without-nostrdb.md`: selective SQLite event persistence, a hot `EventRepository` index, bounded relay health, outbox-first routing, and batched UI/metadata work.
```

- [ ] **Step 5: Verify no production references remain**

Run:

```bash
rg -n "FlowNostrDB|nostrDatabase|nostrdb|Flow-Bridging-Header" Sources Tests project.yml Flow.xcodeproj/project.pbxproj
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add project.yml Flow.xcodeproj Sources Tests NOSTRDB_MIGRATION.md
git commit -m "chore: remove nostrdb build integration"
```

---

### Task 2: Remove NostrDB Test Harness Shims

**Files:**
- Modify: `Tests/NostrFeedServiceTests.swift`
- Modify: `Tests/HomeFeedViewModelTests.swift`
- Modify: `Tests/FeedVisibilityTests.swift`
- Modify: `Tests/FeedEngagementViewportCoordinatorTests.swift`

- [ ] **Step 1: Replace helper signatures that accept `FlowNostrDB`**

In `Tests/NostrFeedServiceTests.swift`, replace the helper with:

```swift
private func makeFeedService(
    relayClient: any NostrRelayEventFetching,
    fileManager: TestFileManager,
    eventRepository customEventRepository: EventRepository? = nil,
    presentationCache: FeedPresentationCache = .shared
) -> NostrFeedService {
    let profileSnapshotStore = ProfileSnapshotStore(fileManager: fileManager)
    let profileCache = ProfileCache(snapshotStore: profileSnapshotStore)
    let followListCache = FollowListSnapshotCache(fileManager: fileManager)
    let eventRepository = customEventRepository ?? EventRepository(fileManager: fileManager)

    return NostrFeedService(
        relayClient: relayClient,
        timelineCache: TimelineEventCache(),
        profileCache: profileCache,
        relayHintCache: ProfileRelayHintCache(),
        followListCache: followListCache,
        eventRepository: eventRepository,
        presentationCache: presentationCache
    )
}
```

- [ ] **Step 2: Remove the compatibility initializer extension**

Delete this extension from `Tests/NostrFeedServiceTests.swift`:

```swift
extension NostrFeedService {
    init(
        relayClient: any NostrRelayEventFetching = NostrRelayClient(),
        timelineCache: any TimelineEventCaching = TimelineEventCache.shared,
        profileCache: any ProfileCaching = ProfileCache.shared,
        relayHintCache: any ProfileRelayHintCaching = ProfileRelayHintCache.shared,
        followListCache: any FollowListSnapshotStoring = FollowListSnapshotCache.shared,
        eventRepository: any EventRepositoryStoring = EventRepository.shared,
        nostrDatabase: FlowNostrDB,
        presentationCache: FeedPresentationCache = .shared,
        outboxDiagnosticsStore: OutboxRecoveryDiagnosticsStore = .shared,
        localFeedReadsEnabled: Bool? = nil
    ) {
        let _ = nostrDatabase
        let _ = localFeedReadsEnabled
        self.init(
            relayClient: relayClient,
            timelineCache: timelineCache,
            profileCache: profileCache,
            relayHintCache: relayHintCache,
            followListCache: followListCache,
            eventRepository: eventRepository,
            presentationCache: presentationCache,
            outboxDiagnosticsStore: outboxDiagnosticsStore
        )
    }
}
```

- [ ] **Step 3: Replace each test-local `FlowNostrDB` construction**

For every block shaped like:

```swift
let nostrDatabase = FlowNostrDB(fileManager: fileManager)
let service = makeFeedService(
    relayClient: relayClient,
    fileManager: fileManager,
    nostrDatabase: nostrDatabase
)
```

replace it with:

```swift
let service = makeFeedService(
    relayClient: relayClient,
    fileManager: fileManager
)
```

For direct service initializers, remove the `nostrDatabase:` argument and keep the other dependencies unchanged.

- [ ] **Step 4: Delete skipped tests whose only purpose was NostrDB**

Remove tests named:

```text
testFetchProfilesBackfillsSnapshotOnlyProfilesIntoNostrDB
testLocalProfileSearchUsesNostrDBProfileIndexBeyondGenericQueryCapacity
testFetchAuthorFeedUsesNostrDBForPaginatedQueriesWithoutRelayFetch
testFetchAuthorFeedReturnsLocalNostrDBResultsWhenRelayRefreshFails
testFetchAuthorFeedSkipsLocalNostrDBFallbackWhenLocalFeedReadsDisabled
testFetchFollowingFeedSkipsLocalNostrDBFallbackWhenLocalFeedReadsDisabled
```

- [ ] **Step 5: Run the reference cleanup search**

Run:

```bash
rg -n "FlowNostrDB|nostrDatabase|localFeedReadsEnabled|NostrDB" Tests Sources
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Tests Sources
git commit -m "test: remove nostrdb harness dependencies"
```

---

### Task 3: Add Wisp-Style Selective Event Persistence

**Files:**
- Create: `Sources/Feed/EventPersistence.swift`
- Modify: `Sources/Feed/FeedStorageProtocols.swift`
- Modify: `Sources/Feed/EventRepository.swift`
- Test: `Tests/EventArchiveStoreTests.swift`

- [ ] **Step 1: Add the write-behind persistence actor**

Create `Sources/Feed/EventPersistence.swift` with the persisted-kind set, normalized current-user pubkey, `shouldPersist(_:)`, deduped 50-event/200ms write-behind batching, `flush()`, and read-through wrappers backed by `EventArchiveStore`.

```swift
import Foundation

actor EventPersistence {
    static let shared = EventPersistence()

    private let archiveStore: EventArchiveStore
    private let batchLimit: Int
    private let flushDelayNanoseconds: UInt64
    private var pendingByID: [String: NostrEvent] = [:]
    private var flushTask: Task<Void, Never>?

    init(
        archiveStore: EventArchiveStore = EventArchiveStore(),
        batchLimit: Int = 50,
        flushDelayNanoseconds: UInt64 = 200_000_000
    ) {
        self.archiveStore = archiveStore
        self.batchLimit = max(batchLimit, 1)
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    func persistEvents(_ events: [NostrEvent]) {
        for event in events where policy.shouldPersist(event) {
            let id = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { continue }
            pendingByID[id] = event
        }

        if pendingByID.count >= batchLimit {
            flushTask?.cancel()
            flushTask = nil
            flushNow()
            return
        }

        scheduleFlush()
    }

    func flushNow() {
        guard !pendingByID.isEmpty else { return }
        let events = Array(pendingByID.values)
        pendingByID.removeAll(keepingCapacity: true)
        flushTask?.cancel()
        flushTask = nil

        Task {
            await archiveStore.store(events: events)
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [flushDelayNanoseconds] in
            try? await Task.sleep(nanoseconds: flushDelayNanoseconds)
            await self.flushNow()
        }
    }
}
```

- [ ] **Step 2: Extend `EventRepositoryStoring` for explicit flushes**

In `Sources/Feed/FeedStorageProtocols.swift`, update the protocol:

```swift
protocol EventRepositoryStoring: Actor, Sendable {
    func store(events: [NostrEvent]) async
    func storeRecentFeed(key: String, events: [NostrEvent]) async
    func recentFeed(key: String) async -> [NostrEvent]?
    func events(ids: [String]) async -> [String: NostrEvent]
    func flushPersistence() async
}
```

Add the default implementation:

```swift
extension EventRepositoryStoring {
    func flushPersistence() async {}
}
```

- [ ] **Step 4: Add tests for policy filtering and write-behind**

Append to `Tests/EventArchiveStoreTests.swift`:

```swift
func testEventPersistenceKeepsWispKindsAndOwnEventsOnly() {
    let ownPubkey = hex("a")
    let persistence = EventPersistence(currentUserPubkey: ownPubkey)
    let ownEphemeral = makeEvent(id: hex("1"), pubkey: ownPubkey, kind: 40_000, content: "own")
    let remoteNote = makeEvent(id: hex("2"), pubkey: hex("b"), kind: 1, content: "note")
    let remoteEphemeral = makeEvent(id: hex("3"), pubkey: hex("c"), kind: 40_000, content: "drop")

    XCTAssertTrue(policy.shouldPersist(ownEphemeral))
    XCTAssertTrue(policy.shouldPersist(remoteNote))
    XCTAssertFalse(policy.shouldPersist(remoteEphemeral))
}

func testPersistenceCoordinatorFlushesOnlyPersistableEvents() async throws {
    let rootURL = try makeRootURL(prefix: "EventPersistence")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let archive = EventArchiveStore(
        fileManager: EventArchiveTestFileManager(rootURL: rootURL),
        budget: .init(
            archiveSoftLimitBytes: 1_000_000,
            archiveHardLimitBytes: 1_200_000,
            hotIndexTargetEventCount: 100,
            minimumFreeDiskBytes: 0
        )
    )
    let coordinator = EventPersistence(
        archiveStore: archive,
        batchLimit: 50,
        flushDelayNanoseconds: 20_000_000
    )
    let persistable = makeEvent(id: hex("4"), kind: 1, content: "keep")
    let dropped = makeEvent(id: hex("5"), kind: 40_000, content: "drop")

    await coordinator.enqueue(events: [persistable, dropped])
    try await Task.sleep(nanoseconds: 80_000_000)

    let restored = await archive.events(ids: [persistable.id, dropped.id])
    XCTAssertEqual(restored[persistable.id.lowercased()]?.content, "keep")
    XCTAssertNil(restored[dropped.id.lowercased()])
}
```

- [ ] **Step 5: Run the new tests**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/EventArchiveStoreTests
```

Expected: all `EventArchiveStoreTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Feed/EventPersistence.swift Sources/Feed/FeedStorageProtocols.swift Tests/EventArchiveStoreTests.swift
git commit -m "feat: add selective event persistence"
```

---

### Task 4: Make EventRepository Own The Wisp-Style Event Cache

**Files:**
- Modify: `Sources/Feed/EventRepository.swift`
- Modify: `Sources/Feed/RecentFeedStore.swift`
- Test: `Tests/EventArchiveStoreTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Replace `EventRepository` state with in-memory cache/dedup/recent-feed ownership**

Use these stored properties:

```swift
private let maxStoredEvents: Int
private let archiveStore: EventArchiveStore
private let persistenceCoordinator: EventPersistence
private var eventsByID: [String: NostrEvent] = [:]
private var recency: [String] = []
private var recentFeedEventIDsByKey: [String: [String]] = [:]

init(
    fileManager: FileManager = .default,
    archiveBudget: EventArchiveBudget = EventArchiveBudget(),
    archiveStore: EventArchiveStore? = nil,
    persistenceCoordinator: EventPersistence? = nil
) {
    let resolvedArchiveStore = archiveStore ?? EventArchiveStore(
        fileManager: fileManager,
        budget: archiveBudget
    )
    self.archiveStore = resolvedArchiveStore
    self.persistenceCoordinator = persistenceCoordinator ?? EventPersistence(
        archiveStore: resolvedArchiveStore
    )
    self.maxStoredEvents = max(archiveBudget.hotIndexTargetEventCount, 4_000)
}
```

- [ ] **Step 2: Persist through the coordinator from `store(events:)`**

Replace `store(events:)` with:

```swift
func store(events: [NostrEvent]) async {
    guard !events.isEmpty else { return }
    for event in events {
        storeEvent(event)
    }
    await persistenceCoordinator.enqueue(events: events)
}
```

- [ ] **Step 3: Persist and pin recent feeds**

Replace `storeRecentFeed(key:events:)` with:

```swift
func storeRecentFeed(key: String, events: [NostrEvent]) async {
    let normalizedKey = normalizeKey(key)
    guard !normalizedKey.isEmpty else { return }

    var orderedIDs: [String] = []
    orderedIDs.reserveCapacity(events.count)

    for event in events {
        let normalizedID = normalizeEventID(event.id)
        guard !normalizedID.isEmpty else { continue }
        storeEvent(event, normalizedID: normalizedID)
        orderedIDs.append(normalizedID)
    }

    recentFeedEventIDsByKey[normalizedKey] = orderedIDs
    await archiveStore.storeRecentFeed(key: normalizedKey, events: events)
}
```

- [ ] **Step 4: Make `recentFeed(key:)` read through the archive**

Replace the body after key normalization with:

```swift
if let orderedIDs = recentFeedEventIDsByKey[normalizedKey], !orderedIDs.isEmpty {
    let events = orderedIDs.compactMap { eventsByID[$0] }
    if !events.isEmpty {
        return events
    }
}

let archivedIDs = await archiveStore.recentFeedEventIDs(key: normalizedKey)
guard !archivedIDs.isEmpty else { return nil }
let archivedEventsByID = await archiveStore.events(ids: archivedIDs)
let archivedEvents = archivedIDs.compactMap { archivedEventsByID[$0] }
guard !archivedEvents.isEmpty else { return nil }

for event in archivedEvents {
    storeEvent(event)
}
recentFeedEventIDsByKey[normalizedKey] = archivedEvents.map { normalizeEventID($0.id) }
return archivedEvents
```

- [ ] **Step 5: Make `events(ids:)` read through the archive for misses**

After reading hot events, add:

```swift
let missingIDs = normalizedIDs.filter { resolved[$0] == nil }
if !missingIDs.isEmpty {
    let archived = await archiveStore.events(ids: missingIDs)
    for (eventID, event) in archived {
        resolved[eventID] = event
        storeEvent(event, normalizedID: eventID)
    }
}
```

- [ ] **Step 6: Implement explicit flush**

Add:

```swift
func flushPersistence() async {
    await persistenceCoordinator.flushNow()
}
```

- [ ] **Step 7: Add a read-through test**

Append to `Tests/EventArchiveStoreTests.swift`:

```swift
func testEventRepositoryReadsThroughArchiveForColdEvents() async throws {
    let rootURL = try makeRootURL(prefix: "EventRepositoryReadThrough")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
    let archive = EventArchiveStore(fileManager: fileManager)
    let event = makeEvent(id: hex("8"), kind: 1, content: "archived")
    await archive.store(events: [event])

    let store = EventRepository(
        fileManager: fileManager,
        archiveStore: archive,
        persistenceCoordinator: EventPersistence(archiveStore: archive)
    )

    let restored = await store.events(ids: [event.id])
    XCTAssertEqual(restored[event.id.lowercased()]?.content, "archived")
}
```

- [ ] **Step 8: Run storage tests**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/EventArchiveStoreTests
```

Expected: all `EventArchiveStoreTests` pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/Feed/EventRepository.swift Sources/Feed/RecentFeedStore.swift Tests/EventArchiveStoreTests.swift
git commit -m "feat: make seen events archive backed"
```

---

### Task 5: Switch Author Outbox Reads To Write Relays

**Files:**
- Modify: `Sources/Feed/AuthorRelayPlanner.swift`
- Modify: `Tests/AuthorRelayPlannerTests.swift`
- Modify: `Tests/NostrFeedServiceTests.swift`
- Modify: `Tests/HomeFeedViewModelTests.swift`

- [ ] **Step 1: Change relay priority**

In `AuthorRelayPlanner.makePlan`, replace the primary relay selection with:

```swift
let entry = normalizedDirectoryEntries[normalizedAuthor]
let authorPrimaryRelayURLs: [URL]
if let entry, !entry.writeRelayURLs.isEmpty {
    authorPrimaryRelayURLs = entry.writeRelayURLs
} else {
    authorPrimaryRelayURLs = entry?.readRelayURLs ?? []
}
```

- [ ] **Step 2: Update planner tests**

Rename `testPlannerPrefersAuthorReadRelaysBeforeAppReadRelays` to:

```swift
func testPlannerPrefersAuthorWriteRelaysBeforeReadAndAppRelays()
```

Change the expected relay order to:

```swift
[
    "wss://author-write.example/",
    "wss://relay.damus.io/",
    "wss://relay.primal.net/"
]
```

Rename `testPlannerFallsBackToWriteRelaysWhenReadRelaysAreMissing` to:

```swift
func testPlannerFallsBackToReadRelaysWhenWriteRelaysAreMissing()
```

Use `readRelayURLs: [URL(string: "wss://author-read.example/")!]`, `writeRelayURLs: []`, and expect:

```swift
[
    "wss://author-read.example/",
    "wss://relay.damus.io/"
]
```

- [ ] **Step 3: Update outbox feed tests**

In `Tests/NostrFeedServiceTests.swift`, rename:

```text
testOutboxRelayPlanStoresFetchedRelayDirectoryEntryAndPrefersReadRelays
testFetchOutboxBackedAuthorFeedUsesReadRelaysWithoutQueryingWriteRelays
```

to:

```text
testOutboxRelayPlanStoresFetchedRelayDirectoryEntryAndPrefersWriteRelays
testFetchOutboxBackedAuthorFeedUsesWriteRelaysForAuthorContent
```

Update assertions so requested relay strings contain the write relay and do not require the read relay for author-authored content.

- [ ] **Step 4: Flip the home following test**

Rename `testFollowingFeedUsesConfiguredReadRelaysDirectlyInsteadOfOutboxRecovery` to:

```swift
func testFollowingFeedUsesAuthorOutboxRelaysForFollowedAuthors() async throws
```

Change the relay list tag to advertise a write relay:

```swift
let authorWriteRelayURL = URL(string: "wss://following-author-write.example")!
let relayListEvent = makeEvent(
    id: hex("7"),
    pubkey: authorPubkey,
    kind: 10_002,
    tags: [["r", authorWriteRelayURL.absoluteString, "write"]],
    content: "",
    createdAt: 1_700_000_330
)
```

Set `outboxNote` on `authorWriteRelayURL` and assert:

```swift
XCTAssertEqual(harness.viewModel.visibleItems.map(\.id), [outboxNote.id])
```

- [ ] **Step 5: Run focused outbox tests**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/AuthorRelayPlannerTests -only-testing:FlowTests/NostrFeedServiceTests/testOutboxRelayPlanStoresFetchedRelayDirectoryEntryAndPrefersWriteRelays -only-testing:FlowTests/NostrFeedServiceTests/testFetchOutboxBackedAuthorFeedUsesWriteRelaysForAuthorContent -only-testing:FlowTests/HomeFeedViewModelTests/testFollowingFeedUsesAuthorOutboxRelaysForFollowedAuthors
```

Expected: selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Feed/AuthorRelayPlanner.swift Tests/AuthorRelayPlannerTests.swift Tests/NostrFeedServiceTests.swift Tests/HomeFeedViewModelTests.swift
git commit -m "feat: prefer outbox write relays for author feeds"
```

---

### Task 6: Route The Main Following Page Through Outbox Groups

**Files:**
- Modify: `Sources/Home/HomeFeedPageFetching.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Test: `Tests/HomeFeedViewModelTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Replace broad following fetch in `fetchFollowingFeedPage`**

In `HomeFeedPageFetching.fetchFollowingFeedPage`, replace:

```swift
let fetchedEvents = try await service.fetchFollowingEvents(
    relayURLs: relayURLs,
    authors: authors,
    kinds: kinds,
    limit: probeLimit,
    until: cursor,
    fetchTimeout: fetchTimeout,
    relayFetchMode: relayFetchMode,
    relayOnly: true,
    moderationSnapshot: moderationSnapshot
)
```

and the following `service.buildFeedItems` call with:

```swift
let fetched = try await service.fetchFollowingFeedRecoveringWithOutbox(
    baseReadRelayURLs: relayURLs,
    authors: authors,
    kinds: kinds,
    limit: probeLimit,
    until: cursor,
    hydrationMode: hydrationMode,
    fetchTimeout: fetchTimeout,
    relayFetchMode: relayFetchMode,
    moderationSnapshot: moderationSnapshot
)
let fetchedEvents = fetched.map(\.event)
```

Keep the existing pagination cursor, merge, mode filtering, and had-more logic.

- [ ] **Step 2: Add a service-level test for grouped relay fetches**

Add to `Tests/NostrFeedServiceTests.swift`:

```swift
func testFetchOutboxBackedFollowingFeedGroupsAuthorsByWriteRelay() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowOutboxFollowingGroups-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let fileManager = TestFileManager(rootURL: rootURL)
    let authorA = hex("a")
    let authorB = hex("b")
    let writeRelayA = URL(string: "wss://author-a-write.example")!
    let writeRelayB = URL(string: "wss://author-b-write.example")!
    let eventA = makeEvent(id: hex("1"), pubkey: authorA, kind: 1, tags: [], content: "a")
    let eventB = makeEvent(id: hex("2"), pubkey: authorB, kind: 1, tags: [], content: "b")
    let relayListA = makeEvent(
        id: hex("3"),
        pubkey: authorA,
        kind: 10_002,
        tags: [["r", writeRelayA.absoluteString, "write"]],
        content: ""
    )
    let relayListB = makeEvent(
        id: hex("4"),
        pubkey: authorB,
        kind: 10_002,
        tags: [["r", writeRelayB.absoluteString, "write"]],
        content: ""
    )
    let relayClient = RecordingOutboxRelayClient(eventsByRelay: [
        relayURL: [relayListA, relayListB],
        writeRelayA: [eventA],
        writeRelayB: [eventB]
    ])
    let service = makeFeedService(relayClient: relayClient, fileManager: fileManager)

    let items = try await service.fetchOutboxBackedFollowingFeed(
        baseReadRelayURLs: [relayURL],
        authors: [authorA, authorB],
        kinds: [1],
        limit: 10,
        until: nil,
        hydrationMode: .cachedProfilesOnly
    )

    XCTAssertEqual(Set(items.map(\.id)), Set([eventA.id, eventB.id]))
    let requested = Set(await relayClient.requestedRelayURLs().map { canonicalRelayString($0) })
    XCTAssertTrue(requested.contains("wss://author-a-write.example"))
    XCTAssertTrue(requested.contains("wss://author-b-write.example"))
}
```

- [ ] **Step 3: Run focused following tests**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/HomeFeedViewModelTests/testFollowingFeedUsesAuthorOutboxRelaysForFollowedAuthors -only-testing:FlowTests/NostrFeedServiceTests/testFetchOutboxBackedFollowingFeedGroupsAuthorsByWriteRelay
```

Expected: selected tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Home/HomeFeedPageFetching.swift Tests/NostrFeedServiceTests.swift Tests/HomeFeedViewModelTests.swift
git commit -m "feat: route following feed through outbox groups"
```

---

### Task 7: Add Relay Health, Caps, And Cooldowns

**Files:**
- Create: `Sources/Feed/RelayHealthStore.swift`
- Modify: `Sources/Feed/NostrRelayClient.swift`
- Test: `Tests/NostrRelayClientTests.swift`

- [ ] **Step 1: Add relay health state**

Create `Sources/Feed/RelayHealthStore.swift`:

```swift
import Foundation

actor RelayHealthStore {
    static let shared = RelayHealthStore()

    struct Configuration: Sendable {
        var maxPersistentConnections = 30
        var maxEphemeralConnections = 50
        var rejectionCooldown: TimeInterval = 60
        var transportFailureCooldown: TimeInterval = 600
    }

    private let configuration: Configuration
    private var cooldownUntilByRelay: [String: Date] = [:]

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func isAvailable(_ relayURL: URL, now: Date = Date()) -> Bool {
        let key = relayKey(relayURL)
        guard let cooldownUntil = cooldownUntilByRelay[key] else { return true }
        return cooldownUntil <= now
    }

    func recordFailure(_ error: Error, relayURL: URL, now: Date = Date()) {
        let message = String(describing: error).lowercased()
        let interval = message.contains("restricted") ||
            message.contains("rate") ||
            message.contains("blocked") ||
            message.contains("4")
            ? configuration.rejectionCooldown
            : configuration.transportFailureCooldown
        cooldownUntilByRelay[relayKey(relayURL)] = now.addingTimeInterval(interval)
    }

    func clearCooldown(_ relayURL: URL) {
        cooldownUntilByRelay[relayKey(relayURL)] = nil
    }

    private func relayKey(_ relayURL: URL) -> String {
        RelayURLSupport.normalizedRelayURLString(relayURL)
            ?? relayURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
```

- [ ] **Step 2: Inject health into `NostrRelayPool`**

Update the pool initializer:

```swift
private let healthStore: RelayHealthStore
private let maxConnections: Int
private var lastUsedAtByKey: [String: Date] = [:]

init(
    healthStore: RelayHealthStore = .shared,
    maxConnections: Int = 80
) {
    self.healthStore = healthStore
    self.maxConnections = max(maxConnections, 1)
}
```

- [ ] **Step 3: Reject cooled-down relays before opening sockets**

At the start of `fetchEvents`, `publishEvent`, and `streamEvents`, add:

```swift
guard await healthStore.isAvailable(relayURL) else {
    throw RelayClientError.closed("Relay is cooling down after recent failures.")
}
```

For `streamEvents`, return an `AsyncThrowingStream` that immediately finishes with the same error.

- [ ] **Step 4: Record failures and evict idle connections**

In pool methods, wrap connection operations:

```swift
do {
    let result = try await connection.fetchEvents(filter: filter, timeout: timeout)
    await healthStore.clearCooldown(relayURL)
    return result
} catch {
    await healthStore.recordFailure(error, relayURL: relayURL)
    throw error
}
```

Add after creating or touching a connection:

```swift
lastUsedAtByKey[key] = Date()
while connections.count > maxConnections,
      let oldestKey = lastUsedAtByKey.min(by: { $0.value < $1.value })?.key {
    connections[oldestKey] = nil
    lastUsedAtByKey[oldestKey] = nil
}
```

- [ ] **Step 5: Replace the skipped cooldown test**

In `Tests/NostrRelayClientTests.swift`, replace `testFetchEventsRespectsRelayCooldownBeforeOpeningSocket` with a non-skipped test that constructs a `RelayHealthStore`, calls `recordFailure`, injects it into `NostrRelayPool`, and asserts `fetchEvents` throws before any socket opens.

- [ ] **Step 6: Run relay tests**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/NostrRelayClientTests
```

Expected: all `NostrRelayClientTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Feed/RelayHealthStore.swift Sources/Feed/NostrRelayClient.swift Tests/NostrRelayClientTests.swift
git commit -m "feat: add bounded relay health"
```

---

### Task 8: Coalesce Live Events Before Hydration

**Files:**
- Modify: `Sources/Home/HomeFeedViewModel.swift`
- Test: `Tests/HomeFeedViewModelTests.swift`

- [ ] **Step 1: Add pending live event state**

Add to `HomeFeedViewModel`:

```swift
private var pendingLiveEventsByID: [String: NostrEvent] = [:]
private var liveEventFlushTask: Task<Void, Never>?
private static let liveEventFlushDelayNanoseconds: UInt64 = 50_000_000
```

- [ ] **Step 2: Replace per-event handling with enqueue**

Replace `handleLiveEvent(_:)` with:

```swift
private func handleLiveEvent(_ event: NostrEvent) async {
    let normalizedEventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard feedKinds(for: feedSource).contains(event.kind) else { return }
    guard !normalizedEventID.isEmpty, !knownEventIDs.contains(normalizedEventID) else { return }

    pendingLiveEventsByID[normalizedEventID] = event
    guard liveEventFlushTask == nil else { return }

    liveEventFlushTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: Self.liveEventFlushDelayNanoseconds)
        await MainActor.run {
            guard let self else { return }
            self.flushPendingLiveEvents()
        }
    }
}
```

- [ ] **Step 3: Add the batch flush**

Add:

```swift
private func flushPendingLiveEvents() {
    let events = Array(pendingLiveEventsByID.values)
        .sorted { $0.createdAt > $1.createdAt }
    pendingLiveEventsByID.removeAll(keepingCapacity: true)
    liveEventFlushTask = nil
    guard !events.isEmpty else { return }

    Task { [weak self, events] in
        guard let self else { return }
        await self.service.ingestLiveEvents(events)
        let hydrated = await self.service.buildFeedItems(
            relayURLs: await MainActor.run { self.hydrationRelayURLs(for: self.feedSource) },
            events: events,
            moderationSnapshot: await MainActor.run { self.muteFilterSnapshot }
        )
        await MainActor.run {
            self.applyLiveItems(hydrated)
        }
    }
}
```

Move the existing insertion logic from the old `handleLiveEvent(_:)` into:

```swift
private func applyLiveItems(_ liveItems: [FeedItem]) {
    let allowed = liveItems.filter { item in
        !knownEventIDs.contains(item.id) && itemIsAllowedForCurrentSource(item)
    }
    guard !allowed.isEmpty else { return }

    for item in allowed {
        knownEventIDs.insert(item.id)
    }

    bufferedNewItems = mergeItemArrays(
        primary: allowed,
        secondary: bufferedNewItems,
        feedSource: feedSource
    )
    scheduleAssetPrefetch(for: allowed)
}
```

Keep the existing article replacement branch inside `applyLiveItems(_:)` for `.articles`.

- [ ] **Step 4: Add a test-only flush hook**

Inside `HomeFeedViewModel`, add:

```swift
#if DEBUG
func flushLiveEventsForTesting() {
    liveEventFlushTask?.cancel()
    liveEventFlushTask = nil
    flushPendingLiveEvents()
}
#endif
```

- [ ] **Step 5: Add a batching test**

Add to `Tests/HomeFeedViewModelTests.swift`:

```swift
@MainActor
func testLiveEventsAreHydratedAsSingleBufferedBatch() async throws {
    let harness = try HomeFeedViewModelHarness()
    let first = makeEvent(id: hex("a"), pubkey: hex("b"), kind: FeedKindFilters.shortTextNote, tags: [], content: "one")
    let second = makeEvent(id: hex("c"), pubkey: hex("d"), kind: FeedKindFilters.shortTextNote, tags: [], content: "two")

    await harness.viewModel.handleLiveEventForTesting(first)
    await harness.viewModel.handleLiveEventForTesting(second)
    harness.viewModel.flushLiveEventsForTesting()
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(Set(harness.viewModel.bufferedNewItems.map(\.id)), Set([first.id, second.id]))
}
```

Add the debug hook:

```swift
#if DEBUG
func handleLiveEventForTesting(_ event: NostrEvent) async {
    await handleLiveEvent(event)
}
#endif
```

- [ ] **Step 6: Run home feed tests**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/HomeFeedViewModelTests/testLiveEventsAreHydratedAsSingleBufferedBatch
```

Expected: selected test passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/Home/HomeFeedViewModel.swift Tests/HomeFeedViewModelTests.swift
git commit -m "feat: coalesce live feed hydration"
```

---

### Task 9: Increase Presentation Cache And Add Metadata Backpressure

**Files:**
- Modify: `Sources/Feed/FeedPresentationSupport.swift`
- Create: `Sources/Feed/MetadataRequestCoordinator.swift`
- Modify: `Sources/Feed/NostrProfileResolver.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Increase presentation cache capacity**

In `FeedPresentationCache`, change:

```swift
private let capacity: Int = 512
```

to:

```swift
private let capacity: Int = 15_000
```

- [ ] **Step 2: Add metadata batching coordinator**

Create `Sources/Feed/MetadataRequestCoordinator.swift`:

```swift
import Foundation

actor MetadataRequestCoordinator {
    static let shared = MetadataRequestCoordinator()

    private let profileBatchLimit: Int
    private let profileFlushDelayNanoseconds: UInt64
    private var pendingProfilePubkeys = Set<String>()
    private var profileFlushTask: Task<Void, Never>?

    init(
        profileBatchLimit: Int = 200,
        profileFlushDelayNanoseconds: UInt64 = 100_000_000
    ) {
        self.profileBatchLimit = max(profileBatchLimit, 1)
        self.profileFlushDelayNanoseconds = profileFlushDelayNanoseconds
    }

    func collectProfiles(_ pubkeys: [String]) async -> [String] {
        for pubkey in pubkeys {
            let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            pendingProfilePubkeys.insert(normalized)
        }

        if pendingProfilePubkeys.count >= profileBatchLimit {
            return drainProfiles()
        }

        try? await Task.sleep(nanoseconds: profileFlushDelayNanoseconds)
        return drainProfiles()
    }

    func drainProfiles() -> [String] {
        let drained = Array(pendingProfilePubkeys).sorted()
        pendingProfilePubkeys.removeAll(keepingCapacity: true)
        profileFlushTask?.cancel()
        profileFlushTask = nil
        return drained
    }
}
```

- [ ] **Step 3: Use the coordinator in profile resolver call sites**

In `NostrProfileResolver.fetchProfiles`, before remote fetching, add:

```swift
let requestedPubkeys = await MetadataRequestCoordinator.shared.collectProfiles(Array(unresolvedPubkeys))
guard !requestedPubkeys.isEmpty else {
    return profilesByPubkey
}
```

Use `requestedPubkeys` where the current implementation initializes `let requestedPubkeys = Array(unresolvedPubkeys)`.

- [ ] **Step 4: Add coordinator tests**

Add to `Tests/NostrFeedServiceTests.swift`:

```swift
func testMetadataRequestCoordinatorDrainsProfilesAtBatchLimit() async {
    let coordinator = MetadataRequestCoordinator(profileBatchLimit: 2, profileFlushDelayNanoseconds: 1_000_000_000)
    async let first = coordinator.collectProfiles([hex("a")])
    try? await Task.sleep(nanoseconds: 10_000_000)
    let second = await coordinator.collectProfiles([hex("b")])
    let firstResult = await first

    XCTAssertEqual(Set(firstResult + second), Set([hex("a"), hex("b")]))
}
```

- [ ] **Step 5: Run metadata tests**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/NostrFeedServiceTests/testMetadataRequestCoordinatorDrainsProfilesAtBatchLimit
```

Expected: selected test passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/Feed/FeedPresentationSupport.swift Sources/Feed/MetadataRequestCoordinator.swift Sources/Feed/NostrProfileResolver.swift Tests/NostrFeedServiceTests.swift
git commit -m "feat: batch metadata and enlarge presentation cache"
```

---

### Task 10: Add Wisp Parity Diagnostics

**Files:**
- Create: `Sources/Feed/WispParityDiagnostics.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Sources/Feed/RelayTimelineFetcher.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Add diagnostics model and store**

Create `Sources/Feed/WispParityDiagnostics.swift`:

```swift
import Foundation

struct WispParityDiagnosticsSnapshot: Equatable, Sendable {
    var relayRequests = 0
    var relayEventsReceived = 0
    var duplicateRelayEventsDropped = 0
    var persistedEventsQueued = 0
    var liveBatchesFlushed = 0
}

actor WispParityDiagnosticsStore {
    static let shared = WispParityDiagnosticsStore()

    private var snapshot = WispParityDiagnosticsSnapshot()

    func recordRelayRequest() {
        snapshot.relayRequests += 1
    }

    func recordRelayEvents(received: Int, duplicatesDropped: Int) {
        snapshot.relayEventsReceived += received
        snapshot.duplicateRelayEventsDropped += duplicatesDropped
    }

    func recordPersistedQueued(_ count: Int) {
        snapshot.persistedEventsQueued += count
    }

    func recordLiveBatchFlushed() {
        snapshot.liveBatchesFlushed += 1
    }

    func currentSnapshot() -> WispParityDiagnosticsSnapshot {
        snapshot
    }

    func reset() {
        snapshot = WispParityDiagnosticsSnapshot()
    }
}
```

- [ ] **Step 2: Record relay request and dedup counts**

In `RelayTimelineFetcher.fetchTimelineEvents(relayURL:filter:timeout:useCache:)`, call:

```swift
await WispParityDiagnosticsStore.shared.recordRelayRequest()
```

In `mergedTimelineEvents`, compute duplicate count:

```swift
let receivedCount = events.count
let merged = deduplicateEvents(events).sorted { lhs, rhs in
    if lhs.createdAt == rhs.createdAt {
        return lhs.id > rhs.id
    }
    return lhs.createdAt > rhs.createdAt
}
Task {
    await WispParityDiagnosticsStore.shared.recordRelayEvents(
        received: receivedCount,
        duplicatesDropped: max(receivedCount - merged.count, 0)
    )
}
```

- [ ] **Step 3: Record persistence queue counts**

In `EventPersistence.enqueue`, after adding persistable events, call:

```swift
let queuedCount = pendingByID.count
Task {
    await WispParityDiagnosticsStore.shared.recordPersistedQueued(queuedCount)
}
```

- [ ] **Step 4: Add diagnostics test**

Add to `Tests/NostrFeedServiceTests.swift`:

```swift
func testWispParityDiagnosticsCountsDuplicateRelayEvents() async throws {
    await WispParityDiagnosticsStore.shared.reset()
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowWispDiagnostics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let fileManager = TestFileManager(rootURL: rootURL)
    let event = makeEvent(id: hex("a"), pubkey: hex("b"), kind: 1, tags: [], content: "dup")
    let relayClient = DelayedRelayClient(eventsByRelay: [
        relayURL: [event],
        relayURL2: [event]
    ])
    let service = makeFeedService(relayClient: relayClient, fileManager: fileManager)

    _ = try await service.fetchFeed(
        relayURLs: [relayURL, relayURL2],
        kinds: [1],
        limit: 10,
        hydrationMode: .cachedProfilesOnly,
        fetchTimeout: 0.1,
        relayFetchMode: .allRelays
    )

    try await Task.sleep(nanoseconds: 50_000_000)
    let snapshot = await WispParityDiagnosticsStore.shared.currentSnapshot()
    XCTAssertEqual(snapshot.relayRequests, 2)
    XCTAssertGreaterThanOrEqual(snapshot.duplicateRelayEventsDropped, 1)
}
```

- [ ] **Step 5: Run diagnostics test**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/NostrFeedServiceTests/testWispParityDiagnosticsCountsDuplicateRelayEvents
```

Expected: selected test passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/Feed/WispParityDiagnostics.swift Sources/Feed/NostrFeedService.swift Sources/Feed/RelayTimelineFetcher.swift Tests/NostrFeedServiceTests.swift
git commit -m "feat: add wisp parity diagnostics"
```

---

### Task 11: Full Verification

**Files:**
- No code edits

- [ ] **Step 1: Confirm NostrDB is gone**

Run:

```bash
rg -n "FlowNostrDB|nostrDatabase|NostrDB|nostrdb|Flow-Bridging-Header|Vendor/nostrdb" Sources Tests project.yml Flow.xcodeproj/project.pbxproj
```

Expected: no output.

- [ ] **Step 2: Run focused test suites**

Run:

```bash
xcodebuild test -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlowTests/AuthorRelayPlannerTests -only-testing:FlowTests/EventArchiveStoreTests -only-testing:FlowTests/NostrRelayClientTests -only-testing:FlowTests/NostrFeedServiceTests -only-testing:FlowTests/HomeFeedViewModelTests
```

Expected: all selected tests pass.

- [ ] **Step 3: Build the app**

Run:

```bash
xcodebuild -scheme Flow -project /Users/k/code/x21-ios/Flow.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Expected: build succeeds.

- [ ] **Step 4: Manual performance smoke test**

Run the app on the simulator and record:

```text
time to first 20 following rows
relay request count during first 5 seconds
relay events received during first 5 seconds
duplicate relay events dropped during first 5 seconds
visible row commits during first 5 seconds
archive count and archive bytes after first refresh
```

Acceptance:

```text
following feed uses author write relays when available
no nostrdb files are linked or opened
live event bursts create one buffered update per flush window
archive stores only Wisp persisted kinds plus own-user events
relay cooldown prevents immediate retry of a failed relay
```

- [ ] **Step 5: Final commit**

```bash
git status --short
git add Sources Tests project.yml Flow.xcodeproj docs
git commit -m "feat: align nostr feed performance with wisp"
```

---

## Self-Review

- Spec coverage: The plan removes `nostrdb`, adopts Wisp-style selective persistence, switches following feeds to outbox routing, prioritizes write relays, adds bounded relay health, coalesces live UI updates, enlarges presentation caching, and adds diagnostics.
- Placeholder scan: No task depends on unspecified files or unnamed behavior. Each code-changing task includes concrete files, code shapes, test commands, and expected results.
- Type consistency: New types are `EventRepository`, `EventPersistence`, `RelayHealthStore`, `MetadataRequestCoordinator`, and `WispParityDiagnosticsStore`; later tasks use the same names.
