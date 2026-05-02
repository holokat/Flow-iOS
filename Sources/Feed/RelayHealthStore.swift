import Foundation

actor RelayHealthStore {
    static let shared = RelayHealthStore()

    struct Configuration: Sendable {
        var maxEphemeralConnections = 50
        var rejectionCooldown: TimeInterval = 60
        var transportFailureCooldown: TimeInterval = 600
    }

    private let configuration: Configuration
    private var cooldownUntilByRelay: [String: Date] = [:]

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func isAvailable(_ relayURL: URL, now: Date = Date()) -> Bool {
        let key = relayKey(relayURL)
        guard let cooldownUntil = cooldownUntilByRelay[key] else { return true }
        return cooldownUntil <= now
    }

    func recordFailure(_ error: Error, relayURL: URL, now: Date = Date()) {
        guard let interval = cooldownInterval(for: error) else { return }
        cooldownUntilByRelay[relayKey(relayURL)] = now.addingTimeInterval(interval)
    }

    private func cooldownInterval(for error: Error) -> TimeInterval? {
        if case RelayConnectionTimeoutError.timedOut = error {
            return nil
        }
        if let relayError = error as? RelayClientError {
            switch relayError {
            case .invalidRelayURL, .poolEvicted, .publishTimedOut:
                return nil
            case .publishRejected(let reason), .closed(let reason):
                return isRejection(reason)
                    ? configuration.rejectionCooldown
                    : configuration.transportFailureCooldown
            }
        }

        return configuration.transportFailureCooldown
    }

    private func isRejection(_ reason: String) -> Bool {
        let message = reason.lowercased()
        return message.contains("restricted") ||
            message.contains("rate") ||
            message.contains("blocked") ||
            message.range(of: #"\b4\d{2}\b"#, options: .regularExpression) != nil
    }

    func clearCooldown(_ relayURL: URL) {
        cooldownUntilByRelay[relayKey(relayURL)] = nil
    }

    private func relayKey(_ relayURL: URL) -> String {
        RelayURLSupport.normalizedRelayURLString(relayURL)
            ?? relayURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
