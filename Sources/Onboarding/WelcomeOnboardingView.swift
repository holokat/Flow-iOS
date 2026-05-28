import SwiftUI

struct WelcomeOnboardingView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @State private var presentedAuthTab: AuthSheetTab?
    @State private var hasAnimatedIn = false
    @State private var welcomeSelection = WelcomeArtworkSelection.initial()

    var body: some View {
        ZStack {
            WelcomeScratchRevealBackgroundView(
                initialArtwork: welcomeSelection.artwork,
                overlayOpacity: 0.28
            )

            VStack(spacing: 0) {
                Spacer(minLength: 52)

                VStack(spacing: 14) {
                    Text("Halo")
                        .font(.custom("SF Pro Display", size: 56).weight(.bold))
                        .foregroundStyle(.white.opacity(0.97))
                        .kerning(-1.1)
                        .shadow(color: Color.black.opacity(0.40), radius: 20, y: 10)
                        .shadow(color: Color.black.opacity(0.24), radius: 2, y: 1)

                    Text("A calmer place for conversations.")
                        .font(.custom("SF Pro Display", size: 24).weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .shadow(color: Color.black.opacity(0.36), radius: 16, y: 8)
                        .shadow(color: Color.black.opacity(0.22), radius: 2, y: 1)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background {
                    welcomeHeroTitleContrastScrim
                }
                .padding(.horizontal, 32)
                .opacity(hasAnimatedIn ? 1 : 0)
                .offset(y: hasAnimatedIn ? 0 : 22)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 32)
            .allowsHitTesting(false)

            welcomeActions
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 52)
        }
        .task {
            guard !hasAnimatedIn else { return }
            try? await Task.sleep(nanoseconds: 140_000_000)
            withAnimation(.spring(response: 0.82, dampingFraction: 0.9)) {
                hasAnimatedIn = true
            }
        }
        .fullScreenCover(item: $presentedAuthTab) { selectedTab in
            AuthSheetView(
                initialTab: selectedTab,
                availableTabs: [.signUp, .signIn],
                signUpSeedPrimaryColorOption: welcomeSelection.primaryColorOption,
                signUpSeedTheme: appSettings.theme
            )
            .id(selectedTab)
            .environmentObject(auth)
            .environmentObject(appSettings)
            .environmentObject(relaySettings)
        }
    }

    private var welcomeHeroTitleContrastScrim: some View {
        LinearGradient(
            colors: [
                Color.clear,
                Color.black.opacity(0.32),
                Color.black.opacity(0.26),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .blur(radius: 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func openAuth(tab: AuthSheetTab) {
        presentedAuthTab = tab
    }

    private var welcomeActions: some View {
        VStack(spacing: 12) {
            Button {
                openAuth(tab: .signUp)
            } label: {
                welcomeButtonLabel("Get Started")
                    .foregroundStyle(buttonForegroundColor)
                    .background(
                        Capsule(style: .continuous)
                            .fill(welcomeSelection.primaryColorOption.color)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                    }
                    .shadow(color: Color.black.opacity(0.22), radius: 18, y: 10)
            }
            .buttonStyle(.plain)
            .opacity(hasAnimatedIn ? 1 : 0)
            .offset(y: hasAnimatedIn ? 0 : 28)

            Button {
                openAuth(tab: .signIn)
            } label: {
                welcomeButtonLabel("I Already Have a Key")
                    .foregroundStyle(.white)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.16))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    }
                    .shadow(color: Color.black.opacity(0.14), radius: 16, y: 8)
            }
            .buttonStyle(.plain)
            .opacity(hasAnimatedIn ? 1 : 0)
            .offset(y: hasAnimatedIn ? 0 : 34)
        }
    }

    private var buttonForegroundColor: Color {
        let resolved = UIColor(welcomeSelection.primaryColorOption.color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .white
        }
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.68 ? .black : .white
    }

    private func welcomeButtonLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
    }
}
