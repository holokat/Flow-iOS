import NostrSDK
import SwiftUI

private struct ReferencedNoteCardChromeModifier: ViewModifier {
    @EnvironmentObject private var appSettings: AppSettingsStore

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let holographicOption = appSettings.activeHolographicGradientOption
        let holographicAccents = holographicOption?.accentPalette(for: appSettings.activeTheme)
        let holographicBorder = holographicOption?.borderColor(for: appSettings.activeTheme)
        let usesDarkGradientTreatment = appSettings.activeTheme.usesDarkGradientTreatment

        content
            .background {
                shape
                    .fill(appSettings.themePalette.quoteBackground)
                    .overlay {
                        if let holographicAccents {
                            shape.fill(
                                LinearGradient(
                                    colors: [
                                        holographicAccents.secondary.opacity(usesDarkGradientTreatment ? 0.18 : 0.13),
                                        holographicAccents.primary.opacity(usesDarkGradientTreatment ? 0.10 : 0.05),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        }
                    }
            }
            .overlay {
                if let holographicAccents, let holographicBorder {
                    ZStack {
                        shape
                            .stroke(holographicBorder, lineWidth: 0.75)

                        shape
                            .inset(by: 1)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        holographicAccents.secondary.opacity(usesDarkGradientTreatment ? 0.34 : 0.24),
                                        holographicAccents.primary.opacity(usesDarkGradientTreatment ? 0.18 : 0.10),
                                        Color.white.opacity(usesDarkGradientTreatment ? 0.05 : 0.18)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.7
                            )
                    }
                } else {
                    shape
                        .stroke(appSettings.themePalette.separator, lineWidth: 0.5)
                }
            }
            .shadow(
                color: holographicAccents?.shadow.opacity(usesDarkGradientTreatment ? 0.12 : 0.07) ?? .clear,
                radius: holographicAccents == nil ? 0 : 12,
                x: 0,
                y: holographicAccents == nil ? 0 : 7
            )
    }
}

private actor EmbeddedReferencedNoteCache {
    static let shared = EmbeddedReferencedNoteCache()

    private enum CachedResult {
        case value(FeedItem)
        case miss(storedAt: Date)
    }

    private let maxResolvedEntries = 512
    private let missRetryInterval: TimeInterval = 60
    private var resolvedItems: [String: CachedResult] = [:]
    private var resolvedOrder: [String] = []
    private var inFlightTasks: [String: Task<FeedItem?, Never>] = [:]

    func cachedValue(for key: String) -> (found: Bool, item: FeedItem?) {
        if let cached = resolvedItems[key] {
            switch cached {
            case .value(let item):
                return (true, item)
            case .miss(let storedAt):
                guard Date().timeIntervalSince(storedAt) >= missRetryInterval else {
                    return (true, nil)
                }
                resolvedItems.removeValue(forKey: key)
                resolvedOrder.removeAll { $0 == key }
            }
        }
        return (false, nil)
    }

    func inFlightTask(for key: String) -> Task<FeedItem?, Never>? {
        inFlightTasks[key]
    }

    func storeInFlightTask(_ task: Task<FeedItem?, Never>, for key: String) {
        inFlightTasks[key] = task
    }

    func storeResolvedValue(_ item: FeedItem?, for key: String) {
        let cachedResult: CachedResult
        if let item {
            cachedResult = .value(item)
        } else {
            cachedResult = .miss(storedAt: Date())
        }

        if resolvedItems[key] == nil {
            resolvedOrder.append(key)
        } else {
            resolvedOrder.removeAll { $0 == key }
            resolvedOrder.append(key)
        }
        resolvedItems[key] = cachedResult
        inFlightTasks[key] = nil

        let overflow = resolvedOrder.count - maxResolvedEntries
        guard overflow > 0 else { return }

        for _ in 0..<overflow {
            let removedKey = resolvedOrder.removeFirst()
            resolvedItems.removeValue(forKey: removedKey)
        }
    }
}

private enum EmbeddedReferencedNoteResolver {
    private enum ReferenceTarget {
        case eventID(String)
        case replaceable(kind: Int, pubkey: String, identifier: String)
    }

