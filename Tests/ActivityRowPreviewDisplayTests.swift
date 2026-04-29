import XCTest
@testable import Flow

final class ActivityRowPreviewDisplayTests: XCTestCase {
    func testReactionToImageOnlyNoteUsesImagePreview() {
        let imageURL = URL(string: "https://cdn.example.com/photo.jpg")!
        let targetEvent = makeEvent(
            id: hex("1"),
            pubkey: hex("a"),
            kind: 1,
            tags: [],
            content: imageURL.absoluteString
        )
        let row = ActivityRow(
            event: makeReactionEvent(targetEventID: targetEvent.id),
            actor: ActivityActor(pubkey: hex("b"), profile: nil),
            action: .reaction(ActivityReaction(content: "+", shortcode: nil, customEmojiImageURL: nil)),
            target: ActivityTargetNote(
                reference: .eventID(targetEvent.id),
                event: targetEvent,
                profile: nil,
                snippet: targetEvent.activitySnippet()
            )
        )

        XCTAssertEqual(row.previewDisplay, .image(imageURL))
    }

    func testReactionToVideoOnlyNoteKeepsMediaFallback() {
        let targetEvent = makeEvent(
            id: hex("2"),
            pubkey: hex("c"),
            kind: 1,
            tags: [],
            content: "https://cdn.example.com/clip.mp4"
        )
        let row = ActivityRow(
            event: makeReactionEvent(targetEventID: targetEvent.id),
            actor: ActivityActor(pubkey: hex("d"), profile: nil),
            action: .reaction(ActivityReaction(content: "+", shortcode: nil, customEmojiImageURL: nil)),
            target: ActivityTargetNote(
                reference: .eventID(targetEvent.id),
                event: targetEvent,
                profile: nil,
                snippet: targetEvent.activitySnippet()
            )
        )

        XCTAssertEqual(row.previewDisplay, .mediaPlaceholder)
    }

    func testReplyPreviewUsesConversationIDForThreadMuting() {
        let rootEventID = hex("4")
        let replyEvent = makeEvent(
            id: hex("5"),
            pubkey: hex("6"),
            kind: 1,
            tags: [["e", rootEventID, "", "root"]],
            content: "reply body"
        )
        let row = ActivityRow(
            event: replyEvent,
            actor: ActivityActor(pubkey: hex("7"), profile: nil),
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

private func makeReactionEvent(targetEventID: String) -> NostrEvent {
    makeEvent(
        id: hex("9"),
        pubkey: hex("e"),
        kind: 7,
        tags: [
            ["e", targetEventID],
            ["p", hex("f")]
        ],
        content: "+"
    )
}

private func makeEvent(
    id: String,
    pubkey: String,
    kind: Int,
    tags: [[String]],
    content: String,
    createdAt: Int = 1_700_000_000
) -> NostrEvent {
    NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
        sig: String(repeating: "f", count: 128)
    )
}

private func hex(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
