import XCTest
@testable import Flow

@MainActor
final class SettingsSheetStateTests: XCTestCase {
    func testResetClearsNavigationAndNestedSheetState() {
        let state = SettingsSheetState()
        state.navigationPath = [.appearance, .feeds]

        state.reset()

        XCTAssertTrue(state.navigationPath.isEmpty)
    }

    func testShowReplacesNavigationPathWithDestination() {
        let state = SettingsSheetState()
        state.navigationPath = [.appearance]

        state.show(.feeds)

        XCTAssertEqual(state.navigationPath, [.feeds])
    }
}
