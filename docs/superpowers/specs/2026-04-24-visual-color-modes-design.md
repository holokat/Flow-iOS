# Visual Color Modes Design

## Goal

Reorganize appearance customization so surface palettes and accent styling are separate concepts. Users choose one color palette for the app chrome, then choose exactly one accent mode: Expressive or Minimal.

## Current Context

The app currently uses `AppThemeOption` for both surface palette identity and legacy theme identity. `SettingsAppearanceView` shows a primary color picker, theme cards, and a separate Button Style navigation row. `SettingsButtonGradientView` allows solid color, generated gradients, text color, and several holographic gradient choices. `AppSettingsStore` persists `theme`, `primaryColor`, `buttonGradientOption`, `generatedButtonGradient`, and `buttonTextColor`.

This makes it possible to combine a free primary color with a gradient, and it presents Dracula, Gamer, Sky, and Sakura as themes even though the new model should treat most of them as surface palettes.

## Product Model

### Color Palettes

Color palettes define backgrounds, surfaces, text, borders, sheet colors, poll chrome, feed card chrome, and similar non-accent UI surfaces. They do not own a primary color.

Visible palette options:

- Light
- Dark
- Black
- System
- Midnight: renamed from Dracula
- Neon: renamed from Gamer
- Air: renamed from Sky / `holographicLight`

Sakura is removed from visible choices. Existing persisted Sakura selections migrate to Light.

Legacy disabled options remain decodable so old settings do not crash or reset unpredictably.

### Visual Accent Modes

Users choose exactly one visual accent mode.

Expressive:

- Uses one of four curated gradients.
- Gradients apply to prominent primary buttons and other existing gradient-aware primary surfaces.
- Link color is auto-extracted from the selected gradient.
- Users can refresh the extracted link color to another eligible color from the same gradient.
- No free color picker appears in Expressive mode.
- The old Button Style menu is removed; the four gradient choices appear directly in the Expressive section.

Minimal:

- Uses one user-selected primary color.
- That color applies to primary buttons, links, selected states, and other primary accent affordances.
- No gradient choices appear in Minimal mode.

Expressive and Minimal cannot be combined.

## Naming

Existing implementation names can be migrated incrementally, but user-facing strings should change immediately:

- Dracula becomes Midnight.
- Gamer becomes Neon.
- Sky becomes Air.
- Theme becomes Color Palette.
- Button Style becomes Visual Mode or Accent Style and is shown inline on Appearance.

## State Design

Add a persisted accent mode concept that is the single source of truth:

```swift
enum AppVisualAccentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case expressive
    case minimal
}

enum ExpressiveGradientOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case aurora
    case prism
    case ember
    case bloom
}
```

`AppSettingsStore` should expose:

- `visualAccentMode`
- `expressiveGradientOption`
- `expressiveLinkColorIndex`
- `minimalPrimaryColor`
- `primaryColor`
- `primaryGradient`
- `linkColor`
- `usesPrimaryGradientForProminentButtons`
- `refreshExpressiveLinkColor()`

Existing call sites can keep reading `primaryColor`, `primaryGradient`, and `usesPrimaryGradientForProminentButtons`. Their behavior changes based on `visualAccentMode`.

In Expressive mode:

- `usesPrimaryGradientForProminentButtons == true`
- `primaryGradient` comes from `expressiveGradientOption`
- `primaryColor` returns the extracted link/accent color for non-gradient controls
- `linkColor` returns the extracted link color

In Minimal mode:

- `usesPrimaryGradientForProminentButtons == false`
- `primaryColor == minimalPrimaryColor`
- `linkColor == minimalPrimaryColor`
- `primaryGradient` can return a two-stop gradient using `minimalPrimaryColor` only for fallback compatibility

## Migration

When decoding existing settings:

- Existing `buttonGradientOption` maps to Expressive.
- Existing `generatedButtonGradient` maps to the closest/default Expressive gradient, because generated/free gradients are removed.
- Existing no-gradient state maps to Minimal using the stored `primaryColor` or the default primary color.
- Existing `buttonTextColor` is ignored by new mode selection; button text should use derived readable foregrounds.
- Existing Sakura theme maps to Light palette.
- Existing Dracula, Gamer, and `holographicLight` keep their raw persisted values if practical, but their titles/subtitles change to Midnight, Neon, and Air.
- Existing `holographicDark` continues to normalize to Dark.

## Settings UI

`SettingsAppearanceView` should contain:

- Color Palette grid.
- Visual Mode segmented control with Expressive and Minimal.
- Expressive section, shown only in Expressive mode:
  - Four gradient cards.
  - Link color preview chip.
  - Refresh button for cycling/extracting another link color from the selected gradient.
- Minimal section, shown only in Minimal mode:
  - Primary color row using the native color picker.
  - Preview chip showing that buttons and links share the same color.
- Typography, Font Size, Feed Layout, and Note Preview remain in Appearance.

Remove the Customize section row for Button Style. Keep Typography as a direct row or section.

## Visual Rules

- Use segmented controls for the mutually exclusive mode choice.
- Use gradient swatches/cards for Expressive gradient choices.
- Use a color swatch and color picker for Minimal primary color.
- Avoid visible explanatory text about how the UI works beyond concise labels and summaries.
- Keep existing theme-aware surfaces and card radii.

## Testing

Update or add tests for:

- Palette list no longer includes Sakura.
- Dracula/Gamer/Sky user-facing titles are Midnight/Neon/Air.
- Sakura persisted values normalize to Light.
- Expressive mode uses gradients and an extracted link color.
- Refreshing Expressive link color changes/cycles within the selected gradient.
- Minimal mode disables primary gradients and uses the primary color for buttons and links.
- Legacy `buttonGradientOption` migrates to Expressive.
- Legacy solid primary color migrates to Minimal.

## Non-Goals

- No freeform gradient generator.
- No separate button text color picker.
- No mixing Minimal primary color with Expressive gradients.
- No reintroduction of Sakura as a visible palette.
