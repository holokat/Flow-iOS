import AVFoundation
import AVKit
import ImageIO
import NostrSDK
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposeMentionQuery: Equatable {
    let range: NSRange
    let query: String
}

struct ComposeSelectedMention: Identifiable, Equatable, Hashable, Codable, Sendable {
    let pubkey: String
    let handle: String
    let range: NSRange

    private enum CodingKeys: String, CodingKey {
        case pubkey
        case handle
        case rangeLocation
        case rangeLength
    }

    var id: String {
        "\(pubkey)|\(range.location)|\(range.length)|\(handle)"
    }

    var replacementText: String {
        "@\(handle)"
    }

    init(
        pubkey: String,
        handle: String,
        range: NSRange
    ) {
        self.pubkey = pubkey
        self.handle = handle
        self.range = range
    }

    func shifted(by delta: Int) -> ComposeSelectedMention {
        ComposeSelectedMention(
            pubkey: pubkey,
            handle: handle,
            range: NSRange(
                location: max(0, range.location + delta),
                length: range.length
            )
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pubkey = try container.decode(String.self, forKey: .pubkey)
        handle = try container.decode(String.self, forKey: .handle)
        let rangeLocation = try container.decode(Int.self, forKey: .rangeLocation)
        let rangeLength = try container.decode(Int.self, forKey: .rangeLength)
        range = NSRange(location: rangeLocation, length: rangeLength)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pubkey, forKey: .pubkey)
        try container.encode(handle, forKey: .handle)
        try container.encode(range.location, forKey: .rangeLocation)
        try container.encode(range.length, forKey: .rangeLength)
    }
}

struct ComposeMentionSuggestion: Identifiable, Equatable {
    let pubkey: String
    let displayName: String
    let handle: String
    let secondaryText: String
    let avatarURL: URL?

    var id: String { pubkey }

    var replacementText: String {
        "@\(handle)"
    }

    init?(result: ProfileSearchResult) {
        let normalizedPubkey = Self.normalizedPubkey(result.pubkey)
        guard !normalizedPubkey.isEmpty else { return nil }
        guard let handle = Self.handle(from: result.profile, pubkey: normalizedPubkey) else { return nil }

        self.pubkey = normalizedPubkey
        displayName = Self.displayName(from: result.profile, pubkey: normalizedPubkey)
        self.handle = handle
        secondaryText = "@\(handle)"
        avatarURL = Self.avatarURL(from: result.profile)
    }

    private static func displayName(from profile: NostrProfile?, pubkey: String) -> String {
        if let displayName = normalizedText(profile?.displayName) {
            return displayName
        }
        if let name = normalizedText(profile?.name) {
            return name
        }
        return shortNostrIdentifier(pubkey)
    }

    private static func avatarURL(from profile: NostrProfile?) -> URL? {
        profile?.resolvedAvatarURL
    }

