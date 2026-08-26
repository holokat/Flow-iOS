import AVKit
import PhotosUI
import SwiftUI
import UIKit

struct HaloLinkThreadView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var auth: AuthManager

    let route: HaloLinkThreadRoute
    @ObservedObject var store: HaloLinkStore

    @StateObject private var speechTranscriber = ComposeSpeechTranscriber()
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var pendingAttachments: [HaloLinkPendingAttachment] = []
    @State private var attachmentUploadTasks: [UUID: Task<Void, Never>] = [:]
    @State private var draftText = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    participantsSummary

                    if currentMessages.isEmpty {
                        emptyThreadState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(currentMessages) { message in
                                HaloLinkMessageRow(
                                    message: message,
                                    conversation: currentConversation,
                                    currentAccountPubkey: auth.currentAccount?.pubkey,
                                    store: store,
                                    onReact: { emoji in
                                        Task {
                                            try? await store.sendReaction(emoji: emoji, to: message)
                                        }
                                    }
                                )
                                .id(message.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(appSettings.themePalette.background)
            .navigationTitle(threadTitle)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    .background(appSettings.themePalette.navigationBackground)
            }
            .task {
                store.markConversationAsRead(route.id)
                applyPendingSystemDraftIfNeeded()
            }
            .onChange(of: lastMessageID) { _, newValue in
                guard let newValue else { return }
                store.markConversationAsRead(route.id)
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
            .onChange(of: selectedMediaItems) { _, newValue in
                guard !newValue.isEmpty else { return }
                let items = newValue
                selectedMediaItems = []
                Task {
                    await prepareAttachments(from: items)
                }
            }
            .onDisappear {
                cancelAllAttachmentUploads()
            }
        }
    }

    private var currentConversation: HaloLinkConversation? {
        store.conversation(for: route.participantPubkeys)
    }

    private var currentMessages: [HaloLinkMessage] {
        currentConversation?.messages ?? []
    }

    private var lastMessageID: String? {
        currentMessages.last?.id
    }

    private var threadTitle: String {
        let names = route.participantPubkeys.map(store.displayName(for:))
        if names.isEmpty {
            return "Conversation"
        }
        if names.count == 1 {
            return names[0]
        }
        if names.count == 2 {
            return names.joined(separator: ", ")
        }
        return "\(names[0]), \(names[1]) +\(names.count - 2)"
    }

    private var participantsSummary: some View {
        HStack(alignment: .center, spacing: 12) {
            HaloLinkParticipantsAvatarStrip(
                participantPubkeys: route.participantPubkeys,
                store: store
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(threadTitle)
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .lineLimit(1)

                Text(route.participantPubkeys.map(store.handle(for:)).joined(separator: ", "))
                    .font(appSettings.appFont(.caption1))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(appSettings.themePalette.sheetCardBorder, lineWidth: 1)
        }
    }

    private var emptyThreadState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(appSettings.primaryColor)

            Text("Start the conversation")
                .font(appSettings.appFont(.headline, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)

            Text("Send a Halo Link message, photo, or video. Replies here will also move requests into Conversations.")
                .font(appSettings.appFont(.subheadline))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var composer: some View {
        let palette = appSettings.themePalette
        let primaryColor = appSettings.primaryColor
        return VStack(alignment: .leading, spacing: 10) {
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(appSettings.appFont(.footnote))
                    .foregroundStyle(palette.errorForeground)
            }

            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pendingAttachments) { attachment in
                            HaloLinkPendingAttachmentChip(
                                attachment: attachment,
                                onRemove: {
                                    removePendingAttachment(attachment.id)
                                }
                            )
                        }
                    }
                }
            }

            if let attachmentStatusText {
                HStack(spacing: 8) {
                    if hasUploadingAttachments {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.errorForeground)
                    }

                    Text(attachmentStatusText)
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(
                            hasUploadingAttachments
                                ? palette.secondaryForeground
                                : palette.errorForeground
                        )
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(
                    selection: $selectedMediaItems,
                    maxSelectionCount: 6,
                    matching: .any(of: [.images, .videos])
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(palette.secondaryGroupedBackground)
                        )
                }
                .buttonStyle(.plain)

                TextField("Write a reply...", text: $draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(appSettings.appFont(.body))
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(palette.secondaryGroupedBackground)
                    )
                    .focused($isComposerFocused)

                Button {
                    Task {
                        await toggleVoiceInput()
                    }
                } label: {
                    Image(systemName: speechTranscriber.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            speechTranscriber.isRecording
                                ? Color.white
                                : palette.foreground
                        )
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(
                                speechTranscriber.isRecording
                                    ? primaryColor
                                    : palette.secondaryGroupedBackground
                            )
                        )
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        await sendDraft()
                    }
                } label: {
                    ZStack {
                        if isSending {
                            ProgressView()
                                .tint(appSettings.buttonTextColor)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(appSettings.buttonTextColor)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(
                            canSend
                                ? AnyShapeStyle(appSettings.primaryGradient)
                                : AnyShapeStyle(palette.tertiaryFill)
                        )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }

            if speechTranscriber.isRecording || speechTranscriber.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text(speechTranscriber.isRecording ? "Listening..." : "Transcribing...")
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(palette.secondaryForeground)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.chromeBorder)
                .frame(height: 0.7)
        }
    }

    private var canSend: Bool {
        !isSending &&
        !hasUploadingAttachments &&
        !hasFailedAttachments &&
        (
            !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            pendingAttachments.contains(where: { $0.preparedAttachment != nil })
        )
    }

    private var hasUploadingAttachments: Bool {
        pendingAttachments.contains { $0.isUploading }
    }

    private var hasFailedAttachments: Bool {
        pendingAttachments.contains { $0.hasFailedUpload }
    }

    private var attachmentStatusText: String? {
        if hasUploadingAttachments {
            let count = pendingAttachments.filter(\.isUploading).count
            return "Uploading \(count) attachment\(count == 1 ? "" : "s")..."
        }

        if hasFailedAttachments {
            return "Remove failed attachments before sending."
        }

        return nil
    }

    private func prepareAttachments(from items: [PhotosPickerItem]) async {
        for item in items {
            let attachmentID = UUID()
            let placeholderAttachment = HaloLinkPendingAttachment(
                id: attachmentID,
                previewImage: nil,
                isVideo: item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
                uploadState: .preparing
            )
            pendingAttachments.append(placeholderAttachment)

            let uploadTask = Task {
                await prepareAndUploadAttachment(from: item, attachmentID: attachmentID)
            }
            attachmentUploadTasks[attachmentID] = uploadTask
        }
    }

    private func previewImage(for prepared: PreparedUploadMedia) -> UIImage? {
        if let previewImage = prepared.previewImage {
            return previewImage
        }

        guard !prepared.mimeType.lowercased().hasPrefix("video/") else {
            return nil
        }

        return UIImage(data: prepared.data)
    }

    private func toggleVoiceInput() async {
        let response = await speechTranscriber.toggleRecording { transcript in
            appendTranscript(transcript)
        }
        if let response, !response.isEmpty {
            errorMessage = response
        }
    }

    private func appendTranscript(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = cleaned
        } else {
            draftText += draftText.hasSuffix(" ") ? cleaned : " \(cleaned)"
        }
    }

    private func applyPendingSystemDraftIfNeeded() {
        guard route.participantPubkeys.count == 1,
              let recipientPubkey = route.participantPubkeys.first,
              let pendingDraft = HaloLinkPendingDraftStore.take(recipientPubkey: recipientPubkey) else {
            return
        }

        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = pendingDraft
        } else {
            draftText += draftText.hasSuffix(" ") ? pendingDraft : " \(pendingDraft)"
        }
        isComposerFocused = true
    }

    private func sendDraft() async {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        let outgoingText = draftText
        let outgoingAttachments = pendingAttachments

        draftText = ""
        pendingAttachments.removeAll()
        isComposerFocused = true

        do {
            try await store.sendMessage(
                recipientPubkeys: route.participantPubkeys,
                content: outgoingText,
                attachments: outgoingAttachments.compactMap(\.preparedAttachment)
            )
        } catch {
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pendingAttachments.isEmpty {
                draftText = outgoingText
                pendingAttachments = outgoingAttachments
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't send that message."
        }

        isSending = false
    }

    private func prepareAndUploadAttachment(
        from item: PhotosPickerItem,
        attachmentID: UUID
    ) async {
        defer {
            attachmentUploadTasks[attachmentID] = nil
        }

        do {
            let prepared = try await MediaUploadPreparation.prepareUploadMedia(from: item)
            try Task.checkCancellation()

            let payload = HaloLinkComposerAttachmentPayload(
                data: prepared.data,
                mimeType: prepared.mimeType,
                fileExtension: prepared.fileExtension
            )
            let resolvedPreviewImage = previewImage(for: prepared)
            let isVideo = prepared.mimeType.lowercased().hasPrefix("video/")

            guard updatePendingAttachment(
                attachmentID,
                previewImage: resolvedPreviewImage,
                isVideo: isVideo,
                uploadState: .uploading
            ) else {
                return
            }

            let uploadedAttachment = try await store.prepareAttachmentForSending(payload)
            try Task.checkCancellation()

            _ = updatePendingAttachment(
                attachmentID,
                previewImage: resolvedPreviewImage,
                isVideo: isVideo,
                uploadState: .ready(uploadedAttachment)
            )
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't upload that attachment."
            if updatePendingAttachment(
                attachmentID,
                uploadState: .failed(message)
            ) {
                errorMessage = message
            }
        }
    }

    @discardableResult
    private func updatePendingAttachment(
        _ attachmentID: UUID,
        previewImage: UIImage? = nil,
        isVideo: Bool? = nil,
        uploadState: HaloLinkPendingAttachmentUploadState
    ) -> Bool {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == attachmentID }) else {
            return false
        }

        if let previewImage {
            pendingAttachments[index].previewImage = previewImage
        }
        if let isVideo {
            pendingAttachments[index].isVideo = isVideo
        }
        pendingAttachments[index].uploadState = uploadState
        return true
    }

    private func removePendingAttachment(_ attachmentID: UUID) {
        attachmentUploadTasks[attachmentID]?.cancel()
        attachmentUploadTasks[attachmentID] = nil
        pendingAttachments.removeAll { $0.id == attachmentID }
    }

    private func cancelAllAttachmentUploads() {
        for task in attachmentUploadTasks.values {
            task.cancel()
        }
        attachmentUploadTasks.removeAll()
    }
}

