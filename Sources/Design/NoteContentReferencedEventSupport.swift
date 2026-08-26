import NostrSDK
import SwiftUI

enum NostrReferenceEmbeddingDecision: Equatable, Sendable {
    case automatic
    case deferred
    case cycle
}

struct NostrReferenceEmbeddingContext: Equatable, Sendable {
    static let maximumAutomaticDepth = 2
    static let maximumAutomaticReferencesPerEvent = 4

    let depth: Int
    let visitedTargetIdentities: Set<String>

    init(rootEvent: NostrEvent) {
        depth = 0
        visitedTargetIdentities = Self.targetIdentities(for: rootEvent)
    }

    private init(depth: Int, visitedTargetIdentities: Set<String>) {
        self.depth = depth
        self.visitedTargetIdentities = visitedTargetIdentities
    }

    func decision(
        for nostrURI: String,
        referenceOrdinal: Int = 0
    ) -> NostrReferenceEmbeddingDecision {
        if let identity = Self.targetIdentity(for: nostrURI),
           visitedTargetIdentities.contains(identity) {
            return .cycle
        }
        let isWithinAutomaticBudget = referenceOrdinal >= 0
            && referenceOrdinal < Self.maximumAutomaticReferencesPerEvent
        return depth < Self.maximumAutomaticDepth && isWithinAutomaticBudget
            ? .automatic
            : .deferred
    }

    func descending(into event: NostrEvent, referencedBy nostrURI: String) -> Self {
        var visited = visitedTargetIdentities
        if let identity = Self.targetIdentity(for: nostrURI) {
            visited.insert(identity)
        }
        visited.formUnion(Self.targetIdentities(for: event))
        return Self(depth: depth + 1, visitedTargetIdentities: visited)
    }

    private static func targetIdentity(for nostrURI: String) -> String? {
        guard let pointer = NoteContentParser.eventReferencePointer(from: nostrURI) else {
            return nil
        }
        switch pointer.target {
        case .eventID(let eventID):
            let normalized = eventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : "event:\(normalized)"
        case .replaceable(let kind, let pubkey, let identifier):
            let normalizedPubkey = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPubkey.isEmpty, !normalizedIdentifier.isEmpty else { return nil }
            return "address:\(kind):\(normalizedPubkey):\(normalizedIdentifier)"
        }
    }

    private static func targetIdentities(for event: NostrEvent) -> Set<String> {
        var identities = Set<String>()
        let eventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !eventID.isEmpty {
            identities.insert("event:\(eventID)")
        }

        if (30_000..<40_000).contains(event.kind),
           let identifier = event.tags.first(where: { tag in
               tag.count > 1 && tag[0].lowercased() == "d"
           })?[1].trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            let pubkey = event.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !pubkey.isEmpty {
                identities.insert("address:\(event.kind):\(pubkey):\(identifier)")
            }
        }
        return identities
    }
}

private struct ReferencedNoteCardChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        content
            .overlay {
                shape.strokeBorder(
                    colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.05),
                    lineWidth: 1
                )
            }
    }
}

