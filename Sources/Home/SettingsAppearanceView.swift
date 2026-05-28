import NostrSDK
import SwiftUI

enum SettingsPrimaryColorSwatchSelectionIndicator {
    static let selectedSystemImageName: String? = nil
    static let selectedBorderWidth: CGFloat = 2.5
    static let defaultBorderWidth: CGFloat = 1
}

struct SettingsAppearanceView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    private var appearanceThemeOptions: [AppThemeOption] {
        AppThemeOption.appearanceOptions
    }

    var body: some View {
        ThemedSettingsForm {
            Section("Appearance") {
                HStack(spacing: 8) {
                    ForEach(appearanceThemeOptions) { option in
                        themeOptionCard(for: option)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Primary Color") {
                primaryColorSection
                .padding(.vertical, 2)
            }

            Section("Feed Layout") {
                SettingsToggleRow(
                    title: "Full Width Notes",
                    isOn: Binding(
                        get: { appSettings.fullWidthNoteRows },
                        set: { appSettings.fullWidthNoteRows = $0 }
                    ),
                    footer: "Show note content at full width by moving the profile image into the header row instead of the left gutter."
                )
            }

            Section("Preview") {
                notePreviewCard
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var notePreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note Preview")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                previewHeader

                NoteContentView(event: Self.previewEvent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(appSettings.themePalette.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .id(appSettings.fullWidthNoteRows)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var previewHeader: some View {
        if appSettings.fullWidthNoteRows {
            HStack(alignment: .top, spacing: 10) {
                previewAvatar(size: 32)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("alex")
                            .font(.subheadline.weight(.semibold))
                        Text("@alex")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text("2 hr")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                previewAvatar(size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("alex")
                        .font(.subheadline.weight(.semibold))
                    Text("@alex")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text("2 hr")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewAvatar(size: CGFloat) -> some View {
        Circle()
            .fill(appSettings.themePalette.tertiaryFill)
            .overlay {
                Text("A")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
    }

    private func themeOptionCard(for option: AppThemeOption) -> some View {
        let isSelected = appSettings.theme == option

        return Button {
            guard option.isEnabled else { return }
            appSettings.theme = option
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(themePreviewFill(for: option))
                        .frame(height: 42)
                        .overlay {
                            Image(systemName: option.iconName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(themePreviewForeground(for: option))
                        }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(appSettings.primaryColor)
                            .padding(5)
                    } else if !option.isEnabled {
                        Text("Soon")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(appSettings.themePalette.chromeBackground.opacity(0.82), in: Capsule(style: .continuous))
                            .padding(8)
                    }
                }

                Text(option.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(option.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(appSettings.themePalette.secondaryBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? appSettings.primaryColor : appSettings.themeSeparator(defaultOpacity: 0.18),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .opacity(option.isEnabled ? 1 : 0.72)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
    }

    private var primaryColorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorPicker(
                selection: primaryColorBinding,
                supportsOpacity: false
            ) {
                HStack(spacing: 10) {
                    Image(systemName: "eyedropper.halffull")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(appSettings.primaryColor)

                    Text("Custom Color")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .tint(appSettings.primaryColor)

            HStack(spacing: 10) {
                ForEach(AppSettingsStore.availablePrimaryColorOptions) { option in
                    primaryColorOptionCard(for: option)
                }
                Spacer(minLength: 0)
            }

            Text("Buttons, links, and selected states all use the same primary color.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var primaryColorBinding: Binding<Color> {
        Binding(
            get: { appSettings.primaryColor },
            set: { appSettings.primaryColor = $0 }
        )
    }

    private func primaryColorOptionCard(for option: AppPrimaryColorOption) -> some View {
        let isSelected = appSettings.selectedPrimaryColorOption == option

        return Button {
            appSettings.primaryColor = option.color
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 26, height: 26)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.32), lineWidth: 1)
                }
                .padding(5)
                .background(
                    Circle()
                        .fill(appSettings.themePalette.secondaryBackground)
                )
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? appSettings.linkColor : appSettings.themeSeparator(defaultOpacity: 0.18),
                            lineWidth: isSelected
                                ? SettingsPrimaryColorSwatchSelectionIndicator.selectedBorderWidth
                                : SettingsPrimaryColorSwatchSelectionIndicator.defaultBorderWidth
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Primary color \(option.hexCode)")
    }

    private func themePreviewFill(for option: AppThemeOption) -> LinearGradient {
        switch option {
        case .system:
            return LinearGradient(
                colors: [Color.white, Color(red: 23.0 / 255.0, green: 23.0 / 255.0, blue: 25.0 / 255.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .black:
            return LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.10), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .white:
            return LinearGradient(
                colors: [Color.white, Color(.systemGray6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .sakura:
            return LinearGradient(
                colors: [Color.white, Color(.systemGray6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .dracula:
            return AppThemeOption.dracula.fixedPrimaryGradient ?? LinearGradient(
                colors: [
                    Color(red: 0.741, green: 0.576, blue: 0.976),
                    Color(red: 1.0, green: 0.475, blue: 0.776)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .gamer:
            return AppThemeOption.gamer.fixedPrimaryGradient ?? LinearGradient(
                colors: [
                    Color(red: 0.553, green: 0.408, blue: 1.0),
                    Color(red: 0.329, green: 0.920, blue: 0.996)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .holographicLight:
            return AppThemeOption.holographicLight.fixedPrimaryGradient ?? LinearGradient(
                colors: [
                    Color(red: 0.380, green: 0.906, blue: 1.0),
                    Color(red: 0.690, green: 0.604, blue: 1.0),
                    Color(red: 1.0, green: 0.560, blue: 0.780)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .holographicDark:
            return AppThemeOption.holographicDark.fixedPrimaryGradient ?? LinearGradient(
                colors: [
                    Color(red: 0.380, green: 0.906, blue: 1.0),
                    Color(red: 0.690, green: 0.604, blue: 1.0),
                    Color(red: 1.0, green: 0.560, blue: 0.780)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .dark:
            return LinearGradient(
                colors: [
                    Color(red: 23.0 / 255.0, green: 23.0 / 255.0, blue: 25.0 / 255.0),
                    Color(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .light:
            return LinearGradient(
                colors: [Color.white, Color(.systemGray6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func themePreviewForeground(for option: AppThemeOption) -> Color {
        switch option {
        case .white, .light, .system:
            return Color(.label).opacity(0.75)
        case .sakura:
            return Color(.label).opacity(0.75)
        case .dracula:
            return Color(red: 0.973, green: 0.973, blue: 0.949).opacity(0.92)
        case .gamer:
            return Color.white.opacity(0.92)
        case .holographicLight:
            return Color(red: 0.055, green: 0.075, blue: 0.125).opacity(0.86)
        case .holographicDark:
            return Color(red: 0.940, green: 0.970, blue: 1.0).opacity(0.94)
        case .black, .dark:
            return .white.opacity(0.85)
        }
    }

    private static var previewEvent: NostrEvent {
        NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: Int(Date().timeIntervalSince1970),
            kind: 1,
            tags: [],
            content: "Switching font size here updates note readability in the feed. #flow",
            sig: String(repeating: "c", count: 128)
        )
    }
}
