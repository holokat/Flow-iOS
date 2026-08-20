import Foundation
import NostrSDK

enum NoteRenderEnvelopeSafety {
    static func normalizedEventID(_ rawValue: String) -> String? {
        normalizedHex(rawValue, expectedByteCount: 64)
    }

    static func normalizedPubkey(_ rawValue: String) -> String? {
        normalizedHex(rawValue, expectedByteCount: 64)
    }

    private static func normalizedHex(
        _ rawValue: String,
        expectedByteCount: Int
    ) -> String? {
        let bytes = Array(rawValue.utf8.prefix(expectedByteCount + 1))
        guard bytes.count == expectedByteCount,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte) ||
                      (65...70).contains(byte) ||
                      (97...102).contains(byte)
              }) else {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self).lowercased()
    }
}

final class NoteParsedContentCache {
    static let shared = NoteParsedContentCache()

    private final class Entry: NSObject {
        let value: NoteContentView.ParsedContent

        init(_ value: NoteContentView.ParsedContent) {
            self.value = value
        }
    }

    private let entries = NSCache<NSString, Entry>()

    init(maxEntries: Int = 2_000) {
        entries.countLimit = max(maxEntries, 1)
    }

    func parsedContent(
        for event: NostrEvent,
        builder: () -> NoteContentView.ParsedContent
    ) -> NoteContentView.ParsedContent {
        guard let cacheKey = NoteRenderEnvelopeSafety.normalizedEventID(event.id) else {
            return builder()
        }

        if let cached = entries.object(forKey: cacheKey as NSString) {
            return cached.value
        }

        let parsed = builder()
        entries.setObject(Entry(parsed), forKey: cacheKey as NSString)

        return parsed
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
