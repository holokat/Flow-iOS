import Combine
import Foundation

struct PollResultsSnapshot: Equatable, Sendable {
    static let empty = PollResultsSnapshot(results: nil, isLoading: false, lastFetchedAt: nil)

    let results: NostrPollResults?
    let isLoading: Bool
    let lastFetchedAt: Date?
}

enum PollResultsError: LocalizedError {
    case missingRelaySources
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .missingRelaySources:
            return "No sources are available for this poll."
        case .loadFailed:
            return "Couldn't load poll results right now."
        }
    }
}

@MainActor
final class PollResultsStore {
    static let shared = PollResultsStore()

    private var resultsByPollID: [String: NostrPollResults] = [:]
    private var loadingPollIDs: Set<String> = []

    private let relayClient: any NostrRelayEventFetching
    private let automaticRefreshInterval: TimeInterval
    private var inFlightTasks: [String: Task<NostrPollResults, Error>] = [:]
    private var lastFetchedAtByPollID: [String: Date] = [:]
    private var snapshotPublishers: [String: CurrentValueSubject<PollResultsSnapshot, Never>] = [:]

    init(
        relayClient: any NostrRelayEventFetching = NostrRelayClient(),
        automaticRefreshInterval: TimeInterval = 30
    ) {
        self.relayClient = relayClient
        self.automaticRefreshInterval = automaticRefreshInterval
    }

    func results(for pollEventID: String) -> NostrPollResults? {
        resultsByPollID[normalizedPollID(pollEventID)]
    }

    func isLoadingResults(for pollEventID: String) -> Bool {
        loadingPollIDs.contains(normalizedPollID(pollEventID))
    }

    func snapshot(for pollEventID: String) -> PollResultsSnapshot {
        let normalizedPollEventID = normalizedPollID(pollEventID)
        guard !normalizedPollEventID.isEmpty else { return .empty }
        return buildSnapshot(for: normalizedPollEventID)
    }

    func publisher(for pollEventID: String) -> AnyPublisher<PollResultsSnapshot, Never> {
        let normalizedPollEventID = normalizedPollID(pollEventID)
        guard !normalizedPollEventID.isEmpty else {
            return Just(.empty).eraseToAnyPublisher()
        }

        return snapshotPublisher(for: normalizedPollEventID)
            .eraseToAnyPublisher()
    }

    func loadResultsIfNeeded(
        for event: NostrEvent,
        poll: NostrPollMetadata,
        relayURLs: [URL]
    ) async {
        let pollEventID = normalizedPollID(event.id)
        if let lastFetchedAt = lastFetchedAtByPollID[pollEventID],
           resultsByPollID[pollEventID] != nil,
           Date().timeIntervalSince(lastFetchedAt) < automaticRefreshInterval {
            return
        }

        do {
            _ = try await refreshResults(
                for: event,
                poll: poll,
                relayURLs: relayURLs
            )
        } catch {
            // Keep the UI usable even when a relay fetch fails.
        }
    }

    func refreshResults(
        for event: NostrEvent,
        poll: NostrPollMetadata,
        relayURLs: [URL]
    ) async throws -> NostrPollResults {
        let pollEventID = normalizedPollID(event.id)
        if let task = inFlightTasks[pollEventID] {
            return try await task.value
        }

        let targetRelayURLs = preferredRelayURLs(
            taggedRelayURLs: poll.relayURLs,
            fallbackRelayURLs: relayURLs
        )
        guard !targetRelayURLs.isEmpty else {
            throw PollResultsError.missingRelaySources
        }

        setLoading(true, for: pollEventID)

        let task = Task { [relayClient] () throws -> NostrPollResults in
            let responseEvents = try await Self.fetchResponseEvents(
                relayClient: relayClient,
                relayURLs: targetRelayURLs,
                pollEventID: event.id,
                endsAt: poll.endsAt
            )
            let responses = responseEvents.compactMap { responseEvent in
                NostrPollResponse(
                    event: responseEvent,
                    validOptionIDs: poll.validOptionIDs,
                    allowsMultipleChoices: poll.pollType.allowsMultipleChoices
                )
            }
            return NostrPollResults.build(for: poll, responses: responses)
        }

        inFlightTasks[pollEventID] = task
        defer {
            inFlightTasks[pollEventID] = nil
            setLoading(false, for: pollEventID)
        }

        do {
            let results = try await task.value
            setResults(results, fetchedAt: Date(), for: pollEventID)
            return results
        } catch {
            if let existing = resultsByPollID[pollEventID] {
                return existing
            }
            throw error
        }
    }

