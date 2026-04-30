import Foundation

struct RelayTimelineFetcher: Sendable {
    private let relayClient: any NostrRelayEventFetching
    private let timelineCache: any TimelineEventCaching
    private let seenEventStore: any SeenEventStoring
    private let dittoEOSEGraceTimeout: TimeInterval

    init(
        relayClient: any NostrRelayEventFetching,
        timelineCache: any TimelineEventCaching,
        seenEventStore: any SeenEventStoring,
        dittoEOSEGraceTimeout: TimeInterval = 0.3
    ) {
        self.relayClient = relayClient
        self.timelineCache = timelineCache
        self.seenEventStore = seenEventStore
        self.dittoEOSEGraceTimeout = dittoEOSEGraceTimeout
    }

    func fetchTimelineEvents(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true
    ) async throws -> [NostrEvent] {
        let events: [NostrEvent]
        let fetchOperation = {
            try await fetchEventsEnforcingTimeout(
                relayURL: relayURL,
                filter: filter,
                timeout: timeout
            )
        }
        if !useCache {
            events = try await fetchOperation()
        } else {
            let cacheKey = generateTimelineKey(relayURL: relayURL, filter: filter)
            events = try await timelineCache.events(for: cacheKey) {
                try await fetchOperation()
            }
        }

        if !events.isEmpty {
            await seenEventStore.store(events: events)
        }
        return events
    }

    func fetchTimelineEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [NostrEvent] {
        try await fetchMergedRelayEvents(
            relayURLs: relayURLs,
            filter: filter,
            timeout: timeout,
            useCache: useCache,
            relayFetchMode: relayFetchMode
        )
    }

