# Compose Button To Sheet Morph

## Goal

Make compose feel like one continuous object instead of a button that triggers an unrelated modal. The floating compose button should become the first visual state of the composer: the circular button expands from its bottom-trailing position, rounds into the sheet header/handle area, and then the composer content blooms in.

This is best used for the floating compose button path in `MainTabShellView`, where the app already has:

- `appSettings.floatingComposeButtonEnabled`
- `composeSheetCoordinator`
- `composeSheetDraftBinding`
- `handleComposeTap()`
- `ComposeNoteSheet`

## Interaction Shape

The tap sequence should feel like this:

1. User taps the floating compose button.
2. The plus button briefly compresses, then expands from its actual screen position.
3. A soft scrim fades in behind the motion.
4. The expanding shape becomes the top/header region of a rounded compose sheet.
5. The sheet content fades/slides in only after the shape has mostly landed.
6. On dismiss, the sheet can either dissolve normally or contract back toward the compose button when the button is still visible.

The key aesthetic move is continuity: the button is not "opening" a sheet, it is becoming the sheet.

## Motion Rules

- Keep the initial morph fast: about `0.22s` to `0.30s`.
- Keep the content bloom slightly delayed: about `0.08s` after the morph starts.
- Use a spring only for geometry, not opacity.
- Respect Reduce Motion by skipping the morph and presenting the sheet immediately.
- Do not animate every internal composer control. Only animate the container, scrim, header, and first content reveal.
- Keep the compose sheet's final resting layout identical to the current production layout.

## Best Implementation Strategy

SwiftUI `matchedGeometryEffect` does not reliably animate between a normal view and a system `.sheet`, because the sheet is hosted in a separate presentation hierarchy. For a true morph, use an app-level overlay presentation for the compose surface.

That means replacing the floating compose `.sheet(item:)` path with a custom overlay only for the new-note compose action. Existing reply, quote, and deep-link compose flows can keep using the current `.sheet(item:)` until they are migrated.

Practical rollout:

1. Keep `AppComposeSheetCoordinator` as the source of truth.
2. Capture the floating button's frame with a preference key.
3. When the button is tapped, set a local `ComposeMorphState`.
4. Render `MorphingComposeSheetOverlay` above `TabView`.
5. Put `ComposeNoteSheet` inside the morphing sheet container.
6. Dismiss by clearing the coordinator draft after the overlay finishes closing.

## Code Example

This is a complete implementation sketch designed to fit into `MainTabShellView`. Names match the current code where possible.

```swift
import SwiftUI

private struct ComposeButtonFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private enum ComposeMorphPhase: Equatable {
    case idle
    case expanding
    case expanded
    case closing
}

private struct ComposeMorphMetrics {
    static let buttonSize: CGFloat = 58
    static let sheetCornerRadius: CGFloat = 34
    static let headerHeight: CGFloat = 76
    static let horizontalMargin: CGFloat = 8
    static let bottomMargin: CGFloat = 0

    static let expandAnimation = Animation.interactiveSpring(
        response: 0.28,
        dampingFraction: 0.88,
        blendDuration: 0.04
    )

    static let contentAnimation = Animation.easeOut(duration: 0.18)
    static let closeAnimation = Animation.easeInOut(duration: 0.18)
}
```

### MainTabShellView Changes

Add local state and capture the floating button frame.

```swift
struct MainTabShellView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var composeSheetCoordinator: AppComposeSheetCoordinator

    @State private var composeButtonFrame: CGRect?
    @State private var composeMorphPhase: ComposeMorphPhase = .idle

    // Existing state and body...
}
```

Update the floating button overlay so the button reports its frame in global coordinates.

```swift
private var composeFloatingButton: some View {
    Button {
        handleComposeTap()
    } label: {
        Image(systemName: "plus")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(appSettings.buttonTextColor)
            .frame(width: 58, height: 58)
            .background(appSettings.primaryGradient, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ComposeButtonFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Compose note")
}
```

Listen for the frame and render the morph overlay above the app content.

