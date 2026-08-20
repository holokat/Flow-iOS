import Foundation
import SwiftUI
import UIKit

enum UserFacingCopy {
    static func sanitizingTechnicalTerms(_ message: String) -> String {
        var result = message.replacingOccurrences(
            of: #"\bNIP(?:[-\s]?\d+)?\b"#,
            with: "message format",
            options: [.regularExpression, .caseInsensitive]
        )

        let replacements: [(technical: String, plain: String)] = [
            ("nprofile", "account address"),
            ("pubkey", "account address"),
            ("npub", "account address"),
            ("nsec", "account access"),
            ("private key", "recovery key"),
            ("gift wrap", "private message"),
            ("rumor", "private message"),
            ("relays", "sources"),
            ("relay", "source"),
            ("Nostr", "network")
        ]

        for replacement in replacements {
            let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: replacement.technical))\b"#
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement.plain,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: " .", with: ".")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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

    static func hierarchyAnimation(index: Int, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let boundedIndex = min(max(index, 0), 7)
        return .spring(response: 0.52, dampingFraction: 0.9)
            .delay(Double(boundedIndex) * 0.052)
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

enum FlowHorizontalPagingBehavior {
    static let minimumDistance: CGFloat = 10
    static let axisDominanceRatio: CGFloat = 1.18
    static let commitDistance: CGFloat = 44
    static let projectedCommitDistance: CGFloat = 76
    static let backNavigationEdgeWidth: CGFloat = 28

    static func isHorizontallyDominant(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * axisDominanceRatio
    }

    static func isVerticallyDominant(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width) * axisDominanceRatio
    }

    static func reservesGestureForBackNavigation(
        startX: CGFloat,
        translation: CGFloat
    ) -> Bool {
        startX <= backNavigationEdgeWidth && translation > 0
    }

    static func shouldBeginPaging(
        currentIndex: Int,
        itemCount: Int,
        startX: CGFloat,
        horizontalDirection: CGFloat,
        handsLeadingBoundaryToParent: Bool
    ) -> Bool {
        guard itemCount > 1,
              currentIndex >= 0,
              currentIndex < itemCount,
              horizontalDirection != 0 else {
            return false
        }

        if reservesGestureForBackNavigation(
            startX: startX,
            translation: horizontalDirection
        ) {
            return false
        }

        if handsLeadingBoundaryToParent,
           currentIndex == 0,
           horizontalDirection > 0 {
            return false
        }

        let candidate = horizontalDirection < 0 ? currentIndex + 1 : currentIndex - 1
        return (0..<itemCount).contains(candidate)
    }

    static func targetIndex(
        currentIndex: Int,
        itemCount: Int,
        translation: CGFloat,
        predictedEndTranslation: CGFloat
    ) -> Int? {
        guard itemCount > 1,
              currentIndex >= 0,
              currentIndex < itemCount else {
            return nil
        }

        let commits = abs(translation) >= commitDistance
            || abs(predictedEndTranslation) >= projectedCommitDistance
        guard commits else { return nil }

        let direction = abs(predictedEndTranslation) > abs(translation)
            ? predictedEndTranslation
            : translation
        let candidate = direction < 0 ? currentIndex + 1 : currentIndex - 1
        guard (0..<itemCount).contains(candidate) else { return nil }
        return candidate
    }

    static func selectionAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .snappy(duration: 0.2, extraBounce: 0)
    }

    static func contentAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 0.16)
    }
}

private struct FlowHorizontalPagingModifier<Selection: Hashable>: ViewModifier {
    @Binding var selection: Selection
    let items: [Selection]
    let isEnabled: Bool
    let handsLeadingBoundaryToParent: Bool

    func body(content: Content) -> some View {
        content
            .background {
                FlowHorizontalPagingGestureBridge(
                    selection: $selection,
                    items: items,
                    isEnabled: isEnabled,
                    handsLeadingBoundaryToParent: handsLeadingBoundaryToParent
                )
            }
    }
}

