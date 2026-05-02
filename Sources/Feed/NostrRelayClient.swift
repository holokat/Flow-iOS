import Combine
import Foundation

protocol NostrRelayEventFetching: Sendable {
    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent]
}

protocol NostrRelayEventPublishing: Sendable {
    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async throws
}

struct SourcePublishOutcome: Sendable {
    let successfulSourceCount: Int
    let firstFailureMessage: String?
    let attempts: [SourcePublishAttemptReport]

    init(
        successfulSourceCount: Int,
        firstFailureMessage: String?,
        attempts: [SourcePublishAttemptReport] = []
    ) {
        self.successfulSourceCount = successfulSourceCount
        self.firstFailureMessage = firstFailureMessage
        self.attempts = attempts
    }
}

enum SourcePublishSuccessPolicy: Sendable {
    case waitForAllAcknowledgements
    case returnAfterFirstSuccess
}

struct SourcePublishTransportError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct SourcePublishAttemptReport: Codable, Equatable, Sendable {
    let sourceURLString: String
    let accepted: Bool
    let failureMessage: String?
    let rateLimited: Bool
    let recordedAt: Date

    init(
        sourceURL: URL,
        accepted: Bool,
        failureMessage: String? = nil,
        rateLimited: Bool = false,
        recordedAt: Date = Date()
    ) {
        self.sourceURLString = Self.normalizedSourceURLString(sourceURL.absoluteString)
        self.accepted = accepted
        self.failureMessage = failureMessage
        self.rateLimited = rateLimited
        self.recordedAt = recordedAt
    }

    private static func normalizedSourceURLString(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct SourcePublishStatsSnapshot: Codable, Equatable, Identifiable, Sendable {
    let sourceURLString: String
    var attemptedCount: Int
    var acceptedCount: Int
    var failedCount: Int
    var rateLimitedCount: Int
    var lastAttemptAt: Date?
    var lastAcceptedAt: Date?
    var lastFailedAt: Date?
    var lastFailureMessage: String?

    var id: String { sourceURLString }

    var acceptanceRate: Double {
        guard attemptedCount > 0 else { return 0 }
        return Double(acceptedCount) / Double(attemptedCount)
    }
}

@MainActor
final class SourcePublishStatsStore: ObservableObject {
    static let shared = SourcePublishStatsStore()

    @Published private(set) var snapshotsBySource: [String: SourcePublishStatsSnapshot]

    private let defaults: UserDefaults
    private let storageKey = "flow.sourcePublishStats.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: SourcePublishStatsSnapshot].self, from: data) {
            self.snapshotsBySource = decoded
        } else {
            self.snapshotsBySource = [:]
        }
    }

    func snapshot(for sourceURLString: String) -> SourcePublishStatsSnapshot? {
        snapshotsBySource[normalizedSourceKey(sourceURLString)]
    }

    func orderedSnapshots(for sourceURLStrings: [String]) -> [SourcePublishStatsSnapshot] {
        sourceURLStrings.compactMap(snapshot(for:))
    }

    func record(_ report: SourcePublishAttemptReport) {
        let key = normalizedSourceKey(report.sourceURLString)
        guard !key.isEmpty else { return }

        var snapshot = snapshotsBySource[key] ?? SourcePublishStatsSnapshot(
            sourceURLString: key,
            attemptedCount: 0,
            acceptedCount: 0,
            failedCount: 0,
            rateLimitedCount: 0,
            lastAttemptAt: nil,
            lastAcceptedAt: nil,
            lastFailedAt: nil,
            lastFailureMessage: nil
        )

        snapshot.attemptedCount += 1
        snapshot.lastAttemptAt = report.recordedAt

        if report.accepted {
            snapshot.acceptedCount += 1
            snapshot.lastAcceptedAt = report.recordedAt
        } else {
            snapshot.failedCount += 1
            snapshot.lastFailedAt = report.recordedAt
            snapshot.lastFailureMessage = report.failureMessage
            if report.rateLimited {
                snapshot.rateLimitedCount += 1
            }
        }

        snapshotsBySource[key] = snapshot
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshotsBySource) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func normalizedSourceKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum RelayClientError: LocalizedError {
    case invalidRelayURL(String)
    case closed(String)
    case poolEvicted
    case publishRejected(String)
    case publishTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL(let value):
            return "Invalid source URL: \(value)"
        case .closed(let reason):
            return "Source closed the subscription: \(reason)"
        case .poolEvicted:
            return "Source connection was evicted from the relay pool."
        case .publishRejected(let reason):
            return "Source rejected the event: \(reason)"
        case .publishTimedOut:
            return "Source publish timed out."
        }
    }
}

