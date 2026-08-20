import SwiftUI

enum SideMenuTransitionLayout {
    static let menuWidthFraction: CGFloat = 0.78
    static let menuClosedOffsetFraction: CGFloat = 0.08
    static let menuClosedOpacity: Double = 0.82
    static let primaryContentOpenScale: CGFloat = 1
    static let primaryContentOpenCornerRadius: CGFloat = 44
    static let backdropOpacity: Double = 0.42
    static let rowStaggerProgress: CGFloat = 0.045
    static let rowClosedXOffset: CGFloat = -12
    static let rowClosedYOffset: CGFloat = 0
    static let rowClosedOpacity: Double = 0
    static let profileHeaderAvatarSize: CGFloat = 52
    static let profileHeaderLinksTopSpacing: CGFloat = 20
    static let logoutTopSpacing: CGFloat = 18
    static let profileHeaderPrimaryFillOpacity: Double = 0
    static let menuButtonBackgroundOpacity: Double = 0
    static let menuIconBackgroundOpacity: Double = 0
    static let menuControlStrokeOpacity: Double = 0.28
    static let dragMinimumDistance: CGFloat = 10
    static let dragAxisDominanceRatio: CGFloat = 1.15
    static let projectedOpenThreshold: CGFloat = 0.5
    static let menuZIndex: Double = 0
    static let primaryContentZIndex: Double = 1
    static let usesParentZStack = true
    static let keepsMenuBehindPrimaryContent = true
    static let menuFillsFullContainerHeight = true

    static func animation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.38, dampingFraction: 0.88)
    }

    static func menuWidth(for containerWidth: CGFloat) -> CGFloat {
        max(0, containerWidth * menuWidthFraction)
    }

    static func resolvedTopSafeArea(
        explicitTopSafeAreaInset: CGFloat,
        geometryTopSafeAreaInset: CGFloat
    ) -> CGFloat {
        let explicitTopSafeArea = max(0, explicitTopSafeAreaInset)
        guard explicitTopSafeArea <= 0 else { return explicitTopSafeArea }
        return max(0, geometryTopSafeAreaInset)
    }

    static func clampedContentOffset(
        isOpen: Bool,
        dragTranslation: CGFloat,
        openOffset: CGFloat
    ) -> CGFloat {
        let restingOffset = isOpen ? openOffset : 0
        return min(max(restingOffset + dragTranslation, 0), max(0, openOffset))
    }

    static func presentationProgress(contentOffset: CGFloat, openOffset: CGFloat) -> CGFloat {
        guard openOffset > 0 else { return 0 }
        return min(max(contentOffset / openOffset, 0), 1)
    }

    static func isHorizontallyDominant(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * dragAxisDominanceRatio
    }

    static func isVerticallyDominant(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width) * dragAxisDominanceRatio
    }

    static func shouldOpen(
        isOpen: Bool,
        predictedEndTranslation: CGFloat,
        openOffset: CGFloat
    ) -> Bool {
        let projectedOffset = clampedContentOffset(
            isOpen: isOpen,
            dragTranslation: predictedEndTranslation,
            openOffset: openOffset
        )
        return projectedOffset >= openOffset * projectedOpenThreshold
    }

    static func canTrackMenuDrag(
        isOpen: Bool,
        allowsOpeningGesture: Bool,
        horizontalTranslation: CGFloat
    ) -> Bool {
        isOpen || (allowsOpeningGesture && horizontalTranslation > 0)
    }

    static func rowPresentationProgress(menuProgress: CGFloat, index: Int) -> CGFloat {
        let stagger = min(CGFloat(max(0, index)) * rowStaggerProgress, 0.4)
        guard stagger < 1 else { return menuProgress >= 1 ? 1 : 0 }
        return min(max((menuProgress - stagger) / (1 - stagger), 0), 1)
    }
}

