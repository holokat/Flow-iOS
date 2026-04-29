# Outbox-Backed Local Feed Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Halo render from the local corpus immediately, then recover missing profile, following, thread, and referenced-event content from proper author outbox relays before falling back to generic app relays.

**Architecture:** Keep Flow DB plus the SQLite archive as the first render path for everything. Build a reusable author relay planner that prefers a profile's `10002` read relays, falls back to `10002` write relays only when no read relays exist, then uses cached relay hints, app read relays, and broad metadata fallback relays. Wire profile feeds, following feeds, thread replies, and referenced-event recovery to use that planner so any network refill also grows the local corpus.

**Tech Stack:** Swift, SwiftUI, FlowNostrDB, SQLite archive, Nostr relay fetchers, XCTest, xcodebuild

---

## Scope Decisions

- Local DB remains the primary fast path.
- Outbox is the primary network recovery path when local storage is missing or stale.
- Relay priority for authored content is:
  - author `10002` read relays
  - author `10002` write relays only if no read relays were declared
  - cached follow-list and observed relay hints
  - app read relays
  - broad metadata fallback relays
- The main profile/following/thread codepaths should use the same planner as the crawler so relay selection does not drift.
- Do not block first paint if local data is already good enough to render a useful screen.
- Persist every successful outbox recovery fetch back into the archive and Flow DB.

## Non-Goals

- Do not remove the SQLite archive or Flow DB split.
- Do not replace the foreground crawler; this plan sits on top of it.
- Do not treat author write relays as the default read source when read relays are known.
- Do not add a server-side indexer in this rollout.

## File Map

### Relay planning and cache model

- Create: `Sources/Feed/AuthorRelayPlanner.swift`
  Shared relay planner for profile/following/thread reads and the crawler.
- Modify: `Sources/Feed/FeedStorageProtocols.swift`
  Add a typed author relay directory cache protocol instead of only raw hint ordering.
- Modify: `Sources/Feed/FeedCaches.swift`
  Store author read/write relay directory entries plus legacy hint relays.
- Modify: `Sources/Profile/ProfileEventService.swift`
  Expose parsed read/write relay lists in a way the planner can consume directly.
- Modify: `Sources/Feed/LocalCorpusCrawler.swift`
  Switch crawler relay planning over to the shared planner.

### Nostr feed recovery

- Modify: `Sources/Feed/NostrFeedService.swift`
  Add outbox-backed recovery APIs for author feeds, following feeds, profile fetches, and referenced events.
- Modify: `Sources/Profile/ProfileViewModel.swift`
  Use outbox-backed author-feed recovery for notes, replies, and articles.
- Modify: `Sources/Home/HomeFeedViewModel.swift`
  Use outbox-backed following-feed recovery instead of generic read-relay batches.
- Modify: `Sources/Thread/ThreadDetailViewModel.swift`
  Use outbox-backed reply and note-activity target recovery for thread screens.

### Diagnostics

- Modify: `Sources/Home/SettingsMediaView.swift`
  Show author relay directory coverage and outbox fallback counters.

### Tests

- Create: `Tests/AuthorRelayPlannerTests.swift`
- Create: `Tests/ProfileViewModelTests.swift`
- Create: `Tests/ThreadDetailViewModelTests.swift`
- Modify: `Tests/NostrFeedServiceTests.swift`
- Modify: `Tests/HomeFeedViewModelTests.swift`
- Modify: `Tests/LocalCorpusCrawlerTests.swift`
- Modify: `Tests/FeedVisibilityTests.swift`

---

### Task 1: Create A Shared Author Relay Planner And Directory Cache

**Files:**
- Create: `Sources/Feed/AuthorRelayPlanner.swift`
- Modify: `Sources/Feed/FeedStorageProtocols.swift`
- Modify: `Sources/Feed/FeedCaches.swift`
- Modify: `Sources/Feed/LocalCorpusCrawler.swift`
- Test: `Tests/AuthorRelayPlannerTests.swift`
- Test: `Tests/LocalCorpusCrawlerTests.swift`

- [ ] **Step 1: Write the failing relay-priority tests**