enum RelayConnectionTimeoutError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Source timed out."
    }
}

public final class RelaySingleResumeContinuationBox<Success>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, Error>?

    public init(_ continuation: CheckedContinuation<Success, Error>) {
        self.continuation = continuation
    }

    public func resume(returning value: Success) {
        takeContinuation()?.resume(returning: value)
    }

    public func resume(throwing error: Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Success, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let captured = continuation
        continuation = nil
        return captured
    }
}

actor NostrRelayPool {
    static let shared = NostrRelayPool()

    private let healthStore: RelayHealthStore
    private let maxConnections: Int
    private var connections: [String: NostrRelaySocketConnection] = [:]
    private var lastUsedAtByKey: [String: Date] = [:]

    init(
        healthStore: RelayHealthStore = .shared,
        maxConnections: Int = RelayHealthStore.Configuration().maxEphemeralConnections
    ) {
        self.healthStore = healthStore
        self.maxConnections = max(maxConnections, 1)
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> [NostrEvent] {
        guard await healthStore.isAvailable(relayURL) else {
            throw RelayClientError.closed("Relay is cooling down after recent failures.")
        }
        let connection = await connection(for: relayURL, session: session)
        do {
            let events = try await connection.fetchEvents(filter: filter, timeout: timeout)
            await healthStore.clearCooldown(relayURL)
            return events
        } catch {
            await healthStore.recordFailure(error, relayURL: relayURL)
            await removeConnection(connection, for: relayURL)
            throw error
        }
    }

    func publishEvent(
        relayURL: URL,
        eventObject: [String: Any],
        eventID: String,
        timeout: TimeInterval,
        session: URLSession
    ) async throws {
        guard await healthStore.isAvailable(relayURL) else {
            throw RelayClientError.closed("Relay is cooling down after recent failures.")
        }
        let connection = await connection(for: relayURL, session: session)
        do {
            try await connection.publishEvent(
                eventObject: eventObject,
                eventID: eventID,
                timeout: timeout
            )
            await healthStore.clearCooldown(relayURL)
        } catch {
            await healthStore.recordFailure(error, relayURL: relayURL)
            await removeConnection(connection, for: relayURL)
            throw error
        }
    }

    func streamEvents(
        relayURL: URL,
        filter: NostrFilter,
        session: URLSession
    ) async -> AsyncThrowingStream<NostrEvent, Error> {
        guard await healthStore.isAvailable(relayURL) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: RelayClientError.closed("Relay is cooling down after recent failures.")
                )
            }
        }
        let connection = await connection(for: relayURL, session: session)
        let healthStore = self.healthStore
        let pool = self

        return AsyncThrowingStream { continuation in
            let task = Task {
                let upstream = await connection.streamEvents(filter: filter)
                do {
                    for try await event in upstream {
                        await healthStore.clearCooldown(relayURL)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    await healthStore.recordFailure(error, relayURL: relayURL)
                    await pool.removeConnection(connection, for: relayURL)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func connection(
        for relayURL: URL,
        session: URLSession
    ) async -> NostrRelaySocketConnection {
        let key = relayKey(relayURL)
        lastUsedAtByKey[key] = Date()
        if let existing = connections[key] {
            return existing
        }

        let created = NostrRelaySocketConnection(
            relayURL: relayURL,
            session: session
        )
        connections[key] = created
        await evictIdleConnectionsIfNeeded()
        return created
    }

    private func removeConnection(
        _ connection: NostrRelaySocketConnection,
        for relayURL: URL
    ) async {
        let key = relayKey(relayURL)
        guard let current = connections[key], current === connection else { return }
        let removed = connections.removeValue(forKey: key)
        lastUsedAtByKey[key] = nil
        await removed?.close()
    }

    private func evictIdleConnectionsIfNeeded() async {
        while connections.count > maxConnections,
              let oldestKey = lastUsedAtByKey.min(by: { $0.value < $1.value })?.key {
            let removed = connections.removeValue(forKey: oldestKey)
            lastUsedAtByKey[oldestKey] = nil
            await removed?.close()
        }
    }

    private func relayKey(_ relayURL: URL) -> String {
        RelayURLSupport.normalizedRelayURLString(relayURL)
            ?? relayURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private actor NostrRelaySocketConnection {
    private struct QuerySubscription {
        let request: String
        var events: [NostrEvent]
        let continuation: CheckedContinuation<[NostrEvent], Error>
    }

    private struct LiveSubscription {
        let request: String
        let continuation: AsyncThrowingStream<NostrEvent, Error>.Continuation
    }

    private struct PublishRequest {
        let request: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private let relayURL: URL
    private let session: URLSession
    private let pingIntervalNanoseconds: UInt64 = 25_000_000_000

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var querySubscriptions: [String: QuerySubscription] = [:]
    private var liveSubscriptions: [String: LiveSubscription] = [:]
    private var pendingPublishes: [String: PublishRequest] = [:]

    init(
        relayURL: URL,
        session: URLSession
    ) {
        self.relayURL = relayURL
        self.session = session
    }

    func fetchEvents(
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        try await openIfNeeded()

        let subscriptionID = UUID().uuidString
        let request = try serializeJSONArray(["REQ", subscriptionID, filter.jsonObject])

        return try await withThrowingTaskGroup(of: [NostrEvent].self) { group in
            group.addTask {
                try await self.awaitQuery(subscriptionID: subscriptionID, request: request)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: Self.timeoutNanoseconds(for: timeout)
                )
                await self.cancelQuery(
                    subscriptionID: subscriptionID,
                    error: RelayConnectionTimeoutError.timedOut
                )
                throw RelayConnectionTimeoutError.timedOut
            }

            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw RelayConnectionTimeoutError.timedOut
            }
            return result
        }
    }

    func publishEvent(
        eventObject: [String: Any],
        eventID: String,
        timeout: TimeInterval
    ) async throws {
        try await openIfNeeded()

        let request = try serializeJSONArray(["EVENT", eventObject])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.awaitPublish(eventID: eventID, request: request)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: Self.timeoutNanoseconds(for: timeout)
                )
                await self.cancelPublish(eventID: eventID)
                throw RelayClientError.publishTimedOut
            }

            defer { group.cancelAll() }

            guard let _ = try await group.next() else {
                throw RelayClientError.publishTimedOut
            }
        }
    }

    func streamEvents(
        filter: NostrFilter
    ) -> AsyncThrowingStream<NostrEvent, Error> {
        let subscriptionID = UUID().uuidString
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.openIfNeeded()
                    let request = try self.serializeJSONArray(
                        ["REQ", subscriptionID, filter.jsonObject]
                    )
                    await self.registerLiveSubscription(
                        subscriptionID: subscriptionID,
                        request: request,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                Task {
                    await self.cancelLiveSubscription(subscriptionID: subscriptionID)
                }
            }
        }
    }

    func close() {
        let queryContinuations = querySubscriptions.values.map(\.continuation)
        let liveContinuations = liveSubscriptions.values.map(\.continuation)
        let publishContinuations = pendingPublishes.values.map(\.continuation)

        querySubscriptions.removeAll()
        liveSubscriptions.removeAll()
        pendingPublishes.removeAll()

        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil

        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        let error = RelayClientError.poolEvicted
        for continuation in queryContinuations {
            continuation.resume(throwing: error)
        }
        for continuation in liveContinuations {
            continuation.finish(throwing: error)
        }
        for continuation in publishContinuations {
            continuation.resume(throwing: error)
        }
    }

    private func awaitQuery(
        subscriptionID: String,
        request: String
    ) async throws -> [NostrEvent] {
        try await withCheckedThrowingContinuation { continuation in
            querySubscriptions[subscriptionID] = QuerySubscription(
                request: request,
                events: [],
                continuation: continuation
            )

            Task {
                do {
                    try await self.send(text: request)
                } catch {
                    await self.failQuery(subscriptionID: subscriptionID, error: error)
                }
            }
        }
    }

    private func awaitPublish(
        eventID: String,
        request: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingPublishes[eventID] = PublishRequest(
                request: request,
                continuation: continuation
            )

            Task {
                do {
                    try await self.send(text: request)
                } catch {
                    await self.failPublish(eventID: eventID, error: error)
                }
            }
        }
    }

    private func registerLiveSubscription(
        subscriptionID: String,
        request: String,
        continuation: AsyncThrowingStream<NostrEvent, Error>.Continuation
    ) async {
        liveSubscriptions[subscriptionID] = LiveSubscription(
            request: request,
            continuation: continuation
        )

        do {
            try await send(text: request)
        } catch {
            liveSubscriptions.removeValue(forKey: subscriptionID)
            continuation.finish(throwing: error)
        }
    }

    private func cancelQuery(
        subscriptionID: String,
        error: Error
    ) async {
        guard let query = querySubscriptions.removeValue(forKey: subscriptionID) else { return }
        if let closeRequest = try? serializeJSONArray(["CLOSE", subscriptionID]) {
            try? await send(text: closeRequest)
        }
        query.continuation.resume(throwing: error)
    }

    private func cancelLiveSubscription(subscriptionID: String) async {
        guard liveSubscriptions.removeValue(forKey: subscriptionID) != nil else { return }
        if let closeRequest = try? serializeJSONArray(["CLOSE", subscriptionID]) {
            try? await send(text: closeRequest)
        }
    }

    private func cancelPublish(eventID: String) async {
        guard let publish = pendingPublishes.removeValue(forKey: eventID) else { return }
        publish.continuation.resume(throwing: RelayClientError.publishTimedOut)
    }

    private func failQuery(
        subscriptionID: String,
        error: Error
    ) async {
        guard let query = querySubscriptions.removeValue(forKey: subscriptionID) else { return }
        query.continuation.resume(throwing: error)
    }

    private func failPublish(
        eventID: String,
        error: Error
    ) async {
        guard let publish = pendingPublishes.removeValue(forKey: eventID) else { return }
        publish.continuation.resume(throwing: error)
    }

    private func openIfNeeded() async throws {
        guard socket == nil else { return }

        let task = session.webSocketTask(with: relayURL)
        task.resume()
        socket = task
        startReceiveLoop(for: task)
        startPingLoop(for: task)
    }

    private func startReceiveLoop(
        for socket: URLSessionWebSocketTask
    ) {
        receiveTask?.cancel()
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    await self.handle(message: message)
                } catch {
                    await self.handleSocketFailure(error)
                    return
                }
            }
        }
    }

    private func startPingLoop(
        for socket: URLSessionWebSocketTask
    ) {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pingIntervalNanoseconds)
                    try await self.awaitPing(on: socket)
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    await self.handleSocketFailure(error)
                    return
                }
            }
        }
    }

    private func handle(
        message: URLSessionWebSocketTask.Message
    ) async {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            text = ""
        }

        guard let inbound = RelayInboundMessage.parse(text) else {
            return
        }

        switch inbound {
        case .event(let subscriptionID, let event):
            if var query = querySubscriptions[subscriptionID] {
                query.events.append(event)
                querySubscriptions[subscriptionID] = query
            }
            if let live = liveSubscriptions[subscriptionID] {
                live.continuation.yield(event)
            }

        case .eose(let subscriptionID):
            guard let query = querySubscriptions.removeValue(forKey: subscriptionID) else {
                return
            }
            if let closeRequest = try? serializeJSONArray(["CLOSE", subscriptionID]) {
                try? await send(text: closeRequest)
            }
            query.continuation.resume(returning: query.events)

        case .notice:
            return

        case .closed(let subscriptionID, let reason):
            if let query = querySubscriptions.removeValue(forKey: subscriptionID) {
                query.continuation.resume(throwing: RelayClientError.closed(reason))
            }
            if let live = liveSubscriptions.removeValue(forKey: subscriptionID) {
                live.continuation.finish(throwing: RelayClientError.closed(reason))
            }

        case .ok(let eventID, let accepted, let reason):
            guard let publish = pendingPublishes.removeValue(forKey: eventID) else { return }
            if accepted {
                publish.continuation.resume()
            } else {
                publish.continuation.resume(
                    throwing: RelayClientError.publishRejected(reason ?? "Unknown reason")
                )
            }

        case .auth(let challenge):
            do {
                let authRequest = try relayAuthRequestString(
                    challenge: challenge,
                    relayURL: relayURL
                )
                try await send(text: authRequest)
                try await resendActiveRequests()
            } catch {
                await handleSocketFailure(error)
            }
        }
    }

    private func resendActiveRequests() async throws {
        for subscription in querySubscriptions.values {
            try await send(text: subscription.request)
        }

        for subscription in liveSubscriptions.values {
            try await send(text: subscription.request)
        }

        for publish in pendingPublishes.values {
            try await send(text: publish.request)
        }
    }

    private func handleSocketFailure(
        _ error: Error
    ) async {
        let queryContinuations = querySubscriptions.values.map(\.continuation)
        let liveContinuations = liveSubscriptions.values.map(\.continuation)
        let publishContinuations = pendingPublishes.values.map(\.continuation)

        querySubscriptions.removeAll()
        liveSubscriptions.removeAll()
        pendingPublishes.removeAll()

        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil

        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        for continuation in queryContinuations {
            continuation.resume(throwing: error)
        }
        for continuation in liveContinuations {
            continuation.finish(throwing: error)
        }
        for continuation in publishContinuations {
            continuation.resume(throwing: error)
        }
    }

    private func send(
        text: String
    ) async throws {
        guard let socket else {
            throw RelayClientError.closed("Source socket is unavailable.")
        }
        try await socket.send(.string(text))
    }

    private func awaitPing(
        on socket: URLSessionWebSocketTask
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let singleResumeContinuation = RelaySingleResumeContinuationBox(continuation)
            socket.sendPing { error in
                if let error {
                    singleResumeContinuation.resume(throwing: error)
                } else {
                    singleResumeContinuation.resume(returning: ())
                }
            }
        }
    }

    private func serializeJSONArray(
        _ value: [Any]
    ) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func timeoutNanoseconds(
        for timeout: TimeInterval
    ) -> UInt64 {
        UInt64(max(timeout, 0) * 1_000_000_000)
    }
}

