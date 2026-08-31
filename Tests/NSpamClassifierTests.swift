import CryptoKit
import XCTest
@testable import Flow

final class NSpamClassifierTests: XCTestCase {
    func testBundledModelIsOfficialV24Artifact() throws {
        let weights = try NSpamWeights.loadFromBundle()

        XCTAssertEqual(weights.configuration.modelVersion, NSpamModelIdentity.version)
        XCTAssertEqual(weights.configuration.schemaVersion, NSpamModelIdentity.schemaVersion)
        XCTAssertEqual(weights.model.trees.count, 500)
        XCTAssertEqual(weights.calibration.calibX.count, 4)
        XCTAssertEqual(weights.calibration.calibX.count, weights.calibration.calibY.count)

        let modelURL = try bundledResourceURL(named: "model", extension: "txt")
        let calibrationURL = try bundledResourceURL(named: "calibration", extension: "npz")
        let configurationURL = try bundledResourceURL(named: "config", extension: "json")
        XCTAssertEqual(try sha256Hex(of: modelURL), NSpamModelIdentity.modelSHA256)
        XCTAssertEqual(try sha256Hex(of: calibrationURL), NSpamModelIdentity.calibrationSHA256)
        XCTAssertEqual(try sha256Hex(of: configurationURL), NSpamModelIdentity.configurationSHA256)
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

    func testV24HashFixturesMatchFeatureExtraction() throws {
        let fixtures: [NSpamHashFixture] = try decodeJSONLines(
            at: sourceFixtureURL(named: "nspam-v2.4-hash.jsonl")
        )

        XCTAssertEqual(fixtures.count, 10)
        for fixture in fixtures {
            let features = NSpamFeatures.extractHashedTextFeaturesForTesting(fixture.token)
            let actualCharBuckets = sparseBuckets(in: features, range: 0..<NSpamFeatures.charFeatureCount)
            let wordStart = NSpamFeatures.charFeatureCount
            let actualWordBuckets = sparseBuckets(
                in: features,
                range: wordStart..<(wordStart + NSpamFeatures.wordFeatureCount),
                subtracting: wordStart
            )

            assertFixtureBuckets(
                actualCharBuckets,
                equalPublishedBuckets: fixture.charWbBuckets,
                label: "char",
                token: fixture.token
            )
            assertFixtureBuckets(
                actualWordBuckets,
                equalPublishedBuckets: fixture.wordBuckets,
                label: "word",
                token: fixture.token
            )
        }
    }

    func testV24PreprocessingUsesNFKCAndFullCasefold() {
        XCTAssertEqual(
            NSpamFeatures.preprocessTextForTesting("Straße ΟΣ Ꭰ ꭰ ᲀ"),
            "strasse οσ Ꭰ Ꭰ в"
        )
        XCTAssertEqual(
            NSpamFeatures.preprocessTextForTesting("\u{1C89} \u{A7CB} \u{10D50} \u{10D65}"),
            "\u{1C8A} \u{264} \u{10D70} \u{10D85}"
        )
    }

    func testV24ParityFixturesMatchPublishedScores() throws {
        let fixtures: [NSpamParityFixture] = try decodeJSONLines(
            at: sourceFixtureURL(named: "nspam-v2.4-parity.jsonl")
        )
        let weights = try NSpamWeights.loadFromBundle()
        let classifier = NSpamClassifier(weights: weights)

        XCTAssertEqual(fixtures.count, 50)
        for fixture in fixtures {
            let notes = fixture.notes.map {
                NSpamNoteInput(content: $0.content, tags: $0.tags, createdAt: $0.createdAt)
            }
            let rawScore = try XCTUnwrap(classifier.rawScore(notes: notes))
            let calibratedScore = weights.calibration.score(rawScore: rawScore)
            XCTAssertEqual(
                rawScore,
                fixture.expectedRawScore,
                accuracy: 0.000_01,
                "raw score mismatch for \(fixture.pubkey)"
            )
            XCTAssertEqual(
                calibratedScore,
                fixture.expectedCalibratedScore,
                accuracy: 0.000_01,
                "calibrated score mismatch for \(fixture.pubkey)"
            )
        }
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

    private func bundledResourceURL(named name: String, extension fileExtension: String) throws -> URL {
        let candidates = [Bundle.main, Bundle(for: Self.self)]
        for bundle in candidates {
            if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "nspam")
                ?? bundle.url(forResource: name, withExtension: fileExtension) {
                return url
            }
        }
        throw NSpamWeightsError.missingResource("\(name).\(fileExtension)")
    }

    private func sourceFixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func sha256Hex(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func decodeJSONLines<Value: Decodable>(at url: URL) throws -> [Value] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0a).map { try JSONDecoder().decode(Value.self, from: Data($0)) }
    }

    private func sparseBuckets(
        in features: [Float],
        range: Range<Int>,
        subtracting offset: Int = 0
    ) -> [NSpamHashFixture.Bucket] {
        range.compactMap { index in
            let value = features[index]
            return value == 0 ? nil : NSpamHashFixture.Bucket(index: index - offset, value: value)
        }
    }

    private func assertFixtureBuckets(
        _ actual: [NSpamHashFixture.Bucket],
        equalPublishedBuckets expected: [NSpamHashFixture.Bucket],
        label: String,
        token: String
    ) {
        XCTAssertEqual(
            Array(actual.prefix(expected.count)),
            expected,
            "\(label) hash mismatch for \(token)"
        )
        if expected.count < 32 {
            XCTAssertEqual(actual.count, expected.count, "unexpected \(label) buckets for \(token)")
        }
    }
}

private struct NSpamHashFixture: Decodable {
    struct Bucket: Codable, Equatable {
        let index: Int
        let value: Float
    }

    let token: String
    let wordBuckets: [Bucket]
    let charWbBuckets: [Bucket]

    enum CodingKeys: String, CodingKey {
        case token
        case wordBuckets = "word_buckets"
        case charWbBuckets = "char_wb_buckets"
    }
}

private struct NSpamParityFixture: Decodable {
    struct Note: Decodable {
        let content: String
        let tags: [[String]]
        let createdAt: Int

        enum CodingKeys: String, CodingKey {
            case content, tags
            case createdAt = "created_at"
        }
    }

    let pubkey: String
    let notes: [Note]
    let expectedRawScore: Double
    let expectedCalibratedScore: Double

    enum CodingKeys: String, CodingKey {
        case pubkey, notes
        case expectedRawScore = "expected_raw_score"
        case expectedCalibratedScore = "expected_calibrated_score"
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
