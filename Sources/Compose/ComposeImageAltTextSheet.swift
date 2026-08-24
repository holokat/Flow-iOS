import SwiftUI

struct ComposeImageAltTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore
    @FocusState private var isEditorFocused: Bool

    let attachment: ComposeMediaAttachment
    let onSave: (String) -> Void

    @State private var draftText: String
    @State private var isGenerating = false
    @State private var generationError: String?

    init(
        attachment: ComposeMediaAttachment,
        onSave: @escaping (String) -> Void
    ) {
        self.attachment = attachment
        self.onSave = onSave
        _draftText = State(initialValue: attachment.altText ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    imagePreview

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Describe this image")
                            .font(appSettings.appFont(.headline, weight: .semibold))

                        Text("Alt text helps people understand the image when they use VoiceOver or can't see it clearly.")
                            .font(appSettings.appFont(.footnote))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    }

                    VStack(alignment: .trailing, spacing: 6) {
                        TextEditor(text: $draftText)
                            .font(appSettings.appFont(.body))
                            .focused($isEditorFocused)
                            .accessibilityLabel("Alt text")
                            .frame(minHeight: 132)
                            .padding(10)
                            .scrollContentBackground(.hidden)
                            .background(
                                appSettings.themePalette.secondaryBackground,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(
                                        appSettings.themeSeparator(defaultOpacity: 0.45),
                                        lineWidth: 0.8
                                    )
                            }
                            .onChange(of: draftText) { _, newValue in
                                guard newValue.count > 300 else { return }
                                draftText = String(newValue.prefix(300))
                            }

                        Text("\(draftText.count)/300")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(appSettings.themePalette.mutedForeground)
                    }

                    onDeviceDraftSection

                    if let generationError {
                        Label(generationError, systemImage: "exclamationmark.circle")
                            .font(appSettings.appFont(.footnote))
                            .foregroundStyle(.red)
                    }

                    if attachment.altText != nil {
                        Button(role: .destructive) {
                            draftText = ""
                            generationError = nil
                        } label: {
                            Label("Clear alt text", systemImage: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(appSettings.themePalette.sheetBackground)
            .navigationTitle("Alt Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draftText)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .toolbarBackground(appSettings.themePalette.sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.sheetBackground)
    }

    private var imagePreview: some View {
        AsyncImage(url: attachment.url) { phase in
            switch phase {
            case .empty:
                ProgressView()
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(
            appSettings.themePalette.secondaryBackground,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.35), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var onDeviceDraftSection: some View {
        if #available(iOS 27.0, *) {
            let availability = HaloOnDeviceAssistant.imageDescriptionAvailability

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task {
                        await generateDraft()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGenerating ? "Drafting on device" : "Draft with Apple Intelligence")
                    }
                    .font(appSettings.appFont(.subheadline, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .background(
                        appSettings.themePalette.navigationControlBackground,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || availability != .available)

                Label(availability.message, systemImage: availability == .available ? "lock.fill" : "info.circle")
                    .font(appSettings.appFont(.caption1))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        } else {
            Label(
                "Write a description manually. On-device image drafting requires iOS 27.",
                systemImage: "text.bubble"
            )
            .font(appSettings.appFont(.footnote))
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }

    private var canSave: Bool {
        let prepared = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !prepared.isEmpty || attachment.altText != nil
    }

    @MainActor
    private func generateDraft() async {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }

        guard let image = await FlowImageCache.shared.image(for: attachment.url) else {
            generationError = "Halo couldn't load that image."
            return
        }

        do {
            draftText = try await HaloOnDeviceAssistant.draftAltText(for: image)
            isEditorFocused = true
        } catch {
            generationError = (error as? LocalizedError)?.errorDescription ?? "Halo couldn't draft alt text."
        }
    }
}