    private struct ParsedReference {
        let target: ReferenceTarget
        let relayHints: [URL]
    }

    private struct ReferenceMetadataDecoder: MetadataCoding {}

    private static let relayClient = NostrRelayClient()
    private static let feedService = NostrFeedService()

    static func normalizedIdentifier(from nostrURI: String) -> String {
        NoteContentParser.normalizedNostrReferenceIdentifier(from: nostrURI)
    }

    static func shortIdentifier(_ value: String) -> String {
        guard value.count > 22 else { return value }
        return "\(value.prefix(12))...\(value.suffix(8))"
    }

    static func resolve(nostrURI: String) async -> FeedItem? {
        let key = normalizedIdentifier(from: nostrURI)
        guard !key.isEmpty else { return nil }

        let cache = EmbeddedReferencedNoteCache.shared
        let cached = await cache.cachedValue(for: key)
        if cached.found {
            return cached.item
        }

        if let inFlight = await cache.inFlightTask(for: key) {
            return await inFlight.value
        }

        let task = Task {
            await fetchReferencedFeedItem(identifier: key)
        }
        await cache.storeInFlightTask(task, for: key)

        let item = await task.value
        await cache.storeResolvedValue(item, for: key)
        return item
    }

    private static func fetchReferencedFeedItem(identifier: String) async -> FeedItem? {
        guard let reference = NoteContentParser.eventReferencePointer(from: identifier) else {
            return nil
        }

        let relayURLs = await effectiveRelayURLs(with: [])
        guard !relayURLs.isEmpty else { return nil }

        return await feedService.fetchReferencedFeedItem(
            reference: reference,
            relayURLs: relayURLs,
            hydrationMode: .cachedProfilesOnly
        )
    }

    private static func parseReference(from identifier: String) -> ParsedReference? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        if isHex64(normalized) {
            return ParsedReference(target: .eventID(normalized), relayHints: [])
        }

        if let coordinate = parseReplaceableCoordinate(from: normalized) {
            return ParsedReference(
                target: .replaceable(
                    kind: coordinate.kind,
                    pubkey: coordinate.pubkey,
                    identifier: coordinate.identifier
                ),
                relayHints: []
            )
        }

        if normalized.hasPrefix("nevent1") || normalized.hasPrefix("naddr1") {
            let decoder = ReferenceMetadataDecoder()
            guard let metadata = try? decoder.decodedMetadata(from: normalized) else {
                return nil
            }

            let rawRelayHints: [String] = metadata.relays ?? []
            let relayHints = rawRelayHints.compactMap { relay -> URL? in
                let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                guard isSupportedRelayHint(trimmed) else { return nil }
                return URL(string: trimmed)
            }

            if let eventID = metadata.eventId?.lowercased(),
               isHex64(eventID) {
                return ParsedReference(target: .eventID(eventID), relayHints: relayHints)
            }

            if let kind = metadata.kind,
               let pubkey = metadata.pubkey?.lowercased(),
               isHex64(pubkey),
               let replaceableIdentifier = metadata.identifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !replaceableIdentifier.isEmpty {
                return ParsedReference(
                    target: .replaceable(
                        kind: Int(kind),
                        pubkey: pubkey,
                        identifier: replaceableIdentifier
                    ),
                    relayHints: relayHints
                )
            }
        }

        return nil
    }

    private static func parseReplaceableCoordinate(
        from value: String
    ) -> (kind: Int, pubkey: String, identifier: String)? {
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let kind = Int(parts[0]), kind >= 0 else { return nil }

        let pubkey = String(parts[1]).lowercased()
        guard isHex64(pubkey) else { return nil }

        let identifier = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        return (kind: kind, pubkey: pubkey, identifier: identifier)
    }

    private static func effectiveRelayURLs(with hints: [URL]) async -> [URL] {
        let (configuredReadRelays, defaults) = await MainActor.run {
            (
                RelaySettingsStore.shared.readRelayURLs,
                RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
            )
        }
        let base = configuredReadRelays.isEmpty ? defaults : configuredReadRelays
        return deduplicatedRelayURLs(hints + base)
    }