    private static func handle(from profile: NostrProfile?, pubkey: String) -> String? {
        if let handle = normalizedHandle(profile?.name) {
            return handle
        }
        if let handle = normalizedHandle(profile?.displayName) {
            return handle
        }
        let fallback = String(pubkey.prefix(12)).lowercased()
        return fallback.isEmpty ? nil : fallback
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedHandle(_ value: String?) -> String? {
        let trimmed = normalizedText(value)?
            .replacingOccurrences(of: "@", with: "")
            .lowercased() ?? ""
        guard !trimmed.isEmpty else { return nil }

        let filtered = trimmed.unicodeScalars.filter { scalar in
            allowedHandleCharacters.contains(scalar)
        }
        let normalized = String(String.UnicodeScalarView(filtered))
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedPubkey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ComposeMentionInsertionResult: Equatable {
    let text: String
    let mentions: [ComposeSelectedMention]
    let selectedRange: NSRange
}

struct ComposePreparedMentions: Equatable {
    let content: String
    let additionalTags: [[String]]
}

enum ComposeMentionSupport {
    static func activeQuery(
        in text: String,
        selection: NSRange,
        confirmedMentions: [ComposeSelectedMention]
    ) -> ComposeMentionQuery? {
        guard selection.length == 0 else { return nil }

        let nsText = text as NSString
        let caretLocation = min(max(selection.location, 0), nsText.length)
        guard !confirmedMentions.contains(where: { mention in
            caretLocation > mention.range.location &&
            caretLocation <= mention.range.location + mention.range.length
        }) else {
            return nil
        }

        var cursor = caretLocation
        while cursor > 0 {
            let previousRange = NSRange(location: cursor - 1, length: 1)
            let previousCharacter = nsText.substring(with: previousRange)

            if confirmedMentions.contains(where: { mention in
                cursor - 1 >= mention.range.location &&
                cursor - 1 < mention.range.location + mention.range.length
            }) {
                return nil
            }

            if previousCharacter == "@" {
                if cursor - 1 > 0 {
                    let leadingCharacter = nsText.substring(with: NSRange(location: cursor - 2, length: 1))
                    if isMentionStartContinuationText(leadingCharacter) {
                        cursor -= 1
                        continue
                    }
                }

                let queryRange = NSRange(location: cursor - 1, length: caretLocation - (cursor - 1))
                let token = nsText.substring(with: queryRange)
                let query = normalizedSearchQuery(String(token.dropFirst()))
                guard isReasonableSearchQuery(query) else {
                    return nil
                }
                return ComposeMentionQuery(range: queryRange, query: query)
            }

            guard isAllowedSearchQueryText(previousCharacter) else { return nil }
            cursor -= 1
        }

        return nil
    }

    static func updatedMentions(
        _ mentions: [ComposeSelectedMention],
        forEditIn range: NSRange,
        replacementText: String
    ) -> [ComposeSelectedMention] {
        let replacementLength = (replacementText as NSString).length
        let delta = replacementLength - range.length

        return mentions.compactMap { mention in
            if NSIntersectionRange(mention.range, range).length > 0 {
                return nil
            }

            if range.location < mention.range.location {
                return mention.shifted(by: delta)
            }

            return mention
        }
    }

    static func insertSuggestion(
        _ suggestion: ComposeMentionSuggestion,
        into text: String,
        replacing query: ComposeMentionQuery,
        existingMentions: [ComposeSelectedMention]
    ) -> ComposeMentionInsertionResult {
        let replacementText = suggestion.replacementText
        let insertedText = replacementText + " "
        let updatedText = (text as NSString).replacingCharacters(in: query.range, with: insertedText)
        var updatedMentions = updatedMentions(
            existingMentions,
            forEditIn: query.range,
            replacementText: insertedText
        )

        updatedMentions.append(
            ComposeSelectedMention(
                pubkey: suggestion.pubkey,
                handle: suggestion.handle,
                range: NSRange(
                    location: query.range.location,
                    length: (replacementText as NSString).length
                )
            )
        )
        updatedMentions.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.pubkey < rhs.pubkey
            }
            return lhs.range.location < rhs.range.location
        }

        return ComposeMentionInsertionResult(
            text: updatedText,
            mentions: updatedMentions,
            selectedRange: NSRange(
                location: query.range.location + (insertedText as NSString).length,
                length: 0
            )
        )
    }

    static func preparedMentions(
        from text: String,
        selectedMentions: [ComposeSelectedMention]
    ) -> ComposePreparedMentions {
        guard !selectedMentions.isEmpty else {
            return ComposePreparedMentions(content: text, additionalTags: [])
        }

        let mutableContent = NSMutableString(string: text)
        var seenPubkeys = Set<String>()
        var additionalTags: [[String]] = []

        for mention in selectedMentions.sorted(by: { lhs, rhs in
            lhs.range.location > rhs.range.location
        }) {
            let normalizedPubkey = mention.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedPubkey.isEmpty else { continue }
            guard let npub = PublicKey(hex: normalizedPubkey)?.npub else { continue }
            guard mention.range.location >= 0,
                  mention.range.location + mention.range.length <= mutableContent.length else {
                continue
            }

            mutableContent.replaceCharacters(in: mention.range, with: "nostr:\(npub)")

            if seenPubkeys.insert(normalizedPubkey).inserted {
                additionalTags.append(["p", normalizedPubkey])
            }
        }

        return ComposePreparedMentions(
            content: mutableContent as String,
            additionalTags: additionalTags
        )
    }

    private static func isAllowedSearchQueryText(_ value: String) -> Bool {
        guard value.unicodeScalars.count == 1,
              let scalar = value.unicodeScalars.first else {
            return false
        }
        guard !CharacterSet.newlines.contains(scalar) else { return false }
        return !mentionSearchTerminatorCharacters.contains(scalar)
    }

    private static func isMentionStartContinuationText(_ value: String) -> Bool {
        guard value.unicodeScalars.count == 1,
              let scalar = value.unicodeScalars.first else {
            return false
        }
        return mentionStartContinuationCharacters.contains(scalar)
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        return trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
    }

    private static func isReasonableSearchQuery(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 48 else { return false }
        return value.split(whereSeparator: { $0.isWhitespace }).count <= 3
    }
}

private let allowedHandleCharacters = CharacterSet.alphanumerics.union(
    CharacterSet(charactersIn: "._-")
)
private let mentionStartContinuationCharacters = CharacterSet.alphanumerics.union(
    CharacterSet(charactersIn: "._-")
)
private let mentionSearchTerminatorCharacters = CharacterSet(charactersIn: ",;:!?()[]{}<>/\\|`~\"")

enum ComposeNoteTextLimit {
    static let maxCharacterCount = 240

    static func limited(_ text: String, limit: Int = maxCharacterCount) -> String {
        guard limit >= 0, text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    static func allowedReplacement(
        in currentText: String,
        range: NSRange,
        replacementText: String,
        limit: Int = maxCharacterCount
    ) -> String {
        guard limit >= 0,
              let stringRange = Range(range, in: currentText) else {
            return ""
        }

        var textAfterRemovingSelection = currentText
        textAfterRemovingSelection.removeSubrange(stringRange)
        let availableCharacterCount = max(0, limit - textAfterRemovingSelection.count)
        guard replacementText.count > availableCharacterCount else {
            return replacementText
        }

        return String(replacementText.prefix(availableCharacterCount))
    }
}

enum ComposePreparedPublication: Sendable {
    case note(PreparedNotePublication)
    case poll(PreparedNotePublication)
    case reply(PreparedThreadReplyPublication)

    var item: FeedItem {
        switch self {
        case .note(let prepared), .poll(let prepared):
            return prepared.item
        case .reply(let prepared):
            return prepared.item
        }
    }

    var isPoll: Bool {
        if case .poll = self {
            return true
        }
        return false
    }

    var isReply: Bool {
        if case .reply = self {
            return true
        }
        return false
    }
}

@MainActor
final class ComposeNoteViewModel: ObservableObject {
    @Published var text: String = "" {
        didSet {
            let limitedText = ComposeNoteTextLimit.limited(text)
            if limitedText != text {
                text = limitedText
            }
        }
    }
    @Published private(set) var isPublishing = false
    @Published var feedbackMessage: String?
    @Published var feedbackIsError = false

    private let publishingService: ComposeNotePublishService
    private let replyPublishingService: ThreadReplyPublishService

