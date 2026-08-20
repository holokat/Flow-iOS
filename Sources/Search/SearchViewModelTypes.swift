import Foundation
import NostrSDK

private struct SearchQueryMetadataDecoder: MetadataCoding {}

extension SearchViewModel {
    enum SearchScope: String {
        case people
        case notes
    }

    struct SearchQueryDescriptor: Equatable {
        let rawText: String

        var trimmed: String {
            rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var isEmpty: Bool {
            trimmed.isEmpty
        }

        var normalizedProfileQuery: String {
            var value = trimmed.lowercased()
            if value.hasPrefix("@") {
                value.removeFirst()
            }
            return value
        }

        var normalizedPeopleOnlyProfileQuery: String {
            var value = normalizedProfileQuery
            while value.hasPrefix("#") {
                value.removeFirst()
            }
            return value
        }

        var normalizedHashtag: String? {
            let value = trimmed.lowercased()
            guard value.hasPrefix("#") else { return nil }

            let raw = value
                .drop(while: { $0 == "#" })
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init) ?? ""
            let hashtag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return hashtag.isEmpty ? nil : hashtag
        }

        var eventReference: NostrEventReferencePointer? {
            let normalized = normalizedIdentifier(from: trimmed)
            guard normalized.hasPrefix("note1") ||
                normalized.hasPrefix("nevent1") ||
                normalized.hasPrefix("naddr1") ||
                isReplaceableCoordinate(normalized) else {
                return nil
            }
            return NoteContentParser.eventReferencePointer(from: normalized)
        }

        var resolvedProfilePubkey: String? {
            let normalized = normalizedIdentifier(from: trimmed)
            guard !normalized.isEmpty else { return nil }

            if normalized.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
                return normalized
            }

            if normalized.hasPrefix("npub1") {
                return PublicKey(npub: normalized)?.hex.lowercased()
            }

            if normalized.hasPrefix("nprofile1") {
                let decoder = SearchQueryMetadataDecoder()
                let metadata = try? decoder.decodedMetadata(from: normalized)
                return metadata?.pubkey?.lowercased()
            }

            return nil
        }

        var suggestedContentSearch: SuggestedContentSearch? {
            guard !trimmed.isEmpty else { return nil }

            if let eventReference {
                return SuggestedContentSearch(kind: .eventReference(eventReference))
            }

            if let hashtag = normalizedHashtag {
                return SuggestedContentSearch(kind: .hashtag(hashtag))
            }

            return SuggestedContentSearch(kind: .notes(query: trimmed))
        }

        private func normalizedIdentifier(from raw: String) -> String {
            let lowered = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if lowered.hasPrefix("nostr:") {
                return String(lowered.dropFirst("nostr:".count))
            }
            return lowered
        }

        private func isReplaceableCoordinate(_ value: String) -> Bool {
            let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return false }
            guard Int(parts[0]) != nil else { return false }
            return parts[1].count == 64
        }
    }

    struct PresentationState {
        let isSearching: Bool
        let isLoading: Bool
        let isLoadingMore: Bool
        let errorMessage: String?
        let suggestedContentSearch: SuggestedContentSearch?
        let activeContentSearch: SuggestedContentSearch?
        let visibleProfiles: [ProfileMatch]
        let visibleItems: [FeedItem]
        let visibleReplyCounts: [String: Int]

        var hasAnySearchResults: Bool {
            !visibleProfiles.isEmpty || !visibleItems.isEmpty
        }

        @MainActor
        init(viewModel: SearchViewModel) {
            let items = viewModel.visibleItems

            isSearching = viewModel.isSearching
            isLoading = viewModel.isLoading
            isLoadingMore = viewModel.isLoadingMore
            errorMessage = viewModel.errorMessage
            suggestedContentSearch = viewModel.suggestedContentSearch
            activeContentSearch = viewModel.activeContentSearch
            visibleProfiles = viewModel.displayedProfiles
            visibleItems = items
            visibleReplyCounts = ReplyCountEstimator.counts(for: items)
        }
    }

    struct SuggestedContentSearch: Equatable {
        enum Kind: Equatable {
            case notes(query: String)
            case hashtag(String)
            case eventReference(NostrEventReferencePointer)
        }

        let kind: Kind

        var title: String {
            switch kind {
            case .notes(let query):
                return "Search notes for \(query)"
            case .hashtag(let hashtag):
                return "Search #\(hashtag) hashtag"
            case .eventReference(let reference):
                return "Find note \(shortIdentifier(reference.normalizedIdentifier))"
            }
        }

        var sectionTitle: String {
            switch kind {
            case .notes:
                return "Notes"
            case .hashtag(let hashtag):
                return "#\(hashtag)"
            case .eventReference:
                return "Note"
            }
        }

        var isPinnable: Bool {
            switch kind {
            case .notes, .hashtag:
                return true
            case .eventReference:
                return false
            }
        }

        private func shortIdentifier(_ value: String) -> String {
            guard value.count > 20 else { return value }
            return "\(value.prefix(10))...\(value.suffix(6))"
        }
    }

    struct ProfileMatch: Identifiable, Hashable {
        let pubkey: String
        let profile: NostrProfile?

        var id: String { pubkey }

        var displayName: String {
            if let displayName = normalized(profile?.displayName), !displayName.isEmpty {
                return displayName
            }
            if let name = normalized(profile?.name), !name.isEmpty {
                return name
            }
            return shortNostrIdentifier(pubkey)
        }

        var handle: String {
            if let name = normalized(profile?.name), !name.isEmpty {
                return "@\(name.replacingOccurrences(of: " ", with: "").lowercased())"
            }
            return "@\(shortNostrIdentifier(pubkey).lowercased())"
        }

        var avatarURL: URL? {
            profile?.resolvedAvatarURL
        }

        private func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    typealias TrendingNotesLoader = (
        _ service: NostrFeedService,
        _ relayURLs: [URL],
        _ limit: Int,
        _ until: Int?,
        _ moderationSnapshot: MuteFilterSnapshot?
    ) async throws -> [FeedItem]

    struct FeedFetchResult {
        let items: [FeedItem]
        let failed: Bool

        static let empty = FeedFetchResult(items: [], failed: false)
    }

    struct ProfileFetchResult {
        let items: [ProfileSearchResult]
        let failed: Bool

        static let empty = ProfileFetchResult(items: [], failed: false)
    }
}
