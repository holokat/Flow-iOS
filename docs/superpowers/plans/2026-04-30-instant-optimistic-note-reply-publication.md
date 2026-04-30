# Instant Optimistic Note And Reply Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make notes and replies appear immediately, remain visible across refreshes, and surface failed publication state without deleting the local item.

**Architecture:** Add a shared `LocalPublicationStore` keyed by event ID, then merge those local records into feed and thread view models instead of letting refreshes replace optimistic items. Feed rows and thread replies render lightweight publication status adornments, and compose updates the shared record from `publishing` to `posted` or `failed` in place.

**Tech Stack:** SwiftUI, `ObservableObject`, async/await, existing `FeedItem`/compose publish services, XCTest, source guardrail tests, `xcodebuild`

---

### Task 1: Create Shared Local Publication State

**Files:**
- Create: `Sources/Feed/LocalPublicationStore.swift`
- Modify: `Sources/Compose/ComposeNoteSheet.swift`
- Test: `Tests/LocalPublicationStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testRegisterPublishingAndMarkFailedKeepsRecordVisible() {
    let store = LocalPublicationStore()
    let item = FeedItem(event: sampleEvent(id: "note-1"), profile: nil)

    store.registerPublishing(item: item, scope: .feed)
    store.markFailed(eventID: "note-1", message: "Connection timeout")

    let record = try XCTUnwrap(store.record(eventID: "note-1"))
    XCTAssertEqual(record.state, .failed(message: "Connection timeout"))
    XCTAssertEqual(store.visibleItems(scope: .feed).map(\.id), ["note-1"])
}

@MainActor
func testMarkPostedTransitionsExistingPublishingRecord() {
    let store = LocalPublicationStore()
    let item = FeedItem(event: sampleEvent(id: "note-2"), profile: nil)

    store.registerPublishing(item: item, scope: .feed)
    store.markPosted(eventID: "note-2")

    let record = try XCTUnwrap(store.record(eventID: "note-2"))
    XCTAssertEqual(record.state, .posted)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -only-testing:FlowTests/LocalPublicationStoreTests`
Expected: FAIL because `LocalPublicationStore` and tests do not exist yet, or because the test bundle still hits the known simulator-loading failure.

- [ ] **Step 3: Write the minimal implementation**

```swift
@MainActor
final class LocalPublicationStore: ObservableObject {
    enum Scope: Equatable {
        case feed
        case profile(pubkey: String)
        case hashtag(String)
        case thread(rootEventID: String)
    }

    enum State: Equatable {
        case publishing
        case posted
        case failed(message: String?)
    }

    struct Record: Identifiable, Equatable {
        let id: String
        var item: FeedItem
        var scope: Scope
        var state: State
        var createdAt: Date
    }

    @Published private(set) var recordsByID: [String: Record] = [:]

    func registerPublishing(item: FeedItem, scope: Scope) { ... }
    func markPosted(eventID: String) { ... }
    func markFailed(eventID: String, message: String?) { ... }
    func mergeFetchedItem(_ item: FeedItem) { ... }
    func visibleItems(scope: Scope) -> [FeedItem] { ... }
    func record(eventID: String) -> Record? { ... }
}
```

- [ ] **Step 4: Wire compose to the shared store**

```swift
onOptimisticPublished?(preparedPublication.item)
localPublicationStore.registerPublishing(
    item: preparedPublication.item,
    scope: publicationScope(for: preparedPublication)
)

if didFinish {
    localPublicationStore.markPosted(eventID: preparedPublication.item.id)
} else {
    localPublicationStore.markFailed(
        eventID: preparedPublication.item.id,
        message: viewModel.feedbackMessage
    )
}
```

- [ ] **Step 5: Run tests and commit**

Run: `xcodebuild build-for-testing -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -derivedDataPath /tmp/flow-local-publication-plan -quiet`
Expected: BUILD SUCCEEDED with existing unrelated warnings.

