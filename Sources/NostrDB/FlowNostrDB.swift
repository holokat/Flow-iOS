import Foundation
import NostrSDK

struct FlowNostrDBDiagnostics: Equatable, Sendable {
    var isOpen: Bool = false
    var databaseDirectoryExists: Bool = false
    var databasePath: String = ""
    var lastOpenError: String?
    var openMapsizeBytes: Int64 = 0
    var lastAttemptedMapsizeBytes: Int64 = 0
    var failedOpenAttempts: [FlowNostrDBOpenAttemptFailure] = []
    var persistedEventCount: Int = 0
    var persistedProfileCount: Int = 0
    var sessionIngestedEventCount: Int = 0
    var sessionIngestedProfileCount: Int = 0
    var ingestCallCount: Int = 0
    var successfulIngestCallCount: Int = 0
    var eventLookupCount: Int = 0
    var profileLookupCount: Int = 0
    var followListLookupCount: Int = 0
    var queryCount: Int = 0
    var recentOverlayEventCount: Int = 0
    var recentReplaceableOverlayCount: Int = 0
    var diskUsageBytes: Int64 = 0

    var hotIndexEventCount: Int { persistedEventCount }
    var hotIndexProfileCount: Int { persistedProfileCount }
}

struct FlowNostrDBOpenAttemptFailure: Equatable, Sendable {
    let mapsizeBytes: Int64
    let errorMessage: String
}

struct FlowNostrDBProfileSearchResult: Equatable, Sendable {
    let pubkey: String
    let profile: NostrProfile
    let createdAt: Int
}

final class FlowNostrDB: @unchecked Sendable {
    static let shared = FlowNostrDB()

    typealias OpenDatabase = @Sendable (_ path: String, _ ingestThreads: Int32, _ mapsize: size_t, _ writerScratchBufferSize: Int32, _ flags: Int32) -> UnsafeMutableRawPointer?
    typealias LastOpenError = @Sendable () -> String?

    private struct ReplaceableKey: Hashable {
        let authorPubkey: String
        let kind: Int
    }

    private let queue = DispatchQueue(label: "com.21media.haloapp.nostrdb")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let fileManager: FileManager
    private let databaseDirectoryURL: URL
    private let ingestThreadCount: Int
    private let initialMapsize: size_t
    private let minimumMapsize: size_t
    private let maxMapUsageBeforeRebuild: Double
    private let writerScratchBufferSize: Int32
    private let flags: Int32
    private let openDatabase: OpenDatabase
    private let lastOpenError: LastOpenError
    private let eventOverlayLimit = 4_000
    private let replaceableOverlayLimit = 2_000
    private let sessionEventTrackingLimit = 8_000
    private let sessionProfileTrackingLimit = 2_000

    private var handle: UnsafeMutableRawPointer?
    private var openMapsize: size_t = 0
    private var lastAttemptedMapsize: size_t = 0
    private var recentEventsByID: [String: NostrEvent] = [:]
    private var recentEventOrder: [String] = []
    private var recentReplaceableEventsByKey: [ReplaceableKey: NostrEvent] = [:]
    private var recentReplaceableOrder: [ReplaceableKey] = []
    private var sessionIngestedEventCount = 0
    private var sessionIngestedProfileCount = 0
    private var recentSessionEventIDs = Set<String>()
    private var recentSessionEventOrder: [String] = []
    private var recentSessionProfilePubkeys = Set<String>()
    private var recentSessionProfileOrder: [String] = []
    private var ingestCallCount = 0
    private var successfulIngestCallCount = 0
    private var eventLookupCount = 0
    private var profileLookupCount = 0
    private var followListLookupCount = 0
    private var queryCount = 0
    private var lastOpenErrorMessage: String?
    private var failedOpenAttempts: [FlowNostrDBOpenAttemptFailure] = []

