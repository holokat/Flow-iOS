import XCTest
@testable import Flow

final class EventArchiveStoreTests: XCTestCase {
    func testEventPersistenceKeepsWispKindsAndOwnEventsOnly() async throws {
        let rootURL = try makeRootURL(prefix: "EventPersistence")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let ownPubkey = hex("a")
        let persistence = EventPersistence(
            archiveStore: EventArchiveStore(fileManager: EventArchiveTestFileManager(rootURL: rootURL)),
            currentUserPubkey: "  \(ownPubkey.uppercased())\n"
        )

        XCTAssertEqual(
            EventPersistence.persistedKinds,
            Set([0, 1, 6, 7, 20, 21, 22, 1_068, 6_969, 9_735, 30_023])
        )

        for kind in EventPersistence.persistedKinds {
            let shouldPersist = await persistence.shouldPersist(
                makeEvent(id: hex("1"), pubkey: hex("b"), kind: kind, content: "wisp")
            )
            XCTAssertTrue(shouldPersist)
        }

        let ownEphemeral = makeEvent(id: hex("2"), pubkey: ownPubkey, kind: 40_000, content: "own")
        let remoteEphemeral = makeEvent(id: hex("3"), pubkey: hex("c"), kind: 40_000, content: "drop")
        let shouldPersistOwnEphemeral = await persistence.shouldPersist(ownEphemeral)
        let shouldPersistRemoteEphemeral = await persistence.shouldPersist(remoteEphemeral)

        XCTAssertTrue(shouldPersistOwnEphemeral)
        XCTAssertFalse(shouldPersistRemoteEphemeral)
    }

    func testEventPersistenceFlushesOnlyPersistableEvents() async throws {
        let rootURL = try makeRootURL(prefix: "EventPersistence")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let archive = EventArchiveStore(
            fileManager: EventArchiveTestFileManager(rootURL: rootURL),
            budget: .init(
                archiveSoftLimitBytes: 1_000_000,
                archiveHardLimitBytes: 1_200_000,
                hotIndexTargetEventCount: 100,
                minimumFreeDiskBytes: 0
            )
        )
        let persistence = EventPersistence(
            archiveStore: archive,
            batchLimit: 50,
            flushDelayNanoseconds: 20_000_000
        )
        let ownPubkey = hex("a")
        await persistence.setCurrentUserPubkey(ownPubkey)
        let duplicateID = hex("4")
        let staleDuplicate = makeEvent(id: duplicateID.uppercased(), kind: 1, content: "stale")
        let persistable = makeEvent(id: duplicateID, kind: 1, content: "keep")
        let ownEphemeral = makeEvent(id: hex("5"), pubkey: ownPubkey, kind: 40_000, content: "own")
        let dropped = makeEvent(id: hex("6"), pubkey: hex("b"), kind: 40_000, content: "drop")

        await persistence.persistEvents([staleDuplicate, dropped, ownEphemeral, persistable])
        try await Task.sleep(nanoseconds: 80_000_000)

        let restored = await archive.events(ids: [persistable.id, ownEphemeral.id, dropped.id])

        XCTAssertEqual(restored[persistable.id.lowercased()]?.content, "keep")
        XCTAssertEqual(restored[ownEphemeral.id.lowercased()]?.content, "own")
        XCTAssertNil(restored[dropped.id.lowercased()])
        XCTAssertEqual(restored.count, 2)
    }

    func testEventRepositoryReadsThroughPersistenceAndCachesResult() async throws {
        let rootURL = try makeRootURL(prefix: "EventRepository")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let archive = EventArchiveStore(fileManager: EventArchiveTestFileManager(rootURL: rootURL))
        let persistence = EventPersistence(archiveStore: archive, flushDelayNanoseconds: 0)
        let repository = EventRepository(
            persistence: persistence,
            archiveBudget: .init(hotIndexTargetEventCount: 4)
        )
        let event = makeEvent(id: hex("8"), kind: 1, content: "persisted")

        await archive.store(events: [event])

        let cacheSizeBeforeReadThrough = await repository.getCacheSize()
        XCTAssertEqual(cacheSizeBeforeReadThrough, 0)

        let resolved = await repository.getEvent(id: event.id.uppercased())
        let cacheSizeAfterReadThrough = await repository.getCacheSize()

        XCTAssertEqual(resolved?.content, "persisted")
        XCTAssertEqual(cacheSizeAfterReadThrough, 1)
    }

