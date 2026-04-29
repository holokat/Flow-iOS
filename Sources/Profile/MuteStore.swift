import Foundation
import NostrSDK

struct MuteFilterSnapshot: Sendable, Equatable {
    let mutedPubkeys: Set<String>
    let exactMutedWords: Set<String>
    let phraseMutedWords: [String]
    var hidesEncodedSpam = true

    var hasAnyRules: Bool {
        hidesEncodedSpam || hasUserRules
    }

    var hasUserRules: Bool {
        !mutedPubkeys.isEmpty || !exactMutedWords.isEmpty || !phraseMutedWords.isEmpty
    }

    func shouldHide(_ event: NostrEvent) -> Bool {
        if mutedPubkeys.contains(normalizePubkey(event.pubkey)) {
            return true
        }

        if hidesEncodedSpam && EncodedSpamContentHeuristic.shouldHide(event.content) {
            return true
        }

        return containsMutedWord(in: event)
    }

    func shouldHideAny(in events: [NostrEvent]) -> Bool {
        for event in events where shouldHide(event) {
            return true
        }
        return false
    }

    private func containsMutedWord(in event: NostrEvent) -> Bool {
        guard !exactMutedWords.isEmpty || !phraseMutedWords.isEmpty else {
            return false
        }

        let tagContent = event.tags
            .flatMap { tag -> [String] in
                guard let name = tag.first?.lowercased(), tag.count > 1 else {
                    return []
                }

                let value = tag[1]

                switch name {
                case "t":
                    let normalized = normalizedMutedWord(value) ?? value
                    return [normalized, "#\(normalized)"]
                case "subject", "title", "summary":
                    return [value]
                default:
                    return []
                }
            }
            .joined(separator: " ")

        let combinedContent: String
        if tagContent.isEmpty {
            combinedContent = event.content
        } else if event.content.isEmpty {
            combinedContent = tagContent
        } else {
            combinedContent = "\(event.content) \(tagContent)"
        }

        return containsMutedWord(inNormalizedText: normalizedMutedWord(combinedContent))
    }

    private func containsMutedWord(inNormalizedText normalizedText: String?) -> Bool {
        guard let normalizedText, !normalizedText.isEmpty else {
            return false
        }

        if !exactMutedWords.isEmpty {
            let tokens = Set(
                normalizedText.split(whereSeparator: { !isMutedWordTokenCharacter($0) })
                    .map(String.init)
            )

            if !tokens.isDisjoint(with: exactMutedWords) {
                return true
            }
        }

        for phrase in phraseMutedWords where normalizedText.contains(phrase) {
            return true
        }

        return false
    }

    private func normalizePubkey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedMutedWord(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isMutedWordTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

@MainActor
final class MutedThreadStore: ObservableObject {
    static let shared = MutedThreadStore()

    @Published private(set) var mutedThreadIDs: Set<String> = []
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let storageKeyPrefix = "flow.mutedThreads.v1"
    private var currentAccountPubkey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountPubkey: String?) {
        let normalizedAccountPubkey = normalizedIdentifier(accountPubkey)
        guard normalizedAccountPubkey != currentAccountPubkey else { return }

        currentAccountPubkey = normalizedAccountPubkey
        mutedThreadIDs = loadMutedThreadIDs(accountPubkey: normalizedAccountPubkey)
        revision &+= 1
    }

    func mute(_ threadID: String) -> Bool {
        guard let normalizedThreadID = normalizedIdentifier(threadID) else {
            return false
        }

        let inserted = mutedThreadIDs.insert(normalizedThreadID).inserted
        guard inserted else { return false }

        persistMutedThreadIDs()
        revision &+= 1
        return true
    }

    func isMuted(_ threadID: String?) -> Bool {
        guard let normalizedThreadID = normalizedIdentifier(threadID) else {
            return false
        }

        return mutedThreadIDs.contains(normalizedThreadID)
    }

    private func loadMutedThreadIDs(accountPubkey: String?) -> Set<String> {
        let storedIDs = defaults.stringArray(forKey: storageKey(for: accountPubkey)) ?? []
        return Set(storedIDs.compactMap(normalizedIdentifier))
    }

    private func persistMutedThreadIDs() {
        defaults.set(Array(mutedThreadIDs).sorted(), forKey: storageKey(for: currentAccountPubkey))
    }

    private func storageKey(for accountPubkey: String?) -> String {
        "\(storageKeyPrefix).\(accountPubkey ?? "anonymous")"
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }

        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalized.isEmpty ? nil : normalized
    }
}

private enum EncodedSpamContentHeuristic {
    private static let minimumContentLength = 320
    private static let minimumTokenLength = 240
    private static let minimumCompactLength = 420
    private static let maximumWhitespaceRatio = 0.035
    private static let minimumBase64AlphabetRatio = 0.94
    private static let minimumUniqueCharacterCount = 22
    private static let minimumUniqueCharacterRatio = 0.035
    private static let maximumUniqueCharacterRatio = 0.42

    static func shouldHide(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars)
        guard scalars.count >= minimumContentLength else {
            return false
        }

        var whitespaceCount = 0
        var currentRunLength = 0
        var longestNonWhitespaceRun = 0
        var compactScalars: [Unicode.Scalar] = []
        compactScalars.reserveCapacity(scalars.count)

        for scalar in scalars {
            if isWhitespace(scalar) {
                whitespaceCount += 1
                longestNonWhitespaceRun = max(longestNonWhitespaceRun, currentRunLength)
                currentRunLength = 0
            } else {
                compactScalars.append(scalar)
                currentRunLength += 1
            }
        }
        longestNonWhitespaceRun = max(longestNonWhitespaceRun, currentRunLength)

        for token in trimmed.split(whereSeparator: { character in
            character.unicodeScalars.allSatisfy(isWhitespace)
        }) {
            if looksLikeEncodedRun(Array(token.unicodeScalars), minimumLength: minimumTokenLength) {
                return true
            }
        }

