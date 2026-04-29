import CryptoKit
import Foundation

actor TimelineEventCache: TimelineEventCaching {
    static let shared = TimelineEventCache()

    private struct Entry {
        let events: [NostrEvent]
        let storedAt: Date
    }

    private let ttl: TimeInterval = 45
    private let maxEntries = 64

    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private var inFlight: [String: Task<[NostrEvent], Error>] = [:]

    func events(
        for key: String,
        fetcher: @escaping @Sendable () async throws -> [NostrEvent]
    ) async throws -> [NostrEvent] {
        if let cached = entries[key], Date().timeIntervalSince(cached.storedAt) < ttl {
            touch(key)
            return cached.events
        }

        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task {
            try await fetcher()
        }
        inFlight[key] = task

        do {
            let value = try await task.value
            inFlight[key] = nil
            store(events: value, for: key)
            return value
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private func store(events: [NostrEvent], for key: String) {
        entries[key] = Entry(events: events, storedAt: Date())
        touch(key)

        if recency.count > maxEntries, let oldest = recency.first {
            recency.removeFirst()
            entries[oldest] = nil
            inFlight[oldest] = nil
        }
    }

    private func touch(_ key: String) {
        recency.removeAll(where: { $0 == key })
        recency.append(key)
    }
}

struct PersistedProfileSnapshot: Codable, Sendable {
    let profile: NostrProfile
    let fetchedAt: Date
}

actor ProfileSnapshotStore {
    static let shared = ProfileSnapshotStore()

    private struct Payload: Codable {
        let storedAt: Date
        let snapshot: PersistedProfileSnapshot
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxSnapshots = 8_000
    private let maxAge: TimeInterval = 60 * 60 * 24 * 30

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directoryURL = root.appendingPathComponent("x21-profile-cache", isDirectory: true)
    }

    func getMany(pubkeys: [String]) async -> [String: PersistedProfileSnapshot] {
        guard !pubkeys.isEmpty else { return [:] }
        ensureDirectory()

        var result: [String: PersistedProfileSnapshot] = [:]
        for pubkey in Set(pubkeys) {
            guard let payload = readPayload(pubkey: pubkey) else { continue }
            result[pubkey] = payload.snapshot
        }
        return result
    }

    func putMany(entries: [String: PersistedProfileSnapshot]) async {
        guard !entries.isEmpty else { return }
        ensureDirectory()

        for (pubkey, snapshot) in entries {
            let payload = Payload(storedAt: Date(), snapshot: snapshot)
            guard let data = try? encoder.encode(payload) else { continue }
            let url = fileURL(for: pubkey)
            try? data.write(to: url, options: .atomic)
        }

        pruneIfNeeded()
    }

    private func readPayload(pubkey: String) -> Payload? {
        let url = fileURL(for: pubkey)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return nil
        }

        if Date().timeIntervalSince(payload.storedAt) > maxAge {
            try? fileManager.removeItem(at: url)
            return nil
        }

        return payload
    }

    private func ensureDirectory() {
        if fileManager.fileExists(atPath: directoryURL.path) {
            return
        }

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hashed = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(hashed).json", isDirectory: false)
    }

    private func pruneIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        if files.count <= maxSnapshots {
            return
        }

        let sorted = files.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        for url in sorted.dropFirst(maxSnapshots) {
            try? fileManager.removeItem(at: url)
        }
    }
}

actor FollowListSnapshotCache: FollowListSnapshotStoring {
    static let shared = FollowListSnapshotCache()

    private struct Payload: Codable {
        let storedAt: Date
        let snapshot: FollowListSnapshot
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxSnapshots = 1_500
    private let maxAge: TimeInterval = 60 * 60 * 24 * 7

    init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directoryURL = root.appendingPathComponent("x21-follow-list-cache", isDirectory: true)
    }

    func cachedSnapshot(pubkey: String, maxAge overrideMaxAge: TimeInterval? = nil) async -> FollowListSnapshot? {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return nil }

        ensureDirectory()
        guard let payload = readPayload(pubkey: normalizedPubkey) else { return nil }

        let allowedAge = overrideMaxAge ?? maxAge
        if Date().timeIntervalSince(payload.storedAt) > allowedAge {
            return nil
        }

        return payload.snapshot
    }

    func storeSnapshot(_ snapshot: FollowListSnapshot, for pubkey: String) async {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return }

        ensureDirectory()
        let payload = Payload(storedAt: Date(), snapshot: snapshot)
        guard let data = try? encoder.encode(payload) else { return }
        let url = fileURL(for: normalizedPubkey)
        try? data.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    private func readPayload(pubkey: String) -> Payload? {
        let url = fileURL(for: pubkey)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return nil
        }

        if Date().timeIntervalSince(payload.storedAt) > maxAge {
            try? fileManager.removeItem(at: url)
            return nil
        }

        return payload
    }

    private func ensureDirectory() {
        if fileManager.fileExists(atPath: directoryURL.path) {
            return
        }

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hashed = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(hashed).json", isDirectory: false)
    }

    private func normalizePubkey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func pruneIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        if files.count <= maxSnapshots {
            return
        }

        let sorted = files.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        for url in sorted.dropFirst(maxSnapshots) {
            try? fileManager.removeItem(at: url)
        }
    }
}

