import SwiftUI

private enum RelaySettingsSourceTab: String, CaseIterable, Identifiable {
    case receive = "Receive"
    case publish = "Publish"
    case messages = "Messages"

    var id: String { rawValue }

    var emptyMessage: String {
        switch self {
        case .receive:
            return "No receive sources configured yet."
        case .publish:
            return "No publish sources configured yet."
        case .messages:
            return "No message sources configured yet."
        }
    }
}

private enum RelayAddScope: String, CaseIterable, Identifiable {
    case both = "Receive + Publish"
    case read = "Receive"
    case write = "Publish"
    case inbox = "Messages"

    var id: String { rawValue }

    var relayScope: RelayScope {
        switch self {
        case .both:
            return .both
        case .read:
            return .read
        case .write:
            return .write
        case .inbox:
            return .inbox
        }
    }
}

struct RelaySettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @ObservedObject private var followStore = FollowStore.shared
    @ObservedObject private var publishStatsStore = SourcePublishStatsStore.shared

    @State private var relayInput = ""
    @State private var relayScope: RelayAddScope = .both
    @State private var selectedSourceTab: RelaySettingsSourceTab = .receive
    @State private var validationMessage: String?
    @State private var isShowingAdvancedSources = false
    @State private var isShowingSourcesInfo = false
    @State private var recommendedSources: [RecommendedDataSourceItem] = []
    @State private var isLoadingRecommendedSources = false

    private let recommendationService = NostrFeedService()

    var body: some View {
        ThemedSettingsForm {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.18))
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(connectionSummaryText)
                                .font(.headline)
                            Text(connectionDetailText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        Button {
                            isShowingSourcesInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                                .haloNativeGlass(interactive: true, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("What are sources?")
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(settingsSurfaceStyle.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(appSettings.themeSeparator(defaultOpacity: 0.14), lineWidth: 1)
                )
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    DisclosureGroup(isExpanded: $isShowingAdvancedSources) {
                        VStack(alignment: .leading, spacing: 18) {
                            sourceList
                            recommendedSourcesSection
                            addSourceControls

                            if let validationMessage {
                                messageBanner(
                                    validationMessage,
                                    systemImage: "exclamationmark.circle.fill",
                                    tint: .red
                                )
                            }

                            if let publishError = relaySettings.lastPublishError {
                                messageBanner(
                                    userFacingMessage(for: publishError),
                                    systemImage: "info.circle.fill",
                                    tint: .secondary
                                )
                            }
                        }
                        .padding(.top, 14)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Data Sources")
                                .font(.headline)
                            Text("Advanced controls for where Halo receives from and publishes to.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(settingsSurfaceStyle.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(appSettings.themeSeparator(defaultOpacity: 0.14), lineWidth: 1)
                )
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingSourcesInfo) {
            sourcesInfoSheet
        }
        .task(id: recommendationTaskKey) {
            await loadRecommendedSources()
        }
    }

    private var settingsSurfaceStyle: SettingsFormSurfaceStyle {
        appSettings.settingsFormSurfaceStyle(for: colorScheme)
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowNativeGlassSegmentedPicker(
                selection: $selectedSourceTab,
                items: RelaySettingsSourceTab.allCases,
                title: { $0.rawValue }
            )

            if selectedDataSources.isEmpty {
                Text(selectedSourceTab.emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(selectedDataSources.enumerated()), id: \.element.id) { index, source in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(selectedSourceTab.rawValue) Source \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Text(source.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(source.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            Menu {
                                if source.receives {
                                    Button("Stop Receiving from Source", role: .destructive) {
                                        removeReceiveSource(source.url)
                                    }
                                }
                                if source.publishes {
                                    Button("Stop Publishing to Source", role: .destructive) {
                                        removePublishSource(source.url)
                                    }
                                }
                                if source.messages {
                                    Button("Remove Message Source", role: .destructive) {
                                        removeMessageSource(source.url)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 8) {
                            if source.receives {
                                sourceCapabilityPill("Receive", systemImage: "arrow.down.circle")
                            }
                            if source.publishes {
                                sourceCapabilityPill("Publish", systemImage: "arrow.up.circle")
                            }
                            if source.messages {
                                sourceCapabilityPill("Messages", systemImage: "envelope.circle")
                            }
                        }

                        if selectedSourceTab == .publish && source.publishes {
                            sourcePublishHealth(for: source)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(settingsSurfaceStyle.subcardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(sourceCardBorderColor, lineWidth: sourceCardBorderWidth)
                    )
                }
            }
        }
    }

    private var sourceCardBorderColor: Color {
        appSettings.themeSeparator(defaultOpacity: colorScheme == .light ? 0.28 : 0.18)
    }

    private var sourceCardBorderWidth: CGFloat {
        colorScheme == .light ? 1.35 : 1
    }

    private func sourceCapabilityPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(settingsSurfaceStyle.controlBackground, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private func sourcePublishHealth(for source: DataSourceItem) -> some View {
        if let stats = publishStatsStore.snapshot(for: source.url) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label("Publish acceptance \(acceptanceRateLabel(for: stats))", systemImage: "paperplane.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)

                    Spacer(minLength: 0)
                }

                Text(publishStatsDetailText(for: stats))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let lastFailureMessage = stats.lastFailureMessage, !lastFailureMessage.isEmpty {
                    Text(lastFailureMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(settingsSurfaceStyle.controlBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text("No publish attempts recorded yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var recommendedSourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Recommended Sources")
                    .font(.headline)

                Spacer(minLength: 0)

                if isLoadingRecommendedSources {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("Based on source hints from people you follow. Adding one here only enables receiving from it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if recommendedSources.isEmpty && !isLoadingRecommendedSources {
                Text("No recommendations yet. They’ll appear after Halo has a cached follow list with source hints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recommendedSources) { source in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(source.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Button("Add Receive") {
                            addRecommendedSource(source)
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(settingsSurfaceStyle.controlBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(settingsSurfaceStyle.subcardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.12), lineWidth: 1)
        )
    }

    private var addSourceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Source")
                .font(.headline)

            TextField("wss://source.example.com", text: $relayInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(settingsSurfaceStyle.controlBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(appSettings.themeSeparator(defaultOpacity: 0.2), lineWidth: 1)
                )

            FlowNativeGlassSegmentedPicker(
                selection: $relayScope,
                items: RelayAddScope.allCases,
                title: { $0.rawValue }
            )

            Button("Add Source") {
                addSource()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(settingsSurfaceStyle.subcardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.12), lineWidth: 1)
        )
    }

    private var connectionSummaryText: String {
        let count = dataSources.count
        return "Connected to \(count) \(count == 1 ? "source" : "sources")"
    }

    private var connectionDetailText: String {
        if dataSources.isEmpty {
            return "Add a source to start receiving, publishing, and routing messages."
        }
        return "Halo is using your configured receive, publish, and message sources."
    }

    private var recommendationTaskKey: String {
        [
            auth.currentAccount?.pubkey.lowercased() ?? "signed-out",
            relaySettings.readRelays.joined(separator: "|"),
            relaySettings.writeRelays.joined(separator: "|"),
            String(followStore.followedPubkeys.count)
        ].joined(separator: "::")
    }

    private var dataSources: [DataSourceItem] {
        let readSet = Set(relaySettings.readRelays)
        let writeSet = Set(relaySettings.writeRelays)
        let inboxSet = Set(relaySettings.inboxRelays)
        let ordered = orderedUniqueSources(from: relaySettings.readRelays + relaySettings.writeRelays + relaySettings.inboxRelays)

        return ordered.enumerated().map { index, url in
            DataSourceItem(
                id: "\(index)-\(url)",
                url: url,
                label: sourceLabel(for: url),
                receives: readSet.contains(url),
                publishes: writeSet.contains(url),
                messages: inboxSet.contains(url)
            )
        }
    }

    private var selectedDataSources: [DataSourceItem] {
        dataSources.filter { source in
            switch selectedSourceTab {
            case .receive:
                return source.receives
            case .publish:
                return source.publishes
            case .messages:
                return source.messages
            }
        }
    }

    private func orderedUniqueSources(from values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values {
            guard seen.insert(value).inserted else { continue }
            ordered.append(value)
        }
        return ordered
    }

    private func sourceLabel(for source: String) -> String {
        guard let host = URL(string: source)?.host(), !host.isEmpty else { return source }
        return host
    }

    private func addSource() {
        validationMessage = nil

        do {
            try relaySettings.addRelay(relayInput, scope: relayScope.relayScope)
            relayInput = ""
        } catch {
            validationMessage = userFacingMessage(for: error)
        }
    }

    private func addRecommendedSource(_ source: RecommendedDataSourceItem) {
        validationMessage = nil

        do {
            try relaySettings.addRelay(source.url, scope: .read)
            recommendedSources.removeAll { $0.id == source.id }
        } catch {
            validationMessage = userFacingMessage(for: error)
        }
    }

    @MainActor
    private func loadRecommendedSources() async {
        guard let accountPubkey = auth.currentAccount?.pubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !accountPubkey.isEmpty else {
            recommendedSources = []
            isLoadingRecommendedSources = false
            return
        }

        isLoadingRecommendedSources = true
        let snapshot = await recommendationService.cachedFollowListSnapshot(pubkey: accountPubkey)
        guard !Task.isCancelled else { return }

        let configuredSources = Set(
            (relaySettings.readRelays + relaySettings.writeRelays)
                .map(normalizedSourceKey)
        )
        recommendedSources = recommendedDataSources(
            from: snapshot,
            excluding: configuredSources,
            limit: 5
        )
        isLoadingRecommendedSources = false
    }

    private func removeReceiveSource(_ source: String) {
        validationMessage = nil
        do {
            try relaySettings.removeReadRelay(source)
        } catch {
            validationMessage = userFacingMessage(for: error)
        }
    }

    private func removePublishSource(_ source: String) {
        validationMessage = nil
        do {
            try relaySettings.removeWriteRelay(source)
        } catch {
            validationMessage = userFacingMessage(for: error)
        }
    }

    private func removeMessageSource(_ source: String) {
        validationMessage = nil
        do {
            try relaySettings.removeInboxRelay(source)
        } catch {
            validationMessage = userFacingMessage(for: error)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return userFacingMessage(for: base)
    }

    private func userFacingMessage(for message: String) -> String {
        let base = message
        return base
            .replacingOccurrences(of: "relay settings", with: "connection settings")
            .replacingOccurrences(of: "Relays", with: "Sources")
            .replacingOccurrences(of: "Relay", with: "Source")
            .replacingOccurrences(of: "read relays", with: "receive sources")
            .replacingOccurrences(of: "write relays", with: "publish sources")
            .replacingOccurrences(of: "inbox relays", with: "message sources")
            .replacingOccurrences(of: "relays", with: "sources")
            .replacingOccurrences(of: "relay", with: "source")
    }

    private func recommendedDataSources(
        from snapshot: FollowListSnapshot?,
        excluding configuredSources: Set<String>,
        limit: Int
    ) -> [RecommendedDataSourceItem] {
        guard let snapshot, limit > 0 else { return [] }

        var countsBySource: [String: Int] = [:]
        var displayURLBySource: [String: String] = [:]

        for relayURLs in snapshot.relayHintsByPubkey.values {
            var countedForFollow = Set<String>()
            for relayURL in relayURLs {
                let normalized = normalizedSourceKey(relayURL.absoluteString)
                guard !normalized.isEmpty else { continue }
                guard !configuredSources.contains(normalized) else { continue }
                guard countedForFollow.insert(normalized).inserted else { continue }

                countsBySource[normalized, default: 0] += 1
                displayURLBySource[normalized] = relayURL.absoluteString
            }
        }

        return countsBySource
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .compactMap { source, count in
                let displayURL = displayURLBySource[source] ?? source
                return RecommendedDataSourceItem(
                    url: displayURL,
                    label: sourceLabel(for: displayURL),
                    followedHintCount: count
                )
            }
    }

    private func acceptanceRateLabel(for stats: SourcePublishStatsSnapshot) -> String {
        guard stats.attemptedCount > 0 else { return "0%" }
        return stats.acceptanceRate.formatted(.percent.precision(.fractionLength(0)))
    }

    private func publishStatsDetailText(for stats: SourcePublishStatsSnapshot) -> String {
        var parts = [
            "\(stats.acceptedCount)/\(stats.attemptedCount) accepted",
            "\(stats.failedCount) failed"
        ]
        if stats.rateLimitedCount > 0 {
            parts.append("\(stats.rateLimitedCount) rate limited")
        }
        return parts.joined(separator: " • ")
    }

    private func normalizedSourceKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func messageBanner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(settingsSurfaceStyle.subcardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.12), lineWidth: 1)
        )
    }

    private var sourcesInfoSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What are sources?")
                    .font(.custom("SF Pro Display", size: 28).weight(.semibold))

                Text("Halo does not operate any servers and collects no data. All information is fetched in real time from public servers operated by other people.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Your connection settings decide which public sources Halo reads from and where your posts, follows, and reactions get published.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("About Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(270), .medium])
        .presentationDragIndicator(.visible)
    }
}

private extension RelaySettingsView {
    struct DataSourceItem: Identifiable {
        let id: String
        let url: String
        let label: String
        let receives: Bool
        let publishes: Bool
        let messages: Bool
    }

    struct RecommendedDataSourceItem: Identifiable, Equatable {
        let url: String
        let label: String
        let followedHintCount: Int

        var id: String {
            url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var detail: String {
            "Hinted by \(followedHintCount) followed \(followedHintCount == 1 ? "person" : "people")"
        }
    }
}