        let whitespaceRatio = Double(whitespaceCount) / Double(max(scalars.count, 1))
        let lacksNaturalSpacing = whitespaceRatio <= maximumWhitespaceRatio ||
            longestNonWhitespaceRun >= max(minimumTokenLength, Int(Double(compactScalars.count) * 0.82))

        guard lacksNaturalSpacing else {
            return false
        }

        return looksLikeEncodedRun(compactScalars, minimumLength: minimumCompactLength)
    }

    private static func looksLikeEncodedRun(_ scalars: [Unicode.Scalar], minimumLength: Int) -> Bool {
        guard scalars.count >= minimumLength else {
            return false
        }

        var base64AlphabetCount = 0
        var uniqueScalars = Set<Unicode.Scalar>()
        var hasUppercase = false
        var hasLowercase = false
        var hasDigit = false

        for scalar in scalars {
            guard isBase64Alphabet(scalar) else {
                continue
            }

            base64AlphabetCount += 1
            uniqueScalars.insert(scalar)

            if scalar.value >= 65 && scalar.value <= 90 {
                hasUppercase = true
            } else if scalar.value >= 97 && scalar.value <= 122 {
                hasLowercase = true
            } else if scalar.value >= 48 && scalar.value <= 57 {
                hasDigit = true
            }
        }

        let base64AlphabetRatio = Double(base64AlphabetCount) / Double(scalars.count)
        let uniqueCharacterRatio = Double(uniqueScalars.count) / Double(max(base64AlphabetCount, 1))
        let categoryCount = [hasUppercase, hasLowercase, hasDigit].filter(\.self).count

        return base64AlphabetRatio >= minimumBase64AlphabetRatio &&
            uniqueScalars.count >= minimumUniqueCharacterCount &&
            uniqueCharacterRatio >= minimumUniqueCharacterRatio &&
            uniqueCharacterRatio <= maximumUniqueCharacterRatio &&
            categoryCount >= 2
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isBase64Alphabet(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value >= 65 && scalar.value <= 90 {
            return true
        }
        if scalar.value >= 97 && scalar.value <= 122 {
            return true
        }
        if scalar.value >= 48 && scalar.value <= 57 {
            return true
        }
        return scalar == "+" || scalar == "/" || scalar == "=" || scalar == "-" || scalar == "_"
    }
}

struct MutedKeywordListState: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let words: [String]
    let allowsToggle: Bool
    let allowsAddingWords: Bool

    var wordCount: Int {
        words.count
    }
}

@MainActor
final class MuteStore: ObservableObject, NIP44v2Encrypting {
    static let shared = MuteStore()
    private static let muteDecisionCacheLimit = 4000
    private static let normalizedEventTextCacheLimit = 4000

    @Published private(set) var mutedPubkeys: Set<String>
    @Published private(set) var activeMutedWords: [String]
    @Published private(set) var mutedKeywordLists: [MutedKeywordListState]
    @Published private(set) var filterRevision = 0
    @Published private(set) var lastPublishError: String?
    @Published private(set) var isPublishing = false

    private let defaults: UserDefaults
    private let feedService: ProfileEventService
    private let relayClient: NostrRelayClient
    private let keyPrefix = "flow.mutedPubkeys"
    private let legacyKeyPrefix = "x21.mutedPubkeys"

    private struct Session: Equatable {
        let accountPubkey: String
        let nsec: String?
        let readRelayURLs: [URL]
        let writeRelayURLs: [URL]
    }

    private struct KeywordListPreset: Sendable {
        let id: String
        let title: String
        let subtitle: String
        let defaultWords: [String]
    }

    private struct DecodedMuteState {
        let publicTags: [NostrSDK.Tag]
        let privateTags: [NostrSDK.Tag]
        let mutedPubkeys: Set<String>
        let activeMutedWords: [String]
        let mutedKeywordLists: [MutedKeywordListState]
    }

    private static let keywordListTagName = "x21-word-list"
    private static let keywordRemovalTagName = "x21-word-remove"
    private static let keywordAdditionTagName = "x21-word-add"
    private static let keywordConfirmationTagName = "x21-word-confirmed"
    private static let otherKeywordListID = "other"
    private static let retiredKeywordListDefaultWordsByID: [String: Set<String>] = [
        "bitcoin": [
            "bitcoin",
            "btc",
            "xbt",
            "bitcoiner",
            "bitcoiners",
            "sats",
            "satoshi",
            "lightning",
            "lightning network",
            "lnurl",
            "zaps",
            "nostr zap",
            "ordinal",
            "ordinals",
            "rune",
            "runes",
            "brc20",
            "halving",
            "mining",
            "miners",
            "hashrate",
            "mempool",
            "utxo",
            "stack sats",
            "stacking sats"
        ]
    ]

    private static let keywordListPresets: [KeywordListPreset] = [
        KeywordListPreset(
            id: "crypto",
            title: "Crypto",
            subtitle: "Altcoins, airdrops, NFTs, token chatter",
            defaultWords: [
                "crypto",
                "cryptocurrency",
                "altcoin",
                "altcoins",
                "token",
                "tokens",
                "shitcoin",
                "shitcoins",
                "memecoin",
                "memecoins",
                "airdrop",
                "airdrops",
                "presale",
                "presales",
                "pump.fun",
                "rug pull",
                "rugpull",
                "pump and dump",
                "web3",
                "defi",
                "yield farm",
                "yield farming",
                "nft",
                "nfts",
                "ethereum",
                "solana",
                "erc20",
                "contract address",
                "ca:"
            ]
        ),
        KeywordListPreset(
            id: "ai-bots-spam",
            title: "AI, Bots & Spam",
            subtitle: "Bot markers and repeated spam patterns",
            defaultWords: [
                "theboard",
                "zone_presence"
            ]
        )
    ]

