import NostrSDK
import SwiftUI

enum SettingsFeedRelayURLs {
    static let searchablePeopleRelayURLs: [URL] = [
        NostrFeedService.nostrArchivesSearchRelayURL
    ].compactMap { $0 }

    static func normalized(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }
}

struct SettingsNewsPersonPickerView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        SettingsFeedPersonPicker(
            relayURLs: searchRelayTargets,
            searchFooter: nil,
            isAdded: { pubkey in
                appSettings.newsAuthorPubkeys.contains(pubkey.lowercased())
            },
            onAdd: { result in
                try appSettings.addNewsAuthor(result.pubkey)
            }
        )
    }

    private var searchRelayTargets: [URL] {
        SettingsFeedRelayURLs.normalized(
            appSettings.newsRelayURLs +
            SettingsFeedRelayURLs.searchablePeopleRelayURLs
        )
    }
}

struct SettingsFeedPersonPicker: View {
    let relayURLs: [URL]
    let searchFooter: String?
    let isAdded: (String) -> Bool
    let onAdd: (ProfileSearchResult) throws -> Void

    @State private var searchText = ""
    @State private var results: [ProfileSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private let service = NostrFeedService()
    private let nostrArchivesSearchService = NostrArchivesProfileSearchService.shared

    var body: some View {
        ThemedSettingsForm {
            Section {
                TextField("Search name or paste npub", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _, _ in
                        scheduleSearch()
                    }

                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching people…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Search")
            } footer: {
                if let searchFooter, !searchFooter.isEmpty {
                    Text(searchFooter)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Results") {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Search by name, handle, or paste a specific person identifier.")
                        .foregroundStyle(.secondary)
                } else if !isSearching && results.isEmpty {
                    Text("No people found yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { result in
                        SettingsNewsPersonSearchRow(
                            result: result,
                            isAdded: isAdded(result.pubkey.lowercased())
                        ) {
                            add(result)
                        }
                    }
                }
            }
        }
        .navigationTitle("Add Person")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func add(_ result: ProfileSearchResult) {
        do {
            try onAdd(result)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        errorMessage = nil

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            let exactPubkey = AppSettingsStore.normalizedNewsAuthorPubkey(from: trimmed)
            let profileQuery = normalizedProfileQuery(trimmed)

            await MainActor.run {
                isSearching = true
            }

            async let exactProfileTask: ProfileSearchResult? = fetchExactProfile(pubkey: exactPubkey)
            async let profileMatchesTask: [ProfileSearchResult] = fetchProfileMatches(query: profileQuery)

            let exactProfile = await exactProfileTask
            let profileMatches = await profileMatchesTask

            guard !Task.isCancelled else { return }

            let leadingExactMatches = exactProfile.map { [$0] } ?? []
            let merged = deduplicatedProfileResults([leadingExactMatches, profileMatches])
            await MainActor.run {
                results = merged
                isSearching = false
            }
        }
    }

    private func normalizedProfileQuery(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.hasPrefix("@") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("nostr:") {
            return String(trimmed.dropFirst("nostr:".count))
        }
        return trimmed
    }

    private func fetchExactProfile(pubkey: String?) async -> ProfileSearchResult? {
        guard let pubkey, !pubkey.isEmpty else { return nil }
        let profile = await service.fetchProfile(
            relayURLs: relayURLs,
            pubkey: pubkey,
            fetchTimeout: 6,
            relayFetchMode: .firstNonEmptyRelay
        )
        return ProfileSearchResult(
            pubkey: pubkey,
            profile: profile,
            createdAt: Int(Date().timeIntervalSince1970)
        )
    }

    private func fetchProfileMatches(query: String) async -> [ProfileSearchResult] {
        guard query.count >= 2 else { return [] }

        return await nostrArchivesSearchService.searchProfiles(
            query: query,
            limit: 12
        )
    }

    private func deduplicatedProfileResults(_ groups: [[ProfileSearchResult]]) -> [ProfileSearchResult] {
        var seen = Set<String>()
        var ordered: [ProfileSearchResult] = []

        for group in groups {
            for result in group {
                let normalized = result.pubkey.lowercased()
                guard seen.insert(normalized).inserted else { continue }
                ordered.append(result)
            }
        }

        return ordered
    }
}

private struct NostrArchivesProfileRecord: Decodable, Sendable {
    let pubkey: String
    let name: String?
    let displayName: String?
    let preferredName: String?
    let picture: String?
    let about: String?
    let nip05: String?
    let lud06: String?
    let lud16: String?
    let website: String?

    enum CodingKeys: String, CodingKey {
        case pubkey
        case name
        case displayName = "display_name"
        case preferredName = "preferred_name"
        case picture
        case about
        case nip05
        case lud06
        case lud16
        case website
    }

