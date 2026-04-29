import SwiftUI

struct AppLaunchSplashOverlay: View {
    private static let valuesMessages: [String] = [
        "No emails, no passwords, how wonderful is that?",
        "We couldn't delete your notes if we tried.",
        "No rage bait. Just what you choose to see.",
        "Family, community, friends. The things that truly matter.",
        "No follow games. Just human connection.",
        "Noise is infinite. Meaning is scarce.",
        "Convenience trades depth for distraction.",
        "Urgency is often manufactured. Importance rarely is.",
        "The trivial expands to fill unguarded time.",
        "Try turning off notifications to take back your time.",
        "Fewer strong connections over many shallow ones.",
        "Autopilot atrophies the mind. It requires challenge.",
        "Synthetic discourse crowds out reality.",
        "Coercion is often disguised as concern.",
        "Fear bypasses scrutiny. Do not fear.",
        "Be the change you want to see.",
        "Time is the ultimate currency. How are you spending yours?"
    ]

    let selection: WelcomeArtworkSelection
    private let message: String

    init(selection: WelcomeArtworkSelection) {
        self.selection = selection
        message = Self.valuesMessages.randomElement() ?? Self.valuesMessages[0]
    }

    var body: some View {
        ZStack {
            WelcomeArtworkBackgroundView(
                artwork: selection.artwork,
                overlayOpacity: 0.20
            )

            VStack(spacing: 14) {
                Spacer()

                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.90))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 26)
                    .frame(maxWidth: 320, minHeight: 54)
                    .shadow(color: Color.black.opacity(0.18), radius: 10, y: 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 24)
            .padding(.bottom, 92)
        }
        .transition(
            .asymmetric(
                insertion: .opacity,
                removal: .move(edge: .top).combined(with: .opacity)
            )
        )
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}