Add `Tests/AuthorRelayPlannerTests.swift` with:

```swift
import XCTest
@testable import Flow

final class AuthorRelayPlannerTests: XCTestCase {
    func testPlannerPrefersAuthorReadRelaysBeforeAppReadRelays() {
        let planner = AuthorRelayPlanner()
        let author = String(repeating: "a", count: 64)
        let plan = planner.makePlan(
            authors: [author],
            baseReadRelayURLs: [URL(string: "wss://relay.damus.io/")!],
            directoryEntriesByPubkey: [
                author: AuthorRelayDirectoryEntry(
                    readRelayURLs: [URL(string: "wss://author-read.example/")!],
                    writeRelayURLs: [URL(string: "wss://author-write.example/")!],
                    hintRelayURLs: [],
                    refreshedAt: nil
                )
            ],
            fallbackRelayURLs: [URL(string: "wss://relay.primal.net/")!]
        )

        XCTAssertEqual(
            plan.relayURLs(for: author).map(\.absoluteString),
            [
                "wss://author-read.example/",
                "wss://relay.damus.io/",
                "wss://relay.primal.net/"
            ]
        )
    }

    func testPlannerFallsBackToWriteRelaysWhenReadRelaysAreMissing() {
        let planner = AuthorRelayPlanner()
        let author = String(repeating: "b", count: 64)
        let plan = planner.makePlan(
            authors: [author],
            baseReadRelayURLs: [URL(string: "wss://relay.damus.io/")!],
            directoryEntriesByPubkey: [
                author: AuthorRelayDirectoryEntry(
                    readRelayURLs: [],
                    writeRelayURLs: [URL(string: "wss://author-write.example/")!],
                    hintRelayURLs: [],
                    refreshedAt: nil
                )
            ],
            fallbackRelayURLs: []
        )

        XCTAssertEqual(
            plan.relayURLs(for: author).map(\.absoluteString),
            [
                "wss://author-write.example/",
                "wss://relay.damus.io/"
            ]
        )
    }
}
```

- [ ] **Step 2: Run the focused planner tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/AuthorRelayPlannerTests
```

Expected: FAIL because the planner type and directory entry model do not exist.

- [ ] **Step 3: Implement the planner and typed directory cache**

Add the shared planner and cache model:

```swift
// Sources/Feed/FeedStorageProtocols.swift
struct AuthorRelayDirectoryEntry: Equatable, Sendable {
    let readRelayURLs: [URL]
    let writeRelayURLs: [URL]
    let hintRelayURLs: [URL]
    let refreshedAt: Date?
}

protocol AuthorRelayDirectoryCaching: Actor, Sendable {
    func entry(for pubkey: String) -> AuthorRelayDirectoryEntry?
    func entries(for pubkeys: [String]) -> [String: AuthorRelayDirectoryEntry]
    func store(entry: AuthorRelayDirectoryEntry, for pubkey: String)
}

// Sources/Feed/AuthorRelayPlanner.swift
struct AuthorRelayPlan: Equatable, Sendable {
    let relayURLsByPubkey: [String: [URL]]

    func relayURLs(for pubkey: String) -> [URL] {
        relayURLsByPubkey[pubkey.lowercased()] ?? []
    }
}

struct AuthorRelayPlanner {
    func makePlan(
        authors: [String],
        baseReadRelayURLs: [URL],
        directoryEntriesByPubkey: [String: AuthorRelayDirectoryEntry],
        fallbackRelayURLs: [URL]
    ) -> AuthorRelayPlan {
        var relayURLsByPubkey: [String: [URL]] = [:]

        for author in authors {
            let normalized = author.lowercased()
            let entry = directoryEntriesByPubkey[normalized]
            let authorPrimary = !(entry?.readRelayURLs.isEmpty ?? true)
                ? (entry?.readRelayURLs ?? [])
                : (entry?.writeRelayURLs ?? [])

            relayURLsByPubkey[normalized] = normalizedRelayURLs(
                authorPrimary
                + (entry?.hintRelayURLs ?? [])
                + baseReadRelayURLs
                + fallbackRelayURLs
            )
        }

        return AuthorRelayPlan(relayURLsByPubkey: relayURLsByPubkey)
    }
}
```

Update `LocalCorpusCrawler` to consume the shared planner instead of its private crawl-only planner.

- [ ] **Step 4: Re-run planner and crawler tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/AuthorRelayPlannerTests \
  -only-testing:FlowTests/LocalCorpusCrawlerTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Feed/AuthorRelayPlanner.swift Sources/Feed/FeedStorageProtocols.swift Sources/Feed/FeedCaches.swift Sources/Feed/LocalCorpusCrawler.swift Tests/AuthorRelayPlannerTests.swift Tests/LocalCorpusCrawlerTests.swift
git commit -m "feat: add shared author relay planner"
```