actor WebOfTrustGraphCache {
    static let shared = WebOfTrustGraphCache()

    private struct Payload: Codable {
        let storedAt: Date
        let pubkeys: [String]
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxSnapshots = 256
    private let maxAge: TimeInterval = 60 * 60 * 12

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directoryURL = root.appendingPathComponent("x21-wot-cache", isDirectory: true)
    }

    func cachedPubkeys(for key: String, maxAge overrideMaxAge: TimeInterval? = nil) async -> [String]? {
        ensureDirectory()
        guard let payload = readPayload(key: key) else { return nil }

        let allowedAge = overrideMaxAge ?? maxAge
        if Date().timeIntervalSince(payload.storedAt) > allowedAge {
            return nil
        }

        return payload.pubkeys
    }

    func storePubkeys(_ pubkeys: [String], for key: String) async {
        ensureDirectory()
        let payload = Payload(storedAt: Date(), pubkeys: pubkeys)
        guard let data = try? encoder.encode(payload) else { return }
        let url = fileURL(for: key)
        try? data.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    private func readPayload(key: String) -> Payload? {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return nil
        }

        if Date().timeIntervalSince(payload.storedAt) > maxAge {
            try? fileManager.removeItem(at: url)
            return nil
        }

        return payload
    }

    private func ensureDirectory() {
        if fileManager.fileExists(atPath: directoryURL.path) {
            return
        }

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hashed = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(hashed).json", isDirectory: false)
    }

    private func pruneIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        if files.count <= maxSnapshots {
            return
        }

        let sorted = files.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        for url in sorted.dropFirst(maxSnapshots) {
            try? fileManager.removeItem(at: url)
        }
    }
}

