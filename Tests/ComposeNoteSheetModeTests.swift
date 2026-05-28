import XCTest
import SwiftUI
import UIKit
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
    func testComposeTextKeepsSoftLimitOverage() {
        let viewModel = ComposeNoteViewModel()
        let overLimitText = String(repeating: "a", count: 241)

        viewModel.text = overLimitText

        XCTAssertEqual(viewModel.text, overLimitText)
        XCTAssertEqual(viewModel.characterCount, 241)
        XCTAssertEqual(viewModel.remainingCharacterCount, 0)
    }

    @MainActor
    func testComposeTextViewCoordinatorAllowsTypingPastSoftLimit() {
        var textValue = String(repeating: "a", count: 238)
        var isFocusedValue = true
        var selectedRangeValue = NSRange(location: (textValue as NSString).length, length: 0)
        var mentionsValue: [ComposeSelectedMention] = []
        var mentionAnchorYValue: CGFloat = 44
        let coordinator = ComposeMultilineTextView.Coordinator(
            text: Binding(
                get: { textValue },
                set: { textValue = $0 }
            ),
            isFocused: Binding(
                get: { isFocusedValue },
                set: { isFocusedValue = $0 }
            ),
            selectedRange: Binding(
                get: { selectedRangeValue },
                set: { selectedRangeValue = $0 }
            ),
            mentions: Binding(
                get: { mentionsValue },
                set: { mentionsValue = $0 }
            ),
            mentionAnchorY: Binding(
                get: { mentionAnchorYValue },
                set: { mentionAnchorYValue = $0 }
            ),
            onMentionQueryChange: { _ in }
        )
        let textView = UITextView()
        textView.text = textValue
        let insertionRange = NSRange(location: (textValue as NSString).length, length: 0)

        let shouldAllowChange = coordinator.textView(
            textView,
            shouldChangeTextIn: insertionRange,
            replacementText: "bcde"
        )

        XCTAssertTrue(shouldAllowChange)
        XCTAssertEqual(textView.text, textValue)
    }

    func testComposerCharacterCounterShowsSoftLimitOverageAsWarning() throws {
        let source = try Self.sourceText(at: "Sources/Compose/ComposeNoteSheetAccessoryViews.swift")

        XCTAssertTrue(source.contains("private var overLimitCount: Int"))
        XCTAssertTrue(source.contains("return \"+\\(overLimitCount)\""))
        XCTAssertFalse(source.contains("return .red"))
    }

    func testSpeechTranscriberDefersAudioInputUntilVoiceToggle() throws {
        let source = try Self.sourceText(at: "Sources/Compose/ComposeSpeechTranscriber.swift")
        let deinitStart = try XCTUnwrap(source.range(of: "deinit {"))
        let toggleStart = try XCTUnwrap(source.range(of: "func toggleRecording", range: deinitStart.upperBound..<source.endIndex))
        let deinitSource = source[deinitStart.lowerBound..<toggleStart.lowerBound]

        XCTAssertFalse(
            source.contains("private let audioEngine = AVAudioEngine()"),
            "Regular text composers should not eagerly allocate microphone-backed audio input."
        )
        XCTAssertFalse(
            deinitSource.contains("audioEngine.inputNode"),
            "Dismissing a regular text composer must not touch the microphone input node."
        )
        XCTAssertTrue(
            source.contains("private func recordingAudioEngine() -> AVAudioEngine"),
            "Audio input should be created lazily from the explicit voice-recording path."
        )
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
    func testComposeTextViewCoordinatorDoesNotEchoUnchangedInputState() {
        var textValue = ""
        var textSetCount = 0
        var isFocusedValue = true
        var selectedRangeValue = NSRange(location: 0, length: 0)
        var selectedRangeSetCount = 0
        var mentionsValue: [ComposeSelectedMention] = []
        var mentionAnchorYValue: CGFloat = 44
        var mentionAnchorYSetCount = 0
        var mentionQueryChangeCount = 0

        let coordinator = ComposeMultilineTextView.Coordinator(
            text: Binding(
                get: { textValue },
                set: { newValue in
                    textValue = newValue
                    textSetCount += 1
                }
            ),
            isFocused: Binding(
                get: { isFocusedValue },
                set: { isFocusedValue = $0 }
            ),
            selectedRange: Binding(
                get: { selectedRangeValue },
                set: { newValue in
                    selectedRangeValue = newValue
                    selectedRangeSetCount += 1
                }
            ),
            mentions: Binding(
                get: { mentionsValue },
                set: { mentionsValue = $0 }
            ),
            mentionAnchorY: Binding(
                get: { mentionAnchorYValue },
                set: { newValue in
                    mentionAnchorYValue = newValue
                    mentionAnchorYSetCount += 1
                }
            ),
            onMentionQueryChange: { _ in
                mentionQueryChangeCount += 1
            }
        )
        let textView = UITextView()
        textView.text = "hello"
        textView.selectedRange = NSRange(location: 5, length: 0)

        coordinator.textViewDidChange(textView)
        coordinator.textViewDidChange(textView)

        XCTAssertEqual(textSetCount, 1)
        XCTAssertEqual(selectedRangeSetCount, 1)
        XCTAssertEqual(mentionAnchorYSetCount, 0)
        XCTAssertEqual(mentionQueryChangeCount, 0)
    }

    @MainActor
    func testComposeTextViewUsesNativeTextKitAndDefaultInputTraits() {
        let textView = ComposeMultilineTextView.makeComposerTextView()

        if #available(iOS 16.0, *) {
            XCTAssertNotNil(textView.textLayoutManager)
        }
        XCTAssertEqual(textView.keyboardType, .default)
        XCTAssertEqual(textView.autocapitalizationType, .sentences)
        XCTAssertEqual(textView.autocorrectionType, .default)
        XCTAssertEqual(textView.spellCheckingType, .default)
        XCTAssertNil(textView.textContentType)
    }

    @MainActor
    func testComposeTextViewCoordinatorIgnoresStaleSelectionEchoAfterTyping() {
        var textValue = ""
        var isFocusedValue = true
        var selectedRangeValue = NSRange(location: 5, length: 0)
        var mentionsValue: [ComposeSelectedMention] = []
        var mentionAnchorYValue: CGFloat = 44

        let coordinator = ComposeMultilineTextView.Coordinator(
            text: Binding(
                get: { textValue },
                set: { textValue = $0 }
            ),
            isFocused: Binding(
                get: { isFocusedValue },
                set: { isFocusedValue = $0 }
            ),
            selectedRange: Binding(
                get: { selectedRangeValue },
                set: { selectedRangeValue = $0 }
            ),
            mentions: Binding(
                get: { mentionsValue },
                set: { mentionsValue = $0 }
            ),
            mentionAnchorY: Binding(
                get: { mentionAnchorYValue },
                set: { mentionAnchorYValue = $0 }
            ),
            onMentionQueryChange: { _ in }
        )
        let textView = UITextView()
        textView.text = "hello!"
        textView.selectedRange = NSRange(location: 6, length: 0)

        coordinator.textViewDidChange(textView)
        coordinator.applyExternalSelectionIfNeeded(
            to: textView,
            selectedRange: NSRange(location: 5, length: 0)
        )

        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(selectedRangeValue, NSRange(location: 6, length: 0))
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

private extension ComposeNoteSheetModeTests {
    static func sourceText(at relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRootURL = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repositoryRootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
