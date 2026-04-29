import XCTest
@testable import Flow

final class CrawlCursorStoreTests: XCTestCase {
    func testRoundTripsTierAUntilCursorPerAuthor() async {
        let rootURL = makeTemporaryDirectory()
        let store = CrawlCursorStore(rootURL: rootURL)

        await store.setUntilCursor(1_234_567, for: "npub-tier-a", tier: .tierA)

        let reloaded = CrawlCursorStore(rootURL: rootURL)
        let cursor = await reloaded.untilCursor(for: "npub-tier-a", tier: .tierA)
        XCTAssertEqual(cursor, 1_234_567)
    }

    func testRoundTripsTierBUntilCursorPerAuthor() async {
        let rootURL = makeTemporaryDirectory()
        let store = CrawlCursorStore(rootURL: rootURL)

        await store.setUntilCursor(765_432, for: "npub-tier-b", tier: .tierB)

        let reloaded = CrawlCursorStore(rootURL: rootURL)
        let cursor = await reloaded.untilCursor(for: "npub-tier-b", tier: .tierB)
        XCTAssertEqual(cursor, 765_432)
    }

    func testRoundTripsLastSuccessfulReplaceableRefreshTimestamp() async {
        let rootURL = makeTemporaryDirectory()
        let store = CrawlCursorStore(rootURL: rootURL)
        let refreshDate = Date(timeIntervalSince1970: 1_717_171_717)

        await store.setLastReplaceableRefreshAt(refreshDate)

        let reloaded = CrawlCursorStore(rootURL: rootURL)
        let persistedDate = await reloaded.lastReplaceableRefreshAt()
        XCTAssertEqual(persistedDate, refreshDate)
    }

    func testRoundTripsQueuedMissingReferenceIDs() async {
        let rootURL = makeTemporaryDirectory()
        let store = CrawlCursorStore(rootURL: rootURL)

        await store.enqueueMissingReferenceIDs(["event-1", "event-2", "event-1"])

        let reloaded = CrawlCursorStore(rootURL: rootURL)
        let queued = await reloaded.queuedMissingReferenceIDs()
        XCTAssertEqual(queued, ["event-1", "event-2"])
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrawlCursorStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
