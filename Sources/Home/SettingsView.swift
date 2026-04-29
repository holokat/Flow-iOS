import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var breakReminderCoordinator: BreakReminderCoordinator
    @EnvironmentObject private var relaySettings: RelaySettingsStore

    @ObservedObject var sheetState: SettingsSheetState

    var body: some View {
        ZStack {
            settingsSurfaceStyle.formBackground
                .ignoresSafeArea()

            NavigationStack(path: navigationPathBinding) {
                VStack(spacing: 0) {
                    ThemedSettingsTitleHeader("Settings") {
                        ThemedToolbarDoneButton {
                            dismiss()
                        }
                    }

                    ThemedSettingsForm {
                        ThemedSettingsSection {
                            SettingsValueNavigationRow(
                                title: "General",
                                systemImage: "slider.horizontal.3",
                                value: .general
                            )

                            SettingsValueNavigationRow(
                                title: "Appearance",
                                systemImage: "paintbrush",
                                value: .appearance
                            )

                            SettingsValueNavigationRow(
                                title: "Feeds",
                                systemImage: "newspaper",
                                value: .feeds
                            )

                            SettingsValueNavigationRow(
                                title: "Notifications",
                                systemImage: "bell.badge",
                                value: .notifications
                            )

                            SettingsValueNavigationRow(
                                title: "Media",
                                systemImage: "photo.on.rectangle.angled",
                                value: .media
                            )

                            SettingsValueNavigationRow(
                                title: "Muted Content",
                                systemImage: "speaker.slash",
                                value: .mutedContent
                            )

                            SettingsValueNavigationRow(
                                title: "Keys",
                                systemImage: "key",
                                value: .keys
                            )

                            SettingsValueNavigationRow(
                                title: "Connection",
                                subtitle: connectionSummaryText,
                                systemImage: "dot.radiowaves.left.and.right",
                                value: .connection
                            )
                        }
                    }
                    .padding(.top, -4)
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(
                    SettingsNavigationChrome.navigationBarVisibility(
                        isShowingDetail: !sheetState.navigationPath.isEmpty
                    ),
                    for: .navigationBar
                )
                .navigationDestination(for: SettingsDestination.self) { destination in
                    SettingsDetailNavigationHost(title: destination.title, onBack: popSettingsDestination) {
                        settingsDestinationView(for: destination)
                    }
                }
                .overlay {
                    BreakReminderOverlayHost(coordinator: breakReminderCoordinator)
                }
                .task {
                    await appSettings.refreshNotificationAuthorizationStatus()
                }
            }
        }
        .presentationBackground(settingsSurfaceStyle.formBackground)
        .preferredColorScheme(appSettings.preferredColorScheme)
    }

    private var settingsSurfaceStyle: SettingsFormSurfaceStyle {
        let effectiveColorScheme = appSettings.preferredColorScheme ?? colorScheme
        return appSettings.settingsFormSurfaceStyle(for: effectiveColorScheme)
    }

    private var connectionSummaryText: String {
        let count = Set(relaySettings.readRelays + relaySettings.writeRelays).count
        return "Connected to \(count) \(count == 1 ? "source" : "sources")"
    }

    private var navigationPathBinding: Binding<[SettingsDestination]> {
        Binding(
            get: { sheetState.navigationPath },
            set: { sheetState.navigationPath = $0 }
        )
    }

    private func popSettingsDestination() {
        guard !sheetState.navigationPath.isEmpty else { return }
        sheetState.navigationPath.removeLast()
    }

    @ViewBuilder
    private func settingsDestinationView(for destination: SettingsDestination) -> some View {
        switch destination {
        case .general:
            SettingsGeneralView()
        case .appearance:
            SettingsAppearanceView()
        case .feeds:
            SettingsFeedsView()
        case .notifications:
            SettingsNotificationsView()
        case .media:
            SettingsMediaView()
        case .mutedContent:
            SettingsMutedContentView()
        case .keys:
            KeysView()
        case .connection:
            RelaySettingsView()
        }
    }
}

@MainActor
final class SettingsSheetState: ObservableObject {
    @Published var navigationPath: [SettingsDestination] = []

    func reset() {
        navigationPath.removeAll()
    }
}

enum SettingsDestination: Hashable {
    case general
    case appearance
    case feeds
    case notifications
    case media
    case mutedContent
    case keys
    case connection

    var title: String {
        switch self {
        case .general:
            "General"
        case .appearance:
            "Appearance"
        case .feeds:
            "Feeds"
        case .notifications:
            "Notifications"
        case .media:
            "Media"
        case .mutedContent:
            "Muted Content"
        case .keys:
            "Keys"
        case .connection:
            "Connection"
        }
    }
}