```swift
var body: some View {
    TabView(selection: $selectedTab) {
        // Existing tabs...
    }
    .onPreferenceChange(ComposeButtonFramePreferenceKey.self) { frame in
        composeButtonFrame = frame
    }
    .overlay {
        if let draft = composeSheetCoordinator.draft,
           composeMorphPhase != .idle,
           let buttonFrame = composeButtonFrame {
            MorphingComposeSheetOverlay(
                phase: $composeMorphPhase,
                sourceFrame: buttonFrame,
                reduceMotion: reduceMotion,
                onDismiss: dismissMorphingCompose
            ) {
                ComposeNoteSheet(
                    currentAccountPubkey: auth.currentAccount?.pubkey,
                    currentNsec: auth.currentNsec,
                    writeRelayURLs: effectiveWriteRelayURLs,
                    initialText: draft.initialText,
                    initialAdditionalTags: draft.initialAdditionalTags,
                    initialUploadedAttachments: draft.initialUploadedAttachments,
                    initialSharedAttachments: draft.initialSharedAttachments,
                    initialSelectedMentions: draft.initialSelectedMentions,
                    initialPollDraft: draft.initialPollDraft,
                    replyTargetEvent: draft.replyTargetEvent,
                    replyTargetDisplayNameHint: draft.replyTargetDisplayNameHint,
                    replyTargetHandleHint: draft.replyTargetHandleHint,
                    replyTargetAvatarURLHint: draft.replyTargetAvatarURLHint,
                    quotedEvent: draft.quotedEvent,
                    quotedDisplayNameHint: draft.quotedDisplayNameHint,
                    quotedHandleHint: draft.quotedHandleHint,
                    quotedAvatarURLHint: draft.quotedAvatarURLHint,
                    savedDraftID: draft.savedDraftID,
                    onOptimisticPublished: handleOptimisticPublished
                )
            }
            .zIndex(100)
        }
    }
}
```

Change compose tap to start the morph when possible.

```swift
private func handleComposeTap() {
    guard auth.currentAccount != nil else {
        authSheetInitialTab = .signIn
        isShowingAuthSheet = true
        return
    }

    composeSheetCoordinator.presentNewNote()

    guard appSettings.floatingComposeButtonEnabled,
          composeButtonFrame != nil,
          !reduceMotion else {
        composeMorphPhase = .expanded
        return
    }

    composeMorphPhase = .expanding
}

private func dismissMorphingCompose() {
    guard !reduceMotion else {
        composeSheetCoordinator.dismiss()
        composeMorphPhase = .idle
        return
    }

    withAnimation(ComposeMorphMetrics.closeAnimation) {
        composeMorphPhase = .closing
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
        composeSheetCoordinator.dismiss()
        composeMorphPhase = .idle
    }
}
```

### Morph Overlay

The overlay interpolates between the button frame and the final sheet frame. The content is hidden until the shape mostly reaches the final position.

