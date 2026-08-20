import CryptoKit
import Foundation
import NostrSDK
import UniformTypeIdentifiers

enum HaloLinkError: LocalizedError {
    case missingPrivateKey
    case invalidPrivateKey
    case invalidRecipient
    case missingInboxRelays
    case missingRecipientInboxRelays
    case publishFailed(String)
    case malformedGiftWrap
    case malformedRumor
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey:
            return "Sign in to use Halo Link."
        case .invalidPrivateKey:
            return "This account is no longer valid."
        case .invalidRecipient:
            return "That conversation has an invalid participant."
        case .missingInboxRelays:
            return "Messaging isn’t fully connected yet. Check Connection settings."
        case .missingRecipientInboxRelays:
            return "One or more people can’t receive private messages yet."
        case .publishFailed(let message):
            return message
        case .malformedGiftWrap:
            return "Halo couldn’t open this private message."
        case .malformedRumor:
            return "Halo couldn’t read this private message."
        case .decryptionFailed:
            return "A Halo Link message could not be decrypted."
        }
    }
}

private struct HaloLinkSession: Equatable {
    let accountPubkey: String
    let nsec: String
    let readRelayURLs: [URL]
    let writeRelayURLs: [URL]
    let inboxRelayURLs: [URL]

    var keypair: Keypair? {
        Keypair(nsec: nsec.lowercased())
    }
}

final class HaloLinkLocalStateStore {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let messagesReadKeyPrefix = "flow.haloLink.messagesReadAt"
    private let conversationReadKeyPrefix = "flow.haloLink.conversationReadAt"
    private let dismissedConversationKeyPrefix = "flow.haloLink.dismissedConversation"
    private let snapshotDirectoryName = "HaloLinkSnapshots"
    private let snapshotQueue = DispatchQueue(label: "flow.halolink.snapshot", qos: .utility)

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func messagesReadAt(for accountPubkey: String) -> Int {
        defaults.integer(forKey: key(messagesReadKeyPrefix, accountPubkey))
    }

    func setMessagesReadAt(_ value: Int, for accountPubkey: String) {
        defaults.set(value, forKey: key(messagesReadKeyPrefix, accountPubkey))
    }

    func conversationReadAtMap(for accountPubkey: String) -> [String: Int] {
        loadMap(for: key(conversationReadKeyPrefix, accountPubkey))
    }

    func setConversationReadAt(
        _ value: Int,
        for conversationID: String,
        accountPubkey: String
    ) {
        var map = conversationReadAtMap(for: accountPubkey)
        map[conversationID] = value
        saveMap(map, for: key(conversationReadKeyPrefix, accountPubkey))
    }

    func dismissedConversationMap(for accountPubkey: String) -> [String: Int] {
        loadMap(for: key(dismissedConversationKeyPrefix, accountPubkey))
    }

    func setDismissedConversationAt(
        _ value: Int,
        for conversationID: String,
        accountPubkey: String
    ) {
        var map = dismissedConversationMap(for: accountPubkey)
        map[conversationID] = value
        saveMap(map, for: key(dismissedConversationKeyPrefix, accountPubkey))
    }

    func snapshot(for accountPubkey: String) -> HaloLinkSnapshot? {
        let snapshotURL = snapshotFileURL(for: accountPubkey)
        guard let data = snapshotQueue.sync(execute: { try? Data(contentsOf: snapshotURL) }),
              let snapshot = try? JSONDecoder().decode(HaloLinkSnapshot.self, from: data),
              snapshot.version == HaloLinkSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    func saveSnapshot(_ snapshot: HaloLinkSnapshot, for accountPubkey: String) {
        let snapshotURL = snapshotFileURL(for: accountPubkey)
        snapshotQueue.async { [fileManager] in
            do {
                try fileManager.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: snapshotURL, options: .atomic)
            } catch {
                return
            }
        }
    }

    private func key(_ prefix: String, _ accountPubkey: String) -> String {
        "\(prefix).\(accountPubkey)"
    }

    private func loadMap(for key: String) -> [String: Int] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveMap(_ map: [String: Int], for key: String) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }

    private func snapshotFileURL(for accountPubkey: String) -> URL {
        snapshotDirectoryURL()
            .appendingPathComponent(accountPubkey.lowercased(), conformingTo: .json)
    }

    private func snapshotDirectoryURL() -> URL {
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport.appendingPathComponent(snapshotDirectoryName, isDirectory: true)
        }

        if let libraryDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            return libraryDirectory.appendingPathComponent(snapshotDirectoryName, isDirectory: true)
        }

        return fileManager.temporaryDirectory.appendingPathComponent(snapshotDirectoryName, isDirectory: true)
    }
}

actor HaloLinkRelayLookupService {
    private let relayClient: NostrRelayClient

    init(relayClient: NostrRelayClient = NostrRelayClient()) {
        self.relayClient = relayClient
    }

    func fetchEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval
    ) async -> [NostrEvent] {
        await withTaskGroup(of: [NostrEvent].self, returning: [NostrEvent].self) { group in
            for relayURL in relayURLs {
                group.addTask {
                    (try? await self.relayClient.fetchEvents(
                        relayURL: relayURL,
                        filter: filter,
                        timeout: timeout
                    )) ?? []
                }
            }

            var merged: [NostrEvent] = []
            for await events in group {
                merged.append(contentsOf: events)
            }
            return merged
        }
    }
}

private struct HaloLinkEncryptedFilePayload {
    let encryptedData: Data
    let originalMimeType: String
    let fileExtension: String
    let encryptedHash: String
    let originalHash: String
    let decryptionKeyBase64: String
    let decryptionNonceBase64: String
}

private struct HaloLinkAttachmentDecryptionInfo {
    let mimeType: String
    let decryptionKeyBase64: String
    let decryptionNonceBase64: String
}

