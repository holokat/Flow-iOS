import XCTest
@testable import Flow

final class MuteFilterSnapshotTests: XCTestCase {
    func testEncodedSpamHeuristicHidesBase64LookingContentWithoutMutedWords() {
        let snapshot = MuteFilterSnapshot(
            mutedPubkeys: [],
            exactMutedWords: [],
            phraseMutedWords: []
        )
        let encodedPayload = String(
            repeating: "VGhlYm9hcmRab25lX3ByZXNlbmNlQWxwaGExMjM0NTY3ODkwKysvPQ==",
            count: 10
        )

        XCTAssertTrue(snapshot.shouldHide(makeMuteFilterEvent(content: encodedPayload)))
    }

    func testEncodedSpamHeuristicAllowsLongNaturalLanguageContent() {
        let snapshot = MuteFilterSnapshot(
            mutedPubkeys: [],
            exactMutedWords: [],
            phraseMutedWords: []
        )
        let naturalPost = String(
            repeating: "This is a normal long note with punctuation, spaces, and enough human-readable structure to avoid encoded spam filtering. ",
            count: 8
        )

        XCTAssertFalse(snapshot.shouldHide(makeMuteFilterEvent(content: naturalPost)))
    }

    func testMutedWordWithUnderscoreMatchesAsSingleToken() {
        let snapshot = MuteFilterSnapshot(
            mutedPubkeys: [],
            exactMutedWords: ["zone_presence"],
            phraseMutedWords: []
        )

        XCTAssertTrue(snapshot.shouldHide(makeMuteFilterEvent(content: "bot marker zone_presence detected")))
        XCTAssertFalse(snapshot.shouldHide(makeMuteFilterEvent(content: "zone presence should not match without underscore")))
    }

    @MainActor
    func testDefaultMutedKeywordListsExcludeBitcoinAndIncludeEditableAISpamList() {
        let suiteName = "MuteFilterSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MuteStore(defaults: defaults)
        let titles = store.mutedKeywordLists.map(\.title)

        XCTAssertFalse(titles.contains("Bitcoin"))

        let aiList = store.mutedKeywordLists.first { $0.id == "ai-bots-spam" }
        XCTAssertEqual(aiList?.title, "AI, Bots & Spam")
        XCTAssertEqual(aiList?.words, ["theboard", "zone_presence"])
        XCTAssertEqual(aiList?.allowsAddingWords, true)
    }

    func testLocalMuteReasonsPersistPerAccountAndIgnoreBlankValues() {
        let suiteName = "MuteFilterSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = LocalMuteReasonPersistence(defaults: defaults)
        persistence.save(
            [
                " PersonA ": "  Repeated unwanted replies  ",
                "PersonB": " \n "
            ],
            for: " AccountA "
        )

        XCTAssertEqual(
            persistence.load(for: "accounta"),
            ["persona": "Repeated unwanted replies"]
        )
        XCTAssertTrue(persistence.load(for: "accountb").isEmpty)

        persistence.save(
            ["PersonA": "Updated local reason"],
            for: "AccountA"
        )
        XCTAssertEqual(
            persistence.load(for: "accounta"),
            ["persona": "Updated local reason"]
        )

        persistence.save([:], for: "AccountA")
        XCTAssertTrue(persistence.load(for: "accounta").isEmpty)
    }

    @MainActor
    func testMutedPersonReasonCanBeAddedUpdatedAndRemovedLocally() {
        let suiteName = "MuteFilterSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ["person"],
            forKey: "flow.mutedPubkeys.account"
        )

        let store = MuteStore(defaults: defaults)
        let localRelayURL = URL(string: "ws://127.0.0.1:1")!
        store.configure(
            accountPubkey: "account",
            nsec: nil,
            readRelayURLs: [localRelayURL],
            writeRelayURLs: [localRelayURL]
        )

        store.setMuteReason("First local reason", for: "PERSON")
        XCTAssertEqual(store.muteReason(for: "person"), "First local reason")
        XCTAssertTrue(store.isMuted("person"))

        store.setMuteReason("Updated local reason", for: "person")
        XCTAssertEqual(store.muteReason(for: "person"), "Updated local reason")
        XCTAssertTrue(store.isMuted("person"))

        store.setMuteReason(nil, for: "person")
        XCTAssertNil(store.muteReason(for: "person"))
        XCTAssertTrue(store.isMuted("person"))
    }
}

private func makeMuteFilterEvent(content: String) -> NostrEvent {
    NostrEvent(
        id: String(repeating: "a", count: 64),
        pubkey: String(repeating: "b", count: 64),
        createdAt: 1_700_000_000,
        kind: 1,
        tags: [],
        content: content,
        sig: String(repeating: "c", count: 128)
    )
}
