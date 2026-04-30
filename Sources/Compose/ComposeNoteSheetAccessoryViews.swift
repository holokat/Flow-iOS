import Foundation
import SwiftUI

enum ComposeToolbarLayout {
    static let leadingItemSpacing: CGFloat = 8
    static let trailingItemSpacing: CGFloat = 8
    static let cancelButtonFontWeight: Font.Weight = .semibold
    static let publishButtonFontWeight: Font.Weight = .semibold
    static let cancelButtonFont = Font.subheadline.weight(cancelButtonFontWeight)
    static let publishButtonFont = Font.subheadline.weight(publishButtonFontWeight)
    static let draftButtonHorizontalPadding: CGFloat = 9
    static let draftButtonVerticalPadding: CGFloat = 6
    static let draftButtonBackgroundOpacity = 0.92
    static let draftButtonBorderOpacity = 0.62
}

struct ComposePublishToolbarButton: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    let isPublishing: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isPublishing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(appSettings.buttonTextColor)
                } else {
                    Text(title)
                }
            }
            .font(ComposeToolbarLayout.publishButtonFont)
            .foregroundStyle(appSettings.buttonTextColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(appSettings.primaryGradient, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct ComposeToolbarAvatarView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let avatarURL: URL?
    let fallbackSymbol: String
    let accessibilityLabel: String

    var body: some View {
        ComposeAvatarCircleView(
            avatarURL: avatarURL,
            fallbackText: fallbackSymbol,
            size: 34,
            fallbackFont: .subheadline.weight(.semibold),
            usesPrimaryFallback: true
        )
        .overlay {
            Circle()
                .stroke(appSettings.themePalette.separator.opacity(0.22), lineWidth: 0.8)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ComposeCharacterCountRing: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let characterCount: Int
    let characterLimit: Int

    private var progress: CGFloat {
        guard characterLimit > 0 else { return 0 }
        return min(1, CGFloat(characterCount) / CGFloat(characterLimit))
    }

    private var ringColor: Color {
        if characterCount >= characterLimit {
            return .red
        }
        if progress >= 0.9 {
            return .orange
        }
        return appSettings.primaryColor
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(appSettings.themePalette.separator.opacity(0.34), lineWidth: 3)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text("\(characterCount)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 36, height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(characterCount) of \(characterLimit) characters")
    }
}

struct ComposeStatusSectionView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let isPublishing: Bool
    let publishSourceCount: Int
    let feedbackMessage: String?
    let feedbackIsError: Bool
    let isTranscribingSpeech: Bool
    let missingNsec: Bool
    let missingPublishSources: Bool
    let pollValidationMessage: String?

    var body: some View {
        Group {
            if isPublishing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Posting to \(publishSourceCount) source\(publishSourceCount == 1 ? "" : "s")...")
                        .font(.footnote)
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    Spacer()
                }
                .padding(.horizontal, 2)
            } else if let feedbackMessage, !feedbackMessage.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedbackIsError ? .red : .green)

                    Text(feedbackMessage)
                        .font(.footnote)
                        .foregroundStyle(feedbackIsError ? .red : appSettings.themePalette.secondaryForeground)

                    Spacer()
                }
                .padding(12)
                .background(
                    (feedbackIsError ? Color.red.opacity(0.08) : Color.green.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            } else if isTranscribingSpeech {
                ComposeInfoBannerView(
                    systemImage: "waveform.badge.magnifyingglass",
                    text: "Transcribing speech..."
                )
            } else if missingNsec {
                ComposeInfoBannerView(
                    systemImage: "lock.fill",
                    text: "This account can read feeds, but it needs an nsec to publish notes."
                )
            } else if missingPublishSources {
                ComposeInfoBannerView(
                    systemImage: "wifi.slash",
                    text: "Add at least one publish source to post notes."
                )
            } else if let pollValidationMessage {
                ComposeInfoBannerView(
                    systemImage: "chart.bar.xaxis",
                    text: pollValidationMessage
                )
            }
        }
    }
}