struct SideMenuContainer<Content: View, Menu: View>: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding private var isOpen: Bool
    @State private var dragTranslation: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var isTrackingMenuDrag = false

    private let content: Content
    private let menu: Menu
    private let menuBackground: Color
    private let topSafeAreaInset: CGFloat
    private let allowsOpeningGesture: Bool

    init(
        isOpen: Binding<Bool>,
        topSafeAreaInset: CGFloat = 0,
        menuBackground: Color = .clear,
        allowsOpeningGesture: Bool = true,
        @ViewBuilder menu: () -> Menu,
        @ViewBuilder content: () -> Content
    ) {
        _isOpen = isOpen
        self.topSafeAreaInset = topSafeAreaInset
        self.menuBackground = menuBackground
        self.allowsOpeningGesture = allowsOpeningGesture
        self.menu = menu()
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let menuWidth = SideMenuTransitionLayout.menuWidth(for: geometry.size.width)
            let contentOffset = SideMenuTransitionLayout.clampedContentOffset(
                isOpen: isOpen,
                dragTranslation: dragTranslation,
                openOffset: menuWidth
            )
            let presentationProgress = SideMenuTransitionLayout.presentationProgress(
                contentOffset: contentOffset,
                openOffset: menuWidth
            )
            let resolvedTopSafeArea = SideMenuTransitionLayout.resolvedTopSafeArea(
                explicitTopSafeAreaInset: topSafeAreaInset,
                geometryTopSafeAreaInset: geometry.safeAreaInsets.top
            )
            let bottomSafeArea = max(0, geometry.safeAreaInsets.bottom)
            let windowSafeAreaInsets = activeWindowSafeAreaInsets
            let menuTopSafeArea = max(resolvedTopSafeArea, windowSafeAreaInsets.top)
            let menuBottomSafeArea = max(bottomSafeArea, windowSafeAreaInsets.bottom)

            ZStack(alignment: .topLeading) {
                menuBackground
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                menuLayer(
                    width: menuWidth,
                    height: geometry.size.height,
                    progress: presentationProgress,
                    safeAreaInsets: EdgeInsets(
                        top: menuTopSafeArea,
                        leading: 0,
                        bottom: menuBottomSafeArea,
                        trailing: 0
                    )
                )
                    .zIndex(SideMenuTransitionLayout.menuZIndex)

                primaryContentLayer(
                    offset: contentOffset,
                    progress: presentationProgress,
                    openOffset: menuWidth
                )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .zIndex(SideMenuTransitionLayout.primaryContentZIndex)
            }
            .ignoresSafeArea()
            .animation(
                SideMenuTransitionLayout.animation(reduceMotion: accessibilityReduceMotion),
                value: isOpen
            )
        }
    }

    private var activeWindowSafeAreaInsets: EdgeInsets {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first(where: \.isKeyWindow) else {
            return EdgeInsets()
        }

        let insets = window.safeAreaInsets
        return EdgeInsets(
            top: max(0, insets.top),
            leading: max(0, insets.left),
            bottom: max(0, insets.bottom),
            trailing: max(0, insets.right)
        )
    }

    private func menuLayer(
        width: CGFloat,
        height: CGFloat,
        progress: CGFloat,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        menu
            .environment(\.sideMenuPresentationIsOpen, isOpen)
            .environment(\.sideMenuPresentationProgress, progress)
            .environment(\.sideMenuSafeAreaInsets, safeAreaInsets)
            .frame(width: width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .offset(
                x: -width
                    * SideMenuTransitionLayout.menuClosedOffsetFraction
                    * (1 - progress)
            )
            .opacity(
                SideMenuTransitionLayout.menuClosedOpacity
                    + ((1 - SideMenuTransitionLayout.menuClosedOpacity) * Double(progress))
            )
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }

    private func primaryContentLayer(
        offset: CGFloat,
        progress: CGFloat,
        openOffset: CGFloat
    ) -> some View {
        let cornerRadius = SideMenuTransitionLayout.primaryContentOpenCornerRadius * progress
        let panelShape = UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )

        return ZStack {
            content
                .disabled(isOpen)
                .accessibilityHidden(isOpen)

            dismissBackdrop(progress: progress)
        }
            .contentShape(panelShape)
            .scaleEffect(
                1 - ((1 - SideMenuTransitionLayout.primaryContentOpenScale) * progress),
                anchor: .center
            )
            .clipShape(panelShape)
            .shadow(
                color: .black.opacity(0.28 * Double(progress)),
                radius: 18 * progress,
                x: -8 * progress,
                y: 0
            )
            .offset(x: offset)
            .simultaneousGesture(sideMenuDragGesture(openOffset: openOffset), including: .all)
    }

    private func dismissBackdrop(progress: CGFloat) -> some View {
        Button {
            closeMenu()
        } label: {
            Rectangle()
                .fill(
                    Color.black.opacity(
                        SideMenuTransitionLayout.backdropOpacity * Double(progress)
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss side menu")
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
    }

    private func sideMenuDragGesture(openOffset: CGFloat) -> some Gesture {
        DragGesture(
            minimumDistance: SideMenuTransitionLayout.dragMinimumDistance,
            coordinateSpace: .local
        )
        .onChanged { value in
            if dragAxis == nil {
                if SideMenuTransitionLayout.isHorizontallyDominant(value.translation) {
                    dragAxis = .horizontal
                } else if SideMenuTransitionLayout.isVerticallyDominant(value.translation) {
                    dragAxis = .vertical
                }
            }

            guard dragAxis == .horizontal else { return }
            guard SideMenuTransitionLayout.canTrackMenuDrag(
                isOpen: isOpen,
                allowsOpeningGesture: allowsOpeningGesture,
                horizontalTranslation: value.translation.width
            ) else {
                return
            }
            isTrackingMenuDrag = true
            dragTranslation = value.translation.width
        }
        .onEnded { value in
            defer {
                dragAxis = nil
                isTrackingMenuDrag = false
            }
            guard dragAxis == .horizontal, isTrackingMenuDrag else {
                dragTranslation = 0
                return
            }

            let shouldOpen = SideMenuTransitionLayout.shouldOpen(
                isOpen: isOpen,
                predictedEndTranslation: value.predictedEndTranslation.width,
                openOffset: openOffset
            )
            settleMenu(open: shouldOpen)
        }
    }

    private func settleMenu(open: Bool) {
        if let animation = SideMenuTransitionLayout.animation(reduceMotion: accessibilityReduceMotion) {
            withAnimation(animation) {
                dragTranslation = 0
                isOpen = open
            }
        } else {
            dragTranslation = 0
            isOpen = open
        }
    }

    private func closeMenu() {
        settleMenu(open: false)
    }
}

private extension SideMenuContainer {
    enum DragAxis {
        case horizontal
        case vertical
    }
}

private struct SideMenuPresentationIsOpenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SideMenuPresentationProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct SideMenuSafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    var sideMenuPresentationIsOpen: Bool {
        get { self[SideMenuPresentationIsOpenKey.self] }
        set { self[SideMenuPresentationIsOpenKey.self] = newValue }
    }

    var sideMenuPresentationProgress: CGFloat {
        get { self[SideMenuPresentationProgressKey.self] }
        set { self[SideMenuPresentationProgressKey.self] = newValue }
    }

    /// Screen safe-area insets the full-bleed side menu ignores; menu content
    /// uses these to keep controls clear of the status bar and home indicator.
    var sideMenuSafeAreaInsets: EdgeInsets {
        get { self[SideMenuSafeAreaInsetsKey.self] }
        set { self[SideMenuSafeAreaInsetsKey.self] = newValue }
    }
}
