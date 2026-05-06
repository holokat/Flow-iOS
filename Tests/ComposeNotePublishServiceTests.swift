import XCTest
import NostrSDK
@testable import Flow

final class ComposeNotePublishServiceTests: XCTestCase {
    func testMergedProfileMetadataRemovesBlankAvatarAndBannerFields() throws {
        let content = try ProfileMetadataEditing.mergedContent(
            fields: EditableProfileFields(
                avatarURLString: " ",
                bannerURLString: "\n",
                displayName: "Halo User"
            ),
            baseJSON: [
                "picture": "https://cdn.example.com/avatar.png",
                "banner": "https://cdn.example.com/banner.png",
                "display_name": "Old Name"
            ]
        )

        let data = try XCTUnwrap(content.data(using: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(json["picture"])
        XCTAssertNil(json["banner"])
        XCTAssertEqual(json["display_name"] as? String, "Halo User")
        XCTAssertEqual(json["displayName"] as? String, "Halo User")
    }

    @MainActor
    func testSaveProfileStoresPublishedMetadataEventLocally() async throws {
        let keypair = try XCTUnwrap(Keypair())
        let pubkey = keypair.publicKey.hex.lowercased()
        let relayClient = RecordingRelayPublisher()
        let viewModel = ProfileViewModel(
            pubkey: pubkey,
            relayURL: URL(string: "wss://relay.example.com")!,
            writeRelayURLs: [URL(string: "wss://relay.example.com")!],
            relayClient: relayClient
        )

        let didSave = await viewModel.saveProfile(
            fields: EditableProfileFields(
                displayName: "Halo User",
                about: "Testing metadata persistence"
            ),
            currentAccountPubkey: pubkey,
            currentNsec: keypair.privateKey.nsec
        )

        XCTAssertTrue(didSave)

        let coldCache = ProfileCache(snapshotStore: .shared)
        let storedProfile = await coldCache.cachedProfile(pubkey: pubkey)

        XCTAssertEqual(storedProfile?.displayName, "Halo User")
    }

    func testPublishNoteAddsClientTag() async throws {
        let relayClient = RecordingRelayPublisher()
        let service = ComposeNotePublishService(relayClient: relayClient)
        let nsec = try makeTestNsec()

        let publishedCount = try await service.publishNote(
            content: "Hello Flow",
            currentNsec: nsec,
            writeRelayURLs: [URL(string: "wss://relay-one.example.com")!]
        )

        XCTAssertEqual(publishedCount, 1)

        let capture = await relayClient.capture()
        let eventData = try XCTUnwrap(capture.eventData)
        let event = try JSONDecoder().decode(Flow.NostrEvent.self, from: eventData)

        XCTAssertEqual(firstTag(named: "client", in: event), ["client", "Halo"])
        XCTAssertEqual(event.clientName, "Halo")
    }

    func testPublishPollEncodesOptionsPollTypeAndRelayTags() async throws {
        let relayClient = RecordingRelayPublisher()
        let service = ComposeNotePublishService(relayClient: relayClient)
        let nsec = try makeTestNsec()
        let relayURLs = [
            URL(string: "wss://relay-one.example.com")!,
            URL(string: "wss://relay-two.example.com")!,
            URL(string: "wss://relay-one.example.com")!,
            URL(string: "wss://relay-three.example.com")!,
            URL(string: "wss://relay-four.example.com")!,
            URL(string: "wss://relay-five.example.com")!
        ]
        let endsAt = Date(timeIntervalSince1970: 1_710_000_123)
        let poll = ComposePollDraft(
            allowsMultipleChoice: true,
            options: [
                ComposePollOption(id: "tea", text: " Tea "),
                ComposePollOption(id: "coffee", text: "Coffee"),
                ComposePollOption(id: "blank", text: " ")
            ],
            endsAt: endsAt
        )

        let publishedCount = try await service.publishPoll(
            content: " Favorite drink? ",
            poll: poll,
            currentNsec: nsec,
            writeRelayURLs: relayURLs
        )

        XCTAssertEqual(publishedCount, 1)

        let capture = await relayClient.capture()
        let eventData = try XCTUnwrap(capture.eventData)
        let eventID = try XCTUnwrap(capture.eventID)
        let event = try JSONDecoder().decode(Flow.NostrEvent.self, from: eventData)

        XCTAssertEqual(eventID, event.id)
        XCTAssertEqual(event.kind, NostrPollKind.poll)
        XCTAssertEqual(event.content, "Favorite drink?")
        XCTAssertFalse(capture.relayURLs.isEmpty)
        XCTAssertTrue(capture.relayURLs.count <= 5)
        XCTAssertTrue(
            Set(capture.relayURLs.map { $0.absoluteString.lowercased() }).isSubset(of: Set([
                "wss://relay-one.example.com",
                "wss://relay-two.example.com",
                "wss://relay-three.example.com",
                "wss://relay-four.example.com",
                "wss://relay-five.example.com"
            ]))
        )
        XCTAssertEqual(tags(named: "option", in: event), [
            ["option", "tea", "Tea"],
            ["option", "coffee", "Coffee"]
        ])
        XCTAssertEqual(firstTag(named: "polltype", in: event)?[1], NostrPollType.multipleChoice.rawValue)
        XCTAssertEqual(
            firstTag(named: "endsAt", in: event)?[1],
            String(Int(ComposePollDraft.roundToMinute(endsAt).timeIntervalSince1970))
        )
        XCTAssertEqual(tags(named: "relay", in: event).compactMap { $0.count > 1 ? $0[1] : nil }, [
            "wss://relay-one.example.com",
            "wss://relay-two.example.com",
            "wss://relay-three.example.com",
            "wss://relay-four.example.com"
        ])
        XCTAssertEqual(firstTag(named: "client", in: event), ["client", "Halo"])
    }

    func testPublishPollRejectsDraftWithoutTwoOptions() async throws {
        let relayClient = RecordingRelayPublisher()
        let service = ComposeNotePublishService(relayClient: relayClient)
        let nsec = try makeTestNsec()
        let poll = ComposePollDraft(
            options: [ComposePollOption(id: "tea", text: "Tea")]
        )

        do {
            _ = try await service.publishPoll(
                content: "Favorite drink?",
                poll: poll,
                currentNsec: nsec,
                writeRelayURLs: [URL(string: "wss://relay-one.example.com")!]
            )
            XCTFail("Expected publishPoll to reject invalid poll drafts.")
        } catch let error as ComposeNotePublishError {
            guard case .invalidPoll = error else {
                return XCTFail("Expected invalidPoll error, got \(error).")
            }
        }

        let capture = await relayClient.capture()
        XCTAssertTrue(capture.relayURLs.isEmpty)
        XCTAssertNil(capture.eventData)
        XCTAssertNil(capture.eventID)
    }

    func testQuoteDraftAddsNIP10QuoteTagWithRelayAndAuthorHints() throws {
        let service = ResharePublishService()
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))
        let quotedEvent = Flow.NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "quoted note",
            sig: String(repeating: "f", count: 128)
        )