    func fetchTimelineEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true,
        relayFetchMode: RelayFetchMode = .allRelays,
        relayOnly: Bool
    ) async throws -> [NostrEvent] {
        let _ = relayOnly
        return try await fetchMergedRelayEvents(
            relayURLs: relayURLs,
            filter: filter,
            timeout: timeout,
            useCache: useCache,
            relayFetchMode: relayFetchMode
        )
    }

    func fetchTimelineEventsFromRelaysOnly(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval = 12,
        useCache: Bool = true,
        relayFetchMode: RelayFetchMode = .allRelays
    ) async throws -> [NostrEvent] {
        try await fetchMergedRelayEvents(
            relayURLs: relayURLs,
            filter: filter,
            timeout: timeout,
            useCache: useCache,
            relayFetchMode: relayFetchMode
        )
    }

    private func fetchMergedRelayEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval,
        useCache: Bool,
        relayFetchMode: RelayFetchMode
    ) async throws -> [NostrEvent] {
        let targets = normalizedRelayURLs(relayURLs)
        guard !targets.isEmpty else { return [] }

        switch relayFetchMode {
        case .firstRelayWithEvents:
            return try await fetchFirstRelayWithEvents(
                relayURLs: targets,
                filter: filter,
                timeout: timeout,
                useCache: useCache
            )
        case .firstNonEmptyRelay:
            return try await fetchFirstNonEmptyRelay(
                relayURLs: targets,
                filter: filter,
                timeout: timeout,
                useCache: useCache
            )
        case .allRelays:
            return try await fetchAllRelays(
                relayURLs: targets,
                filter: filter,
                timeout: timeout,
                useCache: useCache
            )
        }
    }

    private func fetchFirstRelayWithEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval,
        useCache: Bool
    ) async throws -> [NostrEvent] {
        let result: (events: [NostrEvent], successfulFetches: Int, firstError: Error?) = await withTaskGroup(
            of: (events: [NostrEvent]?, error: Error?).self,
            returning: (events: [NostrEvent], successfulFetches: Int, firstError: Error?).self
        ) { group in
            for relayURL in relayURLs {
                group.addTask {
                    do {
                        let events = try await fetchTimelineEvents(
                            relayURL: relayURL,
                            filter: filter,
                            timeout: timeout,
                            useCache: useCache
                        )
                        return (events: events, error: nil)
                    } catch {
                        return (events: nil, error: error)
                    }
                }
            }

            var firstError: Error?
            var successfulFetches = 0

            for await item in group {
                if let events = item.events {
                    successfulFetches += 1
                    guard !events.isEmpty else { continue }
                    group.cancelAll()
                    return (events, successfulFetches, firstError)
                } else if firstError == nil, let error = item.error {
                    firstError = error
                }
            }

            return ([], successfulFetches, firstError)
        }

        if !result.events.isEmpty {
            return mergedTimelineEvents(result.events, filter: filter)
        }

        if result.successfulFetches == 0, let firstError = result.firstError {
            throw firstError
        }
        return []
    }

    private func fetchFirstNonEmptyRelay(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval,
        useCache: Bool
    ) async throws -> [NostrEvent] {
        let result = await fetchFirstNonEmptyRelayResult(
            relayURLs: relayURLs,
            filter: filter,
            timeout: timeout,
            useCache: useCache
        )

        if result.successfulFetches > 0 {
            return mergedTimelineEvents(result.mergedEvents, filter: filter)
        }

        if !result.didTimeOut, result.successfulFetches == 0, let firstError = result.firstError {
            throw firstError
        }
        return []
    }

    private func fetchAllRelays(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval,
        useCache: Bool
    ) async throws -> [NostrEvent] {
        let result: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?) = await withTaskGroup(
            of: (events: [NostrEvent]?, error: Error?).self,
            returning: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?).self
        ) { group in
            for relayURL in relayURLs {
                group.addTask {
                    do {
                        let events = try await fetchTimelineEvents(
                            relayURL: relayURL,
                            filter: filter,
                            timeout: timeout,
                            useCache: useCache
                        )
                        return (events: events, error: nil)
                    } catch {
                        return (events: nil, error: error)
                    }
                }
            }

            var mergedEvents: [NostrEvent] = []
            var firstError: Error?
            var successfulFetches = 0

            for await item in group {
                if let events = item.events {
                    successfulFetches += 1
                    mergedEvents.append(contentsOf: events)
                } else if firstError == nil, let error = item.error {
                    firstError = error
                }
            }

            return (mergedEvents, successfulFetches, firstError)
        }

        if result.successfulFetches > 0 {
            return mergedTimelineEvents(result.mergedEvents, filter: filter)
        }

        if result.successfulFetches == 0, let firstError = result.firstError {
            throw firstError
        }
        return []
    }

    private func fetchFirstNonEmptyRelayResult(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval,
        useCache: Bool
    ) async -> (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?, didTimeOut: Bool) {
        enum RelayProgress {
            case relay(events: [NostrEvent]?, error: Error?)
            case deadline
            case graceWindowClosed
        }

        return await withTaskGroup(
            of: RelayProgress.self,
            returning: (mergedEvents: [NostrEvent], successfulFetches: Int, firstError: Error?, didTimeOut: Bool).self
        ) { group in
            for relayURL in relayURLs {
                group.addTask {
                    do {
                        let events = try await fetchTimelineEvents(
                            relayURL: relayURL,
                            filter: filter,
                            timeout: timeout,
                            useCache: useCache
                        )
                        return .relay(events: events, error: nil)
                    } catch {
                        return .relay(events: nil, error: error)
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds(for: timeout))
                return .deadline
            }

            var mergedEvents: [NostrEvent] = []
            var firstError: Error?
            var successfulFetches = 0
            var hasStartedGraceWindow = false

            for await progress in group {
                switch progress {
                case .relay(let events, let error):
                    if let events {
                        successfulFetches += 1
                        mergedEvents.append(contentsOf: events)

                        if !hasStartedGraceWindow {
                            hasStartedGraceWindow = true
                            let graceTimeout = min(timeout, dittoEOSEGraceTimeout)
                            group.addTask {
                                try? await Task.sleep(
                                    nanoseconds: Self.timeoutNanoseconds(for: graceTimeout)
                                )
                                return .graceWindowClosed
                            }
                        }
                    } else if firstError == nil, let error {
                        firstError = error
                    }
                case .graceWindowClosed:
                    if successfulFetches > 0 {
                        group.cancelAll()
                        return (mergedEvents, successfulFetches, firstError, false)
                    }
                case .deadline:
                    group.cancelAll()
                    return (mergedEvents, successfulFetches, firstError, true)
                }
            }

            return (mergedEvents, successfulFetches, firstError, false)
        }
    }

    private func fetchEventsEnforcingTimeout(
        relayURL: URL,
        filter: NostrFilter,
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        guard timeout > 0 else {
            return try await relayClient.fetchEvents(
                relayURL: relayURL,
                filter: filter,
                timeout: timeout
            )
        }

        return try await withThrowingTaskGroup(of: [NostrEvent].self) { group in
            group.addTask {
                try await relayClient.fetchEvents(
                    relayURL: relayURL,
                    filter: filter,
                    timeout: timeout
                )
            }

            group.addTask {
                try await Task.sleep(
                    nanoseconds: Self.timeoutNanoseconds(for: timeout)
                )
                throw RelayFetchTimeoutError.timedOut
            }

            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw RelayFetchTimeoutError.timedOut
            }
            return result
        }
    }

    private nonisolated static func timeoutNanoseconds(for timeout: TimeInterval) -> UInt64 {
        UInt64(max(timeout, 0) * 1_000_000_000)
    }

    private func mergedTimelineEvents(_ events: [NostrEvent], filter: NostrFilter) -> [NostrEvent] {
        let merged = deduplicateEvents(events).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }

        if let limit = filter.limit {
            return Array(merged.prefix(limit))
        }
        return merged
    }

    private func deduplicateEvents(_ events: [NostrEvent]) -> [NostrEvent] {
        var uniqueEvents: [NostrEvent] = []
        var seen = Set<String>()
        for event in events {
            let normalizedID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty, !seen.contains(normalizedID) else { continue }
            uniqueEvents.append(event)
            seen.insert(normalizedID)
        }
        return uniqueEvents
    }

    private func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var normalized: [URL] = []
        for relayURL in relayURLs {
            let key = relayURL.absoluteString.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            normalized.append(relayURL)
        }
        return normalized
    }
}

private enum RelayFetchTimeoutError: Error {
    case timedOut
}
