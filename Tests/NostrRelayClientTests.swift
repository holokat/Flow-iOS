import XCTest
@testable import Flow

final class NostrRelayClientTests: XCTestCase {
    func testSingleResumeContinuationBoxKeepsFirstReturnValue() async throws {
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let box = RelaySingleResumeContinuationBox(continuation)
            box.resume(returning: 7)
            box.resume(returning: 11)
            box.resume(throwing: SourcePublishTransportError(message: "ignored"))
        }

        XCTAssertEqual(result, 7)
    }

    func testSingleResumeContinuationBoxKeepsFirstThrownError() async {
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let box = RelaySingleResumeContinuationBox(continuation)
                box.resume(throwing: SourcePublishTransportError(message: "first"))
                box.resume(returning: 11)
                box.resume(throwing: SourcePublishTransportError(message: "second"))
            }
            XCTFail("Expected error")
        } catch let error as SourcePublishTransportError {
            XCTAssertEqual(error.message, "first")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchEventsRejectsNonWebSocketURL() async {
        let client = NostrRelayClient(session: .shared)
        let filter = NostrFilter(limit: 1)

        do {
            _ = try await client.fetchEvents(
                relayURL: URL(string: "https://example.com")!,
                filter: filter,
                timeout: 0.01
            )
            XCTFail("Expected invalid relay URL error")
        } catch let error as RelayClientError {
            guard case .invalidRelayURL(let value) = error else {
                return XCTFail("Unexpected relay client error: \(error)")
            }
            XCTAssertEqual(value, "https://example.com")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchEventsRespectsRelayCooldownBeforeOpeningSocket() async throws {
        CountingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let healthStore = RelayHealthStore()
        let relayURL = URL(string: "wss://cooled-relay.example.com")!
        await healthStore.recordFailure(
            RelayClientError.publishRejected("restricted"),
            relayURL: relayURL
        )
        let client = NostrRelayClient(
            session: session,
            connectionPool: NostrRelayPool(healthStore: healthStore)
        )

        do {
            _ = try await client.fetchEvents(
                relayURL: relayURL,
                filter: NostrFilter(limit: 1),
                timeout: 0.01
            )
            XCTFail("Expected relay cooldown error")
        } catch let error as RelayClientError {
            guard case .closed(let reason) = error else {
                return XCTFail("Unexpected relay client error: \(error)")
            }
            XCTAssertTrue(reason.contains("cooling down"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(CountingURLProtocol.startLoadingCount, 0)
    }

    func testTransportFailureUsesLongCooldownEvenWhenErrorCodeContainsFour() async {
        var configuration = RelayHealthStore.Configuration()
        configuration.rejectionCooldown = 60
        configuration.transportFailureCooldown = 600
        let healthStore = RelayHealthStore(configuration: configuration)
        let relayURL = URL(string: "wss://down-relay.example.com")!
        let now = Date()

        await healthStore.recordFailure(
            URLError(.cannotConnectToHost),
            relayURL: relayURL,
            now: now
        )

        let afterRejectionWindow = await healthStore.isAvailable(
            relayURL,
            now: now.addingTimeInterval(61)
        )
        let afterTransportWindow = await healthStore.isAvailable(
            relayURL,
            now: now.addingTimeInterval(601)
        )

        XCTAssertFalse(afterRejectionWindow)
        XCTAssertTrue(afterTransportWindow)
    }

    func testPoolEvictionDoesNotCooldownRelay() async {
        let healthStore = RelayHealthStore()
        let relayURL = URL(string: "wss://evicted-relay.example.com")!

        await healthStore.recordFailure(
            RelayClientError.poolEvicted,
            relayURL: relayURL
        )

        let isAvailable = await healthStore.isAvailable(relayURL)
        XCTAssertTrue(isAvailable)
    }

    func testPublishEventToSourcesPublishesConcurrently() async {
        let firstSource = URL(string: "wss://source-one.example.com")!
        let secondSource = URL(string: "wss://source-two.example.com")!
        let publisher = StubRelayPublisher(
            delays: [
                firstSource: 200_000_000,
                secondSource: 200_000_000
            ]
        )

        let startedAt = Date()
        let outcome = await publisher.publishEvent(
            to: [firstSource, secondSource],
            eventData: Data("{}".utf8),
            eventID: "event-id"
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(outcome.successfulSourceCount, 2)
        XCTAssertNil(outcome.firstFailureMessage)
        XCTAssertLessThan(elapsed, 0.35)
    }

    func testPublishEventToSourcesCapturesFailuresWithoutBlockingSuccesses() async {
        let firstSource = URL(string: "wss://source-one.example.com")!
        let secondSource = URL(string: "wss://source-two.example.com")!
        let publisher = StubRelayPublisher(
            delays: [
                secondSource: 120_000_000
            ],
            failureMessages: [
                firstSource: "Source publish timed out."
            ]
        )

        let outcome = await publisher.publishEvent(
            to: [firstSource, secondSource],
            eventData: Data("{}".utf8),
            eventID: "event-id"
        )

        XCTAssertEqual(outcome.successfulSourceCount, 1)
        XCTAssertEqual(outcome.firstFailureMessage, "Source publish timed out.")
    }

    func testPublishEventToSourcesReturnsAfterFirstSuccessWithoutWaitingForSlowSources() async {
        let fastSource = URL(string: "wss://source-one.example.com")!
        let slowSource = URL(string: "wss://source-two.example.com")!
        let publisher = StubRelayPublisher(
            delays: [
                slowSource: 1_000_000_000
            ]
        )

        let startedAt = Date()
        let outcome = await publisher.publishEvent(
            to: [slowSource, fastSource],
            eventData: Data("{}".utf8),
            eventID: "event-id",
            successPolicy: .returnAfterFirstSuccess
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(outcome.successfulSourceCount, 1)
        XCTAssertNil(outcome.firstFailureMessage)
        XCTAssertLessThan(elapsed, 0.35)
    }
}

private final class CountingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0

    static var startLoadingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

private actor StubRelayPublisher: NostrRelayEventPublishing {
    let delays: [URL: UInt64]
    let failureMessages: [URL: String]

    init(
        delays: [URL: UInt64] = [:],
        failureMessages: [URL: String] = [:]
    ) {
        self.delays = delays
        self.failureMessages = failureMessages
    }

    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async throws {
        if let delay = delays[relayURL] {
            try await Task.sleep(nanoseconds: delay)
        }

        if let failureMessage = failureMessages[relayURL] {
            throw SourcePublishTransportError(message: failureMessage)
        }
    }
}