        let draft = service.buildQuoteDraft(
            for: quotedEvent,
            relayHintURL: relayURL
        )

        XCTAssertEqual(
            draft.additionalTags.first { $0.first == "q" },
            ["q", quotedEvent.id, relayURL.absoluteString, quotedEvent.pubkey]
        )
    }
}

private actor RecordingRelayPublisher: NostrRelayEventPublishing {
    private var relayURLs: [URL] = []
    private var eventData: Data?
    private var eventID: String?

    func publishEvent(
        relayURL: URL,
        eventData: Data,
        eventID: String,
        timeout: TimeInterval
    ) async throws {
        relayURLs.append(relayURL)
        self.eventData = eventData
        self.eventID = eventID
    }

    func capture() -> RelayPublishCapture {
        RelayPublishCapture(
            relayURLs: relayURLs,
            eventData: eventData,
            eventID: eventID
        )
    }
}

private struct RelayPublishCapture: Sendable {
    let relayURLs: [URL]
    let eventData: Data?
    let eventID: String?
}

private func makeTestNsec() throws -> String {
    guard let keypair = Keypair() else {
        throw TestFailure.failedToCreateKeypair
    }
    return keypair.privateKey.nsec
}

private func tags(named name: String, in event: Flow.NostrEvent) -> [[String]] {
    event.tags.filter { tag in
        tag.first?.lowercased() == name.lowercased()
    }
}

private func firstTag(named name: String, in event: Flow.NostrEvent) -> [String]? {
    tags(named: name, in: event).first
}

private enum TestFailure: Error {
    case failedToCreateKeypair
}
