import XCTest
import SwiftUI
@testable import Flow

final class NostrRelayClientTests: XCTestCase {
    private static var projectRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

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
        throw XCTSkip("Ditto relay pool keeps relays hot instead of locally cooling them down.")
    }

    func testLiveSubscriberPreservesCursorAndInitialReplayLimit() {
        let filter = NostrFilter(
            kinds: [7],
            limit: 100,
            since: 1_700_000_000,
            until: 1_700_000_100,
            tagFilters: ["p": [String(repeating: "a", count: 64)]]
        )

        let liveFilter = NostrLiveFeedSubscriber.liveFilter(from: filter)

        XCTAssertEqual(liveFilter.kinds, [7])
        XCTAssertEqual(liveFilter.since, 1_700_000_000)
        XCTAssertNil(liveFilter.until)
        XCTAssertEqual(liveFilter.limit, 100)
        XCTAssertEqual(liveFilter.tagFilters?["p"], [String(repeating: "a", count: 64)])
    }

    func testLiveSubscriberDefaultsMissingCursorToSubscriptionStart() {
        let filter = NostrFilter(
            authors: [String(repeating: "a", count: 64)],
            kinds: [1],
            limit: 100
        )

        let liveFilter = NostrLiveFeedSubscriber.liveFilter(
            from: filter,
            now: 1_800_000_000
        )

        XCTAssertEqual(liveFilter.since, 1_800_000_000)
        XCTAssertNil(liveFilter.until)
        XCTAssertEqual(liveFilter.limit, 100)
    }

    func testLiveSubscriberPreparedCursorStaysStableAcrossReconnects() {
        let initialFilter = NostrLiveFeedSubscriber.liveFilter(
            from: NostrFilter(kinds: [1], limit: 100),
            now: 1_800_000_000
        )

        let reconnectFilter = NostrLiveFeedSubscriber.liveFilter(
            from: initialFilter,
            now: 1_800_000_300
        )

        XCTAssertEqual(reconnectFilter.since, 1_800_000_000)
        XCTAssertEqual(reconnectFilter.limit, 100)
    }

    func testLiveSubscriberRemovesNonPositiveReplayLimit() {
        let filter = NostrFilter(
            kinds: [1],
            limit: 0,
            since: 1_700_000_000
        )

        let liveFilter = NostrLiveFeedSubscriber.liveFilter(from: filter)

        XCTAssertNil(liveFilter.limit)
    }

    func testHaloLinkReplayCursorIncludesNIP59TimestampRandomizationWindow() {
        let latestRumorTimestamp = 1_700_000_000

        XCTAssertEqual(
            HaloLinkSyncPolicy.replaySince(latestRumorTimestamp: latestRumorTimestamp),
            latestRumorTimestamp
                - HaloLinkSyncPolicy.giftWrapRandomizationWindow
                - HaloLinkSyncPolicy.clockSkewAllowance
        )
        XCTAssertNil(HaloLinkSyncPolicy.replaySince(latestRumorTimestamp: nil))
        XCTAssertEqual(HaloLinkSyncPolicy.replaySince(latestRumorTimestamp: 60), 0)
    }

    func testHaloLinkStoreStartsWhenDirectMessagesViewBecomesActive() throws {
        let shellSource = try String(
            contentsOf: Self.projectRootURL
                .appendingPathComponent("Sources/App/MainTabShellView.swift"),
            encoding: .utf8
        )
        let dmSource = try String(
            contentsOf: Self.projectRootURL
                .appendingPathComponent("Sources/DMs/DMsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(shellSource.contains("@StateObject private var haloLinkStore = HaloLinkStore()"))
        XCTAssertFalse(shellSource.contains("configureHaloLinkStore()"))
        XCTAssertTrue(shellSource.contains("DMsView("))
        XCTAssertTrue(shellSource.contains("isRootVisible:"))
        XCTAssertTrue(dmSource.contains("@StateObject private var store = HaloLinkStore()"))
        XCTAssertTrue(dmSource.contains(".task {\n            configureStore()"))
    }

    func testHaloLinkPublishesDecryptedRepliesBeforeProfileEnrichment() throws {
        let source = try String(
            contentsOf: Self.projectRootURL
                .appendingPathComponent("Sources/DMs/HaloLinkStore.swift"),
            encoding: .utf8
        )
        let methodStart = try XCTUnwrap(
            source.range(of: "private func applyWrappedEvents(")?.lowerBound
        )
        let methodEnd = try XCTUnwrap(
            source.range(of: "private func refreshProfiles(", range: methodStart..<source.endIndex)?.lowerBound
        )
        let methodSource = String(source[methodStart..<methodEnd])
        let immediateRebuild = try XCTUnwrap(methodSource.range(of: "rebuildConversations()"))
        let profileLookup = try XCTUnwrap(methodSource.range(of: "await refreshProfiles("))

        XCTAssertLessThan(immediateRebuild.lowerBound, profileLookup.lowerBound)
        XCTAssertTrue(source.contains("seal.pubkey.lowercased() == rumor.pubkey.lowercased()"))
        XCTAssertTrue(source.contains("rumor.id.lowercased() == rumor.calculatedId.lowercased()"))
    }

    func testLiveSubscriberReconnectBackoffIsBounded() {
        XCTAssertEqual(
            NostrLiveFeedSubscriber.reconnectDelayNanoseconds(
                failureCount: 1,
                base: 1_000,
                maximum: 5_000,
                jitterFraction: 0
            ),
            1_000
        )
        XCTAssertEqual(
            NostrLiveFeedSubscriber.reconnectDelayNanoseconds(
                failureCount: 3,
                base: 1_000,
                maximum: 5_000,
                jitterFraction: 0
            ),
            4_000
        )
        XCTAssertEqual(
            NostrLiveFeedSubscriber.reconnectDelayNanoseconds(
                failureCount: 10,
                base: 1_000,
                maximum: 5_000,
                jitterFraction: 0.2
            ),
            5_000
        )
    }

    @MainActor
    func testReactionCatchUpDeduplicatesCapsAndPacesRecoveredEvents() async throws {
        let targetPubkey = String(repeating: "a", count: 64)
        let actorPubkey = String(repeating: "b", count: 64)
        let firstRelay = URL(string: "wss://first.example.com")!
        let secondRelay = URL(string: "wss://second.example.com")!
        let events = (1...4).map { index in
            reactionEvent(
                id: String(repeating: Character(String(index)), count: 64),
                actorPubkey: actorPubkey,
                targetPubkey: targetPubkey,
                content: String(index),
                createdAt: 1_700_000_000 + index
            )
        }
        let subscriber = ReactionTestLiveSubscriber()
        let relayClient = ReactionTestRelayClient(
            eventsByRelay: [
                firstRelay: events,
                secondRelay: events
            ]
        )
        var emitted: [(reaction: ActivityReaction, date: Date)] = []
        let controller = LiveReactsSubscriptionController(
            liveSubscriber: subscriber,
            relayClient: relayClient,
            catchUpMinimumInterval: 0,
            catchUpEmissionIntervalNanoseconds: 50_000_000,
            maximumQueuedCatchUpReactions: 2,
            now: { Date(timeIntervalSince1970: 1_700_000_010) }
        )

        controller.update(
            currentUserPubkey: targetPubkey,
            readRelayURLs: [firstRelay, secondRelay],
            isEnabled: true,
            scenePhase: .active,
            onReaction: { emitted.append(($0, Date())) }
        )

        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(emitted.map(\.reaction.content), ["3", "4"])
        XCTAssertEqual(emitted.count, 2)
        if emitted.count == 2 {
            XCTAssertGreaterThanOrEqual(
                emitted[1].date.timeIntervalSince(emitted[0].date),
                0.035
            )
        }

        let filters = await relayClient.recordedFilters()
        XCTAssertEqual(filters.count, 2)
        XCTAssertTrue(filters.allSatisfy { $0.since == 1_699_999_980 })
        XCTAssertTrue(filters.allSatisfy { $0.until == 1_700_000_010 })
        XCTAssertTrue(filters.allSatisfy { $0.limit == 120 })

        controller.update(
            currentUserPubkey: targetPubkey,
            readRelayURLs: [firstRelay, secondRelay],
            isEnabled: true,
            scenePhase: .inactive
        )
    }

    @MainActor
    func testLiveReactionIsImmediateAndDuplicateIsIgnored() async throws {
        let targetPubkey = String(repeating: "a", count: 64)
        let relay = URL(string: "wss://live.example.com")!
        let subscriber = ReactionTestLiveSubscriber()
        let relayClient = ReactionTestRelayClient(eventsByRelay: [:])
        var emitted: [ActivityReaction] = []
        let controller = LiveReactsSubscriptionController(
            liveSubscriber: subscriber,
            relayClient: relayClient,
            catchUpMinimumInterval: 0,
            catchUpEmissionIntervalNanoseconds: 50_000_000,
            now: { Date(timeIntervalSince1970: 1_700_000_010) }
        )

        controller.update(
            currentUserPubkey: targetPubkey,
            readRelayURLs: [relay],
            isEnabled: true,
            scenePhase: .active,
            onReaction: { emitted.append($0) }
        )
        try await Task.sleep(nanoseconds: 30_000_000)

        let event = reactionEvent(
            id: String(repeating: "1", count: 64),
            actorPubkey: String(repeating: "b", count: 64),
            targetPubkey: targetPubkey,
            content: "🔥",
            createdAt: 1_700_000_011
        )
        await subscriber.emit(event)
        await subscriber.emit(event)

        XCTAssertEqual(emitted.map(\.content), ["🔥"])

        let liveFilters = await subscriber.recordedFilters()
        XCTAssertEqual(liveFilters.count, 1)
        XCTAssertEqual(liveFilters.first?.since, 1_699_999_980)
        XCTAssertNil(liveFilters.first?.limit)

        controller.update(
            currentUserPubkey: targetPubkey,
            readRelayURLs: [relay],
            isEnabled: true,
            scenePhase: .inactive
        )
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

private actor ReactionTestLiveSubscriber: NostrLiveEventSubscribing {
    private var filters: [NostrFilter] = []
    private var eventHandlers: [@Sendable (NostrEvent) async -> Void] = []

    func run(
        relayURL: URL,
        filter: NostrFilter,
        onNewEvent: @escaping @Sendable (NostrEvent) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async {
        filters.append(filter)
        eventHandlers.append(onNewEvent)

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    func emit(_ event: NostrEvent) async {
        let handlers = eventHandlers
        for handler in handlers {
            await handler(event)
        }
    }

    func recordedFilters() -> [NostrFilter] {
        filters
    }
}

private actor ReactionTestRelayClient: NostrRelayEventFetching {
    private let eventsByRelay: [URL: [NostrEvent]]
    private var filters: [NostrFilter] = []

    init(eventsByRelay: [URL: [NostrEvent]]) {
        self.eventsByRelay = eventsByRelay
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        filters.append(filter)
        return eventsByRelay[relayURL] ?? []
    }

    func recordedFilters() -> [NostrFilter] {
        filters
    }
}

private func reactionEvent(
    id: String,
    actorPubkey: String,
    targetPubkey: String,
    content: String,
    createdAt: Int
) -> NostrEvent {
    NostrEvent(
        id: id,
        pubkey: actorPubkey,
        createdAt: createdAt,
        kind: 7,
        tags: [
            ["e", String(repeating: "e", count: 64)],
            ["p", targetPubkey]
        ],
        content: content,
        sig: String(repeating: "f", count: 128)
    )
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
