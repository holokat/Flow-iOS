import XCTest
@testable import Flow

final class AuthorRelayPlannerTests: XCTestCase {
    func testPlannerPrefersAuthorReadRelaysBeforeAppReadRelays() {
        let planner = AuthorRelayPlanner()
        let author = String(repeating: "a", count: 64)

        let plan = planner.makePlan(
            authors: [author],
            baseReadRelayURLs: [URL(string: "wss://relay.damus.io/")!],
            directoryEntriesByPubkey: [
                author: AuthorRelayDirectoryEntry(
                    readRelayURLs: [URL(string: "wss://author-read.example/")!],
                    writeRelayURLs: [URL(string: "wss://author-write.example/")!],
                    hintRelayURLs: [],
                    refreshedAt: nil
                )
            ],
            fallbackRelayURLs: [URL(string: "wss://relay.primal.net/")!]
        )

        XCTAssertEqual(
            plan.relayURLs(for: author).map(\.absoluteString),
            [
                "wss://author-read.example/",
                "wss://relay.damus.io/",
                "wss://relay.primal.net/"
            ]
        )
    }

    func testPlannerFallsBackToWriteRelaysWhenReadRelaysAreMissing() {
        let planner = AuthorRelayPlanner()
        let author = String(repeating: "b", count: 64)

        let plan = planner.makePlan(
            authors: [author],
            baseReadRelayURLs: [URL(string: "wss://relay.damus.io/")!],
            directoryEntriesByPubkey: [
                author: AuthorRelayDirectoryEntry(
                    readRelayURLs: [],
                    writeRelayURLs: [URL(string: "wss://author-write.example/")!],
                    hintRelayURLs: [],
                    refreshedAt: nil
                )
            ],
            fallbackRelayURLs: []
        )

        XCTAssertEqual(
            plan.relayURLs(for: author).map(\.absoluteString),
            [
                "wss://author-write.example/",
                "wss://relay.damus.io/"
            ]
        )
    }
}
