import SwiftUI
import UIKit

struct BreakReminderQuote: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let author: String

    static func next(excluding excludedID: String?) -> BreakReminderQuote {
        let availableQuotes = all.filter { $0.id != excludedID }
        return availableQuotes.randomElement() ?? all[0]
    }

    private static let all: [BreakReminderQuote] = [
        BreakReminderQuote(
            id: "gandhi_speed",
            text: "There is more to life than increasing its speed.",
            author: "Mahatma Gandhi"
        ),
        BreakReminderQuote(
            id: "tolstoy_time_patience",
            text: "The strongest of all warriors are these two - Time and Patience.",
            author: "Leo Tolstoy"
        ),
        BreakReminderQuote(
            id: "pericles_counselor",
            text: "Time is the wisest counselor of all.",
            author: "Pericles"
        ),
        BreakReminderQuote(
            id: "curtin_not_wasted",
            text: "Time you enjoy wasting is not wasted time.",
            author: "Marthe Troly-Curtin"
        ),
        BreakReminderQuote(
            id: "emerson_patience",
            text: "Adopt the pace of nature: her secret is patience.",
            author: "Ralph Waldo Emerson"
        )
    ]
}

@MainActor
final class BreakReminderCoordinator: ObservableObject {
    @Published private(set) var presentedQuote: BreakReminderQuote?

    private var timerTask: Task<Void, Never>?
    private var scenePhase: ScenePhase = .inactive
    private var interval: BreakReminderInterval = .off
    private var isEnabled = false
    private var lastQuoteID: String?

    private static let presentationAnimation = Animation.spring(response: 0.42, dampingFraction: 0.88)

    deinit {
        timerTask?.cancel()
    }

    func update(
        isEnabled: Bool,
        interval: BreakReminderInterval,
        scenePhase: ScenePhase
    ) {
        let configurationChanged =
            self.isEnabled != isEnabled ||
            self.interval != interval ||
            self.scenePhase != scenePhase

        self.isEnabled = isEnabled
        self.interval = interval
        self.scenePhase = scenePhase

        guard configurationChanged else { return }

        guard isEnabled, scenePhase == .active, interval.duration != nil else {
            cancelTimer(resetPresentation: true)
            return
        }

        guard presentedQuote == nil else { return }
        restartTimer()
    }

    func dismissReminder() {
        withAnimation(Self.presentationAnimation) {
            presentedQuote = nil
        }
        restartTimer()
    }

    func completeTakeBreak() {
        timerTask?.cancel()
        timerTask = nil

        withAnimation(Self.presentationAnimation) {
            presentedQuote = nil
        }

        BreakReminderAppCloser.closeApp()
    }

    func presentPreviewReminder() {
        timerTask?.cancel()
        timerTask = nil

        let quote = BreakReminderQuote.next(excluding: lastQuoteID)
        lastQuoteID = quote.id

        withAnimation(Self.presentationAnimation) {
            presentedQuote = quote
        }
    }

    private func restartTimer() {
        timerTask?.cancel()
        timerTask = nil

        guard isEnabled,
              scenePhase == .active,
              presentedQuote == nil,
              let duration = interval.duration else {
            return
        }

        timerTask = Task { [weak self] in
            let nanoseconds = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard self.isEnabled,
                      self.scenePhase == .active,
                      self.presentedQuote == nil,
                      self.interval.duration != nil else {
                    return
                }

                let quote = BreakReminderQuote.next(excluding: self.lastQuoteID)
                self.lastQuoteID = quote.id
                self.timerTask = nil

                withAnimation(Self.presentationAnimation) {
                    self.presentedQuote = quote
                }
            }
        }
    }

    private func cancelTimer(resetPresentation: Bool) {
        timerTask?.cancel()
        timerTask = nil

        guard resetPresentation, presentedQuote != nil else { return }

        withAnimation(Self.presentationAnimation) {
            presentedQuote = nil
        }
    }
}

struct BreakReminderOverlayHost: View {
    @ObservedObject var coordinator: BreakReminderCoordinator

    var body: some View {
        Group {
            if let quote = coordinator.presentedQuote {
                BreakReminderOverlayPresentation(
                    quote: quote,
                    onContinue: { coordinator.dismissReminder() },
                    onTakeBreakCompleted: { coordinator.completeTakeBreak() }
                )
            } else {
                Color.clear
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(coordinator.presentedQuote != nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: coordinator.presentedQuote?.id)
    }
}

struct BreakReminderOverlayPresentation: View {
    @Environment(\.colorScheme) private var colorScheme

    let quote: BreakReminderQuote
    let onContinue: () -> Void
    let onTakeBreakCompleted: () -> Void

    init(
        quote: BreakReminderQuote,
        onContinue: @escaping () -> Void,
        onTakeBreakCompleted: @escaping () -> Void
    ) {
        self.quote = quote
        self.onContinue = onContinue
        self.onTakeBreakCompleted = onTakeBreakCompleted
    }

    init(
        quote: BreakReminderQuote,
        onDismiss: @escaping () -> Void
    ) {
        self.quote = quote
        self.onContinue = onDismiss
        self.onTakeBreakCompleted = onDismiss
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(colorScheme == .dark ? 0.28 : 0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .transition(.opacity)

                BreakReminderSheet(
                    quote: quote,
                    onContinue: onContinue,
                    onTakeBreakCompleted: onTakeBreakCompleted
                )
                .padding(.horizontal, 12)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct BreakReminderSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var choiceState: BreakReminderChoiceState = .choice
    @State private var takeBreakTask: Task<Void, Never>?

    let quote: BreakReminderQuote
    let onContinue: () -> Void
    let onTakeBreakCompleted: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(reminderBackgroundColor)

            reminderArtwork

            centeredContent
                .padding(.horizontal, 26)
        }
        .frame(maxWidth: 540, alignment: .center)
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(reminderBorderColor, lineWidth: 0.9)
        }
        .onDisappear {
            takeBreakTask?.cancel()
            takeBreakTask = nil
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.12), radius: 22, x: 0, y: 10)
        .accessibilityElement(children: .contain)
    }