    func applyOptimisticVote(
        pollEventID: String,
        poll: NostrPollMetadata,
        pubkey: String,
        selectedOptionIDs: [String]
    ) {
        guard !selectedOptionIDs.isEmpty else { return }

        let normalizedPollEventID = normalizedPollID(pollEventID)
        let normalizedPubkey = pubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedPubkey.isEmpty else { return }

        var nextResults = resultsByPollID[normalizedPollEventID] ?? .empty(for: poll)
        guard !nextResults.voters.contains(normalizedPubkey) else { return }

        var voters = nextResults.voters
        voters.insert(normalizedPubkey)

        var optionVoters = nextResults.optionVoters
        for optionID in selectedOptionIDs where poll.validOptionIDs.contains(optionID) {
            var current = optionVoters[optionID, default: []]
            current.insert(normalizedPubkey)
            optionVoters[optionID] = current
        }

        nextResults = NostrPollResults(
            totalVotes: nextResults.totalVotes + selectedOptionIDs.count,
            voters: voters,
            optionVoters: optionVoters
        )
        setResults(nextResults, fetchedAt: Date(), for: normalizedPollEventID)
    }

    private func preferredRelayURLs(
        taggedRelayURLs: [URL],
        fallbackRelayURLs: [URL]
    ) -> [URL] {
        let candidates = taggedRelayURLs + fallbackRelayURLs
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in candidates {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }

    private func normalizedPollID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func buildSnapshot(for pollEventID: String) -> PollResultsSnapshot {
        PollResultsSnapshot(
            results: resultsByPollID[pollEventID],
            isLoading: loadingPollIDs.contains(pollEventID),
            lastFetchedAt: lastFetchedAtByPollID[pollEventID]
        )
    }

    private func snapshotPublisher(for pollEventID: String) -> CurrentValueSubject<PollResultsSnapshot, Never> {
        if let existingPublisher = snapshotPublishers[pollEventID] {
            return existingPublisher
        }

        let publisher = CurrentValueSubject<PollResultsSnapshot, Never>(buildSnapshot(for: pollEventID))
        snapshotPublishers[pollEventID] = publisher
        return publisher
    }

    private func publishSnapshot(for pollEventID: String) {
        let normalizedPollEventID = normalizedPollID(pollEventID)
        guard !normalizedPollEventID.isEmpty else { return }

        let snapshot = buildSnapshot(for: normalizedPollEventID)
        let publisher = snapshotPublisher(for: normalizedPollEventID)
        guard publisher.value != snapshot else { return }
        publisher.send(snapshot)
    }

    private func setResults(_ results: NostrPollResults, fetchedAt: Date, for pollEventID: String) {
        let normalizedPollEventID = normalizedPollID(pollEventID)
        guard !normalizedPollEventID.isEmpty else { return }

        resultsByPollID[normalizedPollEventID] = results
        lastFetchedAtByPollID[normalizedPollEventID] = fetchedAt
        publishSnapshot(for: normalizedPollEventID)
    }

    private func setLoading(_ isLoading: Bool, for pollEventID: String) {
        let normalizedPollEventID = normalizedPollID(pollEventID)
        guard !normalizedPollEventID.isEmpty else { return }

        let didChange: Bool
        if isLoading {
            didChange = loadingPollIDs.insert(normalizedPollEventID).inserted
        } else {
            didChange = loadingPollIDs.remove(normalizedPollEventID) != nil
        }

        guard didChange else { return }
        publishSnapshot(for: normalizedPollEventID)
    }

    private static func fetchResponseEvents(
        relayClient: any NostrRelayEventFetching,
        relayURLs: [URL],
        pollEventID: String,
        endsAt: Int?
    ) async throws -> [NostrEvent] {
        let referencedPollEventIDs = normalizedFilterValues(from: [pollEventID, pollEventID.lowercased()])
        let filter = NostrFilter(
            kinds: [NostrPollKind.response],
            limit: 1_000,
            until: endsAt,
            tagFilters: ["e": referencedPollEventIDs]
        )

        let outcome: (events: [NostrEvent], successfulFetches: Int, firstError: Error?) =
            await withTaskGroup(
                of: (events: [NostrEvent]?, error: Error?).self,
                returning: (events: [NostrEvent], successfulFetches: Int, firstError: Error?).self
            ) { group in
                for relayURL in relayURLs {
                    group.addTask {
                        do {
                            let events = try await relayClient.fetchEvents(
                                relayURL: relayURL,
                                filter: filter,
                                timeout: 10
                            )
                            return (events: events, error: nil)
                        } catch {
                            return (events: nil, error: error)
                        }
                    }
                }

                var mergedEvents: [NostrEvent] = []
                var successfulFetches = 0
                var firstError: Error?

                for await result in group {
                    if let events = result.events {
                        mergedEvents.append(contentsOf: events)
                        successfulFetches += 1
                    } else if firstError == nil {
                        firstError = result.error
                    }
                }

                return (mergedEvents, successfulFetches, firstError)
            }

        if outcome.events.isEmpty, outcome.successfulFetches == 0, let firstError = outcome.firstError {
            throw firstError
        }

        var seenEventIDs = Set<String>()
        return outcome.events.filter { event in
            let normalizedEventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedEventID.isEmpty else { return false }
            return seenEventIDs.insert(normalizedEventID).inserted
        }
    }

    private static func normalizedFilterValues(from values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized
    }
}
