import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct HaloSystemProfileRecord: Codable, Hashable, Sendable {
    let pubkey: String
    let displayName: String
    let handle: String
    let avatarURL: URL?
    let updatedAt: Date
}

struct HaloSystemNoteRecord: Codable, Hashable, Sendable {
    let eventID: String
    let authorPubkey: String
    let authorName: String
    let text: String
    let createdAt: Date
    let updatedAt: Date
}

struct HaloSystemFeedRecord: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let updatedAt: Date
}

actor HaloSystemEntityRepository {
    static let shared = HaloSystemEntityRepository()

    private enum StorageKey {
        static let profiles = "halo.system-entities.profiles.v1"
        static let notes = "halo.system-entities.notes.v1"
        static let feeds = "halo.system-entities.feeds.v1"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults? = UserDefaults(suiteName: FlowSharedComposeDraftStore.appGroupIdentifier)) {
        self.defaults = defaults ?? .standard
    }

    func profiles() -> [HaloSystemProfileRecord] {
        load([HaloSystemProfileRecord].self, key: StorageKey.profiles)
    }

    func notes() -> [HaloSystemNoteRecord] {
        load([HaloSystemNoteRecord].self, key: StorageKey.notes)
    }

    func feeds() -> [HaloSystemFeedRecord] {
        load([HaloSystemFeedRecord].self, key: StorageKey.feeds)
    }

    func upsert(profile: HaloSystemProfileRecord) {
        var values = profiles().filter { $0.pubkey != profile.pubkey }
        values.insert(profile, at: 0)
        save(Array(values.sorted { $0.updatedAt > $1.updatedAt }.prefix(100)), key: StorageKey.profiles)
    }

    func upsert(note: HaloSystemNoteRecord) {
        var values = notes().filter { $0.eventID != note.eventID }
        values.insert(note, at: 0)
        save(Array(values.sorted { $0.updatedAt > $1.updatedAt }.prefix(200)), key: StorageKey.notes)
    }

    func replace(feeds: [HaloSystemFeedRecord]) {
        save(Array(feeds.prefix(100)), key: StorageKey.feeds)
    }

    private func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value where Value: ExpressibleByArrayLiteral {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode(type, from: data) else {
            return []
        }
        return decoded
    }

    private func save<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

enum HaloSystemIndexer {
    static func recordProfile(
        pubkey: String,
        displayName: String,
        handle: String,
        avatarURL: URL?
    ) async {
        let normalizedPubkey = pubkey.lowercased()
        guard normalizedPubkey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return
        }

        let record = HaloSystemProfileRecord(
            pubkey: normalizedPubkey,
            displayName: normalizedDisplayName(displayName, fallback: shortNostrIdentifier(normalizedPubkey)),
            handle: String(handle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
            avatarURL: avatarURL,
            updatedAt: Date()
        )
        await HaloSystemEntityRepository.shared.upsert(profile: record)

        if #available(iOS 18.0, *) {
            try? await CSSearchableIndex.default().indexAppEntities([HaloProfileEntity(record: record)])
        }
    }

    static func recordNote(_ item: FeedItem) async {
        let event = item.displayEvent
        let eventID = event.id.lowercased()
        let authorPubkey = event.pubkey.lowercased()
        guard eventID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              authorPubkey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return
        }

        let record = HaloSystemNoteRecord(
            eventID: eventID,
            authorPubkey: authorPubkey,
            authorName: normalizedDisplayName(item.displayName, fallback: shortNostrIdentifier(authorPubkey)),
            text: String(event.previewSnippet(maxLength: 500).prefix(500)),
            createdAt: event.createdAtDate,
            updatedAt: Date()
        )
        await HaloSystemEntityRepository.shared.upsert(note: record)

        if #available(iOS 18.0, *) {
            try? await CSSearchableIndex.default().indexAppEntities([HaloNoteEntity(record: record)])
        }
    }

    static func syncFeeds(_ feeds: [CustomFeedDefinition]) async {
        let records = feeds.map { feed in
            HaloSystemFeedRecord(
                id: feed.id.lowercased(),
                name: normalizedDisplayName(feed.name, fallback: "Saved feed"),
                detail: feedDetail(feed),
                updatedAt: Date()
            )
        }
        await HaloSystemEntityRepository.shared.replace(feeds: records)

        if #available(iOS 18.0, *) {
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: HaloFeedEntity.self)
            if !records.isEmpty {
                try? await CSSearchableIndex.default().indexAppEntities(records.map(HaloFeedEntity.init(record:)))
            }
        }
    }

    private static func normalizedDisplayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(160))
    }

    private static func feedDetail(_ feed: CustomFeedDefinition) -> String {
        var parts: [String] = []
        if !feed.hashtags.isEmpty {
            parts.append(feed.hashtags.prefix(3).map { "#\($0)" }.joined(separator: ", "))
        }
        if !feed.authorPubkeys.isEmpty {
            parts.append("\(feed.authorPubkeys.count) people")
        }
        if !feed.phrases.isEmpty {
            parts.append(feed.phrases.prefix(2).joined(separator: ", "))
        }
        return String((parts.isEmpty ? "Custom feed" : parts.joined(separator: " · ")).prefix(240))
    }
}