### Task 2: Populate The Author Relay Directory From `10002` And Existing Hints

**Files:**
- Modify: `Sources/Profile/ProfileEventService.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Sources/Feed/FeedCaches.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Write the failing directory-population tests**

Add tests in `Tests/NostrFeedServiceTests.swift`:

```swift
@MainActor
func testFetchRelayConnectionsStoresReadAndWriteRelayDirectoryEntry() async throws {
    let pubkey = String(repeating: "c", count: 64)
    let service = makeService()

    let entry = await service.refreshAuthorRelayDirectory(
        relayURLs: [URL(string: "wss://relay.damus.io/")!],
        pubkey: pubkey
    )

    XCTAssertEqual(entry?.readRelayURLs.first?.absoluteString, "wss://author-read.example/")
    XCTAssertEqual(entry?.writeRelayURLs.first?.absoluteString, "wss://author-write.example/")
}

@MainActor
func testFetchFollowListSnapshotMergesHintRelaysIntoDirectoryEntry() async throws {
    let pubkey = String(repeating: "d", count: 64)
    let service = makeService()

    _ = try await service.fetchFollowListSnapshot(
        relayURLs: [URL(string: "wss://relay.damus.io/")!],
        pubkey: pubkey,
        relayFetchMode: .allRelays
    )

    let entry = await service.authorRelayDirectoryEntry(pubkey: String(repeating: "e", count: 64))
    XCTAssertFalse(entry?.hintRelayURLs.isEmpty ?? true)
}
```

- [ ] **Step 2: Run the focused service tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/NostrFeedServiceTests
```

Expected: FAIL because the service has no typed author relay directory API.

- [ ] **Step 3: Add directory refresh and storage hooks**

Implement a typed refresh path:

```swift
// Sources/Feed/NostrFeedService.swift
@MainActor
func authorRelayDirectoryEntry(pubkey: String) async -> AuthorRelayDirectoryEntry? {
    await relayDirectoryCache.entry(for: normalizePubkey(pubkey))
}

@MainActor
func refreshAuthorRelayDirectory(
    relayURLs: [URL],
    pubkey: String
) async -> AuthorRelayDirectoryEntry? {
    let snapshot = await profileEventService.fetchRelayConnectionsSnapshot(
        relayURLs: relayURLs,
        pubkey: pubkey
    )

    let entry = AuthorRelayDirectoryEntry(
        readRelayURLs: snapshot.readRelays,
        writeRelayURLs: snapshot.writeRelays,
        hintRelayURLs: (await relayHintCache.relayHints(for: [pubkey]))[normalizePubkey(pubkey)] ?? [],
        refreshedAt: Date()
    )
    await relayDirectoryCache.store(entry: entry, for: normalizePubkey(pubkey))
    return entry
}
```

When `fetchFollowListSnapshot(...)` decodes `relayHintsByPubkey`, merge those into existing directory entries so follow-list hints and `10002` data live together.