final class NostrRelayClient: @unchecked Sendable {
    private let session: URLSession
    private let connectionPool: NostrRelayPool

    init(
        session: URLSession = .shared,
        connectionPool: NostrRelayPool = .shared
    ) {
        self.session = session
        self.connectionPool = connectionPool
    }

    func fetchEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval = 12
    ) async throws -> [NostrEvent] {
        let validatedRelayURL = try validatedWebSocketRelayURL(relayURL)
        return try await connectionPool.fetchEvents(
            relayURL: validatedRelayURL,
            filter: filter,
            timeout: timeout,
            session: session
        )
    }

    func publishEvent(
        relayURL: URL,
        eventObject: [String: Any],
        eventID: String,
        timeout: TimeInterval = 10
    ) async throws {
        let validatedRelayURL = try validatedWebSocketRelayURL(relayURL)
        try await connectionPool.publishEvent(
            relayURL: validatedRelayURL,
            eventObject: eventObject,
            eventID: eventID,
            timeout: timeout,
            session: session
        )
    }

    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval = 10
    ) async throws {
        guard let eventObject = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            throw RelayClientError.publishRejected("Malformed event payload")
        }

        try await publishEvent(
            relayURL: relayURL,
            eventObject: eventObject,
            eventID: eventID,
            timeout: timeout
        )
    }

    func fetchEvents(
        relayURLString: String,
        filter: NostrFilter,
        timeout: TimeInterval = 12
    ) async throws -> [NostrEvent] {
        guard let relayURL = URL(string: relayURLString) else {
            throw RelayClientError.invalidRelayURL(relayURLString)
        }
        return try await fetchEvents(relayURL: relayURL, filter: filter, timeout: timeout)
    }

    private func validatedWebSocketRelayURL(_ relayURL: URL) throws -> URL {
        guard let normalizedRelayURL = RelayURLSupport.normalizedURL(from: relayURL.absoluteString) else {
            throw RelayClientError.invalidRelayURL(relayURL.absoluteString)
        }
        return normalizedRelayURL
    }
}