    private static func deduplicatedRelayURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var deduped: [URL] = []
        for relayURL in urls {
            guard isSupportedRelayHint(relayURL.absoluteString) else { continue }
            let key = relayURL.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            deduped.append(relayURL)
        }
        return deduped
    }

    private static func fetchEventByID(_ eventID: String, relayURLs: [URL]) async -> NostrEvent? {
        let normalizedEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = await EventRepository.shared.events(ids: [normalizedEventID])[normalizedEventID] {
            return cached
        }

        let filter = NostrFilter(ids: [normalizedEventID], limit: 1)
        let events = await fetchEvents(relayURLs: relayURLs, filter: filter)
        return deduplicateAndSort(events)
            .first(where: { $0.id.lowercased() == normalizedEventID })
    }

    private static func fetchReplaceableEvent(
        kind: Int,
        pubkey: String,
        identifier: String,
        relayURLs: [URL]
    ) async -> NostrEvent? {
        let filter = NostrFilter(
            authors: [pubkey],
            kinds: [kind],
            limit: 40,
            tagFilters: ["d": [identifier]]
        )
        let events = await fetchEvents(relayURLs: relayURLs, filter: filter)
        return deduplicateAndSort(events).first(where: { event in
            guard event.kind == kind else { return false }
            guard event.pubkey.lowercased() == pubkey.lowercased() else { return false }
            return event.tags.contains { tag in
                guard let name = tag.first?.lowercased(), name == "d" else { return false }
                guard tag.count > 1 else { return false }
                return tag[1].trimmingCharacters(in: .whitespacesAndNewlines) == identifier
            }
        })
    }

    private static func fetchEvents(
        relayURLs: [URL],
        filter: NostrFilter,
        timeout: TimeInterval = 8
    ) async -> [NostrEvent] {
        await withTaskGroup(of: [NostrEvent].self) { group in
            for relayURL in relayURLs {
                group.addTask {
                    (try? await relayClient.fetchEvents(
                        relayURL: relayURL,
                        filter: filter,
                        timeout: timeout
                    )) ?? []
                }
            }

            var merged: [NostrEvent] = []
            for await events in group {
                merged.append(contentsOf: events)
            }
            return merged
        }
    }

    private static func deduplicateAndSort(_ events: [NostrEvent]) -> [NostrEvent] {
        var seen = Set<String>()
        var unique: [NostrEvent] = []
        for event in events {
            let key = event.id.lowercased()
            guard seen.insert(key).inserted else { continue }
            unique.append(event)
        }

        return unique.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func isHex64(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func isSupportedRelayHint(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("ws://") || normalized.hasPrefix("wss://")
    }
}

struct NostrEventReferenceFallbackView: View {
    let nostrURI: String
    var onOpenThread: ((FeedItem) -> Void)? = nil
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var isOpeningInApp = false

    private var identifier: String {
        EmbeddedReferencedNoteResolver.normalizedIdentifier(from: nostrURI)
    }

    var body: some View {
        Group {
            if onOpenThread != nil {
                Button {
                    Task {
                        await openInApp()
                    }
                } label: {
                    fallbackLabel(
                        isLoading: isOpeningInApp,
                        showsChevron: true,
                        showExternalIcon: false
                    )
                }
                .buttonStyle(.plain)
            } else if let externalURL = NoteContentParser.njumpURL(for: identifier) {
                Link(destination: externalURL) {
                    fallbackLabel(
                        isLoading: false,
                        showsChevron: false,
                        showExternalIcon: true
                    )
                }
                .buttonStyle(.plain)
            } else {
                fallbackLabel(
                    isLoading: false,
                    showsChevron: false,
                    showExternalIcon: false
                )
            }
        }
        .padding(12)
        .modifier(ReferencedNoteCardChromeModifier())
    }

    @ViewBuilder
    private func fallbackLabel(
        isLoading: Bool,
        showsChevron: Bool,
        showExternalIcon: Bool
    ) -> some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isLoading ? "Finding referenced note" : "Referenced note")
                    .font(.subheadline.weight(.semibold))
                Text(EmbeddedReferencedNoteResolver.shortIdentifier(identifier))
                    .font(.caption)
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
                    .lineLimit(1)
            }
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
            }
            if showExternalIcon {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(appSettings.themeIconAccentColor)
            }
        }
    }

    private func openInApp() async {
        guard let onOpenThread else { return }
        await MainActor.run {
            isOpeningInApp = true
        }

        let item = await EmbeddedReferencedNoteResolver.resolve(nostrURI: nostrURI)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            isOpeningInApp = false
            if let item {
                onOpenThread(item.threadNavigationItem)
            }
        }
    }
}