actor ProfileRelayHintCache: ProfileRelayHintCaching, AuthorRelayDirectoryCaching {
    static let shared = ProfileRelayHintCache()

    struct Diagnostics: Equatable, Sendable {
        let totalEntries: Int
        let outboxReadyEntries: Int
        let writeOnlyEntries: Int
        let hintOnlyEntries: Int
    }

    private let maxEntries = 8_000
    private let maxHintsPerPubkey = 8

    private var relayDirectoryByPubkey: [String: AuthorRelayDirectoryEntry] = [:]
    private var recency: [String] = []

    func storeHints(_ hintsByPubkey: [String: [URL]]) {
        for (rawPubkey, relayURLs) in hintsByPubkey {
            let pubkey = normalizePubkey(rawPubkey)
            guard !pubkey.isEmpty else { continue }

            let existingEntry = relayDirectoryByPubkey[pubkey] ?? AuthorRelayDirectoryEntry(
                readRelayURLs: [],
                writeRelayURLs: [],
                hintRelayURLs: [],
                refreshedAt: nil
            )
            let mergedRelayURLs = mergeRelayURLs(
                existing: existingEntry.hintRelayURLs,
                incoming: relayURLs
            )
            guard !mergedRelayURLs.isEmpty else { continue }

            relayDirectoryByPubkey[pubkey] = AuthorRelayDirectoryEntry(
                readRelayURLs: existingEntry.readRelayURLs,
                writeRelayURLs: existingEntry.writeRelayURLs,
                hintRelayURLs: Array(mergedRelayURLs.prefix(maxHintsPerPubkey)),
                refreshedAt: existingEntry.refreshedAt
            )
            touch(pubkey)
        }

        pruneIfNeeded()
    }

    func prioritizedRelayURLs(for pubkeys: [String], baseRelayURLs: [URL]) -> [URL] {
        let normalizedPubkeys = Array(
            Set(
                pubkeys
                    .map(normalizePubkey)
                    .filter { !$0.isEmpty }
            )
        )

        var seen = Set<String>()
        var ordered: [URL] = []

        func append(_ relayURL: URL) {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { return }
            ordered.append(relayURL)
        }

        for pubkey in normalizedPubkeys {
            guard let entry = relayDirectoryByPubkey[pubkey] else { continue }
            touch(pubkey)

            let primaryRelayURLs = entry.readRelayURLs.isEmpty
                ? entry.writeRelayURLs
                : entry.readRelayURLs

            for relayURL in primaryRelayURLs + entry.hintRelayURLs {
                append(relayURL)
            }
        }

        for relayURL in baseRelayURLs {
            append(relayURL)
        }

        return ordered
    }

    func relayHints(for pubkeys: [String]) -> [String: [URL]] {
        let normalizedPubkeys = Array(
            Set(
                pubkeys
                    .map(normalizePubkey)
                    .filter { !$0.isEmpty }
            )
        )

        var hints: [String: [URL]] = [:]
        for pubkey in normalizedPubkeys {
            guard let relayURLs = relayDirectoryByPubkey[pubkey]?.hintRelayURLs, !relayURLs.isEmpty else {
                continue
            }
            touch(pubkey)
            hints[pubkey] = relayURLs
        }

        return hints
    }

    func entry(for pubkey: String) -> AuthorRelayDirectoryEntry? {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return nil }
        let entry = relayDirectoryByPubkey[normalizedPubkey]
        if entry != nil {
            touch(normalizedPubkey)
        }
        return entry
    }

    func entries(for pubkeys: [String]) -> [String: AuthorRelayDirectoryEntry] {
        let normalizedPubkeys = Array(
            Set(
                pubkeys
                    .map(normalizePubkey)
                    .filter { !$0.isEmpty }
            )
        )

        var results: [String: AuthorRelayDirectoryEntry] = [:]
        for pubkey in normalizedPubkeys {
            guard let entry = relayDirectoryByPubkey[pubkey] else { continue }
            touch(pubkey)
            results[pubkey] = entry
        }
        return results
    }

    func store(entry: AuthorRelayDirectoryEntry, for pubkey: String) {
        let normalizedPubkey = normalizePubkey(pubkey)
        guard !normalizedPubkey.isEmpty else { return }

        let existingEntry = relayDirectoryByPubkey[normalizedPubkey]
        relayDirectoryByPubkey[normalizedPubkey] = AuthorRelayDirectoryEntry(
            readRelayURLs: RelayURLSupport.normalizedRelayURLs(entry.readRelayURLs),
            writeRelayURLs: RelayURLSupport.normalizedRelayURLs(entry.writeRelayURLs),
            hintRelayURLs: entry.hintRelayURLs.isEmpty
                ? (existingEntry?.hintRelayURLs ?? [])
                : RelayURLSupport.normalizedRelayURLs(entry.hintRelayURLs),
            refreshedAt: entry.refreshedAt ?? existingEntry?.refreshedAt
        )
        touch(normalizedPubkey)
        pruneIfNeeded()
    }

    func diagnosticsSnapshot() -> Diagnostics {
        var outboxReadyEntries = 0
        var writeOnlyEntries = 0
        var hintOnlyEntries = 0

        for entry in relayDirectoryByPubkey.values {
            if !entry.readRelayURLs.isEmpty {
                outboxReadyEntries += 1
            } else if !entry.writeRelayURLs.isEmpty {
                writeOnlyEntries += 1
            } else if !entry.hintRelayURLs.isEmpty {
                hintOnlyEntries += 1
            }
        }

        return Diagnostics(
            totalEntries: relayDirectoryByPubkey.count,
            outboxReadyEntries: outboxReadyEntries,
            writeOnlyEntries: writeOnlyEntries,
            hintOnlyEntries: hintOnlyEntries
        )
    }

    private func mergeRelayURLs(existing: [URL], incoming: [URL]) -> [URL] {
        var seen = Set<String>()
        var merged: [URL] = []

        for relayURL in existing + incoming {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            merged.append(relayURL)
        }

        return merged
    }

    private func touch(_ pubkey: String) {
        recency.removeAll(where: { $0 == pubkey })
        recency.append(pubkey)
    }

    private func pruneIfNeeded() {
        guard recency.count > maxEntries else { return }

        let overflow = recency.count - maxEntries
        for pubkey in recency.prefix(overflow) {
            relayDirectoryByPubkey.removeValue(forKey: pubkey)
        }
        recency.removeFirst(overflow)
    }

    private func normalizePubkey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

