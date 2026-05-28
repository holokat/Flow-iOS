import Foundation
import NostrSDK

enum AuthManagerError: LocalizedError {
    case invalidNsecOrHex
    case invalidNpub
    case keyGenerationFailed
    case iCloudBackupUnavailable
    case storedPrivateKeyMismatch

    var errorDescription: String? {
        switch self {
        case .invalidNsecOrHex:
            return "Invalid account access."
        case .invalidNpub:
            return "Invalid public account ID."
        case .keyGenerationFailed:
            return "Could not create a new account right now."
        case .iCloudBackupUnavailable:
            return "We couldn’t find that iCloud-backed account on this device yet."
        case .storedPrivateKeyMismatch:
            return "The stored account access didn’t match this account."
        }
    }
}

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var accounts: [AuthAccount] = []
    @Published private(set) var currentAccount: AuthAccount?
    @Published private(set) var accountsNeedingSecureStorageRepair = Set<String>()

    private let store: AuthStore
    private var storedAccounts: [StoredAuthAccount] = []
    private var currentAccountID: String?
    private var transientPrivateKeysByAccountID: [String: String] = [:]

    init(store: AuthStore = .shared) {
        self.store = store
        let loaded = store.load()
        storedAccounts = loaded.accounts
        currentAccountID = loaded.currentAccountID
        transientPrivateKeysByAccountID = loaded.transientPrivateKeysByAccountID
        accountsNeedingSecureStorageRepair = loaded.accountsNeedingSecureStorageRepair
        syncPublishedState()
    }

    var isLoggedIn: Bool {
        currentAccount != nil
    }

    var currentNsec: String? {
        guard let currentAccountID else { return nil }
        return validatedPrivateKey(
            for: currentAccountID,
            expectedPubkey: currentAccount?.pubkey
        )
    }

    var currentPrivateKeyMetadata: AuthPrivateKeyMetadata? {
        guard let currentAccountID else { return nil }
        return store.privateKeyMetadata(for: currentAccountID)
    }

    func privateKeyMetadata(for account: AuthAccount) -> AuthPrivateKeyMetadata? {
        store.privateKeyMetadata(for: account.id)
    }

    func privateKeyNeedsSecureStorageRepair(for account: AuthAccount) -> Bool {
        accountsNeedingSecureStorageRepair.contains(account.id)
    }

    var currentPrivateKeySecurityWarning: String? {
        guard let currentAccount else { return nil }
        guard privateKeyNeedsSecureStorageRepair(for: currentAccount) else { return nil }

        if validatedPrivateKey(for: currentAccount.id, expectedPubkey: currentAccount.pubkey) != nil {
            return "This account is only available for this app session because secure storage failed previously. Sign in again to save it securely."
        }

        return "This account is no longer stored securely on this device. Sign in again to restore posting access."
    }

    func iCloudRestoreCandidates() -> [AuthICloudRestoreCandidate] {
        store.iCloudPrivateKeyBackups().compactMap { backup in
            guard let pubkey = backup.pubkey,
                  let npub = PublicKey(hex: pubkey)?.npub else {
                return nil
            }

            return AuthICloudRestoreCandidate(
                accountID: backup.accountID,
                pubkey: pubkey,
                npub: npub,
                createdAt: backup.createdAt,
                modifiedAt: backup.modifiedAt,
                isAlreadyOnDevice: storedAccounts.contains(where: { $0.id == backup.accountID })
            )
        }
    }

    @discardableResult
    func signUp() throws -> GeneratedNostrAccount {
        guard let keypair = Keypair() else {
            throw AuthManagerError.keyGenerationFailed
        }

        let stored = StoredAuthAccount(
            pubkey: keypair.publicKey.hex,
            npub: keypair.publicKey.npub,
            signerType: .nsec,
            privateKeyBackupEnabled: true
        )
        try upsertAndActivate(
            stored,
            privateKey: keypair.privateKey.nsec,
            backupPrivateKeyToICloud: true
        )

        return GeneratedNostrAccount(
            pubkey: keypair.publicKey.hex,
            npub: keypair.publicKey.npub,
            nsec: keypair.privateKey.nsec
        )
    }

    @discardableResult
    func loginWithNsecOrHex(
        _ credential: String,
        backupPrivateKeyToICloud: Bool? = nil
    ) throws -> AuthAccount {
        let normalized = normalizedPrivateKeyCredential(credential)
        guard !normalized.isEmpty else {
            throw AuthManagerError.invalidNsecOrHex
        }

        let keypair: Keypair?
        if normalized.lowercased().hasPrefix("nsec1") {
            keypair = Keypair(nsec: normalized.lowercased())
        } else if normalized.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil {
            keypair = Keypair(hex: normalized.lowercased())
        } else {
            keypair = nil
        }

        guard let keypair else {
            throw AuthManagerError.invalidNsecOrHex
        }

        let stored = StoredAuthAccount(
            pubkey: keypair.publicKey.hex,
            npub: keypair.publicKey.npub,
            signerType: .nsec,
            privateKeyBackupEnabled: backupPrivateKeyToICloud ?? false
        )
        return try upsertAndActivate(
            stored,
            privateKey: keypair.privateKey.nsec,
            backupPrivateKeyToICloud: backupPrivateKeyToICloud
        )
    }

    private func normalizedPrivateKeyCredential(_ credential: String) -> String {
        var normalized = credential
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }

        if normalized.lowercased().hasPrefix("nostr:") {
            normalized = String(normalized.dropFirst("nostr:".count))
        }

        return normalized
    }

    @discardableResult
    func loginWithNpub(_ npub: String) throws -> AuthAccount {
        let normalized = npub.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let publicKey = PublicKey(npub: normalized) else {
            throw AuthManagerError.invalidNpub
        }

        let stored = StoredAuthAccount(
            pubkey: publicKey.hex,
            npub: publicKey.npub,
            signerType: .npub,
            privateKeyBackupEnabled: false
        )
        return try upsertAndActivate(stored)
    }

    @discardableResult
    func restoreFromICloud(_ candidate: AuthICloudRestoreCandidate) throws -> AuthAccount {
        guard let privateKey = store.privateKey(for: candidate.accountID) else {
            throw AuthManagerError.iCloudBackupUnavailable
        }
        guard Keypair(nsec: privateKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())?.publicKey.hex.lowercased()
                == candidate.pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw AuthManagerError.storedPrivateKeyMismatch
        }

        let stored = StoredAuthAccount(
            pubkey: candidate.pubkey,
            npub: candidate.npub,
            signerType: .nsec,
            privateKeyBackupEnabled: true
        )
        return try upsertAndActivate(
            stored,
            backupPrivateKeyToICloud: true
        )
    }

    func switchAccount(to account: AuthAccount?) {
        guard let account else {
            currentAccountID = nil
            persistAndPublish()
            return
        }
        guard storedAccounts.contains(where: { $0.id == account.id }) else { return }

        currentAccountID = account.id
        persistAndPublish()
    }

    func logout() {
        currentAccountID = nil
        persistAndPublish()
    }

    func removeAccount(_ account: AuthAccount) {
        storedAccounts.removeAll { $0.id == account.id }
        transientPrivateKeysByAccountID.removeValue(forKey: account.id)
        accountsNeedingSecureStorageRepair.remove(account.id)
        store.removePrivateKey(for: account.id)

        if currentAccountID == account.id {
            currentAccountID = storedAccounts.first?.id
        }
        persistAndPublish()
    }

    func setPrivateKeyBackupEnabled(_ enabled: Bool, for account: AuthAccount) throws {
        guard account.signerType == .nsec else { return }
        guard let index = storedAccounts.firstIndex(where: { $0.id == account.id }) else { return }

        let privateKey = validatedPrivateKey(for: account.id, expectedPubkey: account.pubkey)
        guard let privateKey else {
            throw AuthPrivateKeyStoreError.missingPrivateKey
        }

        try store.savePrivateKey(privateKey, for: account.id, backupToICloud: enabled)
        transientPrivateKeysByAccountID.removeValue(forKey: account.id)
        accountsNeedingSecureStorageRepair.remove(account.id)
        store.setPrivateKeyNeedsSecureStorageRepair(false, for: account.id)
        storedAccounts[index] = StoredAuthAccount(
            pubkey: storedAccounts[index].pubkey,
            npub: storedAccounts[index].npub,
            signerType: storedAccounts[index].signerType,
            nsec: nil,
            privateKeyBackupEnabled: enabled
        )
        persistAndPublish()
    }

    @discardableResult
    private func upsertAndActivate(
        _ account: StoredAuthAccount,
        privateKey: String? = nil,
        backupPrivateKeyToICloud: Bool? = nil
    ) throws -> AuthAccount {
        let existingIndex = storedAccounts.firstIndex(where: { $0.id == account.id })
        let resolvedBackupSetting: Bool
        if account.signerType == .nsec {
            if let backupPrivateKeyToICloud {
                resolvedBackupSetting = backupPrivateKeyToICloud
            } else if let existingIndex {
                resolvedBackupSetting = storedAccounts[existingIndex].privateKeyBackupEnabled
            } else {
                resolvedBackupSetting = false
            }
        } else {
            resolvedBackupSetting = false
        }

        if account.signerType == .nsec, let privateKey {
            do {
                try store.savePrivateKey(
                    privateKey,
                    for: account.id,
                    backupToICloud: resolvedBackupSetting
                )
                transientPrivateKeysByAccountID.removeValue(forKey: account.id)
                accountsNeedingSecureStorageRepair.remove(account.id)
                store.setPrivateKeyNeedsSecureStorageRepair(false, for: account.id)
            } catch {
                transientPrivateKeysByAccountID[account.id] = privateKey
                accountsNeedingSecureStorageRepair.insert(account.id)
                store.setPrivateKeyNeedsSecureStorageRepair(true, for: account.id)
            }
        }

        let persistedAccount = StoredAuthAccount(
            pubkey: account.pubkey,
            npub: account.npub,
            signerType: account.signerType,
            privateKeyBackupEnabled: resolvedBackupSetting
        )

        if let existingIndex {
            storedAccounts[existingIndex] = persistedAccount
        } else {
            storedAccounts.append(persistedAccount)
        }

        currentAccountID = persistedAccount.id
        persistAndPublish()
        return AuthAccount(
            pubkey: persistedAccount.pubkey,
            npub: persistedAccount.npub,
            signerType: persistedAccount.signerType,
            privateKeyBackupEnabled: persistedAccount.privateKeyBackupEnabled
        )
    }

    private func persistAndPublish() {
        store.save(
            accounts: storedAccounts,
            currentAccountID: currentAccountID,
            accountsNeedingSecureStorageRepair: accountsNeedingSecureStorageRepair
        )
        syncPublishedState()
    }

    private func validatedPrivateKey(for accountID: String, expectedPubkey: String?) -> String? {
        let privateKey = store.privateKey(for: accountID) ?? transientPrivateKeysByAccountID[accountID]
        guard let privateKey else { return nil }

        guard let keypair = Keypair(nsec: privateKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return nil
        }

        guard let expectedPubkey else {
            return privateKey
        }

        let normalizedExpected = expectedPubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard keypair.publicKey.hex.lowercased() == normalizedExpected else {
            return nil
        }

        return privateKey
    }

    private func syncPublishedState() {
        accounts = storedAccounts.map {
            AuthAccount(
                pubkey: $0.pubkey,
                npub: $0.npub,
                signerType: $0.signerType,
                privateKeyBackupEnabled: $0.privateKeyBackupEnabled
            )
        }
        currentAccount = accounts.first(where: { $0.id == currentAccountID })
    }
}
