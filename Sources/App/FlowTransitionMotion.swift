import SwiftUI

enum FlowTransitionMotion {
    enum Timing {
        case badgePop
        case textSwap
        case sidePanelOpen
        case numberPop
        case iconSwap
        case feedRevealScroll
        case feedInsertion
    }

    static func duration(_ timing: Timing, reduceMotion: Bool) -> TimeInterval {
        guard !reduceMotion else { return 0 }

        switch timing {
        case .badgePop:
            return 0.5
        case .textSwap:
            return 0.2
        case .sidePanelOpen:
            return 0.4
        case .numberPop:
            return 0.5
        case .iconSwap:
            return 0.2
        case .feedRevealScroll:
            return 0.24
        case .feedInsertion:
            return 0.34
        }
    }

    static func badgeAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: duration(.badgePop, reduceMotion: false), dampingFraction: 0.72)
    }

    static func textSwapAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: duration(.textSwap, reduceMotion: false))
    }

    static func sidePanelAnimation(reduceMotion: Bool) -> Animation? {
        SideMenuTransitionLayout.animation(reduceMotion: reduceMotion)
    }

    static func numberPopAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: duration(.numberPop, reduceMotion: false), dampingFraction: 0.68)
    }

    static func iconSwapAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: duration(.iconSwap, reduceMotion: false))
    }

    static func feedRevealScrollAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: duration(.feedRevealScroll, reduceMotion: false))
    }

    static func feedInsertionAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: duration(.feedInsertion, reduceMotion: false))
    }

    static func notificationBadgeTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 0.22, x: -8.2, y: 12.4, blur: 2),
                identity: .identity
            ),
            removal: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 0.16, x: 0, y: 0, blur: 2),
                identity: .identity
            )
        )
    }

    static func textStateSwapTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 1, x: 0, y: 8, blur: 2),
                identity: .identity
            ),
            removal: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 1, x: 0, y: -8, blur: 2),
                identity: .identity
            )
        )
    }

    static func sidePanelTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 1, x: -42, y: 0, blur: 2),
                identity: .identity
            ),
            removal: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 1, x: -28, y: 0, blur: 1),
                identity: .identity
            )
        )
    }

    static func numberPopTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 0.96, x: 0, y: 8, blur: 2),
                identity: .identity
            ),
            removal: .opacity
        )
    }

    static func iconSwapTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 0.25, x: 0, y: 0, blur: 2),
                identity: .identity
            ),
            removal: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 0.25, x: 0, y: 0, blur: 2),
                identity: .identity
            )
        )
    }

    static func feedItemInsertionTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .modifier(
                active: FlowTransitionState(opacity: 0, scale: 1, x: 0, y: -10, blur: 1),
                identity: .identity
            ),
            removal: .opacity
        )
    }
}

private struct FlowTransitionState: ViewModifier {
    static let identity = FlowTransitionState(opacity: 1, scale: 1, x: 0, y: 0, blur: 0)

    let opacity: Double
    let scale: CGFloat
    let x: CGFloat
    let y: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(x: x, y: y)
            .blur(radius: blur)
    }
}
