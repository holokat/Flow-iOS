import Foundation
import NostrSDK

enum RelayScope: String, CaseIterable, Identifiable {
    case read
    case write
    case inbox
    case both

    var id: String { rawValue }
}

enum RelaySettingsError: LocalizedError {
    case invalidRelayURL
    case readRelayRequired
    case writeRelayRequired

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            return "Enter a valid source address."
        case .readRelayRequired:
            return "Keep at least one reading source."
        case .writeRelayRequired:
            return "Keep at least one publishing source."
        }
    }
}

@MainActor
final class RelaySettingsStore: ObservableObject {
    static let shared = RelaySettingsStore()

    // Mirrors Flow web defaults.
    static let defaultReadRelayURLs = [
        "wss://relay.damus.io/",
        "wss://relay.primal.net/"
    ]

    static let defaultWriteRelayURLs = [
        "wss://relay.damus.io/",
        "wss://relay.primal.net/",
        "wss://sendit.nosflare.com/"
    ]

    static let defaultInboxRelayURLs: [String] = []

    private static let bootstrapPublishRelayURLs = [
        "wss://relay.damus.io/",
        "wss://nos.lol/",
        "wss://relay.nostr.band/",
        "wss://nostr.mom/"
    ]

    @Published private(set) var readRelays: [String]
    @Published private(set) var writeRelays: [String]
    @Published private(set) var inboxRelays: [String]
    @Published private(set) var lastPublishError: String?

    private struct PersistedRelaySettings: Codable {
        let readRelays: [String]
        let writeRelays: [String]
        let inboxRelays: [String]?
    }

    private let defaults: UserDefaults
    private let relayClient: NostrRelayClient
    private let keyPrefix = "flow.relaySettings"
    private let legacyKeyPrefix = "x21.relaySettings"