    init(
        publishingService: ComposeNotePublishService = ComposeNotePublishService(),
        replyPublishingService: ThreadReplyPublishService = ThreadReplyPublishService()
    ) {
        self.publishingService = publishingService
        self.replyPublishingService = replyPublishingService
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var characterLimit: Int {
        ComposeNoteTextLimit.maxCharacterCount
    }

    var characterCount: Int {
        text.count
    }

    var remainingCharacterCount: Int {
        max(0, characterLimit - characterCount)
    }

    func publish(
        content: String? = nil,
        currentAccountPubkey: String?,
        currentNsec: String?,
        writeRelayURLs: [URL],
        additionalTags: [[String]] = [],
        pollDraft: ComposePollDraft? = nil,
        replyTargetEvent: NostrEvent? = nil
    ) async -> Bool {
        guard let prepared = await preparePublication(
            content: content,
            currentAccountPubkey: currentAccountPubkey,
            currentNsec: currentNsec,
            writeRelayURLs: writeRelayURLs,
            additionalTags: additionalTags,
            pollDraft: pollDraft,
            replyTargetEvent: replyTargetEvent
        ) else {
            return false
        }

        return await finishPublication(prepared)
    }

    func preparePublication(
        content: String? = nil,
        currentAccountPubkey: String?,
        currentNsec: String?,
        writeRelayURLs: [URL],
        additionalTags: [[String]] = [],
        pollDraft: ComposePollDraft? = nil,
        replyTargetEvent: NostrEvent? = nil
    ) async -> ComposePreparedPublication? {
        guard !isPublishing else { return nil }

        isPublishing = true
        feedbackMessage = nil
        feedbackIsError = false

        defer {
            isPublishing = false
        }

        let publishContent = content ?? text

        do {
            if let replyTargetEvent {
                let prepared = try await replyPublishingService.prepareReply(
                    content: publishContent,
                    replyingTo: replyTargetEvent,
                    currentAccountPubkey: currentAccountPubkey,
                    currentNsec: currentNsec,
                    writeRelayURLs: writeRelayURLs,
                    additionalTags: additionalTags
                )
                text = ""
                feedbackMessage = "Reply publishing."
                feedbackIsError = false
                return .reply(prepared)
            } else if let pollDraft {
                let prepared = try await publishingService.preparePoll(
                    content: publishContent,
                    poll: pollDraft,
                    currentNsec: currentNsec,
                    writeRelayURLs: writeRelayURLs,
                    additionalTags: additionalTags
                )

                text = ""
                feedbackMessage = "Poll publishing."
                feedbackIsError = false
                return .poll(prepared)
            } else {
                let prepared = try await publishingService.prepareNote(
                    content: publishContent,
                    currentNsec: currentNsec,
                    writeRelayURLs: writeRelayURLs,
                    additionalTags: additionalTags
                )

                text = ""
                feedbackMessage = "Publishing."
                feedbackIsError = false
                return .note(prepared)
            }
        } catch {
            feedbackMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feedbackIsError = true
            return nil
        }
    }

    func finishPublication(_ prepared: ComposePreparedPublication) async -> Bool {
        do {
            switch prepared {
            case .note(let prepared), .poll(let prepared):
                _ = try await publishingService.publishPrepared(prepared)
            case .reply(let prepared):
                _ = try await replyPublishingService.publishPrepared(prepared)
            }
            feedbackMessage = prepared.isReply ? "Reply posted." : prepared.isPoll ? "Poll posted." : "Posted."
            feedbackIsError = false
            return true
        } catch {
            feedbackMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feedbackIsError = true
            return false
        }
    }
}

struct ComposeMediaAttachment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let url: URL
    let imetaTag: [String]
    let mimeType: String
    let fileSizeBytes: Int?

    init(
        id: UUID = UUID(),
        url: URL,
        imetaTag: [String],
        mimeType: String,
        fileSizeBytes: Int?
    ) {
        self.id = id
        self.url = url
        self.imetaTag = imetaTag
        self.mimeType = mimeType
        self.fileSizeBytes = fileSizeBytes
    }

    var isImage: Bool {
        let normalized = mimeType.lowercased()
        if normalized.hasPrefix("image/") {
            return true
        }
        return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".bmp", ".svg"]
            .contains { url.path.lowercased().hasSuffix($0) }
    }

    var isVideo: Bool {
        let normalized = mimeType.lowercased()
        if normalized.hasPrefix("video/") {
            return true
        }
        return [".mp4", ".mov", ".m4v", ".webm", ".mkv"]
            .contains { url.path.lowercased().hasSuffix($0) }
    }

    var isAudio: Bool {
        let normalized = mimeType.lowercased()
        if normalized.hasPrefix("audio/") {
            return true
        }
        return [".mp3", ".m4a", ".aac", ".wav", ".ogg"]
            .contains { url.path.lowercased().hasSuffix($0) }
    }

    var isGIF: Bool {
        let normalized = mimeType.lowercased()
        if normalized.contains("gif") {
            return true
        }
        return url.pathExtension.lowercased() == "gif"
    }
}

struct CameraCapturePermissionSnapshot: Equatable {
    let cameraStatus: AVAuthorizationStatus
    let microphoneStatus: AVAuthorizationStatus

    static func current() -> CameraCapturePermissionSnapshot {
        CameraCapturePermissionSnapshot(
            cameraStatus: AVCaptureDevice.authorizationStatus(for: .video),
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    var cameraRequiresPrompt: Bool {
        cameraStatus == .notDetermined
    }

    var microphoneRequiresPrompt: Bool {
        microphoneStatus == .notDetermined
    }

    var isCameraBlocked: Bool {
        cameraStatus == .denied || cameraStatus == .restricted
    }

    var isMicrophoneBlocked: Bool {
        microphoneStatus == .denied || microphoneStatus == .restricted
    }
}

enum CapturedCameraMedia {
    case image(data: Data, mimeType: String, fileExtension: String)
    case video(fileURL: URL, mimeType: String, fileExtension: String)
}

enum SharedComposeImportError: LocalizedError {
    case missingFileURL
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .missingFileURL:
            return "Couldn't access the shared media."
        case .unreadableFile:
            return "Couldn't read the shared media."
        }
    }
}

struct ComposeMediaAttachmentController {
    private let mediaUploadService: MediaUploadService
    private let klipyGIFService: KlipyGIFService
    private let uuidProvider: () -> UUID

    init(
        mediaUploadService: MediaUploadService = .shared,
        klipyGIFService: KlipyGIFService = .shared,
        uuidProvider: @escaping () -> UUID = UUID.init
    ) {
        self.mediaUploadService = mediaUploadService
        self.klipyGIFService = klipyGIFService
        self.uuidProvider = uuidProvider
    }

    var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func currentCapturePermissions() -> CameraCapturePermissionSnapshot {
        CameraCapturePermissionSnapshot.current()
    }