private actor HaloLinkMediaDecryptor {
    private var decryptedFileURLs: [String: URL] = [:]
    private var decryptionOrder: [String] = []
    private let maxEntries = 120

    func resolvedMediaURL(for message: HaloLinkMessage) async throws -> URL {
        guard let remoteURL = message.primaryMediaURL else {
            throw HaloLinkError.decryptionFailed
        }

        guard let decryptionInfo = Self.decryptionInfo(from: message.tags) else {
            return remoteURL
        }

        if let cachedURL = decryptedFileURLs[message.id] {
            return cachedURL
        }

        let (encryptedData, _) = try await URLSession.shared.data(from: remoteURL)
        let decryptedData = try Self.decrypt(
            encryptedData: encryptedData,
            decryptionInfo: decryptionInfo
        )

        let fileExtension = UTType(mimeType: decryptionInfo.mimeType)?.preferredFilenameExtension ?? "bin"
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-link-\(message.id).\(fileExtension)")

        try decryptedData.write(to: destinationURL, options: .atomic)
        setCachedURL(destinationURL, for: message.id)
        return destinationURL
    }

    private func setCachedURL(_ url: URL, for messageID: String) {
        decryptedFileURLs[messageID] = url
        decryptionOrder.removeAll { $0 == messageID }
        decryptionOrder.append(messageID)

        while decryptionOrder.count > maxEntries {
            let removedID = decryptionOrder.removeFirst()
            if let removedURL = decryptedFileURLs.removeValue(forKey: removedID) {
                try? FileManager.default.removeItem(at: removedURL)
            }
        }
    }

    private static func decryptionInfo(from tags: [[String]]) -> HaloLinkAttachmentDecryptionInfo? {
        guard let mimeType = HaloLinkSupport.firstTagValue(named: "file-type", from: tags),
              let decryptionKey = HaloLinkSupport.firstTagValue(named: "decryption-key", from: tags),
              let decryptionNonce = HaloLinkSupport.firstTagValue(named: "decryption-nonce", from: tags),
              HaloLinkSupport.firstTagValue(named: "encryption-algorithm", from: tags)?.lowercased() == "aes-gcm" else {
            return nil
        }

        return HaloLinkAttachmentDecryptionInfo(
            mimeType: mimeType,
            decryptionKeyBase64: decryptionKey,
            decryptionNonceBase64: decryptionNonce
        )
    }

    private static func decrypt(
        encryptedData: Data,
        decryptionInfo: HaloLinkAttachmentDecryptionInfo
    ) throws -> Data {
        guard let rawKey = Data(base64Encoded: decryptionInfo.decryptionKeyBase64),
              let nonceData = Data(base64Encoded: decryptionInfo.decryptionNonceBase64) else {
            throw HaloLinkError.decryptionFailed
        }

        let key = SymmetricKey(data: rawKey)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        // NIP-17 attachment payloads are ciphertext+tag, with the nonce carried in tags.
        if encryptedData.count > 16 {
            let ciphertext = encryptedData.dropLast(16)
            let tag = encryptedData.suffix(16)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealedBox, using: key)
        }

        // Fall back to the older combined payload shape so previously sent attachments still open.
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }
}

private struct HaloLinkEventFactory: EventCreating, EventVerifying {}

@MainActor
final class HaloLinkStore: ObservableObject {
    @Published private(set) var conversations: [HaloLinkConversation] = []
    @Published private(set) var activeConversations: [HaloLinkConversation] = []
    @Published private(set) var requests: [HaloLinkConversation] = []
    @Published private(set) var unreadMessageCount = 0
    @Published private(set) var unreadConversationCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedMessages = false
    @Published private(set) var errorMessage: String?

    private let stateStore: HaloLinkLocalStateStore
    private let relayLookupService: HaloLinkRelayLookupService
    private let relayClient: NostrRelayClient
    private let liveSubscriber: NostrLiveFeedSubscriber
    private let feedService: NostrFeedService
    private let mediaUploadService: MediaUploadService
    private let mediaDecryptor = HaloLinkMediaDecryptor()
    private let eventFactory = HaloLinkEventFactory()

    private let bootstrapLookupRelayURLs: [URL] = [
        URL(string: "wss://relay.damus.io/")!,
        URL(string: "wss://relay.primal.net/")!,
        URL(string: "wss://nos.lol/")!,
        URL(string: "wss://relay.nostr.band/")!
    ]

    private var session: HaloLinkSession?
    private var followedPubkeys = Set<String>()
    private var profilesByPubkey: [String: NostrProfile] = [:]
    private var messagesByID: [String: HaloLinkMessage] = [:]
    private var reactionsByID: [String: HaloLinkMessageReaction] = [:]
    private var knownWrapIDs = Set<String>()
    private var ownInboxRelayURLs: [URL] = []
    private var inboxRelayCache: [String: [URL]] = [:]
    private var messagesReadAt = 0
    private var conversationReadAtMap: [String: Int] = [:]
    private var dismissedConversationMap: [String: Int] = [:]
    private var loadTask: Task<Void, Never>?
    private var liveTasks: [String: Task<Void, Never>] = [:]

    init(
        stateStore: HaloLinkLocalStateStore = HaloLinkLocalStateStore(),
        relayLookupService: HaloLinkRelayLookupService = HaloLinkRelayLookupService(),
        relayClient: NostrRelayClient = NostrRelayClient(),
        liveSubscriber: NostrLiveFeedSubscriber = NostrLiveFeedSubscriber(),
        feedService: NostrFeedService = NostrFeedService(),
        mediaUploadService: MediaUploadService = .shared
    ) {
        self.stateStore = stateStore
        self.relayLookupService = relayLookupService
        self.relayClient = relayClient
        self.liveSubscriber = liveSubscriber
        self.feedService = feedService
        self.mediaUploadService = mediaUploadService
    }

    deinit {
        loadTask?.cancel()
        liveTasks.values.forEach { $0.cancel() }
    }

