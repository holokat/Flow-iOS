import Foundation

struct EventPersistencePolicy: Sendable {
    static let wispPersistedKinds: Set<Int> = [
        0,
        1,
        6,
        7,
        20,
        21,
        22,
        1_068,
        6_969,
        9_735,
        30_023
    ]

    let currentUserPubkey: String?

    init(currentUserPubkey: String? = nil) {
        let normalizedPubkey = currentUserPubkey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.currentUserPubkey = normalizedPubkey?.isEmpty == true ? nil : normalizedPubkey
    }

    func shouldPersist(_ event: NostrEvent) -> Bool {
        let authorPubkey = event.pubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let currentUserPubkey, authorPubkey == currentUserPubkey {
            return true
        }

        return Self.wispPersistedKinds.contains(event.kind)
    }
}
