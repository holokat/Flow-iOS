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

        await SeenEventStore.shared.store(events: [event])

        let noteCount = await NSpamAuthorScorer.shared.cachedNoteCountForTesting(pubkey: authorPubkey)
        XCTAssertGreaterThan(noteCount, 0)
    }

    func testAuthorCacheRequestsRescoreWhenNoteCountCrossesThreshold() async {
        let cache = NSpamAuthorCache()
        let pubkey = hex("d")

        await cache.put(
            pubkey: pubkey,
            score: 0.9,
            noteCount: 4,
            personalizationSignature: "labels"
        )

        let scoreBeforeThreshold = await cache.score(
            for: pubkey,
            currentNoteCount: 4,
            personalizationSignature: "labels"
        )
        let scoreAtThreshold = await cache.score(
            for: pubkey,
            currentNoteCount: 5,
            personalizationSignature: "labels"
        )

        XCTAssertEqual(scoreBeforeThreshold, 0.9)
        XCTAssertNil(scoreAtThreshold)
    }

    func testAuthorCacheKeepsScoresForEachPersonalizationSignature() async {
        let cache = NSpamAuthorCache()
        let pubkey = hex("e")

        await cache.put(
            pubkey: pubkey,
            score: 0.2,
            noteCount: 5,
            personalizationSignature: "old-labels",
            scoringRevision: 1
        )
        await cache.put(
            pubkey: pubkey,
            score: 0.8,
            noteCount: 5,
            personalizationSignature: "new-labels",
            scoringRevision: 2
        )

        let oldScore = await cache.score(
            for: pubkey,
            currentNoteCount: 5,
            personalizationSignature: "old-labels"
        )
        let newScore = await cache.score(
            for: pubkey,
            currentNoteCount: 5,
            personalizationSignature: "new-labels"
        )

        XCTAssertEqual(oldScore, 0.2)
        XCTAssertEqual(newScore, 0.8)
    }

    func testOlderScoringRevisionCannotOverwriteNewerScore() async {
        let cache = NSpamAuthorCache()
        let pubkey = hex("f")

        await cache.put(
            pubkey: pubkey,
            score: 0.9,
            noteCount: 5,
            personalizationSignature: "labels",
            scoringRevision: 2
        )
        await cache.put(
            pubkey: pubkey,
            score: 0.1,
            noteCount: 4,
            personalizationSignature: "labels",
            scoringRevision: 1
        )

        let score = await cache.score(
            for: pubkey,
            currentNoteCount: 5,
            personalizationSignature: "labels"
        )

        XCTAssertEqual(score, 0.9)
    }

    func testCancelledTaskCannotPublishScoreToAuthorCache() async {
        let cache = NSpamAuthorCache()
        let gate = NSpamTestGate()
        let pubkey = hex("1")
        let putTask = Task {
            await gate.wait()
            return await cache.put(
                pubkey: pubkey,
                score: 0.1,
                noteCount: 5,
                personalizationSignature: "labels",
                scoringRevision: 1
            )
        }

        while !(await gate.isWaiting) {
            await Task.yield()
        }
        putTask.cancel()
        await gate.release()

        let didCache = await putTask.value
        let cachedScore = await cache.score(
            for: pubkey,
            currentNoteCount: 5,
            personalizationSignature: "labels"
        )

        XCTAssertFalse(didCache)
        XCTAssertNil(cachedScore)
    }

    func testCancelledRevisionCannotRemoveNewerScore() async {
        let cache = NSpamAuthorCache()
        let pubkey = hex("2")

        await cache.put(
            pubkey: pubkey,
            score: 0.9,
            noteCount: 5,
            personalizationSignature: "labels",
            scoringRevision: 2
        )
        await cache.remove(
            pubkey: pubkey,
            personalizationSignature: "labels",
            scoringRevision: 1
        )

        let score = await cache.score(
            for: pubkey,
            currentNoteCount: 5,
            personalizationSignature: "labels"
        )

        XCTAssertEqual(score, 0.9)
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

private actor NSpamTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
