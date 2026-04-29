# Instant Optimistic Note And Reply Publication Design

## Goal

Make note posts and replies appear immediately, stay visible consistently, and transition smoothly through publish states without disappearing during refreshes. Users should never lose sight of something they just posted. If publishing to connected sources fails everywhere, the item should remain visible and clearly marked as failed.

## Current Context

The app already creates optimistic `FeedItem` values with real signed event IDs in `ComposeNotePublishService` and `ThreadReplyPublishService`. `ComposeNoteSheet` inserts those items immediately through `onOptimisticPublished`, then starts the real publish request.

The inconsistency comes from later refresh behavior:

- `ThreadDetailViewModel.appendLocalReply(_:)` appends a local reply, but `scheduleReplyRefresh()` later replaces `rawReplies` with fetched replies from connected sources. If the new reply has not been echoed back yet, it disappears.
- `HomeFeedViewModel.insertOptimisticPublishedItem(_:)`, `ProfileViewModel.insertOptimisticPublishedItem(_:)`, and similar optimistic insertions work initially, but successful publish completion triggers screen refreshes that rebuild visible items from fetched results. That can temporarily drop the local post until connected sources catch up.
- Current publish toasts also communicate lifecycle as separate “publishing” then “posted” events, which visually highlights the moment the disappearance can happen.

The result is an unreliable front-end experience even though local event creation is already fast and valid.

## Product Behavior

### Immediate Visibility

- The moment the user taps post, the note or reply appears in the visible list.
- The item must stay visible through refreshes, hydration upgrades, feed-source updates, and publish completion.
- The item must use the same event ID before and after publishing so later server-backed versions can merge into it rather than replace it visually.

### Publication States

Each locally created post or reply has a front-end publication state:

- `publishing`: just inserted, waiting for at least one connected source to accept it
- `posted`: accepted by at least one connected source
- `failed`: every connected source failed

These states are presentation-only and should not fork the actual event model.

### Failure UX

- Failed posts and replies stay visible.
- A small trailing failure icon appears on the item.
- Tapping the icon opens a lightweight detail surface explaining that the post could not be published to connected sources right now.
- When available, include the most useful failure detail from the underlying transport error.
- User-facing copy should avoid the word “relay” and use “connection” or “connected sources”.

### Animation

- New optimistic notes and replies should animate in with a subtle upward fade/settle motion.
- The animation should feel native and calm rather than flashy.
- State changes from `publishing` to `posted` or `failed` should animate gently, for example by fading status adornments rather than reloading the whole row.
- Respect Reduce Motion by disabling positional animation and keeping only minimal opacity updates when required.

## Architecture

Add a shared local publication layer that owns optimistic publication state independently from any one screen.

Recommended shape:

- `LocalPublicationStore`: `ObservableObject` or `@MainActor` shared store keyed by normalized event ID
- `LocalPublicationRecord`: event ID, `FeedItem`, state (`publishing` / `posted` / `failed`), failure message, created-at timestamp, and optional scope metadata such as reply target/root conversation ID

This store is the single source of truth for front-end optimistic publication state. Screen-specific view models should no longer treat optimistic items as throwaway inserts.

## Integration Plan

### Compose Pipeline

- `ComposeNoteSheet` should still prepare the publication and insert immediately.
- After optimistic insertion, it should register the item in `LocalPublicationStore` as `publishing`.
- Publish completion should update the same store record to `posted` or `failed` instead of relying on a refresh to represent success.

### Feed And Profile Screens

- `HomeFeedViewModel`, `ProfileViewModel`, and hashtag feed view models should merge fetched items with locally published items from `LocalPublicationStore`.
- Refresh paths must preserve local publication records that are still `publishing` or `failed`, even if fetched results do not contain them yet.
- When a fetched item matches a local publication record by event ID, the fetched item should hydrate/upgrade the existing local one in place.

### Thread Detail Replies

- `ThreadDetailViewModel` should merge fetched replies with local publication records scoped to the current conversation instead of replacing `rawReplies` outright.
- `scheduleReplyRefresh()` must preserve local optimistic replies that are still absent from connected source results.
- Reply scrolling should continue to target the same stable event ID, so no special-case ID translation is needed.

## Refresh Rules

- Refreshes may upgrade optimistic items, but they may not delete them unless the user explicitly removes a failed draft-like item in a future feature.
- `posted` items can eventually age out of the local publication layer after the fetched copy has definitively appeared and merged.
- `failed` items should remain until the screen session ends or until a future retry/remove action exists.

## UI Surface Changes

- Add a small publication-status adornment to feed rows and thread replies.
- `publishing` can use a subtle spinner or progress glyph.
- `failed` uses a tappable warning/error icon.
- Avoid large banners or disruptive row chrome.
- Success should usually be quiet; the steady visible item is the confirmation.

## Testing

Add tests for:

- optimistic replies survive thread refreshes when connected sources have not echoed them yet
- optimistic notes survive home/profile/hashtag refreshes after publish completion
- fetched copies merge into local optimistic items by event ID instead of creating duplicates
- failed publications remain visible and are marked failed
- user-facing failure copy uses “connection” / “connected sources” instead of “relay”
- animation/state transitions respect Reduce Motion guards where applicable

## Non-Goals

- No retry workflow in this change beyond exposing failure details
- No draft recovery redesign
- No transport-layer publishing changes beyond surfacing clearer failure outcomes
- No major visual redesign of feed rows beyond subtle insertion/state indicators