extension NostrRelayClient: NostrRelayEventFetching {}
extension NostrRelayClient: NostrRelayEventPublishing {}

private actor SourcePublishFirstSuccessCoordinator {
    private let continuation: CheckedContinuation<SourcePublishOutcome, Never>
    private var remainingCount: Int
    private var successfulSourceCount = 0
    private var firstFailureMessage: String?
    private var attempts: [SourcePublishAttemptReport] = []
    private var didResume = false

    init(
        totalCount: Int,
        continuation: CheckedContinuation<SourcePublishOutcome, Never>
    ) {
        self.remainingCount = totalCount
        self.continuation = continuation
    }

    func record(_ attempt: SourcePublishAttemptReport) {
        guard !didResume else { return }

        attempts.append(attempt)
        remainingCount -= 1

        if attempt.accepted {
            successfulSourceCount += 1
            didResume = true
            continuation.resume(
                returning: SourcePublishOutcome(
                    successfulSourceCount: successfulSourceCount,
                    firstFailureMessage: firstFailureMessage,
                    attempts: attempts
                )
            )
            return
        }

        if firstFailureMessage == nil {
            firstFailureMessage = attempt.failureMessage
        }

        if remainingCount <= 0 {
            didResume = true
            continuation.resume(
                returning: SourcePublishOutcome(
                    successfulSourceCount: successfulSourceCount,
                    firstFailureMessage: firstFailureMessage,
                    attempts: attempts
                )
            )
        }
    }
}

