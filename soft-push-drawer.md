# Soft Push Drawer

## Stated Goals

Replace the current stiff side menu open/close with a softer drawer interaction that feels connected to the main app surface.

The drawer should feel like it pushes the feed/activity surface aside instead of appearing as a flat overlay. The menu panel should have depth, the background content should subtly respond, and the menu rows should arrive with a small stagger.

This should apply to both places that currently use `HomeSlideoutMenuView`:

- `Sources/Home/HomeFeedView.swift`
- `Sources/Activity/ActivityView.swift`

The final user-facing effect:

1. Tap avatar/menu button.
2. The main content nudges right and slightly scales down.
3. The scrim fades in independently.
4. The menu panel slides in with a spring and soft trailing corners.
5. Account header and menu rows settle in with a restrained stagger.
6. Tap scrim or close button dismisses with a quicker, cleaner close.

## Instructions For LLM

Use this as an implementation guide, not a visual redesign brief.

- Preserve the existing menu actions and account/profile behavior.
- Do not redesign the menu content, labels, settings flow, QR sheet, auth flow, or logout behavior.
- Refactor the drawer presentation into a shared SwiftUI component so Home and Activity do not keep separate overlay mechanics.
- Keep `HomeSlideoutMenuView` as the actual menu content.
- Add motion metrics as testable pure functions where possible.
- Respect `accessibilityReduceMotion`.
- Remove conflicting animations that target `isHomeSideMenuPresented` with a separate `.easeInOut(duration: 0.2)`.
- Avoid nested cards, heavy blur, decorative gradients, or large bouncy effects.
- Keep the interaction quiet, native, and readable.
- Use TDD: add layout/motion guardrail tests before production code.

Recommended file ownership:

- Add `Sources/Design/SoftPushDrawerContainer.swift`
- Add or extend motion metrics in `Sources/App/FlowTransitionMotion.swift`
- Update `Sources/Home/HomeFeedView.swift`
- Update `Sources/Activity/ActivityView.swift`
- Update `Sources/Home/HomeSlideoutMenuView.swift`
- Add tests in `Tests/FlowLayoutGuardrailsTests.swift`

## Acceptance Criteria

- Opening the side menu pushes the main content right by about `18pt`.
- Main content scales to about `0.985` while the drawer is open.
- Scrim opacity tops out at about `0.22`.
- Drawer width remains `min(320, screenWidth * 0.82)`.
- Drawer animates from offscreen left to its final position.
- Drawer has subtle trailing corners and shadow while open.
- Menu rows appear with a small stagger.
- Closing is faster than opening.
- Reduce Motion disables the push/scale/stagger and uses immediate state changes.
- Home and Activity use the same drawer container.
- Existing menu actions still work.
- No outer `.easeInOut(duration: 0.2)` fights the drawer animation.

## Current Problem

Current behavior is mostly binary:

```swift
if isShowingSideMenu {
    sideMenuOverlay()
        .transition(FlowTransitionMotion.sidePanelTransition(reduceMotion: accessibilityReduceMotion))
}
.animation(FlowTransitionMotion.sidePanelAnimation(reduceMotion: accessibilityReduceMotion), value: isShowingSideMenu)
```

The overlay itself also uses:

```swift
Color.black.opacity(0.22)

HomeSlideoutMenuView(...)
    .frame(width: min(320, geometry.size.width * 0.82))
    .transition(.move(edge: .leading))
```

This makes the menu feel like a view being inserted, not a surface moving through space. There is also a separate animation in `MainTabShellView`:

```swift
.animation(.easeInOut(duration: 0.2), value: isHomeSideMenuPresented)
```

That should be removed for this specific state so the drawer owns its own motion.

## Proposed Architecture

Create one shared container:

```swift
SoftPushDrawerContainer(
    isPresented: $isShowingSideMenu,
    onDismiss: {
        isShowingSideMenu = false
    },
    background: {
        VStack(spacing: 0) {
            topNavigationBar()
            feedContent()
        }
    },
    drawer: { progress in
        sideMenuOverlay(progress: progress)
    }
)
```

The container owns:

- rendered vs dismissed lifecycle
- open and close animations
- content push/scale
- scrim
- drawer offset
- drawer shadow
- tap outside to dismiss

The menu owns:

- account header
- QR sheet
- menu rows
- row stagger based on `motionProgress`

## Exact Code Example