- [ ] **Step 4: Re-run the service tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Profile/ProfileEventService.swift Sources/Feed/NostrFeedService.swift Sources/Feed/FeedCaches.swift Tests/NostrFeedServiceTests.swift
git commit -m "feat: persist author relay directory entries"
```

### Task 3: Add Outbox-Backed Author And Following Feed APIs

**Files:**
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Sources/Feed/AuthorRelayPlanner.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Write the failing outbox-recovery tests**

Add tests in `Tests/NostrFeedServiceTests.swift`:

```swift
@MainActor
func testFetchAuthorFeedRecoveringWithOutboxUsesLocalRowsBeforeNetwork() async throws {
    let service = makeServiceWithLocalAuthorEvents()

    let items = try await service.fetchAuthorFeedRecoveringWithOutbox(
        baseRelayURLs: [URL(string: "wss://relay.damus.io/")!],
        authorPubkey: String(repeating: "f", count: 64),
        kinds: [1],
        limit: 20,
        until: nil
    )

    XCTAssertEqual(items.count, 20)
    XCTAssertEqual(service.spyRelayClient.fetchCount, 0)
}

@MainActor
func testFetchAuthorFeedRecoveringWithOutboxUsesAuthorReadRelaysWhenLocalIsSparse() async throws {
    let service = makeServiceWithSparseLocalAuthorEvents()

    _ = try await service.fetchAuthorFeedRecoveringWithOutbox(
        baseRelayURLs: [URL(string: "wss://relay.damus.io/")!],
        authorPubkey: String(repeating: "1", count: 64),
        kinds: [30_023],
        limit: 40,
        until: nil
    )

    XCTAssertEqual(
        service.spyRelayClient.requestedRelayURLs.first?.absoluteString,
        "wss://author-read.example/"
    )
}

@MainActor
func testFetchFollowingFeedRecoveringWithOutboxGroupsAuthorsByRelaySignature() async throws {
    let service = makeServiceForFollowingOutboxGrouping()

    _ = try await service.fetchFollowingFeedRecoveringWithOutbox(
        baseRelayURLs: [URL(string: "wss://relay.damus.io/")!],
        authors: [String(repeating: "2", count: 64), String(repeating: "3", count: 64)],
        kinds: [1, 6, 16, 1_111, 1_244],
        limit: 100,
        until: nil
    )

    XCTAssertEqual(service.spyRelayClient.batchRequestCount, 2)
}
```

- [ ] **Step 2: Run the focused service tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/NostrFeedServiceTests
```

Expected: FAIL because the recovery APIs do not exist.

- [ ] **Step 3: Implement local-first outbox recovery APIs**

Add reusable service entry points:

```swift
func fetchAuthorFeedRecoveringWithOutbox(
    baseRelayURLs: [URL],
    authorPubkey: String,
    kinds: [Int],
    limit: Int,
    until: Int?,
    hydrationMode: FeedItemHydrationMode = .full,
    fetchTimeout: TimeInterval = 12,
    moderationSnapshot: MuteFilterSnapshot? = nil
) async throws -> [FeedItem]

func fetchFollowingFeedRecoveringWithOutbox(
    baseRelayURLs: [URL],
    authors: [String],
    kinds: [Int],
    limit: Int,
    until: Int?,
    hydrationMode: FeedItemHydrationMode = .full,
    fetchTimeout: TimeInterval = 12,
    moderationSnapshot: MuteFilterSnapshot? = nil
) async throws -> [FeedItem]
```

Implementation rules:

```swift
let localEvents = localTimelineEvents(relayURLs: baseRelayURLs, filter: filter)
if localTimelineEventsSatisfyRequest(localEvents, filter: filter),
   !shouldRefillFromRelays(relayURLs: baseRelayURLs, filter: filter) {
    return await buildFeedItems(...)
}

let directoryEntries = await relayDirectoryCache.entries(for: [authorPubkey])
let plan = authorRelayPlanner.makePlan(
    authors: [authorPubkey],
    baseReadRelayURLs: baseRelayURLs,
    directoryEntriesByPubkey: directoryEntries,
    fallbackRelayURLs: metadataRelayURLs(primaryRelayURLs: baseRelayURLs)
)

let fetched = try await fetchTimelineEvents(
    relayURLs: plan.relayURLs(for: authorPubkey),
    filter: filter,
    timeout: fetchTimeout,
    useCache: false,
    relayFetchMode: .allRelays
)
```

For following feeds, group authors by the normalized relay signature from the plan before dispatching the relay fetches.

