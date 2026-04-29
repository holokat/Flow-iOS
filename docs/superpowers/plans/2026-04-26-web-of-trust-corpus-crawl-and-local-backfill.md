# Web Of Trust Corpus Crawl And Local Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill Halo's local corpus aggressively enough that profiles, threads, articles, referenced notes, metadata, and follow graphs render from local storage most of the time instead of waiting on relays.

**Architecture:** Build a foreground-first crawler that runs while Halo is open and on Wi-Fi, expands through a 2-hop web of trust, and backfills tiered event kinds into the SQLite archive plus the Flow DB hot index. Add an opportunistic short background refresh pass, stronger retention for replaceable and referenced events, and diagnostics that clearly separate archive counts from hot-index counts.

**Tech Stack:** SwiftUI, Network (`NWPathMonitor`), BackgroundTasks, SQLite3, FlowNostrDB, Nostr relay fetchers, XCTest, xcodebuild

---

## Scope Decisions

- Crawl the user's relevant social graph, not the global firehose.
- Default crawl scope is `2` hops of web of trust.
- Foreground crawl runs only while the app is open, the user is signed in, and Wi-Fi is available.
- Background crawl is opportunistic and short-lived when iOS grants refresh time; it is not assumed to be always-on.
- Deep historical crawl includes long-form articles and the app's main visible feed kinds.
- Reactions and other high-churn note-activity kinds stay shallow or on-demand in the first rollout.
- Use the existing larger storage posture already discussed:
  - archive soft limit `3 GB`
  - archive hard limit `4 GB`
  - hot-index rebuild target `1_000_000` events
  - free-disk floor `1 GB`

## Crawl Corpus Definition

### Tier A: Deep Crawl And Long Retention

These kinds should be actively backfilled through the 2-hop graph and preserved aggressively in both archive and hot-index rebuild seeds:

- `0` profile metadata
- `3` follow lists
- `10002` relay lists
- `1` short notes
- `6` reposts
- `16` generic repost / quote-style reposts already treated as repost content by the app
- `1111` comments
- `1244` voice comments
- `30023` long-form articles
- referenced event IDs discovered from `e` and `a` tags on Tier A content

### Tier B: Medium-Depth Crawl

These kinds should be crawled after Tier A has work in flight, with smaller per-pass budgets:

- `20` picture posts
- `21` video posts
- `22` short videos
- `1222` voice posts
- `1068` polls
- `9802` highlights
- `31987` relay reviews
- `36787` music tracks

### Tier C: Shallow Or On-Demand

These kinds should not be historically deep-crawled in the first rollout:

- `7` reactions
- note-activity-only kinds that are currently fetched specifically for detail views
- any other high-volume activity kinds not required to render feed rows or profile timelines

## Non-Goals

- Do not crawl the full global network indiscriminately.
- Do not deep-backfill reaction history for every crawled note in v1.
- Do not download media binaries as part of this crawler; only ingest event metadata and note records.
- Do not replace relays as the network source of truth for unseen content; this work only improves the local source of truth.

## File Map

### App lifecycle, connectivity, and settings

- Create: `Sources/App/FlowNetworkPathMonitor.swift`
  Extract the shared Wi-Fi monitor from `FlowMediaCache.swift` so the crawler and media systems can reuse it without cross-file coupling.
- Modify: `Sources/App/FlowMediaCache.swift`
  Remove the embedded `FlowNetworkPathMonitor` type and keep using the extracted shared monitor.
- Modify: `Sources/App/AppSettingsStore.swift`
  Add crawl settings and persistence:
  - `localCorpusCrawlEnabled`
  - `localCorpusCrawlWiFiOnly`
  - `localCorpusBackgroundRefreshEnabled`
  - `localCorpusCrawlHopCount`
  - `localCorpusDeepMediaBackfillEnabled`
- Modify: `Sources/App/FlowApp.swift`
  Start, stop, and refresh the crawler with login and scene lifecycle changes.