    func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func uploadAttachment(
        from item: PhotosPickerItem,
        normalizedNsec: String
    ) async throws -> ComposeMediaAttachment {
        let preparedMedia = try await MediaUploadPreparation.prepareUploadMedia(from: item)
        return try await uploadPreparedMedia(preparedMedia, filenamePrefix: "note", normalizedNsec: normalizedNsec)
    }

    func uploadAttachment(
        from capturedMedia: CapturedCameraMedia,
        normalizedNsec: String
    ) async throws -> ComposeMediaAttachment {
        let preparedMedia: PreparedUploadMedia

        switch capturedMedia {
        case .image(let imageData, let capturedMimeType, let capturedFileExtension):
            preparedMedia = try MediaUploadPreparation.prepareUploadMedia(
                data: imageData,
                mimeType: capturedMimeType,
                fileExtension: capturedFileExtension
            )

        case .video(let fileURL, let capturedMimeType, let capturedFileExtension):
            preparedMedia = try await MediaUploadPreparation.prepareUploadMedia(
                fileURL: fileURL,
                mimeType: capturedMimeType,
                fileExtension: capturedFileExtension
            )
        }

        return try await uploadPreparedMedia(preparedMedia, filenamePrefix: "note", normalizedNsec: normalizedNsec)
    }

    func uploadAttachment(
        from selection: KlipyGIFAttachmentCandidate,
        normalizedNsec: String
    ) async throws -> ComposeMediaAttachment {
        let downloadedData = try await klipyGIFService.downloadGIFData(for: selection)
        let preparedMedia = try await MediaUploadPreparation.prepareGIFKeyboardUploadMedia(
            data: downloadedData,
            mimeType: selection.mimeType,
            fileExtension: selection.fileExtension
        )
        let attachment = try await uploadPreparedMedia(
            preparedMedia,
            filenamePrefix: "gif",
            normalizedNsec: normalizedNsec,
            imetaTagTransform: gifKeyboardIMetaTag(from:preparedMedia:)
        )
        return attachment
    }

    func uploadAttachment(
        from sharedAttachment: SharedComposeAttachment,
        normalizedNsec: String
    ) async throws -> ComposeMediaAttachment {
        let preparedMedia = try await prepareSharedComposeAttachmentForUpload(sharedAttachment)
        return try await uploadPreparedMedia(preparedMedia, filenamePrefix: "note", normalizedNsec: normalizedNsec)
    }

    func registerKlipyShare(for selection: KlipyGIFAttachmentCandidate) async {
        await klipyGIFService.registerShare(
            slug: selection.slug,
            customerID: selection.customerID,
            query: selection.searchQuery
        )
    }

    func textRemovingUploadedMediaURL(_ url: URL, from text: String) -> String {
        let urlString = url.absoluteString
        guard text.contains(urlString) else { return text }

        return text
            .replacingOccurrences(of: "\n\(urlString)", with: "")
            .replacingOccurrences(of: urlString, with: "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uploadPreparedMedia(
        _ preparedMedia: PreparedUploadMedia,
        filenamePrefix: String,
        normalizedNsec: String,
        imetaTagTransform: ([String], PreparedUploadMedia) -> [String] = { imetaTag, _ in imetaTag }
    ) async throws -> ComposeMediaAttachment {
        let filename = "\(filenamePrefix)-\(uuidProvider().uuidString).\(preparedMedia.fileExtension)"
        let result = try await mediaUploadService.uploadMedia(
            data: preparedMedia.data,
            mimeType: preparedMedia.mimeType,
            filename: filename,
            nsec: normalizedNsec,
            provider: .blossom
        )

        return ComposeMediaAttachment(
            url: result.url,
            imetaTag: imetaTagTransform(result.imetaTag, preparedMedia),
            mimeType: preparedMedia.mimeType,
            fileSizeBytes: preparedMedia.data.count
        )
    }

    private func gifKeyboardIMetaTag(
        from imetaTag: [String],
        preparedMedia: PreparedUploadMedia
    ) -> [String] {
        guard preparedMedia.mimeType.lowercased().hasPrefix("video/") else {
            return imetaTag
        }

        var updatedTag = imetaTag
        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("m ") }) {
            updatedTag.append("m \(preparedMedia.mimeType)")
        }
        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("size ") }) {
            updatedTag.append("size \(preparedMedia.data.count)")
        }
        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("flow-gif-loop ") }) {
            updatedTag.append("flow-gif-loop 1")
        }

        if !updatedTag.contains(where: { $0.lowercased().hasPrefix("dim ") }),
           let previewSize = preparedMedia.previewImage?.size,
           previewSize.width > 0,
           previewSize.height > 0 {
            updatedTag.append("dim \(Int(previewSize.width.rounded()))x\(Int(previewSize.height.rounded()))")
        }

        return updatedTag
    }

    private func prepareSharedComposeAttachmentForUpload(
        _ sharedAttachment: SharedComposeAttachment
    ) async throws -> PreparedUploadMedia {
        guard let fileURL = sharedAttachment.resolvedFileURL else {
            throw SharedComposeImportError.missingFileURL
        }

        let mimeType = sharedAttachment.mimeType
        let normalizedMimeType = mimeType.lowercased()
        let normalizedFileExtension = sharedAttachment.fileExtension.lowercased()

        if normalizedMimeType.hasPrefix("video/") ||
            ["mp4", "mov", "m4v", "webm", "mkv"].contains(normalizedFileExtension) {
            return try await MediaUploadPreparation.prepareUploadMedia(
                fileURL: fileURL,
                mimeType: mimeType,
                fileExtension: normalizedFileExtension
            )
        }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            throw SharedComposeImportError.unreadableFile
        }

        return try MediaUploadPreparation.prepareUploadMedia(
            data: data,
            mimeType: mimeType,
            fileExtension: normalizedFileExtension
        )
    }
}

