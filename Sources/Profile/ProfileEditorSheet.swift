import PhotosUI
import SwiftUI
import UIKit

struct ProfileEditorSheet: View {
    enum UploadTarget {
        case avatar
        case banner
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var fields: EditableProfileFields
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedBannerItem: PhotosPickerItem?
    @State private var avatarPreviewImage: UIImage?
    @State private var bannerPreviewImage: UIImage?
    @State private var isUploadingAvatar = false
    @State private var isUploadingBanner = false
    @State private var avatarUploadError: String?
    @State private var bannerUploadError: String?
    @State private var avatarPreparedByteCount: Int?
    @State private var bannerPreparedByteCount: Int?
    @State private var avatarRemoteByteCount: Int?
    @State private var bannerRemoteByteCount: Int?
    @State private var isLoadingAvatarRemoteSize = false
    @State private var isLoadingBannerRemoteSize = false

    let previewHandle: String
    let followingCount: Int
    let isSaving: Bool
    let errorMessage: String?
    let onSave: (EditableProfileFields) async -> Bool
    let onUploadAvatar: (Data, String, String) async throws -> String
    let onUploadBanner: (Data, String, String) async throws -> String

    init(
        initialFields: EditableProfileFields,
        previewHandle: String,
        followingCount: Int,
        isSaving: Bool,
        errorMessage: String?,
        onSave: @escaping (EditableProfileFields) async -> Bool,
        onUploadAvatar: @escaping (Data, String, String) async throws -> String,
        onUploadBanner: @escaping (Data, String, String) async throws -> String
    ) {
        _fields = State(initialValue: initialFields)
        self.previewHandle = previewHandle
        self.followingCount = followingCount
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onUploadAvatar = onUploadAvatar
        self.onUploadBanner = onUploadBanner
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    previewSection
                    imagesSection
                    profileSection
                    linksSection
                    errorsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
            .background(appSettings.themePalette.sheetBackground.ignoresSafeArea())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appSettings.themePalette.sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveBar
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(appSettings.themePalette.sheetBackground)
        .onChange(of: selectedAvatarItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await uploadImage(from: newItem, target: .avatar)
            }
        }
        .onChange(of: selectedBannerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await uploadImage(from: newItem, target: .banner)
            }
        }
        .task(id: avatarRemoteAssetLookupID) {
            await refreshRemoteAssetSize(for: .avatar)
        }
        .task(id: bannerRemoteAssetLookupID) {
            await refreshRemoteAssetSize(for: .banner)
        }
    }

    private var isBusy: Bool {
        isSaving || isUploadingAvatar || isUploadingBanner
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Live Preview")

            ProfileEditorPreviewCard(
                fields: fields,
                previewHandle: previewHandle,
                followingCount: followingCount,
                avatarPreviewImage: avatarPreviewImage,
                bannerPreviewImage: bannerPreviewImage
            )
        }
    }

    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Images")

            editorCard {
                VStack(alignment: .leading, spacing: 16) {
                    imageUploadRow(
                        title: "Banner",
                        systemImage: "photo.stack",
                        previewImage: bannerPreviewImage,
                        remoteURLString: fields.bannerURLString,
                        byteCount: bannerByteCount,
                        isLoadingRemoteSize: isLoadingBannerRemoteSize,
                        isUploading: isUploadingBanner,
                        errorMessage: bannerUploadError,
                        selection: $selectedBannerItem,
                        accessibilityLabel: "Upload profile banner",
                        recommendedHint: "Recommended size: 1200×1600, up to 2.5 MB.",
                        maximumRecommendedBytes: maximumRecommendedProfileBannerAssetBytes,
                        oversizedWarningText: "This banner is over 2.5 MB. Re-upload it with Halo so we can resize it properly.",
                        emptyStateText: "No banner uploaded. Your theme color or gradient will be shown instead.",
                        usesCircularPreview: false,
                        removeAccessibilityLabel: "Remove profile banner",
                        onRemove: { removeImage(.banner) }
                    )

                    Divider()

                    imageUploadRow(
                        title: "Profile Photo",
                        systemImage: "person.crop.circle",
                        previewImage: avatarPreviewImage,
                        remoteURLString: fields.avatarURLString,
                        byteCount: avatarByteCount,
                        isLoadingRemoteSize: isLoadingAvatarRemoteSize,
                        isUploading: isUploadingAvatar,
                        errorMessage: avatarUploadError,
                        selection: $selectedAvatarItem,
                        accessibilityLabel: "Upload profile photo",
                        recommendedHint: nil,
                        maximumRecommendedBytes: maximumRecommendedProfileAssetBytes,
                        oversizedWarningText: "This image is over 500 KB. Re-upload it with Halo so we can resize and compress it properly.",
                        emptyStateText: "No profile photo uploaded. Your theme color or gradient will be shown instead.",
                        usesCircularPreview: true,
                        removeAccessibilityLabel: "Remove profile photo",
                        onRemove: { removeImage(.avatar) }
                    )
                }
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Profile")

            editorCard {
                VStack(alignment: .leading, spacing: 16) {
                    labeledField("Display Name", systemImage: "person") {
                        TextField("Display Name", text: $fields.displayName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }

                    labeledField("Handle", systemImage: "at") {
                        TextField("Handle", text: $fields.handle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    labeledField("Bio", systemImage: "text.alignleft", topAligned: true) {
                        TextField("Tell people about yourself", text: $fields.about, axis: .vertical)
                            .lineLimit(4...8)
                            .textInputAutocapitalization(.sentences)
                    }
                }
            }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Links & Payments",
                subtitle: "These appear underneath your bio when present."
            )

            editorCard {
                VStack(alignment: .leading, spacing: 16) {
                    labeledField("Website", systemImage: "globe") {
                        TextField("Website", text: $fields.website)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                    }

                    labeledField("Payment Address", systemImage: "bolt.fill") {
                        TextField("", text: $fields.lightningAddress)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorsSection: some View {
        if let avatarUploadError, !avatarUploadError.isEmpty {
            errorCard(message: avatarUploadError)
        }

        if let bannerUploadError, !bannerUploadError.isEmpty {
            errorCard(message: bannerUploadError)
        }

        if let errorMessage, !errorMessage.isEmpty {
            errorCard(message: errorMessage)
        }
    }

    private var saveBar: some View {
        VStack(spacing: 10) {
            Button {
                save()
            } label: {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(saveButtonForeground)
                    }

                    Text("Save Changes")
                        .font(.headline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(saveButtonForeground)
                .background(saveButtonBackground, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(saveButtonBorder, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(appSettings.themePalette.sheetBackground)
    }

    private var saveButtonBackground: AnyShapeStyle {
        isBusy
            ? AnyShapeStyle(appSettings.themePalette.tertiaryFill)
            : AnyShapeStyle(appSettings.primaryGradient)
    }

    private var saveButtonForeground: Color {
        if isBusy {
            return appSettings.themePalette.secondaryForeground
        }
        return appSettings.buttonTextColor
    }

    private var saveButtonBorder: Color {
        appSettings.themePalette.separator
    }

    private func sectionHeader(title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(appSettings.appFont(.headline, weight: .bold))
                .foregroundStyle(appSettings.themePalette.foreground)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(appSettings.appFont(.footnote))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func editorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(appSettings.themePalette.sheetCardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(appSettings.themePalette.separator.opacity(0.18), lineWidth: 0.8)
            }
    }

    private func labeledField<Content: View>(
        _ title: String,
        systemImage: String,
        topAligned: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: topAligned ? .top : .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                .frame(width: 18)
                .padding(.top, topAligned ? 4 : 0)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(appSettings.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)

                content()
                    .font(appSettings.appFont(.body))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func imageUploadRow(
        title: String,
        systemImage: String,
        previewImage: UIImage?,
        remoteURLString: String,
        byteCount: Int?,
        isLoadingRemoteSize: Bool,
        isUploading: Bool,
        errorMessage: String?,
        selection: Binding<PhotosPickerItem?>,
        accessibilityLabel: String,
        recommendedHint: String?,
        maximumRecommendedBytes: Int,
        oversizedWarningText: String,
        emptyStateText: String,
        usesCircularPreview: Bool,
        removeAccessibilityLabel: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        let uploadButtonFont = appSettings.appFont(.footnote, weight: .semibold)
        let uploadButtonBackground = appSettings.themePalette.tertiaryFill
        let hasExistingImage = hasImage(
            previewImage: previewImage,
            remoteURLString: remoteURLString
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                imageUploadThumbnail(
                    previewImage: previewImage,
                    remoteURLString: remoteURLString,
                    title: title,
                    systemImage: systemImage,
                    usesCircularPreview: usesCircularPreview
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(appSettings.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)

                    Text(imageStatusText(
                        byteCount: byteCount,
                        isLoadingRemoteSize: isLoadingRemoteSize,
                        hasImage: hasExistingImage
                    ))
                    .font(appSettings.appFont(.body))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                    if let recommendedHint, !recommendedHint.isEmpty {
                        Text(recommendedHint)
                            .font(appSettings.appFont(.caption1))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let byteCount, byteCount > maximumRecommendedBytes {
                        Text(oversizedWarningText)
                            .font(appSettings.appFont(.caption1, weight: .semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !hasExistingImage {
                        Text(emptyStateText)
                            .font(appSettings.appFont(.caption1))
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 8) {
                    PhotosPicker(selection: selection, matching: .images) {
                        HStack(spacing: 6) {
                            if isUploading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                            }

                            Text(isUploading ? "Uploading" : "Upload")
                        }
                        .font(uploadButtonFont)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(uploadButtonBackground)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel(accessibilityLabel)

                    if hasExistingImage {
                        Button(role: .destructive, action: onRemove) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text("Remove")
                            }
                            .font(uploadButtonFont)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .foregroundStyle(.red)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(appSettings.themePalette.secondaryBackground)
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(appSettings.themePalette.separator.opacity(0.22), lineWidth: 0.8)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityLabel(removeAccessibilityLabel)
                    }
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(appSettings.appFont(.footnote))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorCard(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(appSettings.appFont(.footnote))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 0.9)
        }
    }

    private func save() {
        Task {
            let didSave = await onSave(fields)
            if didSave {
                dismiss()
            }
        }
    }

    @MainActor
    private func uploadImage(from item: PhotosPickerItem, target: UploadTarget) async {
        switch target {
        case .avatar:
            guard !isUploadingAvatar else { return }
            isUploadingAvatar = true
            avatarUploadError = nil
        case .banner:
            guard !isUploadingBanner else { return }
            isUploadingBanner = true
            bannerUploadError = nil
        }

        defer {
            switch target {
            case .avatar:
                isUploadingAvatar = false
                selectedAvatarItem = nil
            case .banner:
                isUploadingBanner = false
                selectedBannerItem = nil
            }
        }

        do {
            let preparedMedia: PreparedUploadMedia
            switch target {
            case .avatar:
                preparedMedia = try await MediaUploadPreparation.prepareProfileImageUpload(from: item)
            case .banner:
                preparedMedia = try await MediaUploadPreparation.prepareProfileBannerUpload(from: item)
            }
            let timestamp = Int(Date().timeIntervalSince1970)
            let filenamePrefix = target == .avatar ? "profile" : "profile-banner"
            let filename = "\(filenamePrefix)-\(timestamp).\(preparedMedia.fileExtension)"

            if let previewImage = preparedMedia.previewImage ?? UIImage(data: preparedMedia.data) {
                switch target {
                case .avatar:
                    avatarPreviewImage = previewImage
                case .banner:
                    bannerPreviewImage = previewImage
                }
            }

            let uploadedURL: String
            switch target {
            case .avatar:
                avatarPreparedByteCount = preparedMedia.data.count
                avatarRemoteByteCount = nil
                uploadedURL = try await onUploadAvatar(
                    preparedMedia.data,
                    preparedMedia.mimeType,
                    filename
                )
                fields.avatarURLString = uploadedURL
                avatarUploadError = nil
            case .banner:
                bannerPreparedByteCount = preparedMedia.data.count
                bannerRemoteByteCount = nil
                uploadedURL = try await onUploadBanner(
                    preparedMedia.data,
                    preparedMedia.mimeType,
                    filename
                )
                fields.bannerURLString = uploadedURL
                bannerUploadError = nil
            }
        } catch {
            let resolvedError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            switch target {
            case .avatar:
                avatarUploadError = resolvedError
            case .banner:
                bannerUploadError = resolvedError
            }
        }
    }

    private let maximumRecommendedProfileAssetBytes = 500 * 1_024
    private let maximumRecommendedProfileBannerAssetBytes = 2_500 * 1_024

    private var avatarByteCount: Int? {
        avatarPreparedByteCount ?? avatarRemoteByteCount
    }

    private var bannerByteCount: Int? {
        bannerPreparedByteCount ?? bannerRemoteByteCount
    }

    private var avatarRemoteAssetLookupID: String {
        fields.avatarURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bannerRemoteAssetLookupID: String {
        fields.bannerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func refreshRemoteAssetSize(for target: UploadTarget) async {
        let urlString: String
        let previewImage: UIImage?

        switch target {
        case .avatar:
            urlString = fields.avatarURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            previewImage = avatarPreviewImage
            if previewImage != nil, avatarPreparedByteCount != nil {
                avatarRemoteByteCount = nil
                isLoadingAvatarRemoteSize = false
                return
            }
        case .banner:
            urlString = fields.bannerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            previewImage = bannerPreviewImage
            if previewImage != nil, bannerPreparedByteCount != nil {
                bannerRemoteByteCount = nil
                isLoadingBannerRemoteSize = false
                return
            }
        }

        guard let url = URL(string: urlString), !urlString.isEmpty else {
            switch target {
            case .avatar:
                avatarRemoteByteCount = nil
                isLoadingAvatarRemoteSize = false
            case .banner:
                bannerRemoteByteCount = nil
                isLoadingBannerRemoteSize = false
            }
            return
        }

        switch target {
        case .avatar:
            isLoadingAvatarRemoteSize = true
        case .banner:
            isLoadingBannerRemoteSize = true
        }

        let byteCount = await remoteFileSize(for: url)
        guard !Task.isCancelled else { return }

        switch target {
        case .avatar:
            guard fields.avatarURLString.trimmingCharacters(in: .whitespacesAndNewlines) == urlString else { return }
            avatarRemoteByteCount = byteCount
            isLoadingAvatarRemoteSize = false
        case .banner:
            guard fields.bannerURLString.trimmingCharacters(in: .whitespacesAndNewlines) == urlString else { return }
            bannerRemoteByteCount = byteCount
            isLoadingBannerRemoteSize = false
        }
    }

    private func remoteFileSize(for url: URL) async -> Int? {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 12

        if let byteCount = await expectedRemoteContentLength(for: headRequest) {
            return byteCount
        }

        var rangeRequest = URLRequest(url: url)
        rangeRequest.httpMethod = "GET"
        rangeRequest.timeoutInterval = 12
        rangeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        return await expectedRemoteContentLength(for: rangeRequest)
    }

    private func expectedRemoteContentLength(for request: URLRequest) async -> Int? {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
               let totalBytes = contentRange.split(separator: "/").last,
               let parsed = Int(totalBytes) {
                return parsed
            }

            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let parsed = Int(contentLength) {
                return parsed
            }

            let expected = response.expectedContentLength
            return expected > 0 ? Int(expected) : nil
        } catch {
            return nil
        }
    }

    private func removeImage(_ target: UploadTarget) {
        switch target {
        case .avatar:
            selectedAvatarItem = nil
            avatarPreviewImage = nil
            avatarPreparedByteCount = nil
            avatarRemoteByteCount = nil
            avatarUploadError = nil
            isLoadingAvatarRemoteSize = false
            fields.avatarURLString = ""
        case .banner:
            selectedBannerItem = nil
            bannerPreviewImage = nil
            bannerPreparedByteCount = nil
            bannerRemoteByteCount = nil
            bannerUploadError = nil
            isLoadingBannerRemoteSize = false
            fields.bannerURLString = ""
        }
    }

    private func imageStatusText(
        byteCount: Int?,
        isLoadingRemoteSize: Bool,
        hasImage: Bool
    ) -> String {
        if let byteCount {
            let sizeDescription = ByteCountFormatter.string(
                fromByteCount: Int64(byteCount),
                countStyle: .file
            )
            return byteCount > maximumRecommendedProfileAssetBytes
                ? "Current file: \(sizeDescription)"
                : "Current file: \(sizeDescription)"
        }

        if isLoadingRemoteSize {
            return "Checking current size..."
        }

        return hasImage ? "Current image found" : "Upload an image"
    }

    private func hasImage(previewImage: UIImage?, remoteURLString: String) -> Bool {
        if previewImage != nil {
            return true
        }

        return !remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func imageUploadThumbnail(
        previewImage: UIImage?,
        remoteURLString: String,
        title: String,
        systemImage: String,
        usesCircularPreview: Bool
    ) -> some View {
        let thumbnailWidth: CGFloat = usesCircularPreview ? 56 : 96
        let thumbnailHeight: CGFloat = usesCircularPreview ? 56 : 56
        let shape = RoundedRectangle(cornerRadius: usesCircularPreview ? thumbnailWidth / 2 : 14, style: .continuous)

        Group {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL = URL(string: remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
                      !remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CachedAsyncImage(
                    url: remoteURL,
                    kind: usesCircularPreview ? .avatar : .profileBanner
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        imageUploadThumbnailFallback(title: title, systemImage: systemImage)
                    }
                }
            } else {
                imageUploadThumbnailFallback(title: title, systemImage: systemImage)
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .background(appSettings.themePalette.secondaryBackground, in: shape)
        .clipShape(shape)
        .overlay {
            shape.stroke(appSettings.themePalette.separator.opacity(0.22), lineWidth: 0.8)
        }
    }

    private func imageUploadThumbnailFallback(title: String, systemImage: String) -> some View {
        ZStack {
            appSettings.themePalette.tertiaryFill

            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appSettings.themePalette.iconMutedForeground)

                Text(String(title.prefix(1)).uppercased())
                    .font(appSettings.appFont(.caption1, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
    }
}

private struct ProfileEditorPreviewCard: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Environment(\.colorScheme) private var colorScheme

    let fields: EditableProfileFields
    let previewHandle: String
    let followingCount: Int
    let avatarPreviewImage: UIImage?
    let bannerPreviewImage: UIImage?

    private static let bannerHeight: CGFloat = 178
    private static let avatarSize: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewBanner

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 16) {
                    previewAvatar

                    Spacer(minLength: 0)

                    previewActionCapsules
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(resolvedDisplayName)
                        .font(appSettings.appFont(size: 28, weight: .heavy))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(resolvedHandle)
                        .font(appSettings.appFont(.subheadline))
                        .foregroundStyle(appSettings.themePalette.mutedForeground)

                    HStack(spacing: 4) {
                        Text("\(max(followingCount, 0)) following")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(appSettings.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
                }

                if !fields.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ProfileAboutTextView(
                        text: fields.about.trimmingCharacters(in: .whitespacesAndNewlines),
                        onProfileTap: { _ in },
                        onHashtagTap: { _ in }
                    )
                } else {
                    Text("Your bio preview will appear here.")
                        .font(appSettings.appFont(.body))
                        .foregroundStyle(appSettings.themePalette.mutedForeground)
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let website = normalizedWebsiteDisplayText {
                        previewInfoRow(text: website, systemImage: "link")
                    }

                    if let lightning = normalizedValue(fields.lightningAddress) {
                        previewInfoRow(text: lightning, systemImage: "bolt.fill")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, -(Self.avatarSize / 2))
            .padding(.bottom, 18)
        }
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(appSettings.themePalette.separator.opacity(0.18), lineWidth: 0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var resolvedDisplayName: String {
        normalizedValue(fields.displayName) ?? "Your Name"
    }

    private var resolvedHandle: String {
        let editedHandle = ProfileMetadataEditing.normalizeHandle(fields.handle)
        if !editedHandle.isEmpty {
            return "@\(editedHandle.replacingOccurrences(of: " ", with: "").lowercased())"
        }

        let trimmedHandle = previewHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHandle.isEmpty {
            return trimmedHandle
        }

        if let displayName = normalizedValue(fields.displayName) {
            return "@\(displayName.replacingOccurrences(of: " ", with: "").lowercased())"
        }

        return "@flow"
    }

    private var normalizedWebsiteDisplayText: String? {
        guard let url = ProfileMetadataEditing.normalizedWebsiteURL(from: fields.website) else { return nil }
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return host
        }
        return "\(host)/\(path)"
    }

    @ViewBuilder
    private var previewBanner: some View {
        ZStack {
            previewBannerContent

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    .clear,
                    appSettings.themePalette.groupedBackground.opacity(0.24)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.bannerHeight)
        .background(appSettings.themePalette.secondaryBackground)
        .clipped()
    }

    @ViewBuilder
    private var previewBannerContent: some View {
        let bannerString = fields.bannerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bannerPreviewImage {
            Image(uiImage: bannerPreviewImage)
                .resizable()
                .scaledToFill()
        } else if let bannerURL = URL(string: bannerString), !bannerString.isEmpty {
            CachedAsyncImage(url: bannerURL, kind: .profileBanner) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    previewBannerFallback
                }
            }
        } else {
            previewBannerFallback
        }
    }

    private var previewBannerFallback: some View {
        ZStack {
            Rectangle()
                .fill(appSettings.primaryGradient)
                .opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.92 : 0.34)
                .background(appSettings.themePalette.secondaryBackground)

            Circle()
                .fill(Color.white.opacity(appSettings.usesPrimaryGradientForProminentButtons ? 0.36 : 0.40))
                .frame(width: 148, height: 148)
                .blur(radius: 18)
                .offset(x: 122, y: -46)

            Circle()
                .fill(appSettings.primaryColor.opacity(0.18))
                .frame(width: 190, height: 190)
                .blur(radius: 28)
                .offset(x: -128, y: 54)
        }
    }

    private var previewAvatar: some View {
        let avatarString = fields.avatarURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        return Group {
            if let avatarPreviewImage {
                Image(uiImage: avatarPreviewImage)
                    .resizable()
                    .scaledToFill()
            } else if let avatarURL = URL(string: avatarString), !avatarString.isEmpty {
                CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        previewAvatarFallback
                    }
                }
            } else {
                previewAvatarFallback
            }
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .background(Circle().fill(appSettings.themePalette.background))
        .clipShape(Circle())
        .overlay {
            Circle().stroke(appSettings.themePalette.background, lineWidth: 4)
        }
        .overlay {
            Circle().stroke(appSettings.themePalette.separator.opacity(0.22), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)
    }

    private var previewAvatarFallback: some View {
        ZStack {
            Circle()
                .fill(appSettings.primaryGradient)

            Text(String(resolvedDisplayName.prefix(1)).uppercased())
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(appSettings.buttonTextColor)
        }
    }

    private var previewActionCapsules: some View {
        HStack(spacing: 10) {
            previewActionCapsule(systemImage: "qrcode")
            previewActionCapsule(systemImage: "ellipsis")
            previewPrimaryActionCapsule(text: "Follow")
        }
    }

    private func previewActionCapsule(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(appSettings.themePalette.foreground)
            .frame(width: 42, height: 40)
            .background(
                Capsule(style: .continuous)
                    .fill(appSettings.themePalette.tertiaryFill)
            )
    }

    private func previewPrimaryActionCapsule(text: String) -> some View {
        Text(text)
            .font(appSettings.appFont(.subheadline, weight: .semibold))
            .foregroundStyle(appSettings.buttonTextColor)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(
                Capsule(style: .continuous)
                    .fill(appSettings.primaryGradient)
            )
    }

    private func previewInfoRow(text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.mutedForeground)
                .frame(width: 16)

            Text(text)
                .font(appSettings.appFont(.footnote))
                .foregroundStyle(appSettings.themePalette.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func normalizedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
