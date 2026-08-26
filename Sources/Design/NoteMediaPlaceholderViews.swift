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

struct NoteBlurRevealContainer: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let cornerRadius: CGFloat
    let aspectRatio: CGFloat
    let onReveal: () -> Void

    init(
        cornerRadius: CGFloat,
        aspectRatio: CGFloat = NoteImageLayoutGuide.defaultSingleImageAspectRatio,
        onReveal: @escaping () -> Void
    ) {
        self.cornerRadius = cornerRadius
        self.aspectRatio = NoteImageLayoutGuide.normalizedAspectRatio(aspectRatio)
            ?? NoteImageLayoutGuide.defaultSingleImageAspectRatio
        self.onReveal = onReveal
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(appSettings.themePalette.secondaryBackground)

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(appSettings.themePalette.secondaryForeground.opacity(0.34))

            VStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .font(.headline.weight(.semibold))
                Text("Tap to reveal")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(revealPillForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .haloNativeGlass(interactive: true, in: Capsule(style: .continuous))
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture(perform: onReveal)
        .accessibilityLabel("Reveal media")
    }

    private var revealPillForeground: Color {
        appSettings.themePalette.foreground
    }
}