struct ComposeMentionSuggestionController {
    func suggestions(
        for query: ComposeMentionQuery,
        currentAccountPubkey: String?,
        selectedMentions: [ComposeSelectedMention],
        profileService: NostrFeedService,
        limit: Int = 24
    ) async -> [ComposeMentionSuggestion] {
        let normalizedQuery = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let followedPubkeys = await MainActor.run {
            FollowStore.shared.followedPubkeys
        }
        let profileResults: [ProfileSearchResult]
        if normalizedQuery.isEmpty {
            profileResults = await localMentionSeedProfileResults(
                followedPubkeys: followedPubkeys,
                limit: limit,
                currentAccountPubkey: currentAccountPubkey,
                profileService: profileService
            )
        } else {
            profileResults = await profileService.searchProfiles(
                query: normalizedQuery,
                limit: limit,
                preferredPubkeys: followedPubkeys
            )
        }

        let excludedPubkeys = Set(selectedMentions.map(\.pubkey))
        let normalizedCurrentPubkey = currentAccountPubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return profileResults.compactMap(ComposeMentionSuggestion.init).filter { suggestion in
            guard !excludedPubkeys.contains(suggestion.pubkey) else { return false }
            if let normalizedCurrentPubkey, suggestion.pubkey == normalizedCurrentPubkey {
                return false
            }
            return true
        }
    }

    private func localMentionSeedProfileResults(
        followedPubkeys: Set<String>,
        limit: Int,
        currentAccountPubkey: String?,
        profileService: NostrFeedService
    ) async -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        let orderedFollowedPubkeys = await orderedFollowedMentionPubkeys(
            fallback: followedPubkeys,
            currentAccountPubkey: currentAccountPubkey,
            profileService: profileService
        )
        let followedCandidates = Array(orderedFollowedPubkeys.prefix(max(limit * 3, 48)))
        let followedProfiles = await profileService.cachedProfiles(pubkeys: followedCandidates)
        let followedResults = followedCandidates.enumerated().compactMap { index, pubkey -> ProfileSearchResult? in
            guard let profile = followedProfiles[pubkey] else { return nil }
            return ProfileSearchResult(
                pubkey: pubkey,
                profile: profile,
                createdAt: Int.max - index
            )
        }
        let recentResults = await profileService.recentLocalProfiles(limit: limit)

        return mergedMentionProfileResults(
            [followedResults, recentResults],
            limit: limit
        )
    }

    private func orderedFollowedMentionPubkeys(
        fallback followedPubkeys: Set<String>,
        currentAccountPubkey: String?,
        profileService: NostrFeedService
    ) async -> [String] {
        if let normalizedCurrentPubkey = currentAccountPubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !normalizedCurrentPubkey.isEmpty,
           let snapshot = await profileService.cachedFollowListSnapshot(pubkey: normalizedCurrentPubkey) {
            let ordered = normalizedUniqueMentionPubkeys(snapshot.followedPubkeys)
            if !ordered.isEmpty {
                return ordered
            }
        }

        return normalizedUniqueMentionPubkeys(Array(followedPubkeys).sorted())
    }

    private func mergedMentionProfileResults(
        _ groups: [[ProfileSearchResult]],
        limit: Int
    ) -> [ProfileSearchResult] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var merged: [ProfileSearchResult] = []
        merged.reserveCapacity(limit)

        for group in groups {
            for result in group {
                let pubkey = result.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !pubkey.isEmpty, seen.insert(pubkey).inserted else { continue }
                merged.append(result)
                if merged.count >= limit {
                    return merged
                }
            }
        }

        return merged
    }

    private func normalizedUniqueMentionPubkeys(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(pubkeys.count)

        for pubkey in pubkeys {
            let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }
}

struct ComposeDraftInsertionResult: Equatable {
    let text: String
    let selectedMentions: [ComposeSelectedMention]
    let selectedRange: NSRange
}

struct ComposeDraftController {
    func makeSnapshot(
        text: String,
        additionalTags: [[String]],
        uploadedAttachments: [ComposeMediaAttachment],
        selectedMentions: [ComposeSelectedMention],
        pollDraft: ComposePollDraft?,
        replyTargetEvent: NostrEvent?,
        replyTargetDisplayNameHint: String?,
        replyTargetHandleHint: String?,
        replyTargetAvatarURLHint: URL?,
        quotedEvent: NostrEvent?,
        quotedDisplayNameHint: String?,
        quotedHandleHint: String?,
        quotedAvatarURLHint: URL?
    ) -> SavedComposeDraftSnapshot {
        SavedComposeDraftSnapshot(
            text: text,
            additionalTags: additionalTags,
            uploadedAttachments: uploadedAttachments,
            selectedMentions: selectedMentions,
            pollDraft: pollDraft,
            replyTargetEvent: replyTargetEvent,
            replyTargetDisplayNameHint: replyTargetDisplayNameHint,
            replyTargetHandleHint: replyTargetHandleHint,
            replyTargetAvatarURLHint: replyTargetAvatarURLHint,
            quotedEvent: quotedEvent,
            quotedDisplayNameHint: quotedDisplayNameHint,
            quotedHandleHint: quotedHandleHint,
            quotedAvatarURLHint: quotedAvatarURLHint
        )
    }

    @MainActor
    @discardableResult
    func saveDraftIfNeeded(
        store: AppComposeDraftStore,
        snapshot: SavedComposeDraftSnapshot,
        ownerPubkey: String?,
        existingDraftID: UUID?
    ) -> SavedComposeDraft? {
        store.saveDraft(
            snapshot: snapshot,
            ownerPubkey: ownerPubkey,
            existingDraftID: existingDraftID
        )
    }

    @MainActor
    func deleteDraft(
        _ draft: SavedComposeDraft,
        store: AppComposeDraftStore,
        activeDraftID: UUID?
    ) -> UUID? {
        store.deleteDraft(draft)
        return activeDraftID == draft.id ? nil : activeDraftID
    }

