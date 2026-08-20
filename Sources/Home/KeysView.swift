import SwiftUI
import UIKit

struct KeysView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealedPrivateKey: String?
    @State private var backupErrorMessage: String?
    @State private var privateKeyAccessError: String?
    @State private var isAuthenticatingPrivateKey = false

    var body: some View {
        ThemedSettingsForm {
            publicKeySection
            privateKeySection
            iCloudBackupSection
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: auth.currentAccount?.id) { _, _ in
            revealedPrivateKey = nil
            backupErrorMessage = nil
            privateKeyAccessError = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            revealedPrivateKey = nil
            privateKeyAccessError = nil
        }
    }

    private var settingsSurfaceStyle: SettingsFormSurfaceStyle {
        appSettings.settingsFormSurfaceStyle(for: colorScheme)
    }

    private var publicKeySection: some View {
        ThemedSettingsSection("Account ID") {
            if let account = auth.currentAccount {
                keyValueRow(
                    title: nil,
                    value: account.npub,
                    actionTitle: "Copy Account ID",
                    action: {
                        UIPasteboard.general.string = account.npub
                    }
                )
            } else {
                Text("No signed-in account is available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privateKeySection: some View {
        ThemedSettingsSection("Secret Access Code") {
            if auth.currentNsec != nil {
                privateKeyRevealControl

                if let revealedPrivateKey {
                    keyValueRow(
                        title: "Recovery Key",
                        value: revealedPrivateKey,
                        actionTitle: "Copy Secret Access Code",
                        action: {
                            UIPasteboard.general.string = revealedPrivateKey
                        }
                    )
                } else {
                    maskedPrivateKeyPlaceholder
                }

                if let warning = auth.currentPrivateKeySecurityWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let privateKeyAccessError {
                    Text(privateKeyAccessError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                privateKeyRevealControl
                    .disabled(true)

                if let warning = auth.currentPrivateKeySecurityWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("This account was created for viewing only, so there is no secret access code to reveal or copy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var iCloudBackupSection: some View {
        if let account = auth.currentAccount, account.signerType == .nsec {
            ThemedSettingsSection {
                Toggle("Back Up Access Code to iCloud", isOn: privateKeyBackupBinding(for: account))

                privateKeyBackupStatusCard(for: account)

                if let backupErrorMessage {
                    Text(backupErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("iCloud Backup")
            } footer: {
                if !account.privateKeyBackupEnabled {
                    Text("This access code stays only on this device until you turn on iCloud backup. New Halo-created accounts ask about iCloud backup during setup.")
                }
            }
        }
    }

    private var maskedPrivateKeyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep your secret access code private to yourself. It protects your account and can't be reset if it's exposed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    settingsSurfaceStyle.subcardBackground,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            Text("Turn on reveal only when you need to view or copy it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var privateKeyRevealControl: some View {
        Button {
            if revealedPrivateKey != nil {
                revealedPrivateKey = nil
                privateKeyAccessError = nil
            } else {
                requestPrivateKeyReveal()
            }
        } label: {
            HStack(spacing: 12) {
                if isAuthenticatingPrivateKey {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: revealedPrivateKey != nil ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }

                Text(revealedPrivateKey != nil ? "Hide Secret Access Code" : "Reveal Secret Access Code")
                    .foregroundStyle(.primary)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(isAuthenticatingPrivateKey)
    }

    private func privateKeyBackupStatusCard(for account: AuthAccount) -> some View {
        let metadata = auth.privateKeyMetadata(for: account)
        let status = backupStatusDescription(for: account, metadata: metadata)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.iconName)
                    .foregroundStyle(status.tint)
                Text(status.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(status.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            settingsSurfaceStyle.subcardBackground,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func backupStatusDescription(
        for account: AuthAccount,
        metadata: AuthPrivateKeyMetadata?
    ) -> (title: String, message: String, iconName: String, tint: Color) {
        if account.privateKeyBackupEnabled {
            if metadata?.isSynchronizable == true {
                let savedDate = metadata?.modifiedAt ?? metadata?.createdAt
                if let savedDate {
                    return (
                        title: "Backed up on this device",
                        message: "Last added to iCloud Keychain: \(savedDate.formatted(date: .abbreviated, time: .shortened))",
                        iconName: "checkmark.circle.fill",
                        tint: .green
                    )
                }

                return (
                    title: "Backup enabled",
                    message: "This account is stored in iCloud Keychain on this device.",
                    iconName: "icloud.fill",
                    tint: .green
                )
            }

            return (
                title: "Backup enabled",
                message: "iCloud backup is turned on, but this account has not reported a local iCloud Keychain save yet.",
                iconName: "icloud.slash",
                tint: .orange
            )
        }

        return (
            title: "Device only",
            message: "This account is stored only on this device right now.",
            iconName: "iphone",
            tint: Color.secondary
        )
    }

    private func keyValueRow(
        title: String?,
        value: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    settingsSurfaceStyle.subcardBackground,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            Button {
                action()
            } label: {
                Label(actionTitle, systemImage: "doc.on.doc")
            }
        }
        .padding(.vertical, 2)
    }

    private func privateKeyBackupBinding(for account: AuthAccount) -> Binding<Bool> {
        Binding(
            get: {
                auth.currentAccount?.id == account.id
                    ? (auth.currentAccount?.privateKeyBackupEnabled ?? false)
                    : account.privateKeyBackupEnabled
            },
            set: { newValue in
                do {
                    try auth.setPrivateKeyBackupEnabled(newValue, for: account)
                    backupErrorMessage = nil
                } catch {
                    backupErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        )
    }

    private func requestPrivateKeyReveal() {
        guard !isAuthenticatingPrivateKey else { return }
        guard let privateKeyToReveal = auth.currentNsec else {
            privateKeyAccessError = "This account is no longer available on this device."
            revealedPrivateKey = nil
            return
        }

        Task { @MainActor in
            isAuthenticatingPrivateKey = true
            privateKeyAccessError = nil
            defer { isAuthenticatingPrivateKey = false }

            do {
                try await DeviceOwnerAuthenticationGate.authenticate(
                    reason: "Reveal your account access in Halo."
                )
                revealedPrivateKey = privateKeyToReveal
            } catch {
                revealedPrivateKey = nil
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if message != "Authentication was cancelled." {
                    privateKeyAccessError = message
                }
            }
        }
    }
}
