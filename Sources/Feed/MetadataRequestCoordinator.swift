import Foundation

struct MetadataProfileRequest: Sendable {
    let pubkeysToFetch: [String]
    let requestedPubkeys: [String]
}

actor MetadataRequestCoordinator {
    static let shared = MetadataRequestCoordinator()

    private let profileBatchLimit: Int
    private let profileFlushDelayNanoseconds: UInt64
    private var pendingProfilePubkeys = Set<String>()
    private var inFlightProfilePubkeys = Set<String>()
    private var profileWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        profileBatchLimit: Int = 200,
        profileFlushDelayNanoseconds: UInt64 = 100_000_000
    ) {
        self.profileBatchLimit = max(profileBatchLimit, 1)
        self.profileFlushDelayNanoseconds = profileFlushDelayNanoseconds
    }

    func collectProfiles(_ pubkeys: [String]) async -> MetadataProfileRequest {
        let localPubkeys = Set(
            pubkeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !localPubkeys.isEmpty else {
            return MetadataProfileRequest(pubkeysToFetch: [], requestedPubkeys: [])
        }

        pendingProfilePubkeys.formUnion(localPubkeys.subtracting(inFlightProfilePubkeys))

        if pendingProfilePubkeys.count >= profileBatchLimit {
            return drainProfiles(requestedPubkeys: localPubkeys)
        }

        try? await Task.sleep(nanoseconds: profileFlushDelayNanoseconds)
        return drainProfiles(requestedPubkeys: localPubkeys)
    }

    func completeProfiles(_ pubkeys: [String]) {
        let completedPubkeys = Set(
            pubkeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !completedPubkeys.isEmpty else { return }

        inFlightProfilePubkeys.subtract(completedPubkeys)
        for pubkey in completedPubkeys {
            let waiters = profileWaiters.removeValue(forKey: pubkey) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitForProfiles(_ pubkeys: [String]) async {
        let pendingPubkeys = Set(
            pubkeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        .intersection(inFlightProfilePubkeys)

        await withTaskGroup(of: Void.self) { group in
            for pubkey in pendingPubkeys {
                group.addTask {
                    await self.waitForProfile(pubkey)
                }
            }
        }
    }

    private func drainProfiles(requestedPubkeys: Set<String>) -> MetadataProfileRequest {
        let drained = Array(pendingProfilePubkeys).sorted()
        pendingProfilePubkeys.removeAll(keepingCapacity: true)
        inFlightProfilePubkeys.formUnion(drained)
        return MetadataProfileRequest(
            pubkeysToFetch: drained,
            requestedPubkeys: Array(requestedPubkeys).sorted()
        )
    }

    private func waitForProfile(_ pubkey: String) async {
        guard inFlightProfilePubkeys.contains(pubkey) else { return }

        await withCheckedContinuation { continuation in
            profileWaiters[pubkey, default: []].append(continuation)
        }
    }
}