- Modify: `Sources/Resources/Info.plist`
  Register any required BackgroundTasks identifiers.

### Crawl planning and execution

- Create: `Sources/Feed/LocalCorpusCrawlPolicy.swift`
  Define content tiers, hop limits, per-pass budgets, and refresh intervals.
- Create: `Sources/Feed/CrawlRelayPlanner.swift`
  Build relay target sets from relay hints, follow-list hints, read relays, and broad fallback relays.
- Create: `Sources/Feed/CrawlCursorStore.swift`
  Persist per-scope historical crawl cursors and last-refresh timestamps.
- Create: `Sources/Feed/LocalCorpusCrawler.swift`
  Main foreground and background crawl coordinator.
- Modify: `Sources/Home/HomeFeedTrustGraph.swift`
  Expose reusable trusted-pubkey expansion logic without forcing UI-only ownership.
- Modify: `Sources/Feed/NostrFeedService.swift`
  Add historical author-window fetch helpers, replaceable refresh helpers, and reference-resolution batch fetchers.
- Modify: `Sources/Profile/ProfileEventService.swift`
  Reuse follow-list and relay-list fetching in crawl flows.
- Modify: `Sources/Feed/FeedCaches.swift`
  Extend relay hint persistence and ranking inputs for crawl planning.

### Storage, retention, and diagnostics

- Modify: `Sources/Feed/EventArchiveStore.swift`
  Add archive diagnostics, pinning helpers, and retention-class-aware pruning.
- Modify: `Sources/Feed/SeenEventStore.swift`
  Seed Flow DB rebuilds from pinned replaceables, referenced events, and recent corpus slices instead of plain recency only.
- Modify: `Sources/NostrDB/FlowNostrDB.swift`
  Expand diagnostics to distinguish note, profile, and replaceable persistence health that matters to the crawler.
- Modify: `Sources/Home/SettingsMediaView.swift`
  Show archive counts and crawl health separately from hot-index counts.
- Modify: `Sources/Home/SettingsGeneralView.swift`
  Add user-facing crawl controls.

### Tests

- Create: `Tests/FlowNetworkPathMonitorTests.swift`
- Create: `Tests/LocalCorpusCrawlPolicyTests.swift`
- Create: `Tests/CrawlRelayPlannerTests.swift`
- Create: `Tests/CrawlCursorStoreTests.swift`
- Create: `Tests/LocalCorpusCrawlerTests.swift`
- Modify: `Tests/EventArchiveStoreTests.swift`
- Modify: `Tests/FlowNostrDBTests.swift`
- Modify: `Tests/NostrFeedServiceTests.swift`

---

### Task 1: Extract Shared Connectivity Monitoring And Add Crawl Settings

**Files:**
- Create: `Sources/App/FlowNetworkPathMonitor.swift`
- Modify: `Sources/App/FlowMediaCache.swift`
- Modify: `Sources/App/AppSettingsStore.swift`
- Modify: `Sources/Home/SettingsGeneralView.swift`
- Test: `Tests/FlowNetworkPathMonitorTests.swift`

- [ ] **Step 1: Add the failing tests for the extracted Wi-Fi monitor seam**

Add `Tests/FlowNetworkPathMonitorTests.swift` with tests that verify a fake path update flips the exposed `isCurrentlyUsingWiFi` value and publishes the same value on the main actor.

