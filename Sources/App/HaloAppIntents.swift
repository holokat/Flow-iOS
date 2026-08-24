import AppIntents
import Foundation

@available(iOS 18.0, *)
struct OpenHaloProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Halo Profile"
    static let description = IntentDescription("Open a recently viewed public profile in Halo.")

    @Parameter(title: "Profile")
    var profile: HaloProfileEntity

    init() {}

    init(profile: HaloProfileEntity) {
        self.profile = profile
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(HaloDeepLinkRoute.profile(pubkey: profile.id).url))
    }
}

@available(iOS 18.0, *)
struct OpenHaloNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Halo Note"
    static let description = IntentDescription("Open a recently viewed public note or thread in Halo.")

    @Parameter(title: "Note")
    var note: HaloNoteEntity

    init() {}

    init(note: HaloNoteEntity) {
        self.note = note
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(HaloDeepLinkRoute.note(reference: note.id).url))
    }
}

@available(iOS 18.0, *)
struct OpenHaloFeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Halo Feed"
    static let description = IntentDescription("Open one of your saved feeds in Halo.")

    @Parameter(title: "Feed")
    var feed: HaloFeedEntity

    init() {}

    init(feed: HaloFeedEntity) {
        self.feed = feed
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(HaloDeepLinkRoute.feed(id: feed.id).url))
    }
}

@available(iOS 18.0, *)
struct SearchHaloIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Halo"
    static let description = IntentDescription("Search public profiles and notes in Halo.")

    @Parameter(title: "Search")
    var query: String?

    init() {}

    init(query: String?) {
        self.query = query
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(HaloDeepLinkRoute.search(query: query ?? "").url))
    }
}

@available(iOS 18.0, *)
struct DraftHaloNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft Halo Note"
    static let description = IntentDescription("Open Halo with a new public note draft. Halo will not publish it automatically.")

    @Parameter(title: "Draft")
    var text: String?

    init() {}

    init(text: String?) {
        self.text = text
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(HaloDeepLinkRoute.compose(text: text ?? "").url))
    }
}

@available(iOS 18.0, *)
struct DraftHaloLinkMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft Halo Link Message"
    static let description = IntentDescription("Open an encrypted Halo Link conversation with a message draft. Halo will not send it automatically.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Recipient")
    var recipient: HaloProfileEntity

    @Parameter(title: "Draft")
    var text: String?

    init() {}

    init(recipient: HaloProfileEntity, text: String?) {
        self.recipient = recipient
        self.text = text
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(
            opensIntent: OpenURLIntent(
                HaloDeepLinkRoute.message(pubkey: recipient.id, draft: text ?? "").url
            )
        )
    }
}

@available(iOS 18.0, *)
struct HaloAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenHaloProfileIntent(),
            phrases: ["Open a profile in \(.applicationName)"],
            shortTitle: "Open Profile",
            systemImageName: "person.crop.circle"
        )
        AppShortcut(
            intent: OpenHaloNoteIntent(),
            phrases: ["Open a note in \(.applicationName)"],
            shortTitle: "Open Note",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: OpenHaloFeedIntent(),
            phrases: ["Open a saved feed in \(.applicationName)"],
            shortTitle: "Open Feed",
            systemImageName: "square.stack.3d.up"
        )
        AppShortcut(
            intent: SearchHaloIntent(),
            phrases: ["Search \(.applicationName)"],
            shortTitle: "Search Halo",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: DraftHaloNoteIntent(),
            phrases: ["Draft a note in \(.applicationName)"],
            shortTitle: "Draft Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: DraftHaloLinkMessageIntent(),
            phrases: ["Draft a Halo Link message in \(.applicationName)"],
            shortTitle: "Draft Message",
            systemImageName: "lock.bubble"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .purple
}
