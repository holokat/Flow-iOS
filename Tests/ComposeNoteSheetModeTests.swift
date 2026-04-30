import XCTest
@testable import Flow

final class ComposeNoteSheetModeTests: XCTestCase {
    func testNewNoteModeUsesSharedComposerCopy() {
        let mode = ComposeNoteSheetMode(hasReplyTarget: false, hasQuotedEvent: false)

        XCTAssertEqual(mode, .newNote)
        XCTAssertEqual(mode.navigationTitle, "Compose")
        XCTAssertEqual(mode.publishButtonTitle, "Post")
        XCTAssertEqual(mode.placeholderText, "What do you want to share?")
        XCTAssertEqual(mode.accessibilityActionLabel, "Posting")
    }

    func testReplyModeUsesReplySpecificCopy() {
        let mode = ComposeNoteSheetMode(hasReplyTarget: true, hasQuotedEvent: false)

        XCTAssertEqual(mode, .reply)
        XCTAssertEqual(mode.navigationTitle, "Reply")
        XCTAssertEqual(mode.publishButtonTitle, "Reply")
        XCTAssertEqual(mode.placeholderText, "Post your reply")
        XCTAssertEqual(mode.accessibilityActionLabel, "Replying")
    }

    func testQuoteModeKeepsSharedComposerChrome() {
        let mode = ComposeNoteSheetMode(hasReplyTarget: false, hasQuotedEvent: true)

        XCTAssertEqual(mode, .quote)
        XCTAssertEqual(mode.navigationTitle, "Quote")
        XCTAssertEqual(mode.publishButtonTitle, "Post")
        XCTAssertEqual(mode.placeholderText, "Add your thoughts")
        XCTAssertEqual(mode.accessibilityActionLabel, "Quoting")
    }

    func testQuotedEventTakesPriorityWhenBothContextsArePresent() {
        let mode = ComposeNoteSheetMode(hasReplyTarget: true, hasQuotedEvent: true)

        XCTAssertEqual(mode, .quote)
    }

    @MainActor
    func testComposeTextIsLimitedToTwoHundredFortyCharacters() {
        let viewModel = ComposeNoteViewModel()
        let overLimitText = String(repeating: "a", count: 241)

        viewModel.text = overLimitText

        XCTAssertEqual(viewModel.text.count, 240)
        XCTAssertEqual(viewModel.characterCount, 240)
    }

    func testComposeTextLimitTruncatesInsertedTextToAvailableSpace() {
        let currentText = String(repeating: "a", count: 238)
        let insertionRange = NSRange(location: (currentText as NSString).length, length: 0)

        let replacement = ComposeNoteTextLimit.allowedReplacement(
            in: currentText,
            range: insertionRange,
            replacementText: "bcde"
        )

        XCTAssertEqual(replacement, "bc")
    }

    func testActiveMentionQuerySupportsFreeformLocalSearchWithSpaces() {
        let text = "gm @fiat jaf"
        let selection = NSRange(location: (text as NSString).length, length: 0)

        let query = ComposeMentionSupport.activeQuery(
            in: text,
            selection: selection,
            confirmedMentions: []
        )

        XCTAssertEqual(query?.query, "fiat jaf")
    }

    func testActiveMentionQuerySupportsNip05StyleSearchText() {
        let text = "@jb55@damus.io"
        let selection = NSRange(location: (text as NSString).length, length: 0)

        let query = ComposeMentionSupport.activeQuery(
            in: text,
            selection: selection,
            confirmedMentions: []
        )

        XCTAssertEqual(query?.query, "jb55@damus.io")
    }

    func testActiveMentionQueryIgnoresEmailAddresses() {
        let text = "reach me at fiat@jaf.com"
        let selection = NSRange(location: (text as NSString).length, length: 0)

        let query = ComposeMentionSupport.activeQuery(
            in: text,
            selection: selection,
            confirmedMentions: []
        )

        XCTAssertNil(query)
    }

    func testActiveMentionQueryDoesNotReopenConfirmedMentionAfterInsertion() {
        let text = "@fiatjaf "
        let selection = NSRange(location: (text as NSString).length, length: 0)
        let confirmedMention = ComposeSelectedMention(
            pubkey: String(format: "%064x", 1),
            handle: "fiatjaf",
            range: NSRange(location: 0, length: 8)
        )

        let query = ComposeMentionSupport.activeQuery(
            in: text,
            selection: selection,
            confirmedMentions: [confirmedMention]
        )

        XCTAssertNil(query)
    }

    func testActiveMentionQueryStopsAfterTrailingProseExtendsPastSearchBounds() {
        let text = "gm @michael saylor thanks for the note"
        let selection = NSRange(location: (text as NSString).length, length: 0)

        let query = ComposeMentionSupport.activeQuery(
            in: text,
            selection: selection,
            confirmedMentions: []
        )

        XCTAssertNil(query)
    }