- [ ] **Step 4: Re-run the service tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Feed/NostrFeedService.swift Sources/Feed/AuthorRelayPlanner.swift Tests/NostrFeedServiceTests.swift
git commit -m "feat: add outbox-backed feed recovery APIs"
```

### Task 4: Wire Profile Loads And Articles To Outbox-Backed Recovery

**Files:**
- Modify: `Sources/Profile/ProfileViewModel.swift`
- Create: `Tests/ProfileViewModelTests.swift`
- Modify: `Tests/FeedVisibilityTests.swift`

- [ ] **Step 1: Write the failing profile tests**

Add `Tests/ProfileViewModelTests.swift` with:

```swift
@MainActor
func testInitialProfileLoadUsesOutboxBackedAuthorFeedRecovery() async throws {
    let service = FakeProfileOutboxFeedService()
    let viewModel = ProfileViewModel(
        pubkey: String(repeating: "4", count: 64),
        readRelayURLs: [URL(string: "wss://relay.damus.io/")!],
        service: service
    )

    await viewModel.load()

    XCTAssertEqual(service.fetchAuthorFeedRecoveringWithOutboxCallCount, 1)
}

@MainActor
func testArticlesModeUsesOutboxBackedRecoveryWithArticleKindsOnly() async throws {
    let service = FakeProfileOutboxFeedService()
    let viewModel = ProfileViewModel(
        pubkey: String(repeating: "5", count: 64),
        readRelayURLs: [URL(string: "wss://relay.damus.io/")!],
        service: service
    )

    viewModel.mode = .articles
    await viewModel.load()

    XCTAssertEqual(service.lastRequestedKinds, [30_023])
}
```

Also extend `Tests/FeedVisibilityTests.swift` so the profile article visibility assertions still pass after the service swap.

- [ ] **Step 2: Run the focused profile tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/ProfileViewModelTests \
  -only-testing:FlowTests/FeedVisibilityTests
```

Expected: FAIL because `ProfileViewModel` still calls `fetchAuthorFeed(...)`.

- [ ] **Step 3: Switch profile author feeds and metadata refresh to outbox-backed recovery**

Update `fetchModeAwareAuthorFeed(...)`:

```swift
let fetched = try await service.fetchAuthorFeedRecoveringWithOutbox(
    baseRelayURLs: readRelayURLs,
    authorPubkey: pubkey,
    kinds: requestedKinds,
    limit: batchSize,
    until: nextUntil,
    hydrationMode: hydrationMode,
    fetchTimeout: fetchTimeout,
    moderationSnapshot: moderationSnapshot
)
```

Also refresh the viewed profile's relay directory before deeper pagination:

```swift
await service.refreshAuthorRelayDirectory(
    relayURLs: readRelayURLs,
    pubkey: pubkey
)
```

- [ ] **Step 4: Re-run the focused profile tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Profile/ProfileViewModel.swift Tests/ProfileViewModelTests.swift Tests/FeedVisibilityTests.swift
git commit -m "feat: use outbox-backed profile feed recovery"
```

### Task 5: Wire Following Feed, Thread Replies, And Referenced Events

**Files:**
- Modify: `Sources/Home/HomeFeedViewModel.swift`
- Modify: `Sources/Thread/ThreadDetailViewModel.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Tests/HomeFeedViewModelTests.swift`
- Create: `Tests/ThreadDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing following and thread tests**

Add tests:

```swift
@MainActor
func testFollowingBootstrapUsesOutboxBackedRecovery() async throws {
    let service = FakeHomeOutboxFeedService()
    let viewModel = makeHomeFeedViewModel(service: service)

    await viewModel.load()

    XCTAssertEqual(service.fetchFollowingFeedRecoveringWithOutboxCallCount, 1)
}

@MainActor
func testThreadReplyRefreshUsesOutboxBackedReferencedEventRecovery() async throws {
    let service = FakeThreadOutboxFeedService()
    let viewModel = makeThreadDetailViewModel(service: service)

    await viewModel.loadReplies()

    XCTAssertGreaterThan(service.fetchReferencedEventsCallCount, 0)
    XCTAssertTrue(service.lastReferencedEventRelayModeWasOutboxBacked)
}
```

