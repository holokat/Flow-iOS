import Foundation
import SQLite3

private let SQLITE_TRANSIENT_ARCHIVE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct EventArchiveBudget: Sendable {
    let archiveSoftLimitBytes: Int64
    let archiveHardLimitBytes: Int64
    let hotIndexTargetEventCount: Int
    let minimumFreeDiskBytes: Int64

    init(
        archiveSoftLimitBytes: Int64 = 3 * 1_024 * 1_024 * 1_024,
        archiveHardLimitBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        hotIndexTargetEventCount: Int = 1_000_000,
        minimumFreeDiskBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    ) {
        let normalizedSoftLimit = max(archiveSoftLimitBytes, 1)
        let normalizedHardLimit = max(archiveHardLimitBytes, normalizedSoftLimit)
        self.archiveSoftLimitBytes = normalizedSoftLimit
        self.archiveHardLimitBytes = normalizedHardLimit
        self.hotIndexTargetEventCount = max(hotIndexTargetEventCount, 1)
        self.minimumFreeDiskBytes = max(minimumFreeDiskBytes, 0)
    }
}

actor EventArchiveStore {
    struct Diagnostics: Equatable, Sendable {
        var archiveCount: Int = 0
        var archiveBytes: Int64 = 0
        var pinnedFeedEventCount: Int = 0
    }

    private let fileManager: FileManager
    private let budget: EventArchiveBudget
    private let databaseURL: URL
    private let availableFreeDiskBytesProvider: (@Sendable (URL) -> Int64)?
    private let maintenanceObserver: @Sendable () -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var database: OpaquePointer?

    init(
        fileManager: FileManager = .default,
        budget: EventArchiveBudget = EventArchiveBudget(),
        availableFreeDiskBytesProvider: (@Sendable (URL) -> Int64)? = nil,
        maintenanceObserver: @escaping @Sendable () -> Void = {}
    ) {
        self.fileManager = fileManager
        self.budget = budget
        self.databaseURL = Self.resolveDatabaseURL(fileManager: fileManager)
        self.availableFreeDiskBytesProvider = availableFreeDiskBytesProvider
        self.maintenanceObserver = maintenanceObserver
        self.database = Self.openDatabase(at: databaseURL, fileManager: fileManager)
        Self.createSchema(in: database)
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func store(events: [NostrEvent]) async {
        guard !events.isEmpty else { return }
        persistArchivedEvents(events)
        pruneIfNeeded()
    }

    func storeRecentFeed(key: String, events: [NostrEvent]) async {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        persistArchivedEvents(events)
        replaceRecentFeed(key: key, events: events)
        pruneIfNeeded()
    }

    func recentFeedEventIDs(key: String) async -> [String] {
        guard let statement = prepareStatement(
            """
            SELECT event_id
            FROM recent_feed_events
            WHERE feed_key = ?
            ORDER BY position ASC;
            """
        ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bindText(key, to: statement, index: 1)

        var eventIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let eventID = columnText(statement, column: 0) else { continue }
            eventIDs.append(eventID)
        }

        return eventIDs
    }

    func prioritizedPinnedEventIDs(limit: Int) async -> [String] {
        let cappedLimit = max(limit, 0)
        guard cappedLimit > 0,
              let statement = prepareStatement(
                  """
                  SELECT event_id
                  FROM recent_feed_events
                  ORDER BY stored_at DESC, position ASC;
                  """
              ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var ids: [String] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, ids.count < cappedLimit {
            guard let eventID = columnText(statement, column: 0),
                  seen.insert(eventID).inserted else {
                continue
            }
            ids.append(eventID)
        }
        return ids
    }

    func allPinnedEventIDs() async -> Set<String> {
        guard let statement = prepareStatement(
            "SELECT DISTINCT event_id FROM recent_feed_events;"
        ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var ids = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let eventID = columnText(statement, column: 0) else { continue }
            ids.insert(eventID)
        }
        return ids
    }

    func events(ids: [String]) async -> [String: NostrEvent] {
        let normalizedIDs = Self.normalizedIDs(ids)
        guard !normalizedIDs.isEmpty else { return [:] }

        var decoded: [String: NostrEvent] = [:]
        for chunk in normalizedIDs.chunked(into: 250) {
            guard let statement = prepareStatement(
                """
                SELECT id, event_json
                FROM archived_events
                WHERE id IN (\(sqlPlaceholders(count: chunk.count)));
                """
            ) else {
                continue
            }

            defer { sqlite3_finalize(statement) }

            for (index, eventID) in chunk.enumerated() {
                bindText(eventID, to: statement, index: Int32(index + 1))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let eventID = columnText(statement, column: 0),
                      let event = decodeEvent(from: statement, column: 1) else {
                    continue
                }
                decoded[eventID] = event
            }
        }

        return decoded
    }

    func recentEvents(limit: Int, pinnedIDs: Set<String>) async -> [NostrEvent] {
        let cappedLimit = max(limit, 0)
        guard cappedLimit > 0 else { return [] }

        struct RetainedRecord {
            let event: NostrEvent
            let seenAt: Double
            let isPinned: Bool
        }

        let normalizedPinnedIDs = Self.normalizedIDs(Array(pinnedIDs))
        let normalizedPinnedSet = Set(normalizedPinnedIDs)
        var retainedByID: [String: RetainedRecord] = [:]

        for chunk in normalizedPinnedIDs.chunked(into: 250) {
            guard let statement = prepareStatement(
                """
                SELECT id, seen_at, event_json
                FROM archived_events
                WHERE id IN (\(sqlPlaceholders(count: chunk.count)));
                """
            ) else {
                continue
            }

            defer { sqlite3_finalize(statement) }

            for (index, eventID) in chunk.enumerated() {
                bindText(eventID, to: statement, index: Int32(index + 1))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let eventID = columnText(statement, column: 0),
                      let event = decodeEvent(from: statement, column: 2) else {
                    continue
                }

                retainedByID[eventID] = RetainedRecord(
                    event: event,
                    seenAt: sqlite3_column_double(statement, 1),
                    isPinned: true
                )
            }
        }

        let remainingLimit = max(cappedLimit - retainedByID.count, 0)
        if remainingLimit > 0,
           let statement = prepareStatement(
               """
               SELECT id, seen_at, event_json
               FROM archived_events
               ORDER BY seen_at DESC, created_at DESC, id DESC
               LIMIT ?;
               """
           ) {
            sqlite3_bind_int64(statement, 1, Int64(cappedLimit + normalizedPinnedIDs.count))
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let eventID = columnText(statement, column: 0),
                      retainedByID[eventID] == nil,
                      let event = decodeEvent(from: statement, column: 2) else {
                    continue
                }

                retainedByID[eventID] = RetainedRecord(
                    event: event,
                    seenAt: sqlite3_column_double(statement, 1),
                    isPinned: normalizedPinnedSet.contains(eventID)
                )
                if retainedByID.count >= cappedLimit {
                    break
                }
            }
        }

        return retainedByID.values.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned
            }
            if $0.seenAt != $1.seenAt {
                return $0.seenAt > $1.seenAt
            }
            if $0.event.createdAt != $1.event.createdAt {
                return $0.event.createdAt > $1.event.createdAt
            }
            return $0.event.id.lowercased() > $1.event.id.lowercased()
        }.map(\.event)
    }

    func diagnosticsSnapshot() async -> Diagnostics {
        syncDiagnosticsSnapshot()
    }

    private func persistArchivedEvents(_ events: [NostrEvent]) {
        guard database != nil else { return }

        withTransaction {
            guard let statement = prepareStatement(
                """
                INSERT OR REPLACE INTO archived_events (
                    id,
                    pubkey,
                    kind,
                    created_at,
                    seen_at,
                    payload_bytes,
                    event_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            ) else {
                return
            }
            defer { sqlite3_finalize(statement) }

            let seenAt = Date().timeIntervalSince1970
            for event in events {
                guard let payload = try? encoder.encode(event) else { continue }

                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)

                bindText(event.id.lowercased(), to: statement, index: 1)
                bindText(event.pubkey, to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, Int64(event.kind))
                sqlite3_bind_int64(statement, 4, Int64(event.createdAt))
                sqlite3_bind_double(statement, 5, seenAt)
                sqlite3_bind_int64(statement, 6, Int64(payload.count))
                _ = payload.withUnsafeBytes { rawBuffer in
                    sqlite3_bind_blob(
                        statement,
                        7,
                        rawBuffer.baseAddress,
                        Int32(rawBuffer.count),
                        SQLITE_TRANSIENT_ARCHIVE
                    )
                }

                sqlite3_step(statement)
            }
        }
    }

    private func replaceRecentFeed(key: String, events: [NostrEvent]) {
        guard database != nil else { return }

        withTransaction {
            guard let deleteStatement = prepareStatement(
                "DELETE FROM recent_feed_events WHERE feed_key = ?;"
            ) else {
                return
            }
            bindText(key, to: deleteStatement, index: 1)
            sqlite3_step(deleteStatement)
            sqlite3_finalize(deleteStatement)

            guard !events.isEmpty,
                  let insertStatement = prepareStatement(
                      """
                      INSERT OR REPLACE INTO recent_feed_events (
                          feed_key,
                          position,
                          event_id,
                          stored_at
                      ) VALUES (?, ?, ?, ?);
                      """
                  ) else {
                return
            }
            defer { sqlite3_finalize(insertStatement) }

            let storedAt = Date().timeIntervalSince1970
            for (index, event) in events.enumerated() {
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)

                bindText(key, to: insertStatement, index: 1)
                sqlite3_bind_int64(insertStatement, 2, Int64(index))
                bindText(event.id.lowercased(), to: insertStatement, index: 3)
                sqlite3_bind_double(insertStatement, 4, storedAt)

                sqlite3_step(insertStatement)
            }
        }
    }

    private func pruneIfNeeded() {
        guard database != nil else { return }

        var archiveFootprintBytes = syncArchiveFootprintBytes()
        var freeDiskBytes = availableFreeDiskBytes()
        guard archiveFootprintBytes > budget.archiveHardLimitBytes || freeDiskBytes < budget.minimumFreeDiskBytes else {
            return
        }

        checkpointArchive()

        archiveFootprintBytes = syncArchiveFootprintBytes()
        freeDiskBytes = availableFreeDiskBytes()

        guard archiveFootprintBytes > budget.archiveSoftLimitBytes || freeDiskBytes < budget.minimumFreeDiskBytes else {
            return
        }

        let batchLimit = suggestedPruneBatchLimit(archiveCount: syncArchiveEventCount())
        var protectionRelaxed = false

        while archiveFootprintBytes > budget.archiveSoftLimitBytes || freeDiskBytes < budget.minimumFreeDiskBytes {
            let deletedCount = deleteOldestPrunableEvents(
                limit: batchLimit,
                excludingPinnedRows: !protectionRelaxed
            )

            if deletedCount == 0 {
                guard !protectionRelaxed, hasPinnedArchivedEvents() else { break }
                protectionRelaxed = true
                continue
            }

            compactArchive()
            archiveFootprintBytes = syncArchiveFootprintBytes()
            freeDiskBytes = availableFreeDiskBytes()
        }
    }

    private func deleteOldestPrunableEvents(limit: Int, excludingPinnedRows: Bool) -> Int {
        let sql: String
        if excludingPinnedRows {
            sql =
                """
                WITH candidates AS (
                    SELECT archived_events.id
                    FROM archived_events
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM recent_feed_events
                        WHERE recent_feed_events.event_id = archived_events.id
                    )
                    ORDER BY archived_events.seen_at ASC, archived_events.created_at ASC, archived_events.id ASC
                    LIMIT ?
                )
                DELETE FROM archived_events
                WHERE id IN (SELECT id FROM candidates);
                """
        } else {
            sql =
                """
                WITH candidates AS (
                    SELECT archived_events.id
                    FROM archived_events
                    ORDER BY archived_events.seen_at ASC, archived_events.created_at ASC, archived_events.id ASC
                    LIMIT ?
                )
                DELETE FROM archived_events
                WHERE id IN (SELECT id FROM candidates);
                """
        }

        guard let statement = prepareStatement(sql),
              let database else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(max(limit, 1)))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            return 0
        }

        return Int(sqlite3_changes(database))
    }

    private func syncDiagnosticsSnapshot() -> Diagnostics {
        guard let statement = prepareStatement(
            """
            SELECT COUNT(*)
            FROM archived_events;
            """
        ) else {
            return Diagnostics()
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return Diagnostics()
        }

        return Diagnostics(
            archiveCount: Int(sqlite3_column_int64(statement, 0)),
            archiveBytes: syncArchiveFootprintBytes(),
            pinnedFeedEventCount: syncPinnedEventIDs().count
        )
    }

    private func syncPinnedEventIDs() -> Set<String> {
        guard let statement = prepareStatement(
            "SELECT DISTINCT event_id FROM recent_feed_events;"
        ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var ids = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let eventID = columnText(statement, column: 0) else { continue }
            ids.insert(eventID)
        }
        return ids
    }

    private func hasPinnedArchivedEvents() -> Bool {
        guard let statement = prepareStatement(
            """
            SELECT 1
            FROM archived_events
            WHERE EXISTS (
                SELECT 1
                FROM recent_feed_events
                WHERE recent_feed_events.event_id = archived_events.id
            )
            LIMIT 1;
            """
        ) else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func syncArchiveEventCount() -> Int {
        guard let statement = prepareStatement(
            """
            SELECT COUNT(*)
            FROM archived_events;
            """
        ) else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func availableFreeDiskBytes() -> Int64 {
        let directoryURL = databaseURL.deletingLastPathComponent()
        if let availableFreeDiskBytesProvider {
            return availableFreeDiskBytesProvider(directoryURL)
        }
        return Self.defaultAvailableFreeDiskBytes(at: directoryURL)
    }

    private func syncArchiveFootprintBytes() -> Int64 {
        let componentPaths = [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
        ]

        return componentPaths.reduce(into: Int64(0)) { total, path in
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else {
                return
            }
            total += size.int64Value
        }
    }

    private func checkpointArchive() {
        guard let database else { return }

        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    private func compactArchive() {
        guard let database else { return }

        maintenanceObserver()
        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_exec(database, "VACUUM;", nil, nil, nil)
        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    private func suggestedPruneBatchLimit(archiveCount: Int) -> Int {
        min(256, max(16, archiveCount / 8))
    }

    private static func defaultAvailableFreeDiskBytes(at directoryURL: URL) -> Int64 {
        guard let values = try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return .max
        }
        return Int64(capacity)
    }

    private static func resolveDatabaseURL(fileManager: FileManager) -> URL {
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent("FeedArchive", isDirectory: true)
                .appendingPathComponent("event-archive.sqlite", isDirectory: false)
        }

        if let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let libraryDirectory = cachesDirectory.deletingLastPathComponent()
            return libraryDirectory
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("FeedArchive", isDirectory: true)
                .appendingPathComponent("event-archive.sqlite", isDirectory: false)
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("event-archive.sqlite", isDirectory: false)
    }

    private static func openDatabase(at databaseURL: URL, fileManager: FileManager) -> OpaquePointer? {
        let directoryURL = databaseURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var database: OpaquePointer?
        if sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK {
            sqlite3_busy_timeout(database, 1_500)
            sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(database, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        } else {
            if let database {
                sqlite3_close_v2(database)
            }
            database = nil
        }

        return database
    }

    private static func createSchema(in database: OpaquePointer?) {
        guard let database else { return }

        let statements = [
            """
            CREATE TABLE IF NOT EXISTS archived_events (
                id TEXT PRIMARY KEY,
                pubkey TEXT NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                seen_at REAL NOT NULL,
                payload_bytes INTEGER NOT NULL,
                pin_rank INTEGER NOT NULL DEFAULT 0,
                event_json BLOB NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS recent_feed_events (
                feed_key TEXT NOT NULL,
                position INTEGER NOT NULL,
                event_id TEXT NOT NULL,
                stored_at REAL NOT NULL,
                PRIMARY KEY (feed_key, position)
            );
            """,
            "CREATE INDEX IF NOT EXISTS archived_events_seen_at_idx ON archived_events(seen_at DESC);",
            "CREATE INDEX IF NOT EXISTS archived_events_created_at_idx ON archived_events(created_at DESC);",
            "CREATE INDEX IF NOT EXISTS archived_events_pin_rank_idx ON archived_events(pin_rank DESC, seen_at DESC);",
            "CREATE INDEX IF NOT EXISTS recent_feed_events_feed_key_idx ON recent_feed_events(feed_key);",
            "CREATE INDEX IF NOT EXISTS recent_feed_events_event_id_idx ON recent_feed_events(event_id);"
        ]

        for statement in statements {
            sqlite3_exec(database, statement, nil, nil, nil)
        }
    }

    private func withTransaction(_ body: () -> Void) {
        guard let database else { return }
        sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        body()
        sqlite3_exec(database, "COMMIT TRANSACTION;", nil, nil, nil)
    }

    private func prepareStatement(_ sql: String) -> OpaquePointer? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement {
                sqlite3_finalize(statement)
            }
            return nil
        }
        return statement
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT_ARCHIVE)
    }

    private func decodeEvent(from statement: OpaquePointer?, column: Int32) -> NostrEvent? {
        let length = sqlite3_column_bytes(statement, column)
        guard length > 0,
              let rawBytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        let data = Data(bytes: rawBytes, count: Int(length))
        return try? decoder.decode(NostrEvent.self, from: data)
    }

    private func columnText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    private func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func normalizedIDs(_ ids: [String]) -> [String] {
        Array(
            Set(
                ids
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)

        var index = startIndex
        while index < endIndex {
            let nextIndex = Swift.min(index + size, endIndex)
            result.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }

        return result
    }
}