private struct HaloLinkParticipantsAvatarStrip: View {
    let participantPubkeys: [String]
    @ObservedObject var store: HaloLinkStore

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(Array(participantPubkeys.prefix(3)).enumerated()), id: \.element) { index, pubkey in
                AvatarView(
                    url: store.avatarURL(for: pubkey),
                    fallback: store.displayName(for: pubkey),
                    size: 38
                )
                .offset(x: CGFloat(index) * 18)
            }
        }
        .frame(width: participantPubkeys.count > 1 ? 74 : 38, height: 38, alignment: .leading)
    }
}

private enum HaloLinkPendingAttachmentUploadState {
    case preparing
    case uploading
    case ready(HaloLinkPreparedComposerAttachment)
    case failed(String)
}

private struct HaloLinkPendingAttachment: Identifiable {
    let id: UUID
    var previewImage: UIImage?
    var isVideo: Bool
    var uploadState: HaloLinkPendingAttachmentUploadState

    var preparedAttachment: HaloLinkPreparedComposerAttachment? {
        guard case .ready(let attachment) = uploadState else { return nil }
        return attachment
    }

    var isUploading: Bool {
        switch uploadState {
        case .preparing, .uploading:
            return true
        case .ready, .failed:
            return false
        }
    }

    var hasFailedUpload: Bool {
        if case .failed = uploadState {
            return true
        }
        return false
    }
}