    func insertionResult(
        for draft: SavedComposeDraft,
        currentText: String,
        selectedMentions: [ComposeSelectedMention]
    ) -> ComposeDraftInsertionResult? {
        guard draft.canInsertText else { return nil }

        let separator: String
        if currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            separator = ""
        } else if currentText.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }

        let offset = (currentText as NSString).length + (separator as NSString).length
        let updatedText = currentText + separator + draft.snapshot.text
        var updatedMentions = selectedMentions + draft.snapshot.selectedMentions.map { $0.shifted(by: offset) }
        updatedMentions.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.handle < rhs.handle
            }
            return lhs.range.location < rhs.range.location
        }

        return ComposeDraftInsertionResult(
            text: updatedText,
            selectedMentions: updatedMentions,
            selectedRange: NSRange(location: (updatedText as NSString).length, length: 0)
        )
    }

    func freshSnapshot() -> SavedComposeDraftSnapshot {
        SavedComposeDraftSnapshot(
            text: "",
            additionalTags: [],
            uploadedAttachments: [],
            selectedMentions: [],
            pollDraft: nil,
            replyTargetEvent: nil,
            replyTargetDisplayNameHint: nil,
            replyTargetHandleHint: nil,
            replyTargetAvatarURLHint: nil,
            quotedEvent: nil,
            quotedDisplayNameHint: nil,
            quotedHandleHint: nil,
            quotedAvatarURLHint: nil
        )
    }

    func normalizedHint(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedHandle(_ value: String?) -> String? {
        guard let trimmed = normalizedHint(value) else { return nil }
        return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
    }
}

struct ComposeContextPreviewSnapshot: Equatable {
    let authorPubkey: String
    let createdAtDate: Date
    let previewText: String
    let imageURLs: [URL]
    let hasVideo: Bool
    let hasAudio: Bool
    let hasPoll: Bool
}

struct SavedComposeDraftSnapshot: Codable, Hashable, Sendable {
    var text: String
    var additionalTags: [[String]]
    var uploadedAttachments: [ComposeMediaAttachment]
    var selectedMentions: [ComposeSelectedMention]
    var pollDraft: ComposePollDraft?
    var replyTargetEvent: NostrEvent?
    var replyTargetDisplayNameHint: String?
    var replyTargetHandleHint: String?
    var replyTargetAvatarURLHint: URL?
    var quotedEvent: NostrEvent?
    var quotedDisplayNameHint: String?
    var quotedHandleHint: String?
    var quotedAvatarURLHint: URL?

    var hasMeaningfulContent: Bool {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !uploadedAttachments.isEmpty || pollDraft != nil {
            return true
        }
        return quotedEvent != nil
    }
}

struct SavedComposeDraft: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let ownerPubkey: String?
    let createdAt: Date
    let updatedAt: Date
    let snapshot: SavedComposeDraftSnapshot

    var mode: ComposeNoteSheetMode {
        ComposeNoteSheetMode(
            hasReplyTarget: snapshot.replyTargetEvent != nil,
            hasQuotedEvent: snapshot.quotedEvent != nil
        )
    }

    var textPreview: String {
        let normalized = snapshot.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            if normalized.count > 110 {
                let endIndex = normalized.index(normalized.startIndex, offsetBy: 110)
                return String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
            }
            return normalized
        }
        if snapshot.pollDraft != nil {
            return "Poll draft"
        }
        if snapshot.replyTargetEvent != nil {
            return "Reply draft"
        }
        if snapshot.quotedEvent != nil {
            return "Quote draft"
        }
        if !snapshot.uploadedAttachments.isEmpty {
            return "Media draft"
        }
        return "Untitled draft"
    }

    var accessorySummary: String {
        var parts: [String] = []
        if !snapshot.uploadedAttachments.isEmpty {
            let count = snapshot.uploadedAttachments.count
            parts.append("\(count) attachment\(count == 1 ? "" : "s")")
        }
        if snapshot.pollDraft != nil {
            parts.append("Poll")
        }
        return parts.joined(separator: " • ")
    }

    var canInsertText: Bool {
        !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class AppComposeDraftStore: ObservableObject {
    @Published private(set) var drafts: [SavedComposeDraft] = []

    private let defaults: UserDefaults
    private let storageKey = "app-compose-drafts-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadDrafts()
    }

    func drafts(for ownerPubkey: String?) -> [SavedComposeDraft] {
        let normalizedOwnerPubkey = Self.normalizedOwnerPubkey(ownerPubkey)
        return drafts.filter { $0.ownerPubkey == normalizedOwnerPubkey }
    }

    func draftCount(for ownerPubkey: String?) -> Int {
        drafts(for: ownerPubkey).count
    }

    @discardableResult
    func saveDraft(
        snapshot: SavedComposeDraftSnapshot,
        ownerPubkey: String?,
        existingDraftID: UUID? = nil
    ) -> SavedComposeDraft? {
        if !snapshot.hasMeaningfulContent {
            if let existingDraftID {
                deleteDraft(id: existingDraftID)
            }
            return nil
        }

        let now = Date()
        let normalizedOwnerPubkey = Self.normalizedOwnerPubkey(ownerPubkey)
        let existingDraft = existingDraftID.flatMap { draftID in
            self.draft(id: draftID)
        }
        let savedDraft = SavedComposeDraft(
            id: existingDraftID ?? UUID(),
            ownerPubkey: normalizedOwnerPubkey,
            createdAt: existingDraft?.createdAt ?? now,
            updatedAt: now,
            snapshot: snapshot
        )

        upsertDraft(savedDraft)
        return savedDraft
    }

    func deleteDraft(_ draft: SavedComposeDraft) {
        deleteDraft(id: draft.id)
    }

    func deleteDraft(id: UUID) {
        let previousCount = drafts.count
        drafts.removeAll { $0.id == id }
        guard drafts.count != previousCount else { return }
        persistDrafts()
    }

    func draft(id: UUID) -> SavedComposeDraft? {
        drafts.first { $0.id == id }
    }

    private func upsertDraft(_ draft: SavedComposeDraft) {
        if let existingIndex = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[existingIndex] = draft
        } else {
            drafts.append(draft)
        }

        drafts.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        persistDrafts()
    }

    private func loadDrafts() {
        guard let data = defaults.data(forKey: storageKey) else {
            drafts = []
            return
        }

        do {
            drafts = try JSONDecoder().decode([SavedComposeDraft].self, from: data)
        } catch {
            drafts = []
        }
    }

    private func persistDrafts() {
        do {
            let data = try JSONEncoder().encode(drafts)
            defaults.set(data, forKey: storageKey)
        } catch {
            assertionFailure("Failed to persist compose drafts: \(error.localizedDescription)")
        }
    }

    private static func normalizedOwnerPubkey(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ComposeFloatingActionButton: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(appSettings.buttonTextColor)
                .frame(width: 56, height: 56)
                .background(appSettings.primaryGradient, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compose")
    }
}