    @MainActor
    func testDraftStoreDoesNotPersistEmptyReplyDraftButKeepsQuoteContext() {
        let defaults = makeDraftStoreDefaults()
        let store = AppComposeDraftStore(defaults: defaults)

        let replyDraft = store.saveDraft(
            snapshot: SavedComposeDraftSnapshot(
                text: "",
                additionalTags: [],
                uploadedAttachments: [],
                selectedMentions: [],
                pollDraft: nil,
                replyTargetEvent: makeDraftEvent(idSuffix: "reply"),
                replyTargetDisplayNameHint: nil,
                replyTargetHandleHint: nil,
                replyTargetAvatarURLHint: nil,
                quotedEvent: nil,
                quotedDisplayNameHint: nil,
                quotedHandleHint: nil,
                quotedAvatarURLHint: nil
            ),
            ownerPubkey: "abc123"
        )
        let quoteDraft = store.saveDraft(
            snapshot: SavedComposeDraftSnapshot(
                text: "",
                additionalTags: [["q", "quote"]],
                uploadedAttachments: [],
                selectedMentions: [],
                pollDraft: nil,
                replyTargetEvent: nil,
                replyTargetDisplayNameHint: nil,
                replyTargetHandleHint: nil,
                replyTargetAvatarURLHint: nil,
                quotedEvent: makeDraftEvent(idSuffix: "quote"),
                quotedDisplayNameHint: "Quote Target",
                quotedHandleHint: "@quote",
                quotedAvatarURLHint: nil
            ),
            ownerPubkey: "abc123"
        )

        XCTAssertNil(replyDraft)
        XCTAssertNotNil(quoteDraft)
        XCTAssertEqual(store.draftCount(for: "abc123"), 1)
    }

    @MainActor
    func testDraftStoreUpdatesExistingDraftAndFiltersPerOwner() {
        let defaults = makeDraftStoreDefaults()
        let store = AppComposeDraftStore(defaults: defaults)

        let originalDraft = store.saveDraft(
            snapshot: SavedComposeDraftSnapshot(
                text: "first",
                additionalTags: [],
                uploadedAttachments: [],
                selectedMentions: [],
                pollDraft: nil,
                replyTargetEvent: nil,
                replyTargetDisplayNameHint: nil,
                replyTargetHandleHint: nil,
                replyTargetAvatarURLHint: nil,
                quotedEvent: nil,
                quotedDisplayNameHint: nil,
                quotedHandleHint: nil,
                quotedAvatarURLHint: nil
            ),
            ownerPubkey: "ABC123"
        )
        let updatedDraft = store.saveDraft(
            snapshot: SavedComposeDraftSnapshot(
                text: "second",
                additionalTags: [],
                uploadedAttachments: [],
                selectedMentions: [],
                pollDraft: nil,
                replyTargetEvent: nil,
                replyTargetDisplayNameHint: nil,
                replyTargetHandleHint: nil,
                replyTargetAvatarURLHint: nil,
                quotedEvent: nil,
                quotedDisplayNameHint: nil,
                quotedHandleHint: nil,
                quotedAvatarURLHint: nil
            ),
            ownerPubkey: "abc123",
            existingDraftID: originalDraft?.id
        )
        _ = store.saveDraft(
            snapshot: SavedComposeDraftSnapshot(
                text: "other-account",
                additionalTags: [],
                uploadedAttachments: [],
                selectedMentions: [],
                pollDraft: nil,
                replyTargetEvent: nil,
                replyTargetDisplayNameHint: nil,
                replyTargetHandleHint: nil,
                replyTargetAvatarURLHint: nil,
                quotedEvent: nil,
                quotedDisplayNameHint: nil,
                quotedHandleHint: nil,
                quotedAvatarURLHint: nil
            ),
            ownerPubkey: "def456"
        )

        XCTAssertEqual(originalDraft?.id, updatedDraft?.id)
        XCTAssertEqual(store.drafts(for: "abc123").count, 1)
        XCTAssertEqual(store.drafts(for: "abc123").first?.snapshot.text, "second")
        XCTAssertEqual(store.drafts(for: "def456").count, 1)
    }
}

private func makeDraftStoreDefaults() -> UserDefaults {
    let suiteName = "ComposeDraftStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func makeDraftEvent(idSuffix: String) -> NostrEvent {
    NostrEvent(
        id: String(repeating: idSuffix == "quote" ? "b" : "a", count: 64),
        pubkey: String(repeating: "c", count: 64),
        createdAt: 1_700_000_000,
        kind: 1,
        tags: [],
        content: "Draft target",
        sig: String(repeating: "d", count: 128)
    )
}