    func configure(
        accountPubkey: String?,
        nsec: String?,
        readRelayURLs: [URL],
        writeRelayURLs: [URL],
        inboxRelayURLs: [URL],
        followedPubkeys: Set<String>
    ) {
        self.followedPubkeys = Set(followedPubkeys.map(HaloLinkSupport.normalizePubkey))

        let normalizedAccountPubkey = HaloLinkSupport.normalizePubkey(accountPubkey)
        let normalizedNsec = (nsec ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedReadRelays = HaloLinkSupport.normalizedRelayURLs(readRelayURLs)
        let normalizedWriteRelays = HaloLinkSupport.normalizedRelayURLs(writeRelayURLs)
        let normalizedInboxRelays = HaloLinkSupport.normalizedRelayURLs(inboxRelayURLs)

        guard !normalizedAccountPubkey.isEmpty, !normalizedNsec.isEmpty else {
            resetState()
            return
        }

        let nextSession = HaloLinkSession(
            accountPubkey: normalizedAccountPubkey,
            nsec: normalizedNsec,
            readRelayURLs: normalizedReadRelays,
            writeRelayURLs: normalizedWriteRelays,
            inboxRelayURLs: normalizedInboxRelays
        )

        guard nextSession != session else {
            rebuildConversations()
            return
        }

        session = nextSession
        messagesReadAt = stateStore.messagesReadAt(for: normalizedAccountPubkey)
        conversationReadAtMap = stateStore.conversationReadAtMap(for: normalizedAccountPubkey)
        dismissedConversationMap = stateStore.dismissedConversationMap(for: normalizedAccountPubkey)
        profilesByPubkey = [:]
        messagesByID = [:]
        reactionsByID = [:]
        knownWrapIDs = []
        ownInboxRelayURLs = []
        inboxRelayCache = [:]
        errorMessage = nil
        let restoredSnapshot = restoreSnapshot(for: normalizedAccountPubkey)
        isLoading = !restoredSnapshot
        hasLoadedMessages = restoredSnapshot
        rebuildConversations(persistSnapshot: false)

        loadTask?.cancel()
        liveTasks.values.forEach { $0.cancel() }
        liveTasks.removeAll()

        loadTask = Task { [weak self] in
            await self?.loadMessagesAndStartLiveSync(
                for: nextSession,
                restoredFromSnapshot: restoredSnapshot
            )
        }
    }

    func resetState() {
        session = nil
        loadTask?.cancel()
        liveTasks.values.forEach { $0.cancel() }
        liveTasks.removeAll()
        profilesByPubkey = [:]
        messagesByID = [:]
        reactionsByID = [:]
        knownWrapIDs = []
        ownInboxRelayURLs = []
        inboxRelayCache = [:]
        messagesReadAt = 0
        conversationReadAtMap = [:]
        dismissedConversationMap = [:]
        conversations = []
        activeConversations = []
        requests = []
        unreadConversationCount = 0
        unreadMessageCount = 0
        isLoading = false
        hasLoadedMessages = false
        errorMessage = nil
    }

    func conversation(for participantPubkeys: [String]) -> HaloLinkConversation? {
        let conversationID = HaloLinkSupport.conversationID(for: participantPubkeys)
        return conversations.first { $0.id == conversationID }
    }

    func displayName(for pubkey: String) -> String {
        let normalizedPubkey = HaloLinkSupport.normalizePubkey(pubkey)
        if let displayName = profilesByPubkey[normalizedPubkey]?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let name = profilesByPubkey[normalizedPubkey]?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return shortNostrIdentifier(normalizedPubkey)
    }

    func handle(for pubkey: String) -> String {
        let normalizedPubkey = HaloLinkSupport.normalizePubkey(pubkey)
        if let name = profilesByPubkey[normalizedPubkey]?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return "@\(name.replacingOccurrences(of: " ", with: "").lowercased())"
        }
        if let displayName = profilesByPubkey[normalizedPubkey]?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return "@\(displayName.replacingOccurrences(of: " ", with: "").lowercased())"
        }
        return "@\(shortNostrIdentifier(normalizedPubkey).lowercased())"
    }

    func avatarURL(for pubkey: String) -> URL? {
        profilesByPubkey[HaloLinkSupport.normalizePubkey(pubkey)]?.resolvedAvatarURL
    }

    func markAllAsRead() {
        guard let session else { return }
        let now = Int(Date().timeIntervalSince1970)
        messagesReadAt = now
        stateStore.setMessagesReadAt(now, for: session.accountPubkey)
        rebuildConversations()
    }

    func markConversationAsRead(_ conversationID: String) {
        guard let session else { return }
        let now = Int(Date().timeIntervalSince1970)
        conversationReadAtMap[conversationID] = now
        stateStore.setConversationReadAt(now, for: conversationID, accountPubkey: session.accountPubkey)
        rebuildConversations()
    }

    func dismissConversation(_ conversationID: String) {
        guard let session else { return }
        let dismissedAt = conversation(for: conversationID)?.lastMessageAt ?? Int(Date().timeIntervalSince1970)
        dismissedConversationMap[conversationID] = dismissedAt
        stateStore.setDismissedConversationAt(dismissedAt, for: conversationID, accountPubkey: session.accountPubkey)
        rebuildConversations()
    }

    func searchProfiles(query: String) async -> [ProfileSearchResult] {
        guard let session else { return [] }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayTargets = lookupRelayTargets(for: session)

        if normalizedQuery.isEmpty {
            return await feedService.recentLocalProfiles(limit: 18)
                .filter { $0.pubkey.lowercased() != session.accountPubkey }
        }

        do {
            return try await feedService.searchProfiles(
                relayURLs: relayTargets,
                query: normalizedQuery,
                limit: 24,
                fetchTimeout: 6,
                relayFetchMode: .firstNonEmptyRelay
            )
            .filter { $0.pubkey.lowercased() != session.accountPubkey }
        } catch {
            return await feedService.searchProfiles(query: normalizedQuery, limit: 24)
                .filter { $0.pubkey.lowercased() != session.accountPubkey }
        }
    }

    func sendMessage(
        recipientPubkeys: [String],
        content: String,
        attachments: [HaloLinkPreparedComposerAttachment] = [],
        replyToMessageID: String? = nil
    ) async throws {
        guard let session else { throw HaloLinkError.missingPrivateKey }
        guard let keypair = session.keypair else { throw HaloLinkError.invalidPrivateKey }

        let normalizedRecipients = HaloLinkSupport.normalizedUniquePubkeys(recipientPubkeys)
            .filter { $0 != session.accountPubkey }
        guard !normalizedRecipients.isEmpty else {
            throw HaloLinkError.invalidRecipient
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty || !attachments.isEmpty else { return }

        let relayMap = try await resolveRecipientRelayMap(
            recipientPubkeys: normalizedRecipients,
            session: session
        )

        var insertedMessageIDs: [String] = []

        do {
            if !trimmedContent.isEmpty {
                let rumor = try buildTextRumor(
                    content: trimmedContent,
                    recipientPubkeys: normalizedRecipients,
                    replyToMessageID: replyToMessageID,
                    keypair: keypair
                )
                let optimistic = try messageModel(from: rumor, wrapID: "local-\(rumor.id)", accountPubkey: session.accountPubkey)
                upsert(message: optimistic)
                insertedMessageIDs.append(optimistic.id)
                try await publishRumor(
                    rumor,
                    recipientPubkeys: normalizedRecipients,
                    relayMap: relayMap,
                    session: session
                )
            }

            for attachment in attachments {
                let optimisticAttachment = try makeOptimisticAttachmentMessage(
                    attachmentPayload: attachment.payload,
                    recipientPubkeys: normalizedRecipients,
                    accountPubkey: session.accountPubkey
                )
                upsert(message: optimisticAttachment)
                insertedMessageIDs.append(optimisticAttachment.id)

                let rumor = try buildAttachmentRumor(
                    attachment: attachment,
                    recipientPubkeys: normalizedRecipients,
                    keypair: keypair
                )
                let optimistic = try messageModel(
                    from: rumor,
                    wrapID: "local-\(rumor.id)",
                    accountPubkey: session.accountPubkey
                )
                messagesByID.removeValue(forKey: optimisticAttachment.id)
                deleteLocalOptimisticMediaIfNeeded(for: optimisticAttachment)
                insertedMessageIDs.removeAll { $0 == optimisticAttachment.id }
                upsert(message: optimistic)
                insertedMessageIDs.append(optimistic.id)
                try await publishRumor(
                    rumor,
                    recipientPubkeys: normalizedRecipients,
                    relayMap: relayMap,
                    session: session
                )
            }

            let now = Int(Date().timeIntervalSince1970)
            let conversationID = HaloLinkSupport.conversationID(for: normalizedRecipients)
            conversationReadAtMap[conversationID] = now
            stateStore.setConversationReadAt(now, for: conversationID, accountPubkey: session.accountPubkey)
            rebuildConversations()
        } catch {
            for messageID in insertedMessageIDs {
                if let removedMessage = messagesByID.removeValue(forKey: messageID) {
                    deleteLocalOptimisticMediaIfNeeded(for: removedMessage)
                }
            }
            rebuildConversations()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw HaloLinkError.publishFailed(message)
        }
    }

    func prepareAttachmentForSending(
        _ attachmentPayload: HaloLinkComposerAttachmentPayload
    ) async throws -> HaloLinkPreparedComposerAttachment {
        guard let session else { throw HaloLinkError.missingPrivateKey }

        let encryptedPayload = try encryptAttachmentPayload(attachmentPayload)
        let encryptedFilename = "halo-link-\(UUID().uuidString).\(attachmentPayload.fileExtension)"

        do {
            let uploadResult = try await mediaUploadService.uploadMedia(
                data: encryptedPayload.encryptedData,
                mimeType: encryptedPayload.originalMimeType,
                filename: encryptedFilename,
                nsec: session.nsec,
                provider: .blossom
            )

            return HaloLinkPreparedComposerAttachment(
                payload: attachmentPayload,
                upload: HaloLinkPreparedAttachmentUpload(
                    remoteURL: uploadResult.url,
                    mimeType: encryptedPayload.originalMimeType,
                    uploadMetadata: [],
                    encryptedMetadata: HaloLinkEncryptedAttachmentUploadMetadata(
                        encryptedHash: encryptedPayload.encryptedHash,
                        originalHash: encryptedPayload.originalHash,
                        decryptionKeyBase64: encryptedPayload.decryptionKeyBase64,
                        decryptionNonceBase64: encryptedPayload.decryptionNonceBase64,
                        encryptedSize: encryptedPayload.encryptedData.count
                    )
                )
            )
        } catch {
            let compatibilityUpload = try await mediaUploadService.uploadMedia(
                data: attachmentPayload.data,
                mimeType: attachmentPayload.mimeType,
                filename: encryptedFilename,
                nsec: session.nsec,
                provider: .blossom
            )

            return HaloLinkPreparedComposerAttachment(
                payload: attachmentPayload,
                upload: HaloLinkPreparedAttachmentUpload(
                    remoteURL: compatibilityUpload.url,
                    mimeType: attachmentPayload.mimeType,
                    uploadMetadata: compatibilityUpload.imetaTag,
                    encryptedMetadata: nil
                )
            )
        }
    }

    func sendReaction(
        emoji: String,
        to message: HaloLinkMessage
    ) async throws {
        guard let session else { throw HaloLinkError.missingPrivateKey }
        guard let keypair = session.keypair else { throw HaloLinkError.invalidPrivateKey }

        let normalizedRecipients = HaloLinkSupport.normalizedUniquePubkeys(message.participantPubkeys)
            .filter { $0 != session.accountPubkey }
        guard !normalizedRecipients.isEmpty else {
            throw HaloLinkError.invalidRecipient
        }

        let relayMap = try await resolveRecipientRelayMap(
            recipientPubkeys: normalizedRecipients,
            session: session
        )

        let rumor = try buildReactionRumor(
            emoji: emoji,
            targetMessage: message,
            recipientPubkeys: normalizedRecipients,
            keypair: keypair
        )
        let optimisticReaction = try reactionModel(
            from: rumor,
            wrapID: "local-\(rumor.id)",
            accountPubkey: session.accountPubkey
        )
        upsert(reaction: optimisticReaction)

        do {
            try await publishRumor(
                rumor,
                recipientPubkeys: normalizedRecipients,
                relayMap: relayMap,
                session: session
            )
            rebuildConversations()
        } catch {
            reactionsByID.removeValue(forKey: optimisticReaction.id)
            rebuildConversations()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw HaloLinkError.publishFailed(message)
        }
    }

    func mediaURL(for message: HaloLinkMessage) async throws -> URL {
        try await mediaDecryptor.resolvedMediaURL(for: message)
    }

    private func loadMessagesAndStartLiveSync(
        for session: HaloLinkSession,
        restoredFromSnapshot: Bool
    ) async {
        if restoredFromSnapshot {
            let recentSyncFloor = HaloLinkSyncPolicy.replaySince(
                latestRumorTimestamp: latestKnownActivityTimestamp()
            )
            let initialRelayTargets = messageRelayTargets(for: session)

            startLiveSubscriptions(
                for: session,
                relayTargets: initialRelayTargets,
                since: recentSyncFloor
            )
            await syncRecentMessages(
                for: session,
                relayTargets: initialRelayTargets,
                since: recentSyncFloor
            )

            let resolvedOwnInboxRelayURLs = await resolveOwnInboxRelayURLs(for: session)
            guard self.session == session else { return }

            ownInboxRelayURLs = resolvedOwnInboxRelayURLs
            let refreshedRelayTargets = messageRelayTargets(for: session)
            if refreshedRelayTargets != initialRelayTargets {
                startLiveSubscriptions(
                    for: session,
                    relayTargets: refreshedRelayTargets,
                    since: recentSyncFloor
                )
                await syncRecentMessages(
                    for: session,
                    relayTargets: refreshedRelayTargets,
                    since: recentSyncFloor
                )
            }

            guard self.session == session else { return }
            isLoading = false
            hasLoadedMessages = true
            errorMessage = nil
            rebuildConversations()
            return
        }

        ownInboxRelayURLs = await resolveOwnInboxRelayURLs(for: session)
        let relayTargets = messageRelayTargets(for: session)
        var until: Int?

        for page in 0..<HaloLinkSupport.maxBackfillPages {
            guard self.session == session, !Task.isCancelled else { return }

            let filter = NostrFilter(
                kinds: [HaloLinkSupport.giftWrapKind],
                limit: HaloLinkSupport.backfillPageLimit,
                until: until,
                tagFilters: ["p": [session.accountPubkey]]
            )
            let wrappedEvents = deduplicatedWrappedEvents(
                await relayLookupService.fetchEvents(
                    relayURLs: relayTargets,
                    filter: filter,
                    timeout: page == 0
                        ? HaloLinkSupport.initialQueryTimeout
                        : HaloLinkSupport.backfillQueryTimeout
                )
            )

            guard !wrappedEvents.isEmpty else { break }

            await applyWrappedEvents(wrappedEvents, session: session)
            until = wrappedEvents.last.map { $0.createdAt - 1 }
        }

        guard self.session == session else { return }
        isLoading = false
        hasLoadedMessages = true
        errorMessage = nil
        startLiveSubscriptions(
            for: session,
            relayTargets: relayTargets,
            since: HaloLinkSyncPolicy.replaySince(
                latestRumorTimestamp: latestKnownActivityTimestamp()
            )
        )
    }

    private func startLiveSubscriptions(
        for session: HaloLinkSession,
        relayTargets: [URL],
        since: Int? = nil
    ) {
        liveTasks.values.forEach { $0.cancel() }
        liveTasks.removeAll()

        let filter = NostrFilter(
            kinds: [HaloLinkSupport.giftWrapKind],
            limit: HaloLinkSupport.liveReplayLimit,
            since: since,
            tagFilters: ["p": [session.accountPubkey]]
        )

        for relayURL in relayTargets {
            let key = relayURL.absoluteString.lowercased()
            liveTasks[key] = Task { [weak self] in
                guard let self else { return }
                await liveSubscriber.run(
                    relayURL: relayURL,
                    filter: filter,
                    onNewEvent: { [weak self] event in
                        await self?.applyWrappedEvents([event], session: session)
                    }
                )
            }
        }
    }

    private func applyWrappedEvents(
        _ wrappedEvents: [NostrEvent],
        session: HaloLinkSession
    ) async {
        guard self.session == session else { return }

        var participantPubkeys = Set<String>()

        for wrappedEvent in wrappedEvents {
            let normalizedWrapID = wrappedEvent.id.lowercased()
            guard knownWrapIDs.insert(normalizedWrapID).inserted else { continue }

            guard let conversationEvent = try? unwrapConversationEvent(
                wrappedEvent: wrappedEvent,
                accountPubkey: session.accountPubkey,
                keypair: session.keypair
            ) else {
                continue
            }

            switch conversationEvent {
            case .message(let message):
                upsert(message: message)
                participantPubkeys.formUnion(message.participantPubkeys)
                participantPubkeys.insert(message.senderPubkey)
            case .reaction(let reaction):
                upsert(reaction: reaction)
                participantPubkeys.formUnion(reaction.participantPubkeys)
                participantPubkeys.insert(reaction.senderPubkey)
            }
        }

        guard !participantPubkeys.isEmpty else { return }

        // Publish decrypted messages immediately. Profile lookup is optional
        // enrichment and must never hold a reply behind relay timeouts.
        rebuildConversations()
        await refreshProfiles(for: Array(participantPubkeys), session: session)
        guard self.session == session else { return }
        rebuildConversations()
    }

    private func refreshProfiles(
        for pubkeys: [String],
        session: HaloLinkSession
    ) async {
        let targets = lookupRelayTargets(for: session)
        let normalizedPubkeys = HaloLinkSupport.normalizedUniquePubkeys(pubkeys)
        let missingPubkeys = normalizedPubkeys.filter { profilesByPubkey[$0] == nil }
        guard !missingPubkeys.isEmpty else { return }

        let fetchedProfiles = await feedService.fetchProfiles(
            relayURLs: targets,
            pubkeys: missingPubkeys
        )

        guard self.session == session else { return }
        profilesByPubkey.merge(fetchedProfiles) { _, new in new }
    }

    private func rebuildConversations(persistSnapshot: Bool = true) {
        let sortedMessages = messagesByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.wrapID < rhs.wrapID
            }
            return lhs.createdAt < rhs.createdAt
        }

        var conversationsByID: [String: HaloLinkConversation] = [:]
        var messageIDsByConversation: [String: Set<String>] = [:]

        for message in sortedMessages {
            if var conversation = conversationsByID[message.conversationID] {
                var nextMessages = conversation.messages
                nextMessages.append(message)
                conversation = HaloLinkConversation(
                    id: conversation.id,
                    participantPubkeys: conversation.participantPubkeys,
                    primaryPubkey: conversation.primaryPubkey,
                    isGroup: conversation.isGroup,
                    isRequest: conversation.isRequest,
                    unreadCount: conversation.unreadCount,
                    lastMessageAt: message.createdAt,
                    lastMessagePreview: message.previewText,
                    subject: message.subject ?? conversation.subject,
                    messages: nextMessages,
                    reactionsByMessageID: conversation.reactionsByMessageID,
                    hasOutgoingActivity: conversation.hasOutgoingActivity || message.isOutgoing
                )
                conversationsByID[conversation.id] = conversation
                messageIDsByConversation[conversation.id, default: []].insert(message.id)
            } else {
                conversationsByID[message.conversationID] = HaloLinkConversation(
                    id: message.conversationID,
                    participantPubkeys: message.participantPubkeys,
                    primaryPubkey: message.participantPubkeys.first,
                    isGroup: message.participantPubkeys.count > 1,
                    isRequest: false,
                    unreadCount: 0,
                    lastMessageAt: message.createdAt,
                    lastMessagePreview: message.previewText,
                    subject: message.subject,
                    messages: [message],
                    reactionsByMessageID: [:],
                    hasOutgoingActivity: message.isOutgoing
                )
                messageIDsByConversation[message.conversationID] = [message.id]
            }
        }

        let sortedReactions = reactionsByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.wrapID < rhs.wrapID
            }
            return lhs.createdAt < rhs.createdAt
        }

        for reaction in sortedReactions {
            guard var conversation = conversationsByID[reaction.conversationID],
                  messageIDsByConversation[reaction.conversationID]?.contains(reaction.targetMessageID) == true else {
                continue
            }

            var reactionsByMessageID = conversation.reactionsByMessageID
            reactionsByMessageID[reaction.targetMessageID, default: []].append(reaction)
            conversation = HaloLinkConversation(
                id: conversation.id,
                participantPubkeys: conversation.participantPubkeys,
                primaryPubkey: conversation.primaryPubkey,
                isGroup: conversation.isGroup,
                isRequest: conversation.isRequest,
                unreadCount: conversation.unreadCount,
                lastMessageAt: conversation.lastMessageAt,
                lastMessagePreview: conversation.lastMessagePreview,
                subject: conversation.subject,
                messages: conversation.messages,
                reactionsByMessageID: reactionsByMessageID,
                hasOutgoingActivity: conversation.hasOutgoingActivity || reaction.isOutgoing
            )
            conversationsByID[conversation.id] = conversation
        }

        let rebuilt = conversationsByID.values
            .map { conversation -> HaloLinkConversation in
                let readAt = max(messagesReadAt, conversationReadAtMap[conversation.id] ?? 0)
                let unreadCount = conversation.messages.filter {
                    !$0.isOutgoing && $0.createdAt > readAt
                }.count
                let isGroup = conversation.participantPubkeys.count > 1
                let primaryPubkey = conversation.primaryPubkey ?? ""
                let isRequest = isGroup
                    ? !conversation.hasOutgoingActivity
                    : !primaryPubkey.isEmpty
                        && !followedPubkeys.contains(primaryPubkey.lowercased())
                        && !conversation.hasOutgoingActivity

                return HaloLinkConversation(
                    id: conversation.id,
                    participantPubkeys: conversation.participantPubkeys,
                    primaryPubkey: conversation.primaryPubkey,
                    isGroup: conversation.isGroup,
                    isRequest: isRequest,
                    unreadCount: unreadCount,
                    lastMessageAt: conversation.lastMessageAt,
                    lastMessagePreview: conversation.lastMessagePreview,
                    subject: conversation.subject,
                    messages: conversation.messages,
                    reactionsByMessageID: conversation.reactionsByMessageID,
                    hasOutgoingActivity: conversation.hasOutgoingActivity
                )
            }
            .sorted { lhs, rhs in
                if lhs.lastMessageAt == rhs.lastMessageAt {
                    return lhs.id < rhs.id
                }
                return lhs.lastMessageAt > rhs.lastMessageAt
            }

        conversations = rebuilt.filter {
            (dismissedConversationMap[$0.id] ?? 0) < $0.lastMessageAt
        }
        activeConversations = conversations.filter { !$0.isRequest }
        requests = conversations.filter(\.isRequest)
        unreadMessageCount = conversations.reduce(0) { $0 + $1.unreadCount }
        unreadConversationCount = conversations.filter { $0.unreadCount > 0 }.count

        if persistSnapshot {
            persistSnapshotIfNeeded()
        }
    }

    private func resolveOwnInboxRelayURLs(for session: HaloLinkSession) async -> [URL] {
        if !session.inboxRelayURLs.isEmpty {
            inboxRelayCache[session.accountPubkey] = session.inboxRelayURLs
            return session.inboxRelayURLs
        }

        let lookupTargets = HaloLinkSupport.normalizedRelayURLs(
            session.readRelayURLs + session.writeRelayURLs + bootstrapLookupRelayURLs
        )
        let existing = await fetchInboxRelayURLs(
            for: session.accountPubkey,
            relayTargets: lookupTargets,
            useCache: false
        )

        if !existing.isEmpty {
            inboxRelayCache[session.accountPubkey] = existing
            return existing
        }

        guard let keypair = session.keypair else { return [] }

        let candidateRelayURLs = HaloLinkSupport.normalizedRelayURLs(
            Array(session.writeRelayURLs.prefix(HaloLinkSupport.maxPublishedInboxRelays))
        )
        guard !candidateRelayURLs.isEmpty else { return [] }

        let inboxRelayEvent = try? buildInboxRelayListEvent(
            relayURLs: candidateRelayURLs,
            keypair: keypair
        )
        guard let inboxRelayEvent,
              let eventData = try? JSONEncoder().encode(inboxRelayEvent) else {
            return []
        }

        let publishTargets = HaloLinkSupport.normalizedRelayURLs(
            session.writeRelayURLs + bootstrapLookupRelayURLs
        )
        let publishOutcome = await relayClient.publishEvent(
            to: publishTargets,
            eventData: eventData,
            eventID: inboxRelayEvent.id,
            successPolicy: .returnAfterFirstSuccess
        )

        guard publishOutcome.successfulSourceCount > 0 else {
            return []
        }

        inboxRelayCache[session.accountPubkey] = candidateRelayURLs
        return candidateRelayURLs
    }

    private func resolveRecipientRelayMap(
        recipientPubkeys: [String],
        session: HaloLinkSession
    ) async throws -> [String: [URL]] {
        let lookupTargets = lookupRelayTargets(for: session)
        var relayMap: [String: [URL]] = [:]

        let wrapRecipients = HaloLinkSupport.normalizedUniquePubkeys(
            [session.accountPubkey] + recipientPubkeys
        )

        for recipientPubkey in wrapRecipients {
            let relayURLs: [URL]
            if recipientPubkey == session.accountPubkey {
                let configuredInboxRelays = session.inboxRelayURLs.isEmpty
                    ? Array(session.writeRelayURLs.prefix(HaloLinkSupport.maxPublishedInboxRelays))
                    : session.inboxRelayURLs
                relayURLs = ownInboxRelayURLs.isEmpty ? configuredInboxRelays : ownInboxRelayURLs
            } else {
                relayURLs = await fetchInboxRelayURLs(
                    for: recipientPubkey,
                    relayTargets: lookupTargets
                )
            }

            guard !relayURLs.isEmpty else {
                throw HaloLinkError.missingRecipientInboxRelays
            }

            relayMap[recipientPubkey] = relayURLs
            inboxRelayCache[recipientPubkey] = relayURLs
        }

        return relayMap
    }

    private func lookupRelayTargets(for session: HaloLinkSession) -> [URL] {
        HaloLinkSupport.normalizedRelayURLs(
            ownInboxRelayURLs +
            session.inboxRelayURLs +
            session.readRelayURLs +
            session.writeRelayURLs +
            bootstrapLookupRelayURLs
        )
    }

    private func messageRelayTargets(for session: HaloLinkSession) -> [URL] {
        let inboxTargets = HaloLinkSupport.normalizedRelayURLs(
            ownInboxRelayURLs + session.inboxRelayURLs
        )
        if !inboxTargets.isEmpty {
            return inboxTargets
        }

        return HaloLinkSupport.normalizedRelayURLs(
            Array(session.writeRelayURLs.prefix(HaloLinkSupport.maxPublishedInboxRelays)) +
            Array(session.readRelayURLs.prefix(2))
        )
    }

    private func fetchInboxRelayURLs(
        for pubkey: String,
        relayTargets: [URL],
        useCache: Bool = true
    ) async -> [URL] {
        let normalizedPubkey = HaloLinkSupport.normalizePubkey(pubkey)
        let cachedRelayURLs = inboxRelayCache[normalizedPubkey] ?? []
        if useCache, !cachedRelayURLs.isEmpty {
            return cachedRelayURLs
        }

        let events = await relayLookupService.fetchEvents(
            relayURLs: relayTargets,
            filter: NostrFilter(
                authors: [normalizedPubkey],
                kinds: [HaloLinkSupport.inboxRelayKind],
                limit: 4
            ),
            timeout: 6
        )
        let sorted = events.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
        guard let latest = sorted.first else { return cachedRelayURLs }

        let relayURLs = latest.tags.compactMap { tag -> URL? in
            guard tag.first?.lowercased() == "relay",
                  let value = tag[safe: 1],
                  let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "ws" || scheme == "wss" else {
                return nil
            }
            return url
        }

        let normalized = HaloLinkSupport.normalizedRelayURLs(relayURLs)
        if !normalized.isEmpty {
            inboxRelayCache[normalizedPubkey] = normalized
        }
        return normalized.isEmpty ? cachedRelayURLs : normalized
    }

    private func buildInboxRelayListEvent(
        relayURLs: [URL],
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        let sdkTags = relayURLs.compactMap { decodeSDKTag(from: ["relay", $0.absoluteString]) }
        return try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(HaloLinkSupport.inboxRelayKind))
            .content("")
            .appendTags(contentsOf: sdkTags)
            .build(signedBy: keypair)
    }

    private func restoreSnapshot(for accountPubkey: String) -> Bool {
        guard let snapshot = stateStore.snapshot(for: accountPubkey) else {
            return false
        }

        profilesByPubkey = Dictionary(
            uniqueKeysWithValues: snapshot.profilesByPubkey.map { key, profile in
                (HaloLinkSupport.normalizePubkey(key), profile)
            }
        )

        let stableMessages = snapshot.messages.filter { !$0.isPendingDelivery }
        messagesByID = Dictionary(uniqueKeysWithValues: stableMessages.map { ($0.id, $0) })
        reactionsByID = Dictionary(uniqueKeysWithValues: snapshot.reactions.map { ($0.id, $0) })
        knownWrapIDs = Set(snapshot.knownWrapIDs.map { $0.lowercased() })
        ownInboxRelayURLs = snapshot.ownInboxRelayURLStrings.compactMap(URL.init(string:))
        inboxRelayCache = snapshot.inboxRelayCache.reduce(into: [:]) { partial, entry in
            partial[HaloLinkSupport.normalizePubkey(entry.key)] = entry.value.compactMap(URL.init(string:))
        }

        return !messagesByID.isEmpty || !reactionsByID.isEmpty
    }

    private func persistSnapshotIfNeeded() {
        guard let session else { return }

        let stableMessages = messagesByID.values
            .filter { !$0.isPendingDelivery }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.wrapID < rhs.wrapID
                }
                return lhs.createdAt < rhs.createdAt
            }

        let stableReactions = reactionsByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.wrapID < rhs.wrapID
            }
            return lhs.createdAt < rhs.createdAt
        }

        let snapshot = HaloLinkSnapshot(
            version: HaloLinkSnapshot.currentVersion,
            savedAt: Int(Date().timeIntervalSince1970),
            messages: stableMessages,
            reactions: stableReactions,
            profilesByPubkey: profilesByPubkey,
            knownWrapIDs: Array(knownWrapIDs).sorted(),
            ownInboxRelayURLStrings: ownInboxRelayURLs.map(\.absoluteString),
            inboxRelayCache: inboxRelayCache.mapValues { $0.map(\.absoluteString) }
        )
        stateStore.saveSnapshot(snapshot, for: session.accountPubkey)
    }

    private func latestKnownActivityTimestamp() -> Int? {
        let latestMessageTimestamp = messagesByID.values.map(\.createdAt).max()
        let latestReactionTimestamp = reactionsByID.values.map(\.createdAt).max()
        return [latestMessageTimestamp, latestReactionTimestamp].compactMap { $0 }.max()
    }

    private func syncRecentMessages(
        for session: HaloLinkSession,
        relayTargets: [URL],
        since: Int?
    ) async {
        guard let since else { return }

        let filter = NostrFilter(
            kinds: [HaloLinkSupport.giftWrapKind],
            limit: HaloLinkSupport.backfillPageLimit,
            since: since,
            tagFilters: ["p": [session.accountPubkey]]
        )
        let wrappedEvents = deduplicatedWrappedEvents(
            await relayLookupService.fetchEvents(
                relayURLs: relayTargets,
                filter: filter,
                timeout: HaloLinkSupport.initialQueryTimeout
            )
        )

        guard !wrappedEvents.isEmpty else { return }
        await applyWrappedEvents(wrappedEvents, session: session)
    }

    private func buildTextRumor(
        content: String,
        recipientPubkeys: [String],
        replyToMessageID: String?,
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        var rawTags = recipientPubkeys.map { ["p", $0] }
        if let replyToMessageID, !replyToMessageID.isEmpty {
            rawTags.append(["e", replyToMessageID, "", "reply"])
        }
        rawTags = FlowClientAttribution.appending(to: rawTags)

        let builder = DirectMessageEvent.Builder()
            .content(content)
            .appendTags(contentsOf: rawTags.compactMap(decodeSDKTag(from:)))

        return builder.build(pubkey: keypair.publicKey)
    }

    private func buildAttachmentRumor(
        attachment: HaloLinkPreparedComposerAttachment,
        recipientPubkeys: [String],
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        if let encryptedMetadata = attachment.upload.encryptedMetadata {
            return try buildEncryptedAttachmentRumor(
                remoteURL: attachment.upload.remoteURL,
                mimeType: attachment.upload.mimeType,
                encryptedMetadata: encryptedMetadata,
                recipientPubkeys: recipientPubkeys,
                keypair: keypair
            )
        }

        return try buildCompatibilityAttachmentRumor(
            remoteURL: attachment.upload.remoteURL,
            uploadMetadata: attachment.upload.uploadMetadata,
            mimeType: attachment.upload.mimeType,
            recipientPubkeys: recipientPubkeys,
            keypair: keypair
        )
    }

    private func buildEncryptedAttachmentRumor(
        remoteURL: URL,
        mimeType: String,
        encryptedMetadata: HaloLinkEncryptedAttachmentUploadMetadata,
        recipientPubkeys: [String],
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        var rawTags = recipientPubkeys.map { ["p", $0] }
        rawTags.append(contentsOf: [
            ["file-type", mimeType],
            ["encryption-algorithm", "aes-gcm"],
            ["decryption-key", encryptedMetadata.decryptionKeyBase64],
            ["decryption-nonce", encryptedMetadata.decryptionNonceBase64],
            ["x", encryptedMetadata.encryptedHash],
            ["ox", encryptedMetadata.originalHash],
            ["size", String(encryptedMetadata.encryptedSize)]
        ])
        rawTags = FlowClientAttribution.appending(to: rawTags)

        return NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(HaloLinkSupport.fileMessageKind))
            .content(remoteURL.absoluteString)
            .appendTags(contentsOf: rawTags.compactMap(decodeSDKTag(from:)))
            .build(pubkey: keypair.publicKey)
    }

    private func buildCompatibilityAttachmentRumor(
        remoteURL: URL,
        uploadMetadata: [String],
        mimeType: String,
        recipientPubkeys: [String],
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        var rawTags = recipientPubkeys.map { ["p", $0] }
        rawTags.append(["file-type", mimeType])
        if !uploadMetadata.isEmpty {
            rawTags.append(uploadMetadata)
        }
        rawTags = FlowClientAttribution.appending(to: rawTags)

        return NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(HaloLinkSupport.fileMessageKind))
            .content(remoteURL.absoluteString)
            .appendTags(contentsOf: rawTags.compactMap(decodeSDKTag(from:)))
            .build(pubkey: keypair.publicKey)
    }

    private func makeOptimisticAttachmentMessage(
        attachmentPayload: HaloLinkComposerAttachmentPayload,
        recipientPubkeys: [String],
        accountPubkey: String
    ) throws -> HaloLinkMessage {
        let localURL = try writeOptimisticAttachmentToTemporaryFile(attachmentPayload)
        let normalizedRecipients = HaloLinkSupport.normalizedUniquePubkeys(recipientPubkeys)
        let now = Int(Date().timeIntervalSince1970)
        let localID = "local-attachment-\(UUID().uuidString.lowercased())"

        return HaloLinkMessage(
            id: localID,
            wrapID: localID,
            createdAt: now,
            senderPubkey: accountPubkey,
            recipientPubkeys: normalizedRecipients,
            participantPubkeys: normalizedRecipients,
            conversationID: HaloLinkSupport.conversationID(for: normalizedRecipients),
            isOutgoing: true,
            kind: HaloLinkSupport.fileMessageKind,
            tags: [["file-type", attachmentPayload.mimeType]],
            content: localURL.absoluteString,
            subject: nil,
            replyToID: nil,
            isPendingDelivery: true
        )
    }

    private func writeOptimisticAttachmentToTemporaryFile(
        _ attachmentPayload: HaloLinkComposerAttachmentPayload
    ) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-link-local-\(UUID().uuidString).\(attachmentPayload.fileExtension)")
        try attachmentPayload.data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func deleteLocalOptimisticMediaIfNeeded(for message: HaloLinkMessage) {
        guard message.id.hasPrefix("local-attachment-"),
              let localURL = URL(string: message.content),
              localURL.isFileURL else {
            return
        }

        try? FileManager.default.removeItem(at: localURL)
    }

    private func buildReactionRumor(
        emoji: String,
        targetMessage: HaloLinkMessage,
        recipientPubkeys: [String],
        keypair: Keypair
    ) throws -> NostrSDK.NostrEvent {
        var rawTags = recipientPubkeys.map { ["p", $0] }
        rawTags.append(["e", targetMessage.id])
        rawTags.append(["k", String(targetMessage.kind)])
        rawTags = FlowClientAttribution.appending(to: rawTags)

        return NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .reaction)
            .content(emoji)
            .appendTags(contentsOf: rawTags.compactMap(decodeSDKTag(from:)))
            .build(pubkey: keypair.publicKey)
    }

    private func publishRumor(
        _ rumor: NostrSDK.NostrEvent,
        recipientPubkeys: [String],
        relayMap: [String: [URL]],
        session: HaloLinkSession
    ) async throws {
        guard let keypair = session.keypair else { throw HaloLinkError.invalidPrivateKey }

        for recipientPubkey in HaloLinkSupport.normalizedUniquePubkeys([session.accountPubkey] + recipientPubkeys) {
            guard let recipientKey = PublicKey(hex: recipientPubkey) else {
                throw HaloLinkError.invalidRecipient
            }
            guard let relayURLs = relayMap[recipientPubkey], !relayURLs.isEmpty else {
                throw HaloLinkError.missingRecipientInboxRelays
            }

            let wrappedEvent = try eventFactory.giftWrap(
                withRumor: rumor,
                toRecipient: recipientKey,
                signedBy: keypair
            )
            let eventData = try JSONEncoder().encode(wrappedEvent)
            let publishOutcome = await relayClient.publishEvent(
                to: relayURLs,
                eventData: eventData,
                eventID: wrappedEvent.id,
                successPolicy: .returnAfterFirstSuccess
            )

            guard publishOutcome.successfulSourceCount > 0 else {
                throw HaloLinkError.publishFailed(
                    publishOutcome.firstFailureMessage ?? "Halo Link couldn't publish right now."
                )
            }
        }
    }

    private func unwrapConversationEvent(
        wrappedEvent: NostrEvent,
        accountPubkey: String,
        keypair: Keypair?
    ) throws -> HaloLinkConversationEvent {
        guard let keypair else {
            throw HaloLinkError.invalidPrivateKey
        }
        let outerTags = wrappedEvent.tags
        guard wrappedEvent.kind == HaloLinkSupport.giftWrapKind,
              HaloLinkSupport.tagValues(named: "p", from: outerTags)
                .map(HaloLinkSupport.normalizePubkey)
                .contains(accountPubkey.lowercased()) else {
            throw HaloLinkError.malformedGiftWrap
        }

        let eventData = try JSONEncoder().encode(wrappedEvent)
        let giftWrap = try JSONDecoder().decode(GiftWrapEvent.self, from: eventData)
        try eventFactory.verifyEvent(giftWrap)
        let seal = try giftWrap.unwrappedSeal(using: keypair.privateKey)
        try eventFactory.verifyEvent(seal)
        let rumor = try seal.unsealedRumor(using: keypair.privateKey)

        guard seal.pubkey.lowercased() == rumor.pubkey.lowercased(),
              rumor.id.lowercased() == rumor.calculatedId.lowercased() else {
            throw HaloLinkError.malformedRumor
        }

        if rumor.kind.rawValue == HaloLinkSupport.directMessageKind || rumor.kind.rawValue == HaloLinkSupport.fileMessageKind {
            return .message(try messageModel(
                from: rumor,
                wrapID: wrappedEvent.id,
                accountPubkey: accountPubkey
            ))
        }

        if rumor.kind.rawValue == EventKind.reaction.rawValue {
            return .reaction(try reactionModel(
                from: rumor,
                wrapID: wrappedEvent.id,
                accountPubkey: accountPubkey
            ))
        }

        throw HaloLinkError.malformedRumor
    }

    private func messageModel(
        from rumor: NostrSDK.NostrEvent,
        wrapID: String,
        accountPubkey: String
    ) throws -> HaloLinkMessage {
        let tags = rawTagArrays(from: rumor.tags)
        let recipientPubkeys = HaloLinkSupport.normalizedUniquePubkeys(
            HaloLinkSupport.tagValues(named: "p", from: tags)
        )
        let isOutgoing = rumor.pubkey.lowercased() == accountPubkey.lowercased()

        guard isOutgoing || recipientPubkeys.contains(accountPubkey.lowercased()) else {
            throw HaloLinkError.decryptionFailed
        }

        let participantPubkeys = HaloLinkSupport.normalizedUniquePubkeys(
            (isOutgoing ? recipientPubkeys : [rumor.pubkey] + recipientPubkeys)
                .filter { HaloLinkSupport.normalizePubkey($0) != accountPubkey.lowercased() }
        )
        let replyToID = tags.last(where: {
            $0.first?.lowercased() == "e" && ($0[safe: 3]?.lowercased() == "reply")
        })?[safe: 1] ?? HaloLinkSupport.firstTagValue(named: "e", from: tags)

        return HaloLinkMessage(
            id: rumor.id.lowercased(),
            wrapID: wrapID.lowercased(),
            createdAt: Int(rumor.createdAt),
            senderPubkey: rumor.pubkey.lowercased(),
            recipientPubkeys: recipientPubkeys,
            participantPubkeys: participantPubkeys,
            conversationID: HaloLinkSupport.conversationID(for: participantPubkeys),
            isOutgoing: isOutgoing,
            kind: rumor.kind.rawValue,
            tags: tags,
            content: rumor.content,
            subject: HaloLinkSupport.firstTagValue(named: "subject", from: tags),
            replyToID: replyToID,
            isPendingDelivery: false
        )
    }

    private func reactionModel(
        from rumor: NostrSDK.NostrEvent,
        wrapID: String,
        accountPubkey: String
    ) throws -> HaloLinkMessageReaction {
        let tags = rawTagArrays(from: rumor.tags)
        let recipientPubkeys = HaloLinkSupport.normalizedUniquePubkeys(
            HaloLinkSupport.tagValues(named: "p", from: tags)
        )
        let participantPubkeys = HaloLinkSupport.normalizedUniquePubkeys(
            ([rumor.pubkey] + recipientPubkeys)
                .filter { HaloLinkSupport.normalizePubkey($0) != accountPubkey.lowercased() }
        )
        guard let targetMessageID = HaloLinkSupport.firstTagValue(named: "e", from: tags) else {
            throw HaloLinkError.malformedRumor
        }

        return HaloLinkMessageReaction(
            id: rumor.id.lowercased(),
            wrapID: wrapID.lowercased(),
            createdAt: Int(rumor.createdAt),
            senderPubkey: rumor.pubkey.lowercased(),
            recipientPubkeys: recipientPubkeys,
            participantPubkeys: participantPubkeys,
            conversationID: HaloLinkSupport.conversationID(for: participantPubkeys),
            isOutgoing: rumor.pubkey.lowercased() == accountPubkey.lowercased(),
            targetMessageID: targetMessageID.lowercased(),
            emoji: rumor.content
        )
    }

    private func upsert(message: HaloLinkMessage) {
        messagesByID[message.id] = message
    }

    private func upsert(reaction: HaloLinkMessageReaction) {
        reactionsByID[reaction.id] = reaction
    }

    private func conversation(for conversationID: String) -> HaloLinkConversation? {
        conversations.first { $0.id == conversationID }
    }

    private func deduplicatedWrappedEvents(_ events: [NostrEvent]) -> [NostrEvent] {
        var uniqueByID: [String: NostrEvent] = [:]
        for event in events {
            let key = event.id.lowercased()
            if let current = uniqueByID[key] {
                if event.createdAt > current.createdAt ||
                    (event.createdAt == current.createdAt && event.id > current.id) {
                    uniqueByID[key] = event
                }
            } else {
                uniqueByID[key] = event
            }
        }

        return uniqueByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func encryptAttachmentPayload(
        _ payload: HaloLinkComposerAttachmentPayload
    ) throws -> HaloLinkEncryptedFilePayload {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(
            payload.data,
            using: key,
            nonce: nonce
        )
        let encryptedData = sealedBox.ciphertext + sealedBox.tag

        return HaloLinkEncryptedFilePayload(
            encryptedData: encryptedData,
            originalMimeType: payload.mimeType,
            fileExtension: payload.fileExtension,
            encryptedHash: SHA256.hash(data: encryptedData).hexString,
            originalHash: SHA256.hash(data: payload.data).hexString,
            decryptionKeyBase64: key.withUnsafeBytes { Data($0) }.base64EncodedString(),
            decryptionNonceBase64: Data(nonce).base64EncodedString()
        )
    }

    private func rawTagArrays(from tags: [Tag]) -> [[String]] {
        tags.map { [$0.name, $0.value] + $0.otherParameters }
    }

    private func decodeSDKTag(from raw: [String]) -> Tag? {
        guard raw.count >= 2,
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(Tag.self, from: data) else {
            return nil
        }
        return tag
    }
}

private enum HaloLinkConversationEvent {
    case message(HaloLinkMessage)
    case reaction(HaloLinkMessageReaction)
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