```bash
git add /Users/k/code/x21-ios/Sources/Feed/LocalPublicationStore.swift /Users/k/code/x21-ios/Sources/Compose/ComposeNoteSheet.swift /Users/k/code/x21-ios/Tests/LocalPublicationStoreTests.swift
git commit -m "Add shared local publication store"
```

### Task 2: Preserve Local Publications In Feeds

**Files:**
- Modify: `Sources/Home/HomeFeedViewModel.swift`
- Modify: `Sources/Profile/ProfileViewModel.swift`
- Modify: `Sources/Hashtag/HashtagFeedViewModel.swift`
- Test: `Tests/HomeFeedViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testRefreshKeepsOptimisticPublishedItemWhenFetchedResultsDoNotContainIt() async throws {
    let harness = try HomeFeedViewModelHarness()
    let optimistic = FeedItem(event: sampleEvent(id: "optimistic-note"), profile: nil)

    harness.viewModel.insertOptimisticPublishedItem(optimistic)
    harness.serviceStub.nextRefreshItems = []

    await harness.viewModel.refresh()

    XCTAssertTrue(harness.viewModel.items.contains { $0.id == "optimistic-note" })
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -only-testing:FlowTests/HomeFeedViewModelTests`
Expected: FAIL because refresh currently drops optimistic-only items when fetched results are empty or stale.

- [ ] **Step 3: Merge fetched items with local publication records**

```swift
func insertOptimisticPublishedItem(_ item: FeedItem) {
    guard itemIsAllowedForCurrentSource(item) else { return }
    localPublicationStore.registerPublishing(item: item, scope: .feed)
    mergeKeepingNewest(itemsToMerge: [item])
}

private func mergedVisibleItemsWithLocalPublications(
    _ fetched: [FeedItem],
    source: HomePrimaryFeedSource
) -> [FeedItem] {
    let localItems = localPublicationStore.visibleItems(scope: scope(for: source))
    return pruneItemsForSource(pruneMutedItems(mergeItemArrays(primary: localItems, secondary: fetched)))
}
```

- [ ] **Step 4: Apply the same merge rule to profile and hashtag feeds**

```swift
func insertOptimisticPublishedItem(_ item: FeedItem) {
    guard item.displayAuthorPubkey.lowercased() == pubkey.lowercased() else { return }
    localPublicationStore.registerPublishing(item: item, scope: .profile(pubkey: pubkey.lowercased()))
    mergeKeepingNewest(itemsToMerge: [item])
}
```

- [ ] **Step 5: Run tests and commit**

Run: `xcodebuild build-for-testing -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -derivedDataPath /tmp/flow-feed-optimistic-plan -quiet`
Expected: BUILD SUCCEEDED with existing unrelated warnings.

```bash
git add /Users/k/code/x21-ios/Sources/Home/HomeFeedViewModel.swift /Users/k/code/x21-ios/Sources/Profile/ProfileViewModel.swift /Users/k/code/x21-ios/Sources/Hashtag/HashtagFeedViewModel.swift /Users/k/code/x21-ios/Tests/HomeFeedViewModelTests.swift
git commit -m "Preserve optimistic publications across feed refreshes"
```

### Task 3: Preserve Local Replies In Thread Detail

**Files:**
- Modify: `Sources/Thread/ThreadDetailViewModel.swift`
- Modify: `Sources/Thread/ThreadDetailView.swift`
- Test: `Tests/ThreadDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testReplyRefreshPreservesOptimisticReplyUntilConnectedSourcesEchoIt() async throws {
    let harness = try ThreadDetailViewModelHarness()
    let optimisticReply = FeedItem(event: sampleReplyEvent(id: "reply-1", rootID: harness.rootEventID), profile: nil)

    harness.viewModel.appendLocalReply(optimisticReply)
    harness.serviceStub.nextReplies = []

    await harness.viewModel.refresh()

    XCTAssertTrue(harness.viewModel.replies.contains { $0.id == "reply-1" })
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -only-testing:FlowTests/ThreadDetailViewModelTests`
Expected: FAIL because `scheduleReplyRefresh()` currently replaces `rawReplies`.

- [ ] **Step 3: Merge thread refreshes with local publication state**