@available(iOS 18.0, *)
struct HaloProfileEntity: IndexedEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Halo Profile")
    static let defaultQuery = HaloProfileEntityQuery()

    let id: String
    let name: String
    let handle: String
    let avatarURL: URL?

    init(record: HaloSystemProfileRecord) {
        id = record.pubkey
        name = record.displayName
        handle = record.handle
        avatarURL = record.avatarURL
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: handle.isEmpty ? nil : "\(handle)",
            image: avatarURL.map { .init(url: $0) } ?? .init(systemName: "person.crop.circle")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = handle
        attributes.contentURL = HaloDeepLinkRoute.profile(pubkey: id).url
        attributes.thumbnailURL = avatarURL
        attributes.keywords = [name, handle, id]
        return attributes
    }
}

@available(iOS 18.0, *)
struct HaloProfileEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [HaloProfileEntity.ID]) async throws -> [HaloProfileEntity] {
        let requested = Set(identifiers.map { $0.lowercased() })
        return await HaloSystemEntityRepository.shared.profiles()
            .filter { requested.contains($0.pubkey) }
            .map(HaloProfileEntity.init(record:))
    }

    func suggestedEntities() async throws -> [HaloProfileEntity] {
        await HaloSystemEntityRepository.shared.profiles().prefix(20).map(HaloProfileEntity.init(record:))
    }

    func entities(matching string: String) async throws -> [HaloProfileEntity] {
        let terms = normalizedTerms(string)
        return await HaloSystemEntityRepository.shared.profiles()
            .filter { record in
                terms.allSatisfy { term in
                    record.displayName.localizedCaseInsensitiveContains(term) ||
                        record.handle.localizedCaseInsensitiveContains(term) ||
                        record.pubkey.contains(term.lowercased())
                }
            }
            .prefix(40)
            .map(HaloProfileEntity.init(record:))
    }
}

@available(iOS 18.0, *)
struct HaloNoteEntity: IndexedEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Halo Note")
    static let defaultQuery = HaloNoteEntityQuery()

    let id: String
    let authorPubkey: String
    let authorName: String
    let text: String
    let createdAt: Date

    init(record: HaloSystemNoteRecord) {
        id = record.eventID
        authorPubkey = record.authorPubkey
        authorName = record.authorName
        text = record.text
        createdAt = record.createdAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: text.isEmpty ? "Note from \(authorName)" : "\(text)",
            subtitle: "By \(authorName)",
            image: .init(systemName: "text.bubble")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = text.isEmpty ? "Note from \(authorName)" : text
        attributes.displayName = authorName
        attributes.contentDescription = text
        attributes.contentCreationDate = createdAt
        attributes.contentURL = HaloDeepLinkRoute.note(reference: id).url
        attributes.keywords = [authorName, authorPubkey, id]
        return attributes
    }
}

@available(iOS 18.0, *)
struct HaloNoteEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [HaloNoteEntity.ID]) async throws -> [HaloNoteEntity] {
        let requested = Set(identifiers.map { $0.lowercased() })
        return await HaloSystemEntityRepository.shared.notes()
            .filter { requested.contains($0.eventID) }
            .map(HaloNoteEntity.init(record:))
    }

    func suggestedEntities() async throws -> [HaloNoteEntity] {
        await HaloSystemEntityRepository.shared.notes().prefix(20).map(HaloNoteEntity.init(record:))
    }

    func entities(matching string: String) async throws -> [HaloNoteEntity] {
        let terms = normalizedTerms(string)
        return await HaloSystemEntityRepository.shared.notes()
            .filter { record in
                terms.allSatisfy { term in
                    record.text.localizedCaseInsensitiveContains(term) ||
                        record.authorName.localizedCaseInsensitiveContains(term)
                }
            }
            .prefix(40)
            .map(HaloNoteEntity.init(record:))
    }
}

@available(iOS 18.0, *)
struct HaloFeedEntity: IndexedEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Halo Feed")
    static let defaultQuery = HaloFeedEntityQuery()

    let id: String
    let name: String
    let detail: String

    init(record: HaloSystemFeedRecord) {
        id = record.id
        name = record.name
        detail = record.detail
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(detail)",
            image: .init(systemName: "square.stack.3d.up")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.contentDescription = detail
        attributes.contentURL = HaloDeepLinkRoute.feed(id: id).url
        attributes.keywords = [name, detail]
        return attributes
    }
}

@available(iOS 18.0, *)
struct HaloFeedEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [HaloFeedEntity.ID]) async throws -> [HaloFeedEntity] {
        let requested = Set(identifiers.map { $0.lowercased() })
        return await HaloSystemEntityRepository.shared.feeds()
            .filter { requested.contains($0.id) }
            .map(HaloFeedEntity.init(record:))
    }

    func suggestedEntities() async throws -> [HaloFeedEntity] {
        await HaloSystemEntityRepository.shared.feeds().prefix(20).map(HaloFeedEntity.init(record:))
    }

    func entities(matching string: String) async throws -> [HaloFeedEntity] {
        let terms = normalizedTerms(string)
        return await HaloSystemEntityRepository.shared.feeds()
            .filter { record in
                terms.allSatisfy { term in
                    record.name.localizedCaseInsensitiveContains(term) ||
                        record.detail.localizedCaseInsensitiveContains(term)
                }
            }
            .prefix(40)
            .map(HaloFeedEntity.init(record:))
    }
}

private func normalizedTerms(_ value: String) -> [String] {
    value
        .split(whereSeparator: \Character.isWhitespace)
        .map(String.init)
        .filter { !$0.isEmpty }
}
