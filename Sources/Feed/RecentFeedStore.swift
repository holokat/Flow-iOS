import CryptoKit
import Foundation

actor RecentFeedStore {
    static let shared = RecentFeedStore()

    private struct Payload: Codable {
        let storedAt: Date
        let events: [NostrEvent]
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let decoder = JSONDecoder()
    private let eventRepository: EventRepository

    init(
        fileManager: FileManager = .default,
        eventRepository: EventRepository = .shared
    ) {
        self.fileManager = fileManager
        self.eventRepository = eventRepository
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directoryURL = root.appendingPathComponent("x21-recent-feeds", isDirectory: true)
    }

    func getRecentFeed(key: String) async -> [NostrEvent]? {
        if let cached = await eventRepository.recentFeed(key: key), !cached.isEmpty {
            return cached
        }

        ensureDirectory()
        let url = fileURL(for: key)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return nil
        }

        if !payload.events.isEmpty {
            await eventRepository.storeRecentFeed(key: key, events: payload.events)
        }
        return payload.events
    }

    func putRecentFeed(key: String, events: [NostrEvent]) async {
        await eventRepository.storeRecentFeed(key: key, events: events)

        ensureDirectory()
        let legacyURL = fileURL(for: key)
        if fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
    }

    private func ensureDirectory() {
        if fileManager.fileExists(atPath: directoryURL.path) {
            return
        }

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hashed = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(hashed).json", isDirectory: false)
    }
}