```swift
private struct MorphingComposeSheetOverlay<Content: View>: View {
    @Binding var phase: ComposeMorphPhase
    let sourceFrame: CGRect
    let reduceMotion: Bool
    let onDismiss: () -> Void
    let content: () -> Content

    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var isExpanded = false
    @State private var revealContent = false

    init(
        phase: Binding<ComposeMorphPhase>,
        sourceFrame: CGRect,
        reduceMotion: Bool,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _phase = phase
        self.sourceFrame = sourceFrame
        self.reduceMotion = reduceMotion
        self.onDismiss = onDismiss
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let sheetFrame = finalSheetFrame(in: proxy)
            let progress = progressValue
            let currentFrame = interpolate(from: sourceFrame, to: sheetFrame, progress: progress)
            let cornerRadius = interpolate(
                from: ComposeMorphMetrics.buttonSize / 2,
                to: ComposeMorphMetrics.sheetCornerRadius,
                progress: progress
            )

            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(0.28 * progress)
                    .ignoresSafeArea()
                    .onTapGesture {
                        onDismiss()
                    }

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(appSettings.themePalette.secondaryBackground)
                    .overlay(alignment: .top) {
                        morphHeader(progress: progress)
                    }
                    .overlay {
                        if revealContent || reduceMotion {
                            content()
                                .opacity(progress)
                                .offset(y: 10 * (1 - progress))
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: ComposeMorphMetrics.sheetCornerRadius,
                                        style: .continuous
                                    )
                                )
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .frame(width: currentFrame.width, height: currentFrame.height)
                    .position(x: currentFrame.midX, y: currentFrame.midY)
                    .shadow(
                        color: .black.opacity(0.18 * progress),
                        radius: 24 * progress,
                        x: 0,
                        y: 10 * progress
                    )
            }
            .ignoresSafeArea()
            .onAppear {
                startIfNeeded()
            }
            .onChange(of: phase) { _, newPhase in
                if newPhase == .closing {
                    revealContent = false
                    withAnimation(ComposeMorphMetrics.closeAnimation) {
                        isExpanded = false
                    }
                }
            }
        }
    }

    private var progressValue: CGFloat {
        isExpanded ? 1 : 0
    }

    private func startIfNeeded() {
        guard !reduceMotion else {
            isExpanded = true
            phase = .expanded
            revealContent = true
            return
        }

        withAnimation(ComposeMorphMetrics.expandAnimation) {
            isExpanded = true
            phase = .expanding
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(ComposeMorphMetrics.contentAnimation) {
                revealContent = true
                phase = .expanded
            }
        }
    }

    private func morphHeader(progress: CGFloat) -> some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.secondary.opacity(0.28 * progress))
                .frame(width: 38, height: 5)
                .padding(.top, 12)

            HStack {
                Image(systemName: "plus")
                    .font(.system(size: interpolate(from: 25, to: 16, progress: progress), weight: .semibold))
                    .foregroundStyle(appSettings.buttonTextColor)
                    .frame(width: 34, height: 34)
                    .background(appSettings.primaryGradient, in: Circle())
                    .opacity(1 - min(progress, 0.96))

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(appSettings.themePalette.tertiaryFill, in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(progress)
                .accessibilityLabel("Close compose")
            }
            .padding(.horizontal, 16)
        }
        .frame(height: ComposeMorphMetrics.headerHeight, alignment: .top)
    }

    private func finalSheetFrame(in proxy: GeometryProxy) -> CGRect {
        let safeTop = proxy.safeAreaInsets.top
        let width = proxy.size.width - (ComposeMorphMetrics.horizontalMargin * 2)
        let height = proxy.size.height - safeTop - ComposeMorphMetrics.bottomMargin

        return CGRect(
            x: ComposeMorphMetrics.horizontalMargin,
            y: safeTop,
            width: width,
            height: height
        )
    }

    private func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: interpolate(from: start.minX, to: end.minX, progress: progress),
            y: interpolate(from: start.minY, to: end.minY, progress: progress),
            width: interpolate(from: start.width, to: end.width, progress: progress),
            height: interpolate(from: start.height, to: end.height, progress: progress)
        )
    }

    private func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + ((end - start) * min(max(progress, 0), 1))
    }
}
```

## Production Notes

The example above intentionally keeps the app's existing coordinator. The important change is presentation, not composer ownership.

Recommended production refinements:

- Move `ComposeMorphPhase`, metrics, and overlay into `Sources/Compose/ComposeMorphingSheetOverlay.swift`.
- Keep the old `.sheet(item:)` for reply/quote flows until the morph is proven for new notes.
- Add a layout guardrail test for the morph timings and source/final frame interpolation.
- Add an accessibility test or manual QA pass for Reduce Motion.
- Make dismissal call the same draft-saving logic the current `ComposeNoteSheet` uses.
- If `ComposeNoteSheet` currently depends on system sheet dismissal, inject a local dismiss action through the environment or a closure so the overlay can close it cleanly.

## Acceptance Criteria

- Tapping the floating compose button visually expands from the button's actual position.
- The plus icon does not simply vanish; it is absorbed into the header motion.
- Composer content appears after the container begins landing.
- Reduce Motion presents the composer without geometry morphing.
- The final composer layout matches the current sheet layout.
- Existing non-floating compose paths still work.