private let haloLinkQuickReactionEmojis = ["👍", "❤️", "😂", "🔥", "👏"]

private struct HaloLinkPendingAttachmentChip: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let attachment: HaloLinkPendingAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let previewImage = attachment.previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(appSettings.themePalette.secondaryGroupedBackground)
                        .overlay {
                            Image(systemName: attachment.isVideo ? "play.rectangle.fill" : "photo")
                                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        }
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                attachmentStatusBadge
                    .padding(8)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.white, Color.black.opacity(0.55))
                    .font(.system(size: 20))
            }
            .offset(x: 6, y: -6)
        }
    }

    @ViewBuilder
    private var attachmentStatusBadge: some View {
        switch attachment.uploadState {
        case .preparing:
            attachmentBadge(text: "Preparing", showsProgress: true)
        case .uploading:
            attachmentBadge(text: "Uploading", showsProgress: true)
        case .failed:
            attachmentBadge(text: "Failed", systemImage: "exclamationmark.triangle.fill")
        case .ready:
            EmptyView()
        }
    }

    private func attachmentBadge(
        text: String,
        systemImage: String? = nil,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.white)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }

            Text(text)
                .font(appSettings.appFont(.caption2, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.68), in: Capsule())
    }
}

private struct HaloLinkMessageRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let message: HaloLinkMessage
    let conversation: HaloLinkConversation?
    let currentAccountPubkey: String?
    @ObservedObject var store: HaloLinkStore
    let onReact: (String) -> Void

    @State private var isReactionPickerPresented = false

    var body: some View {
        VStack(
            alignment: message.isOutgoing ? .trailing : .leading,
            spacing: 4
        ) {
            if showSenderName {
                Text(store.displayName(for: message.senderPubkey))
                    .font(appSettings.appFont(.caption1, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .padding(.horizontal, 8)
            }

            bubble

            if !reactionSummaries.isEmpty {
                HStack(spacing: 6) {
                    ForEach(reactionSummaries, id: \.emoji) { summary in
                        HaloLinkReactionCircle(
                            summary: summary,
                            isHighlighted: summary.includesCurrentUser
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            if message.isPendingDelivery {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Sending...")
                        .font(appSettings.appFont(.caption1))
                        .foregroundStyle(appSettings.themePalette.tertiaryForeground)
                }
                .padding(.horizontal, 8)
            } else {
                Text(timestampText)
                    .font(appSettings.appFont(.caption1))
                    .foregroundStyle(appSettings.themePalette.tertiaryForeground)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isAttachmentMessage {
                HaloLinkMessageMediaView(message: message, store: store)
            }

            if let displayText {
                Text(displayText)
                    .font(appSettings.appFont(.body))
                    .foregroundStyle(message.isOutgoing ? appSettings.buttonTextColor : appSettings.themePalette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(bubbleBackground)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.28) {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
            isReactionPickerPresented = true
        }
        .sheet(isPresented: $isReactionPickerPresented) {
            HaloLinkMessageReactionPickerSheet { emoji in
                onReact(emoji)
            }
            .presentationDetents([.height(420), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                message.isOutgoing
                    ? AnyShapeStyle(appSettings.primaryGradient)
                    : AnyShapeStyle(appSettings.themePalette.secondaryGroupedBackground)
            )
            .overlay {
                if !message.isOutgoing {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(appSettings.themePalette.separator, lineWidth: 0.7)
                }
            }
    }

    private var showSenderName: Bool {
        conversation?.isGroup == true && !message.isOutgoing
    }

    private var trimmedText: String {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayText: String? {
        if message.isAttachmentMessage {
            guard !trimmedText.isEmpty else { return nil }
            if let url = URL(string: trimmedText), url.scheme != nil {
                return nil
            }
            return trimmedText
        }

        return trimmedText.isEmpty ? message.previewText : trimmedText
    }

    private var reactionSummaries: [HaloLinkReactionSummary] {
        conversation?.reactionSummaries(
            for: message.id,
            currentAccountPubkey: currentAccountPubkey
        ) ?? []
    }

    private var timestampText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: message.createdAtDate, relativeTo: Date())
    }
}

private struct HaloLinkReactionCircle: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let summary: HaloLinkReactionSummary
    let isHighlighted: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 36, height: 36)
                .haloNativeGlass(
                    tint: isHighlighted ? appSettings.primaryColor.opacity(0.16) : nil,
                    in: Circle()
                )

            Text(summary.emoji)
                .font(.system(size: 20))

            if summary.count > 1 {
                Text("\(summary.count)")
                    .font(appSettings.appFont(.caption2, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isHighlighted ? appSettings.primaryColor : appSettings.themePalette.secondaryForeground)
                    )
                    .offset(x: 6, y: 6)
            }
        }
        .frame(width: 42, height: 42)
    }
}

private struct HaloLinkMessageReactionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore

    @State private var searchQuery = ""

    let onSelectEmoji: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Reactions")
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)

                Text("Hold a message, then tap a quick reaction or browse the full emoji list.")
                    .font(appSettings.appFont(.footnote))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(haloLinkQuickReactionEmojis, id: \.self) { emoji in
                        Button {
                            select(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 28))
                        }
                        .haloNativeGlassButtonStyle()
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                    }
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Browse Emojis")
                    .font(appSettings.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.tertiaryForeground)

                    TextField("Search emoji or keyword", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(appSettings.appFont(.body))
                        .foregroundStyle(appSettings.themePalette.foreground)

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(appSettings.themePalette.tertiaryForeground)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear emoji search")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(appSettings.themePalette.secondaryGroupedBackground)
                )

                if filteredEmojiEntries.isEmpty {
                    Text("No emoji match that search yet.")
                        .font(appSettings.appFont(.footnote, weight: .medium))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: gridColumns, spacing: 10) {
                            ForEach(filteredEmojiEntries) { entry in
                                Button {
                                    select(entry.emoji)
                                } label: {
                                    Text(entry.emoji)
                                        .font(.system(size: 24))
                                }
                                .haloNativeGlassButtonStyle()
                                .buttonBorderShape(.roundedRectangle(radius: 14))
                                .controlSize(.large)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(appSettings.themePalette.background.ignoresSafeArea())
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 52, maximum: 60), spacing: 10)]
    }

    private var normalizedSearchQuery: String {
        searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var filteredEmojiEntries: [ImageRemixEmojiEntry] {
        let filteredEntries: [ImageRemixEmojiEntry]
        if normalizedSearchQuery.isEmpty {
            filteredEntries = ImageRemixEmojiEntry.catalog
        } else {
            let queryTerms = normalizedSearchQuery.split(whereSeparator: \.isWhitespace)
            filteredEntries = ImageRemixEmojiEntry.catalog.filter { entry in
                queryTerms.allSatisfy { entry.matches(searchTerm: String($0)) }
            }
        }

        let quickReactionSet = Set(haloLinkQuickReactionEmojis)
        return filteredEntries.filter { !quickReactionSet.contains($0.emoji) }
    }

    private func select(_ emoji: String) {
        onSelectEmoji(emoji)
        dismiss()
    }
}

