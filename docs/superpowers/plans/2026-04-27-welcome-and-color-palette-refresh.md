# Welcome And Color Palette Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace expressive gradients with fixed accent colors, rename and remap app palettes, refresh onboarding with rotating welcome art, and add a short relaunch loading splash.

**Architecture:** Keep the persisted theme model backward-compatible by preserving legacy enum cases while changing user-facing titles, enabled option lists, and normalization behavior. Centralize the new fixed accent palette and first-run theme default logic in `AppSettingsStore`, then wire onboarding, welcome, settings, and launch overlays to the same source of truth so selection changes propagate immediately.

**Tech Stack:** SwiftUI, UIKit bridges for image loading, XCTest, app-local bundled resources.

---

### Task 1: Lock Theme Naming And Migration Behavior

**Files:**
- Modify: `Sources/App/AppSettingsStore.swift`
- Modify: `Tests/AppThemeOptionTests.swift`

- [ ] Add failing tests for palette titles, visible onboarding/settings palette lists, legacy normalization, and time-of-day first-run theme defaults.
- [ ] Run: `xcodebuild test -scheme Flow -only-testing:FlowTests/AppThemeOptionTests`
- [ ] Update `AppThemeOption` and `AppSettingsStore` minimally so:
  - `black` is user-facing `Dark`
  - existing `dark` is user-facing `Charcoal`
  - `holographicLight` is user-facing `Light`
  - `light`/`white` are user-facing `Clean`
  - onboarding-visible themes are `Light`, `Dark`, `System`, `Midnight`, `Neon`, `Charcoal`
  - settings-visible themes add `Clean`
  - first-run defaults choose `Light` by day and `Dark` by night
- [ ] Re-run: `xcodebuild test -scheme Flow -only-testing:FlowTests/AppThemeOptionTests`

### Task 2: Remove Expressive Accent Paths And Install Fixed Accent Colors

**Files:**
- Modify: `Sources/App/AppSettingsStore.swift`
- Modify: `Sources/Home/SettingsAppearanceView.swift`
- Modify: `Tests/AppThemeOptionTests.swift`

- [ ] Add failing tests that assert prominent buttons no longer depend on expressive gradients and that fixed accent colors survive store reload.
- [ ] Run: `xcodebuild test -scheme Flow -only-testing:FlowTests/AppThemeOptionTests`
- [ ] Replace freeform/expressive accent behavior with a fixed accent color list containing `#FF0000`, `#0059FF`, `#FF5900`, `#91C500`, `#00D4FF`, `#D000FF`, `#9000FF`.
- [ ] Simplify appearance settings so users choose a fixed primary color and remove the expressive/gradient UI.
- [ ] Re-run: `xcodebuild test -scheme Flow -only-testing:FlowTests/AppThemeOptionTests`

### Task 3: Refresh Welcome And Onboarding Selection UI

**Files:**
- Modify: `Sources/Onboarding/WelcomeOnboardingView.swift`
- Modify: `Sources/Onboarding/SignupOnboardingView.swift`
- Create: `Sources/Onboarding/WelcomeArtwork.swift`

- [ ] Copy the three supplied welcome images into app resources and add a small helper for randomized artwork/color selection.
- [ ] Replace the Unicorn Studio welcome animation with one randomized welcome image shown on first visit.
- [ ] Make the welcome CTA use a randomized allowed primary color.
- [ ] Replace onboarding gradient randomizers with fixed primary color chips and an onboarding palette selector.
- [ ] Ensure onboarding button colors update immediately when the user changes primary color and that onboarding completion stores both accent color and chosen theme.

### Task 4: Add Relaunch Loading Splash

**Files:**
- Modify: `Sources/App/FlowApp.swift`
- Create: `Sources/App/AppLaunchSplashOverlay.swift`

- [ ] Introduce a short loading overlay for logged-in launches that reuses the randomized welcome art as a background-only splash.
- [ ] Keep the overlay lightweight and time-bounded so it can mask initial feed warmup without blocking indefinitely.
- [ ] Make sure the splash does not appear over the first-time logged-out welcome flow.

### Task 5: Verify End-To-End

**Files:**
- Verify only

- [ ] Run targeted tests for updated theme/onboarding behavior.
- [ ] Run an app build to catch SwiftUI/compiler issues.
- [ ] Review touched files for unintended changes around existing in-progress user edits before reporting completion.