### 1. Add Shared Layout And Container

Create `Sources/Design/SoftPushDrawerContainer.swift`.

```swift
import SwiftUI

enum SoftPushDrawerLayout {
    static let maxDrawerWidth: CGFloat = 320
    static let drawerWidthRatio: CGFloat = 0.82
    static let contentPushDistance: CGFloat = 18
    static let contentOpenScale: CGFloat = 0.985
    static let maxScrimOpacity: Double = 0.22
    static let maxShadowOpacity: Double = 0.18
    static let maxTrailingCornerRadius: CGFloat = 28
    static let rowStagger: TimeInterval = 0.025

    static func drawerWidth(for availableWidth: CGFloat) -> CGFloat {
        min(maxDrawerWidth, max(0, availableWidth) * drawerWidthRatio)
    }

    static func clampedProgress(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    static func contentOffset(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        contentPushDistance * clampedProgress(progress)
    }

    static func contentScale(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let progress = clampedProgress(progress)
        return 1 - ((1 - contentOpenScale) * progress)
    }

    static func scrimOpacity(progress: CGFloat, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return maxScrimOpacity }
        return maxScrimOpacity * Double(clampedProgress(progress))
    }

    static func drawerOffset(drawerWidth: CGFloat, progress: CGFloat, dragOffset: CGFloat = 0) -> CGFloat {
        let progress = clampedProgress(progress)
        return (-drawerWidth * (1 - progress)) + min(0, dragOffset)
    }

    static func trailingCornerRadius(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return maxTrailingCornerRadius * clampedProgress(progress)
    }

    static func rowAnimation(index: Int, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let delay = min(Double(max(index, 0)) * rowStagger, 0.14)
        return .easeOut(duration: 0.18).delay(delay)
    }
}

struct SoftPushDrawerContainer<Background: View, Drawer: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    let background: () -> Background
    let drawer: (_ progress: CGFloat) -> Drawer

    @State private var isRendered = false
    @State private var progress: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    init(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void,
        @ViewBuilder background: @escaping () -> Background,
        @ViewBuilder drawer: @escaping (_ progress: CGFloat) -> Drawer
    ) {
        _isPresented = isPresented
        self.onDismiss = onDismiss
        self.background = background
        self.drawer = drawer
    }

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = SoftPushDrawerLayout.drawerWidth(for: proxy.size.width)
            let effectiveProgress = effectiveProgress(drawerWidth: drawerWidth)

            ZStack(alignment: .leading) {
                background()
                    .offset(
                        x: SoftPushDrawerLayout.contentOffset(
                            progress: effectiveProgress,
                            reduceMotion: reduceMotion
                        )
                    )
                    .scaleEffect(
                        SoftPushDrawerLayout.contentScale(
                            progress: effectiveProgress,
                            reduceMotion: reduceMotion
                        ),
                        anchor: .leading
                    )
                    .disabled(isRendered)
                    .allowsHitTesting(!isRendered)

                if isRendered {
                    Color.black
                        .opacity(
                            SoftPushDrawerLayout.scrimOpacity(
                                progress: effectiveProgress,
                                reduceMotion: reduceMotion
                            )
                        )
                        .ignoresSafeArea()
                        .onTapGesture {
                            dismiss()
                        }

                    drawer(effectiveProgress)
                        .frame(width: drawerWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .clipShape(
                            UnevenRoundedRectangle(
                                cornerRadii: RectangleCornerRadii(
                                    topLeading: 0,
                                    bottomLeading: 0,
                                    bottomTrailing: SoftPushDrawerLayout.trailingCornerRadius(
                                        progress: effectiveProgress,
                                        reduceMotion: reduceMotion
                                    ),
                                    topTrailing: SoftPushDrawerLayout.trailingCornerRadius(
                                        progress: effectiveProgress,
                                        reduceMotion: reduceMotion
                                    )
                                ),
                                style: .continuous
                            )
                        )
                        .shadow(
                            color: .black.opacity(SoftPushDrawerLayout.maxShadowOpacity * Double(effectiveProgress)),
                            radius: 24 * effectiveProgress,
                            x: 8 * effectiveProgress,
                            y: 0
                        )
                        .offset(
                            x: SoftPushDrawerLayout.drawerOffset(
                                drawerWidth: drawerWidth,
                                progress: effectiveProgress
                            )
                        )
                        .gesture(dismissDrag(drawerWidth: drawerWidth))
                }
            }
            .onAppear {
                syncPresentationState(isPresented)
            }
            .onChange(of: isPresented) { _, newValue in
                syncPresentationState(newValue)
            }
        }
    }

    private func effectiveProgress(drawerWidth: CGFloat) -> CGFloat {
        guard drawerWidth > 0 else { return progress }
        let dragProgress = dragOffset / drawerWidth
        return SoftPushDrawerLayout.clampedProgress(progress + dragProgress)
    }

    private func syncPresentationState(_ presented: Bool) {
        if reduceMotion {
            isRendered = presented
            progress = presented ? 1 : 0
            return
        }

        if presented {
            isRendered = true
            withAnimation(FlowTransitionMotion.sidePanelOpenAnimation(reduceMotion: reduceMotion)) {
                progress = 1
            }
        } else {
            withAnimation(FlowTransitionMotion.sidePanelCloseAnimation(reduceMotion: reduceMotion)) {
                progress = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + FlowTransitionMotion.duration(.sidePanelClose, reduceMotion: false)) {
                guard !isPresented else { return }
                isRendered = false
            }
        }
    }

    private func dismiss() {
        onDismiss()
    }

    private func dismissDrag(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                state = min(0, value.translation.width)
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                let shouldDismiss = value.translation.width < -(drawerWidth * 0.28) || predicted < -(drawerWidth * 0.42)
                if shouldDismiss {
                    dismiss()
                }
            }
    }
}
```

