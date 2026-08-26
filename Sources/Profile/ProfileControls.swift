import SwiftUI

struct ProfileActionIconButton: View {
    let systemImage: String
    let isPrimary: Bool
    let isDisabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        let style = appSettings.themePalette.profileActionStyle
        let disabledOpacity = isDisabled ? 0.48 : 1.0
        let usesHolographicPrimaryGradient = isPrimary && appSettings.usesPrimaryGradientForProminentButtons
        let foreground = isPrimary
            ? appSettings.buttonTextColor
            : (style?.foreground ?? (isDisabled ? appSettings.themePalette.mutedForeground : appSettings.themePalette.foreground))

        Button(action: action) {
            let label = Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 18, height: 18)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .foregroundStyle(foreground.opacity(disabledOpacity))

            if isPrimary {
                label
                    .background {
                        Capsule()
                            .fill(
                                usesHolographicPrimaryGradient
                                    ? AnyShapeStyle(appSettings.primaryGradient)
                                    : AnyShapeStyle(appSettings.primaryColor)
                            )
                    }
            } else {
                label
                    .haloNativeGlass(interactive: true, in: Capsule(style: .continuous))
            }
        }
        .buttonStyle(FlowPressScaleButtonStyle())
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ProfileActionTextButton: View {
    let title: String
    let minimumWidth: CGFloat
    let isPrimary: Bool
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        let style = appSettings.themePalette.profileActionStyle
        let disabledOpacity = isDisabled ? 0.48 : 1.0
        let usesHolographicPrimaryGradient = isPrimary && appSettings.usesPrimaryGradientForProminentButtons
        let foreground: Color = if isPrimary {
            appSettings.buttonTextColor
        } else if isSelected {
            appSettings.primaryColor
        } else {
            style?.foreground ?? appSettings.themePalette.foreground
        }

        Button(action: action) {
            let label = Text(title)
                .font(appSettings.appFont(.subheadline, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(minWidth: minimumWidth, minHeight: 40)
                .padding(.horizontal, 8)
                .foregroundStyle(foreground.opacity(disabledOpacity))

            if isPrimary {
                label
                    .background {
                        Capsule(style: .continuous)
                            .fill(
                                usesHolographicPrimaryGradient
                                    ? AnyShapeStyle(appSettings.primaryGradient)
                                    : AnyShapeStyle(appSettings.primaryColor)
                            )
                    }
            } else {
                label
                    .haloNativeGlass(
                        tint: isSelected ? appSettings.primaryColor.opacity(0.14) : nil,
                        interactive: true,
                        in: Capsule(style: .continuous)
                    )
            }
        }
        .buttonStyle(ProfileActionPressButtonStyle())
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .animation(.easeOut(duration: 0.16), value: title)
    }
}

private struct ProfileActionPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !accessibilityReduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct ProfileBannerCircleIcon: View {
    let systemImage: String
    let foreground: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: 44, height: 44)
            .haloNativeGlass(interactive: true, in: Circle())
    }
}

struct ProfileMenuOptionLabel: View {
    let title: String
    let systemImage: String

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        Label {
            Text(title)
                .font(appSettings.appFont(.body))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(appSettings.themeIconAccentColor)
        }
    }
}

enum MuteReasonEditorMode: String, Identifiable, Equatable {
    case mute
    case edit

    var id: String { rawValue }

    var navigationTitle: String {
        switch self {
        case .mute:
            return "Mute"
        case .edit:
            return "Mute reason"
        }
    }
}