private struct FlowHorizontalPagingGestureBridge<Selection: Hashable>: UIViewRepresentable {
    @Binding var selection: Selection
    let items: [Selection]
    let isEnabled: Bool
    let handsLeadingBoundaryToParent: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onSuperviewChange = { [weak coordinator = context.coordinator] attachmentView in
            coordinator?.attachGestureIfPossible(from: attachmentView)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.panGestureRecognizer.isEnabled = isEnabled
        context.coordinator.attachGestureIfPossible(from: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        uiView.onSuperviewChange = nil
        coordinator.detachGesture()
    }

    final class AttachmentView: UIView {
        var onSuperviewChange: ((AttachmentView) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onSuperviewChange?(self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: FlowHorizontalPagingGestureBridge
        let panGestureRecognizer = UIPanGestureRecognizer()

        private weak var gestureHostView: UIView?

        init(configuration: FlowHorizontalPagingGestureBridge) {
            self.configuration = configuration
            super.init()

            panGestureRecognizer.delegate = self
            panGestureRecognizer.maximumNumberOfTouches = 1
            panGestureRecognizer.cancelsTouchesInView = false
            panGestureRecognizer.delaysTouchesBegan = false
            panGestureRecognizer.delaysTouchesEnded = false
            panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        func attachGestureIfPossible(from attachmentView: UIView) {
            guard let hostView = attachmentView.superview,
                  gestureHostView !== hostView else {
                return
            }

            detachGesture()
            hostView.addGestureRecognizer(panGestureRecognizer)
            gestureHostView = hostView
        }

        func detachGesture() {
            gestureHostView?.removeGestureRecognizer(panGestureRecognizer)
            gestureHostView = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard configuration.isEnabled,
                  configuration.items.count > 1,
                  let hostView = gestureHostView,
                  let currentIndex = configuration.items.firstIndex(
                    of: configuration.selection
                ) else {
                return false
            }

            let translation = panGestureRecognizer.translation(in: hostView)
            let velocity = panGestureRecognizer.velocity(in: hostView)
            let direction = abs(velocity.x) > 1 ? velocity.x : translation.x
            let intent = CGSize(
                width: abs(velocity.x) > 1 ? velocity.x : translation.x,
                height: abs(velocity.y) > 1 ? velocity.y : translation.y
            )
            guard hypot(translation.x, translation.y)
                    >= FlowHorizontalPagingBehavior.minimumDistance,
                  FlowHorizontalPagingBehavior.isHorizontallyDominant(intent) else {
                return false
            }

            let startX = panGestureRecognizer.location(in: hostView).x - translation.x
            return FlowHorizontalPagingBehavior.shouldBeginPaging(
                currentIndex: currentIndex,
                itemCount: configuration.items.count,
                startX: startX,
                horizontalDirection: direction,
                handsLeadingBoundaryToParent: configuration.handsLeadingBoundaryToParent
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended,
                  let hostView = gestureHostView,
                  let currentIndex = configuration.items.firstIndex(
                    of: configuration.selection
                  ) else {
                return
            }

            let translation = recognizer.translation(in: hostView).x
            let projectedTranslation = translation
                + (recognizer.velocity(in: hostView).x * 0.14)
            guard let targetIndex = FlowHorizontalPagingBehavior.targetIndex(
                currentIndex: currentIndex,
                itemCount: configuration.items.count,
                translation: translation,
                predictedEndTranslation: projectedTranslation
            ) else {
                return
            }

            configuration.selection = configuration.items[targetIndex]
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

private struct FlowPeerTabContentModifier<Selection: Hashable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let selection: Selection

    func body(content: Content) -> some View {
        content
            .id(selection)
            .transition(accessibilityReduceMotion ? .identity : .opacity)
            .animation(
                FlowHorizontalPagingBehavior.contentAnimation(
                    reduceMotion: accessibilityReduceMotion
                ),
                value: selection
            )
    }
}

private struct FlowInteractiveBackSwipeResolver: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ResolverViewController {
        let viewController = ResolverViewController()
        viewController.onResolveNavigationController = {
            [weak viewController, weak coordinator = context.coordinator] in
            guard let viewController else { return }
            coordinator?.enableInteractivePop(from: viewController)
        }
        return viewController
    }

    func updateUIViewController(_ viewController: ResolverViewController, context: Context) {
        viewController.onResolveNavigationController = {
            [weak viewController, weak coordinator = context.coordinator] in
            guard let viewController else { return }
            coordinator?.enableInteractivePop(from: viewController)
        }
        context.coordinator.enableInteractivePop(from: viewController)
    }

    static func dismantleUIViewController(
        _ uiViewController: ResolverViewController,
        coordinator: Coordinator
    ) {
        uiViewController.onResolveNavigationController = nil
        coordinator.detach()
    }

    final class ResolverViewController: UIViewController {
        var onResolveNavigationController: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onResolveNavigationController?()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            onResolveNavigationController?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigationController: UINavigationController?

        func enableInteractivePop(from resolver: UIViewController) {
            DispatchQueue.main.async { [weak self, weak resolver] in
                guard let self,
                      let navigationController = resolver?.navigationController,
                      let recognizer = navigationController.interactivePopGestureRecognizer else {
                    return
                }

                if self.navigationController !== navigationController {
                    self.detach()
                    self.navigationController = navigationController
                }
                recognizer.delegate = self
                recognizer.isEnabled = navigationController.viewControllers.count > 1
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            return navigationController.viewControllers.count > 1
                && navigationController.transitionCoordinator == nil
        }

        func detach() {
            guard let recognizer = navigationController?.interactivePopGestureRecognizer else {
                navigationController = nil
                return
            }
            if recognizer.delegate === self {
                recognizer.delegate = nil
            }
            navigationController = nil
        }
    }
}

extension View {
    func flowHorizontalPaging<Selection: Hashable>(
        selection: Binding<Selection>,
        items: [Selection],
        isEnabled: Bool = true,
        handsLeadingBoundaryToParent: Bool = false
    ) -> some View {
        modifier(
            FlowHorizontalPagingModifier(
                selection: selection,
                items: items,
                isEnabled: isEnabled,
                handsLeadingBoundaryToParent: handsLeadingBoundaryToParent
            )
        )
    }

    func flowInteractiveBackSwipe() -> some View {
        background {
            FlowInteractiveBackSwipeResolver()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    func flowPeerTabContentTransition<Selection: Hashable>(
        selection: Selection
    ) -> some View {
        modifier(FlowPeerTabContentModifier(selection: selection))
    }
}

struct FlowPressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !accessibilityReduceMotion ? 0.96 : 1)
            .animation(
                accessibilityReduceMotion
                    ? nil
                    : .spring(response: 0.22, dampingFraction: 0.78),
                value: configuration.isPressed
            )
    }
}

private struct FlowHierarchyEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isPresented = false

    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(isPresented || accessibilityReduceMotion ? 1 : 0)
            .scaleEffect(isPresented || accessibilityReduceMotion ? 1 : 0.985, anchor: .top)
            .offset(y: isPresented || accessibilityReduceMotion ? 0 : 14)
            .onAppear {
                guard !isPresented else { return }
                if let animation = FlowTransitionMotion.hierarchyAnimation(
                    index: index,
                    reduceMotion: accessibilityReduceMotion
                ) {
                    withAnimation(animation) {
                        isPresented = true
                    }
                } else {
                    isPresented = true
                }
            }
    }
}

extension View {
    func flowHierarchyEntrance(index: Int) -> some View {
        modifier(FlowHierarchyEntranceModifier(index: index))
    }
}

enum FollowCelebrationMotion {
    static let particleCount = 8

    static func nextTrigger(
        current: Int,
        didFollow: Bool,
        didChange: Bool
    ) -> Int {
        guard didFollow, didChange else { return current }
        return current &+ 1
    }
}

private struct FollowCelebrationAnimationValues {
    var buttonScale: CGFloat = 1
    var burstProgress: CGFloat = 1
}

private struct FollowCelebrationBurst: View {
    let progress: CGFloat
    let accentColor: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(accentColor.opacity(haloOpacity), lineWidth: 1.4)
                .frame(width: 48, height: 48)
                .scaleEffect(0.68 + (progress * 0.64))

            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.white)
                .shadow(color: accentColor.opacity(0.75), radius: 4)
                .scaleEffect(0.25 + (progress * 0.9))
                .opacity(centerSparkleOpacity)

            ForEach(0..<FollowCelebrationMotion.particleCount, id: \.self) { index in
                particle(at: index)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func particle(at index: Int) -> some View {
        let stagger = CGFloat(index) * 0.035
        let adjustedProgress = min(1, max(0, (progress - stagger) / (1 - stagger)))
        let angle = (Double(index) / Double(FollowCelebrationMotion.particleCount)) * (.pi * 2) - (.pi / 2)
        let distance = CGFloat(index.isMultiple(of: 2) ? 36 : 31)
        let x = CGFloat(cos(angle)) * distance * adjustedProgress
        let y = CGFloat(sin(angle)) * distance * adjustedProgress

        Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "circle.fill")
            .font(.system(size: index.isMultiple(of: 2) ? 11 : 6, weight: .bold))
            .foregroundStyle(particleColor(at: index))
            .scaleEffect(0.25 + (adjustedProgress * 0.95))
            .rotationEffect(.degrees(Double(index * 24) + (Double(adjustedProgress) * 70)))
            .offset(x: x, y: y)
            .opacity(particleOpacity(for: adjustedProgress))
    }

    private var haloOpacity: Double {
        let fadeIn = min(Double(progress) * 6, 1)
        let fadeOut = max(0, 1 - Double(progress))
        return fadeIn * fadeOut * 0.42
    }

    private var centerSparkleOpacity: Double {
        let value = Double(progress)
        let fadeIn = min(value * 9, 1)
        let fadeOut = min(max((0.72 - value) * 4, 0), 1)
        return fadeIn * fadeOut
    }

    private func particleOpacity(for adjustedProgress: CGFloat) -> Double {
        let value = Double(adjustedProgress)
        let fadeIn = min(value * 7, 1)
        let fadeOut = min(max((1 - value) * 3.2, 0), 1)
        return fadeIn * fadeOut
    }

    private func particleColor(at index: Int) -> Color {
        switch index % 3 {
        case 0:
            return accentColor
        case 1:
            return Color(red: 1, green: 0.72, blue: 0.16)
        default:
            return Color(red: 0.98, green: 0.36, blue: 0.68)
        }
    }
}

private struct FollowCelebrationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let trigger: Int
    let accentColor: Color

    func body(content: Content) -> some View {
        let reduceMotion = accessibilityReduceMotion

        return content
            .keyframeAnimator(
                initialValue: FollowCelebrationAnimationValues(),
                trigger: trigger
            ) { view, values in
                view
                    .scaleEffect(reduceMotion ? 1 : values.buttonScale)
                    .overlay {
                        if !reduceMotion {
                            FollowCelebrationBurst(
                                progress: values.burstProgress,
                                accentColor: accentColor
                            )
                        }
                    }
            } keyframes: { _ in
                KeyframeTrack(\.buttonScale) {
                    LinearKeyframe(1, duration: 0)
                    SpringKeyframe(
                        1.12,
                        duration: 0.18,
                        spring: .bouncy(duration: 0.32, extraBounce: 0.06)
                    )
                    SpringKeyframe(
                        1,
                        duration: 0.3,
                        spring: .snappy(duration: 0.28)
                    )
                }

                KeyframeTrack(\.burstProgress) {
                    LinearKeyframe(0, duration: 0)
                    CubicKeyframe(1, duration: 0.52)
                }
            }
            .overlay {
                if reduceMotion {
                    FollowCelebrationReducedMotionFeedback(
                        trigger: trigger,
                        accentColor: accentColor
                    )
                }
            }
            .sensoryFeedback(
                .impact(weight: .light, intensity: 0.85),
                trigger: trigger
            )
    }
}

private struct FollowCelebrationReducedMotionFeedback: View {
    let trigger: Int
    let accentColor: Color

    @State private var isVisible = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(accentColor)
            .padding(6)
            .background(.ultraThinMaterial, in: Circle())
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: trigger) { oldValue, newValue in
                guard newValue != oldValue else { return }
                isVisible = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(420))
                    guard trigger == newValue else { return }
                    isVisible = false
                }
            }
    }
}

extension View {
    func followCelebration(trigger: Int, accentColor: Color) -> some View {
        modifier(
            FollowCelebrationModifier(
                trigger: trigger,
                accentColor: accentColor
            )
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