private struct HaloLinkMessageMediaView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let message: HaloLinkMessage
    @ObservedObject var store: HaloLinkStore

    @State private var resolvedURL: URL?
    @State private var player: AVPlayer?
    @State private var loadError: String?
    @State private var fullscreenImage: HaloLinkFullscreenImage?

    var body: some View {
        Group {
            if let loadError {
                Text(loadError)
                    .font(appSettings.appFont(.caption1))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else if isVideo, let player {
                VideoPlayer(player: player)
                    .frame(width: 250, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if isImage, let resolvedURL {
                imageView(for: resolvedURL)
            } else {
                ProgressView()
                    .frame(width: 60, height: 60)
            }
        }
        .task(id: message.id) {
            await loadMedia()
        }
        .fullScreenCover(item: $fullscreenImage) { selected in
            HaloLinkImageFullscreenViewer(url: selected.url)
        }
    }

    private var mimeType: String {
        HaloLinkSupport.firstTagValue(named: "file-type", from: message.tags) ?? ""
    }

    private var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    private var isVideo: Bool {
        mimeType.lowercased().hasPrefix("video/")
    }

    @ViewBuilder
    private func imageView(for url: URL) -> some View {
        if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
            Button {
                fullscreenImage = HaloLinkFullscreenImage(url: url)
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 250, height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                fullscreenImage = HaloLinkFullscreenImage(url: url)
            } label: {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(appSettings.themePalette.secondaryGroupedBackground)
                    }
                }
                .frame(width: 250, height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func loadMedia() async {
        do {
            let url = try await store.mediaURL(for: message)
            resolvedURL = url
            if isVideo {
                player = AVPlayer(url: url)
            }
            loadError = nil
        } catch {
            loadError = "Unable to decrypt attachment"
        }
    }
}

private struct HaloLinkFullscreenImage: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

private struct HaloLinkImageFullscreenViewer: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .padding(16)
                        case .failure:
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.8))
                        case .empty:
                            ProgressView()
                                .tint(.white)
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
            .navigationTitle("Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ThemedToolbarDoneButton {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
