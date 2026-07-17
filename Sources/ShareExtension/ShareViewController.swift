import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private enum ShareExtensionError: LocalizedError {
        case noSupportedMedia
        case failedToLoadMedia

        var errorDescription: String? {
            switch self {
            case .noSupportedMedia:
                return "Halo can only accept photos and videos here."
            case .failedToLoadMedia:
                return "Couldn't prepare the selected media."
            }
        }
    }

    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var hasStartedProcessing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewHierarchy()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !hasStartedProcessing else { return }
        hasStartedProcessing = true

        Task {
            await processSharedItems()
        }
    }

    @MainActor
    private func processSharedItems() async {
        let providers = supportedItemProviders()
        guard !providers.isEmpty else {
            showFailure(message: ShareExtensionError.noSupportedMedia.localizedDescription)
            return
        }

        detailLabel.text = providers.count == 1
            ? "Adding your attachment to a new note..."
            : "Adding \(providers.count) attachments to a new note..."

        var pendingItems: [SharedComposePendingItem] = []
        var temporaryURLs: [URL] = []

        defer {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            for provider in providers {
                let loadedItem = try await loadPendingItem(from: provider)
                if let fileURL = loadedItem.fileURL {
                    temporaryURLs.append(fileURL)
                }
                pendingItems.append(loadedItem)
            }

            guard !pendingItems.isEmpty else {
                throw ShareExtensionError.noSupportedMedia
            }

            _ = try await Task.detached(priority: .userInitiated) {
                try FlowSharedComposeDraftStore.savePendingDraft(items: pendingItems)
            }.value
            showSavedForHalo(attachmentCount: pendingItems.count)
        } catch {
            showFailure(
                message: (error as? LocalizedError)?.errorDescription
                    ?? ShareExtensionError.failedToLoadMedia.localizedDescription
            )
        }
    }

    private func configureViewHierarchy() {
        view.backgroundColor = .systemBackground

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Add to Halo"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.text = "Preparing your media..."
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        detailLabel.lineBreakMode = .byWordWrapping

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.configuration = .filled()
        actionButton.configuration?.cornerStyle = .capsule
        actionButton.configuration?.baseBackgroundColor = .label
        actionButton.configuration?.baseForegroundColor = .systemBackground
        actionButton.setTitle("Done", for: .normal)
        actionButton.addTarget(self, action: #selector(handleActionButtonTap), for: .touchUpInside)
        actionButton.isHidden = true

        let stackView = UIStackView(arrangedSubviews: [
            activityIndicator,
            titleLabel,
            detailLabel,
            actionButton
        ])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 14

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])
    }

    private func showFailure(message: String) {
        activityIndicator.stopAnimating()
        titleLabel.text = "Couldn't Share"
        detailLabel.text = message
        actionButton.setTitle("Close", for: .normal)
        actionButton.isHidden = false
    }

    private func showSavedForHalo(attachmentCount: Int) {
        activityIndicator.stopAnimating()
        titleLabel.text = "Ready in Halo"
        detailLabel.text = attachmentCount == 1
            ? "Your attachment is saved. Tap Done, then open Halo and the new post will appear automatically."
            : "Your \(attachmentCount) attachments are saved. Tap Done, then open Halo and the new post will appear automatically."
        actionButton.setTitle("Done", for: .normal)
        actionButton.isHidden = false
    }

    @objc
    private func handleActionButtonTap() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func supportedItemProviders() -> [NSItemProvider] {
        let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        return extensionItems
            .flatMap { $0.attachments ?? [] }
            .filter { preferredSupportedType(for: $0) != nil }
    }

    private func loadPendingItem(from provider: NSItemProvider) async throws -> SharedComposePendingItem {
        guard let contentType = preferredSupportedType(for: provider) else {
            throw ShareExtensionError.noSupportedMedia
        }

        let suggestedFilename = preferredFilename(
            suggestedName: provider.suggestedName,
            contentType: contentType
        )

        if let temporaryCopyURL = try? await loadTemporaryCopy(
            from: provider,
            contentType: contentType,
            suggestedFilename: suggestedFilename
        ) {
            let fileExtension = preferredFileExtension(
                contentType: contentType,
                suggestedFilename: suggestedFilename,
                fileURL: temporaryCopyURL
            )
            let mimeType = preferredMimeType(
                contentType: contentType,
                fileExtension: fileExtension
            )

            return SharedComposePendingItem(
                fileURL: temporaryCopyURL,
                mimeType: mimeType,
                fileExtension: fileExtension,
                originalFilename: suggestedFilename
            )
        }

        let data = try await loadDataRepresentation(
            from: provider,
            contentType: contentType
        )
        let fileExtension = preferredFileExtension(
            contentType: contentType,
            suggestedFilename: suggestedFilename,
            fileURL: nil
        )
        let mimeType = preferredMimeType(
            contentType: contentType,
            fileExtension: fileExtension
        )

        return SharedComposePendingItem(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension,
            originalFilename: suggestedFilename
        )
    }

    private func preferredSupportedType(for provider: NSItemProvider) -> UTType? {
        let registeredTypes = provider.registeredTypeIdentifiers.compactMap(UTType.init)

        if let movieType = registeredTypes.first(where: { $0.conforms(to: .movie) }) {
            return movieType
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return .movie
        }

        if let imageType = registeredTypes.first(where: { $0.conforms(to: .image) }) {
            return imageType
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return .image
        }

        return nil
    }

    private func loadTemporaryCopy(
        from provider: NSItemProvider,
        contentType: UTType,
        suggestedFilename: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: contentType.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url else {
                    continuation.resume(throwing: ShareExtensionError.failedToLoadMedia)
                    return
                }

                let fileExtension = self.preferredFileExtension(
                    contentType: contentType,
                    suggestedFilename: suggestedFilename,
                    fileURL: url
                )
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fileExtension)

                do {
                    if FileManager.default.fileExists(atPath: temporaryURL.path) {
                        try FileManager.default.removeItem(at: temporaryURL)
                    }
                    try FileManager.default.copyItem(at: url, to: temporaryURL)
                    continuation.resume(returning: temporaryURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadDataRepresentation(
        from provider: NSItemProvider,
        contentType: UTType
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: ShareExtensionError.failedToLoadMedia)
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    private func preferredFilename(suggestedName: String?, contentType: UTType) -> String {
        let trimmedSuggestedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedSuggestedName.isEmpty {
            return trimmedSuggestedName
        }

        let fallbackExtension = contentType.preferredFilenameExtension
            ?? (contentType.conforms(to: .movie) ? "mov" : "jpg")
        return "shared-\(UUID().uuidString.lowercased()).\(fallbackExtension)"
    }

    private func preferredFileExtension(
        contentType: UTType,
        suggestedFilename: String,
        fileURL: URL?
    ) -> String {
        let suggestedExtension = URL(fileURLWithPath: suggestedFilename)
            .pathExtension
            .lowercased()
        if !suggestedExtension.isEmpty {
            return suggestedExtension
        }

        if let fileURL {
            let pathExtension = fileURL.pathExtension.lowercased()
            if !pathExtension.isEmpty {
                return pathExtension
            }
        }

        if let preferredExtension = contentType.preferredFilenameExtension,
           !preferredExtension.isEmpty {
            return preferredExtension.lowercased()
        }

        return contentType.conforms(to: .movie) ? "mov" : "jpg"
    }

    private func preferredMimeType(contentType: UTType, fileExtension: String) -> String {
        if let mimeType = contentType.preferredMIMEType {
            return mimeType
        }

        if let inferredMimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType {
            return inferredMimeType
        }

        return contentType.conforms(to: .movie) ? "video/quicktime" : "image/jpeg"
    }
}
