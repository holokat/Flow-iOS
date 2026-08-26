import SwiftUI

struct HaloFeedCatchUpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore

    let summary: HaloFeedCatchUpSummary?
    let isGenerating: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    privacyLabel

                    if isGenerating {
                        generatingState
                    } else if let summary {
                        summaryContent(summary)
                    } else if let errorMessage {
                        errorState(errorMessage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .navigationTitle("Catch Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ThemedToolbarDoneButton {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var privacyLabel: some View {
        Label("Visible posts are summarized on this device.", systemImage: "lock.fill")
            .font(appSettings.appFont(.footnote, weight: .medium))
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .haloNativeGlass(in: Capsule(style: .continuous))
    }

    private var generatingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text("Reading the visible posts")
                .font(appSettings.appFont(.headline, weight: .semibold))

            Text("This can take a moment the first time the on-device model runs.")
                .font(appSettings.appFont(.footnote))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private func summaryContent(_ summary: HaloFeedCatchUpSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(summary.overview)
                .font(appSettings.appFont(.body))
                .foregroundStyle(appSettings.themePalette.foreground)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(summary.highlights) { highlight in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(highlight.title)
                            .font(appSettings.appFont(.subheadline, weight: .semibold))
                            .foregroundStyle(appSettings.themePalette.foreground)

                        Text(highlight.detail)
                            .font(appSettings.appFont(.footnote))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        appSettings.themePalette.secondaryBackground,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
            }

            Text("Generated from \(summary.sourceCount) visible posts. Check the originals for context.")
                .font(appSettings.appFont(.caption1))
                .foregroundStyle(appSettings.themePalette.mutedForeground)

            retryButton(title: "Refresh summary")
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "info.circle")
                .font(appSettings.appFont(.body))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            retryButton(title: "Try again")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    private func retryButton(title: String) -> some View {
        Button(action: onRetry) {
            Label(title, systemImage: "arrow.clockwise")
                .font(appSettings.appFont(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(appSettings.themePalette.foreground)
                .haloNativeGlass(
                    interactive: true,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}
