import SwiftUI

enum SideMenuTransitionLayout {
    static let menuWidthFraction: CGFloat = 0.78
    static let menuClosedOffsetFraction: CGFloat = 1.08
    static let menuClosedOpacity: Double = 0
    static let primaryContentOpenScale: CGFloat = 0.965
    static let primaryContentOpenOffsetFraction: CGFloat = 0.045
    static let primaryContentOpenOffsetMaximum: CGFloat = 18
    static let primaryContentOpenCornerRadius: CGFloat = 26
    static let menuTrailingCornerRadius: CGFloat = 30
    static let backdropOpacity: Double = 0.24
    static let backdropBlurRadius: CGFloat = 3
    static let rowStaggerDelay: TimeInterval = 0.045
    static let rowClosedXOffset: CGFloat = -10
    static let rowClosedYOffset: CGFloat = 0
    static let rowClosedOpacity: Double = 0
    static let profileBannerHeight: CGFloat = 204
    static let profileBannerFadeHeight: CGFloat = 120
    static let profileBannerLoadedImageOpacity: Double = 0.68
    static let profileBannerLoadedImageSaturation: Double = 0.92
    static let profileHeaderAvatarSize: CGFloat = 76
    static let profileHeaderContentBottomPadding: CGFloat = 8
    static let profileHeaderLinksTopSpacing: CGFloat = 22
    static let logoutTopSpacing: CGFloat = 18
    static let profileHeaderPrimaryFillOpacity: Double = 0
    static let menuButtonBackgroundOpacity: Double = 0
    static let menuIconBackgroundOpacity: Double = 0
    static let menuControlStrokeOpacity: Double = 0.28
    static let primaryContentZIndex: Double = 0
    static let backdropZIndex: Double = 1
    static let menuZIndex: Double = 2
    static let usesParentZStack = true
    static let keepsMenuBehindPrimaryContent = false
    static let menuFillsFullContainerHeight = true

    static func animation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.4, dampingFraction: 0.82)
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

    static func primaryContentOpenOffset(for containerWidth: CGFloat) -> CGFloat {
        max(0, min(containerWidth * primaryContentOpenOffsetFraction, primaryContentOpenOffsetMaximum))
    }
}

struct SideMenuContainer<Content: View, Menu: View>: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding private var isOpen: Bool

    private let content: Content
    private let menu: Menu
    private let topSafeAreaInset: CGFloat

    init(
        isOpen: Binding<Bool>,
        topSafeAreaInset: CGFloat = 0,
        @ViewBuilder menu: () -> Menu,
        @ViewBuilder content: () -> Content
    ) {
        _isOpen = isOpen
        self.topSafeAreaInset = topSafeAreaInset
        self.menu = menu()
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let contentOffset = SideMenuTransitionLayout.primaryContentOpenOffset(
                for: geometry.size.width
            )
            let resolvedTopSafeArea = SideMenuTransitionLayout.resolvedTopSafeArea(
                explicitTopSafeAreaInset: topSafeAreaInset,
                geometryTopSafeAreaInset: geometry.safeAreaInsets.top
            )
            let bottomSafeArea = max(0, geometry.safeAreaInsets.bottom)

            ZStack(alignment: .topLeading) {
                primaryContentLayer(offset: contentOffset)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .zIndex(SideMenuTransitionLayout.primaryContentZIndex)

                menuComposition(topSafeArea: resolvedTopSafeArea, bottomSafeArea: bottomSafeArea)
                    .ignoresSafeArea()
                    .zIndex(SideMenuTransitionLayout.menuZIndex)
            }
            .animation(
                SideMenuTransitionLayout.animation(reduceMotion: accessibilityReduceMotion),
                value: isOpen
            )
        }
    }

    // Rendered edge-to-edge (under the status bar and home indicator) so the
    // drawer and scrim cover the full screen. The safe-area insets are resolved
    // in the outer geometry (the expanded one reports zero) and handed to the
    // menu content through the environment.
    private func menuComposition(topSafeArea: CGFloat, bottomSafeArea: CGFloat) -> some View {
        GeometryReader { geometry in
            let menuWidth = SideMenuTransitionLayout.menuWidth(for: geometry.size.width)

            ZStack(alignment: .topLeading) {
                if isOpen {
                    backdropLayer()
                        .zIndex(SideMenuTransitionLayout.backdropZIndex)
                        .transition(.opacity)
                }

                menuLayer(
                    width: menuWidth,
                    height: geometry.size.height,
                    safeAreaInsets: EdgeInsets(
                        top: topSafeArea,
                        leading: 0,
                        bottom: bottomSafeArea,
                        trailing: 0
                    )
                )
                    .zIndex(SideMenuTransitionLayout.menuZIndex)
            }
        }
    }

    private func menuLayer(width: CGFloat, height: CGFloat, safeAreaInsets: EdgeInsets) -> some View {
        menu
            .environment(\.sideMenuPresentationIsOpen, isOpen)
            .environment(\.sideMenuSafeAreaInsets, safeAreaInsets)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(SideMenuTrailingRoundedShape(radius: SideMenuTransitionLayout.menuTrailingCornerRadius))
            .contentShape(SideMenuTrailingRoundedShape(radius: SideMenuTransitionLayout.menuTrailingCornerRadius))
            .shadow(color: .black.opacity(isOpen ? 0.18 : 0), radius: isOpen ? 22 : 0, x: 10, y: 16)
            .offset(x: isOpen ? 0 : -width * SideMenuTransitionLayout.menuClosedOffsetFraction)
            .opacity(isOpen ? 1 : SideMenuTransitionLayout.menuClosedOpacity)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }

    private func primaryContentLayer(offset: CGFloat) -> some View {
        content
            .disabled(isOpen)
            .scaleEffect(
                isOpen ? SideMenuTransitionLayout.primaryContentOpenScale : 1,
                anchor: .center
            )
            .offset(x: isOpen ? offset : 0)
            .blur(radius: isOpen ? SideMenuTransitionLayout.backdropBlurRadius : 0)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: isOpen ? SideMenuTransitionLayout.primaryContentOpenCornerRadius : 0,
                    style: .continuous
                )
            )
            .shadow(color: .black.opacity(isOpen ? 0.22 : 0), radius: isOpen ? 20 : 0, x: -8, y: 14)
    }

    private func backdropLayer() -> some View {
        Button {
            closeMenu()
        } label: {
            Rectangle()
                .fill(Color.black.opacity(SideMenuTransitionLayout.backdropOpacity))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss side menu")
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func closeMenu() {
        if let animation = SideMenuTransitionLayout.animation(reduceMotion: accessibilityReduceMotion) {
            withAnimation(animation) {
                isOpen = false
            }
        } else {
            isOpen = false
        }
    }
}

private struct SideMenuTrailingRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let clippedRadius = max(0, min(radius, rect.width / 2, rect.height / 2))
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - clippedRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + clippedRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - clippedRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - clippedRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()

        return path
    }
}

private struct SideMenuPresentationIsOpenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SideMenuSafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    var sideMenuPresentationIsOpen: Bool {
        get { self[SideMenuPresentationIsOpenKey.self] }
        set { self[SideMenuPresentationIsOpenKey.self] = newValue }
    }

    /// Screen safe-area insets the full-bleed side menu ignores; menu content
    /// uses these to keep controls clear of the status bar and home indicator.
    var sideMenuSafeAreaInsets: EdgeInsets {
        get { self[SideMenuSafeAreaInsetsKey.self] }
        set { self[SideMenuSafeAreaInsetsKey.self] = newValue }
    }
}
