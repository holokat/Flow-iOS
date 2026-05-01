import SwiftUI

struct NoteMediaPlaceholderView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let systemImage: String
    let text: String
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    placeholderContent(isActionable: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Loads media for this note")
            } else {
                placeholderContent(isActionable: false)
            }
        }
    }

    private func placeholderContent(isActionable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isActionable ? appSettings.themeIconAccentColor : appSettings.themePalette.iconMutedForeground)
            Text(text)
                .font(.footnote.weight(isActionable ? .semibold : .regular))
                .foregroundStyle(isActionable ? appSettings.primaryColor : appSettings.themePalette.secondaryForeground)
                .lineLimit(nil)
            Spacer(minLength: 0)
            if isActionable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appSettings.themeIconAccentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(appSettings.themePalette.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isActionable ? appSettings.primaryColor.opacity(0.35) : appSettings.themeSeparator(defaultOpacity: 0.35),
                    lineWidth: 0.5
                )
        )
    }
}

struct NoteBlurRevealContainer<Content: View>: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let cornerRadius: CGFloat
    let onReveal: () -> Void
    let content: Content

    init(
        cornerRadius: CGFloat,
        onReveal: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.onReveal = onReveal
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .blur(radius: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                }
                .allowsHitTesting(false)

            VStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .font(.headline.weight(.semibold))
                Text("Tap to reveal")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(appSettings.themePalette.modalBackground)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.08),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.18),
                                    Color.clear
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                }
            )
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture(perform: onReveal)
        .accessibilityLabel("Reveal media")
    }
}
