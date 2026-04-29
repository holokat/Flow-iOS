import XCTest
import NostrSDK
import Security
@testable import Flow

final class AuthManagerTests: XCTestCase {
    @MainActor
    func testLoggingInWithSecondPrivateKeyAppendsAccountList() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let privateKeyStore = AuthPrivateKeyStore()
        let store = AuthStore(defaults: defaults, privateKeyStore: privateKeyStore)
        let auth = AuthManager(store: store)

        let firstKeypair = try XCTUnwrap(Keypair())
        let secondKeypair = try XCTUnwrap(Keypair())

        _ = try auth.loginWithNsecOrHex(firstKeypair.privateKey.nsec)
        _ = try auth.loginWithNsecOrHex(secondKeypair.privateKey.nsec)

        XCTAssertEqual(auth.accounts.count, 2)
        XCTAssertEqual(
            Set(auth.accounts.map(\.pubkey)),
            Set([firstKeypair.publicKey.hex, secondKeypair.publicKey.hex])
        )
        XCTAssertEqual(auth.currentAccount?.pubkey, secondKeypair.publicKey.hex)

        for account in auth.accounts {
            auth.removeAccount(account)
        }
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testGeneratedPrivateKeyAccountIsAddedWhenSecureStorageFails() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AuthStore(
            defaults: defaults,
            privateKeyStore: FailingPrivateKeyStore()
        )
        let auth = AuthManager(store: store)
        let keypair = try XCTUnwrap(Keypair())

        let account = try auth.loginWithNsecOrHex(
            keypair.privateKey.nsec,
            backupPrivateKeyToICloud: true
        )

        XCTAssertEqual(auth.accounts.count, 1)
        XCTAssertEqual(auth.currentAccount?.id, account.id)
        XCTAssertEqual(auth.currentNsec, keypair.privateKey.nsec)
        XCTAssertTrue(auth.privateKeyNeedsSecureStorageRepair(for: account))
        XCTAssertNotNil(auth.currentPrivateKeySecurityWarning)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "flow.auth.accounts"))
        let persistedAccounts = try JSONDecoder().decode([StoredAuthAccount].self, from: persistedData)
        XCTAssertEqual(persistedAccounts.count, 1)
        XCTAssertNil(persistedAccounts[0].nsec)

        let relaunchedAuth = AuthManager(
            store: AuthStore(
                defaults: defaults,
                privateKeyStore: FailingPrivateKeyStore()
            )
        )

        XCTAssertEqual(relaunchedAuth.accounts.count, 1)
        XCTAssertEqual(relaunchedAuth.currentAccount?.id, account.id)
        XCTAssertNil(relaunchedAuth.currentNsec)
        XCTAssertNotNil(relaunchedAuth.currentPrivateKeySecurityWarning)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testPrivateKeyBackupPreferenceCanOptOutDuringSignup() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let privateKeyStore = RecordingPrivateKeyStore()
        let store = AuthStore(defaults: defaults, privateKeyStore: privateKeyStore)
        let auth = AuthManager(store: store)
        let keypair = try XCTUnwrap(Keypair())

        let account = try auth.loginWithNsecOrHex(
            keypair.privateKey.nsec,
            backupPrivateKeyToICloud: false
        )

        XCTAssertFalse(account.privateKeyBackupEnabled)
        XCTAssertFalse(auth.currentAccount?.privateKeyBackupEnabled ?? true)
        XCTAssertEqual(auth.currentNsec, keypair.privateKey.nsec)
        XCTAssertEqual(privateKeyStore.backupFlagsByAccountID[account.id], false)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "flow.auth.accounts"))
        let persistedAccounts = try JSONDecoder().decode([StoredAuthAccount].self, from: persistedData)
        XCTAssertEqual(persistedAccounts.count, 1)
        XCTAssertFalse(persistedAccounts[0].privateKeyBackupEnabled)
        XCTAssertNil(persistedAccounts[0].nsec)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testLegacyPlaintextKeyIsScrubbedFromDefaultsWhenSecureMigrationFails() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let keypair = try XCTUnwrap(Keypair())
        let storedAccount = StoredAuthAccount(
            pubkey: keypair.publicKey.hex,
            npub: keypair.publicKey.npub,
            signerType: .nsec,
            nsec: keypair.privateKey.nsec,
            privateKeyBackupEnabled: false
        )

        let data = try JSONEncoder().encode([storedAccount])
        defaults.set(data, forKey: "flow.auth.accounts")
        defaults.set(storedAccount.id, forKey: "flow.auth.currentAccountID")

        let store = AuthStore(
            defaults: defaults,
            privateKeyStore: FailingPrivateKeyStore()
        )
        let auth = AuthManager(store: store)

        XCTAssertEqual(auth.currentNsec, keypair.privateKey.nsec)
        XCTAssertNotNil(auth.currentPrivateKeySecurityWarning)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "flow.auth.accounts"))
        let persistedAccounts = try JSONDecoder().decode([StoredAuthAccount].self, from: persistedData)
        XCTAssertEqual(persistedAccounts.count, 1)
        XCTAssertNil(persistedAccounts[0].nsec)
    }

    @MainActor
    func testSecureStorageWarningPersistsAcrossRestartWhenLegacyMigrationFails() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let keypair = try XCTUnwrap(Keypair())
        let storedAccount = StoredAuthAccount(
            pubkey: keypair.publicKey.hex,
            npub: keypair.publicKey.npub,
            signerType: .nsec,
            nsec: keypair.privateKey.nsec,
            privateKeyBackupEnabled: false
        )

        let data = try JSONEncoder().encode([storedAccount])
        defaults.set(data, forKey: "flow.auth.accounts")
        defaults.set(storedAccount.id, forKey: "flow.auth.currentAccountID")

        let firstStore = AuthStore(
            defaults: defaults,
            privateKeyStore: FailingPrivateKeyStore()
        )
        _ = AuthManager(store: firstStore)

        let secondStore = AuthStore(
            defaults: defaults,
            privateKeyStore: FailingPrivateKeyStore()
        )
        let relaunchedAuth = AuthManager(store: secondStore)

        XCTAssertNil(relaunchedAuth.currentNsec)
        XCTAssertNotNil(relaunchedAuth.currentPrivateKeySecurityWarning)
    }
}

