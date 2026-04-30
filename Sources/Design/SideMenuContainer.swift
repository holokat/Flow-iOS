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
    static let clipsCompositionToContainerBounds = true

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

    static func menuTopOffset(topSafeAreaInset: CGFloat) -> CGFloat {
        max(0, topSafeAreaInset)
    }

    static func menuHeight(for containerHeight: CGFloat, topSafeAreaInset: CGFloat) -> CGFloat {
        max(0, containerHeight - menuTopOffset(topSafeAreaInset: topSafeAreaInset))
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
            let menuWidth = SideMenuTransitionLayout.menuWidth(for: geometry.size.width)
            let resolvedTopSafeArea = SideMenuTransitionLayout.resolvedTopSafeArea(
                explicitTopSafeAreaInset: topSafeAreaInset,
                geometryTopSafeAreaInset: geometry.safeAreaInsets.top
            )
            let menuTopOffset = SideMenuTransitionLayout.menuTopOffset(
                topSafeAreaInset: resolvedTopSafeArea
            )
            let menuHeight = SideMenuTransitionLayout.menuHeight(
                for: geometry.size.height,
                topSafeAreaInset: resolvedTopSafeArea
            )
            let contentOffset = SideMenuTransitionLayout.primaryContentOpenOffset(
                for: geometry.size.width
            )

            ZStack(alignment: .leading) {
                primaryContentLayer(offset: contentOffset)
                    .zIndex(SideMenuTransitionLayout.primaryContentZIndex)

                if isOpen {
                    backdropLayer()
                        .zIndex(SideMenuTransitionLayout.backdropZIndex)
                        .transition(.opacity)
                }

                menuLayer(
                    width: menuWidth,
                    height: menuHeight,
                    topOffset: menuTopOffset
                )
                    .zIndex(SideMenuTransitionLayout.menuZIndex)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(
                SideMenuTransitionLayout.animation(reduceMotion: accessibilityReduceMotion),
                value: isOpen
            )
        }
    }

    private func menuLayer(width: CGFloat, height: CGFloat, topOffset: CGFloat) -> some View {
        menu
            .environment(\.sideMenuPresentationIsOpen, isOpen)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(SideMenuTrailingRoundedShape(radius: SideMenuTransitionLayout.menuTrailingCornerRadius))
            .contentShape(SideMenuTrailingRoundedShape(radius: SideMenuTransitionLayout.menuTrailingCornerRadius))
            .shadow(color: .black.opacity(isOpen ? 0.18 : 0), radius: isOpen ? 22 : 0, x: 10, y: 16)
            .offset(
                x: isOpen ? 0 : -width * SideMenuTransitionLayout.menuClosedOffsetFraction,
                y: topOffset
            )
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

extension EnvironmentValues {
    var sideMenuPresentationIsOpen: Bool {
        get { self[SideMenuPresentationIsOpenKey.self] }
        set { self[SideMenuPresentationIsOpenKey.self] = newValue }
    }
}