private struct ComposeInfoBannerView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(appSettings.themePalette.iconMutedForeground)

            Text(text)
                .font(.footnote)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            Spacer()
        }
        .padding(12)
        .background(
            appSettings.themePalette.secondaryGroupedBackground,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

struct ComposeDraftLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore

    let drafts: [SavedComposeDraft]
    let activeDraftID: UUID?
    let onOpenDraft: (SavedComposeDraft) -> Void
    let onInsertText: (SavedComposeDraft) -> Void
    let onDeleteDraft: (SavedComposeDraft) -> Void
    let onCreateNewDraft: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(drafts) { draft in
                            ComposeDraftLibraryRow(
                                draft: draft,
                                isActive: activeDraftID == draft.id,
                                onOpen: {
                                    onOpenDraft(draft)
                                    dismiss()
                                },
                                onInsertText: draft.canInsertText ? {
                                    onInsertText(draft)
                                    dismiss()
                                } : nil
                            )
                            .listRowBackground(appSettings.themePalette.sheetBackground)
                            .listRowSeparatorTint(appSettings.themePalette.separator.opacity(0.12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onDeleteDraft(draft)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(appSettings.themePalette.sheetBackground)
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close drafts")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onCreateNewDraft()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .foregroundStyle(appSettings.primaryColor)
                    .accessibilityLabel("New draft")
                }
            }
            .toolbarBackground(appSettings.themePalette.sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.sheetBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(appSettings.primaryColor)
                .frame(width: 68, height: 68)
                .background(appSettings.primaryColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("No local drafts yet")
                .font(appSettings.appFont(.headline, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)

            Text("Swipe a composer down or tap Cancel after writing something, and Halo will keep that draft on this device.")
                .font(appSettings.appFont(.subheadline))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, 40)
    }
}

private struct ComposeDraftLibraryRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let draft: SavedComposeDraft
    let isActive: Bool
    let onOpen: () -> Void
    let onInsertText: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(draft.mode.navigationTitle)
                            .font(appSettings.appFont(.caption1, weight: .semibold))
                            .foregroundStyle(appSettings.primaryColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(appSettings.primaryColor.opacity(0.12), in: Capsule())

                        if isActive {
                            Text("Open")
                                .font(appSettings.appFont(.caption1, weight: .semibold))
                                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        }

                        Spacer(minLength: 8)

                        Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(appSettings.appFont(.caption1))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    }

                    Text(draft.textPreview)
                        .font(appSettings.appFont(.body, weight: .medium))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !draft.accessorySummary.isEmpty {
                        Text(draft.accessorySummary)
                            .font(appSettings.appFont(.footnote))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onInsertText {
                Button {
                    onInsertText()
                } label: {
                    Text("Insert")
                        .font(appSettings.appFont(.caption1, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            appSettings.themePalette.navigationControlBackground,
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

struct ComposeMentionSuggestionPanel: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    static let maxHeight: CGFloat = 220

    let suggestions: [ComposeMentionSuggestion]
    let isLoading: Bool
    let onSelect: (ComposeMentionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Mention suggestions")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, suggestions.isEmpty ? 12 : 8)

            if !suggestions.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                onSelect(suggestion)
                            } label: {
                                ComposeMentionSuggestionRow(suggestion: suggestion)
                            }
                            .buttonStyle(.plain)

                            if index < suggestions.count - 1 {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: Self.maxHeight)
                .scrollIndicators(.visible)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            appSettings.themePalette.secondaryGroupedBackground,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themePalette.separator.opacity(0.18), lineWidth: 0.8)
        }
    }
}

struct ComposeContextPreviewCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    let previewSnapshot: ComposeContextPreviewSnapshot
    let displayName: String
    let handle: String
    let avatarURL: URL?
    let fallbackText: String
    let videoSummary: String
    let audioSummary: String
    let pollSummary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            HStack(alignment: .top, spacing: 10) {
                ComposeAvatarCircleView(
                    avatarURL: avatarURL,
                    fallbackText: fallbackText,
                    size: 30,
                    fallbackFont: .caption.weight(.semibold)
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(handle)
                            .font(.subheadline)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(RelativeTimestampFormatter.shortString(from: previewSnapshot.createdAtDate))
                            .font(.caption)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .lineLimit(1)
                    }

                    Text(previewSnapshot.previewText)
                        .font(.body)
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ComposeContextPreviewMediaView(
                        imageURLs: previewSnapshot.imageURLs,
                        hasVideo: previewSnapshot.hasVideo,
                        hasAudio: previewSnapshot.hasAudio,
                        hasPoll: previewSnapshot.hasPoll,
                        videoSummary: videoSummary,
                        audioSummary: audioSummary,
                        pollSummary: pollSummary
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(contextPreviewBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themePalette.separator.opacity(0.3), lineWidth: 0.8)
        )
    }

    private var contextPreviewBackground: Color {
        if effectiveContextPreviewColorScheme == .light {
            return .white
        }
        return appSettings.themePalette.secondaryBackground
    }

    private var effectiveContextPreviewColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }
}

private struct ComposeContextPreviewMediaView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let imageURLs: [URL]
    let hasVideo: Bool
    let hasAudio: Bool
    let hasPoll: Bool
    let videoSummary: String
    let audioSummary: String
    let pollSummary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaContent

            if hasPoll {
                pollBadge
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var mediaContent: some View {
        if !imageURLs.isEmpty {
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: 8),
                count: min(max(imageURLs.count, 1), 2)
            )
            let thumbnailHeight: CGFloat = imageURLs.count == 1 ? 170 : 104

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(imageURLs.enumerated()), id: \.offset) { _, url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            appSettings.themePalette.tertiaryFill
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                                }
                        case .empty:
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(appSettings.themePalette.tertiaryFill)
                        @unknown default:
                            appSettings.themePalette.tertiaryFill
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if hasVideo || hasAudio {
            HStack(spacing: 8) {
                Image(systemName: hasVideo ? "video" : "waveform")
                Text(hasVideo ? videoSummary : audioSummary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(appSettings.themePalette.tertiaryFill)
            )
        }
    }

    private var pollBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
            Text(pollSummary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(appSettings.themePalette.secondaryForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appSettings.themePalette.tertiaryFill)
        )
    }
}