struct NostrEventReferenceCardView: View {
    private enum LoadState {
        case idle
        case loading
        case loaded(FeedItem)
        case failed
    }

    let nostrURI: String
    let embedDepth: Int
    let onHashtagTap: ((String) -> Void)?
    let onProfileTap: ((String) -> Void)?
    let onOpenThread: ((FeedItem) -> Void)?
    let onRelayTap: ((URL) -> Void)?
    @EnvironmentObject private var appSettings: AppSettingsStore

    @State private var state: LoadState = .idle

    private var normalizedIdentifier: String {
        EmbeddedReferencedNoteResolver.normalizedIdentifier(from: nostrURI)
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                loadingCard
            case .loaded(let item):
                embeddedCard(for: item)
            case .failed:
                NostrEventReferenceFallbackView(nostrURI: nostrURI, onOpenThread: onOpenThread)
            }
        }
        .task(id: normalizedIdentifier) {
            await loadReferencedEvent()
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading referenced note")
                    .font(.subheadline.weight(.semibold))
                Text(EmbeddedReferencedNoteResolver.shortIdentifier(normalizedIdentifier))
                    .font(.caption)
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .modifier(ReferencedNoteCardChromeModifier())
    }

    @ViewBuilder
    private func embeddedCard(for item: FeedItem) -> some View {
        if let onOpenThread {
            Button {
                onOpenThread(item.threadNavigationItem)
            } label: {
                embeddedCardContent(for: item)
            }
            .buttonStyle(.plain)
        } else {
            embeddedCardContent(for: item)
        }
    }

    private func embeddedCardContent(for item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                cardAvatar(for: item)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.handle)
                        .font(.caption)
                        .foregroundStyle(appSettings.themePalette.mutedForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let clientName = item.displayEvent.clientName {
                    Text("via \(clientName)")
                        .font(.caption2)
                        .foregroundStyle(appSettings.themePalette.mutedForeground)
                        .lineLimit(1)
                }

                Text(RelativeTimestampFormatter.shortString(from: item.displayEvent.createdAtDate))
                    .font(.caption2)
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
                    .lineLimit(1)
            }

            NoteContentView(
                event: item.displayEvent,
                embedDepth: embedDepth,
                articleAuthor: LongFormArticleAuthorSummary(item: item),
                onHashtagTap: onHashtagTap,
                onProfileTap: onProfileTap,
                onReferencedEventTap: onOpenThread,
                onRelayTap: onRelayTap
            )
        }
        .padding(10)
        .modifier(ReferencedNoteCardChromeModifier())
    }

    private func cardAvatar(for item: FeedItem) -> some View {
        Group {
            if appSettings.textOnlyMode {
                fallbackAvatar(for: item)
            } else if let url = item.avatarURL {
                CachedAsyncImage(url: url, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar(for: item)
                    }
                }
            } else {
                fallbackAvatar(for: item)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(appSettings.themePalette.separator, lineWidth: 0.5)
        }
    }

    private func fallbackAvatar(for item: FeedItem) -> some View {
        ZStack {
            Circle().fill(appSettings.themePalette.secondaryFill)
            Text(String(item.displayName.prefix(1)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.mutedForeground)
        }
    }

    private func loadReferencedEvent() async {
        let key = normalizedIdentifier
        guard !key.isEmpty else {
            await MainActor.run { state = .failed }
            return
        }

        await MainActor.run { state = .loading }
        let item = await EmbeddedReferencedNoteResolver.resolve(nostrURI: nostrURI)

        guard !Task.isCancelled else { return }

        await MainActor.run {
            if let item {
                state = .loaded(item)
            } else {
                state = .failed
            }
        }
    }
}
