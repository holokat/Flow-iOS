# Flow iOS Ship Checklist

Use this checklist for every feature, fix, or UX change before shipping.

## 1. First-Paint and Performance

- Does the change add any new `await`, relay fetch, cache miss, image load, or profile hydration before the first visible UI paint?
- If yes, can that work move to background hydration after the initial rows or screen render?
- For feeds, activity, threads, and media viewers: verify the first screenful appears before secondary enrichment finishes.

## 2. Navigation and Presentation

- Verify every new sheet, full-screen cover, dropdown, and composer stays open until the user dismisses it.
- Check that leaving and returning to a tab resets to the correct root state when expected.
- Confirm deep links, mention taps, hashtag taps, and media actions still route to the correct in-app destination.

## 3. Interaction and Hit Testing

- Test all overlay controls on real device or simulator:
  - video mute/unmute
  - media actions
  - reply / repost / like / share
  - bottom drawers and floating controls
- Check for invisible overlays, clipped buttons, gesture conflicts, and controls that sit too close to native player chrome.

## 4. Live and Incremental Updates

- For any live subscription change, verify:
  - first load still renders quickly
  - live events still arrive after first paint
  - reconnect or fallback logic still works
- If a feature depends on live data, confirm the UI still behaves sensibly when no live events arrive.

## 5. Theme and Layout

- Check dark mode and light mode.
- Check iPhone portrait and any rotation-dependent flows.
- Verify visual contrast for buttons, labels, frosted panels, overlays, and selected states.

## 6. Shared State and Persistence

- If a setting is changed in one surface, confirm every connected surface updates too.
- If behavior should persist across screens or relaunches, verify it actually persists.
- If behavior should be local-only, verify it does not leak into unrelated screens.

## 7. Regression Tests

- Add or update at least one focused regression test for the code path that was changed if the change touches:
  - feed/activity loading
  - media playback or upload
  - composer/reply flows
  - navigation/presentation
  - live subscriptions
- Prefer tests that prove the critical path stays off the network when caches are hot.

## 8. Manual QA

- Run the project build:

```bash
xcodebuild -scheme Flow -project /Users/k/code/x21-ios/Flow.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

- Before installing any physical-device build, verify that both Halo and its Share Extension were signed and provisioned for the shared App Group:

```bash
./Scripts/verify-app-group-signing.sh /path/to/Flow.app
```

- Never work around a provisioning failure by clearing `CODE_SIGN_ENTITLEMENTS`; doing so breaks sharing from other apps.

- Test the exact user flow that motivated the change.
- Test one adjacent flow that could have regressed because of shared code.
- If the change affects Activity, feeds, media, or composer, test it from at least two entry points.

## 9. Ship Notes

- Write down:
  - what changed
  - what was verified
  - any known risk that still remains

If a checklist item is skipped, call it out explicitly before shipping.