private struct ComposeAvatarCircleView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let avatarURL: URL?
    let fallbackText: String
    let size: CGFloat
    let fallbackFont: Font
    var usesPrimaryFallback = false

    var body: some View {
        Group {
            if let avatarURL {
                CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            if usesPrimaryFallback {
                Circle().fill(appSettings.primaryGradient)
            } else {
                Circle().fill(appSettings.themePalette.secondaryFill)
            }
            if let firstCharacter = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(firstCharacter).uppercased())
                    .font(fallbackFont)
                    .foregroundStyle(usesPrimaryFallback ? appSettings.buttonTextColor : appSettings.themePalette.secondaryForeground)
            } else {
                Image(systemName: "person.fill")
                    .font(fallbackFont)
                    .foregroundStyle(usesPrimaryFallback ? appSettings.buttonTextColor : appSettings.themePalette.secondaryForeground)
            }
        }
    }
}

struct CameraCapturePermissionSheet: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let permissions: CameraCapturePermissionSnapshot
    let isRequestingAccess: Bool
    let onContinue: () -> Void
    let onOpenSettings: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: permissions.isCameraBlocked ? "camera.fill.badge.ellipsis" : "camera.badge.ellipsis")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(appSettings.primaryColor)

                Text(title)
                    .font(.title3.weight(.semibold))

                Text(message)
                    .font(.body)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                if permissions.isCameraBlocked {
                    Button {
                        onOpenSettings()
                    } label: {
                        Text("Open Settings")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        onContinue()
                    } label: {
                        Group {
                            if isRequestingAccess {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Continue")
                                    .font(.headline.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequestingAccess)
                }

                Button("Not now") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.body.weight(.medium))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .padding(20)
    }

    private var title: String {
        if permissions.isCameraBlocked {
            return "Turn on camera access"
        }
        return "Camera and microphone access"
    }

    private var message: String {
        if permissions.isCameraBlocked {
            return "To capture photos or videos for your note, \(AppBrand.displayName) needs camera access. Microphone access is used for video capture with sound. You can change this any time later in app settings."
        }
        return "To capture photos or videos for your note, \(AppBrand.displayName) needs access to your camera and microphone. You can change this any time later in app settings."
    }
}