    private var accountPubkey: String?
    private var nsec: String?
    private var publishTask: Task<Void, Never>?
    private var inboxPublishTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        relayClient: NostrRelayClient = NostrRelayClient()
    ) {
        self.defaults = defaults
        self.relayClient = relayClient
        self.readRelays = Self.defaultReadRelayURLs
        self.writeRelays = Self.defaultWriteRelayURLs
        self.inboxRelays = Self.defaultInboxRelayURLs
    }

    deinit {
        publishTask?.cancel()
        inboxPublishTask?.cancel()
    }

    var readRelayURLs: [URL] {
        readRelays.compactMap(URL.init(string:))
    }

    var writeRelayURLs: [URL] {
        writeRelays.compactMap(URL.init(string:))
    }

    var inboxRelayURLs: [URL] {
        inboxRelays.compactMap(URL.init(string:))
    }

    var primaryReadRelayURL: URL? {
        readRelayURLs.first
    }

    var primaryReadRelayLabel: String {
        primaryReadRelayURL?.host() ?? readRelays.first ?? Self.defaultReadRelayURLs[0]
    }

    func configure(accountPubkey: String?, nsec: String?) {
        let normalizedAccount = normalizeAccountPubkey(accountPubkey)
        let normalizedNsec = normalizeNsec(nsec)

        let accountChanged = normalizedAccount != self.accountPubkey
        self.accountPubkey = normalizedAccount
        self.nsec = normalizedNsec

        guard accountChanged else { return }

        lastPublishError = nil
        publishTask?.cancel()
        inboxPublishTask?.cancel()

        guard let normalizedAccount else {
            apply(
                readRelays: Self.defaultReadRelayURLs,
                writeRelays: Self.defaultWriteRelayURLs,
                inboxRelays: Self.defaultInboxRelayURLs
            )
            return
        }

        if let persisted = loadPersistedSettings(for: normalizedAccount) {
            apply(
                readRelays: persisted.readRelays,
                writeRelays: persisted.writeRelays,
                inboxRelays: persisted.inboxRelays ?? Self.defaultInboxRelayURLs
            )
        } else {
            apply(
                readRelays: Self.defaultReadRelayURLs,
                writeRelays: Self.defaultWriteRelayURLs,
                inboxRelays: Self.defaultInboxRelayURLs
            )
        }
    }

    func seedDefaultRelaysForCurrentAccount(publishToBootstrapRelays: Bool) {
        guard accountPubkey != nil else { return }
        apply(
            readRelays: Self.defaultReadRelayURLs,
            writeRelays: Self.defaultWriteRelayURLs,
            inboxRelays: Self.defaultInboxRelayURLs
        )
        persistCurrentSettings()
        if publishToBootstrapRelays {
            schedulePublishRelayList(useBootstrapRelayTargets: true)
        }
    }

    func addRelay(_ relayInput: String, scope: RelayScope) throws {
        guard let normalized = normalizedRelayURL(relayInput) else {
            throw RelaySettingsError.invalidRelayURL
        }

        switch scope {
        case .read:
            if !readRelays.contains(normalized) {
                readRelays.append(normalized)
            }
        case .write:
            if !writeRelays.contains(normalized) {
                writeRelays.append(normalized)
            }
        case .inbox:
            if !inboxRelays.contains(normalized) {
                inboxRelays.append(normalized)
            }
        case .both:
            if !readRelays.contains(normalized) {
                readRelays.append(normalized)
            }
            if !writeRelays.contains(normalized) {
                writeRelays.append(normalized)
            }
        }

        persistCurrentSettings()
        switch scope {
        case .inbox:
            schedulePublishInboxRelayList()
        case .read, .write, .both:
            schedulePublishRelayList(useBootstrapRelayTargets: false)
        }
    }

    func removeReadRelay(_ relayURL: String) throws {
        guard readRelays.contains(relayURL) else { return }
        guard readRelays.count > 1 else {
            throw RelaySettingsError.readRelayRequired
        }

        readRelays.removeAll { $0 == relayURL }

        persistCurrentSettings()
        schedulePublishRelayList(useBootstrapRelayTargets: false)
    }

    func removeInboxRelay(_ relayURL: String) throws {
        guard inboxRelays.contains(relayURL) else { return }
        inboxRelays.removeAll { $0 == relayURL }
        persistCurrentSettings()
        schedulePublishInboxRelayList()
    }

    func removeWriteRelay(_ relayURL: String) throws {
        guard writeRelays.contains(relayURL) else { return }
        guard writeRelays.count > 1 else {
            throw RelaySettingsError.writeRelayRequired
        }

        writeRelays.removeAll { $0 == relayURL }
        persistCurrentSettings()
        schedulePublishRelayList(useBootstrapRelayTargets: false)
    }

    private func loadPersistedSettings(for accountPubkey: String) -> PersistedRelaySettings? {
        if let data = defaults.data(forKey: defaultsKey(for: accountPubkey)),
           let decoded = try? JSONDecoder().decode(PersistedRelaySettings.self, from: data) {
            return decoded
        }

        guard let data = defaults.data(forKey: legacyDefaultsKey(for: accountPubkey)),
              let decoded = try? JSONDecoder().decode(PersistedRelaySettings.self, from: data) else {
            return nil
        }
        defaults.set(data, forKey: defaultsKey(for: accountPubkey))
        return decoded
    }

    private func persistCurrentSettings() {
        guard let accountPubkey else { return }

        let payload = PersistedRelaySettings(
            readRelays: readRelays,
            writeRelays: writeRelays,
            inboxRelays: inboxRelays
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: defaultsKey(for: accountPubkey))
        }
    }

    private func schedulePublishRelayList(useBootstrapRelayTargets: Bool) {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            await self?.publishRelayList(useBootstrapRelayTargets: useBootstrapRelayTargets)
        }
    }

    private func schedulePublishInboxRelayList() {
        inboxPublishTask?.cancel()
        inboxPublishTask = Task { [weak self] in
            await self?.publishInboxRelayList()
        }
    }

    private func publishRelayList(useBootstrapRelayTargets: Bool) async {
        guard let accountPubkey, let nsec else { return }
        guard let keypair = Keypair(nsec: nsec.lowercased()) else {
            guard self.accountPubkey == accountPubkey else { return }
            lastPublishError = "Couldn’t update Connection settings. Please sign in again."
            return
        }

        let relayTags = relayMetadataTags()
        guard !relayTags.isEmpty else { return }

        let sdkTags = relayTags.compactMap(decodeSDKTag(from:))
        guard !sdkTags.isEmpty else { return }

        do {
            let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .relayListMetadata)
                .content("")
                .appendTags(contentsOf: sdkTags)
                .build(signedBy: keypair)

            let eventData = try JSONEncoder().encode(event)
            guard let eventObject = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                throw RelayClientError.publishRejected("Couldn’t prepare Connection settings")
            }

            let targets: [String]
            if useBootstrapRelayTargets {
                targets = Self.bootstrapPublishRelayURLs
            } else {
                let normalizedWrite = normalizeRelayList(writeRelays)
                targets = normalizedWrite.isEmpty ? Self.bootstrapPublishRelayURLs : normalizedWrite
            }

            var successfulPublishes = 0
            for relayString in targets {
                guard let relayURL = URL(string: relayString) else { continue }
                do {
                    try await relayClient.publishEvent(
                        relayURL: relayURL,
                        eventObject: eventObject,
                        eventID: event.id
                    )
                    successfulPublishes += 1
                } catch {
                    continue
                }
            }

            guard self.accountPubkey == accountPubkey else { return }
            if successfulPublishes > 0 {
                lastPublishError = nil
            } else {
                lastPublishError = "Couldn’t update Connection settings right now."
            }
        } catch {
            guard self.accountPubkey == accountPubkey else { return }
            lastPublishError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func relayMetadataTags() -> [[String]] {
        let readSet = Set(readRelays)
        let writeSet = Set(writeRelays)
        let orderedRelays = orderedUniqueRelays(from: readRelays + writeRelays)

        return orderedRelays.map { relayURL in
            let isRead = readSet.contains(relayURL)
            let isWrite = writeSet.contains(relayURL)

            if isRead && isWrite {
                return ["r", relayURL]
            }
            if isRead {
                return ["r", relayURL, "read"]
            }
            return ["r", relayURL, "write"]
        }
    }

    private func publishInboxRelayList() async {
        guard let accountPubkey, let nsec else { return }
        guard !inboxRelays.isEmpty else { return }
        guard let keypair = Keypair(nsec: nsec.lowercased()) else {
            guard self.accountPubkey == accountPubkey else { return }
            lastPublishError = "Couldn’t update messaging sources. Please sign in again."
            return
        }

        let sdkTags = inboxRelays.compactMap { decodeSDKTag(from: ["relay", $0]) }
        guard !sdkTags.isEmpty else { return }

        do {
            let event = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(10_050))
                .content("")
                .appendTags(contentsOf: sdkTags)
                .build(signedBy: keypair)

            let eventData = try JSONEncoder().encode(event)
            guard let eventObject = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                throw RelayClientError.publishRejected("Couldn’t prepare messaging sources")
            }

            let targets = normalizeRelayList(writeRelays + inboxRelays + Self.bootstrapPublishRelayURLs)
            var successfulPublishes = 0
            for relayString in targets {
                guard let relayURL = URL(string: relayString) else { continue }
                do {
                    try await relayClient.publishEvent(
                        relayURL: relayURL,
                        eventObject: eventObject,
                        eventID: event.id
                    )
                    successfulPublishes += 1
                } catch {
                    continue
                }
            }

            guard self.accountPubkey == accountPubkey else { return }
            lastPublishError = successfulPublishes > 0 ? nil : "Couldn’t update messaging sources right now."
        } catch {
            guard self.accountPubkey == accountPubkey else { return }
            lastPublishError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func decodeSDKTag(from raw: [String]) -> NostrSDK.Tag? {
        guard raw.count >= 2 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
            return nil
        }
        return tag
    }

    private func apply(readRelays: [String], writeRelays: [String], inboxRelays: [String]) {
        let normalizedRead = normalizeRelayList(readRelays)
        let normalizedWrite = normalizeRelayList(writeRelays)
        let normalizedInbox = normalizeRelayList(inboxRelays)

        self.readRelays = normalizedRead.isEmpty ? Self.defaultReadRelayURLs : normalizedRead
        self.writeRelays = normalizedWrite.isEmpty ? Self.defaultWriteRelayURLs : normalizedWrite
        self.inboxRelays = normalizedInbox
    }

    private func normalizeRelayList(_ relays: [String]) -> [String] {
        orderedUniqueRelays(from: relays.compactMap(normalizedRelayURL(_:)))
    }

    private func orderedUniqueRelays(from relays: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for relay in relays {
            guard seen.insert(relay).inserted else { continue }
            ordered.append(relay)
        }
        return ordered
    }

    private func normalizedRelayURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "wss://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              (scheme == "wss" || scheme == "ws"),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        guard let url = components.url,
              FlowURLSafety.isPubliclyLoadableRelayURL(url) else {
            return nil
        }

        let portPart = components.port.map { ":\($0)" } ?? ""
        var pathPart = components.path
        if pathPart.isEmpty {
            pathPart = "/"
        } else if !pathPart.hasPrefix("/") {
            pathPart = "/\(pathPart)"
        }

        // Keep relay URLs canonical and comparable.
        if pathPart == "/" {
            return "\(scheme)://\(host)\(portPart)/"
        }
        return "\(scheme)://\(host)\(portPart)\(pathPart)"
    }

    private func normalizeAccountPubkey(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeNsec(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func defaultsKey(for accountPubkey: String) -> String {
        "\(keyPrefix).\(accountPubkey)"
    }

    private func legacyDefaultsKey(for accountPubkey: String) -> String {
        "\(legacyKeyPrefix).\(accountPubkey)"
    }
}