    var normalizedPubkey: String {
        pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var profile: NostrProfile {
        NostrProfile(
            name: name ?? preferredName,
            displayName: displayName ?? preferredName,
            picture: picture,
            banner: nil,
            about: about,
            nip05: nip05,
            website: website,
            lud06: lud06,
            lud16: lud16
        )
    }
}

private struct NostrArchivesSuggestResponse: Decodable, Sendable {
    let suggestions: [NostrArchivesProfileRecord]
}

private struct NostrArchivesSearchResponse: Decodable, Sendable {
    let profiles: [NostrArchivesProfileRecord]
}

private actor NostrArchivesProfileSearchService {
    static let shared = NostrArchivesProfileSearchService()

    private static let baseURL = URL(string: "https://api.nostrarchives.com")!

    func searchProfiles(query: String, limit: Int) async -> [ProfileSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2 else { return [] }

        let clampedLimit = min(max(limit, 1), 20)
        let suggestionResults = (try? await fetchSuggestions(query: normalizedQuery, limit: clampedLimit)) ?? []
        if suggestionResults.count >= clampedLimit {
            return suggestionResults
        }

        let searchResults = (try? await fetchProfiles(query: normalizedQuery, limit: clampedLimit)) ?? []
        return deduplicated(suggestionResults + searchResults, limit: clampedLimit)
    }

    private func fetchSuggestions(query: String, limit: Int) async throws -> [ProfileSearchResult] {
        var components = URLComponents(
            url: Self.baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("search")
                .appendingPathComponent("suggest"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(NostrArchivesSuggestResponse.self, from: data)
        return profileResults(from: decoded.suggestions)
    }

    private func fetchProfiles(query: String, limit: Int) async throws -> [ProfileSearchResult] {
        var components = URLComponents(
            url: Self.baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "profiles"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(NostrArchivesSearchResponse.self, from: data)
        return profileResults(from: decoded.profiles)
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func profileResults(from profiles: [NostrArchivesProfileRecord]) -> [ProfileSearchResult] {
        let referenceTime = Int(Date().timeIntervalSince1970)

        return Array(profiles.enumerated().compactMap { index, profile in
            let pubkey = profile.normalizedPubkey
            guard pubkey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                return nil
            }

            return ProfileSearchResult(
                pubkey: pubkey,
                profile: profile.profile,
                createdAt: referenceTime - index
            )
        })
    }

    private func deduplicated(_ results: [ProfileSearchResult], limit: Int) -> [ProfileSearchResult] {
        var seen = Set<String>()
        var ordered: [ProfileSearchResult] = []

        for result in results {
            let normalizedPubkey = result.pubkey.lowercased()
            guard seen.insert(normalizedPubkey).inserted else { continue }
            ordered.append(result)
            if ordered.count >= limit {
                break
            }
        }

        return ordered
    }
}

struct SettingsNewsAuthorRow: View {
    let pubkey: String
    let relayURLs: [URL]
    let service: NostrFeedService
    let onRemove: () -> Void

    @State private var profile: NostrProfile?

    var body: some View {
        let identity = SettingsFeedProfileIdentity(pubkey: pubkey, profile: profile)

        HStack(spacing: 12) {
            NewsAuthorAvatarView(
                url: identity.avatarURL,
                fallbackText: identity.displayName
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(identity.handle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(AppSettingsStore.shared.primaryColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(identity.displayName)")
        }
        .task(id: pubkey) {
            if let cached = await service.cachedProfile(pubkey: pubkey) {
                profile = cached
            }

            if profile == nil, !relayURLs.isEmpty {
                profile = await service.fetchProfile(
                    relayURLs: relayURLs,
                    pubkey: pubkey,
                    fetchTimeout: 6,
                    relayFetchMode: .firstNonEmptyRelay
                )
            }
        }
    }
}

struct SettingsNewsPersonSearchRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let result: ProfileSearchResult
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        let identity = SettingsFeedProfileIdentity(pubkey: result.pubkey, profile: result.profile)

        HStack(spacing: 12) {
            NewsAuthorAvatarView(
                url: identity.avatarURL,
                fallbackText: identity.displayName
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(identity.handle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isAdded {
                Text("Added")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(appSettings.primaryColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(identity.displayName)")
            }
        }
    }
}

private struct SettingsFeedProfileIdentity {
    let pubkey: String
    let profile: NostrProfile?

    var displayName: String {
        if let displayName = normalized(profile?.displayName) {
            return displayName
        }
        if let name = normalized(profile?.name) {
            return name
        }
        return shortNostrIdentifier(pubkey)
    }

    var handle: String {
        if let name = normalized(profile?.name) {
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

private struct NewsAuthorAvatarView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let url: URL?
    let fallbackText: String

    var body: some View {
        Group {
            if let url {
                CachedAsyncImage(url: url, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(appSettings.themePalette.tertiaryFill)
            .overlay {
                Text(String(fallbackText.prefix(1)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
    }
}