    init(
        fileManager: FileManager = .default,
        initialMapsize: size_t = size_t(32) * 1024 * 1024 * 1024,
        minimumMapsize: size_t = size_t(768) * 1024 * 1024,
        maxMapUsageBeforeRebuild: Double = 0.72,
        openDatabase: @escaping OpenDatabase = { path, ingestThreads, mapsize, writerScratchBufferSize, flags in
            path.withCString { rawPath in
                flow_ndb_open(
                    rawPath,
                    ingestThreads,
                    mapsize,
                    writerScratchBufferSize,
                    flags
                )
            }
        },
        lastOpenError: @escaping LastOpenError = {
            guard let rawError = flow_ndb_last_open_error(),
                  rawError.pointee != 0 else {
                return nil
            }
            return String(cString: rawError)
        }
    ) {
        self.fileManager = fileManager
        self.databaseDirectoryURL = Self.resolveDatabaseDirectoryURL(fileManager: fileManager)
        self.ingestThreadCount = max(ProcessInfo.processInfo.processorCount - 1, 1)
        self.initialMapsize = max(initialMapsize, minimumMapsize)
        self.minimumMapsize = minimumMapsize
        self.maxMapUsageBeforeRebuild = min(
            max(maxMapUsageBeforeRebuild, Double.leastNonzeroMagnitude),
            0.95
        )
        self.writerScratchBufferSize = 2 * 1024 * 1024
        self.flags = Int32(FLOW_NDB_FLAG_NO_NOTE_BLOCKS | FLOW_NDB_FLAG_NO_STATS)
        self.openDatabase = openDatabase
        self.lastOpenError = lastOpenError
    }

    deinit {
        if let handle {
            flow_ndb_close(handle)
        }
    }

    func ingest(events: [NostrEvent]) -> Bool {
        guard !events.isEmpty else { return true }

        return queue.sync {
            ingestCallCount += 1
            guard openIfNeeded() else { return false }

            let ingestedAny = ingestLocked(events: events, updateSessionCounters: true)

            if ingestedAny {
                successfulIngestCallCount += 1
            }
            return ingestedAny
        }
    }

    func requiresRebuild() -> Bool {
        queue.sync {
            guard openIfNeeded() else { return false }
            return shouldRebuildLocked()
        }
    }

    func rebuild(retaining events: [NostrEvent]) -> Bool {
        let retainedEvents = deduplicated(events)
        guard !retainedEvents.isEmpty else { return false }

        return queue.sync {
            guard rebuildLocked(retaining: retainedEvents) else { return false }
            return !shouldRebuildLocked()
        }
    }

