import SwiftUI

struct SettingsFeedsView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        ThemedSettingsForm {
            Section("Visible Feed Tabs") {
                SettingsToggleRow(
                    title: "Show Polls Feed",
                    isOn: Binding(
                        get: { appSettings.pollsFeedVisible },
                        set: { appSettings.pollsFeedVisible = $0 }
                    ),
                    footer: "Keep a dedicated Polls feed in the home feed picker for polls from people you follow."
                )
            }

            Section {
                SettingsNavigationRow(title: "Interests", systemImage: "sparkles") {
                    SettingsInterestsFeedView()
                }

                SettingsNavigationRow(title: "News", systemImage: "newspaper.fill") {
                    SettingsNewsFeedView()
                }
            } header: {
                Text("Feed Setup")
            } footer: {
                Text("Choose what powers Interests and News.")
            }

            SettingsCustomFeedsSection()
        }
        .navigationTitle("Feeds")
        .navigationBarTitleDisplayMode(.inline)
    }
}
