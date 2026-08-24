import XCTest
@testable import Flow

final class HaloSystemNavigationTests: XCTestCase {
    private let pubkey = String(repeating: "a", count: 64)
    private let eventID = String(repeating: "b", count: 64)

    func testProfileRoundTrip() {
        let route = HaloDeepLinkRoute.profile(pubkey: pubkey)
        XCTAssertEqual(HaloDeepLinkRoute.parse(route.url), route)
    }

    func testNoteRoundTrip() {
        let route = HaloDeepLinkRoute.note(reference: eventID)
        XCTAssertEqual(HaloDeepLinkRoute.parse(route.url), route)
    }

    func testComposeRoundTripPreservesText() {
        let route = HaloDeepLinkRoute.compose(text: "A note with spaces and #hashtags")
        XCTAssertEqual(HaloDeepLinkRoute.parse(route.url), route)
    }

    func testMessageRoundTripPreservesRecipientAndDraft() {
        let route = HaloDeepLinkRoute.message(pubkey: pubkey, draft: "Private draft")
        XCTAssertEqual(HaloDeepLinkRoute.parse(route.url), route)
    }

    func testRejectsInvalidProfileIdentifier() {
        XCTAssertNil(HaloDeepLinkRoute.parse(URL(string: "flow://profile/not-a-pubkey")!))
    }

    func testSearchTextIsBounded() {
        let longQuery = String(repeating: "q", count: 800)
        let parsed = HaloDeepLinkRoute.parse(HaloDeepLinkRoute.search(query: longQuery).url)
        XCTAssertEqual(parsed, .search(query: String(longQuery.prefix(500))))
    }
}
