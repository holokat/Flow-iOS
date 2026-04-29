import NostrSDK
import SwiftUI

private enum MutedContentTab: String, CaseIterable, Identifiable {
    case filters = "Filters"
    case words = "Words"
    case users = "Users"

    var id: String { rawValue }
}

struct SettingsMutedContentView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore
    @ObservedObject private var muteStore = MuteStore.shared

    @State private var selectedTab: MutedContentTab = .filters
    @State private var mutedUserProfiles: [String: NostrProfile] = [:]
    @State private var isLoadingMutedUsers = false

    var body: some View {
        ThemedSettingsForm {
            Section {
                FlowCapsuleTabBar(
                    selection: $selectedTab,
                    items: MutedContentTab.allCases,
                    title: { $0.rawValue }
                )
            }

            if selectedTab == .filters {
                filterSections
            } else if selectedTab == .words {
                mutedWordsSections
            } else {
                mutedUsersSections
            }

            if let error = muteStore.lastPublishError, !error.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Muted Content")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            muteStore.configure(
                accountPubkey: auth.currentAccount?.pubkey,
                nsec: auth.currentNsec,
                readRelayURLs: relaySettings.readRelayURLs,
                writeRelayURLs: relaySettings.writeRelayURLs
            )
            muteStore.refreshFromRelay()
        }
        .task(id: mutedUsersFetchKey) {
            guard selectedTab == .users else { return }
            await loadMutedUserProfiles()
        }
        .onChange(of: selectedTab) { _, newValue in
            guard newValue == .users else { return }
            Task {
                await loadMutedUserProfiles()
            }
        }
    }

    @ViewBuilder
    private var filterSections: some View {
        Section {
            Toggle("Spam replies", isOn: spamReplyFilterBinding)

            Text("Uses an on-device model to hide likely-bot replies in threads and Pulse from people you don't follow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Text("Model scoring stays on this device. Marked spam is shared across your local accounts.")
        }

        Section {
            if appSettings.spamFilterMarkedPubkeys.isEmpty {
                Text("No accounts marked as spam yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appSettings.spamFilterMarkedPubkeys, id: \.self) { pubkey in
                    spamLabelRow(
                        pubkey: pubkey,
                        removeAccessibilityLabel: "Remove \(shortNostrIdentifier(pubkey)) from Marked spam",
                        onRemove: {
                            appSettings.removeSpamFilterMarkedPubkey(pubkey)
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            appSettings.removeSpamFilterMarkedPubkey(pubkey)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
            }
        } header: {
            Text("Marked Spam")
        } footer: {
            Text("Mark Spam from a note or profile to hide that author and personalize likely-spam scoring for every account on this device.")
        }
    }

    private func spamLabelRow(
        pubkey: String,
        removeAccessibilityLabel: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortNostrIdentifier(pubkey))
                    .font(.body.weight(.medium))

                Text(pubkey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(removeAccessibilityLabel)
        }
    }

    private var spamReplyFilterBinding: Binding<Bool> {
        Binding(
            get: { appSettings.spamReplyFilterEnabled },
            set: { appSettings.spamReplyFilterEnabled = $0 }
        )
    }

    @ViewBuilder
    private var mutedWordsSections: some View {
        Section {
            ForEach(orderedKeywordLists) { list in
                NavigationLink {
                    SettingsDetailNavigationHost(title: list.title) {
                        SettingsMutedKeywordListDetailView(listID: list.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(list.title)
                                .font(.body.weight(.medium))

                            Spacer(minLength: 8)

                            if list.allowsToggle {
                                Text(list.isEnabled ? "On" : "Off")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(list.isEnabled ? .secondary : .tertiary)
                            } else {
                                Text("Private")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("\(list.wordCount) term\(list.wordCount == 1 ? "" : "s")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text(list.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Lists")
        } footer: {
            Text("Add any word, phrase, or hashtag to hide matching notes instantly across your feeds.")
        }
    }

    @ViewBuilder
    private var mutedUsersSections: some View {
        if orderedMutedPubkeys.isEmpty {
            Section {
                Text("No muted people yet.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Muted Users")
            } footer: {
                Text("Mute people from a note menu or profile, and they’ll appear here.")
            }
        } else {
            Section {
                if isLoadingMutedUsers && mutedUserProfiles.isEmpty {
                    ProgressView("Loading muted users...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(orderedMutedPubkeys, id: \.self) { pubkey in
                    NavigationLink {
                        SettingsDetailNavigationHost(title: "Muted User") {
                            ProfileView(
                                pubkey: pubkey,
                                relayURL: effectivePrimaryRelayURL,
                                readRelayURLs: effectiveReadRelayURLs,
                                writeRelayURLs: effectiveWriteRelayURLs
                            )
                        }
                    } label: {
                        MutedUserRow(
                            pubkey: pubkey,
                            profile: mutedUserProfiles[pubkey]
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            muteStore.toggleMute(pubkey)
                        } label: {
                            Label("Unmute", systemImage: "speaker.wave.2")
                        }
                        .tint(.secondary)
                    }
                }
            } header: {
                Text("Muted Users")
            } footer: {
                Text("Muted people are hidden immediately. Unmute from here at any time.")
            }
        }
    }

    private var orderedKeywordLists: [MutedKeywordListState] {
        muteStore.mutedKeywordLists.sorted { lhs, rhs in
            if lhs.id == "other" { return true }
            if rhs.id == "other" { return false }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var orderedMutedPubkeys: [String] {
        muteStore.mutedPubkeys.sorted()
    }

    private var effectiveReadRelayURLs: [URL] {
        let urls = relaySettings.readRelayURLs.isEmpty ? relaySettings.writeRelayURLs : relaySettings.readRelayURLs
        return urls.isEmpty ? [AppSettingsStore.slowModeRelayURL] : urls
    }

    private var effectiveWriteRelayURLs: [URL] {
        let urls = relaySettings.writeRelayURLs.isEmpty ? effectiveReadRelayURLs : relaySettings.writeRelayURLs
        return urls.isEmpty ? [AppSettingsStore.slowModeRelayURL] : urls
    }

    private var effectivePrimaryRelayURL: URL {
        effectiveReadRelayURLs.first ?? AppSettingsStore.slowModeRelayURL
    }

    private var mutedUsersFetchKey: String {
        let pubkeyKey = orderedMutedPubkeys.joined(separator: "|")
        let relayKey = effectiveReadRelayURLs.map(\.absoluteString).joined(separator: "|")
        return "\(selectedTab.rawValue)|\(pubkeyKey)|\(relayKey)"
    }

    @MainActor
    private func loadMutedUserProfiles() async {
        let pubkeys = orderedMutedPubkeys
        guard !pubkeys.isEmpty else {
            mutedUserProfiles = [:]
            isLoadingMutedUsers = false
            return
        }

        isLoadingMutedUsers = true
        let profiles = await NostrFeedService().fetchProfiles(
            relayURLs: effectiveReadRelayURLs,
            pubkeys: pubkeys
        )
        guard !Task.isCancelled else { return }
        mutedUserProfiles = profiles
        isLoadingMutedUsers = false
    }
}

private struct MutedUserRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let pubkey: String
    let profile: NostrProfile?

    var body: some View {
        HStack(spacing: 12) {
            mutedUserAvatar

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Text(handle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var mutedUserAvatar: some View {
        Group {
            if let avatarURL {
                CachedAsyncImage(url: avatarURL, kind: .avatar) { phase in
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
        .frame(width: 42, height: 42)
        .clipShape(Circle())
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(appSettings.themePalette.tertiaryFill)
            .overlay {
                Text(String(displayName.prefix(1)).uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
    }

    private var displayName: String {
        let trimmedDisplayName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDisplayName, !trimmedDisplayName.isEmpty {
            return trimmedDisplayName
        }

        let trimmedName = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return shortNostrIdentifier(pubkey)
    }

    private var handle: String {
        let trimmedName = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return "@\(trimmedName.lowercased())"
        }

        return "@\(shortNostrIdentifier(pubkey).lowercased())"
    }

    private var nip05: String? {
        let trimmed = profile?.nip05?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private var avatarURL: URL? {
        profile?.resolvedAvatarURL
    }
}

private struct SettingsMutedKeywordListDetailView: View {
    @ObservedObject private var muteStore = MuteStore.shared
    @State private var draftWord = ""

    let listID: String

    var body: some View {
        ThemedSettingsForm {
            if let list = currentList {
                if list.allowsToggle {
                    Section {
                        Toggle("Use this list", isOn: listEnabledBinding(for: list))
                    } footer: {
                        Text("Turn this off to stop filtering these terms without deleting the list.")
                    }
                }

                if list.allowsAddingWords {
                    Section("Add Term") {
                        TextField("Add word, phrase, or hashtag", text: $draftWord)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addDraftWord)

                        Button("Add Term") {
                            addDraftWord()
                        }
                        .disabled(normalizedDraftWord.isEmpty)
                    }
                }

                Section {
                    if list.words.isEmpty {
                        Text("No terms in this list.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(list.words, id: \.self) { word in
                            HStack(spacing: 12) {
                                Text(word)
                                    .font(.body)

                                Spacer(minLength: 8)

                                Button {
                                    muteStore.removeWord(word, from: list.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(word)")
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    muteStore.removeWord(word, from: list.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Muted Terms")
                } footer: {
                    Text(list.allowsAddingWords
                         ? "Removing a term updates your private encrypted mute list immediately."
                         : "These are private muted terms already stored on your account.")
                }
            }

            if let error = muteStore.lastPublishError, !error.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(currentList?.title ?? "Muted Terms")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentList: MutedKeywordListState? {
        muteStore.mutedKeywordLists.first(where: { $0.id == listID })
    }

    private var normalizedDraftWord: String {
        draftWord
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func listEnabledBinding(for list: MutedKeywordListState) -> Binding<Bool> {
        Binding(
            get: {
                muteStore.mutedKeywordLists.first(where: { $0.id == list.id })?.isEnabled ?? list.isEnabled
            },
            set: { isEnabled in
                muteStore.setKeywordListEnabled(list.id, isEnabled: isEnabled)
            }
        )
    }

    private func addDraftWord() {
        let trimmed = normalizedDraftWord
        guard !trimmed.isEmpty else { return }
        muteStore.addWord(trimmed, to: listID)
        draftWord = ""
    }
}
