import NostrSDK
import SwiftUI
import UIKit

struct NoteImageFullscreenViewer: View {
    let urls: [URL]
    let sourceEvent: NostrEvent
    let reactionCount: Int
    let commentCount: Int
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var composeSheetCoordinator: AppComposeSheetCoordinator
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reactionStats = NoteReactionStatsService.shared
    @State private var selectedIndex: Int
    @State private var isShowingInlineResharePanel = false
    @State private var isPublishingRepost = false
    @State private var repostStatusMessage: String?
    @State private var repostStatusIsError = false
    @State private var remixSourceImage: UIImage?
    @State private var pendingRemixComposeDraft: NoteImageRemixComposeDraft?
    @State private var isShowingRemixEditor = false
    @State private var isPreparingRemixEditor = false
    @State private var zoomedImageIndices = Set<Int>()
    @State private var swipeDismissOffset: CGSize = .zero
    @State private var isCompletingSwipeDismiss = false
    private let reshareService = ResharePublishService()
    private let reactionPublishService = NoteReactionPublishService()

    init(urls: [URL], sourceEvent: NostrEvent, initialIndex: Int, reactionCount: Int, commentCount: Int) {
        self.urls = urls
        self.sourceEvent = sourceEvent
        self.reactionCount = reactionCount
        self.commentCount = commentCount
        _selectedIndex = State(initialValue: max(0, min(initialIndex, max(urls.count - 1, 0))))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                viewerBackgroundColor
                    .opacity(viewerBackgroundOpacity(for: geometry.size))
                    .ignoresSafeArea()

                NavigationStack {
                    TabView(selection: $selectedIndex) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            ZStack {
                                viewerBackgroundColor.ignoresSafeArea()
                                NoteZoomableFullscreenImageView(
                                    url: url,
                                    chromeForegroundColor: chromeForegroundColor,
                                    onZoomStateChange: { isZoomed in
                                        updateZoomState(isZoomed, for: index)
                                    }
                                )
                            }
                            .tag(index)
                            .flowRemoteImageSaveContextMenu(url: url)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(doneButtonForegroundColor)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close")
                        }
                    }
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarBackground(viewerNavigationBarColor, for: .navigationBar)
                    .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
                    .safeAreaInset(edge: .bottom) {
                        mediaActionBar
                    }
                }
                .offset(swipeDismissOffset)
                .scaleEffect(viewerScale(for: geometry.size))
                .rotationEffect(.degrees(viewerRotationDegrees(for: geometry.size)))
                .simultaneousGesture(swipeToDismissGesture(containerSize: geometry.size))
                .allowsHitTesting(!isShowingInlineResharePanel)

                if isShowingInlineResharePanel {
                    fullscreenReshareOverlay
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .fullScreenCover(
            isPresented: $isShowingRemixEditor,
            onDismiss: handleRemixEditorDismissed
        ) {
            if let remixSourceImage {
                ImageRemixEditorView(
                    sourceImage: remixSourceImage,
                    sourceEvent: sourceEvent,
                    currentAccountPubkey: auth.currentAccount?.pubkey,
                    currentNsec: auth.currentNsec,
                    writeRelayURLs: effectiveWriteRelayURLs,
                    onComposeRequested: { attachment, replyTargetEvent in
                        pendingRemixComposeDraft = NoteImageRemixComposeDraft(
                            attachment: attachment,
                            replyTargetEvent: replyTargetEvent
                        )
                        isShowingRemixEditor = false
                    }
                )
            }
        }
        .task {
            reactionStats.prefetch(events: [sourceEvent], relayURLs: effectiveReadRelayURLs)
        }
    }

    private var mediaActionBar: some View {
        HStack(spacing: 16) {
            Button {
                presentReplyComposer()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                    if visibleReplyCount > 0 {
                        Text("\(visibleReplyCount)")
                            .font(.footnote)
                    }
                }
                .foregroundStyle(chromeForegroundColor)
                .frame(minWidth: 36, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply")

            Button {
                repostStatusMessage = nil
                repostStatusIsError = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    isShowingInlineResharePanel = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                    if visibleRepostCount > 0 {
                        Text("\(visibleRepostCount)")
                            .font(.footnote)
                    }
                }
                .foregroundStyle(chromeForegroundColor)
                .frame(minWidth: 36, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Re-share")

            ReactionButton(
                isLiked: isLikedByCurrentUser,
                isBonusReaction: isBonusReactionByCurrentUser,
                count: visibleReactionCount,
                bonusActiveColor: appSettings.primaryColor,
                inactiveColor: chromeForegroundColor,
                minWidth: 36
            ) { bonusCount in
                Task {
                    await handleReactionTap(bonusCount: bonusCount)
                }
            }

            ShareLink(item: urls[selectedIndex]) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(chromeForegroundColor)
                    .frame(minWidth: 36, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")

            Button {
                Task {
                    await openRemixEditor()
                }
            } label: {
                Group {
                    if isPreparingRemixEditor {
                        ProgressView()
                            .controlSize(.small)
                            .tint(appSettings.primaryColor)
                            .frame(minWidth: 36, minHeight: 28, alignment: .leading)
                    } else {
                        Image(systemName: "paintbrush.pointed.fill")
                            .foregroundStyle(appSettings.primaryColor)
                            .frame(minWidth: 36, minHeight: 28, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isPreparingRemixEditor)
            .accessibilityLabel("Edit image")
        }
        .font(.headline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var visibleReactionCount: Int {
        reactionStats.reactionCount(for: sourceEvent.id)
    }

    private var visibleReplyCount: Int {
        max(commentCount, reactionStats.replyCount(for: sourceEvent.id))
    }

    private var visibleRepostCount: Int {
        reactionStats.repostCount(for: sourceEvent.id)
    }

    private var isLikedByCurrentUser: Bool {
        reactionStats.isReactedByCurrentUser(
            for: sourceEvent.id,
            currentPubkey: auth.currentAccount?.pubkey
        )
    }

    private var isBonusReactionByCurrentUser: Bool {
        reactionStats.currentUserReaction(
            for: sourceEvent.id,
            currentPubkey: auth.currentAccount?.pubkey
        )?.bonusCount ?? 0 > 0
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: effectiveReadRelayURLs
        )
    }

    private var viewerBackgroundColor: Color {
        appSettings.themePalette.background
    }

    private var viewerNavigationBarColor: Color {
        appSettings.themePalette.navigationBackground
    }

    private var chromeForegroundColor: Color {
        appSettings.themePalette.foreground
    }

    private var doneButtonForegroundColor: Color {
        appSettings.themePalette.foreground
    }

    private var fullscreenReshareOverlay: some View {
        ZStack(alignment: .bottom) {
            appSettings.themePalette.overlayBackground
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isShowingInlineResharePanel = false
                    }
                }

            VStack(alignment: .leading, spacing: 16) {
                Capsule()
                    .fill(appSettings.themeSeparator(defaultOpacity: 0.82))
                    .frame(width: 42, height: 5)
                    .frame(maxWidth: .infinity)

                HStack {
                    Text("Re-share")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            isShowingInlineResharePanel = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                            .frame(width: 30, height: 30)
                            .background(appSettings.themePalette.tertiaryFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close re-share options")
                }

                VStack(spacing: 0) {
                    inlineReshareActionRow(
                        title: "Repost",
                        systemImage: "arrow.2.squarepath"
                    ) {
                        Task {
                            await publishRepost()
                        }
                    }

                    Divider()
                        .padding(.leading, 18)

                    inlineReshareActionRow(
                        title: "Quote",
                        systemImage: "quote.bubble"
                    ) {
                        presentQuoteComposer()
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(appSettings.themePalette.modalBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(appSettings.themeSeparator(defaultOpacity: 0.35), lineWidth: 0.8)
                        )
                )

                if let repostStatusMessage, !repostStatusMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: repostStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(repostStatusIsError ? .red : .green)
                        Text(repostStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(repostStatusIsError ? .red : appSettings.themePalette.secondaryForeground)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill((repostStatusIsError ? Color.red : Color.green).opacity(0.1))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(appSettings.themePalette.modalBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(appSettings.themeSeparator(defaultOpacity: 0.35), lineWidth: 0.7)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    @MainActor
    private func handleReactionTap(bonusCount: Int = 0) async {
        let eventID = sourceEvent.id
        guard reactionStats.beginPublishingReaction(for: eventID) else { return }
        let existingReaction = reactionStats.currentUserReaction(
            for: eventID,
            currentPubkey: auth.currentAccount?.pubkey
        )
        let optimisticToggle = reactionStats.applyOptimisticToggle(
            for: eventID,
            currentPubkey: auth.currentAccount?.pubkey,
            bonusCount: bonusCount
        )
        defer {
            reactionStats.endPublishingReaction(for: eventID)
        }

        do {
            let result = try await reactionPublishService.toggleReaction(
                for: sourceEvent,
                existingReactionID: existingReaction?.id,
                bonusCount: bonusCount,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                relayHintURL: effectiveReadRelayURLs.first
            )

            switch result {
            case .liked(let reactionEvent):
                reactionStats.registerPublishedReaction(
                    reactionEvent,
                    targetEventID: eventID
                )
            case .unliked(let reactionID):
                reactionStats.registerDeletedReaction(
                    reactionID: reactionID,
                    targetEventID: eventID
                )
            }
        } catch {
            reactionStats.rollbackOptimisticToggle(for: eventID, snapshot: optimisticToggle)
            return
        }
    }

    @ViewBuilder
    private func inlineReshareActionRow(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(appSettings.themePalette.foreground)

                Spacer(minLength: 0)

                if isPublishingRepost && title == "Repost" {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPublishingRepost)
    }

    @MainActor
    private func publishRepost() async {
        guard !isPublishingRepost else { return }
        isPublishingRepost = true
        repostStatusMessage = nil
        repostStatusIsError = false
        defer { isPublishingRepost = false }

        do {
            let relayCount = try await reshareService.publishRepost(
                of: sourceEvent,
                currentNsec: auth.currentNsec,
                writeRelayURLs: effectiveWriteRelayURLs,
                relayHintURL: effectiveReadRelayURLs.first
            )
            repostStatusMessage = "Reposted to \(relayCount) source\(relayCount == 1 ? "" : "s")."
            repostStatusIsError = false

            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                isShowingInlineResharePanel = false
            }
        } catch {
            repostStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            repostStatusIsError = true
        }
    }

    @MainActor
    private func openRemixEditor() async {
        guard !isPreparingRemixEditor else { return }
        isPreparingRemixEditor = true
        defer {
            isPreparingRemixEditor = false
        }

        let currentURL = urls[selectedIndex]
        guard let image = await FlowImageCache.shared.image(for: currentURL) else {
            toastCenter.show("Couldn't load that image for editing.", style: .error, duration: 2.8)
            return
        }

        composeSheetCoordinator.dismiss()
        pendingRemixComposeDraft = nil
        remixSourceImage = image
        isShowingRemixEditor = true
    }

    @MainActor
    private func handleRemixEditorDismissed() {
        remixSourceImage = nil

        guard let draft = pendingRemixComposeDraft else { return }
        pendingRemixComposeDraft = nil

        Task { @MainActor in
            // Dismiss the fullscreen image viewer before asking the app shell to present compose.
            dismiss()
            try? await Task.sleep(nanoseconds: 320_000_000)
            composeSheetCoordinator.presentRemix(
                attachment: draft.attachment,
                replyTargetEvent: draft.replyTargetEvent
            )
        }
    }

    @MainActor
    private func presentReplyComposer() {
        Task { @MainActor in
            dismiss()
            try? await Task.sleep(nanoseconds: 320_000_000)
            composeSheetCoordinator.presentReply(to: sourceEvent)
        }
    }

    @MainActor
    private func presentQuoteComposer() {
        let draft = reshareService.buildQuoteDraft(
            for: sourceEvent,
            relayHintURL: effectiveReadRelayURLs.first
        )

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            isShowingInlineResharePanel = false
        }

        Task { @MainActor in
            dismiss()
            try? await Task.sleep(nanoseconds: 320_000_000)
            composeSheetCoordinator.presentQuote(draft)
        }
    }

    private func swipeToDismissGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard !isShowingInlineResharePanel, !isShowingRemixEditor, !isPreparingRemixEditor else { return }
                guard !isCurrentImageZoomed else { return }
                guard shouldTrackSwipeDismiss(for: value.translation) else { return }
                swipeDismissOffset = value.translation
            }
            .onEnded { value in
                guard !isShowingInlineResharePanel, !isShowingRemixEditor else { return }
                guard !isCurrentImageZoomed else {
                    swipeDismissOffset = .zero
                    return
                }
                guard shouldTrackSwipeDismiss(for: value.translation) else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        swipeDismissOffset = .zero
                    }
                    return
                }

                let finalTranslation = projectedSwipeDismissOffset(for: value)
                if shouldCompleteSwipeDismiss(with: finalTranslation, in: containerSize) {
                    completeSwipeDismiss(using: finalTranslation, in: containerSize)
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        swipeDismissOffset = .zero
                    }
                }
            }
    }

    private func shouldTrackSwipeDismiss(for translation: CGSize) -> Bool {
        guard !isCompletingSwipeDismiss else { return false }
        if urls.count <= 1 {
            return true
        }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        if vertical >= max(horizontal * 0.7, 20) {
            return true
        }

        let isSwipingOutFromLeadingEdge = translation.width > 0 && selectedIndex == 0
        let isSwipingOutFromTrailingEdge = translation.width < 0 && selectedIndex == urls.count - 1
        return horizontal >= max(vertical * 1.25, 44) &&
            (isSwipingOutFromLeadingEdge || isSwipingOutFromTrailingEdge)
    }

    private func projectedSwipeDismissOffset(for value: DragGesture.Value) -> CGSize {
        CGSize(
            width: value.predictedEndTranslation.width,
            height: value.predictedEndTranslation.height
        )
    }

    private func shouldCompleteSwipeDismiss(with translation: CGSize, in size: CGSize) -> Bool {
        let distance = hypot(translation.width, translation.height)
        let threshold = max(150, min(size.width, size.height) * 0.18)
        return distance >= threshold
    }

    private func completeSwipeDismiss(using translation: CGSize, in size: CGSize) {
        guard !isCompletingSwipeDismiss else { return }
        isCompletingSwipeDismiss = true

        let targetOffset = swipeDismissCompletionOffset(for: translation, in: size)
        withAnimation(.easeOut(duration: 0.2)) {
            swipeDismissOffset = targetOffset
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            dismiss()
        }
    }

    private func swipeDismissCompletionOffset(for translation: CGSize, in size: CGSize) -> CGSize {
        let distance = max(hypot(translation.width, translation.height), 1)
        let direction = CGVector(dx: translation.width / distance, dy: translation.height / distance)
        let exitDistance = max(size.width, size.height) * 1.18
        return CGSize(
            width: direction.dx * exitDistance,
            height: direction.dy * exitDistance
        )
    }

    private func viewerBackgroundOpacity(for size: CGSize) -> Double {
        let distance = hypot(swipeDismissOffset.width, swipeDismissOffset.height)
        let maxDistance = max(min(size.width, size.height) * 0.75, 1)
        return max(0.35, 1 - (distance / maxDistance) * 0.75)
    }

    private func viewerScale(for size: CGSize) -> CGFloat {
        let distance = hypot(swipeDismissOffset.width, swipeDismissOffset.height)
        let maxDistance = max(max(size.width, size.height), 1)
        return max(0.9, 1 - (distance / maxDistance) * 0.09)
    }

    private func viewerRotationDegrees(for size: CGSize) -> Double {
        guard size.width > 0 else { return 0 }
        return Double(swipeDismissOffset.width / size.width) * 8
    }

    private var isCurrentImageZoomed: Bool {
        zoomedImageIndices.contains(selectedIndex)
    }

    private func updateZoomState(_ isZoomed: Bool, for index: Int) {
        if isZoomed {
            zoomedImageIndices.insert(index)
        } else {
            zoomedImageIndices.remove(index)
        }
    }
}

struct NoteImageRemixComposeDraft: Identifiable {
    let id = UUID()
    let attachment: ComposeMediaAttachment
    let replyTargetEvent: NostrEvent?
}