    private var session: Session?
    private var syncTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var latestMuteListSnapshot: MuteListSnapshot?
    private var latestPrivateTags: [NostrSDK.Tag] = []
    private var exactMutedWords = Set<String>()
    private var phraseMutedWords: [String] = []
    private var muteDecisionCache: [String: Bool] = [:]
    private var normalizedEventTextCache: [String: String] = [:]
    init(
        defaults: UserDefaults = .standard,
        feedService: ProfileEventService = ProfileEventService(),
        relayClient: NostrRelayClient = NostrRelayClient()
    ) {
        self.defaults = defaults
        self.feedService = feedService
        self.relayClient = relayClient
        self.mutedPubkeys = []
        self.activeMutedWords = []
        self.mutedKeywordLists = Self.defaultMutedKeywordLists()
    }

    deinit {
        syncTask?.cancel()
        publishTask?.cancel()
    }

    func configure(accountPubkey: String?, nsec: String?, relayURL: URL) {
        let sharedReadRelays = RelaySettingsStore.shared.readRelayURLs
        let sharedWriteRelays = RelaySettingsStore.shared.writeRelayURLs
        let fallbackTargets = [relayURL]

        configure(
            accountPubkey: accountPubkey,
            nsec: nsec,
            readRelayURLs: sharedReadRelays.isEmpty ? fallbackTargets : sharedReadRelays,
            writeRelayURLs: sharedWriteRelays.isEmpty ? fallbackTargets : sharedWriteRelays
        )
    }

    func configure(accountPubkey: String?, nsec: String?, readRelayURLs: [URL], writeRelayURLs: [URL]) {
        let normalizedAccount = normalizePubkey(accountPubkey)
        let normalizedNsec = normalizeNsec(nsec)
        let normalizedReadRelays = normalizedRelayURLs(readRelayURLs)
        let normalizedWriteRelays = normalizedRelayURLs(writeRelayURLs)

        let effectiveReadRelays = normalizedReadRelays.isEmpty ? normalizedWriteRelays : normalizedReadRelays
        let effectiveWriteRelays = normalizedWriteRelays.isEmpty ? effectiveReadRelays : normalizedWriteRelays

        let nextSession: Session?
        if normalizedAccount.isEmpty || effectiveReadRelays.isEmpty || effectiveWriteRelays.isEmpty {
            nextSession = nil
        } else {
            nextSession = Session(
                accountPubkey: normalizedAccount,
                nsec: normalizedNsec,
                readRelayURLs: effectiveReadRelays,
                writeRelayURLs: effectiveWriteRelays
            )
        }

        guard nextSession != session else { return }

        session = nextSession
        latestMuteListSnapshot = nil
        latestPrivateTags = []
        clearMuteCaches()
        clearDerivedEventCaches()
        lastPublishError = nil
        isPublishing = false

        syncTask?.cancel()
        publishTask?.cancel()

        guard let session = nextSession else {
            mutedPubkeys = []
            activeMutedWords = []
            mutedKeywordLists = Self.defaultMutedKeywordLists()
            rebuildMutedWordMatchers()
            return
        }

        mutedPubkeys = loadPersistedMutes(for: session.accountPubkey)
        activeMutedWords = []
        mutedKeywordLists = Self.defaultMutedKeywordLists()
        rebuildMutedWordMatchers()

        syncTask = Task(priority: .utility) { [weak self] in
            await self?.syncFromRelay(for: session)
        }
    }

    func isMuted(_ pubkey: String) -> Bool {
        mutedPubkeys.contains(normalizePubkey(pubkey))
    }

    func shouldHide(_ event: NostrEvent) -> Bool {
        if isMuted(event.pubkey) {
            return true
        }

        if let cached = muteDecisionCache[event.id] {
            return cached
        }

        let decision = EncodedSpamContentHeuristic.shouldHide(event.content) || containsMutedWord(in: event)
        if muteDecisionCache.count >= Self.muteDecisionCacheLimit {
            muteDecisionCache.removeAll(keepingCapacity: true)
        }
        muteDecisionCache[event.id] = decision
        return decision
    }

    func containsMutedWord(in content: String) -> Bool {
        guard !activeMutedWords.isEmpty else {
            return false
        }

        return containsMutedWord(inNormalizedText: normalizedMutedWord(content))
    }

    func shouldHideAny(_ events: [NostrEvent]) -> Bool {
        for event in events where shouldHide(event) {
            return true
        }
        return false
    }

    var filterSnapshot: MuteFilterSnapshot {
        MuteFilterSnapshot(
            mutedPubkeys: mutedPubkeys,
            exactMutedWords: exactMutedWords,
            phraseMutedWords: phraseMutedWords
        )
    }

    func toggleMute(_ pubkey: String) {
        guard let session else { return }
        guard session.nsec != nil else {
            lastPublishError = "Sign in with a private key to manage mutes."
            return
        }

        let normalizedTarget = normalizePubkey(pubkey)
        guard !normalizedTarget.isEmpty, normalizedTarget != session.accountPubkey else { return }

        let shouldMute = !mutedPubkeys.contains(normalizedTarget)
        let previousPubkeys = mutedPubkeys

        if shouldMute {
            mutedPubkeys.insert(normalizedTarget)
        } else {
            mutedPubkeys.remove(normalizedTarget)
        }
        invalidateFilterCaches()
        persistCurrentMutes()
        lastPublishError = nil
        isPublishing = true

        publishTask?.cancel()
        publishTask = Task { [weak self] in
            await self?.publishMuteState(
                for: session,
                rollback: {
                    self?.mutedPubkeys = previousPubkeys
                    self?.invalidateFilterCaches()
                    self?.persistCurrentMutes()
                },
                mutate: { state in
                    let nextPrivateTags = self?.updatedPrivatePubkeyTags(
                        from: state.privateTags,
                        targetPubkey: normalizedTarget,
                        shouldMute: shouldMute
                    ) ?? state.privateTags
                    return (
                        publicTags: self?.updatedPublicTags(from: state.publicTags, targetPubkey: normalizedTarget) ?? state.publicTags,
                        privateTags: nextPrivateTags
                    )
                }
            )
        }
    }