    func testEventPersistenceNotificationSeedMatchesWispRelevantKinds() async throws {
        let rootURL = try makeRootURL(prefix: "EventPersistenceNotifications")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let archive = EventArchiveStore(fileManager: EventArchiveTestFileManager(rootURL: rootURL))
        let persistence = EventPersistence(archiveStore: archive, flushDelayNanoseconds: 0)
        let newestNotificationKind = makeEvent(
            id: hex("9"),
            pubkey: hex("f"),
            kind: 1,
            content: "newest note",
            createdAt: 1_700_000_200
        )
        let olderNotificationKind = makeEvent(
            id: hex("8"),
            pubkey: hex("a"),
            kind: 1,
            content: "older note",
            createdAt: 1_700_000_100
        )
        let ignoredKind = makeEvent(
            id: hex("7"),
            pubkey: hex("b"),
            kind: 42,
            content: "not notification seed material",
            createdAt: 1_700_000_300
        )

        await archive.store(events: [newestNotificationKind, olderNotificationKind, ignoredKind])

        let notifications = await persistence.getRecentNotificationEvents(limit: 10)

        XCTAssertEqual(notifications.map(\.id), [newestNotificationKind.id, olderNotificationKind.id])
    }

    func testArchiveStoreRoundTripsEventsAndPrunesByByteBudget() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchiveStore")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let store = EventArchiveStore(
            fileManager: fileManager,
            budget: .init(
                archiveSoftLimitBytes: 80_000,
                archiveHardLimitBytes: 96_000,
                hotIndexTargetEventCount: 100,
                minimumFreeDiskBytes: 0
            )
        )

        let events = (0..<50).map { index in
            makeEvent(
                id: String(format: "%064x", index),
                content: String(repeating: "x", count: 1_024),
                createdAt: 1_700_000_000 + index
            )
        }

        await store.store(events: events)

        let diagnostics = await store.diagnosticsSnapshot()
        let resolved = await store.events(ids: [events.first!.id, events.last!.id])
        let footprintBytes = try archiveFootprintBytes(rootURL: rootURL)

        XCTAssertEqual(diagnostics.archiveBytes, footprintBytes)
        XCTAssertLessThanOrEqual(diagnostics.archiveBytes, 80_000)
        XCTAssertLessThan(diagnostics.archiveCount, events.count)
        XCTAssertEqual(resolved[events.last!.id.lowercased()]?.content, events.last!.content)
        XCTAssertEqual(resolved.count, 1)
    }

    func testRecentEventsKeepsPinnedIDsWhenSelectingHotIndexSeed() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchivePinned")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let store = EventArchiveStore(fileManager: fileManager)

        let oldest = makeEvent(id: hex("1"), content: "oldest", createdAt: 1_700_000_000)
        let middle = makeEvent(id: hex("2"), content: "middle", createdAt: 1_700_000_100)
        let newest = makeEvent(id: hex("3"), content: "newest", createdAt: 1_700_000_200)

        await store.store(events: [oldest, middle, newest])

        let retained = await store.recentEvents(limit: 2, pinnedIDs: [oldest.id.lowercased()])

        XCTAssertEqual(
            Set(retained.map { $0.id.lowercased() }),
            Set([oldest.id.lowercased(), newest.id.lowercased()])
        )
    }

    func testRecentEventsPreferLaterSeenAtOverNewerCreatedAt() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchiveSeenPriority")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let store = EventArchiveStore(fileManager: fileManager)

        let newerCreatedEarlierSeen = makeEvent(
            id: hex("6"),
            content: "newer-created",
            createdAt: 1_700_000_200
        )
        let olderCreatedLaterSeen = makeEvent(
            id: hex("7"),
            content: "later-seen",
            createdAt: 1_700_000_100
        )

        await store.store(events: [newerCreatedEarlierSeen])
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.store(events: [olderCreatedLaterSeen])

        let retained = await store.recentEvents(limit: 1, pinnedIDs: [])

        XCTAssertEqual(retained.map { $0.id.lowercased() }, [olderCreatedLaterSeen.id.lowercased()])
    }

    func testArchiveStoreEnforcesHardBudgetEvenWhenOnlyPinnedRowsRemain() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchivePinnedBudget")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let store = EventArchiveStore(
            fileManager: fileManager,
            budget: .init(
                archiveSoftLimitBytes: 80_000,
                archiveHardLimitBytes: 96_000,
                hotIndexTargetEventCount: 10,
                minimumFreeDiskBytes: 0
            )
        )

        let events = (0..<3).map { index in
            makeEvent(
                id: String(format: "%064x", index),
                content: String(repeating: "p", count: 32_768),
                createdAt: 1_700_000_000 + index
            )
        }

        await store.storeRecentFeed(key: "following:test", events: events)

        let diagnostics = await store.diagnosticsSnapshot()
        let restored = await store.events(ids: events.map(\.id))
        let footprintBytes = try archiveFootprintBytes(rootURL: rootURL)

        XCTAssertEqual(diagnostics.archiveBytes, footprintBytes)
        XCTAssertLessThanOrEqual(diagnostics.archiveBytes, 80_000)
        XCTAssertLessThan(restored.count, events.count)
    }

    func testArchiveStoreReportsAndEnforcesOnDiskSQLiteFootprint() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchiveFootprint")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let store = EventArchiveStore(
            fileManager: fileManager,
            budget: .init(
                archiveSoftLimitBytes: 96_000,
                archiveHardLimitBytes: 112_000,
                hotIndexTargetEventCount: 100,
                minimumFreeDiskBytes: 0
            )
        )

        let events = (0..<24).map { index in
            makeEvent(
                id: String(format: "%064x", index),
                content: String(repeating: "w", count: 4_096),
                createdAt: 1_700_000_000 + index
            )
        }

        await store.store(events: events)

        let diagnostics = await store.diagnosticsSnapshot()
        let footprintBytes = try archiveFootprintBytes(rootURL: rootURL)

        XCTAssertEqual(diagnostics.archiveBytes, footprintBytes)
        XCTAssertLessThanOrEqual(footprintBytes, 96_000)
    }

    func testDiagnosticsSnapshotReportsArchiveAndPinnedFeedCounts() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchiveDiagnostics")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let store = EventArchiveStore(fileManager: fileManager)

        let first = makeEvent(id: hex("4"), content: "first", createdAt: 1_700_000_000)
        let second = makeEvent(id: hex("5"), content: "second", createdAt: 1_700_000_100)

        await store.storeRecentFeed(key: "following:test", events: [first, second])

        let diagnostics = await store.diagnosticsSnapshot()

        XCTAssertEqual(diagnostics.archiveCount, 2)
        XCTAssertEqual(diagnostics.pinnedFeedEventCount, 2)
        XCTAssertGreaterThan(diagnostics.archiveBytes, 0)
    }

    func testArchiveStoreBatchesCompactionPassesWhilePruning() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchiveBatchPrune")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let maintenanceCounter = MaintenanceCounter()
        let store = EventArchiveStore(
            fileManager: fileManager,
            budget: .init(
                archiveSoftLimitBytes: 80_000,
                archiveHardLimitBytes: 96_000,
                hotIndexTargetEventCount: 100,
                minimumFreeDiskBytes: 0
            ),
            maintenanceObserver: {
                maintenanceCounter.increment()
            }
        )

        let events = (0..<18).map { index in
            makeEvent(
                id: String(format: "%064x", index),
                content: String(repeating: "b", count: 8_192),
                createdAt: 1_700_000_000 + index
            )
        }

        await store.store(events: events)

        let diagnostics = await store.diagnosticsSnapshot()
        let deletedCount = events.count - diagnostics.archiveCount

        XCTAssertGreaterThan(deletedCount, 4)
        XCTAssertLessThan(maintenanceCounter.count, deletedCount)
    }

    func testArchiveStoreRechecksMinimumFreeDiskAfterEachPrunePass() async throws {
        let rootURL = try makeRootURL(prefix: "EventArchiveLowDisk")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = EventArchiveTestFileManager(rootURL: rootURL)
        let freeDiskProbe = SequencedFreeDiskProbe(values: [30_000, 30_000, 40_000, 50_000])
        let store = EventArchiveStore(
            fileManager: fileManager,
            budget: .init(
                archiveSoftLimitBytes: 1_000_000,
                archiveHardLimitBytes: 2_000_000,
                hotIndexTargetEventCount: 100,
                minimumFreeDiskBytes: 50_000
            ),
            availableFreeDiskBytesProvider: { _ in
                freeDiskProbe.nextValue()
            }
        )

        let events = (0..<17).map { index in
            makeEvent(
                id: String(format: "%064x", index),
                content: String(repeating: "d", count: 2_048),
                createdAt: 1_700_000_000 + index
            )
        }

        await store.store(events: events)

        let diagnostics = await store.diagnosticsSnapshot()

        XCTAssertEqual(
            diagnostics.archiveCount,
            0,
            "Pruning should continue until minimum free disk is satisfied."
        )
    }

    private func makeRootURL(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEvent(
        id: String,
        pubkey: String = String(repeating: "a", count: 64),
        kind: Int = 1,
        tags: [[String]] = [],
        content: String,
        createdAt: Int = 1_700_000_000
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: String(repeating: "f", count: 128)
        )
    }

    private func hex(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func archiveFootprintBytes(rootURL: URL) throws -> Int64 {
        let databaseURL = rootURL
            .appendingPathComponent("FeedArchive", isDirectory: true)
            .appendingPathComponent("event-archive.sqlite", isDirectory: false)
        let componentURLs = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]

        return try componentURLs.reduce(into: Int64(0)) { total, url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}

private final class EventArchiveTestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        [rootURL]
    }
}

private final class MaintenanceCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private final class SequencedFreeDiskProbe: @unchecked Sendable {
    private let values: [Int64]
    private var index = 0

    init(values: [Int64]) {
        self.values = values
    }

    func nextValue() -> Int64 {
        guard !values.isEmpty else { return .max }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}