actor EmbeddedReferencedNoteCache {
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

    func cachedValue(
        for key: String,
        retryCachedMiss: Bool = false
    ) -> (found: Bool, item: FeedItem?) {
        if let cached = resolvedItems[key] {
            switch cached {
            case .value(let item):
                return (true, item)
            case .miss(let storedAt):
                guard retryCachedMiss || Date().timeIntervalSince(storedAt) >= missRetryInterval else {
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
    private actor BatchResolver {
        private struct PendingRequest {
            let reference: NostrEventReferencePointer
            var continuations: [CheckedContinuation<FeedItem?, Never>]
        }

        private let flushDelayNanoseconds: UInt64 = 35_000_000
        private var pendingRequests: [String: PendingRequest] = [:]
        private var flushTask: Task<Void, Never>?

        func resolve(identifier: String, reference: NostrEventReferencePointer) async -> FeedItem? {
            await withCheckedContinuation { continuation in
                if var pending = pendingRequests[identifier] {
                    pending.continuations.append(continuation)
                    pendingRequests[identifier] = pending
                } else {
                    pendingRequests[identifier] = PendingRequest(
                        reference: reference,
                        continuations: [continuation]
                    )
                }
                scheduleFlushIfNeeded()
            }
        }

        private func scheduleFlushIfNeeded() {
            guard flushTask == nil else { return }
            flushTask = Task {
                try? await Task.sleep(nanoseconds: flushDelayNanoseconds)
                await flush()
            }
        }

        private func flush() async {
            let requests = pendingRequests
            pendingRequests = [:]
            flushTask = nil
            guard !requests.isEmpty else { return }

            let referencesByKey = requests.mapValues(\.reference)
            let itemsByKey = await EmbeddedReferencedNoteResolver.fetchReferencedFeedItems(
                referencesByKey: referencesByKey
            )

            for (key, request) in requests {
                let item = itemsByKey[key]
                for continuation in request.continuations {
                    continuation.resume(returning: item)
                }
            }
        }
    }

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
    private static let batchResolver = BatchResolver()

    static func normalizedIdentifier(from nostrURI: String) -> String {
        NoteContentParser.normalizedNostrReferenceIdentifier(from: nostrURI)
    }

    static func shortIdentifier(_ value: String) -> String {
        guard value.count > 22 else { return value }
        return "\(value.prefix(12))...\(value.suffix(8))"
    }

    static func resolve(
        nostrURI: String,
        retryCachedMiss: Bool = false
    ) async -> FeedItem? {
        let key = normalizedIdentifier(from: nostrURI)
        guard !key.isEmpty else { return nil }

        let cache = EmbeddedReferencedNoteCache.shared
        let cached = await cache.cachedValue(
            for: key,
            retryCachedMiss: retryCachedMiss
        )
        if cached.found {
            return cached.item
        }

        if let inFlight = await cache.inFlightTask(for: key) {
            return await inFlight.value
        }

        guard let reference = NoteContentParser.eventReferencePointer(from: key) else {
            return nil
        }

        let task = Task {
            await batchResolver.resolve(identifier: key, reference: reference)
        }
        await cache.storeInFlightTask(task, for: key)

        let item = await task.value
        await cache.storeResolvedValue(item, for: key)
        return item
    }

    private static func fetchReferencedFeedItems(
        referencesByKey: [String: NostrEventReferencePointer]
    ) async -> [String: FeedItem] {
        let relayURLs = await effectiveRelayURLs(with: [])
        guard !relayURLs.isEmpty, !referencesByKey.isEmpty else { return [:] }

        let itemsByReference = await feedService.fetchReferencedFeedItems(
            references: Array(referencesByKey.values),
            baseReadRelayURLs: relayURLs,
            hydrationMode: .cachedProfilesOnly,
            fetchTimeout: 4,
            relayFetchMode: .firstNonEmptyRelay
        )

        var itemsByKey: [String: FeedItem] = [:]
        for (key, reference) in referencesByKey {
            guard let item = itemsByReference[reference] else { continue }
            itemsByKey[key] = item
        }
        return itemsByKey
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
                guard !trimmed.isEmpty,
                      let url = URL(string: trimmed),
                      FlowURLSafety.isPubliclyLoadableRelayURL(url) else {
                    return nil
                }
                return url
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
            guard let normalizedURL = RelayURLSupport.normalizedURL(from: relayURL.absoluteString) else { continue }
            let key = normalizedURL.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            deduped.append(normalizedURL)
        }
        return deduped
    }

    private static func fetchEventByID(_ eventID: String, relayURLs: [URL]) async -> NostrEvent? {
        let normalizedEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = await SeenEventStore.shared.events(ids: [normalizedEventID])[normalizedEventID] {
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

}

struct NostrZapReceiptMetadata: Equatable {
    enum Target: Equatable {
        case podcastEpisode
        case podcast
        case external
    }

    private struct ZapRequest: Decodable {
        let kind: Int
        let content: String
        let tags: [[String]]
    }

    static let receiptKind = 9_735
    private static let requestKind = 9_734

    let amountMillisats: UInt64?
    let comment: String?
    let target: Target
    let destinationURL: URL?
    let providerName: String?

    init?(event: NostrEvent) {
        guard event.kind == Self.receiptKind else { return nil }

        let request = Self.zapRequest(from: event.tags)
        let requestedAmount = Self.tagValue(named: "amount", in: request?.tags ?? event.tags)
            .flatMap(UInt64.init)
        let invoiceAmount = Self.tagValue(named: "bolt11", in: event.tags)
            .flatMap(Self.millisatsFromBolt11)

        if let requestedAmount {
            amountMillisats = requestedAmount == invoiceAmount ? requestedAmount : nil
        } else {
            amountMillisats = invoiceAmount
        }

        let trimmedComment = request?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        comment = trimmedComment.flatMap { $0.isEmpty ? nil : $0 }

        let referenceTags = event.tags + (request?.tags ?? [])
        let externalReference = Self.preferredExternalReference(in: referenceTags)
        target = Self.target(for: externalReference?.identifier)
        destinationURL = externalReference?.urlHint.flatMap(NoteContentParser.webURL(from:))
        providerName = Self.providerName(for: destinationURL)
    }

    var amountText: String {
        guard let amountMillisats else { return "Lightning zap" }
        guard amountMillisats >= 1_000 else {
            return "\(amountMillisats.formatted()) msats"
        }

        if amountMillisats.isMultiple(of: 1_000) {
            return "\((amountMillisats / 1_000).formatted()) sats"
        }

        let sats = Double(amountMillisats) / 1_000
        return "\(sats.formatted(.number.precision(.fractionLength(0...3)))) sats"
    }

    var subtitle: String {
        switch target {
        case .podcastEpisode:
            return "Podcast episode zap"
        case .podcast:
            return "Podcast zap"
        case .external:
            return "Lightning zap receipt"
        }
    }

    var targetLabel: String {
        switch target {
        case .podcastEpisode:
            return "Podcast episode"
        case .podcast:
            return "Podcast"
        case .external:
            return "External content"
        }
    }

    var actionTitle: String {
        let destination: String
        switch target {
        case .podcastEpisode:
            destination = "episode"
        case .podcast:
            destination = "podcast"
        case .external:
            destination = "source"
        }

        if let providerName {
            return "Open \(destination) on \(providerName)"
        }
        return "Open \(destination)"
    }

    private static func zapRequest(from tags: [[String]]) -> ZapRequest? {
        guard let description = tagValue(named: "description", in: tags),
              let data = description.data(using: .utf8),
              let request = try? JSONDecoder().decode(ZapRequest.self, from: data),
              request.kind == requestKind else {
            return nil
        }
        return request
    }

    private static func tagValue(named name: String, in tags: [[String]]) -> String? {
        tags.first { tag in
            tag.count > 1 && tag[0].caseInsensitiveCompare(name) == .orderedSame
        }?[1]
    }

    private static func preferredExternalReference(
        in tags: [[String]]
    ) -> (identifier: String, urlHint: String?)? {
        let references = tags.compactMap { tag -> (identifier: String, urlHint: String?)? in
            guard tag.count > 1, tag[0].lowercased() == "i" else { return nil }
            return (tag[1], tag.count > 2 ? tag[2] : nil)
        }

        return references.first { $0.identifier.lowercased().hasPrefix("podcast:item:guid:") }
            ?? references.first { $0.identifier.lowercased().hasPrefix("podcast:guid:") }
            ?? references.first
    }

    private static func target(for identifier: String?) -> Target {
        let normalized = identifier?.lowercased() ?? ""
        if normalized.hasPrefix("podcast:item:guid:") {
            return .podcastEpisode
        }
        if normalized.hasPrefix("podcast:guid:") {
            return .podcast
        }
        return .external
    }

    private static func providerName(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host == "fountain.fm" || host.hasSuffix(".fountain.fm") {
            return "Fountain"
        }

        let components = host.split(separator: ".")
        let candidate = components.dropLast().last ?? components.first
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private static func millisatsFromBolt11(_ invoice: String) -> UInt64? {
        let normalized = invoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("ln"),
              let separator = normalized.lastIndex(of: "1") else {
            return nil
        }

        let humanReadablePart = normalized[..<separator]
        guard let amountStart = humanReadablePart.firstIndex(where: \Character.isNumber) else {
            return nil
        }

        let amountToken = humanReadablePart[amountStart...]
        let multiplier = amountToken.last.flatMap { "munp".contains($0) ? $0 : nil }
        let digits = multiplier == nil ? amountToken : amountToken.dropLast()
        guard !digits.isEmpty, let value = UInt64(digits) else { return nil }

        switch multiplier {
        case "m":
            return multiplied(value, by: 100_000_000)
        case "u":
            return multiplied(value, by: 100_000)
        case "n":
            return multiplied(value, by: 100)
        case "p":
            guard value.isMultiple(of: 10) else { return nil }
            return value / 10
        case nil:
            return multiplied(value, by: 100_000_000_000)
        default:
            return nil
        }
    }

    private static func multiplied(_ value: UInt64, by multiplier: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: multiplier)
        return result.overflow ? nil : result.partialValue
    }
}

struct NostrZapReceiptCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore

    let metadata: NostrZapReceiptMetadata

    private static let cardCornerRadius: CGFloat = 20
    private static let actionCornerRadius: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(appSettings.primaryColor.opacity(0.13))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(appSettings.primaryColor)
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(metadata.amountText)
                        .font(appSettings.appFont(.title3, weight: .bold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                    Text(metadata.subtitle)
                        .font(appSettings.appFont(.caption1, weight: .medium))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }

                Spacer(minLength: 8)

                Text("Receipt")
                    .font(appSettings.appFont(.caption2, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(appSettings.themePalette.tertiaryFill, in: Capsule())
            }

            if let comment = metadata.comment {
                Text(comment)
                    .font(appSettings.appFont(.body))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let destinationURL = metadata.destinationURL {
                Link(destination: destinationURL) {
                    HStack(spacing: 8) {
                        Image(systemName: metadata.target == .external ? "link" : "play.fill")
                            .font(.caption.weight(.bold))
                        Text(metadata.actionTitle)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(appSettings.appFont(.caption1, weight: .semibold))
                    .foregroundStyle(appSettings.primaryColor)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        appSettings.primaryColor.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: Self.actionCornerRadius, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if metadata.target != .external {
                Label(metadata.targetLabel, systemImage: "waveform")
                    .font(appSettings.appFont(.caption1, weight: .medium))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
        .padding(12)
        .background(appSettings.themePalette.linkPreviewBackground, in: cardShape)
        .overlay(cardShape.stroke(appSettings.themePalette.linkPreviewBorder, lineWidth: 0.7))
        .shadow(
            color: colorScheme == .dark ? .clear : Color.black.opacity(0.04),
            radius: 4,
            x: 0,
            y: 2
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
    }
}

struct NostrUnsupportedEventMetadata: Equatable {
    private static let genericallyRenderedKinds: Set<Int> = [
        1,      // Short text note
        20,     // Picture
        21,     // Video
        22,     // Short video
        1_063,  // File metadata
        1_068,  // Poll
        1_111,  // Comment
        1_222,  // Voice post
        1_244,  // Voice comment
        9_802,  // Highlight
        31_987, // Relay review
        36_787  // Music track
    ]
    private static let speciallyRenderedKinds: Set<Int> = [
        NostrZapReceiptMetadata.receiptKind,
        NostrLongFormArticleKind.article
    ]

    let kind: Int

    init?(event: NostrEvent) {
        guard !Self.genericallyRenderedKinds.contains(event.kind),
              !Self.speciallyRenderedKinds.contains(event.kind) else {
            return nil
        }
        kind = event.kind
    }

    var title: String { "Unsupported shared item" }
    var message: String { "Halo can’t display this shared item yet." }
    var kindLabel: String { "Kind \(kind)" }
}

struct NostrUnsupportedEventCardView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let metadata: NostrUnsupportedEventMetadata

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .frame(width: 36, height: 36)
                .background(appSettings.themePalette.tertiaryFill, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(metadata.title)
                    .font(appSettings.appFont(.headline, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)

                Text(metadata.message)
                    .font(appSettings.appFont(.subheadline))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)

                Text(metadata.kindLabel)
                    .font(appSettings.appFont(.caption1, weight: .semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(appSettings.themePalette.tertiaryFill, in: Capsule())
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            appSettings.themePalette.linkPreviewBackground,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appSettings.themePalette.linkPreviewBorder, lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unsupported shared item. Halo can’t display it yet.")
    }
}

struct NostrEventReferenceFallbackView: View {
    let nostrURI: String
    var onOpenThread: ((FeedItem) -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var title = "Referenced note"
    var systemImage = "quote.bubble"
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var isOpeningInApp = false

    private var identifier: String {
        EmbeddedReferencedNoteResolver.normalizedIdentifier(from: nostrURI)
    }

    var body: some View {
        Group {
            if let onRetry {
                Button(action: onRetry) {
                    fallbackLabel(
                        isLoading: false,
                        showsChevron: true,
                        showExternalIcon: false
                    )
                }
                .buttonStyle(.plain)
            } else if onOpenThread != nil {
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
                Image(systemName: systemImage)
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isLoading ? "Finding referenced note" : title)
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

struct NostrDeferredEventReferenceView: View {
    let nostrURI: String
    let embeddingContext: NostrReferenceEmbeddingContext
    let onHashtagTap: ((String) -> Void)?
    let onProfileTap: ((String) -> Void)?
    let onOpenThread: ((FeedItem) -> Void)?
    let onRelayTap: ((URL) -> Void)?
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var isExpanded = false

    private var identifier: String {
        EmbeddedReferencedNoteResolver.normalizedIdentifier(from: nostrURI)
    }

    var body: some View {
        if isExpanded {
            NostrEventReferenceCardView(
                nostrURI: nostrURI,
                embeddingContext: embeddingContext,
                onHashtagTap: onHashtagTap,
                onProfileTap: onProfileTap,
                onOpenThread: onOpenThread,
                onRelayTap: onRelayTap
            )
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isExpanded = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .foregroundStyle(appSettings.themePalette.mutedForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show referenced note")
                            .font(.subheadline.weight(.semibold))
                        Text(EmbeddedReferencedNoteResolver.shortIdentifier(identifier))
                            .font(.caption)
                            .foregroundStyle(appSettings.themePalette.mutedForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.mutedForeground)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(ReferencedNoteCardChromeModifier())
            .accessibilityLabel("Show referenced note")
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
    let embeddingContext: NostrReferenceEmbeddingContext
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
                NostrEventReferenceFallbackView(
                    nostrURI: nostrURI,
                    onOpenThread: onOpenThread,
                    onRetry: {
                        Task {
                            await loadReferencedEvent(retryCachedMiss: true)
                        }
                    },
                    title: "Retry referenced note",
                    systemImage: "arrow.clockwise"
                )
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
        if let zapReceipt = NostrZapReceiptMetadata(event: item.displayEvent) {
            NostrZapReceiptCardView(metadata: zapReceipt)
        } else {
            embeddedCardContent(for: item)
        }
    }

    private func embeddedCardContent(for item: FeedItem) -> some View {
        let childEmbeddingContext = embeddingContext.descending(
            into: item.displayEvent,
            referencedBy: nostrURI
        )
        return VStack(alignment: .leading, spacing: 8) {
            referencedNoteHeader(for: item)

            NoteContentView(
                event: item.displayEvent,
                referenceEmbeddingContext: childEmbeddingContext,
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

    @ViewBuilder
    private func referencedNoteHeader(for item: FeedItem) -> some View {
        if let onOpenThread {
            Button {
                onOpenThread(item.threadNavigationItem)
            } label: {
                referencedNoteHeaderContent(for: item)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open referenced note by \(item.displayName)")
        } else {
            referencedNoteHeaderContent(for: item)
        }
    }

    private func referencedNoteHeaderContent(for item: FeedItem) -> some View {
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
        .frame(minHeight: 40)
        .contentShape(Rectangle())
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

    private func loadReferencedEvent(retryCachedMiss: Bool = false) async {
        let key = normalizedIdentifier
        guard !key.isEmpty else {
            await MainActor.run { state = .failed }
            return
        }

        await MainActor.run { state = .loading }
        let item = await EmbeddedReferencedNoteResolver.resolve(
            nostrURI: nostrURI,
            retryCachedMiss: retryCachedMiss
        )

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