enum ComposeNoteSheetMode: Equatable {
    case newNote
    case reply
    case quote

    init(hasReplyTarget: Bool, hasQuotedEvent: Bool) {
        if hasQuotedEvent {
            self = .quote
        } else if hasReplyTarget {
            self = .reply
        } else {
            self = .newNote
        }
    }

    var navigationTitle: String {
        switch self {
        case .newNote:
            return "Compose"
        case .reply:
            return "Reply"
        case .quote:
            return "Quote"
        }
    }

    var publishButtonTitle: String {
        switch self {
        case .reply:
            return "Reply"
        case .newNote, .quote:
            return "Post"
        }
    }

    var placeholderText: String {
        switch self {
        case .newNote:
            return "What do you want to share?"
        case .reply:
            return "Post your reply"
        case .quote:
            return "Add your thoughts"
        }
    }

    var accessibilityActionLabel: String {
        switch self {
        case .newNote:
            return "Posting"
        case .reply:
            return "Replying"
        case .quote:
            return "Quoting"
        }
    }
}

struct ComposeMultilineTextView: UIViewRepresentable {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var selectedRange: NSRange
    @Binding var mentions: [ComposeSelectedMention]
    @Binding var mentionAnchorY: CGFloat
    let mentionColor: UIColor
    let characterLimit: Int
    let onMentionQueryChange: (ComposeMentionQuery?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            selectedRange: $selectedRange,
            mentions: $mentions,
            mentionAnchorY: $mentionAnchorY,
            characterLimit: characterLimit,
            onMentionQueryChange: onMentionQueryChange
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = Self.makeComposerTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = appSettings.appUIFont(.body)
        textView.adjustsFontForContentSizeCategory = false
        textView.textColor = UIColor(appSettings.themePalette.foreground)
        textView.tintColor = UIColor(appSettings.themePalette.foreground)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.bounces = false
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let preferredFont = appSettings.appUIFont(.body)
        let preferredTextColor = UIColor(appSettings.themePalette.foreground)
        let fontChanged = uiView.font != preferredFont
        if fontChanged {
            uiView.font = preferredFont
        }

        let textColorChanged = uiView.textColor != preferredTextColor
        if textColorChanged {
            uiView.textColor = preferredTextColor
            uiView.tintColor = preferredTextColor
        }

        if uiView.text != text, uiView.markedTextRange == nil {
            context.coordinator.isApplyingProgrammaticUpdate = true
            uiView.text = text
            context.coordinator.isApplyingProgrammaticUpdate = false
        }

        context.coordinator.applyExternalSelectionIfNeeded(to: uiView, selectedRange: selectedRange)

        if isFocused {
            guard uiView.window != nil, !uiView.isFirstResponder else { return }
            DispatchQueue.main.async {
                if uiView.window != nil && !uiView.isFirstResponder {
                    uiView.becomeFirstResponder()
                }
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    static func makeComposerTextView() -> UITextView {
        // Keep the composer on UIKit's plain native text-input path. Emoji
        // QuickType suggestions do not have a public opt-in API; they depend on
        // default UITextInputTraits and the system text stack, so avoid TextKit
        // opt-outs or forced prediction traits without device-verifying them.
        UITextView()
    }

    private static func clampedRange(_ range: NSRange, maxLength: Int) -> NSRange {
        let location = min(max(range.location, 0), maxLength)
        let remainingLength = max(0, maxLength - location)
        let length = min(max(range.length, 0), remainingLength)
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool
        @Binding private var selectedRange: NSRange
        @Binding private var mentions: [ComposeSelectedMention]
        @Binding private var mentionAnchorY: CGFloat
        private let characterLimit: Int
        private let onMentionQueryChange: (ComposeMentionQuery?) -> Void
        var isApplyingProgrammaticUpdate = false
        private var lastReportedMentionQuery: ComposeMentionQuery?
        // Keep selection reconciliation stateful. UITextView reports a new caret
        // before SwiftUI has necessarily re-rendered with that binding value;
        // applying the older bound range during that update moves the cursor
        // backward while typing. Do not replace this with a stateless clamp/set
        // helper unless you also preserve the stale-echo guard below.
        private var pendingTextViewSelectionReport: NSRange?
        private var staleSelectionEchoes: [NSRange] = []

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            selectedRange: Binding<NSRange>,
            mentions: Binding<[ComposeSelectedMention]>,
            mentionAnchorY: Binding<CGFloat>,
            characterLimit: Int,
            onMentionQueryChange: @escaping (ComposeMentionQuery?) -> Void
        ) {
            _text = text
            _isFocused = isFocused
            _selectedRange = selectedRange
            _mentions = mentions
            _mentionAnchorY = mentionAnchorY
            self.characterLimit = characterLimit
            self.onMentionQueryChange = onMentionQueryChange
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            let allowedReplacement = ComposeNoteTextLimit.allowedReplacement(
                in: textView.text ?? "",
                range: range,
                replacementText: text,
                limit: characterLimit
            )

            guard allowedReplacement == text else {
                guard !allowedReplacement.isEmpty else { return false }
                applyReplacement(allowedReplacement, to: textView, in: range)
                return false
            }

            let updatedMentions = ComposeMentionSupport.updatedMentions(
                mentions,
                forEditIn: range,
                replacementText: allowedReplacement
            )
            reportMentions(updatedMentions)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            reportSelectedRange(textView.selectedRange)
            reportText(textView.text)
            updateMentionQuery(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            guard reportSelectedRange(textView.selectedRange) else { return }
            updateMentionQuery(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            reportFocus(true)
            reportSelectedRange(textView.selectedRange)
            updateMentionQuery(for: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            reportFocus(false)
            reportSelectedRange(textView.selectedRange)
            lastReportedMentionQuery = nil
            onMentionQueryChange(nil)
        }

        func applyExternalSelectionIfNeeded(to textView: UITextView, selectedRange: NSRange) {
            guard textView.markedTextRange == nil else { return }

            let clampedRange = ComposeMultilineTextView.clampedRange(
                selectedRange,
                maxLength: textView.text.utf16.count
            )

            // A range we just reported from UITextView is authoritative. Older
            // SwiftUI echoes are ignored, while explicit external selections
            // like mention or draft insertion are still allowed through.
            if let pendingTextViewSelectionReport {
                if clampedRange == pendingTextViewSelectionReport {
                    self.pendingTextViewSelectionReport = nil
                    staleSelectionEchoes.removeAll()
                } else if staleSelectionEchoes.contains(clampedRange) {
                    return
                } else {
                    self.pendingTextViewSelectionReport = nil
                    staleSelectionEchoes.removeAll()
                }
            }

            if textView.selectedRange != clampedRange {
                textView.selectedRange = clampedRange
            }
        }

        private func updateMentionQuery(for textView: UITextView) {
            let query = ComposeMentionSupport.activeQuery(
                in: textView.text,
                selection: textView.selectedRange,
                confirmedMentions: mentions
            )
            updateMentionAnchor(for: textView, hasActiveQuery: query != nil)
            guard query != lastReportedMentionQuery else { return }
            lastReportedMentionQuery = query
            onMentionQueryChange(query)
        }

        private func applyReplacement(
            _ replacementText: String,
            to textView: UITextView,
            in range: NSRange
        ) {
            let updatedText = ((textView.text ?? "") as NSString)
                .replacingCharacters(in: range, with: replacementText)
            let updatedMentions = ComposeMentionSupport.updatedMentions(
                mentions,
                forEditIn: range,
                replacementText: replacementText
            )
            reportMentions(updatedMentions)

            let updatedSelection = NSRange(
                location: range.location + (replacementText as NSString).length,
                length: 0
            )
            isApplyingProgrammaticUpdate = true
            textView.text = updatedText
            textView.selectedRange = updatedSelection
            isApplyingProgrammaticUpdate = false

            reportText(updatedText)
            reportSelectedRange(updatedSelection)
            updateMentionQuery(for: textView)
        }

        private func updateMentionAnchor(for textView: UITextView, hasActiveQuery: Bool) {
            guard hasActiveQuery, let caretPosition = textView.selectedTextRange?.end else {
                reportMentionAnchorY(44)
                return
            }

            let caretRect = textView.caretRect(for: caretPosition)
            let visibleCaretBottom = caretRect.maxY - textView.contentOffset.y
            let clampedAnchorY = min(max(visibleCaretBottom, 32), max(textView.bounds.height - 44, 44))
            reportMentionAnchorY(clampedAnchorY)
        }

        @discardableResult
        private func reportText(_ newValue: String) -> Bool {
            guard text != newValue else { return false }
            text = newValue
            return true
        }

        @discardableResult
        private func reportFocus(_ newValue: Bool) -> Bool {
            guard isFocused != newValue else { return false }
            isFocused = newValue
            return true
        }

        @discardableResult
        private func reportSelectedRange(_ newValue: NSRange) -> Bool {
            guard selectedRange != newValue else { return false }
            staleSelectionEchoes.append(selectedRange)
            if staleSelectionEchoes.count > 4 {
                staleSelectionEchoes.removeFirst(staleSelectionEchoes.count - 4)
            }
            pendingTextViewSelectionReport = newValue
            selectedRange = newValue
            return true
        }

        @discardableResult
        private func reportMentions(_ newValue: [ComposeSelectedMention]) -> Bool {
            guard mentions != newValue else { return false }
            mentions = newValue
            return true
        }

        @discardableResult
        private func reportMentionAnchorY(_ newValue: CGFloat) -> Bool {
            guard abs(mentionAnchorY - newValue) >= 0.5 else { return false }
            mentionAnchorY = newValue
            return true
        }
    }
}

struct ComposeMentionSuggestionRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let suggestion: ComposeMentionSuggestion

    var body: some View {
        HStack(spacing: 12) {
            ComposeMentionAvatarView(
                url: suggestion.avatarURL,
                fallbackText: suggestion.displayName
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .lineLimit(1)

                Text(suggestion.secondaryText)
                    .font(.caption)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct ComposeMentionAvatarView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let url: URL?
    let fallbackText: String

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
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
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(appSettings.themePalette.secondaryFill)
            Text(String(fallbackText.prefix(1)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (CapturedCameraMedia) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.mediaTypes = supportedMediaTypes
        picker.videoQuality = .typeMedium
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    private var supportedMediaTypes: [String] {
        let available = Set(UIImagePickerController.availableMediaTypes(for: .camera) ?? [])
        let preferred = [UTType.image.identifier, UTType.movie.identifier]
        let filtered = preferred.filter { available.contains($0) }
        return filtered.isEmpty ? [UTType.image.identifier] : filtered
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraCaptureView

        init(parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let mediaType = info[.mediaType] as? String else {
                parent.onCancel()
                return
            }

            if mediaType == UTType.movie.identifier,
               let mediaURL = info[.mediaURL] as? URL {
                let fileExtension = mediaURL.pathExtension.isEmpty ? "mov" : mediaURL.pathExtension.lowercased()
                let mimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "video/quicktime"
                parent.onCapture(.video(fileURL: mediaURL, mimeType: mimeType, fileExtension: fileExtension))
                return
            }

            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage,
               let imageData = image.jpegData(compressionQuality: 0.92) {
                parent.onCapture(.image(data: imageData, mimeType: "image/jpeg", fileExtension: "jpg"))
                return
            }

            parent.onCancel()
        }
    }
}