- [ ] **Step 2: Run the focused monitor tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/FlowNetworkPathMonitorTests
```

Expected: FAIL because the monitor is still embedded inside `FlowMediaCache.swift` and has no dedicated test seam.

- [ ] **Step 3: Extract `FlowNetworkPathMonitor` into its own file**

Move the existing `FlowNetworkPathMonitor` type out of `Sources/App/FlowMediaCache.swift` into `Sources/App/FlowNetworkPathMonitor.swift` without changing behavior. Keep `FlowMediaCache` using `FlowNetworkPathMonitor.shared`.

- [ ] **Step 4: Add persisted crawl settings to `AppSettingsStore`**

Add new persisted settings keys and public accessors:

```swift
var localCorpusCrawlEnabled: Bool = true
var localCorpusCrawlWiFiOnly: Bool = true
var localCorpusBackgroundRefreshEnabled: Bool = true
var localCorpusCrawlHopCount: Int = 2
var localCorpusDeepMediaBackfillEnabled: Bool = false
```

Clamp `localCorpusCrawlHopCount` to `1...2` for v1.

- [ ] **Step 5: Add a settings UI section**

Add a new "Local Corpus Crawl" section in `Sources/Home/SettingsGeneralView.swift` with:
- enable toggle
- Wi-Fi only toggle
- background refresh toggle
- hop-count picker with `1 Hop` and `2 Hops`
- deep-media-backfill toggle

- [ ] **Step 6: Re-run the focused tests**

Run the same test command from Step 2.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/App/FlowNetworkPathMonitor.swift Sources/App/FlowMediaCache.swift Sources/App/AppSettingsStore.swift Sources/Home/SettingsGeneralView.swift Tests/FlowNetworkPathMonitorTests.swift
git commit -m "feat: add shared connectivity monitor and crawl settings"
```

### Task 2: Define Crawl Policy, Content Tiers, And Per-Pass Budgets

**Files:**
- Create: `Sources/Feed/LocalCorpusCrawlPolicy.swift`
- Test: `Tests/LocalCorpusCrawlPolicyTests.swift`

- [ ] **Step 1: Write failing tests for crawl tiers and budgets**

Add tests that assert:
- Tier A includes `0`, `3`, `10002`, `1`, `6`, `16`, `1111`, `1244`, and `30023`
- Tier B includes `20`, `21`, `22`, `1222`, `1068`, `9802`, `31987`, and `36787`
- Tier C includes `7`
- default policy uses `2` hops, foreground Wi-Fi crawl, and smaller media budgets than Tier A

- [ ] **Step 2: Run the focused policy tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/LocalCorpusCrawlPolicyTests
```

Expected: FAIL because no crawl-policy type exists yet.

- [ ] **Step 3: Create `LocalCorpusCrawlPolicy.swift`**

Define:
- `LocalCorpusCrawlTier`
- `LocalCorpusCrawlPolicy`
- exact kind lists per tier
- per-pass limits:
  - Tier A author page limit
  - Tier B author page limit
  - reference-resolution batch size
  - background-refresh batch size
  - relay timeout defaults

Use values that bias heavily toward text/article/replaceable coverage before media.

- [ ] **Step 4: Re-run the focused policy tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Feed/LocalCorpusCrawlPolicy.swift Tests/LocalCorpusCrawlPolicyTests.swift
git commit -m "feat: define local corpus crawl policy"
```

### Task 3: Add Trust-Graph Expansion And Relay Planning For 2-Hop Crawl Targets

**Files:**
- Create: `Sources/Feed/CrawlRelayPlanner.swift`
- Modify: `Sources/Home/HomeFeedTrustGraph.swift`
- Modify: `Sources/Profile/ProfileEventService.swift`
- Modify: `Sources/Feed/FeedCaches.swift`
- Test: `Tests/CrawlRelayPlannerTests.swift`

- [ ] **Step 1: Write failing tests for target expansion and relay ranking**

Add tests that verify:
- direct follows are always included
- `2` hops expands through cached follow snapshots before network fetches
- relay-planning prefers cached author hints and follow-list hints
- planner still appends broad fallback relays when hints are sparse

