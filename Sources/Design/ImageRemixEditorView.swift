
import ImagePlayground
import SwiftUI
import UIKit


struct ImageRemixEditorView: View {
    let baseImage: UIImage
    let sourceEvent: NostrEvent?
    let currentAccountPubkey: String?
    let currentNsec: String?
    let writeRelayURLs: [URL]
    let onComposeRequested: ((ComposeMediaAttachment, NostrEvent?) -> Void)?
    let onApplyEditedImage: ((UIImage) async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var filteredPreviewImage: UIImage
    @State private var selectedTool: ImageRemixTool?
    @State private var selectedFilter: ImageRemixFilterPreset = .original
    @State private var previewRequestID = UUID()
    @State private var isPreparingFilter = false
    @State private var strokes: [ImageRemixStroke] = []
    @State private var activeStrokePoints: [CGPoint] = []
    @State private var textOverlays: [ImageRemixTextOverlay] = []
    @State private var stickerOverlays: [ImageRemixStickerOverlay] = []
    @State private var selectedOverlayID: UUID?
    @State private var draftText = ""
    @State private var stickerSearchQuery = ""
    @State private var draftTextPalette: ImageRemixPalette = .sunlight
    @State private var draftTextPlacement: ImageRemixTextPlacement = .center
    @State private var draftStickerScale: CGFloat = 0.15
    @State private var draftTextScale: CGFloat = 0.09
    @State private var draftBrushPalette: ImageRemixPalette = .polar
    @State private var draftBrushWidth: CGFloat = 0.012
    @State private var redoStrokes: [ImageRemixStroke] = []
    @State private var isToolPanelExpanded = false
    @State private var isSavingImage = false
    @State private var isUploadingImage = false
    @State private var isApplyingEditedImage = false
    @State private var isShowingPostOptions = false
    @State private var confirmationBannerMessage: String?
    @State private var confirmationBannerRequestID = UUID()
    @State private var subjectSelection: HaloSubjectSelection?
    @State private var subjectEditedImage: UIImage?
    @State private var isSelectingSubject = false
    @State private var isShowingImagePlayground = false
    @State private var imagePlaygroundSourceImage: UIImage?

    private let mediaUploadService = MediaUploadService.shared

    init(
        sourceImage: UIImage,
        sourceEvent: NostrEvent,
        currentAccountPubkey: String?,
        currentNsec: String?,
        writeRelayURLs: [URL],
        onComposeRequested: @escaping (ComposeMediaAttachment, NostrEvent?) -> Void
    ) {
        let preparedImage = sourceImage.flowPreparedForRemix(maxDimension: 1_800)
        self.baseImage = preparedImage
        self.sourceEvent = sourceEvent
        self.currentAccountPubkey = currentAccountPubkey
        self.currentNsec = currentNsec
        self.writeRelayURLs = writeRelayURLs
        self.onComposeRequested = onComposeRequested
        self.onApplyEditedImage = nil
        _filteredPreviewImage = State(initialValue: preparedImage)
    }

    init(
        sourceImage: UIImage,
        onApplyEditedImage: @escaping (UIImage) async throws -> Void
    ) {
        let preparedImage = sourceImage.flowPreparedForRemix(maxDimension: 1_800)
        self.baseImage = preparedImage
        self.sourceEvent = nil
        self.currentAccountPubkey = nil
        self.currentNsec = nil
        self.writeRelayURLs = []
        self.onComposeRequested = nil
        self.onApplyEditedImage = onApplyEditedImage
        _filteredPreviewImage = State(initialValue: preparedImage)
    }

    var body: some View {
        configuredEditorContent
    }

    @ViewBuilder
    private var configuredEditorContent: some View {
        if #available(iOS 27.0, *) {
            editorContent
                .imagePlaygroundSheet(
                    isPresented: $isShowingImagePlayground,
                    concepts: [],
                    sourceImage: imagePlaygroundSourceImage.map(Image.init(uiImage:)),
                    onCompletion: handleImagePlaygroundCompletion
                )
                .imagePlaygroundGenerationStyle(
                    .illustration,
                    in: [.animation, .illustration, .sketch]
                )
                .imagePlaygroundOptions(imagePlaygroundOptions27)
        } else if #available(iOS 18.4, *) {
            editorContent
                .imagePlaygroundSheet(
                    isPresented: $isShowingImagePlayground,
                    concepts: [],
                    sourceImage: imagePlaygroundSourceImage.map(Image.init(uiImage:)),
                    onCompletion: handleImagePlaygroundCompletion
                )
                .imagePlaygroundGenerationStyle(
                    .illustration,
                    in: [.animation, .illustration, .sketch]
                )
        } else if #available(iOS 18.1, *) {
            editorContent
                .imagePlaygroundSheet(
                    isPresented: $isShowingImagePlayground,
                    concepts: [],
                    sourceImage: imagePlaygroundSourceImage.map(Image.init(uiImage:)),
                    onCompletion: handleImagePlaygroundCompletion
                )
        } else {
            editorContent
        }
    }

    private var editorContent: some View {
        ZStack {
            remixBackground

            if isShowingPostOptions {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                            isShowingPostOptions = false
                        }
                    }
            }

            VStack(spacing: 0) {
                topBar

                GeometryReader { geometry in
                    let canvasSize = fittedCanvasSize(in: geometry.size)

                    VStack(spacing: 0) {
                        editorCanvas(canvasSize: canvasSize)
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .background(editorBackgroundColor)
                            .clipped()
                            .overlay(
                                Rectangle()
                                    .stroke(canvasBorderColor, lineWidth: 1)
                            )

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 22)
                    .padding(.top, canvasTopPadding)
                    .padding(.bottom, 16)
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isToolPanelExpanded)
                }
            }

            if isPreparingFilter || isSavingImage || isUploadingImage || isApplyingEditedImage || isSelectingSubject {
                processingOverlay
            }

            if let confirmationBannerMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        Text(confirmationBannerMessage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.top, 86)

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom) {
            bottomToolPanel
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
        .onChange(of: selectedFilter) { _, _ in
            refreshFilteredPreview()
        }
    }

    @available(iOS 27.0, *)
    private var imagePlaygroundOptions27: ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        options.creationStrategy = .editExisting
        options.creationVariety = .high
        options.personalization = .disabled
        options.sizeSpecification = .closest(to: workingBaseImage.size)
        return options
    }

    private var remixBackground: some View {
        Rectangle()
            .fill(editorBackgroundColor)
            .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(chromePrimaryColor)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close editor")

            VStack(alignment: .leading, spacing: 2) {
                Text(editorTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(chromePrimaryColor)

                Text(editorSubtitle)
                    .font(.footnote)
                    .foregroundStyle(chromeSecondaryColor)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    await saveEditedImageToLibrary()
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(chromePrimaryColor)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("Save edited image")

            if isEditingComposeAttachment {
                Button {
                    Task {
                        await applyEditedImageToComposeAttachment()
                    }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(appSettings.buttonTextColor)
                        .frame(width: 42, height: 42)
                        .background(appSettings.primaryGradient, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .opacity(isBusy ? 0.65 : 1)
                .accessibilityLabel("Use edited image")
            } else {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        isShowingPostOptions.toggle()
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(appSettings.buttonTextColor)
                        .frame(width: 42, height: 42)
                        .background(appSettings.primaryGradient, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .opacity(isBusy ? 0.65 : 1)
                .accessibilityLabel("Post remix")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .overlay(alignment: .topTrailing) {
            if isShowingPostOptions {
                postOptionsDropdown
                    .padding(.trailing, 16)
                    .offset(y: 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .zIndex(1)
    }

    private var postOptionsDropdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                beginPostFlow(forReply: false)
            } label: {
                postOptionRow(
                    title: "Post as new note",
                    subtitle: "Open composer with your remix attached",
                    systemImage: "square.and.pencil"
                )
            }
            .buttonStyle(.plain)

            Button {
                beginPostFlow(forReply: true)
            } label: {
                postOptionRow(
                    title: "Reply with remix",
                    subtitle: "Attach it to a reply composer",
                    systemImage: "arrowshape.turn.up.left"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(postOptionsBackgroundColor)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(controlBorderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 10)
    }

    private func postOptionRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appSettings.buttonTextColor)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(appSettings.primaryGradient)
                        .opacity(0.88)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chromePrimaryColor)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(chromeSecondaryColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 234, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(controlRowFillColor)
        )
    }

    private var bottomToolPanel: some View {
        VStack(alignment: .leading, spacing: isToolPanelExpanded ? 16 : 0) {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ImageRemixTool.allCases) { tool in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                    selectedTool = tool
                                    isToolPanelExpanded = true
                                }
                            } label: {
                                ImageRemixToolButtonLabel(
                                    tool: tool,
                                    isSelected: selectedTool == tool,
                                    showsTitle: isToolPanelExpanded,
                                    accentColor: appSettings.primaryColor
                                )
                                .frame(width: isToolPanelExpanded ? 76 : 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                        isToolPanelExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isToolPanelExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(chromePrimaryColor)
                        .frame(width: 40, height: 40)
                        .background(controlFillColor, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isToolPanelExpanded ? "Minimize tools" : "Expand tools")
            }

            if isToolPanelExpanded {
                Group {
                    if let selectedTool {
                        switch selectedTool {
                        case .filters:
                            filtersPanel
                        case .subjects:
                            subjectsPanel
                        case .draw:
                            drawPanel
                        case .text:
                            textPanel
                        case .stickers:
                            stickersPanel
                        case .create:
                            createPanel
                        }
                    } else {
                        toolSelectionPrompt
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(toolPanelTint)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(toolPanelBorder, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var filtersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fun Filters")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chromePrimaryColor)

            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(ImageRemixFilterPreset.allCases) { preset in
                            Button {
                                selectedFilter = preset
                            } label: {
                                ImageRemixFilterPresetChip(
                                    preset: preset,
                                    isSelected: selectedFilter == preset,
                                    accentColor: appSettings.primaryColor
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 58)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        colors: [.clear, edgeFadeColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 34)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(chromeTertiaryColor)
                        .padding(.trailing, 4)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var subjectsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Subject")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chromePrimaryColor)

                Spacer(minLength: 0)

                if isSelectingSubject {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if #available(iOS 27.0, *) {
                Text(subjectSelection == nil
                     ? "Tap a subject in the image to select it on device."
                     : "Subject selected. Choose how to separate it from the background.")
                    .font(.caption)
                    .foregroundStyle(chromeSecondaryColor)

                HStack(spacing: 10) {
                    Button {
                        applySubjectEffect(\.blurredBackground)
                    } label: {
                        Label("Blur background", systemImage: "camera.aperture")
                    }
                    .buttonStyle(ImageRemixSecondaryButtonStyle())
                    .disabled(subjectSelection == nil || isSelectingSubject)

                    Button {
                        applySubjectEffect(\.cutout)
                    } label: {
                        Label("Lift subject", systemImage: "person.crop.rectangle.badge.plus")
                    }
                    .buttonStyle(ImageRemixSecondaryButtonStyle())
                    .disabled(subjectSelection == nil || isSelectingSubject)
                }

                if subjectEditedImage != nil || subjectSelection != nil {
                    Button {
                        resetSubjectEdits()
                    } label: {
                        Label("Reset subject edit", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(ImageRemixSecondaryButtonStyle())
                    .disabled(isSelectingSubject)
                }
            } else {
                Label("Subject selection requires iOS 27.", systemImage: "iphone.gen3")
                    .font(.caption)
                    .foregroundStyle(chromeSecondaryColor)
            }
        }
    }

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image Playground")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chromePrimaryColor)

            Text("Open the system editor with this composition as the source image.")
                .font(.caption)
                .foregroundStyle(chromeSecondaryColor)

            if #available(iOS 18.1, *), ImagePlaygroundViewController.isAvailable {
                Button {
                    openImagePlayground()
                } label: {
                    Label("Create variation", systemImage: "wand.and.stars")
                }
                .buttonStyle(ImageRemixAccentButtonStyle(color: appSettings.primaryColor))
                .disabled(isBusy)
            } else {
                Label("Image Playground isn't available on this device.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(chromeSecondaryColor)
            }
        }
    }

    private var drawPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Brush")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chromePrimaryColor)

                Spacer(minLength: 0)

                Text("Draw right on the image")
                    .font(.caption)
                    .foregroundStyle(chromeSecondaryColor)
            }

            ImageRemixPaletteStrip(
                title: "Color",
                selected: draftBrushPalette,
                onSelect: { draftBrushPalette = $0 }
            )

            HStack(spacing: 12) {
                Text("Width")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(chromeMutedColor)
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(draftBrushWidth) },
                        set: { draftBrushWidth = CGFloat($0) }
                    ),
                    in: 0.005...0.028
                )
                .tint(appSettings.primaryColor)
            }

            HStack(spacing: 10) {
                Button {
                    undoLastStroke()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(ImageRemixSecondaryButtonStyle())
                .disabled(strokes.isEmpty)

                Button {
                    redoLastStroke()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(ImageRemixSecondaryButtonStyle())
                .disabled(redoStrokes.isEmpty)

                Button {
                    strokes.removeAll()
                    redoStrokes.removeAll()
                    activeStrokePoints.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(ImageRemixSecondaryButtonStyle())
                .disabled(strokes.isEmpty && activeStrokePoints.isEmpty)
            }
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Text")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chromePrimaryColor)

                Spacer(minLength: 0)

                Text(selectedTextOverlay == nil ? "Type and drop it in" : "Drag it or snap it below")
                    .font(.caption)
                    .foregroundStyle(chromeSecondaryColor)
            }

            HStack(spacing: 10) {
                TextField("Write something loud", text: $draftText)
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(controlFillColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(chromePrimaryColor)

                Button("Add") {
                    addTextOverlay()
                }
                .buttonStyle(ImageRemixAccentButtonStyle(color: appSettings.primaryColor))
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ImageRemixPaletteStrip(
                title: "Color",
                selected: activeTextPalette,
                onSelect: { palette in
                    if let selectedID = selectedTextOverlay?.id {
                        updateTextOverlay(id: selectedID) { overlay in
                            overlay.palette = palette
                        }
                    } else {
                        draftTextPalette = palette
                    }
                }
            )

            HStack(spacing: 12) {
                Text("Size")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(chromeMutedColor)
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(activeTextScale) },
                        set: { newValue in
                            if let selectedID = selectedTextOverlay?.id {
                                updateTextOverlay(id: selectedID) { overlay in
                                    overlay.scale = CGFloat(newValue)
                                }
                            } else {
                                draftTextScale = CGFloat(newValue)
                            }
                        }
                    ),
                    in: 0.055...0.16
                )
                .tint(appSettings.primaryColor)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Position")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(chromeMutedColor)

                    Spacer(minLength: 0)

                    Text(activeTextPlacement?.title ?? "Custom")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(chromePrimaryColor.opacity(0.82))
                }

                HStack(alignment: .bottom, spacing: 12) {
                    ImageRemixTextPlacementPicker(
                        selectedPlacement: activeTextPlacement,
                        accentColor: appSettings.primaryColor,
                        onSelect: applyTextPlacement(_:)
                    )

                    if let selectedTextOverlay {
                        Button("Delete", role: .destructive) {
                            textOverlays.removeAll { $0.id == selectedTextOverlay.id }
                            selectedOverlayID = nil
                        }
                        .buttonStyle(ImageRemixSecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var stickersPanel: some View {
        let stickerResults = filteredStickerEntries
        let stickerGridColumns = Array(repeating: GridItem(.flexible(minimum: 0, maximum: 42), spacing: 8), count: 7)
        let hasTypedEmojiCandidate = typedStickerCandidate != nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Emoji Stickers")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chromePrimaryColor)

                Spacer(minLength: 0)

                Text(normalizedStickerSearchQuery.isEmpty ? "Search, type, or tap to drop" : "\(stickerResults.count) result\(stickerResults.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(chromeSecondaryColor)
            }

            if normalizedStickerSearchQuery.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Picks")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(chromeMutedColor)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ImageRemixEmojiEntry.featured) { entry in
                                Button {
                                    selectStickerFromPicker(entry.emoji)
                                } label: {
                                    ImageRemixStickerLibraryBadge(emoji: entry.emoji, size: 42)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 42)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(chromeTertiaryColor)

                TextField("Search emoji or keyword", text: $stickerSearchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(chromePrimaryColor)

                if !stickerSearchQuery.isEmpty {
                    Button {
                        stickerSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(chromeTertiaryColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear emoji search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(controlFillColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let typedStickerCandidate {
                Button {
                    selectStickerFromPicker(typedStickerCandidate)
                } label: {
                    HStack(spacing: 10) {
                        ImageRemixStickerLibraryBadge(emoji: typedStickerCandidate, size: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use typed emoji")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(chromePrimaryColor)

                            Text(typedStickerCandidate)
                                .font(.caption)
                                .foregroundStyle(chromeSecondaryColor)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appSettings.primaryColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(controlRowFillColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if stickerResults.isEmpty {
                Text("No emoji match that search yet.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(chromeSecondaryColor)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: stickerGridColumns, spacing: 8) {
                        ForEach(stickerResults) { entry in
                            Button {
                                selectStickerFromPicker(entry.emoji)
                            } label: {
                                ImageRemixStickerLibraryBadge(emoji: entry.emoji, size: 40)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(height: hasTypedEmojiCandidate ? 138 : 154)
            }

            HStack(spacing: 12) {
                Text("Size")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(chromeMutedColor)
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(activeStickerScale) },
                        set: { newValue in
                            if let selectedID = selectedStickerOverlay?.id {
                                updateStickerOverlay(id: selectedID) { overlay in
                                    overlay.scale = CGFloat(newValue)
                                }
                            } else {
                                draftStickerScale = CGFloat(newValue)
                            }
                        }
                    ),
                    in: 0.08...0.24
                )
                .tint(appSettings.primaryColor)
            }

            if let selectedStickerOverlay {
                HStack(spacing: 10) {
                    Button("Center") {
                        updateStickerOverlay(id: selectedStickerOverlay.id) { overlay in
                            overlay.position = CGPoint(x: 0.5, y: 0.5)
                        }
                    }
                    .buttonStyle(ImageRemixSecondaryButtonStyle())

                    Button("Delete", role: .destructive) {
                        stickerOverlays.removeAll { $0.id == selectedStickerOverlay.id }
                        selectedOverlayID = nil
                    }
                    .buttonStyle(ImageRemixSecondaryButtonStyle())
                }
            }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(chromePrimaryColor)

                Text(progressTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chromePrimaryColor)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var toolSelectionPrompt: some View {
        Text("Pick a tool to start editing.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(chromeSecondaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func editorCanvas(canvasSize: CGSize) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedOverlayID = nil
                }

            Image(uiImage: filteredPreviewImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: canvasSize.width, height: canvasSize.height)

            if selectedTool == .subjects, let maskPreview = subjectSelection?.maskPreview {
                Image(uiImage: maskPreview)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(appSettings.primaryColor.opacity(0.44))
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .allowsHitTesting(false)
            }

            ImageRemixDrawingLayer(
                strokes: strokes,
                activeStrokePoints: activeStrokePoints,
                activeStrokeColor: draftBrushPalette.swiftUIColor,
                activeStrokeWidth: draftBrushWidth,
                canvasSize: canvasSize
            )

            ForEach(textOverlays) { overlay in
                ImageRemixDraggableTextOverlayView(
                    overlay: overlay,
                    canvasSize: canvasSize,
                    isHighlighted: overlay.id == selectedOverlayID && selectedTool != .draw,
                    allowsInteraction: selectedTool != .draw,
                    onSelect: {
                        selectedOverlayID = overlay.id
                        selectedTool = .text
                    },
                    onMove: { normalizedPosition in
                        updateTextOverlay(id: overlay.id) { mutableOverlay in
                            mutableOverlay.placement = nil
                            mutableOverlay.position = normalizedPosition
                        }
                    }
                )
            }

            ForEach(stickerOverlays) { overlay in
                ImageRemixDraggableStickerOverlayView(
                    overlay: overlay,
                    canvasSize: canvasSize,
                    isHighlighted: overlay.id == selectedOverlayID && selectedTool != .draw,
                    allowsInteraction: selectedTool != .draw,
                    onSelect: {
                        selectedOverlayID = overlay.id
                        selectedTool = .stickers
                    },
                    onMove: { normalizedPosition in
                        updateStickerOverlay(id: overlay.id) { mutableOverlay in
                            mutableOverlay.position = normalizedPosition
                        }
                    }
                )
            }

            if selectedTool == .draw {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let normalizedPoint = CGPoint(
                                    x: (value.location.x / canvasSize.width).clamped(to: 0...1),
                                    y: (value.location.y / canvasSize.height).clamped(to: 0...1)
                                )
                                activeStrokePoints.append(normalizedPoint)
                            }
                            .onEnded { _ in
                                guard activeStrokePoints.count > 1 else {
                                    activeStrokePoints.removeAll()
                                    return
                                }

                                strokes.append(
                                    ImageRemixStroke(
                                        points: activeStrokePoints,
                                        palette: draftBrushPalette,
                                        lineWidth: draftBrushWidth
                                    )
                                )
                                redoStrokes.removeAll()
                                activeStrokePoints.removeAll()
                            }
                    )
            }

            if selectedTool == .subjects {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                let normalizedPoint = CGPoint(
                                    x: (value.location.x / canvasSize.width).clamped(to: 0...1),
                                    y: (value.location.y / canvasSize.height).clamped(to: 0...1)
                                )
                                selectSubject(at: normalizedPoint)
                            }
                    )
                    .accessibilityLabel("Select image subject")
                    .accessibilityHint("Tap the subject to separate it from the background")
            }
        }
    }

    private var isBusy: Bool {
        isPreparingFilter || isSavingImage || isUploadingImage || isApplyingEditedImage || isSelectingSubject
    }

    private var isEditingComposeAttachment: Bool {
        onApplyEditedImage != nil
    }

    private var editorTitle: String {
        isEditingComposeAttachment ? "Edit image" : "Remix"
    }

    private var editorSubtitle: String {
        if selectedFilter != .original {
            return selectedFilter.title
        }
        return isEditingComposeAttachment ? "Adjust before posting" : "Add some chaos"
    }

    private var canvasTopPadding: CGFloat {
        isToolPanelExpanded ? 2 : 10
    }

    private var editorBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var canvasBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.05) : .black.opacity(0.06)
    }

    private var chromePrimaryColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.92)
    }

    private var chromeSecondaryColor: Color {
        colorScheme == .dark ? .white.opacity(0.72) : Color.black.opacity(0.68)
    }

    private var chromeMutedColor: Color {
        colorScheme == .dark ? .white.opacity(0.70) : Color.black.opacity(0.62)
    }

    private var chromeTertiaryColor: Color {
        colorScheme == .dark ? .white.opacity(0.56) : Color.black.opacity(0.48)
    }

    private var controlFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var controlRowFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)
    }

    private var controlBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    private var edgeFadeColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.55)
    }

    private var postOptionsBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.94)
            : Color(.systemBackground).opacity(0.94)
    }

    private var toolPanelTint: Color {
        colorScheme == .dark ? Color.black.opacity(0.34) : Color.white.opacity(0.28)
    }

    private var toolPanelBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    private var progressTitle: String {
        if isSelectingSubject {
            return "Finding subject..."
        }
        if isApplyingEditedImage {
            return "Updating image..."
        }
        if isUploadingImage {
            return "Uploading your remix..."
        }
        if isSavingImage {
            return "Saving to Photos..."
        }
        return "Applying \(selectedFilter.title)..."
    }

    private var selectedTextOverlay: ImageRemixTextOverlay? {
        guard let selectedOverlayID else { return nil }
        return textOverlays.first(where: { $0.id == selectedOverlayID })
    }

    private var workingBaseImage: UIImage {
        subjectEditedImage ?? baseImage
    }

    private var selectedStickerOverlay: ImageRemixStickerOverlay? {
        guard let selectedOverlayID else { return nil }
        return stickerOverlays.first(where: { $0.id == selectedOverlayID })
    }

    private var activeTextPalette: ImageRemixPalette {
        selectedTextOverlay?.palette ?? draftTextPalette
    }

    private var activeTextScale: CGFloat {
        selectedTextOverlay?.scale ?? draftTextScale
    }

    private var activeTextPlacement: ImageRemixTextPlacement? {
        if let selectedTextOverlay {
            return selectedTextOverlay.placement
        }
        return draftTextPlacement
    }

    private var activeStickerScale: CGFloat {
        selectedStickerOverlay?.scale ?? draftStickerScale
    }

    private var normalizedStickerSearchQuery: String {
        stickerSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var typedStickerCandidate: String? {
        normalizedStickerSearchQuery.firstEmojiCluster
    }

    private var filteredStickerEntries: [ImageRemixEmojiEntry] {
        guard !normalizedStickerSearchQuery.isEmpty else {
            return ImageRemixEmojiEntry.catalog
        }

        let queryTerms = normalizedStickerSearchQuery.split(whereSeparator: \.isWhitespace)
        return ImageRemixEmojiEntry.catalog.filter { entry in
            queryTerms.allSatisfy { entry.matches(searchTerm: String($0)) }
        }
    }

    private func fittedCanvasSize(in availableSize: CGSize) -> CGSize {
        let sourceSize = workingBaseImage.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: max(availableSize.width - 40, 0), height: max(availableSize.height - 40, 0))
        }

        let maxWidth = max(availableSize.width - 40, 120)
        let maxHeight = max(availableSize.height - 40, 120)
        let widthRatio = maxWidth / sourceSize.width
        let heightRatio = maxHeight / sourceSize.height
        let scale = min(widthRatio, heightRatio)
        return CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
    }

    private func refreshFilteredPreview() {
        previewRequestID = UUID()
        let requestID = previewRequestID
        let preset = selectedFilter
        let source = workingBaseImage

        if preset == .original {
            filteredPreviewImage = source
            isPreparingFilter = false
            return
        }

        isPreparingFilter = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = ImageRemixFilterProcessor.renderedImage(for: preset, from: source)
            DispatchQueue.main.async {
                guard previewRequestID == requestID else { return }
                filteredPreviewImage = rendered
                isPreparingFilter = false
            }
        }
    }

    private func addTextOverlay() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let overlay = ImageRemixTextOverlay(
            text: trimmed,
            palette: draftTextPalette,
            scale: draftTextScale,
            position: draftTextPlacement.normalizedAnchorPoint,
            placement: draftTextPlacement
        )
        textOverlays.append(overlay)
        selectedOverlayID = overlay.id
        draftText = ""
    }

    private func addStickerOverlay(emoji: String) {
        let offset = min(CGFloat(stickerOverlays.count), 4) * 0.05
        let overlay = ImageRemixStickerOverlay(
            emoji: emoji,
            scale: draftStickerScale,
            position: CGPoint(
                x: (0.5 - offset).clamped(to: 0.16...0.84),
                y: (0.5 + offset * 0.35).clamped(to: 0.2...0.8)
            )
        )
        stickerOverlays.append(overlay)
        selectedOverlayID = overlay.id
    }

    private func selectStickerFromPicker(_ emoji: String) {
        addStickerOverlay(emoji: emoji)
        stickerSearchQuery = ""
    }

    private func undoLastStroke() {
        guard let removedStroke = strokes.popLast() else { return }
        redoStrokes.append(removedStroke)
    }

    private func redoLastStroke() {
        guard let restoredStroke = redoStrokes.popLast() else { return }
        strokes.append(restoredStroke)
    }

    private func updateTextOverlay(id: UUID, mutate: (inout ImageRemixTextOverlay) -> Void) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        var overlay = textOverlays[index]
        mutate(&overlay)
        overlay.position = overlay.position.clampedToUnitSquare()
        textOverlays[index] = overlay
    }

    private func applyTextPlacement(_ placement: ImageRemixTextPlacement) {
        if let selectedID = selectedTextOverlay?.id {
            updateTextOverlay(id: selectedID) { overlay in
                overlay.placement = placement
                overlay.position = placement.normalizedAnchorPoint
            }
        } else {
            draftTextPlacement = placement
        }
    }

    private func updateStickerOverlay(id: UUID, mutate: (inout ImageRemixStickerOverlay) -> Void) {
        guard let index = stickerOverlays.firstIndex(where: { $0.id == id }) else { return }
        var overlay = stickerOverlays[index]
        mutate(&overlay)
        overlay.position = overlay.position.clampedToUnitSquare()
        stickerOverlays[index] = overlay
    }

    private func selectSubject(at normalizedPoint: CGPoint) {
        guard !isSelectingSubject else { return }
        guard #available(iOS 27.0, *) else {
            toastCenter.show("Subject selection requires iOS 27.", style: .error, duration: 2.8)
            return
        }

        isSelectingSubject = true
        let source = filteredPreviewImage
        Task {
            do {
                let selection = try await HaloSubjectSegmentation.selectSubject(
                    in: source,
                    at: normalizedPoint
                )
                subjectSelection = selection
                isSelectingSubject = false
                showConfirmationBanner("Subject selected")
            } catch {
                isSelectingSubject = false
                subjectSelection = nil
                toastCenter.show(
                    (error as? LocalizedError)?.errorDescription ?? "Halo couldn't select that subject.",
                    style: .error,
                    duration: 2.8
                )
            }
        }
    }

    private func applySubjectEffect(_ keyPath: KeyPath<HaloSubjectSelection, UIImage>) {
        guard let subjectSelection else { return }
        subjectEditedImage = subjectSelection[keyPath: keyPath]
        selectedFilter = .original
        filteredPreviewImage = subjectSelection[keyPath: keyPath]
        self.subjectSelection = nil
    }

    private func resetSubjectEdits() {
        subjectSelection = nil
        subjectEditedImage = nil
        refreshFilteredPreview()
    }

    private func openImagePlayground() {
        guard #available(iOS 18.1, *), ImagePlaygroundViewController.isAvailable else {
            toastCenter.show("Image Playground isn't available on this device.", style: .error, duration: 2.8)
            return
        }
        imagePlaygroundSourceImage = renderEditedImage()
        isShowingImagePlayground = true
    }

    private func handleImagePlaygroundCompletion(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let generatedImage = UIImage(data: data)?.flowPreparedForRemix(maxDimension: 1_800) else {
            toastCenter.show("Halo couldn't open the created image.", style: .error, duration: 2.8)
            return
        }

        subjectEditedImage = generatedImage
        subjectSelection = nil
        selectedFilter = .original
        filteredPreviewImage = generatedImage
        strokes.removeAll()
        redoStrokes.removeAll()
        textOverlays.removeAll()
        stickerOverlays.removeAll()
        selectedOverlayID = nil
        imagePlaygroundSourceImage = nil
        showConfirmationBanner("Variation added")
    }

    private func renderEditedImage() -> UIImage {
        let filteredImage = ImageRemixFilterProcessor.renderedImage(for: selectedFilter, from: workingBaseImage)
        let content = ImageRemixStaticCompositionView(
            image: filteredImage,
            canvasSize: filteredImage.size,
            strokes: strokes,
            textOverlays: textOverlays,
            stickerOverlays: stickerOverlays
        )

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(filteredImage.size)
        return renderer.uiImage ?? filteredImage
    }

    private func saveEditedImageToLibrary() async {
        guard !isBusy else { return }
        isSavingImage = true
        let image = renderEditedImage()

        let authorizationStatus = await ImageRemixPhotoLibrary.requestWriteAuthorizationIfNeeded()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            isSavingImage = false
            toastCenter.show("Photos access is needed to save.", style: .error, duration: 2.8)
            return
        }

        do {
            try await ImageRemixPhotoLibrary.save(image: image)
            isSavingImage = false
            toastCenter.show("Saved")
            showConfirmationBanner("Saved to Photos")
        } catch {
            isSavingImage = false
            toastCenter.show(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't save that image right now.",
                style: .error,
                duration: 2.8
            )
        }
    }

    private func uploadEditedImage(forReply: Bool) async {
        guard !isBusy else { return }
        guard let sourceEvent, let onComposeRequested else { return }

        guard let normalizedNsec = currentNsec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedNsec.isEmpty else {
            toastCenter.show("Sign in to post remixes.", style: .error, duration: 2.8)
            return
        }

        guard !writeRelayURLs.isEmpty else {
            toastCenter.show("Add a publish source before posting.", style: .error, duration: 2.8)
            return
        }

        let image = renderEditedImage()
        guard let encodedImage = ImageRemixUploadEncoding(image: image) else {
            toastCenter.show("Couldn't prepare that image for upload.", style: .error, duration: 2.8)
            return
        }

        isUploadingImage = true
        defer {
            isUploadingImage = false
        }

        do {
            let result = try await mediaUploadService.uploadMedia(
                data: encodedImage.data,
                mimeType: encodedImage.mimeType,
                filename: "remix-\(UUID().uuidString).\(encodedImage.fileExtension)",
                nsec: normalizedNsec,
                provider: appSettings.mediaUploadProvider
            )

            onComposeRequested(
                ComposeMediaAttachment(
                    url: result.url,
                    imetaTag: result.imetaTag,
                    mimeType: encodedImage.mimeType,
                    fileSizeBytes: encodedImage.data.count
                ),
                forReply ? sourceEvent : nil
            )
        } catch {
            toastCenter.show(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't upload that remixed image right now.",
                style: .error,
                duration: 2.8
            )
        }
    }

    private func beginPostFlow(forReply: Bool) {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            isShowingPostOptions = false
        }

        Task {
            await uploadEditedImage(forReply: forReply)
        }
    }

    private func applyEditedImageToComposeAttachment() async {
        guard !isBusy, let onApplyEditedImage else { return }

        isApplyingEditedImage = true
        defer {
            isApplyingEditedImage = false
        }

        do {
            try await onApplyEditedImage(renderEditedImage())
            dismiss()
        } catch {
            toastCenter.show(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't update that image right now.",
                style: .error,
                duration: 2.8
            )
        }
    }

    private func showConfirmationBanner(_ message: String) {
        let requestID = UUID()
        confirmationBannerRequestID = requestID
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            confirmationBannerMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            guard confirmationBannerRequestID == requestID else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                confirmationBannerMessage = nil
            }
        }
    }
}
