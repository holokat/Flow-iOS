import SwiftUI

struct FollowingListView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @ObservedObject private var followStore = FollowStore.shared
    @StateObject private var viewModel: FollowingListViewModel

    @State private var selectedProfileRoute: ProfileRoute?

    init(
        pubkey: String,
        readRelayURLs: [URL],
        service: NostrFeedService = NostrFeedService()
    ) {
        _viewModel = StateObject(
            wrappedValue: FollowingListViewModel(
                pubkey: pubkey,
                readRelayURLs: readRelayURLs,
                service: service
            )
        )
    }

    var body: some View {
        List {
            if (viewModel.isLoading || viewModel.isRefreshing) && viewModel.rows.isEmpty {
                loadingHeader
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                ForEach(0..<5, id: \.self) { _ in
                    loadingRow
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else if viewModel.rows.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.rows) { row in
                    followingRow(row)
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isCurrentAccount(row.pubkey) {
                                Button(followStore.isFollowing(row.pubkey) ? "Unfollow" : "Follow") {
                                    if followStore.isFollowing(row.pubkey) {
                                        followStore.unfollow(row.pubkey)
                                    } else {
                                        followStore.follow(row.pubkey)
                                    }
                                }
                                .tint(followStore.isFollowing(row.pubkey) ? .red : .accentColor)
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Following")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !followAllTargets.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        followStore.follow(pubkeys: followAllTargets)
                    } label: {
                        Text("Follow All")
                    }
                    .disabled(auth.currentNsec == nil)
                }
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            configureStores()
            await viewModel.loadIfNeeded()
        }
        .navigationDestination(item: $selectedProfileRoute) { route in
            ProfileView(
                pubkey: route.pubkey,
                relayURL: viewModel.readRelayURLs.first ?? URL(string: "wss://relay.damus.io/")!,
                readRelayURLs: viewModel.readRelayURLs,
                writeRelayURLs: relaySettings.writeRelayURLs
            )
        }
        .onChange(of: auth.currentAccount?.pubkey) { _, _ in
            configureStores()
        }
        .onChange(of: auth.currentNsec) { _, _ in
            configureStores()
        }
        .onChange(of: relaySettings.readRelays) { _, _ in
            configureStores()
        }
        .onChange(of: relaySettings.writeRelays) { _, _ in
            configureStores()
        }
    }

    private var followAllTargets: [String] {
        viewModel.rows.map(\.pubkey).filter {
            !isCurrentAccount($0) && !followStore.isFollowing($0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)

                Button("Try Again") {
                    Task {
                        await viewModel.refresh()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No following accounts yet.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var loadingHeader: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading following list…")
                .font(.subheadline)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func followingRow(_ row: FollowingListViewModel.Row) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CompactProfileAvatar(url: row.avatarURL, fallback: row.displayName)
                    .environmentObject(appSettings)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(appSettings.themePalette.foreground)
                            .layoutPriority(2)

                        Text(row.handle)
                            .font(.footnote)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    if let nip05Domain = row.nip05Domain {
                        HStack(spacing: 4) {
                            DomainFavicon(domain: nip05Domain)
                                .environmentObject(appSettings)
                            Text(nip05Domain)
                                .font(.caption)
                                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedProfileRoute = ProfileRoute(pubkey: row.pubkey)
            }

            if isCurrentAccount(row.pubkey) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .accessibilityLabel("This is you")
            } else {
                followToggleButton(for: row)
            }
        }
    }

    private func isCurrentAccount(_ pubkey: String) -> Bool {
        guard let currentPubkey = auth.currentAccount?.pubkey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !currentPubkey.isEmpty else {
            return false
        }
        return pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == currentPubkey
    }

    private func followToggleButton(for row: FollowingListViewModel.Row) -> some View {
        let isFollowing = followStore.isFollowing(row.pubkey)
        let title = isFollowing ? "Following" : "Follow"

        return Button {
            if isFollowing {
                followStore.unfollow(row.pubkey)
            } else {
                followStore.follow(row.pubkey)
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .foregroundStyle(
                    isFollowing
                        ? appSettings.themePalette.foreground
                        : Color.white
                )
                .background(
                    Capsule()
                        .fill(
                            isFollowing
                                ? appSettings.themePalette.secondaryBackground
                                : appSettings.primaryColor
                        )
                )
                .overlay {
                    if isFollowing {
                        Capsule()
                            .stroke(appSettings.themePalette.separator.opacity(0.35), lineWidth: 0.8)
                    }
                }
        }
        .buttonStyle(.plain)
        .followCelebration(
            trigger: followStore.followCelebrationToken(for: row.pubkey),
            accentColor: appSettings.primaryColor
        )
        .disabled(auth.currentNsec == nil)
        .opacity(auth.currentNsec == nil ? 0.5 : 1)
        .accessibilityLabel(title)
    }

    private var loadingRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 150, height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 110, height: 10)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 130, height: 10)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
    }

    private func configureStores() {
        followStore.configure(
            accountPubkey: auth.currentAccount?.pubkey,
            nsec: auth.currentNsec,
            readRelayURLs: effectiveReadRelayURLs,
            writeRelayURLs: effectiveWriteRelayURLs
        )
    }

    private var effectiveReadRelayURLs: [URL] {
        appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
    }

    private var effectiveWriteRelayURLs: [URL] {
        appSettings.effectiveWriteRelayURLs(from: relaySettings.writeRelayURLs, fallbackReadRelayURLs: effectiveReadRelayURLs)
    }
}

private struct CompactProfileAvatar: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let url: URL?
    let fallback: String

    var body: some View {
        Group {
            if appSettings.textOnlyMode {
                fallbackAvatar
            } else if let url {
                CachedAsyncImage(url: url, kind: .avatar) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(appSettings.themePalette.separator.opacity(0.35), lineWidth: 0.6)
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)

            Text(String(fallback.prefix(1)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
        }
    }
}

private struct DomainFavicon: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    let domain: String

    var body: some View {
        Group {
            if appSettings.textOnlyMode {
                fallbackIcon
            } else if let faviconURL {
                CachedAsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: 12, height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    private var fallbackIcon: some View {
        Image(systemName: "globe")
            .font(.caption2)
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
    }

    private var faviconURL: URL? {
        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "sz", value: "32")
        ]
        return components?.url
    }
}
