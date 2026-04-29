import SwiftUI

struct SettingsNewsFeedView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var relaySettings: RelaySettingsStore

    @State private var relayInput = ""
    @State private var hashtagInput = ""
    @State private var validationMessage: String?

    private let service = NostrFeedService()

    var body: some View {
        ThemedSettingsForm {
            Section {
                ForEach(appSettings.newsRelayURLs, id: \.self) { relay in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(relayLabel(for: relay))
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(relay.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Button {
                            removeRelay(relay)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(appSettings.primaryColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(appSettings.newsRelayURLs.count <= 1)
                        .accessibilityLabel("Remove \(relayLabel(for: relay))")
                    }
                }
            } header: {
                Text("News Relays")
            } footer: {
                Text("The News feed listens to all configured News relays.")
            }

            Section("Add Relay") {
                TextField("wss://news.example.com", text: $relayInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addRelay)

                Button("Add Relay") {
                    addRelay()
                }
                .buttonStyle(.borderedProminent)
                .disabled(relayInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                NavigationLink {
                    SettingsDetailNavigationHost(title: "Add Person") {
                        SettingsNewsPersonPickerView()
                    }
                } label: {
                    Label("Add Person", systemImage: "person.crop.circle.badge.plus")
                }

                if appSettings.newsAuthorPubkeys.isEmpty {
                    Text("No specific people added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appSettings.newsAuthorPubkeys, id: \.self) { pubkey in
                        SettingsNewsAuthorRow(
                            pubkey: pubkey,
                            relayURLs: newsSearchRelayURLs,
                            service: service
                        ) {
                            appSettings.removeNewsAuthor(pubkey)
                        }
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Text("Added people will always be blended into the News feed, even if they post on relays outside the News relay list.")
            }

            Section {
                if appSettings.newsHashtags.isEmpty {
                    Text("No hashtags added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appSettings.newsHashtags, id: \.self) { hashtag in
                        HStack(spacing: 10) {
                            Label("#\(hashtag)", systemImage: "number")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Button {
                                appSettings.removeNewsHashtag(hashtag)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(appSettings.primaryColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove #\(hashtag)")
                        }
                    }
                }
            } header: {
                Text("Hashtags")
            } footer: {
                Text("Use hashtags to pull topic-specific notes into News.")
            }

            Section("Add Hashtag") {
                TextField("#breaking", text: $hashtagInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addHashtag)

                Button("Add Hashtag") {
                    addHashtag()
                }
                .buttonStyle(.borderedProminent)
                .disabled(hashtagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("News")
        .navigationBarTitleDisplayMode(.large)
    }

    private var newsSearchRelayURLs: [URL] {
        SettingsFeedRelayURLs.normalized(
            relaySettings.readRelayURLs +
            appSettings.newsRelayURLs +
            SettingsFeedRelayURLs.searchablePeopleRelayURLs
        )
    }

    private func relayLabel(for relay: URL) -> String {
        guard let host = relay.host, !host.isEmpty else {
            return relay.absoluteString
        }
        return host
    }

    private func addRelay() {
        validationMessage = nil

        do {
            try appSettings.addNewsRelay(relayInput)
            relayInput = ""
        } catch {
            validationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func removeRelay(_ relay: URL) {
        validationMessage = nil

        do {
            try appSettings.removeNewsRelay(relay)
        } catch {
            validationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func addHashtag() {
        validationMessage = nil

        do {
            try appSettings.addNewsHashtag(hashtagInput)
            hashtagInput = ""
        } catch {
            validationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
