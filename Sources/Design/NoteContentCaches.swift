import Foundation
import NostrSDK

final class NoteParsedContentCache {
    static let shared = NoteParsedContentCache()

    private let maxEntries = 2_000
    private var entries: [String: NoteContentView.ParsedContent] = [:]
    private var recency: [String] = []
    private let lock = NSLock()

    func parsedContent(
        for event: NostrEvent,
        builder: () -> NoteContentView.ParsedContent
    ) -> NoteContentView.ParsedContent {
        let cacheKey = event.id.lowercased()

        lock.lock()
        if let cached = entries[cacheKey] {
            touch(cacheKey)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = builder()

        lock.lock()
        entries[cacheKey] = parsed
        touch(cacheKey)
        if recency.count > maxEntries, let oldest = recency.first {
            recency.removeFirst()
            entries[oldest] = nil
        }
        lock.unlock()

        return parsed
    }

    private func touch(_ key: String) {
        recency.removeAll(where: { $0 == key })
        recency.append(key)
    }
}

final class NoteBlurRevealStateCache {
    static let shared = NoteBlurRevealStateCache()

    private let maxEntries = 2_000
    private var revealedKeys = Set<String>()
    private var recency: [String] = []
    private let lock = NSLock()

    func isRevealed(for key: String) -> Bool {
        guard !key.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }
        return revealedKeys.contains(key)
    }

    func markRevealed(for key: String) {
        guard !key.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        revealedKeys.insert(key)
        touch(key)

        let overflow = recency.count - maxEntries
        guard overflow > 0 else { return }

        for _ in 0..<overflow {
            let removedKey = recency.removeFirst()
            revealedKeys.remove(removedKey)
        }
    }

    private func touch(_ key: String) {
        recency.removeAll(where: { $0 == key })
        recency.append(key)
    }
}
