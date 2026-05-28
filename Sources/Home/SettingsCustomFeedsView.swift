import SwiftUI

struct SettingsCustomFeedsView: View {
    var body: some View {
        ThemedSettingsForm {
            SettingsCustomFeedsSection()
        }
        .navigationTitle("Custom Feeds")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct SettingsCustomFeedsSection: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    @State private var draft: SettingsCustomFeedDraft?

    var body: some View {
        Section {
            Button {
                draft = SettingsCustomFeedDraft()
            } label: {
                Label("Create Feed", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            if appSettings.customFeeds.isEmpty {
                Text("No custom feeds yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appSettings.customFeeds) { feed in
                    customFeedRow(feed)
                        .swipeActions {
                            Button(role: .destructive) {
                                appSettings.removeCustomFeed(id: feed.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text("Custom Feeds")
        } footer: {
            Text("Mix hashtags, people, and phrases into feeds that appear in Feed Source.")
        }
        .sheet(item: $draft) { currentDraft in
            SettingsCustomFeedEditorSheet(initialDraft: currentDraft)
        }
    }

    private func customFeedRow(_ feed: CustomFeedDefinition) -> some View {
        Button {
            draft = SettingsCustomFeedDraft(feed: feed)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: feed.iconSystemName)
                        .font(.headline)
                        .foregroundStyle(appSettings.primaryColor)
                        .frame(width: 24, alignment: .center)

                    Text(feed.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                Text(criteriaSummary(for: feed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func criteriaSummary(for feed: CustomFeedDefinition) -> String {
        let hashtags = feed.hashtags.map { "#\($0)" }
        let authors = feed.authorPubkeys.map { "@\(shortNostrIdentifier($0).lowercased())" }
        let phrases = feed.phrases.map { "\"\($0)\"" }
        let parts = hashtags + authors + phrases
        return parts.isEmpty ? "No sources configured" : parts.joined(separator: " • ")
    }
}

private struct SettingsCustomFeedDraft: Identifiable, Hashable {
    var id: String
    var name: String
    var iconSystemName: String
    var hashtags: [String]
    var authorPubkeys: [String]
    var phrases: [String]

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String = "",
        iconSystemName: String = CustomFeedIconCatalog.randomIconName(),
        hashtags: [String] = [],
        authorPubkeys: [String] = [],
        phrases: [String] = []
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.hashtags = hashtags
        self.authorPubkeys = authorPubkeys
        self.phrases = phrases
    }

    init(feed: CustomFeedDefinition) {
        self.id = feed.id
        self.name = feed.name
        self.iconSystemName = feed.iconSystemName
        self.hashtags = feed.hashtags
        self.authorPubkeys = feed.authorPubkeys
        self.phrases = feed.phrases
    }

    var definition: CustomFeedDefinition {
        CustomFeedDefinition(
            id: id,
            name: name,
            iconSystemName: iconSystemName,
            hashtags: hashtags,
            authorPubkeys: authorPubkeys,
            phrases: phrases
        )
    }
}

private struct SettingsCustomFeedEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore

    @State private var draft: SettingsCustomFeedDraft
    @State private var hashtagInput = ""
    @State private var phraseInput = ""
    @State private var validationMessage: String?

    private let service = NostrFeedService()

    init(initialDraft: SettingsCustomFeedDraft) {
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            ThemedSettingsForm {
                Section("Name") {
                    TextField("Soccer Season", text: $draft.name)
                }

                Section("Icon") {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(appSettings.primaryColor.opacity(0.14))
                                .frame(width: 56, height: 56)

                            Image(systemName: draft.iconSystemName)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(appSettings.primaryColor)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Feed icon")
                                .font(.subheadline.weight(.medium))
                            Button("Randomize Icon") {
                                draft.iconSystemName = CustomFeedIconCatalog.randomIconName()
                            }
                            .font(.footnote.weight(.semibold))
                        }

                        Spacer(minLength: 0)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                        ForEach(CustomFeedIconCatalog.availableIcons, id: \.self) { icon in
                            Button {
                                draft.iconSystemName = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.headline)
                                    .foregroundStyle(draft.iconSystemName == icon ? appSettings.primaryColor : .primary)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(
                                                draft.iconSystemName == icon
                                                    ? appSettings.primaryColor.opacity(0.16)
                                                    : appSettings.themePalette.secondaryBackground
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }

                Section("Hashtags") {
                    HStack(spacing: 10) {
                        TextField("#soccer", text: $hashtagInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addHashtag)

                        Button(action: addHashtag) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(hashtagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Add hashtag")
                    }

                    if draft.hashtags.isEmpty {
                        Text("No hashtags added yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(draft.hashtags, id: \.self) { hashtag in
                            HStack(spacing: 10) {
                                Label("#\(hashtag)", systemImage: "number")
                                    .foregroundStyle(.primary)

                                Spacer(minLength: 8)

                                Button {
                                    draft.hashtags.removeAll { $0 == hashtag }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(appSettings.primaryColor)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove #\(hashtag)")
                            }
                        }
                    }
                }

                Section("People") {
                    NavigationLink {
                        SettingsDetailNavigationHost(title: "Add Person") {
                            SettingsCustomFeedPersonPickerView(
                                selectedPubkeys: $draft.authorPubkeys,
                                relayURLs: personSearchRelayURLs
                            )
                        }
                    } label: {
                        Label("Add Person", systemImage: "person.crop.circle.badge.plus")
                            .font(.body.weight(.semibold))
                    }

                    if draft.authorPubkeys.isEmpty {
                        Text("No specific people added yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(draft.authorPubkeys, id: \.self) { pubkey in
                            SettingsNewsAuthorRow(
                                pubkey: pubkey,
                                relayURLs: personSearchRelayURLs,
                                service: service
                            ) {
                                draft.authorPubkeys.removeAll { $0 == pubkey }
                            }
                        }
                    }
                }

                Section("Phrases") {
                    HStack(spacing: 10) {
                        TextField("soccer scores", text: $phraseInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addPhrase)

                        Button(action: addPhrase) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(phraseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Add phrase")
                    }

                    if draft.phrases.isEmpty {
                        Text("No phrases added yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(draft.phrases, id: \.self) { phrase in
                            HStack(spacing: 10) {
                                Label(phrase, systemImage: "text.quote")
                                    .foregroundStyle(.primary)

                                Spacer(minLength: 8)

                                Button {
                                    draft.phrases.removeAll { $0.caseInsensitiveCompare(phrase) == .orderedSame }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(appSettings.primaryColor)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(phrase)")
                            }
                        }
                    }
                }

                if isEditingExistingFeed {
                    Section {
                        Button("Delete Feed", role: .destructive) {
                            appSettings.removeCustomFeed(id: draft.id)
                            dismiss()
                        }
                    }
                }

                if let validationMessage, !validationMessage.isEmpty {
                    Section {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditingExistingFeed ? "Edit Feed" : "Create Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditingExistingFeed ? "Save" : "Create") {
                        saveFeed()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var isEditingExistingFeed: Bool {
        appSettings.customFeed(withID: draft.id) != nil
    }

    private var personSearchRelayURLs: [URL] {
        SettingsFeedRelayURLs.normalized(
            relaySettings.readRelayURLs +
            appSettings.newsRelayURLs +
            SettingsFeedRelayURLs.searchablePeopleRelayURLs
        )
    }

    private func addHashtag() {
        validationMessage = nil
        guard let normalized = AppSettingsStore.normalizedNewsHashtag(hashtagInput) else {
            validationMessage = AppSettingsError.invalidNewsHashtag.errorDescription
            return
        }

        if !draft.hashtags.contains(normalized) {
            draft.hashtags.append(normalized)
        }
        hashtagInput = ""
    }

    private func addPhrase() {
        validationMessage = nil
        guard let normalized = AppSettingsStore.normalizedCustomFeedPhrase(phraseInput) else {
            return
        }

        if !draft.phrases.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            draft.phrases.append(normalized)
        }
        phraseInput = ""
    }

    private func saveFeed() {
        validationMessage = nil

        do {
            try appSettings.saveCustomFeed(draft.definition)
            dismiss()
        } catch {
            validationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct SettingsCustomFeedPersonPickerView: View {
    @Binding var selectedPubkeys: [String]
    let relayURLs: [URL]

    var body: some View {
        SettingsFeedPersonPicker(
            relayURLs: relayURLs,
            searchFooter: "You can also paste a hex pubkey, npub, or nprofile directly.",
            isAdded: { pubkey in
                selectedPubkeys.contains(pubkey.lowercased())
            },
            onAdd: { result in
                let normalized = result.pubkey.lowercased()
                if !selectedPubkeys.contains(normalized) {
                    selectedPubkeys.append(normalized)
                }
            }
        )
    }
}