    func events(ids: [String]) -> [String: NostrEvent]? {
        let normalizedIDs = normalizedEventIDs(from: ids)
        guard !normalizedIDs.isEmpty else { return [:] }

        return queue.sync {
            guard openIfNeeded() else { return nil }
            eventLookupCount += normalizedIDs.count

            var resolved: [String: NostrEvent] = [:]
            resolved.reserveCapacity(normalizedIDs.count)

            for eventID in normalizedIDs {
                if let event = recentEventsByID[eventID] {
                    resolved[eventID] = event
                    continue
                }

                guard let idData = Self.decodeHex(eventID) else { continue }

                let event: NostrEvent? = idData.withUnsafeBytes { rawBuffer in
                    guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return nil
                    }

                    var length: Int32 = 0
                    guard let jsonPointer = flow_ndb_copy_note_json(handle, bytes, &length),
                          length > 0 else {
                        return nil
                    }
                    defer { flow_ndb_free_string(jsonPointer) }

                    let data = Data(bytes: jsonPointer, count: Int(length))
                    return try? decoder.decode(NostrEvent.self, from: data)
                }

                if let event {
                    resolved[eventID] = event
                }
            }

            return resolved
        }
    }

    func profile(pubkey: String) -> NostrProfile? {
        profiles(pubkeys: [pubkey])?[normalizeHexIdentifier(pubkey)]
    }

    func profiles(pubkeys: [String]) -> [String: NostrProfile]? {
        let normalizedPubkeys = normalizedHexIdentifiers(from: pubkeys)
        guard !normalizedPubkeys.isEmpty else { return [:] }

        return queue.sync {
            guard openIfNeeded() else { return nil }
            profileLookupCount += normalizedPubkeys.count

            var resolved: [String: NostrProfile] = [:]
            resolved.reserveCapacity(normalizedPubkeys.count)

            for pubkey in normalizedPubkeys {
                if let event = recentReplaceableEvent(authorPubkey: pubkey, kind: 0),
                   let profile = NostrProfile.decode(from: event.content) {
                    resolved[pubkey] = profile
                    continue
                }

                guard let pubkeyData = Self.decodeHex(pubkey) else { continue }

                let profile: NostrProfile? = pubkeyData.withUnsafeBytes { rawBuffer in
                    guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return nil
                    }
                    return decodeProfile(pubkeyBytes: bytes)
                }

                if let profile {
                    resolved[pubkey] = profile
                }
            }

            return resolved
        }
    }

    func searchProfiles(query: String, limit: Int) -> [FlowNostrDBProfileSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, limit > 0 else { return [] }

        return queue.sync {
            guard openIfNeeded() else { return [] }
            queryCount += 1

            let rows: [ProfileSearchRow] = normalizedQuery.withCString { rawQuery in
                var length: Int32 = 0
                guard let jsonPointer = flow_ndb_copy_profile_search_json(handle, rawQuery, Int32(limit), &length),
                      length > 0 else {
                    return []
                }
                defer { flow_ndb_free_string(jsonPointer) }

                let data = Data(bytes: jsonPointer, count: Int(length))
                return (try? decoder.decode([ProfileSearchRow].self, from: data)) ?? []
            }

            return rows.compactMap { row in
                let pubkey = normalizeHexIdentifier(row.pubkey)
                guard !pubkey.isEmpty else { return nil }
                return FlowNostrDBProfileSearchResult(
                    pubkey: pubkey,
                    profile: row.profile,
                    createdAt: row.createdAt
                )
            }
        }
    }

    func followListSnapshot(pubkey: String) -> FollowListSnapshot? {
        let normalized = normalizeHexIdentifier(pubkey)
        guard !normalized.isEmpty else { return nil }

        return queue.sync {
            guard openIfNeeded() else { return nil }
            followListLookupCount += 1

            if let event = recentReplaceableEvent(authorPubkey: normalized, kind: 3) {
                return Self.makeFollowListSnapshot(from: event)
            }

            guard let pubkeyData = Self.decodeHex(normalized) else { return nil }

            return pubkeyData.withUnsafeBytes { rawBuffer in
                guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return nil
                }
                return decodeLatestEvent(authorPubkeyBytes: bytes, kind: 3)
                    .flatMap(Self.makeFollowListSnapshot(from:))
            }
        }
    }

    func queryEvents(filter: NostrFilter) -> [NostrEvent]? {
        queryEvents(filters: [filter])
    }

    func queryEvents(filters: [NostrFilter]) -> [NostrEvent]? {
        let usableFilters = filters.filter { !$0.jsonObject.isEmpty }
        guard !usableFilters.isEmpty else { return [] }

        return queue.sync {
            guard openIfNeeded() else { return nil }
            queryCount += usableFilters.count

            var combinedEvents: [NostrEvent] = []
            combinedEvents.reserveCapacity(usableFilters.count * 32)

            for filter in usableFilters {
                combinedEvents.append(contentsOf: queryEventsLocked(filter: filter))
            }

            let overlayEvents = recentEventOrder.compactMap { eventID in
                recentEventsByID[eventID]
            }
            combinedEvents.append(contentsOf: overlayEvents.filter { event in
                usableFilters.contains { filter in
                    Self.event(event, matches: filter)
                }
            })

            return finalizedQueryResults(from: combinedEvents, filters: usableFilters)
        }
    }

    func diagnosticsSnapshot() -> FlowNostrDBDiagnostics {
        queue.sync {
            let opened = openIfNeeded()
            let persistedEventCount = opened ? Int(flow_ndb_note_count(handle)) : 0
            let persistedProfileCount = opened ? Int(flow_ndb_profile_count(handle)) : 0
            var isDirectory = ObjCBool(false)
            let databaseDirectoryExists = fileManager.fileExists(
                atPath: databaseDirectoryURL.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue

            return FlowNostrDBDiagnostics(
                isOpen: opened,
                databaseDirectoryExists: databaseDirectoryExists,
                databasePath: databaseDirectoryURL.path,
                lastOpenError: lastOpenErrorMessage,
                openMapsizeBytes: Int64(openMapsize),
                lastAttemptedMapsizeBytes: Int64(lastAttemptedMapsize),
                failedOpenAttempts: failedOpenAttempts,
                persistedEventCount: persistedEventCount,
                persistedProfileCount: persistedProfileCount,
                sessionIngestedEventCount: sessionIngestedEventCount,
                sessionIngestedProfileCount: sessionIngestedProfileCount,
                ingestCallCount: ingestCallCount,
                successfulIngestCallCount: successfulIngestCallCount,
                eventLookupCount: eventLookupCount,
                profileLookupCount: profileLookupCount,
                followListLookupCount: followListLookupCount,
                queryCount: queryCount,
                recentOverlayEventCount: recentEventOrder.count,
                recentReplaceableOverlayCount: recentReplaceableOrder.count,
                diskUsageBytes: diskUsageBytes()
            )
        }
    }

    func resetSessionDiagnostics() {
        queue.sync {
            sessionIngestedEventCount = 0
            sessionIngestedProfileCount = 0
            recentSessionEventIDs.removeAll(keepingCapacity: false)
            recentSessionEventOrder.removeAll(keepingCapacity: false)
            recentSessionProfilePubkeys.removeAll(keepingCapacity: false)
            recentSessionProfileOrder.removeAll(keepingCapacity: false)
            ingestCallCount = 0
            successfulIngestCallCount = 0
            eventLookupCount = 0
            profileLookupCount = 0
            followListLookupCount = 0
            queryCount = 0
        }
    }

    private func openIfNeeded() -> Bool {
        if handle != nil {
            lastOpenErrorMessage = nil
            return true
        }

        do {
            try fileManager.createDirectory(
                at: databaseDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            lastOpenErrorMessage = error.localizedDescription
            return false
        }

        let path = databaseDirectoryURL.path
        var attemptedMapsizes: [size_t] = []
        var candidateMapsize = initialMapsize
        failedOpenAttempts.removeAll(keepingCapacity: true)

        while candidateMapsize >= minimumMapsize {
            lastAttemptedMapsize = candidateMapsize
            attemptedMapsizes.append(candidateMapsize)

            if let openedHandle = openDatabase(
                path,
                Int32(ingestThreadCount),
                candidateMapsize,
                writerScratchBufferSize,
                flags
            ) {
                handle = openedHandle
                openMapsize = candidateMapsize
                lastOpenErrorMessage = nil
                return true
            }

            failedOpenAttempts.append(
                FlowNostrDBOpenAttemptFailure(
                    mapsizeBytes: Int64(candidateMapsize),
                    errorMessage: currentOpenErrorMessage()
                )
            )
            candidateMapsize /= 2
        }

        openMapsize = 0
        let attemptedDescription = attemptedMapsizes
            .map { Self.mapsizeDescription(bytes: Int64($0)) }
            .joined(separator: ", ")
        let failureDetails = failedOpenAttempts
            .map { "\(Self.mapsizeDescription(bytes: $0.mapsizeBytes)): \($0.errorMessage)" }
            .joined(separator: "; ")
        lastOpenErrorMessage = [
            "Failed to open nostrdb at \(path) after trying mapsizes: \(attemptedDescription)",
            failureDetails.isEmpty ? nil : failureDetails
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
        return false
    }

    private static func mapsizeDescription(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    private func currentOpenErrorMessage() -> String {
        let message = lastOpenError()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else {
            return "flow_ndb_open returned nil"
        }
        return message
    }

    private static func resolveDatabaseDirectoryURL(fileManager: FileManager) -> URL {
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport.appendingPathComponent("FlowNostrDB", isDirectory: true)
        }

        if let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let libraryDirectory = cachesDirectory.deletingLastPathComponent()
            return libraryDirectory
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("FlowNostrDB", isDirectory: true)
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FlowNostrDB", isDirectory: true)
    }

    private func remember(event: NostrEvent) {
        remember(event: event, updateSessionCounters: true)
    }

    private func remember(event: NostrEvent, updateSessionCounters: Bool) {
        let eventID = normalizeHexIdentifier(event.id)
        guard !eventID.isEmpty else { return }

        if updateSessionCounters {
            recordSessionEvent(eventID)
        }

        if recentEventsByID[eventID] == nil {
            recentEventOrder.append(eventID)
        }
        recentEventsByID[eventID] = event

        let overflow = recentEventOrder.count - eventOverlayLimit
        if overflow > 0 {
            for _ in 0..<overflow {
                let removedID = recentEventOrder.removeFirst()
                recentEventsByID.removeValue(forKey: removedID)
            }
        }

        rememberReplaceable(event: event, updateSessionCounters: updateSessionCounters)
    }

    private func encodedEventJSON(_ event: NostrEvent) -> String? {
        guard let data = try? encoder.encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct ProfileSearchRow: Decodable {
        let pubkey: String
        let createdAt: Int
        let profile: NostrProfile

        private enum CodingKeys: String, CodingKey {
            case pubkey
            case createdAt = "created_at"
            case profile
        }
    }

    private func rememberReplaceable(event: NostrEvent, updateSessionCounters: Bool) {
        guard Self.isReplaceableKind(event.kind) else { return }

        let authorPubkey = normalizeHexIdentifier(event.pubkey)
        guard !authorPubkey.isEmpty else { return }

        if updateSessionCounters, event.kind == 0 {
            recordSessionProfile(authorPubkey)
        }

        let key = ReplaceableKey(authorPubkey: authorPubkey, kind: event.kind)
        if let existing = recentReplaceableEventsByKey[key],
           !Self.isNewerReplaceableEvent(event, than: existing) {
            return
        }

        if recentReplaceableEventsByKey[key] == nil {
            recentReplaceableOrder.append(key)
        }
        recentReplaceableEventsByKey[key] = event

        let overflow = recentReplaceableOrder.count - replaceableOverlayLimit
        if overflow > 0 {
            for _ in 0..<overflow {
                let removedKey = recentReplaceableOrder.removeFirst()
                recentReplaceableEventsByKey.removeValue(forKey: removedKey)
            }
        }
    }

    private func recentReplaceableEvent(authorPubkey: String, kind: Int) -> NostrEvent? {
        recentReplaceableEventsByKey[ReplaceableKey(authorPubkey: authorPubkey, kind: kind)]
    }

    private func recordSessionEvent(_ eventID: String) {
        guard recentSessionEventIDs.insert(eventID).inserted else { return }
        sessionIngestedEventCount += 1
        recentSessionEventOrder.append(eventID)

        let overflow = recentSessionEventOrder.count - sessionEventTrackingLimit
        guard overflow > 0 else { return }

        for _ in 0..<overflow {
            let removedID = recentSessionEventOrder.removeFirst()
            recentSessionEventIDs.remove(removedID)
        }
    }

    private func recordSessionProfile(_ pubkey: String) {
        guard recentSessionProfilePubkeys.insert(pubkey).inserted else { return }
        sessionIngestedProfileCount += 1
        recentSessionProfileOrder.append(pubkey)

        let overflow = recentSessionProfileOrder.count - sessionProfileTrackingLimit
        guard overflow > 0 else { return }

        for _ in 0..<overflow {
            let removedPubkey = recentSessionProfileOrder.removeFirst()
            recentSessionProfilePubkeys.remove(removedPubkey)
        }
    }

    private func ingestLocked(events: [NostrEvent], updateSessionCounters: Bool) -> Bool {
        var ingestedAny = false

        for event in events {
            remember(event: event, updateSessionCounters: updateSessionCounters)

            guard let payload = encodedEventJSON(event) else { continue }
            let ok = payload.withCString { raw in
                flow_ndb_ingest_note_json(handle, raw, Int32(payload.utf8.count))
            }
            ingestedAny = ingestedAny || ok != 0
        }

        return ingestedAny
    }

    private func shouldRebuildLocked() -> Bool {
        guard openMapsize > 0 else { return false }
        let usageThreshold = Int64(Double(openMapsize) * maxMapUsageBeforeRebuild)
        guard usageThreshold > 0 else { return false }
        return diskUsageBytes() >= usageThreshold
    }

    private func rebuildLocked(retaining events: [NostrEvent]) -> Bool {
        let retainedEvents = events.sorted(by: Self.rebuildSort)

        if let handle {
            flow_ndb_close(handle)
            self.handle = nil
        }

        openMapsize = 0
        lastAttemptedMapsize = 0
        lastOpenErrorMessage = nil
        failedOpenAttempts.removeAll(keepingCapacity: false)
        recentEventsByID.removeAll(keepingCapacity: false)
        recentEventOrder.removeAll(keepingCapacity: false)
        recentReplaceableEventsByKey.removeAll(keepingCapacity: false)
        recentReplaceableOrder.removeAll(keepingCapacity: false)

        do {
            if fileManager.fileExists(atPath: databaseDirectoryURL.path) {
                try fileManager.removeItem(at: databaseDirectoryURL)
            }
            try fileManager.createDirectory(
                at: databaseDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            lastOpenErrorMessage = "Failed to reset FlowNostrDB directory: \(error.localizedDescription)"
            return false
        }

        guard openIfNeeded() else { return false }
        return ingestLocked(events: retainedEvents, updateSessionCounters: false)
    }

    private func decodeProfile(pubkeyBytes: UnsafePointer<UInt8>) -> NostrProfile? {
        var length: Int32 = 0
        guard let jsonPointer = flow_ndb_copy_profile_json(handle, pubkeyBytes, &length),
              length > 0 else {
            return nil
        }
        defer { flow_ndb_free_string(jsonPointer) }

        let data = Data(bytes: jsonPointer, count: Int(length))
        return try? decoder.decode(NostrProfile.self, from: data)
    }

    private func decodeLatestEvent(authorPubkeyBytes: UnsafePointer<UInt8>, kind: Int) -> NostrEvent? {
        guard let kind = UInt32(exactly: kind) else { return nil }

        var length: Int32 = 0
        guard let jsonPointer = flow_ndb_copy_latest_note_json_for_pubkey_kind(handle, authorPubkeyBytes, kind, &length),
              length > 0 else {
            return nil
        }
        defer { flow_ndb_free_string(jsonPointer) }

        let data = Data(bytes: jsonPointer, count: Int(length))
        return try? decoder.decode(NostrEvent.self, from: data)
    }

    private func queryEventsLocked(filter: NostrFilter) -> [NostrEvent] {
        guard let filterJSONString = encodedFilterJSON(filter) else { return [] }

        var length: Int32 = 0
        guard let jsonPointer = filterJSONString.withCString({ raw in
            flow_ndb_copy_note_json_array_for_filter_json(handle, raw, Int32(filterJSONString.utf8.count), &length)
        }), length >= 0 else {
            return []
        }
        defer { flow_ndb_free_string(jsonPointer) }

        let data = Data(bytes: jsonPointer, count: Int(length))
        return (try? decoder.decode([NostrEvent].self, from: data)) ?? []
    }

    private func encodedFilterJSON(_ filter: NostrFilter) -> String? {
        let object = filter.jsonObject
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func finalizedQueryResults(from events: [NostrEvent], filters: [NostrFilter]) -> [NostrEvent] {
        let filteredEvents = deduplicated(events).filter { event in
            filters.contains { filter in
                Self.event(event, matches: filter)
            }
        }

        let sortedEvents = filteredEvents.sorted(by: Self.timelineSort)
        let limit = filters.compactMap(\.limit).max() ?? sortedEvents.count
        return Array(sortedEvents.prefix(limit))
    }

    private func deduplicated(_ events: [NostrEvent]) -> [NostrEvent] {
        var seen = Set<String>()
        var uniqueEvents: [NostrEvent] = []
        uniqueEvents.reserveCapacity(events.count)

        for event in events {
            let eventID = normalizeHexIdentifier(event.id)
            guard !eventID.isEmpty else { continue }
            guard seen.insert(eventID).inserted else { continue }
            uniqueEvents.append(event)
        }

        return uniqueEvents
    }

    private func diskUsageBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: databaseDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            totalBytes += Int64(values.fileSize ?? 0)
        }

        return totalBytes
    }

    private func normalizedEventIDs(from ids: [String]) -> [String] {
        normalizedHexIdentifiers(from: ids)
    }

    private func normalizedHexIdentifiers(from values: [String]) -> [String] {
        Array(
            Set(
                values.map(normalizeHexIdentifier).filter { !$0.isEmpty }
            )
        )
    }

    private func normalizeHexIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count == 64, value.count.isMultiple(of: 2) else { return nil }

        var bytes = Data(capacity: value.count / 2)
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            guard let byte = UInt8(value[cursor..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            cursor = next
        }

        return bytes
    }

    private static func isReplaceableKind(_ kind: Int) -> Bool {
        kind == 0 || kind == 3 || (10_000..<20_000).contains(kind) || (30_000..<40_000).contains(kind)
    }

    private static func isNewerReplaceableEvent(_ lhs: NostrEvent, than rhs: NostrEvent) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.lowercased() > rhs.id.lowercased()
    }

    private static func timelineSort(lhs: NostrEvent, rhs: NostrEvent) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.lowercased() > rhs.id.lowercased()
    }

    private static func rebuildSort(lhs: NostrEvent, rhs: NostrEvent) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.lowercased() < rhs.id.lowercased()
    }

    private static func event(_ event: NostrEvent, matches filter: NostrFilter) -> Bool {
        if let ids = filter.ids, !ids.isEmpty {
            let allowed = Set(ids.map(Self.normalizeIdentifier))
            guard allowed.contains(Self.normalizeIdentifier(event.id)) else { return false }
        }

        if let authors = filter.authors, !authors.isEmpty {
            let allowed = Set(authors.map(Self.normalizeIdentifier))
            guard allowed.contains(Self.normalizeIdentifier(event.pubkey)) else { return false }
        }

        if let kinds = filter.kinds, !kinds.isEmpty {
            guard kinds.contains(event.kind) else { return false }
        }

        if let since = filter.since, event.createdAt < since {
            return false
        }

        if let until = filter.until, event.createdAt > until {
            return false
        }

        if let tagFilters = filter.tagFilters, !tagFilters.isEmpty {
            for (rawTag, values) in tagFilters {
                let normalizedTag = rawTag
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "#", with: "")
                    .lowercased()
                let allowedValues = Set(values.map(Self.normalizeIdentifier))

                let matchesTag = event.tags.contains { tag in
                    guard let tagName = tag.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                          tagName == normalizedTag,
                          tag.count > 1 else {
                        return false
                    }
                    return allowedValues.contains(Self.normalizeIdentifier(tag[1]))
                }

                guard matchesTag else { return false }
            }
        }

        if let search = filter.search?.trimmingCharacters(in: .whitespacesAndNewlines),
           !search.isEmpty {
            let normalizedQuery = search.lowercased()
            let searchableParts = [event.content, event.id, event.pubkey] + event.tags.flatMap { $0 }
            let searchableText = searchableParts.joined(separator: " ").lowercased()
            guard searchableText.contains(normalizedQuery) else { return false }
        }

        return true
    }

    private static func normalizeIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeFollowListSnapshot(from event: NostrEvent) -> FollowListSnapshot? {
        guard event.kind == 3 else { return nil }
        return FollowListSnapshot(content: event.content, tags: event.tags)
    }
}