- [ ] **Step 2: Run the focused following and thread tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/HomeFeedViewModelTests \
  -only-testing:FlowTests/ThreadDetailViewModelTests
```

Expected: FAIL because home and thread still use generic read-relay fetches.

- [ ] **Step 3: Switch following and thread recovery to the shared outbox path**

In `HomeFeedViewModel.fetchFollowingFeedPage(...)`:

```swift
let fetched = try await service.fetchFollowingFeedRecoveringWithOutbox(
    baseRelayURLs: relayURLs,
    authors: authors,
    kinds: kinds,
    limit: probeLimit,
    until: cursor,
    hydrationMode: hydrationMode,
    fetchTimeout: fetchTimeout,
    moderationSnapshot: moderationSnapshot
)
```

In thread resolution paths inside `NostrFeedService`, replace raw `fetchTimelineEvents(relayURLs: relayURLs, ...)` calls for missing IDs and address lookups with relay targets built from `AuthorRelayPlanner` and `reference.targetPubkey` when known.

- [ ] **Step 4: Re-run the focused following and thread tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Home/HomeFeedViewModel.swift Sources/Thread/ThreadDetailViewModel.swift Sources/Feed/NostrFeedService.swift Tests/HomeFeedViewModelTests.swift Tests/ThreadDetailViewModelTests.swift
git commit -m "feat: use outbox-backed following and thread recovery"
```

### Task 6: Add Diagnostics For Outbox Coverage And Fallback Behavior

**Files:**
- Modify: `Sources/Home/SettingsMediaView.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Write the failing diagnostics test**

Add a focused test in `Tests/NostrFeedServiceTests.swift`:

```swift
@MainActor
func testOutboxDiagnosticsTrackDirectoryHitsAndGenericFallbacks() async throws {
    let service = makeServiceWithOutboxDiagnostics()

    _ = try await service.fetchAuthorFeedRecoveringWithOutbox(
        baseRelayURLs: [URL(string: "wss://relay.damus.io/")!],
        authorPubkey: String(repeating: "6", count: 64),
        kinds: [1],
        limit: 20,
        until: nil
    )

    let diagnostics = await service.outboxDiagnostics()
    XCTAssertGreaterThanOrEqual(diagnostics.directoryHitCount, 1)
}
```

- [ ] **Step 2: Run the focused diagnostics tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/NostrFeedServiceTests
```

Expected: FAIL because there is no outbox diagnostics surface.

- [ ] **Step 3: Add a minimal diagnostics surface**

Add counters:

```swift
struct OutboxRecoveryDiagnostics: Equatable, Sendable {
    var directoryHitCount: Int = 0
    var writeRelayFallbackCount: Int = 0
    var genericReadRelayFallbackCount: Int = 0
}
```

Surface them in `SettingsMediaView` with concise rows:

```swift
DiagnosticsMetricRow(
    title: "Outbox Directory Entries",
    value: "\(mediaDiagnostics.outboxDirectoryEntryCount)",
    info: "Profiles with known read/write relay data for outbox recovery."
)
```

- [ ] **Step 4: Re-run the diagnostics tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Home/SettingsMediaView.swift Sources/Feed/NostrFeedService.swift Tests/NostrFeedServiceTests.swift
git commit -m "feat: add outbox recovery diagnostics"
```

## Self-Review

- Spec coverage:
  - local DB first: covered in Tasks 3, 4, and 5
  - proper outbox recovery: covered in Tasks 1, 2, and 3
  - profile/following/thread integration: covered in Tasks 4 and 5
  - maintainable shared planner: covered in Task 1
  - diagnostics: covered in Task 6
- Placeholder scan:
  - no `TODO`, `TBD`, or “write tests later” placeholders remain
  - every task has named files, commands, and concrete test names
- Type consistency:
  - planner uses `AuthorRelayDirectoryEntry`
  - service entry points use `fetchAuthorFeedRecoveringWithOutbox` and `fetchFollowingFeedRecoveringWithOutbox`
  - diagnostics use `OutboxRecoveryDiagnostics`