    func setKeywordListEnabled(_ listID: String, isEnabled: Bool) {
        guard let session else { return }
        guard session.nsec != nil else {
            lastPublishError = "Sign in with a private key to manage muted keywords."
            return
        }
        guard listID != Self.otherKeywordListID else { return }

        let previousPrivateTags = latestPrivateTags
        let previousMutedWords = activeMutedWords
        let previousKeywordLists = mutedKeywordLists

        let localPrivateTags = rebuildWordTags(
            in: markingKeywordConfigurationConfirmed(
                in: replacingKeywordListEnabledTag(
                    in: latestPrivateTags,
                    listID: listID,
                    isEnabled: isEnabled
                )
            )
        )
        applyPrivateTagsLocally(localPrivateTags)

        lastPublishError = nil
        isPublishing = true

        publishTask?.cancel()
        publishTask = Task { [weak self] in
            await self?.publishMuteState(
                for: session,
                rollback: {
                    self?.latestPrivateTags = previousPrivateTags
                    self?.activeMutedWords = previousMutedWords
                    self?.mutedKeywordLists = previousKeywordLists
                    self?.rebuildMutedWordMatchers()
                },
                mutate: { state in
                    let updated = self?.rebuildWordTags(
                        in: self?.markingKeywordConfigurationConfirmed(
                            in: self?.replacingKeywordListEnabledTag(
                                in: state.privateTags,
                                listID: listID,
                                isEnabled: isEnabled
                            ) ?? state.privateTags
                        ) ?? state.privateTags
                    ) ?? state.privateTags
                    return (publicTags: state.publicTags, privateTags: updated)
                }
            )
        }
    }

    func addWord(_ word: String, to listID: String) {
        guard let session else { return }
        guard session.nsec != nil else {
            lastPublishError = "Sign in with a private key to manage muted keywords."
            return
        }
        guard let normalizedWord = normalizedMutedWord(word), !normalizedWord.isEmpty else { return }

        let previousPrivateTags = latestPrivateTags
        let previousMutedWords = activeMutedWords
        let previousKeywordLists = mutedKeywordLists

        let localPrivateTags: [NostrSDK.Tag]
        if listID == Self.otherKeywordListID {
            localPrivateTags = upsertingPrivateWordTag(normalizedWord, in: latestPrivateTags)
        } else {
            localPrivateTags = rebuildWordTags(
                in: markingKeywordConfigurationConfirmed(
                    in: upsertingAddedWord(
                        normalizedWord,
                        in: removingKeywordRemovalTag(
                            normalizedWord,
                            from: latestPrivateTags,
                            listID: listID
                        ),
                        listID: listID
                    )
                )
            )
        }
        applyPrivateTagsLocally(localPrivateTags)

        lastPublishError = nil
        isPublishing = true

        publishTask?.cancel()
        publishTask = Task { [weak self] in
            await self?.publishMuteState(
                for: session,
                rollback: {
                    self?.latestPrivateTags = previousPrivateTags
                    self?.activeMutedWords = previousMutedWords
                    self?.mutedKeywordLists = previousKeywordLists
                    self?.rebuildMutedWordMatchers()
                },
                mutate: { state in
                    let updated: [NostrSDK.Tag]
                    if listID == Self.otherKeywordListID {
                        updated = self?.upsertingPrivateWordTag(normalizedWord, in: state.privateTags) ?? state.privateTags
                    } else {
                        updated = self?.rebuildWordTags(
                            in: self?.markingKeywordConfigurationConfirmed(
                                in: self?.upsertingAddedWord(
                                    normalizedWord,
                                    in: self?.removingKeywordRemovalTag(
                                        normalizedWord,
                                        from: state.privateTags,
                                        listID: listID
                                    ) ?? state.privateTags,
                                    listID: listID
                                ) ?? state.privateTags
                            ) ?? state.privateTags
                        ) ?? state.privateTags
                    }
                    return (publicTags: state.publicTags, privateTags: updated)
                }
            )
        }
    }

    func removeWord(_ word: String, from listID: String) {
        guard let session else { return }
        guard session.nsec != nil else {
            lastPublishError = "Sign in with a private key to manage muted keywords."
            return
        }
        guard let normalizedWord = normalizedMutedWord(word), !normalizedWord.isEmpty else { return }

        let previousPrivateTags = latestPrivateTags
        let previousMutedWords = activeMutedWords
        let previousKeywordLists = mutedKeywordLists

        let localPrivateTags: [NostrSDK.Tag]
        if listID == Self.otherKeywordListID {
            localPrivateTags = removingPrivateWordTag(normalizedWord, from: latestPrivateTags)
        } else {
            localPrivateTags = rebuildWordTags(
                in: markingKeywordConfigurationConfirmed(
                    in: tagExists(
                        name: Self.keywordAdditionTagName,
                        value: listID,
                        firstOtherParameter: normalizedWord,
                        in: latestPrivateTags
                    )
                        ? removingKeywordAdditionTag(normalizedWord, from: latestPrivateTags, listID: listID)
                        : upsertingRemovedWord(normalizedWord, in: latestPrivateTags, listID: listID)
                )
            )
        }
        applyPrivateTagsLocally(localPrivateTags)

        lastPublishError = nil
        isPublishing = true

        publishTask?.cancel()
        publishTask = Task { [weak self] in
            await self?.publishMuteState(
                for: session,
                rollback: {
                    self?.latestPrivateTags = previousPrivateTags
                    self?.activeMutedWords = previousMutedWords
                    self?.mutedKeywordLists = previousKeywordLists
                    self?.rebuildMutedWordMatchers()
                },
                mutate: { state in
                    let updated: [NostrSDK.Tag]
                    if listID == Self.otherKeywordListID {
                        updated = self?.removingPrivateWordTag(normalizedWord, from: state.privateTags) ?? state.privateTags
                    } else if self?.tagExists(
                        name: Self.keywordAdditionTagName,
                        value: listID,
                        firstOtherParameter: normalizedWord,
                        in: state.privateTags
                    ) == true {
                        updated = self?.rebuildWordTags(
                            in: self?.markingKeywordConfigurationConfirmed(
                                in: self?.removingKeywordAdditionTag(normalizedWord, from: state.privateTags, listID: listID) ?? state.privateTags
                            ) ?? state.privateTags
                        ) ?? state.privateTags
                    } else {
                        updated = self?.rebuildWordTags(
                            in: self?.markingKeywordConfigurationConfirmed(
                                in: self?.upsertingRemovedWord(normalizedWord, in: state.privateTags, listID: listID) ?? state.privateTags
                            ) ?? state.privateTags
                        ) ?? state.privateTags
                    }
                    return (publicTags: state.publicTags, privateTags: updated)
                }
            )
        }
    }

