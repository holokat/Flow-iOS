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
}
