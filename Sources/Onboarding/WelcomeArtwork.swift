import SwiftUI

enum WelcomeArtwork: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cityConversation = "welcome-scene-city"
    case cozyBedroom = "welcome-scene-bedroom"
    case cafeConversation = "welcome-scene-cafe"

    var id: String { rawValue }

    var assetName: String { rawValue }
}

struct WelcomeArtworkSelection: Hashable, Sendable {
    let artwork: WelcomeArtwork
    let primaryColorOption: AppPrimaryColorOption

    static func random() -> WelcomeArtworkSelection {
        WelcomeArtworkSelection(
            artwork: WelcomeArtwork.allCases.randomElement() ?? .cityConversation,
            primaryColorOption: AppPrimaryColorOption.random()
        )
    }
}

struct WelcomeArtworkBackgroundView: View {
    let artwork: WelcomeArtwork
    var overlayOpacity: Double = 0.22

    var body: some View {
        ZStack {
            Image(artwork.assetName)
                .resizable()
                .scaledToFill()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(overlayOpacity * 0.5),
                    Color.black.opacity(overlayOpacity)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