    func refreshFromRelay() {
        guard let session else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.syncFromRelay(for: session)
        }
    }

    private func syncFromRelay(for session: Session) async {
        do {
            let snapshot = try await fetchMuteListSnapshot(
                relayURLs: session.readRelayURLs,
                pubkey: session.accountPubkey
            )

            guard !Task.isCancelled else { return }
            guard self.session == session else { return }

            latestMuteListSnapshot = snapshot
            let state = try decodedMuteState(from: snapshot, nsec: session.nsec)
            applyDecodedState(state)
        } catch {
            // Keep the locally persisted cache when relay sync fails.
        }
    }

    private func publishMuteState(
        for session: Session,
        rollback: @escaping @MainActor () -> Void,
        mutate: @escaping (DecodedMuteState) -> (publicTags: [NostrSDK.Tag], privateTags: [NostrSDK.Tag])
    ) async {
        defer {
            if self.session == session {
                isPublishing = false
            }
        }

        guard let nsec = session.nsec else { return }
        guard let keypair = Keypair(nsec: nsec.lowercased()) else {
            guard self.session == session else { return }
            rollback()
            lastPublishError = "Couldn't sign mute update. Please sign in again."
            return
        }

        do {
            let snapshot = try await fetchMuteListSnapshot(
                relayURLs: session.readRelayURLs,
                pubkey: session.accountPubkey
            )
            guard !Task.isCancelled else { return }

            let baseSnapshot = snapshot ?? latestMuteListSnapshot
            let decodedState = try decodedMuteState(from: baseSnapshot, nsec: session.nsec)
            let nextState = mutate(decodedState)
            let publishedSnapshot = try await publishMuteListSnapshot(
                publicTags: nextState.publicTags,
                privateTags: nextState.privateTags,
                session: session,
                keypair: keypair
            )

            guard !Task.isCancelled else { return }
            guard self.session == session else { return }

            latestMuteListSnapshot = publishedSnapshot
            applyDecodedState(try decodedMuteState(from: publishedSnapshot, nsec: session.nsec))
            lastPublishError = nil
        } catch {
            guard !Task.isCancelled else { return }
            guard self.session == session else { return }

            rollback()
            lastPublishError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func publishMuteListSnapshot(
        publicTags: [NostrSDK.Tag],
        privateTags: [NostrSDK.Tag],
        session: Session,
        keypair: Keypair
    ) async throws -> MuteListSnapshot {
        let encryptedContent: String
        if privateTags.isEmpty {
            encryptedContent = ""
        } else {
            let rawTags = privateTags.map(encodeRawTag(_:))
            let data = try JSONSerialization.data(withJSONObject: rawTags, options: [.sortedKeys])
            guard let plaintext = String(data: data, encoding: .utf8) else {
                throw RelayClientError.publishRejected("Malformed mute list")
            }
            encryptedContent = try encrypt(
                plaintext: plaintext,
                privateKeyA: keypair.privateKey,
                publicKeyB: keypair.publicKey
            )
        }

        let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .muteList)
            .content(encryptedContent)
            .appendTags(contentsOf: publicTags)
            .build(signedBy: keypair)

        let eventData = try JSONEncoder().encode(event)
        guard let eventObject = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            throw RelayClientError.publishRejected("Malformed mute event")
        }

        var successfulPublishes = 0
        var firstPublishError: Error?

        for relayURL in session.writeRelayURLs {
            do {
                try await relayClient.publishEvent(
                    relayURL: relayURL,
                    eventObject: eventObject,
                    eventID: event.id
                )
                successfulPublishes += 1
            } catch {
                if firstPublishError == nil {
                    firstPublishError = error
                }
            }
        }

        if successfulPublishes == 0 {
            throw firstPublishError ?? RelayClientError.publishRejected("Couldn't publish mute event")
        }

        return MuteListSnapshot(content: encryptedContent, tags: publicTags.map(encodeRawTag(_:)))
    }

    private func fetchMuteListSnapshot(relayURLs: [URL], pubkey: String) async throws -> MuteListSnapshot? {
        let targets = normalizedRelayURLs(relayURLs)
        guard !targets.isEmpty else { return nil }

        if targets.count == 1, let onlyRelay = targets.first {
            return try await feedService.fetchMuteListSnapshot(relayURL: onlyRelay, pubkey: pubkey)
        }

        let filter = NostrFilter(
            authors: [pubkey],
            kinds: [10000],
            limit: 20
        )

        var mergedEvents: [NostrEvent] = []
        var firstError: Error?
        var successfulFetches = 0

        for relayURL in targets {
            do {
                let events = try await relayClient.fetchEvents(
                    relayURL: relayURL,
                    filter: filter,
                    timeout: 10
                )
                successfulFetches += 1
                mergedEvents.append(contentsOf: events)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if successfulFetches == 0, let firstError {
            throw firstError
        }

        guard let newest = mergedEvents
            .filter({ $0.kind == 10000 })
            .sorted(by: { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            })
            .first else {
            return nil
        }

        return MuteListSnapshot(content: newest.content, tags: newest.tags)
    }

    private func decodedMuteState(from snapshot: MuteListSnapshot?, nsec: String?) throws -> DecodedMuteState {
        let publicTags = snapshot?.tags.compactMap(decodeSDKTag(from:)) ?? []
        let privateTags = try decodedPrivateTags(from: snapshot, nsec: nsec)
        let mutedPubkeys = Set(snapshot?.publicMutedPubkeys ?? [])
            .union(privateTags.compactMap { tag in
                guard tag.name.lowercased() == "p" else { return nil }
                let normalized = normalizePubkey(tag.value)
                return normalized.isEmpty ? nil : normalized
            })

        let activeMutedWords = activeMutedWords(from: privateTags)
        let keywordLists = keywordLists(from: privateTags)

        return DecodedMuteState(
            publicTags: publicTags,
            privateTags: privateTags,
            mutedPubkeys: mutedPubkeys,
            activeMutedWords: activeMutedWords,
            mutedKeywordLists: keywordLists
        )
    }

    private func decodedPrivateTags(from snapshot: MuteListSnapshot?, nsec: String?) throws -> [NostrSDK.Tag] {
        guard let snapshot else { return [] }

        let trimmedContent = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return [] }

        if let plainTags = decodePrivateTags(from: trimmedContent) {
            return rebuildWordTags(in: plainTags)
        }

        guard let nsec, let keypair = Keypair(nsec: nsec.lowercased()) else {
            return []
        }

        guard let decrypted = try? decrypt(
            payload: trimmedContent,
            privateKeyA: keypair.privateKey,
            publicKeyB: keypair.publicKey
        ), let decryptedTags = decodePrivateTags(from: decrypted) else {
            throw RelayClientError.publishRejected("Couldn't read the existing private mute list.")
        }

        return rebuildWordTags(in: decryptedTags)
    }

    private func applyDecodedState(_ state: DecodedMuteState) {
        latestPrivateTags = state.privateTags
        mutedPubkeys = state.mutedPubkeys
        activeMutedWords = state.activeMutedWords
        mutedKeywordLists = state.mutedKeywordLists
        rebuildMutedWordMatchers()
        persistCurrentMutes()
    }

    private func applyPrivateTagsLocally(_ privateTags: [NostrSDK.Tag]) {
        latestPrivateTags = privateTags
        activeMutedWords = activeMutedWords(from: privateTags)
        mutedKeywordLists = keywordLists(from: privateTags)
        rebuildMutedWordMatchers()
    }

    private func activeMutedWords(from privateTags: [NostrSDK.Tag]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for tag in privateTags where tag.name.lowercased() == "word" {
            guard let normalized = normalizedMutedWord(tag.value),
                  seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func keywordLists(from privateTags: [NostrSDK.Tag]) -> [MutedKeywordListState] {
        var visibleLists: [MutedKeywordListState] = []
        var assignedWords = Set<String>()

        for preset in Self.keywordListPresets {
            let removedWords = removedWords(for: preset.id, in: privateTags)
            let addedWords = addedWords(for: preset.id, in: privateTags)

            var words: [String] = []
            var seen = Set<String>()

            for word in preset.defaultWords {
                let normalized = normalizedMutedWord(word) ?? word
                guard !removedWords.contains(normalized), seen.insert(normalized).inserted else { continue }
                words.append(normalized)
            }

            for word in addedWords.sorted() {
                guard seen.insert(word).inserted else { continue }
                words.append(word)
            }

            assignedWords.formUnion(words)

            visibleLists.append(
                MutedKeywordListState(
                    id: preset.id,
                    title: preset.title,
                    subtitle: preset.subtitle,
                    isEnabled: keywordListEnabled(for: preset.id, in: privateTags),
                    words: words,
                    allowsToggle: true,
                    allowsAddingWords: true
                )
            )
        }

        let otherWords = activeMutedWords(from: privateTags).filter { !assignedWords.contains($0) }
        visibleLists.append(
            MutedKeywordListState(
                id: Self.otherKeywordListID,
                title: "Custom",
                subtitle: "Your private muted words, phrases, and hashtags",
                isEnabled: true,
                words: otherWords,
                allowsToggle: false,
                allowsAddingWords: true
            )
        )

        return visibleLists
    }

    private func keywordListEnabled(for listID: String, in privateTags: [NostrSDK.Tag]) -> Bool {
        guard isKeywordConfigurationConfirmed(in: privateTags) else { return false }
        let matches = privateTags.filter {
            $0.name.lowercased() == Self.keywordListTagName && $0.value == listID
        }
        guard let tag = matches.last else { return true }
        return tag.otherParameters.first?.lowercased() != "0"
    }

    private func removedWords(for listID: String, in privateTags: [NostrSDK.Tag]) -> Set<String> {
        Set(
            privateTags.compactMap { tag in
                guard tag.name.lowercased() == Self.keywordRemovalTagName,
                      tag.value == listID,
                      let word = tag.otherParameters.first,
                      let normalized = normalizedMutedWord(word) else { return nil }
                return normalized
            }
        )
    }

    private func addedWords(for listID: String, in privateTags: [NostrSDK.Tag]) -> Set<String> {
        Set(
            privateTags.compactMap { tag in
                guard tag.name.lowercased() == Self.keywordAdditionTagName,
                      tag.value == listID,
                      let word = tag.otherParameters.first,
                      let normalized = normalizedMutedWord(word) else { return nil }
                return normalized
            }
        )
    }

    private func rebuildWordTags(in privateTags: [NostrSDK.Tag]) -> [NostrSDK.Tag] {
        let retiredPresetWordsToDrop = retiredPresetDefaultWordsToDrop(from: privateTags)
        let nonWordTags = privateTags.filter {
            $0.name.lowercased() != "word" && !isRetiredKeywordListMetadata($0)
        }
        let visibleLists = keywordLists(from: nonWordTags)
        let allListWords = Set(visibleLists.flatMap(\.words))
        let orphanWords = activeMutedWords(from: privateTags).filter {
            !allListWords.contains($0) && !retiredPresetWordsToDrop.contains($0)
        }

        var rebuilt = nonWordTags
        var appended = Set<String>()

        for word in orphanWords {
            if appended.insert(word).inserted, let tag = decodeSDKTag(from: ["word", word]) {
                rebuilt.append(tag)
            }
        }

        for list in visibleLists where list.isEnabled && list.id != Self.otherKeywordListID {
            for word in list.words {
                if appended.insert(word).inserted, let tag = decodeSDKTag(from: ["word", word]) {
                    rebuilt.append(tag)
                }
            }
        }

        return rebuilt
    }

    private func retiredPresetDefaultWordsToDrop(from privateTags: [NostrSDK.Tag]) -> Set<String> {
        var wordsToDrop = Set<String>()

        for (listID, words) in Self.retiredKeywordListDefaultWordsByID {
            guard privateTags.contains(where: { isRetiredKeywordListMetadata($0, listID: listID) }) else {
                continue
            }
            wordsToDrop.formUnion(words)
        }

        return wordsToDrop
    }

    private func isRetiredKeywordListMetadata(_ tag: NostrSDK.Tag) -> Bool {
        Self.retiredKeywordListDefaultWordsByID.keys.contains { listID in
            isRetiredKeywordListMetadata(tag, listID: listID)
        }
    }

    private func isRetiredKeywordListMetadata(_ tag: NostrSDK.Tag, listID: String) -> Bool {
        let name = tag.name.lowercased()
        guard tag.value == listID else { return false }
        return name == Self.keywordListTagName ||
            name == Self.keywordRemovalTagName ||
            name == Self.keywordAdditionTagName
    }

    private func needsDefaultKeywordSeeding(in privateTags: [NostrSDK.Tag]) -> Bool {
        false
    }

    private func seedingDefaultKeywordListMetadata(into privateTags: [NostrSDK.Tag]) -> [NostrSDK.Tag] {
        var next = privateTags
        for preset in Self.keywordListPresets {
            next = replacingKeywordListEnabledTag(in: next, listID: preset.id, isEnabled: true)
        }
        return next
    }

    private func updatedPublicTags(from publicTags: [NostrSDK.Tag], targetPubkey: String) -> [NostrSDK.Tag] {
        publicTags.filter { tag in
            !(tag.name.lowercased() == "p" && normalizePubkey(tag.value) == targetPubkey)
        }
    }

    private func updatedPrivatePubkeyTags(from privateTags: [NostrSDK.Tag], targetPubkey: String, shouldMute: Bool) -> [NostrSDK.Tag] {
        var next = privateTags.filter { tag in
            !(tag.name.lowercased() == "p" && normalizePubkey(tag.value) == targetPubkey)
        }

        if shouldMute, let pubkeyTag = decodeSDKTag(from: ["p", targetPubkey]) {
            next.append(pubkeyTag)
        }

        return next
    }

    private func replacingKeywordListEnabledTag(in privateTags: [NostrSDK.Tag], listID: String, isEnabled: Bool) -> [NostrSDK.Tag] {
        var next = privateTags.filter {
            !($0.name.lowercased() == Self.keywordListTagName && $0.value == listID)
        }

        if let tag = decodeSDKTag(from: [Self.keywordListTagName, listID, isEnabled ? "1" : "0"]) {
            next.append(tag)
        }
        return next
    }

    private func isKeywordConfigurationConfirmed(in privateTags: [NostrSDK.Tag]) -> Bool {
        privateTags.contains { tag in
            let name = tag.name.lowercased()
            if name == Self.keywordConfirmationTagName {
                return true
            }
            if name == Self.keywordRemovalTagName || name == Self.keywordAdditionTagName {
                return true
            }
            if name == Self.keywordListTagName {
                return tag.otherParameters.first?.lowercased() == "0"
            }
            return false
        }
    }

    private func markingKeywordConfigurationConfirmed(in privateTags: [NostrSDK.Tag]) -> [NostrSDK.Tag] {
        var next = privateTags.filter { $0.name.lowercased() != Self.keywordConfirmationTagName }
        if let tag = decodeSDKTag(from: [Self.keywordConfirmationTagName, "1"]) {
            next.append(tag)
        }
        return next
    }

    private func upsertingRemovedWord(_ word: String, in privateTags: [NostrSDK.Tag], listID: String) -> [NostrSDK.Tag] {
        var next = removingKeywordAdditionTag(word, from: privateTags, listID: listID)
        guard !tagExists(name: Self.keywordRemovalTagName, value: listID, firstOtherParameter: word, in: next),
              let tag = decodeSDKTag(from: [Self.keywordRemovalTagName, listID, word]) else {
            return next
        }
        next.append(tag)
        return next
    }

    private func upsertingAddedWord(_ word: String, in privateTags: [NostrSDK.Tag], listID: String) -> [NostrSDK.Tag] {
        var next = removingKeywordRemovalTag(word, from: privateTags, listID: listID)
        guard !tagExists(name: Self.keywordAdditionTagName, value: listID, firstOtherParameter: word, in: next),
              let tag = decodeSDKTag(from: [Self.keywordAdditionTagName, listID, word]) else {
            return next
        }
        next.append(tag)
        return next
    }

    private func removingKeywordRemovalTag(_ word: String, from privateTags: [NostrSDK.Tag], listID: String) -> [NostrSDK.Tag] {
        privateTags.filter {
            !($0.name.lowercased() == Self.keywordRemovalTagName &&
              $0.value == listID &&
              normalizedMutedWord($0.otherParameters.first) == word)
        }
    }

    private func removingKeywordAdditionTag(_ word: String, from privateTags: [NostrSDK.Tag], listID: String) -> [NostrSDK.Tag] {
        privateTags.filter {
            !($0.name.lowercased() == Self.keywordAdditionTagName &&
              $0.value == listID &&
              normalizedMutedWord($0.otherParameters.first) == word)
        }
    }

    private func removingPrivateWordTag(_ word: String, from privateTags: [NostrSDK.Tag]) -> [NostrSDK.Tag] {
        privateTags.filter {
            !($0.name.lowercased() == "word" && normalizedMutedWord($0.value) == word)
        }
    }

    private func upsertingPrivateWordTag(_ word: String, in privateTags: [NostrSDK.Tag]) -> [NostrSDK.Tag] {
        guard !containsPrivateWordTag(word, in: privateTags),
              let tag = decodeSDKTag(from: ["word", word]) else {
            return privateTags
        }
        return privateTags + [tag]
    }

    private func containsPrivateWordTag(_ word: String, in privateTags: [NostrSDK.Tag]) -> Bool {
        privateTags.contains {
            $0.name.lowercased() == "word" &&
                normalizedMutedWord($0.value) == word
        }
    }

    private func tagExists(
        name: String,
        value: String,
        firstOtherParameter: String,
        in privateTags: [NostrSDK.Tag]
    ) -> Bool {
        privateTags.contains {
            $0.name.lowercased() == name &&
                $0.value == value &&
                normalizedMutedWord($0.otherParameters.first) == firstOtherParameter
        }
    }

    private func decodePrivateTags(from content: String) -> [NostrSDK.Tag]? {
        guard let data = content.data(using: .utf8),
              let tags = try? JSONDecoder().decode([NostrSDK.Tag].self, from: data) else {
            return nil
        }
        return tags
    }

    private func decodeSDKTag(from raw: [String]) -> NostrSDK.Tag? {
        guard raw.count >= 2 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
            return nil
        }
        return tag
    }

    private func encodeRawTag(_ tag: NostrSDK.Tag) -> [String] {
        [tag.name, tag.value] + tag.otherParameters
    }

    private func loadPersistedMutes(for accountPubkey: String) -> Set<String> {
        if let saved = defaults.stringArray(forKey: defaultsKey(for: accountPubkey)) {
            return Set(saved.map(normalizePubkey).filter { !$0.isEmpty })
        }

        let legacyKey = legacyDefaultsKey(for: accountPubkey)
        guard let saved = defaults.stringArray(forKey: legacyKey) else { return [] }
        let migrated = Set(saved.map(normalizePubkey).filter { !$0.isEmpty })
        defaults.set(Array(migrated).sorted(), forKey: defaultsKey(for: accountPubkey))
        return migrated
    }

    private func persistCurrentMutes() {
        guard let accountPubkey = session?.accountPubkey else { return }
        defaults.set(Array(mutedPubkeys).sorted(), forKey: defaultsKey(for: accountPubkey))
    }

    private func defaultsKey(for accountPubkey: String) -> String {
        "\(keyPrefix).\(accountPubkey)"
    }

    private func legacyDefaultsKey(for accountPubkey: String) -> String {
        "\(legacyKeyPrefix).\(accountPubkey)"
    }

    private func normalizePubkey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizeNsec(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedMutedWord(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    private static func defaultMutedKeywordLists() -> [MutedKeywordListState] {
        let presetLists = keywordListPresets.map {
            MutedKeywordListState(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                isEnabled: false,
                words: $0.defaultWords,
                allowsToggle: true,
                allowsAddingWords: true
            )
        }

        return presetLists + [
            MutedKeywordListState(
                id: otherKeywordListID,
                title: "Custom",
                subtitle: "Your private muted words, phrases, and hashtags",
                isEnabled: true,
                words: [],
                allowsToggle: false,
                allowsAddingWords: true
            )
        ]
    }

    private func containsMutedWord(in event: NostrEvent) -> Bool {
        guard !activeMutedWords.isEmpty else {
            return false
        }

        return containsMutedWord(inNormalizedText: normalizedSearchableText(for: event))
    }

    private func containsMutedWord(inNormalizedText normalizedText: String?) -> Bool {
        guard !activeMutedWords.isEmpty,
              let normalizedText,
              !normalizedText.isEmpty else {
            return false
        }

        if !exactMutedWords.isEmpty {
            let tokens = Set(
                normalizedText.split(whereSeparator: { !isMutedWordTokenCharacter($0) })
                    .map(String.init)
            )

            if !tokens.isDisjoint(with: exactMutedWords) {
                return true
            }
        }

        for phrase in phraseMutedWords where normalizedText.contains(phrase) {
            return true
        }

        return false
    }

    private func rebuildMutedWordMatchers() {
        invalidateFilterCaches()

        var nextExactMutedWords = Set<String>()
        var nextPhraseMutedWords: [String] = []

        for word in activeMutedWords {
            if word.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil {
                nextExactMutedWords.insert(word)
            } else {
                nextPhraseMutedWords.append(word)
            }
        }

        exactMutedWords = nextExactMutedWords
        phraseMutedWords = nextPhraseMutedWords
    }

    private func clearMuteCaches() {
        muteDecisionCache.removeAll(keepingCapacity: true)
    }

    private func clearDerivedEventCaches() {
        normalizedEventTextCache.removeAll(keepingCapacity: true)
    }

    private func invalidateFilterCaches() {
        clearMuteCaches()
        filterRevision &+= 1
    }

    private func normalizedSearchableText(for event: NostrEvent) -> String? {
        if let cached = normalizedEventTextCache[event.id] {
            return cached.isEmpty ? nil : cached
        }

        let tagContent = event.tags
            .flatMap { tag -> [String] in
                guard let name = tag.first?.lowercased(), tag.count > 1 else {
                    return []
                }

                let value = tag[1]

                switch name {
                case "t":
                    let normalized = normalizedMutedWord(value) ?? value
                    return [normalized, "#\(normalized)"]
                case "subject", "title", "summary":
                    return [value]
                default:
                    return []
                }
            }
            .joined(separator: " ")

        let combinedContent: String
        if tagContent.isEmpty {
            combinedContent = event.content
        } else if event.content.isEmpty {
            combinedContent = tagContent
        } else {
            combinedContent = "\(event.content) \(tagContent)"
        }

        let normalized = normalizedMutedWord(combinedContent) ?? ""
        if normalizedEventTextCache.count >= Self.normalizedEventTextCacheLimit {
            normalizedEventTextCache.removeAll(keepingCapacity: true)
        }
        normalizedEventTextCache[event.id] = normalized
        return normalized.isEmpty ? nil : normalized
    }

    private func isMutedWordTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