### 2. Extend FlowTransitionMotion

Update `Sources/App/FlowTransitionMotion.swift`.

```swift
enum FlowTransitionMotion {
    enum Timing {
        case badgePop
        case textSwap
        case sidePanelOpen
        case sidePanelClose
        case numberPop
        case iconSwap
    }

    static func duration(_ timing: Timing, reduceMotion: Bool) -> TimeInterval {
        guard !reduceMotion else { return 0 }

        switch timing {
        case .badgePop:
            return 0.5
        case .textSwap:
            return 0.2
        case .sidePanelOpen:
            return 0.36
        case .sidePanelClose:
            return 0.22
        case .numberPop:
            return 0.5
        case .iconSwap:
            return 0.2
        }
    }

    static func sidePanelOpenAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .interactiveSpring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.04)
    }

    static func sidePanelCloseAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: duration(.sidePanelClose, reduceMotion: false))
    }

    static func sidePanelAnimation(reduceMotion: Bool) -> Animation? {
        sidePanelOpenAnimation(reduceMotion: reduceMotion)
    }
}
```

Keep `sidePanelTransition(reduceMotion:)` during migration if other code still calls it, but the new drawer container should not use that transition for menu presentation.

### 3. Update HomeFeedRootContent

Change the side menu closure to accept a progress value.

```swift
private struct HomeFeedRootContent: View {
    @Binding var isShowingSideMenu: Bool

    let topNavigationBar: () -> AnyView
    let feedContent: () -> AnyView
    let sideMenuOverlay: (_ progress: CGFloat) -> AnyView

    var body: some View {
        ZStack(alignment: .leading) {
            AppThemeBackgroundView(holographicSpotlight: .feed)
                .ignoresSafeArea()

            SoftPushDrawerContainer(
                isPresented: $isShowingSideMenu,
                onDismiss: {
                    isShowingSideMenu = false
                },
                background: {
                    VStack(spacing: 0) {
                        topNavigationBar()
                        feedContent()
                    }
                },
                drawer: { progress in
                    sideMenuOverlay(progress)
                }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
```

Change the callsite in `HomeFeedView` from:

```swift
sideMenuOverlay: { AnyView(sideMenuOverlay) }
```

to:

```swift
sideMenuOverlay: { progress in AnyView(sideMenuOverlay(progress: progress)) }
```

Change the overlay property into a function:

```swift
private func sideMenuOverlay(progress: CGFloat) -> some View {
    HomeSlideoutMenuView(
        motionProgress: progress,
        onViewProfile: {
            if let pubkey = auth.currentAccount?.pubkey {
                openProfile(pubkey: pubkey)
            }
            closeSideMenu()
        },
        onOpenScannedProfile: { pubkey in
            closeSideMenu()
            openProfile(pubkey: pubkey)
        },
        onManageSettings: {
            closeSideMenu()
            isShowingSettings = true
        },
        onManageAccounts: {
            closeSideMenu()
            openAuthSheet(tab: .accounts)
        },
        onLogout: {
            auth.logout()
            closeSideMenu()
        },
        onClose: {
            closeSideMenu()
        }
    )
    .environmentObject(auth)
}
```

