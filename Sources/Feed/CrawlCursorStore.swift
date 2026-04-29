import Foundation

enum LocalCorpusCrawlCursorTier: String, Codable, CaseIterable, Sendable {
    case tierA
    case tierAArticles
    case tierB
}

actor CrawlCursorStore {
    struct State: Codable, Equatable, Sendable {
        var untilCursorByTierAndPubkey: [String: [String: Int]] = [:]
        var lastReplaceableRefreshAt: Date?
        var queuedMissingReferenceIDs: [String] = []
    }

    private let fileManager: FileManager
    private let stateURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var state: State

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        fileName: String = "local-corpus-crawl-state.json"
    ) {
        self.fileManager = fileManager
        let baseURL = rootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.stateURL = baseURL.appendingPathComponent(fileName, isDirectory: false)
        self.state = Self.loadState(fileManager: fileManager, decoder: decoder, stateURL: stateURL)
    }

    func untilCursor(
        for pubkey: String,
        tier: LocalCorpusCrawlCursorTier
    ) -> Int? {
        state.untilCursorByTierAndPubkey[tier.rawValue]?[normalize(pubkey)]
    }

    func setUntilCursor(
        _ cursor: Int?,
        for pubkey: String,
        tier: LocalCorpusCrawlCursorTier
    ) async {
        let normalizedPubkey = normalize(pubkey)
        guard !normalizedPubkey.isEmpty else { return }

        var cursors = state.untilCursorByTierAndPubkey[tier.rawValue] ?? [:]
        if let cursor {
            cursors[normalizedPubkey] = cursor
        } else {
            cursors.removeValue(forKey: normalizedPubkey)
        }

        if cursors.isEmpty {
            state.untilCursorByTierAndPubkey.removeValue(forKey: tier.rawValue)
        } else {
            state.untilCursorByTierAndPubkey[tier.rawValue] = cursors
        }

        persist()
    }

    func lastReplaceableRefreshAt() -> Date? {
        state.lastReplaceableRefreshAt
    }

    func setLastReplaceableRefreshAt(_ date: Date?) async {
        state.lastReplaceableRefreshAt = date
        persist()
    }

    func queuedMissingReferenceIDs() -> [String] {
        state.queuedMissingReferenceIDs
    }

    func queuedMissingReferenceIdentifiers() -> [String] {
        state.queuedMissingReferenceIDs
    }

    func enqueueMissingReferenceIDs(_ ids: [String]) async {
        guard !ids.isEmpty else { return }

        var seen = Set(state.queuedMissingReferenceIDs)
        for id in ids.map(normalize).filter({ !$0.isEmpty }) {
            guard seen.insert(id).inserted else { continue }
            state.queuedMissingReferenceIDs.append(id)
        }

        persist()
    }

    func enqueueMissingReferenceIdentifiers(_ identifiers: [String]) async {
        await enqueueMissingReferenceIDs(identifiers)
    }

    func removeMissingReferenceIDs(_ ids: [String]) async {
        guard !ids.isEmpty else { return }

        let removals = Set(ids.map(normalize).filter { !$0.isEmpty })
        guard !removals.isEmpty else { return }

        state.queuedMissingReferenceIDs.removeAll { removals.contains($0) }
        persist()
    }

    func removeMissingReferenceIdentifiers(_ identifiers: [String]) async {
        await removeMissingReferenceIDs(identifiers)
    }

    func snapshot() -> State {
        state
    }

    private func persist() {
        let directoryURL = stateURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }

        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadState(
        fileManager: FileManager,
        decoder: JSONDecoder,
        stateURL: URL
    ) -> State {
        guard fileManager.fileExists(atPath: stateURL.path),
              let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(State.self, from: data) else {
            return State()
        }
        return state
    }
}