@MainActor
final class MutedThreadStorePersistenceTests: XCTestCase {
    func testMutedThreadsPersistPerAccount() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = MutedThreadStore(defaults: defaults)

        store.configure(accountPubkey: "AccountA")
        XCTAssertTrue(store.mute("ThreadOne"))
        XCTAssertTrue(store.isMuted("threadone"))

        store.configure(accountPubkey: "AccountB")
        XCTAssertFalse(store.isMuted("threadone"))
        XCTAssertTrue(store.mute("ThreadTwo"))
        XCTAssertTrue(store.isMuted("threadtwo"))

        store.configure(accountPubkey: "AccountA")
        XCTAssertTrue(store.isMuted("threadone"))
        XCTAssertFalse(store.isMuted("threadtwo"))

        defaults.removePersistentDomain(forName: suiteName)
    }
}

final class ActivityRowThreadMutePreviewTests: XCTestCase {
    func testReactionToImageOnlyNoteUsesImagePreview() {
        let imageURL = URL(string: "https://cdn.example.com/photo.jpg")!
        let targetEvent = makeActivityEventForTests(
            id: activityHex("1"),
            pubkey: activityHex("a"),
            kind: 1,
            tags: [],
            content: imageURL.absoluteString
        )
        let row = ActivityRow(
            event: makeReactionEventForTests(targetEventID: targetEvent.id),
            actor: ActivityActor(pubkey: activityHex("b"), profile: nil),
            action: .reaction(ActivityReaction(content: "+", shortcode: nil, customEmojiImageURL: nil)),
            target: ActivityTargetNote(
                reference: .eventID(targetEvent.id),
                event: targetEvent,
                profile: nil,
                snippet: targetEvent.activitySnippet()
            )
        )

        XCTAssertEqual(row.previewDisplay, ActivityRowPreviewDisplay.image(imageURL))
    }

