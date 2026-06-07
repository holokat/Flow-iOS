import XCTest
@testable import Flow

final class NSpamClassifierTests: XCTestCase {
    func testBundledWeightsMatchFeatureVector() throws {
        let weights = try NSpamWeights.loadFromBundle()

        XCTAssertEqual(weights.coef.count, NSpamFeatures.totalFeatureCount)
        XCTAssertFalse(weights.calibX.isEmpty)
        XCTAssertEqual(weights.calibX.count, weights.calibY.count)
    }

    func testClassifierScoresSeededReplyNotes() throws {
        let weights = try NSpamWeights.loadFromBundle()
        let classifier = NSpamClassifier(weights: weights)
        let score = try XCTUnwrap(
            classifier.score(notes: [
                NSpamNoteInput(
                    content: "claim your prize now https://spam.example/reward",
                    tags: [["e", hex("1"), "", "reply"]],
                    createdAt: 1_700_000_000
                )
            ])
        )

        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThanOrEqual(score, 1)
    }

    func testAuthorScorerReadsCachedLocalNotes() async {
        let authorPubkey = hex("a")
        let event = makeEvent(
            id: hex("b"),
            pubkey: authorPubkey,
            kind: 1,
            tags: [["e", hex("c"), "", "reply"]],
            content: "cached reply used for spam scoring"
        )

        XCTAssertTrue(FlowNostrDB.shared.ingest(events: [event]))

        let noteCount = await NSpamAuthorScorer.shared.cachedNoteCountForTesting(pubkey: authorPubkey)
        XCTAssertGreaterThan(noteCount, 0)
    }

    private func makeEvent(
        id: String,
        pubkey: String,
        kind: Int,
        tags: [[String]],
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
}
