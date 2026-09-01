import XCTest

#if canImport(AppIntentsTesting) && !HALO_NSEC_LOGIN_TEST
import AppIntentsTesting

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
#endif

#if HALO_NSEC_LOGIN_TEST
final class NsecPasteSmokeUITests: XCTestCase {
    private let app = XCUIApplication()
    private var didAttemptGeneratedSignIn = false
    private var didObserveSignedInHome = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        didAttemptGeneratedSignIn = false
        didObserveSignedInHome = false

        addTeardownBlock {
            if self.didAttemptGeneratedSignIn {
                XCTAssertTrue(
                    self.cleanUpGeneratedAccountAfterAttempt(
                        in: self.app,
                        didObserveSignedInHome: self.didObserveSignedInHome
                    ),
                    "The test could not verify that the generated account was removed or never persisted."
                )
            }
        }
    }

    func testPasteNsecAndSignIn() throws {
        app.launch()

        ensureSignedOut(in: app)

        let welcomeSignInButton = app.buttons["welcome-sign-in"]
        XCTAssertTrue(waitUntilStableAndHittable(welcomeSignInButton, timeout: 8))
        welcomeSignInButton.tap()

        let credentialField = app.secureTextFields["auth-private-key-input"]
        XCTAssertTrue(credentialField.waitForExistence(timeout: 8))
        let pasteButton = app.buttons["auth-private-key-paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { pasteButton.isEnabled })
        pasteButton.tap()

        let submitButton = app.buttons["auth-sign-in-submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { submitButton.isEnabled })

        let openMenuButton = app.buttons["Open menu"]
        XCTAssertTrue(submitButton.isHittable)
        didAttemptGeneratedSignIn = true
        submitButton.tap()

        let didSignIn = openMenuButton.waitForExistence(timeout: 15)
        if didSignIn {
            didObserveSignedInHome = true
        }
        if !didSignIn {
            let rejectedAsInvalid = app.staticTexts["Invalid account access."].exists
            XCTFail(
                "A valid pasted NSEC did not reach the signed-in Home UI. "
                    + "invalidCredentialError=\(rejectedAsInvalid) credentialFieldStillVisible=\(credentialField.exists)"
            )
        }
    }

    private func ensureSignedOut(in app: XCUIApplication) {
        let welcomeTagline = app.staticTexts["A calmer place for conversations."]
        if welcomeTagline.waitForExistence(timeout: 3) {
            return
        }

        let openMenuButton = app.buttons["Open menu"]
        XCTAssertTrue(openMenuButton.waitForExistence(timeout: 8))
        openMenuButton.tap()

        let logOutButton = app.buttons["Log Out"]
        XCTAssertTrue(logOutButton.waitForExistence(timeout: 5))
        logOutButton.tap()
        XCTAssertTrue(welcomeTagline.waitForExistence(timeout: 8))
    }

    private func cleanUpGeneratedAccountAfterAttempt(
        in app: XCUIApplication,
        didObserveSignedInHome: Bool
    ) -> Bool {
        if didObserveSignedInHome {
            return removeActiveAccount(in: app)
        }

        app.terminate()
        app.launch()

        let openMenuButton = app.buttons["Open menu"]
        if openMenuButton.waitForExistence(timeout: 8) {
            return removeActiveAccount(in: app)
        }

        let welcomeTagline = app.staticTexts["A calmer place for conversations."]
        return welcomeTagline.waitForExistence(timeout: 5)
    }

    @discardableResult
    private func removeActiveAccount(in app: XCUIApplication) -> Bool {
        let openMenuButton = app.buttons["Open menu"]
        guard openMenuButton.waitForExistence(timeout: 8) else { return false }
        openMenuButton.tap()

        let accountsButton = app.buttons["Accounts"]
        guard accountsButton.waitForExistence(timeout: 5) else { return false }
        accountsButton.tap()

        let accountsTab = app.segmentedControls.buttons["Accounts"]
        guard accountsTab.waitForExistence(timeout: 5) else { return false }
        if !accountsTab.isSelected {
            accountsTab.tap()
        }

        let removeActiveAccountButton = app.buttons["remove-active-account"]
        guard removeActiveAccountButton.waitForExistence(timeout: 8) else { return false }
        removeActiveAccountButton.tap()

        let confirmButton = app.buttons["Remove Account"]
        guard confirmButton.waitForExistence(timeout: 5) else { return false }
        confirmButton.tap()
        return waitUntil(timeout: 5) { !confirmButton.exists }
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return predicate()
    }

    private func waitUntilStableAndHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        var previousFrame: CGRect?
        var stableSampleCount = 0

        return waitUntil(timeout: timeout, pollInterval: 0.15) {
            guard element.exists, element.isEnabled, element.isHittable else {
                previousFrame = nil
                stableSampleCount = 0
                return false
            }

            let currentFrame = element.frame
            if previousFrame == currentFrame {
                stableSampleCount += 1
            } else {
                previousFrame = currentFrame
                stableSampleCount = 0
            }
            return stableSampleCount >= 2
        }
    }
}
#endif
