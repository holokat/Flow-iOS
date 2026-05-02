import Foundation

actor MetadataRequestCoordinator {
    static let shared = MetadataRequestCoordinator()

    private let profileBatchLimit: Int
    private let profileFlushDelayNanoseconds: UInt64
    private var pendingProfilePubkeys = Set<String>()

    init(
        profileBatchLimit: Int = 200,
        profileFlushDelayNanoseconds: UInt64 = 100_000_000
    ) {
        self.profileBatchLimit = max(profileBatchLimit, 1)
        self.profileFlushDelayNanoseconds = profileFlushDelayNanoseconds
    }

    func collectProfiles(_ pubkeys: [String]) async -> [String] {
        let localPubkeys = Set(
            pubkeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !localPubkeys.isEmpty else { return [] }

        pendingProfilePubkeys.formUnion(localPubkeys)

        if pendingProfilePubkeys.count >= profileBatchLimit {
            return drainProfiles()
        }

        try? await Task.sleep(nanoseconds: profileFlushDelayNanoseconds)
        return drainProfiles()
    }

    func drainProfiles() -> [String] {
        let drained = Array(pendingProfilePubkeys).sorted()
        pendingProfilePubkeys.removeAll(keepingCapacity: true)
        return drained
    }
}
