import SwiftUI

struct HaloSystemRouteView: View {
    let route: HaloDeepLinkRoute

    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore

    private var readRelayURLs: [URL] {
        let values = appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
        if !values.isEmpty {
            return values
        }
        return RelaySettingsStore.defaultReadRelayURLs.compactMap(URL.init(string:))
    }

    private var writeRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(
            from: relaySettings.writeRelayURLs,
            fallbackReadRelayURLs: readRelayURLs
        )
    }

    private var primaryRelayURL: URL {
        readRelayURLs.first ?? URL(string: "wss://relay.damus.io/")!
    }

    var body: some View {
        switch route {
        case .profile(let pubkey):
            NavigationStack {
                ProfileView(
                    pubkey: pubkey,
                    relayURL: primaryRelayURL,
                    readRelayURLs: readRelayURLs,
                    writeRelayURLs: writeRelayURLs
                )
            }
            .flowInteractiveBackSwipe()
        case .note(let reference):
            HaloSystemNoteRouteView(
                reference: reference,
                relayURL: primaryRelayURL,
                readRelayURLs: readRelayURLs
            )
        case .hashtag(let name):
            NavigationStack {
                HashtagFeedView(
                    hashtag: name,
                    relayURL: primaryRelayURL,
                    readRelayURLs: readRelayURLs
                )
            }
            .flowInteractiveBackSwipe()
        case .feed, .search, .compose, .message:
            ContentUnavailableView(
                "Open Halo",
                systemImage: "arrow.up.forward.app",
                description: Text("This destination opens in Halo's main navigation.")
            )
        }
    }
}

private struct HaloSystemNoteRouteView: View {
    let reference: String
    let relayURL: URL
    let readRelayURLs: [URL]

    @Environment(\.dismiss) private var dismiss
    @State private var item: FeedItem?
    @State private var didFinishLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    ThreadDetailView(
                        initialItem: item,
                        relayURL: relayURL,
                        readRelayURLs: readRelayURLs
                    )
                } else if didFinishLoading {
                    ContentUnavailableView(
                        "Note unavailable",
                        systemImage: "text.bubble",
                        description: Text("Halo couldn't find this note on your configured relays.")
                    )
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding note")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .toolbar {
                if item == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", action: dismiss.callAsFunction)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
            .task(id: reference) {
                await loadNote()
            }
        }
        .flowInteractiveBackSwipe()
    }

    private func loadNote() async {
        defer { didFinishLoading = true }
        guard let pointer = NoteContentParser.eventReferencePointer(from: reference) else { return }
        item = await NostrFeedService().fetchReferencedFeedItem(
            reference: pointer,
            relayURLs: readRelayURLs,
            hydrationMode: .full,
            fetchTimeout: 8,
            relayFetchMode: .firstRelayWithEvents,
            moderationSnapshot: MuteStore.shared.filterSnapshot
        )
    }
}
