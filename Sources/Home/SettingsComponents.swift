import SwiftUI

struct SettingsNavigationRow<Destination: View>: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    let subtitle: String?
    let systemImage: String
    let destination: Destination

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            SettingsDetailNavigationHost(title: title) {
                destination
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appSettings.primaryColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(appSettings.appFont(.body, weight: .regular))
                        .foregroundStyle(appSettings.themePalette.foreground)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(appSettings.appFont(.footnote))
                            .foregroundStyle(appSettings.themePalette.mutedForeground)
                    }
                }

                Spacer(minLength: 8)
            }
        }
    }
}

struct SettingsValueNavigationRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    let subtitle: String?
    let systemImage: String
    let value: SettingsDestination

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        value: SettingsDestination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.value = value
    }

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appSettings.primaryColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(appSettings.appFont(.body, weight: .regular))
                        .foregroundStyle(appSettings.themePalette.foreground)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(appSettings.appFont(.footnote))
                            .foregroundStyle(appSettings.themePalette.mutedForeground)
                    }
                }

                Spacer(minLength: 8)
            }
        }
    }
}

struct SettingsToggleRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    @Binding var isOn: Bool
    let footer: String?
    let info: String?

    init(
        title: String,
        isOn: Binding<Bool>,
        footer: String? = nil,
        info: String? = nil
    ) {
        self.title = title
        self._isOn = isOn
        self.footer = footer
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 6) {
                    Text(title)
                    if let info, !info.isEmpty {
                        SettingsInfoButton(title: title, message: info)
                    }
                }
            }

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(appSettings.themePalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsInfoButton: View {
    let title: String
    let message: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information about \(title)")
        .alert(title, isPresented: $isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

struct NotificationPreferencesView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var navigationTitleText: String = "Notifications"

    var body: some View {
        ThemedSettingsForm {
            Section("System Notifications") {
                NotificationPreferencesToggleRow(
                    title: "Enable Notifications",
                    isOn: Binding(
                        get: { appSettings.notificationsEnabled },
                        set: { appSettings.notificationsEnabled = $0 }
                    ),
                    footer: appSettings.notificationsStatusDescription
                )
            }

            Section {
                Toggle("Mentions", isOn: Binding(
                    get: { appSettings.activityMentionNotificationsEnabled },
                    set: { appSettings.activityMentionNotificationsEnabled = $0 }
                ))

                Toggle("Reactions", isOn: Binding(
                    get: { appSettings.activityReactionNotificationsEnabled },
                    set: { appSettings.activityReactionNotificationsEnabled = $0 }
                ))

                Toggle("Replies", isOn: Binding(
                    get: { appSettings.activityReplyNotificationsEnabled },
                    set: { appSettings.activityReplyNotificationsEnabled = $0 }
                ))

                Toggle("Reshares", isOn: Binding(
                    get: { appSettings.activityReshareNotificationsEnabled },
                    set: { appSettings.activityReshareNotificationsEnabled = $0 }
                ))

                Toggle("Quote Shares", isOn: Binding(
                    get: { appSettings.activityQuoteShareNotificationsEnabled },
                    set: { appSettings.activityQuoteShareNotificationsEnabled = $0 }
                ))
            } header: {
                Text("Pulse Alerts")
            } footer: {
                Text("These controls decide which Pulse events trigger the in-app bell badge and future notification delivery.")
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await appSettings.refreshNotificationAuthorizationStatus()
        }
    }
}

struct SettingsFormSurfaceStyle {
    let formBackground: Color
    let cardBackground: Color
    let cardBorder: Color
    let subcardBackground: Color
    let controlBackground: Color
    let navigationBackground: Color
}

enum SettingsSurfaceBackgroundRole: Equatable {
    case form
    case navigation
}

enum SettingsNavigationChrome {
    static func navigationBarVisibility(isShowingDetail: Bool) -> Visibility {
        .hidden
    }
}

enum SettingsDetailNavigationLayout {
    static let height: CGFloat = 92
    static let horizontalPadding: CGFloat = 20
    static let backButtonSize: CGFloat = 46
    static let headerBackgroundRole: SettingsSurfaceBackgroundRole = .form
}

struct SettingsDetailNavigationHost<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore

    private let title: String
    private let onBack: (() -> Void)?
    private let content: Content

    init(
        title: String,
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsDetailNavigationHeader(title: title, onBack: goBack)

            content
        }
        .background(surfaceStyle.formBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(SettingsNavigationChrome.navigationBarVisibility(isShowingDetail: true), for: .navigationBar)
    }

    private var surfaceStyle: SettingsFormSurfaceStyle {
        let effectiveColorScheme = appSettings.preferredColorScheme ?? colorScheme
        return appSettings.settingsFormSurfaceStyle(for: effectiveColorScheme)
    }

    private func goBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }
}

private struct SettingsDetailNavigationHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(appSettings.appFont(.title3, weight: .semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .frame(
                            width: SettingsDetailNavigationLayout.backButtonSize,
                            height: SettingsDetailNavigationLayout.backButtonSize
                        )
                        .background(surfaceStyle.controlBackground.opacity(0.92), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(appSettings.themeSeparator(defaultOpacity: 0.16), lineWidth: 0.7)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer(minLength: SettingsDetailNavigationLayout.backButtonSize)
            }

            Text(title)
                .font(appSettings.appFont(.headline, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: SettingsDetailNavigationLayout.height)
        .padding(.horizontal, SettingsDetailNavigationLayout.horizontalPadding)
        .background(surfaceStyle.background(for: SettingsDetailNavigationLayout.headerBackgroundRole))
    }

    private var surfaceStyle: SettingsFormSurfaceStyle {
        let effectiveColorScheme = appSettings.preferredColorScheme ?? colorScheme
        return appSettings.settingsFormSurfaceStyle(for: effectiveColorScheme)
    }
}

extension SettingsFormSurfaceStyle {
    func background(for role: SettingsSurfaceBackgroundRole) -> Color {
        switch role {
        case .form:
            formBackground
        case .navigation:
            navigationBackground
        }
    }
}

extension AppSettingsStore {
    func settingsFormSurfaceStyle(for colorScheme: ColorScheme) -> SettingsFormSurfaceStyle {
        let palette = themePalette
        let subcardBackground = colorScheme == .light
            ? palette.sheetCardBackground
            : palette.sheetInsetBackground
        let formBackground: Color = colorScheme == .light
            ? .white
            : palette.sheetBackground
        let navigationBackground: Color = colorScheme == .light
            ? .white
            : palette.navigationBackground

        return SettingsFormSurfaceStyle(
            formBackground: formBackground,
            cardBackground: palette.sheetCardBackground,
            cardBorder: settingsCardBorder,
            subcardBackground: subcardBackground,
            controlBackground: palette.sheetInsetBackground,
            navigationBackground: navigationBackground
        )
    }
}

struct ThemedSettingsForm<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let effectiveColorScheme = appSettings.preferredColorScheme ?? colorScheme
        let surfaceStyle = appSettings.settingsFormSurfaceStyle(for: effectiveColorScheme)

        return Form {
            content
                .listRowBackground(surfaceStyle.cardBackground)
                .listRowSeparatorTint(surfaceStyle.cardBorder)
                .listSectionSeparatorTint(surfaceStyle.cardBorder)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(surfaceStyle.formBackground)
        .tint(appSettings.primaryColor)
        .listRowSeparatorTint(surfaceStyle.cardBorder)
        .listSectionSeparatorTint(surfaceStyle.cardBorder)
        .toolbarBackground(surfaceStyle.navigationBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(effectiveColorScheme, for: .navigationBar)
        .presentationBackground(surfaceStyle.formBackground)
        .preferredColorScheme(appSettings.preferredColorScheme)
    }
}

struct ThemedSettingsTitleHeader<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore

    private let title: String
    private let trailing: Trailing

    init(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                trailing
            }
            .frame(minHeight: 32)
            .padding(.bottom, 10)

            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .frame(minHeight: 48, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(titleBackground)
    }

    private var titleBackground: Color {
        let effectiveColorScheme = appSettings.preferredColorScheme ?? colorScheme
        return appSettings.settingsFormSurfaceStyle(for: effectiveColorScheme).formBackground
    }
}

extension ThemedSettingsTitleHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

struct ThemedToolbarDoneButton: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var title: String = "Done"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(appSettings.appFont(.footnote, weight: .semibold))
                .foregroundStyle(appSettings.themePalette.foreground)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct ThemedSettingsSection: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    private let title: LocalizedStringKey?
    private let content: AnyView
    private let header: AnyView?
    private let footer: AnyView?

    init<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = AnyView(content())
        self.header = nil
        self.footer = nil
    }

    init<Content: View>(
        @ViewBuilder content: () -> Content
    ) {
        self.title = nil
        self.content = AnyView(content())
        self.header = nil
        self.footer = nil
    }

    init<Content: View, Header: View, Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = nil
        self.content = AnyView(content())
        self.header = AnyView(header())
        self.footer = AnyView(footer())
    }

    var body: some View {
        sectionBody
            .listRowBackground(appSettings.themePalette.sheetCardBackground)
            .listRowSeparatorTint(appSettings.settingsCardBorder)
            .listSectionSeparatorTint(appSettings.settingsCardBorder)
    }

    @ViewBuilder
    private var sectionBody: some View {
        if let header, let footer {
            Section {
                content
            } header: {
                header
            } footer: {
                footer
            }
        } else if let title {
            Section(title) {
                content
            }
        } else {
            Section {
                content
            }
        }
    }
}

private struct NotificationPreferencesToggleRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    @Binding var isOn: Bool
    let footer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: $isOn)

            Text(footer)
                .font(.footnote)
                .foregroundStyle(appSettings.themePalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