extension NostrRelayEventPublishing {
    func publishEvent(
        to sourceURLs: [URL],
        eventData: Data,
        eventID: String,
        timeout: TimeInterval = 10,
        successPolicy: SourcePublishSuccessPolicy = .waitForAllAcknowledgements
    ) async -> SourcePublishOutcome {
        guard !sourceURLs.isEmpty else {
            return SourcePublishOutcome(successfulSourceCount: 0, firstFailureMessage: nil)
        }

        switch successPolicy {
        case .waitForAllAcknowledgements:
            return await publishEventWaitingForAllSources(
                sourceURLs: sourceURLs,
                eventData: eventData,
                eventID: eventID,
                timeout: timeout
            )
        case .returnAfterFirstSuccess:
            return await publishEventReturningAfterFirstSourceSuccess(
                sourceURLs: sourceURLs,
                eventData: eventData,
                eventID: eventID,
                timeout: timeout
            )
        }
    }

    private func publishEventWaitingForAllSources(
        sourceURLs: [URL],
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async -> SourcePublishOutcome {
        await withTaskGroup(of: SourcePublishAttempt.self, returning: SourcePublishOutcome.self) { group in
            for sourceURL in sourceURLs {
                group.addTask {
                    await publishAttemptReport(
                        publisher: self,
                        sourceURL: sourceURL,
                        eventData: eventData,
                        eventID: eventID,
                        timeout: timeout
                    )
                }
            }

            var successfulSourceCount = 0
            var firstFailureMessage: String?
            var attempts: [SourcePublishAttemptReport] = []

            for await attempt in group {
                attempts.append(attempt)
                recordSourcePublishAttempt(attempt)

                if attempt.accepted {
                    successfulSourceCount += 1
                } else if firstFailureMessage == nil {
                    firstFailureMessage = attempt.failureMessage
                }
            }

            return SourcePublishOutcome(
                successfulSourceCount: successfulSourceCount,
                firstFailureMessage: firstFailureMessage,
                attempts: attempts
            )
        }
    }

    private func publishEventReturningAfterFirstSourceSuccess(
        sourceURLs: [URL],
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async -> SourcePublishOutcome {
        await withCheckedContinuation { continuation in
            let coordinator = SourcePublishFirstSuccessCoordinator(
                totalCount: sourceURLs.count,
                continuation: continuation
            )

            for sourceURL in sourceURLs {
                Task.detached(priority: .userInitiated) {
                    let attempt = await publishAttemptReport(
                        publisher: self,
                        sourceURL: sourceURL,
                        eventData: eventData,
                        eventID: eventID,
                        timeout: timeout
                    )

                    recordSourcePublishAttempt(attempt)
                    await coordinator.record(attempt)
                }
            }
        }
    }
}

private typealias SourcePublishAttempt = SourcePublishAttemptReport

private func recordSourcePublishAttempt(_ attempt: SourcePublishAttemptReport) {
    Task { @MainActor in
        SourcePublishStatsStore.shared.record(attempt)
    }
}

private func publishAttemptReport(
    publisher: any NostrRelayEventPublishing,
    sourceURL: URL,
    eventData: Data,
    eventID: String,
    timeout: TimeInterval
) async -> SourcePublishAttemptReport {
    do {
        try await publisher.publishEvent(
            relayURL: sourceURL,
            eventData: eventData,
            eventID: eventID,
            timeout: timeout
        )
        return SourcePublishAttemptReport(sourceURL: sourceURL, accepted: true)
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return SourcePublishAttemptReport(
            sourceURL: sourceURL,
            accepted: false,
            failureMessage: message,
            rateLimited: SourcePublishFailureClassifier.isRateLimited(error: error, message: message)
        )
    }
}

private enum SourcePublishFailureClassifier {
    static func isRateLimited(error: Error, message: String) -> Bool {
        if let relayError = error as? RelayClientError {
            switch relayError {
            case .publishRejected(let reason):
                return isRateLimitMessage(reason)
            case .invalidRelayURL, .closed, .poolEvicted, .publishTimedOut:
                break
            }
        }

        return isRateLimitMessage(message)
    }

    private static func isRateLimitMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("rate limit") ||
            normalized.contains("rate-limit") ||
            normalized.contains("ratelimit") ||
            normalized.contains("too many") ||
            normalized.contains("too-many") ||
            normalized.contains("limited")
    }
}