```swift
private func mergedThreadRepliesWithLocalPublications(_ fetched: [FeedItem]) -> [FeedItem] {
    let localReplies = localPublicationStore.visibleItems(
        scope: .thread(rootEventID: rootItem.displayEventID.lowercased())
    )
    return Self.sortedReplies(mergeItemArrays(primary: localReplies, secondary: fetched))
}

func appendLocalReply(_ item: FeedItem) {
    localPublicationStore.registerPublishing(
        item: item,
        scope: .thread(rootEventID: rootItem.displayEventID.lowercased())
    )
    ...
}
```

- [ ] **Step 4: Keep scroll/refresh behavior stable**

```swift
onOptimisticPublished: { item in
    viewModel.appendLocalReply(item)
    pendingReplyScrollTargetID = item.id
}
```

- [ ] **Step 5: Run tests and commit**

Run: `xcodebuild build-for-testing -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -derivedDataPath /tmp/flow-thread-optimistic-plan -quiet`
Expected: BUILD SUCCEEDED with existing unrelated warnings.

```bash
git add /Users/k/code/x21-ios/Sources/Thread/ThreadDetailViewModel.swift /Users/k/code/x21-ios/Sources/Thread/ThreadDetailView.swift /Users/k/code/x21-ios/Tests/ThreadDetailViewModelTests.swift
git commit -m "Keep optimistic replies visible during thread refreshes"
```

### Task 4: Add Publication Status UI And Motion

**Files:**
- Modify: `Sources/Design/FeedRowView.swift`
- Modify: `Sources/Thread/ThreadDetailComponents.swift`
- Modify: `Sources/App/FlowTransitionMotion.swift`
- Modify: `Tests/FlowLayoutGuardrailsTests.swift`

- [ ] **Step 1: Write the failing guardrail tests**

```swift
func testFeedRowsRenderPublicationStatusAdornmentAndConnectedSourceCopy() throws {
    let source = try Self.sourceText(at: "Sources/Design/FeedRowView.swift")

    XCTAssertTrue(source.contains("LocalPublicationStore"))
    XCTAssertTrue(source.contains("connected sources"))
    XCTAssertFalse(source.contains("relay"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -only-testing:FlowTests/FlowLayoutGuardrailsTests`
Expected: FAIL because the adornment/copy does not exist yet or because the known simulator test-bundle loading issue prevents execution.

- [ ] **Step 3: Render subtle publication status UI**

```swift
@ObservedObject private var localPublicationStore = LocalPublicationStore.shared

private var publicationStatusAdornment: some View {
    switch localPublicationStore.record(eventID: item.id)?.state {
    case .publishing:
        return AnyView(ProgressView().controlSize(.mini))
    case .failed(let message):
        return AnyView(
            Button {
                activePublicationFailureMessage = message ?? "Couldn't publish to connected sources right now."
            } label: {
                Image(systemName: "exclamationmark.circle")
            }
        )
    default:
        return AnyView(EmptyView())
    }
}
```

- [ ] **Step 4: Use subtle insertion/state animation**

```swift
static func optimisticPublicationAnimation(reduceMotion: Bool) -> Animation? {
    guard !reduceMotion else { return nil }
    return .spring(response: 0.26, dampingFraction: 0.88)
}
```

- [ ] **Step 5: Run verification and commit**

Run: `xcodebuild build-for-testing -project /Users/k/code/x21-ios/Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,id=58261591-5BBF-4D27-9BBC-3040870537F2' -derivedDataPath /tmp/flow-publication-ui-plan -quiet`
Expected: BUILD SUCCEEDED with existing unrelated warnings.

```bash
git add /Users/k/code/x21-ios/Sources/Design/FeedRowView.swift /Users/k/code/x21-ios/Sources/Thread/ThreadDetailComponents.swift /Users/k/code/x21-ios/Sources/App/FlowTransitionMotion.swift /Users/k/code/x21-ios/Tests/FlowLayoutGuardrailsTests.swift
git commit -m "Add optimistic publication status UI"
```