- [ ] **Step 2: Run the focused planner tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/CrawlRelayPlannerTests
```

Expected: FAIL because crawl relay planning is not implemented.

- [ ] **Step 3: Extract reusable trust-graph expansion helpers**

Refactor `Sources/Home/HomeFeedTrustGraph.swift` so the follow-expansion logic can be called from non-UI code without depending on `@Published` state. Keep the existing `WebOfTrustStore` behavior intact.

- [ ] **Step 4: Implement `CrawlRelayPlanner.swift`**

Planner inputs must include:
- account pubkey
- crawl hop count
- read relays
- cached follow-list snapshots
- cached relay hints
- fallback broad relays

Planner output must include:
- ordered author targets
- relay URLs per author
- a deduplicated broad fallback list

- [ ] **Step 5: Re-run the focused planner tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Feed/CrawlRelayPlanner.swift Sources/Home/HomeFeedTrustGraph.swift Sources/Profile/ProfileEventService.swift Sources/Feed/FeedCaches.swift Tests/CrawlRelayPlannerTests.swift
git commit -m "feat: add two-hop crawl target and relay planning"
```

### Task 4: Persist Historical Cursors And Crawl Progress

**Files:**
- Create: `Sources/Feed/CrawlCursorStore.swift`
- Test: `Tests/CrawlCursorStoreTests.swift`

- [ ] **Step 1: Write failing tests for cursor persistence**

Add tests that verify the store can round-trip:
- per-author Tier A `until` cursor
- per-author Tier B `until` cursor
- last successful replaceable refresh timestamp
- queued missing-reference IDs

- [ ] **Step 2: Run the focused cursor tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/CrawlCursorStoreTests
```

Expected: FAIL because no cursor store exists yet.

- [ ] **Step 3: Implement `CrawlCursorStore.swift`**

Store a compact JSON or SQLite-backed state that can answer:
- where each author's historical crawl stopped
- when each scope was last refreshed
- which referenced events are still missing locally

Keep storage actor-isolated and deterministic in tests.

- [ ] **Step 4: Re-run the focused cursor tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Feed/CrawlCursorStore.swift Tests/CrawlCursorStoreTests.swift
git commit -m "feat: persist local corpus crawl progress"
```

### Task 5: Build The Foreground Wi-Fi Crawler

**Files:**
- Create: `Sources/Feed/LocalCorpusCrawler.swift`
- Modify: `Sources/App/FlowApp.swift`
- Modify: `Sources/Feed/NostrFeedService.swift`
- Modify: `Sources/Feed/SeenEventStore.swift`
- Test: `Tests/LocalCorpusCrawlerTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Write failing crawler tests**

Add tests that verify:
- crawler starts only when logged in, enabled, foregrounded, and allowed by Wi-Fi policy
- Tier A scopes run before Tier B scopes
- fetched batches are stored through `SeenEventStore`
- missing referenced events are queued and resolved by ID

- [ ] **Step 2: Run the focused crawler tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/LocalCorpusCrawlerTests \
  -only-testing:FlowTests/NostrFeedServiceTests
```

Expected: FAIL because no crawler exists and the service has no historical-crawl helpers.

- [ ] **Step 3: Add historical fetch helpers to `NostrFeedService.swift`**

Add explicit methods for:
- refreshing latest replaceables for many authors
- fetching older author windows by `until`
- fetching reference targets by IDs and relay hints

Each helper must store non-empty results through `seenEventStore`.

- [ ] **Step 4: Implement `LocalCorpusCrawler.swift`**

The foreground pass should:
- build `2`-hop author targets from the planner
- refresh latest `0`, `3`, and `10002` replaceables first
- backfill Tier A note/article/reply/repost windows by author cursor
- enqueue and resolve missing references
- spend remaining budget on Tier B kinds if enabled

The crawler should loop with sleeps between passes, not spin continuously.

- [ ] **Step 5: Wire the crawler into `FlowApp.swift`**

Start or stop the crawler when:
- login state changes
- `scenePhase` changes
- crawl settings change
- slow-connection mode changes

Use `.active` scene phase only for the first rollout.