struct MuteReasonSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore

    let displayName: String
    let initialReason: String?
    let mode: MuteReasonEditorMode
    let onComplete: (String?) -> Void

    var body: some View {
        NavigationStack {
            MuteReasonEditorView(
                displayName: displayName,
                initialReason: initialReason,
                mode: mode,
                onConfirm: { reason in
                    onComplete(reason)
                    dismiss()
                }
            )
            .navigationTitle(mode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(appSettings.themePalette.sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.sheetBackground)
    }
}

struct MuteReasonEditorView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @FocusState private var isReasonFocused: Bool

    let displayName: String
    let initialReason: String?
    let mode: MuteReasonEditorMode
    let onCancel: (() -> Void)?
    let onConfirm: (String?) -> Void

    @State private var reason: String

    init(
        displayName: String,
        initialReason: String? = nil,
        mode: MuteReasonEditorMode,
        onCancel: (() -> Void)? = nil,
        onConfirm: @escaping (String?) -> Void
    ) {
        self.displayName = displayName
        self.initialReason = initialReason
        self.mode = mode
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _reason = State(initialValue: initialReason ?? "")
    }

    private var normalizedReason: String? {
        let value = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var normalizedInitialReason: String? {
        let value = initialReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private var editorTitle: String {
        switch mode {
        case .mute:
            return "Mute \(displayName)?"
        case .edit:
            return normalizedInitialReason == nil
                ? "Add a mute reason"
                : "Edit mute reason"
        }
    }

    private var editorSubtitle: String {
        switch mode {
        case .mute:
            return "Add a reason for yourself, or skip this step."
        case .edit:
            return "Keep a note about why you muted this person."
        }
    }

    private var primaryButtonTitle: String {
        mode == .mute ? "Mute with reason" : "Save reason"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let onCancel {
                Button {
                    isReasonFocused = false
                    onCancel()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(appSettings.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FlowPressScaleButtonStyle())
            }

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: mode == .mute ? "speaker.slash.fill" : "note.text")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appSettings.primaryColor)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(appSettings.primaryColor.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(editorTitle)
                        .font(appSettings.appFont(.title3, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(2)

                    Text(editorSubtitle)
                        .font(appSettings.appFont(.subheadline))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Reason (optional)")
                    .font(appSettings.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)

                TextField(
                    "Why are you muting this person?",
                    text: $reason,
                    axis: .vertical
                )
                .font(appSettings.appFont(.body))
                .lineLimit(3...5)
                .focused($isReasonFocused)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(appSettings.themePalette.sheetInsetBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isReasonFocused
                                ? appSettings.primaryColor.opacity(0.72)
                                : appSettings.themePalette.separator.opacity(0.5),
                            lineWidth: isReasonFocused ? 1.2 : 0.8
                        )
                )

                Label("Saved locally. Never sent to relays.", systemImage: "lock.fill")
                    .font(appSettings.appFont(.caption1))
                    .foregroundStyle(appSettings.themePalette.tertiaryForeground)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    onConfirm(normalizedReason)
                } label: {
                    Text(primaryButtonTitle)
                        .font(appSettings.appFont(.body, weight: .semibold))
                        .foregroundStyle(appSettings.buttonTextColor)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    normalizedReason == nil
                                        ? appSettings.primaryColor.opacity(0.42)
                                        : appSettings.primaryColor
                                )
                        )
                }
                .buttonStyle(FlowPressScaleButtonStyle())
                .disabled(normalizedReason == nil)

                if mode == .mute {
                    secondaryButton(
                        title: "Skip reason and mute",
                        foreground: appSettings.themePalette.foreground
                    ) {
                        onConfirm(nil)
                    }
                } else if normalizedInitialReason != nil {
                    secondaryButton(
                        title: "Remove reason",
                        foreground: appSettings.themePalette.errorForeground
                    ) {
                        onConfirm(nil)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(appSettings.themePalette.sheetBackground)
        .onAppear {
            DispatchQueue.main.async {
                isReasonFocused = true
            }
        }
    }

    private func secondaryButton(
        title: String,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(appSettings.appFont(.body, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(appSettings.themePalette.secondaryGroupedBackground)
                )
        }
        .buttonStyle(FlowPressScaleButtonStyle())
    }
}

struct MutedProfileReasonCard: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let reason: String?
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "speaker.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appSettings.primaryColor)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(appSettings.primaryColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Muted")
                        .font(appSettings.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)

                    Spacer(minLength: 8)

                    Text("Local note")
                        .font(appSettings.appFont(.caption2, weight: .semibold))
                        .foregroundStyle(appSettings.primaryColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(appSettings.primaryColor.opacity(0.12))
                        )
                }

                Text("Your reason")
                    .font(appSettings.appFont(.caption1, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)

                Text(reason ?? "No reason added.")
                    .font(appSettings.appFont(.body))
                    .foregroundStyle(
                        reason == nil
                            ? appSettings.themePalette.tertiaryForeground
                            : appSettings.themePalette.foreground
                    )
                    .fixedSize(horizontal: false, vertical: true)

                Label("Not sent to relays", systemImage: "lock.fill")
                    .font(appSettings.appFont(.caption1))
                    .foregroundStyle(appSettings.themePalette.tertiaryForeground)

                Rectangle()
                    .fill(appSettings.themePalette.separator.opacity(0.35))
                    .frame(height: 0.7)
                    .padding(.top, 3)

                Button(action: onEdit) {
                    HStack(spacing: 8) {
                        Label(
                            reason == nil ? "Add reason" : "Edit reason",
                            systemImage: "square.and.pencil"
                        )
                        .font(appSettings.appFont(.subheadline, weight: .semibold))

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(appSettings.primaryColor)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FlowPressScaleButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(appSettings.themePalette.secondaryGroupedBackground)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .contain)
    }
}

struct ProfileFeedLoadingRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 150, height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 180, height: 14)
            }
        }
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }
}
