import XCTest
@testable import Flow

final class LongFormArticleModelsTests: XCTestCase {
    func testMetadataParsesTitleSummaryImageAndTags() throws {
        let event = makeArticleEvent(
            tags: [
                ["d", "flow-article"],
                ["title", "Liquid Glass in Flow"],
                ["summary", "A native-feeling walkthrough of the new reader."],
                ["image", "https://cdn.example.com/hero.jpg"],
                ["published_at", "1710000123"],
                ["t", "SwiftUI"],
                ["t", "Nostr"],
                ["t", "swiftui"]
            ],
            content: "# Heading\n\nHello world"
        )

        let metadata = try XCTUnwrap(NostrLongFormArticleMetadata(event: event))

        XCTAssertEqual(metadata.title, "Liquid Glass in Flow")
        XCTAssertEqual(metadata.summary, "A native-feeling walkthrough of the new reader.")
        XCTAssertEqual(metadata.identifier, "flow-article")
        XCTAssertEqual(metadata.imageURL?.absoluteString, "https://cdn.example.com/hero.jpg")
        XCTAssertEqual(metadata.publishedAt, 1_710_000_123)
        XCTAssertEqual(metadata.tags, ["swiftui", "nostr"])
        XCTAssertEqual(metadata.wordCount, 4)
        XCTAssertEqual(metadata.readingTimeMinutes, 1)
    }

    func testIndexMetadataParsesIdentifierAndPublishedAtFromTagsOnly() throws {
        let event = makeArticleEvent(
            tags: [
                ["d", "flow-article"],
                ["published_at", "1710000123"]
            ],
            content: String(repeating: "word ", count: 20_000)
        )

        let metadata = try XCTUnwrap(event.longFormArticleIndexMetadata)

        XCTAssertEqual(metadata.identifier, "flow-article")
        XCTAssertEqual(metadata.publishedAt, 1_710_000_123)
    }

    func testIndexMetadataFallsBackToCreatedAtWhenPublishedAtTagMissing() throws {
        let createdAt = 1_700_000_000
        let event = makeArticleEvent(
            tags: [["d", "flow-article"]],
            content: "Hello world",
            createdAt: createdAt
        )

        let metadata = try XCTUnwrap(event.longFormArticleIndexMetadata)

        XCTAssertEqual(metadata.identifier, "flow-article")
        XCTAssertEqual(metadata.publishedAt, createdAt)
    }

    func testParserBuildsStructuredBlocks() {
        let markdown = """
        # Title

        Intro paragraph with **bold** text.

        > A quoted line
        > with a second line.

        - One
        - Two

        1. First
        2. Second

        ![Hero](https://cdn.example.com/image.jpg)

        ---

        ```swift
        print("hello")
        ```
        """

        let blocks = LongFormArticleMarkdownParser.parseBlocks(from: markdown)

        XCTAssertEqual(blocks.count, 8)
        XCTAssertEqual(blocks[0], .heading(level: 1, markdown: "Title"))
        XCTAssertEqual(blocks[1], .paragraph(markdown: "Intro paragraph with **bold** text."))
        XCTAssertEqual(
            blocks[2],
            .blockquote(markdown: "A quoted line\nwith a second line.")
        )
        XCTAssertEqual(blocks[3], .unorderedList(items: ["One", "Two"]))
        XCTAssertEqual(blocks[4], .orderedList(start: 1, items: ["First", "Second"]))
        XCTAssertEqual(
            blocks[5],
            .image(url: URL(string: "https://cdn.example.com/image.jpg")!, alt: "Hero")
        )
        XCTAssertEqual(blocks[6], .divider)
        XCTAssertEqual(
            blocks[7],
            .codeBlock(language: "swift", code: "print(\"hello\")")
        )
    }

    func testReaderHeroPrefersCoverImageOverAuthorAvatar() throws {
        let event = makeArticleEvent(
            tags: [
                ["title", "Visual Article"],
                ["image", "https://cdn.example.com/cover.jpg"]
            ],
            content: "Hello world"
        )
        let article = try XCTUnwrap(NostrLongFormArticleMetadata(event: event))
        let avatarURL = URL(string: "https://cdn.example.com/avatar.jpg")!

        let heroURL = LongFormArticleReaderLayout.heroBackgroundURL(
            article: article,
            authorAvatarURL: avatarURL
        )

        XCTAssertEqual(heroURL?.absoluteString, "https://cdn.example.com/cover.jpg")
    }

    func testReaderHeroFallsBackToAuthorAvatarWithoutCoverImage() throws {
        let event = makeArticleEvent(
            tags: [
                ["title", "Avatar-backed Article"]
            ],
            content: "Hello world"
        )
        let article = try XCTUnwrap(NostrLongFormArticleMetadata(event: event))
        let avatarURL = URL(string: "https://cdn.example.com/avatar.jpg")!

        let heroURL = LongFormArticleReaderLayout.heroBackgroundURL(
            article: article,
            authorAvatarURL: avatarURL
        )

        XCTAssertEqual(heroURL, avatarURL)
    }

    func testReaderHeroChromeMatchesRequestedControls() {
        XCTAssertFalse(LongFormArticleReaderLayout.showsArticleTypeBadge)
        XCTAssertFalse(LongFormArticleReaderLayout.showsBookmarkAction)
        XCTAssertTrue(LongFormArticleReaderLayout.showsShareAction)
        XCTAssertTrue(LongFormArticleReaderLayout.usesRuledAuthorSection)
        XCTAssertEqual(LongFormArticleReaderLayout.heroCornerRadius, 0)
        XCTAssertGreaterThan(LongFormArticleReaderLayout.heroHeaderOverlap, 0)
        XCTAssertGreaterThanOrEqual(LongFormArticleReaderLayout.followButtonVerticalPadding, 10)
    }
}

private func makeArticleEvent(
    tags: [[String]],
    content: String,
    createdAt: Int = 1_700_000_000
) -> NostrEvent {
    NostrEvent(
        id: String(repeating: "1", count: 64),
        pubkey: String(repeating: "a", count: 64),
        createdAt: createdAt,
        kind: NostrLongFormArticleKind.article,
        tags: tags,
        content: content,
        sig: String(repeating: "f", count: 128)
    )
}