- [ ] **Step 6: Re-run the focused crawler tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Feed/LocalCorpusCrawler.swift Sources/App/FlowApp.swift Sources/Feed/NostrFeedService.swift Sources/Feed/SeenEventStore.swift Tests/LocalCorpusCrawlerTests.swift Tests/NostrFeedServiceTests.swift
git commit -m "feat: add foreground local corpus crawler"
```

### Task 6: Add Opportunistic Background Refresh

**Files:**
- Modify: `Sources/App/FlowApp.swift`
- Modify: `Sources/Resources/Info.plist`
- Modify: `Sources/Feed/LocalCorpusCrawler.swift`
- Test: `Tests/LocalCorpusCrawlerTests.swift`

- [ ] **Step 1: Write failing tests for short background passes**

Add tests that verify background refresh:
- runs a short replaceable + latest-note pass only
- respects task cancellation / expiration
- does not schedule deep historical Tier B work

- [ ] **Step 2: Run the focused background tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/LocalCorpusCrawlerTests
```

Expected: FAIL because background refresh support does not exist yet.

- [ ] **Step 3: Add background-refresh integration**

Register a BackgroundTasks identifier and implement a short refresh entry point that:
- uses the same target planner
- refreshes latest `0`, `3`, `10002`
- refreshes newest Tier A windows for the hottest authors
- resolves a bounded number of queued missing references

- [ ] **Step 4: Re-run the focused background tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/FlowApp.swift Sources/Resources/Info.plist Sources/Feed/LocalCorpusCrawler.swift Tests/LocalCorpusCrawlerTests.swift
git commit -m "feat: add opportunistic local corpus background refresh"
```

### Task 7: Strengthen Retention And Rebuild Seeding For Metadata, Follow Lists, And References

**Files:**
- Modify: `Sources/Feed/EventArchiveStore.swift`
- Modify: `Sources/Feed/SeenEventStore.swift`
- Modify: `Sources/NostrDB/FlowNostrDB.swift`
- Test: `Tests/EventArchiveStoreTests.swift`
- Test: `Tests/FlowNostrDBTests.swift`

- [ ] **Step 1: Write failing tests for retention priorities**

Add tests that verify:
- latest kind `0` per crawled pubkey survives prune pressure
- latest kind `3` and `10002` per crawled pubkey survive prune pressure
- referenced events survive long enough to satisfy local ID lookups
- Flow DB rebuild seeds pinned replaceables and references before plain recency

- [ ] **Step 2: Run the focused retention tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/EventArchiveStoreTests \
  -only-testing:FlowTests/FlowNostrDBTests
```

Expected: FAIL because retention is still mostly recency-based.

- [ ] **Step 3: Add retention-class-aware archive support**

Teach `EventArchiveStore` to distinguish:
- replaceable essentials
- reference essentials
- recent feed pins
- ordinary crawled events

Pruning must preserve higher-value classes first.

- [ ] **Step 4: Upgrade `SeenEventStore` rebuild seeding**

Rebuild seed order should be:
1. pinned recent-feed IDs
2. latest `0`, `3`, `10002` replaceables for crawled pubkeys
3. queued or recently used referenced events
4. newest ordinary events until the hot-index target is filled

- [ ] **Step 5: Re-run the focused retention tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Feed/EventArchiveStore.swift Sources/Feed/SeenEventStore.swift Sources/NostrDB/FlowNostrDB.swift Tests/EventArchiveStoreTests.swift Tests/FlowNostrDBTests.swift
git commit -m "feat: retain replaceables and references aggressively"
```

### Task 8: Surface Honest Diagnostics And Verification Hooks

**Files:**
- Modify: `Sources/Home/SettingsMediaView.swift`
- Modify: `Sources/Feed/LocalCorpusCrawler.swift`
- Modify: `Sources/Feed/EventArchiveStore.swift`
- Modify: `Sources/NostrDB/FlowNostrDB.swift`
- Test: `Tests/LocalCorpusCrawlerTests.swift`

- [ ] **Step 1: Add failing tests for diagnostics snapshots**

Add tests that verify diagnostics can report:
- archive event count
- archive byte size
- hot-index event count
- hot-index profile count
- last crawl pass time
- last crawl batch counts by tier
- queued missing-reference count

- [ ] **Step 2: Run the focused diagnostics tests**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/LocalCorpusCrawlerTests \
  -only-testing:FlowTests/EventArchiveStoreTests \
  -only-testing:FlowTests/FlowNostrDBTests
```