Change `openSideMenu()` and `closeSideMenu()` so they only mutate state. The container owns animation.

```swift
private func openSideMenu() {
    isShowingSideMenu = true
}

private func closeSideMenu() {
    isShowingSideMenu = false
}
```

### 4. Update ActivityView

Mirror the Home changes. Replace its local `GeometryReader` drawer overlay with the same `SoftPushDrawerContainer` pattern.

Activity currently has:

```swift
if isShowingSideMenu {
    sideMenuOverlay
}
.animation(FlowTransitionMotion.sidePanelAnimation(reduceMotion: accessibilityReduceMotion), value: isShowingSideMenu)
```

Replace that root stack with:

```swift
SoftPushDrawerContainer(
    isPresented: $isShowingSideMenu,
    onDismiss: {
        isShowingSideMenu = false
    },
    background: {
        VStack(spacing: 0) {
            topNavigationBar
            activityContent
        }
    },
    drawer: { progress in
        sideMenuOverlay(progress: progress)
    }
)
```

Then make Activity's menu overlay match Home:

```swift
private func sideMenuOverlay(progress: CGFloat) -> some View {
    HomeSlideoutMenuView(
        motionProgress: progress,
        onViewProfile: {
            if let pubkey = auth.currentAccount?.pubkey {
                openProfile(pubkey: pubkey)
            }
            closeSideMenu()
        },
        onOpenScannedProfile: { pubkey in
            closeSideMenu()
            openProfile(pubkey: pubkey)
        },
        onManageSettings: {
            closeSideMenu()
            isShowingSettings = true
        },
        onManageAccounts: {
            closeSideMenu()
            openAuthSheet(tab: .accounts)
        },
        onLogout: {
            auth.logout()
            closeSideMenu()
        },
        onClose: {
            closeSideMenu()
        }
    )
    .environmentObject(auth)
}
```

Also simplify Activity open/close:

```swift
private func openSideMenu() {
    isShowingSideMenu = true
}

private func closeSideMenu() {
    isShowingSideMenu = false
}
```

### 5. Add Row Stagger To HomeSlideoutMenuView

Update `Sources/Home/HomeSlideoutMenuView.swift`.

Add a stored property:

```swift
var motionProgress: CGFloat = 1
```

Add Reduce Motion to the environment:

```swift
@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
```

Update the menu row calls:

```swift
menuButton(
    title: "View Profile",
    icon: "person.crop.circle",
    motionIndex: 0,
    action: onViewProfile
)

menuButton(
    title: "Settings",
    icon: "gearshape",
    motionIndex: 1,
    action: onManageSettings
)

menuButton(
    title: "Manage Accounts",
    icon: "arrow.left.arrow.right.circle",
    motionIndex: 2,
    action: onManageAccounts
)

if auth.isLoggedIn {
    menuButton(
        title: "Log Out",
        icon: "rectangle.portrait.and.arrow.right",
        tint: .red,
        motionIndex: 3,
        action: onLogout
    )
}
```

Update the helper signature:

```swift
private func menuButton(
    title: String,
    icon: String,
    tint: Color? = nil,
    motionIndex: Int,
    action: @escaping () -> Void
) -> some View {
    let iconTint = tint ?? appSettings.themeIconAccentColor
    let textTint = tint ?? appSettings.themePalette.foreground
    let rowProgress = accessibilityReduceMotion
        ? 1
        : SoftPushDrawerLayout.clampedProgress((motionProgress - 0.18) / 0.82)

    return Button {
        action()
    } label: {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 22)

            Text(title)
                .font(appSettings.appFont(.body))
                .foregroundStyle(textTint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .opacity(rowProgress)
        .offset(x: 10 * (1 - rowProgress))
        .animation(
            SoftPushDrawerLayout.rowAnimation(
                index: motionIndex,
                reduceMotion: accessibilityReduceMotion
            ),
            value: rowProgress
        )
    }
    .buttonStyle(.plain)
}
```

Optional: apply a lighter version to the account header.

```swift
accountHeader(currentAccount)
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .opacity(SoftPushDrawerLayout.clampedProgress(motionProgress / 0.8))
    .offset(x: 8 * (1 - SoftPushDrawerLayout.clampedProgress(motionProgress / 0.8)))
```