    private var reminderArtwork: some View {
        Image(BreakReminderChoiceLayout.artworkImageName)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.black.opacity(colorScheme == .dark ? 0.10 : 0.02),
                        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.15),
                        Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var centeredContent: some View {
        ZStack {
            if choiceState == .choice {
                choiceContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        )
                    )
            } else {
                successContent
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(contentAnimation, value: choiceState)
    }

    private var choiceContent: some View {
        VStack(spacing: 18) {
            Text(BreakReminderChoiceLayout.promptText)
                .font(.title2.weight(.semibold))
                .foregroundStyle(reminderTextColor)
                .multilineTextAlignment(.center)
                .shadow(color: reminderTextShadowColor, radius: 8, x: 0, y: 3)

            HStack(spacing: 10) {
                reminderButton(
                    title: BreakReminderChoiceLayout.takeBreakButtonTitle,
                    role: .primary,
                    action: handleTakeBreak
                )

                reminderButton(
                    title: BreakReminderChoiceLayout.continueButtonTitle,
                    role: .secondary,
                    action: onContinue
                )
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(choiceState == .choice)
    }

    private var successContent: some View {
        Text(BreakReminderChoiceLayout.successText)
            .font(.title2.weight(.semibold))
            .foregroundStyle(reminderTextColor)
            .multilineTextAlignment(.center)
            .shadow(color: reminderTextShadowColor, radius: 8, x: 0, y: 3)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func reminderButton(
        title: String,
        role: BreakReminderButtonRole,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.84)
                .foregroundStyle(role.foregroundColor(colorScheme: colorScheme))
                .frame(minWidth: 112)
                .frame(height: 38)
                .padding(.horizontal, 8)
                .background(role.backgroundColor(colorScheme: colorScheme), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(role.borderColor(colorScheme: colorScheme), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func handleTakeBreak() {
        guard choiceState == .choice else { return }

        withAnimation(contentAnimation) {
            choiceState = .success
        }

        takeBreakTask?.cancel()
        takeBreakTask = Task {
            try? await Task.sleep(nanoseconds: BreakReminderChoiceLayout.takeBreakCloseDelayNanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                onTakeBreakCompleted()
            }
        }
    }

    private var contentAnimation: Animation {
        accessibilityReduceMotion
            ? .linear(duration: 0)
            : .easeInOut(duration: 0.24)
    }

    private var reminderBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var reminderBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }

    private var reminderTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.white.opacity(0.96)
    }

    private var reminderTextShadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.28)
            : Color.black.opacity(0.18)
    }
}

enum BreakReminderChoiceState: Equatable {
    case choice
    case success
}

enum BreakReminderChoiceLayout {
    static let artworkImageName = "manage-accounts-background"
    static let promptText = "Take a break or continue?"
    static let takeBreakButtonTitle = "Take a break"
    static let continueButtonTitle = "Continue"
    static let successText = "Wise choice! Enjoy!"
    static let takeBreakCloseDelay: TimeInterval = 4

    static var takeBreakCloseDelayNanoseconds: UInt64 {
        UInt64(takeBreakCloseDelay * 1_000_000_000)
    }
}

enum BreakReminderButtonRole {
    case primary
    case secondary

    func foregroundColor(colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary:
            return colorScheme == .dark ? .black.opacity(0.86) : .black.opacity(0.82)
        case .secondary:
            return .white.opacity(colorScheme == .dark ? 0.88 : 0.92)
        }
    }

    func backgroundColor(colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary:
            return .white.opacity(colorScheme == .dark ? 0.84 : 0.88)
        case .secondary:
            return .black.opacity(colorScheme == .dark ? 0.22 : 0.24)
        }
    }

    func borderColor(colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary:
            return .white.opacity(colorScheme == .dark ? 0.52 : 0.64)
        case .secondary:
            return .white.opacity(colorScheme == .dark ? 0.22 : 0.38)
        }
    }
}

enum BreakReminderAppCloser {
    @MainActor
    static func closeApp() {
        _ = UIApplication.shared.perform(NSSelectorFromString("suspend"))
    }
}