Expected: FAIL because the settings screen still only exposes hot-index-style persisted counts.

- [ ] **Step 3: Rename and expand diagnostics in `SettingsMediaView.swift`**

Replace misleading labels:
- `Persisted Events` -> `Hot Index Events`
- `Persisted Profiles` -> `Hot Index Profiles`

Add new rows:
- `Archive Events`
- `Archive Size`
- `Pinned Feed IDs`
- `Pinned Replaceables`
- `Queued Missing References`
- `Last Crawl Pass`
- `Last Tier A Batch`
- `Last Tier B Batch`

- [ ] **Step 4: Re-run the focused diagnostics tests**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Home/SettingsMediaView.swift Sources/Feed/LocalCorpusCrawler.swift Sources/Feed/EventArchiveStore.swift Sources/NostrDB/FlowNostrDB.swift Tests/LocalCorpusCrawlerTests.swift Tests/EventArchiveStoreTests.swift Tests/FlowNostrDBTests.swift
git commit -m "feat: expose archive and crawler diagnostics"
```

### Task 9: End-To-End Verification

**Files:**
- Modify: none
- Test: `Tests/FlowNetworkPathMonitorTests.swift`
- Test: `Tests/LocalCorpusCrawlPolicyTests.swift`
- Test: `Tests/CrawlRelayPlannerTests.swift`
- Test: `Tests/CrawlCursorStoreTests.swift`
- Test: `Tests/LocalCorpusCrawlerTests.swift`
- Test: `Tests/EventArchiveStoreTests.swift`
- Test: `Tests/FlowNostrDBTests.swift`
- Test: `Tests/NostrFeedServiceTests.swift`

- [ ] **Step 1: Run the full focused crawl/storage suite**

Run:

```bash
xcodebuild test \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FlowTests/FlowNetworkPathMonitorTests \
  -only-testing:FlowTests/LocalCorpusCrawlPolicyTests \
  -only-testing:FlowTests/CrawlRelayPlannerTests \
  -only-testing:FlowTests/CrawlCursorStoreTests \
  -only-testing:FlowTests/LocalCorpusCrawlerTests \
  -only-testing:FlowTests/EventArchiveStoreTests \
  -only-testing:FlowTests/FlowNostrDBTests \
  -only-testing:FlowTests/NostrFeedServiceTests
```

Expected: PASS.

- [ ] **Step 2: Run a simulator smoke pass**

Run:

```bash
xcodebuild build \
  -project /Users/k/code/x21-ios/Flow.xcodeproj \
  -scheme Flow \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Then launch the app and verify:
- the crawler shows as active on Wi-Fi
- archive counts rise over time
- hot-index counts rise over time
- a previously slow profile shows local notes sooner on a second visit
- an article profile resolves article rows locally
- a referenced note opens without waiting for relay fetch if already crawled

- [ ] **Step 3: Commit the verification note if any small docs changes were needed**

```bash
git status --short
```

Expected: no unexpected source changes after verification.

## Self-Review

- Spec coverage: this plan covers the discussed 2-hop web-of-trust crawl, long-form article backfill, tiered feed-kind support, foreground Wi-Fi crawling, opportunistic background refresh, stronger replaceable/reference retention, and clearer archive-vs-hot diagnostics.
- Placeholder scan: no `TODO` or `TBD` markers remain.
- Type consistency: all new plan types use the same names across tasks:
  - `FlowNetworkPathMonitor`
  - `LocalCorpusCrawlPolicy`
  - `CrawlRelayPlanner`
  - `CrawlCursorStore`
  - `LocalCorpusCrawler`