### 6. Remove Conflicting MainTabShell Animation

In `Sources/App/MainTabShellView.swift`, delete this line:

```swift
.animation(.easeInOut(duration: 0.2), value: isHomeSideMenuPresented)
```

The drawer container now owns the side menu motion. Keeping this outer animation can make the tab shell, bottom bar, and drawer feel like they are using two different timing systems.

## Test Examples

Add guardrails in `Tests/FlowLayoutGuardrailsTests.swift`.

```swift
func testSoftPushDrawerLayoutUsesSubtleContentPush() {
    XCTAssertEqual(SoftPushDrawerLayout.drawerWidth(for: 500), 320, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.drawerWidth(for: 300), 246, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.contentOffset(progress: 1, reduceMotion: false), 18, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.contentOffset(progress: 1, reduceMotion: true), 0, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.contentScale(progress: 1, reduceMotion: false), 0.985, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.contentScale(progress: 1, reduceMotion: true), 1, accuracy: 0.0001)
}

func testSoftPushDrawerLayoutScrimAndPanelMotionAreBounded() {
    XCTAssertEqual(SoftPushDrawerLayout.scrimOpacity(progress: 1, reduceMotion: false), 0.22, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.scrimOpacity(progress: 2, reduceMotion: false), 0.22, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.drawerOffset(drawerWidth: 320, progress: 0), -320, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.drawerOffset(drawerWidth: 320, progress: 1), 0, accuracy: 0.0001)
    XCTAssertEqual(SoftPushDrawerLayout.trailingCornerRadius(progress: 1, reduceMotion: false), 28, accuracy: 0.0001)
}
```

Update the existing transition timing guardrail to include close timing:

```swift
XCTAssertEqual(FlowTransitionMotion.duration(.sidePanelOpen, reduceMotion: false), 0.36, accuracy: 0.0001)
XCTAssertEqual(FlowTransitionMotion.duration(.sidePanelClose, reduceMotion: false), 0.22, accuracy: 0.0001)
XCTAssertEqual(FlowTransitionMotion.duration(.sidePanelClose, reduceMotion: true), 0, accuracy: 0.0001)
```

## Verification Commands

Use a red-green flow.

First run the new tests before production code and confirm they fail:

```sh
xcodebuild build-for-testing -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/FlowSoftPushDrawerRed -only-testing:FlowTests/FlowLayoutGuardrailsTests/testSoftPushDrawerLayoutUsesSubtleContentPush -only-testing:FlowTests/FlowLayoutGuardrailsTests/testSoftPushDrawerLayoutScrimAndPanelMotionAreBounded
```

After implementation:

```sh
xcodebuild build-for-testing -project Flow.xcodeproj -scheme Flow -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/FlowSoftPushDrawerGreen -only-testing:FlowTests/FlowLayoutGuardrailsTests/testSoftPushDrawerLayoutUsesSubtleContentPush -only-testing:FlowTests/FlowLayoutGuardrailsTests/testSoftPushDrawerLayoutScrimAndPanelMotionAreBounded
```

Then run the built tests:

```sh
find /tmp/FlowSoftPushDrawerGreen -name '*.xctestrun' -print
xcodebuild test-without-building -xctestrun /tmp/FlowSoftPushDrawerGreen/Build/Products/Flow_iphonesimulator26.4-arm64.xctestrun -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FlowTests/FlowLayoutGuardrailsTests/testSoftPushDrawerLayoutUsesSubtleContentPush -only-testing:FlowTests/FlowLayoutGuardrailsTests/testSoftPushDrawerLayoutScrimAndPanelMotionAreBounded
git diff --check
```

## Manual QA

Check these flows on simulator:

- Open menu from Home.
- Close menu by tapping scrim.
- Close menu with the `xmark` button.
- Open Settings from menu.
- Open Manage Accounts from menu.
- Open View Profile from menu.
- Open menu from Activity.
- Swipe left on the drawer to dismiss.
- Enable Reduce Motion and confirm no push/scale/stagger is used.

## Notes

The most important part is not the exact numbers. It is that all visible pieces are tied to one progress value:

- main content offset
- main content scale
- scrim opacity
- drawer offset
- drawer corner radius
- drawer shadow
- row entrance

That shared progress is what makes the drawer feel softer and more intentional.
