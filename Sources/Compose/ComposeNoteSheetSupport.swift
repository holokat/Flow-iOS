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
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = appSettings.appUIFont(.body)
        textView.adjustsFontForContentSizeCategory = false
        textView.textColor = UIColor(appSettings.themePalette.foreground)
        textView.tintColor = UIColor(appSettings.themePalette.foreground)
        Self.configureNaturalLanguageInputTraits(for: textView)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
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
        Self.configureNaturalLanguageInputTraits(for: uiView)

        if uiView.text != text, uiView.markedTextRange == nil {
            context.coordinator.isApplyingProgrammaticUpdate = true
            uiView.text = text
            context.coordinator.isApplyingProgrammaticUpdate = false
        }

        let clampedRange = Self.clampedRange(selectedRange, maxLength: uiView.text.utf16.count)
        if uiView.selectedRange != clampedRange {
            uiView.selectedRange = clampedRange
        }

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

    private static func configureNaturalLanguageInputTraits(for textView: UITextView) {
        if textView.autocapitalizationType != .sentences {
            textView.autocapitalizationType = .sentences
        }
        if textView.autocorrectionType != .yes {
            textView.autocorrectionType = .yes
        }
        if textView.spellCheckingType != .yes {
            textView.spellCheckingType = .yes
        }
        if textView.smartQuotesType != .yes {
            textView.smartQuotesType = .yes
        }
        if textView.smartDashesType != .yes {
            textView.smartDashesType = .yes
        }
        if textView.smartInsertDeleteType != .yes {
            textView.smartInsertDeleteType = .yes
        }
        if textView.keyboardType != .default {
            textView.keyboardType = .default
        }
        if textView.returnKeyType != .default {
            textView.returnKeyType = .default
        }
        if textView.textContentType != nil {
            textView.textContentType = nil
        }

        if #available(iOS 17.0, *) {
            if textView.inlinePredictionType != .yes {
                textView.inlinePredictionType = .yes
            }
        }
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
            if updatedMentions != mentions {
                mentions = updatedMentions
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            text = textView.text
            selectedRange = textView.selectedRange
            updateMentionQuery(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            selectedRange = textView.selectedRange
            updateMentionQuery(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused = true
            selectedRange = textView.selectedRange
            updateMentionQuery(for: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused = false
            selectedRange = textView.selectedRange
            lastReportedMentionQuery = nil
            onMentionQueryChange(nil)
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
            if updatedMentions != mentions {
                mentions = updatedMentions
            }

            let updatedSelection = NSRange(
                location: range.location + (replacementText as NSString).length,
                length: 0
            )
            isApplyingProgrammaticUpdate = true
            textView.text = updatedText
            textView.selectedRange = updatedSelection
            isApplyingProgrammaticUpdate = false

            text = updatedText
            selectedRange = updatedSelection
            updateMentionQuery(for: textView)
        }

        private func updateMentionAnchor(for textView: UITextView, hasActiveQuery: Bool) {
            guard hasActiveQuery, let caretPosition = textView.selectedTextRange?.end else {
                mentionAnchorY = 44
                return
            }

            let caretRect = textView.caretRect(for: caretPosition)
            let visibleCaretBottom = caretRect.maxY - textView.contentOffset.y
            let clampedAnchorY = min(max(visibleCaretBottom, 32), max(textView.bounds.height - 44, 44))
            mentionAnchorY = clampedAnchorY
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