actor ProfileCache: ProfileCaching {
    static let shared = ProfileCache()

    private let maxEntries = 4_000
    private let missTTL: TimeInterval = 60 * 20
    private let snapshotStore: ProfileSnapshotStore
    private var profiles: [String: PersistedProfileSnapshot] = [:]
    private var knownMisses: [String: Date] = [:]
    private var recency: [String] = []
    private var priorityPubkeys: Set<String> = []

    init(
        snapshotStore: ProfileSnapshotStore = .shared
    ) {
        self.snapshotStore = snapshotStore
    }

    func resolve(
        pubkeys: [String],
        ignoringKnownMisses: Bool = false
    ) async -> (hits: [String: NostrProfile], missing: [String]) {
        var hits: [String: NostrProfile] = [:]
        var unresolved: [String] = []

        let now = Date()
        let uniquePubkeys = Array(
            Set(
                pubkeys
                    .map(normalizePubkey)
                    .filter { !$0.isEmpty }
            )
        )

        for pubkey in uniquePubkeys {
            if let profile = profiles[pubkey] {
                hits[pubkey] = profile.profile
                touch(pubkey)
            } else if ignoringKnownMisses || !isKnownMissStillValid(pubkey, now: now) {
                unresolved.append(pubkey)
            }
        }

        if !unresolved.isEmpty {
            let persisted = await snapshotStore.getMany(pubkeys: unresolved)
            for (pubkey, snapshot) in persisted {
                profiles[pubkey] = snapshot
                hits[pubkey] = snapshot.profile
                knownMisses.removeValue(forKey: pubkey)
                touch(pubkey)
            }
            unresolved.removeAll(where: { persisted[$0] != nil })
            pruneOverflowIfNeeded()
        }

        let missing = unresolved.filter { pubkey in
            profiles[pubkey] == nil && (ignoringKnownMisses || !isKnownMissStillValid(pubkey, now: now))
        }
        return (hits, missing)
    }

    func cachedProfile(pubkey: String) async -> NostrProfile? {
        let normalized = normalizePubkey(pubkey)
        guard !normalized.isEmpty else { return nil }
        let resolved = await resolve(pubkeys: [normalized])
        return resolved.hits[normalized]
    }

    func cachedProfiles(pubkeys: [String]) async -> [String: NostrProfile] {
        let resolved = await resolve(pubkeys: pubkeys)
        return resolved.hits
    }

    func recentProfilePubkeys(limit: Int) async -> [String] {
        guard limit > 0 else { return [] }
        return Array(recency.suffix(limit).reversed())
    }

    func store(profiles newProfiles: [String: NostrProfile], missed: [String]) async {
        let now = Date()
        var persisted: [String: PersistedProfileSnapshot] = [:]
        var normalizedInserted = Set<String>()

        for (rawPubkey, profile) in newProfiles {
            let pubkey = normalizePubkey(rawPubkey)
            guard !pubkey.isEmpty else { continue }

            let snapshot = PersistedProfileSnapshot(profile: profile, fetchedAt: now)
            profiles[pubkey] = snapshot
            persisted[pubkey] = snapshot
            normalizedInserted.insert(pubkey)
            knownMisses.removeValue(forKey: pubkey)
            touch(pubkey)
        }

        for pubkey in missed where newProfiles[pubkey] == nil {
            let normalized = normalizePubkey(pubkey)
            guard !normalized.isEmpty, !normalizedInserted.contains(normalized) else { continue }
            knownMisses[normalized] = now
        }

        pruneKnownMisses(now: now)
        pruneOverflowIfNeeded()

        if !persisted.isEmpty {
            await snapshotStore.putMany(entries: persisted)
        }
    }

    func setPriorityPubkeys(_ pubkeys: Set<String>) {
        priorityPubkeys = Set(
            pubkeys
                .map(normalizePubkey)
                .filter { !$0.isEmpty }
        )

        for pubkey in priorityPubkeys where profiles[pubkey] != nil {
            touch(pubkey)
        }

        pruneOverflowIfNeeded()
    }

    private func touch(_ pubkey: String) {
        recency.removeAll(where: { $0 == pubkey })
        recency.append(pubkey)
    }

    private func normalizePubkey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isKnownMissStillValid(_ pubkey: String, now: Date) -> Bool {
        guard let knownAt = knownMisses[pubkey] else { return false }
        if now.timeIntervalSince(knownAt) < missTTL {
            return true
        }
        knownMisses.removeValue(forKey: pubkey)
        return false
    }

    private func pruneKnownMisses(now: Date) {
        knownMisses = knownMisses.filter { _, date in
            now.timeIntervalSince(date) < missTTL
        }
    }

    private func pruneOverflowIfNeeded() {
        guard recency.count > maxEntries else { return }

        var overflow = recency.count - maxEntries
        var retained: [String] = []
        retained.reserveCapacity(maxEntries)

        for pubkey in recency {
            if overflow > 0, !priorityPubkeys.contains(pubkey) {
                profiles.removeValue(forKey: pubkey)
                overflow -= 1
            } else {
                retained.append(pubkey)
            }
        }

        if overflow > 0 {
            for pubkey in retained.prefix(overflow) {
                profiles.removeValue(forKey: pubkey)
            }
            retained.removeFirst(overflow)
        }

        recency = retained
    }
}
