import XCTest
@testable import Flow

@MainActor
final class SearchViewModelRelayTargetTests: XCTestCase {
    func testKeywordSearchRelayTargetsStartWithDittoSearchRelays() throws {
        let viewModel = SearchViewModel(
            relayURL: try XCTUnwrap(URL(string: "wss://relay.damus.io/")),
            readRelayURLs: [
                try XCTUnwrap(URL(string: "wss://relay.primal.net/")),
                try XCTUnwrap(URL(string: "wss://nos.lol/"))
            ]
        )

        let targets = viewModel.keywordSearchRelayTargetsForTesting().map(\.absoluteString)

        XCTAssertEqual(
            Array(targets.prefix(2)),
            [
                "wss://relay.ditto.pub/",
                "wss://relay.dreamith.to/"
            ]
        )
    }

    func testKeywordSearchRelayTargetsDoNotIncludeNormalReadRelays() throws {
        let viewModel = SearchViewModel(
            relayURL: try XCTUnwrap(URL(string: "wss://relay.damus.io/")),
            readRelayURLs: [
                try XCTUnwrap(URL(string: "wss://relay.primal.net/")),
                try XCTUnwrap(URL(string: "wss://nos.lol/"))
            ]
        )

        let targets = viewModel.keywordSearchRelayTargetsForTesting().map {
            $0.absoluteString.lowercased()
        }

        XCTAssertFalse(targets.contains("wss://relay.primal.net/"))
        XCTAssertFalse(targets.contains("wss://nos.lol/"))
        XCTAssertFalse(targets.contains("wss://relay.damus.io/"))
    }

    func testKeywordSearchRelayTargetsDoNotIncludeSlowOrProfileOnlySearchRelays() throws {
        let viewModel = SearchViewModel(
            relayURL: try XCTUnwrap(URL(string: "wss://relay.damus.io/"))
        )

        let targets = viewModel.keywordSearchRelayTargetsForTesting().map {
            $0.absoluteString.lowercased()
        }

        XCTAssertFalse(targets.contains("wss://search.nostrarchives.com"))
        XCTAssertFalse(targets.contains("wss://indexer.nostrarchives.com/"))
        XCTAssertFalse(targets.contains("wss://indexer.coracle.social/"))
        XCTAssertFalse(targets.contains("wss://relay.nos.social/"))
    }
}