    func testReactionToVideoOnlyNoteKeepsMediaFallback() {
        let targetEvent = makeActivityEventForTests(
            id: activityHex("2"),
            pubkey: activityHex("c"),
            kind: 1,
            tags: [],
            content: "https://cdn.example.com/clip.mp4"
        )
        let row = ActivityRow(
            event: makeReactionEventForTests(targetEventID: targetEvent.id),
            actor: ActivityActor(pubkey: activityHex("d"), profile: nil),
            action: .reaction(ActivityReaction(content: "+", shortcode: nil, customEmojiImageURL: nil)),
            target: ActivityTargetNote(
                reference: .eventID(targetEvent.id),
                event: targetEvent,
                profile: nil,
                snippet: targetEvent.activitySnippet()
            )
        )

        XCTAssertEqual(row.previewDisplay, ActivityRowPreviewDisplay.mediaPlaceholder)
    }

    func testReplyPreviewUsesConversationIDForThreadMuting() {
        let rootEventID = activityHex("4")
        let replyEvent = makeActivityEventForTests(
            id: activityHex("5"),
            pubkey: activityHex("6"),
            kind: 1,
            tags: [["e", rootEventID, "", "root"]],
            content: "reply body"
        )
        let row = ActivityRow(
            event: replyEvent,
            actor: ActivityActor(pubkey: activityHex("7"), profile: nil),
            action: .reply(kind: 1),
            target: ActivityTargetNote(
                reference: .eventID(rootEventID),
                event: nil,
                profile: nil,
                snippet: "thread root"
            )
        )

        XCTAssertEqual(row.threadMuteIdentifier, rootEventID)
    }
}

private struct FailingPrivateKeyStore: AuthPrivateKeyStoring {
    func privateKey(for accountID: String) -> String? { nil }
    func privateKeyMetadata(for accountID: String) -> AuthPrivateKeyMetadata? { nil }
    func savePrivateKey(_ nsec: String, for accountID: String, backupToICloud: Bool) throws {
        throw AuthPrivateKeyStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    func iCloudPrivateKeyBackups() -> [AuthICloudPrivateKeyBackup] { [] }
    func removePrivateKey(for accountID: String) {}
}

private final class RecordingPrivateKeyStore: AuthPrivateKeyStoring, @unchecked Sendable {
    private var privateKeysByAccountID: [String: String] = [:]
    private(set) var backupFlagsByAccountID: [String: Bool] = [:]

    func privateKey(for accountID: String) -> String? {
        privateKeysByAccountID[accountID]
    }

    func privateKeyMetadata(for accountID: String) -> AuthPrivateKeyMetadata? {
        guard let isSynchronizable = backupFlagsByAccountID[accountID] else { return nil }
        return AuthPrivateKeyMetadata(
            isSynchronizable: isSynchronizable,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    func savePrivateKey(_ nsec: String, for accountID: String, backupToICloud: Bool) throws {
        privateKeysByAccountID[accountID] = nsec
        backupFlagsByAccountID[accountID] = backupToICloud
    }

    func iCloudPrivateKeyBackups() -> [AuthICloudPrivateKeyBackup] { [] }

    func removePrivateKey(for accountID: String) {
        privateKeysByAccountID.removeValue(forKey: accountID)
        backupFlagsByAccountID.removeValue(forKey: accountID)
    }
}

private func makeReactionEventForTests(targetEventID: String) -> Flow.NostrEvent {
    makeActivityEventForTests(
        id: activityHex("9"),
        pubkey: activityHex("e"),
        kind: 7,
        tags: [
            ["e", targetEventID],
            ["p", activityHex("f")]
        ],
        content: "+"
    )
}

private func makeActivityEventForTests(
    id: String,
    pubkey: String,
    kind: Int,
    tags: [[String]],
    content: String,
    createdAt: Int = 1_700_000_000
) -> Flow.NostrEvent {
    Flow.NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
        sig: String(repeating: "f", count: 128)
    )
}

private func activityHex(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
