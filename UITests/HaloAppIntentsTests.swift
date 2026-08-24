import AppIntentsTesting
import XCTest

@available(iOS 27.0, *)
final class HaloAppIntentsTests: XCTestCase {
    private let definitions = IntentDefinitions(bundleIdentifier: "com.21media.haloapp")

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().launch()
    }

    func testSearchIntentRunsThroughSystemIntentInfrastructure() async throws {
        let intent = definitions.intents["SearchHaloIntent"].makeIntent(
            query: "nostr"
        )

        try await intent.run()
    }

    func testDraftNoteIntentRunsWithoutPublishing() async throws {
        let intent = definitions.intents["DraftHaloNoteIntent"].makeIntent(
            draftText: "A local draft created by an App Intents integration test."
        )

        try await intent.run()
    }
}
