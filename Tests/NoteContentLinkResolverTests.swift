import XCTest
import NostrSDK
import UIKit
@testable import Flow

final class NoteContentLinkResolverTests: XCTestCase {
    func testReferencedNoteEmbeddingAutomaticallyResolvesTheReportedNestedChain() {
        let rootEvent = NostrEvent(
            id: "3928242e745b89e7a65a1327bafc98ada2e21077a3bd55a0157ddb1417da7680",
            pubkey: "8fb140b4e8ddef97ce4b821d247278a1a4353362623f64021484b372f948000c",
            createdAt: 1_787_275_452,
            kind: 1,
            tags: [],
            content: "",
            sig: String(repeating: "f", count: 128)
        )
        let firstReference = "nevent1qqsru33n2mukexssvl5sv9n46p055stvxm2gw05j2zuxga8n4cp9jyc62vryt"
        let firstReferencedEvent = NostrEvent(
            id: "3e463356f96c9a1067e9061675d05f4a416c36d4873e9250b86474f3ae025913",
            pubkey: rootEvent.pubkey,
            createdAt: 1_786_495_218,
            kind: 1,
            tags: [],
            content: "",
            sig: String(repeating: "e", count: 128)
        )
        let reportedNestedReference = "nevent1qqsq5fnyagj2r4k5skzednp83feswmk5dp8allu2vm698dl4r2vnc2g7dflzx"

        let rootContext = NostrReferenceEmbeddingContext(rootEvent: rootEvent)
        XCTAssertEqual(rootContext.decision(for: firstReference), .automatic)

        let firstReferenceContext = rootContext.descending(
            into: firstReferencedEvent,
            referencedBy: firstReference
        )
        XCTAssertEqual(firstReferenceContext.depth, 1)
        XCTAssertEqual(
            firstReferenceContext.decision(for: reportedNestedReference),
            .automatic
        )
    }

    func testReferencedNoteEmbeddingDefersDeeperAcyclicChainsForInlineExpansion() {
        let rootEvent = makeReferenceEmbeddingEvent(idCharacter: "1")
        let firstEvent = makeReferenceEmbeddingEvent(idCharacter: "2")
        let secondEvent = makeReferenceEmbeddingEvent(idCharacter: "3")
        let firstReference = String(repeating: "2", count: 64)
        let secondReference = String(repeating: "3", count: 64)
        let deeperReference = String(repeating: "4", count: 64)

        let rootContext = NostrReferenceEmbeddingContext(rootEvent: rootEvent)
        let firstContext = rootContext.descending(
            into: firstEvent,
            referencedBy: firstReference
        )
        let secondContext = firstContext.descending(
            into: secondEvent,
            referencedBy: secondReference
        )

        XCTAssertEqual(secondContext.depth, NostrReferenceEmbeddingContext.maximumAutomaticDepth)
        XCTAssertEqual(secondContext.decision(for: deeperReference), .deferred)
    }

    func testReferencedNoteEmbeddingDefersExcessSiblingReferences() {
        let context = NostrReferenceEmbeddingContext(
            rootEvent: makeReferenceEmbeddingEvent(idCharacter: "1")
        )
        let reference = String(repeating: "2", count: 64)

        XCTAssertEqual(
            context.decision(
                for: reference,
                referenceOrdinal: NostrReferenceEmbeddingContext.maximumAutomaticReferencesPerEvent - 1
            ),
            .automatic
        )
        XCTAssertEqual(
            context.decision(
                for: reference,
                referenceOrdinal: NostrReferenceEmbeddingContext.maximumAutomaticReferencesPerEvent
            ),
            .deferred
        )
    }

    func testReferencedNoteEmbeddingStopsCyclesByCanonicalEventIdentity() {
        let rootEvent = makeReferenceEmbeddingEvent(idCharacter: "a")
        let childEvent = makeReferenceEmbeddingEvent(idCharacter: "b")
        let childReference = String(repeating: "b", count: 64)
        let rootReference = String(repeating: "a", count: 64)

        let childContext = NostrReferenceEmbeddingContext(rootEvent: rootEvent).descending(
            into: childEvent,
            referencedBy: childReference
        )

        XCTAssertEqual(childContext.decision(for: rootReference), .cycle)
    }

    func testReferencedNoteEmbeddingStopsAddressableEventCycles() {
        let pubkey = String(repeating: "c", count: 64)
        let rootEvent = NostrEvent(
            id: String(repeating: "d", count: 64),
            pubkey: pubkey,
            createdAt: 1_700_000_000,
            kind: 30_023,
            tags: [["d", "article-slug"]],
            content: "",
            sig: String(repeating: "f", count: 128)
        )
        let rootAddress = "30023:\(pubkey):article-slug"

        XCTAssertEqual(
            NostrReferenceEmbeddingContext(rootEvent: rootEvent).decision(for: rootAddress),
            .cycle
        )
    }

    func testReferencedNoteRetryBypassesCachedMiss() async {
        let cache = EmbeddedReferencedNoteCache()
        let key = "missing-reference"
        await cache.storeResolvedValue(nil, for: key)

        let cachedMiss = await cache.cachedValue(for: key)
        XCTAssertTrue(cachedMiss.found)
        XCTAssertNil(cachedMiss.item)

        let retryLookup = await cache.cachedValue(for: key, retryCachedMiss: true)
        XCTAssertFalse(retryLookup.found)
        XCTAssertNil(retryLookup.item)
    }

    func testWebsitePreviewParserReadsOpenGraphMetadataRegardlessOfAttributeOrder() throws {
        let pageURL = URL(
            string: "https://reclaimthenet.org/meta-trial-opens-as-states-demand-age-verification"
        )!
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta content="Meta Trial Opens as States Demand Age Verification" property="og:title">
          <meta property='og:description' content='A trial doesn&#x27;t need a verdict to be useful.'>
          <meta content="Reclaim The Net: Free Speech, Privacy, Digital Rights" property="og:site_name">
          <meta property="og:url" content="https://reclaimthenet.org/meta-trial-opens-as-states-demand-age-verification/">
          <meta content="https://media.reclaimthenet.org/images/2026/08/F25we0EGVSwN.jpg" property="og:image">
        </head>
        </html>
        """

        let metadata = try XCTUnwrap(
            WebsitePreviewHTMLParser.parse(html: html, responseURL: pageURL)
        )

        XCTAssertEqual(metadata.title, "Meta Trial Opens as States Demand Age Verification")
        XCTAssertEqual(metadata.summary, "A trial doesn't need a verdict to be useful.")
        XCTAssertEqual(
            metadata.siteName,
            "Reclaim The Net: Free Speech, Privacy, Digital Rights"
        )
        XCTAssertEqual(
            metadata.imageURL?.absoluteString,
            "https://media.reclaimthenet.org/images/2026/08/F25we0EGVSwN.jpg"
        )
        XCTAssertEqual(
            metadata.resolvedURL?.absoluteString,
            "https://reclaimthenet.org/meta-trial-opens-as-states-demand-age-verification/"
        )
    }

    func testWebsitePreviewParserFallsBackToHTMLTitleAndRelativeSiteIcon() throws {
        let pageURL = URL(string: "https://otherstuff.ai/word5/")!
        let html = """
        <!doctype html>
        <html>
        <head>
          <link rel="icon" type="image/png" sizes="512x512" href="assets/icon-word5.png">
          <link rel="apple-touch-icon" href="assets/icon-word5.png">
          <title>  WORD5  </title>
        </head>
        </html>
        """

        let metadata = try XCTUnwrap(
            WebsitePreviewHTMLParser.parse(html: html, responseURL: pageURL)
        )

        XCTAssertEqual(metadata.title, "WORD5")
        XCTAssertNil(metadata.imageURL)
        XCTAssertEqual(
            metadata.iconURL?.absoluteString,
            "https://otherstuff.ai/word5/assets/icon-word5.png"
        )
    }

    func testWebsitePreviewParserUsesTwitterFallbackAndDecodesNumericEntities() throws {
        let pageURL = URL(string: "https://example.com/article")!
        let html = """
        <html><head>
          <meta name="twitter:title" content="Rock &#x26; Roll &#8217;26">
          <meta name="twitter:image" content="/social-card.jpg">
          <link rel="canonical" href="/canonical-article">
        </head></html>
        """

        let metadata = try XCTUnwrap(
            WebsitePreviewHTMLParser.parse(html: html, responseURL: pageURL)
        )

        XCTAssertEqual(metadata.title, "Rock & Roll ’26")
        XCTAssertEqual(metadata.imageURL?.absoluteString, "https://example.com/social-card.jpg")
        XCTAssertEqual(metadata.resolvedURL?.absoluteString, "https://example.com/canonical-article")
    }

    func testWebsitePreviewParserRejectsPrivateNetworkPreviewAssets() throws {
        let pageURL = URL(string: "https://example.com/article")!
        let html = """
        <html><head>
          <meta property="og:title" content="Public article">
          <meta property="og:image" content="http://127.0.0.1/private-image.jpg">
          <link rel="icon" href="http://localhost/private-icon.png">
        </head></html>
        """

        let metadata = try XCTUnwrap(
            WebsitePreviewHTMLParser.parse(html: html, responseURL: pageURL)
        )

        XCTAssertEqual(metadata.title, "Public article")
        XCTAssertNil(metadata.imageURL)
        XCTAssertNil(metadata.iconURL)
    }

    func testReportedNIP89HandlerParsesAsApplicationMetadata() throws {
        let event = NostrEvent(
            id: "e14c76b35415e66e78bcb46eecbe54385b5b9ecef74f6da000625f3c1cbe27e8",
            pubkey: "d133ecb09963a7f7a705bf250324a226fcacbf51eba6f0b1b97df8c09338a4c8",
            createdAt: 1_783_261_857,
            kind: 31_990,
            tags: [
                ["d", "5ijupcvs"],
                ["alt", "NIP-89 handler: Vector"],
                ["k", "0"],
                ["k", "1059"],
                ["t", "messaging"],
                ["t", "social"],
                ["t", "media"]
            ],
            content: "{\"name\":\"Vector\",\"about\":\"A private messenger.\",\"picture\":\"https://cdn.example.com/vector.png\",\"website\":\"vectorapp.io\"}",
            sig: String(repeating: "f", count: 128)
        )

        let metadata = try XCTUnwrap(NostrAppHandlerMetadata(event: event))

        XCTAssertEqual(metadata.name, "Vector")
        XCTAssertEqual(metadata.about, "A private messenger.")
        XCTAssertEqual(metadata.pictureURL?.absoluteString, "https://cdn.example.com/vector.png")
        XCTAssertEqual(metadata.websiteURL?.absoluteString, "https://vectorapp.io")
        XCTAssertEqual(metadata.supportedKinds, [0, 1_059])
        XCTAssertEqual(metadata.categories, ["messaging", "social", "media"])
    }

    private func makeReferenceEmbeddingEvent(idCharacter: Character) -> Flow.NostrEvent {
        NostrEvent(
            id: String(repeating: idCharacter, count: 64),
            pubkey: String(repeating: "c", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "",
            sig: String(repeating: "f", count: 128)
        )
    }

    func testNIP89HandlerFallsBackToAltNameWithoutValidMetadataJSON() throws {
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 31_990,
            tags: [["alt", "NIP-89 handler: Relay Tools"], ["k", "1"]],
            content: "not-json",
            sig: String(repeating: "f", count: 128)
        )

        let metadata = try XCTUnwrap(NostrAppHandlerMetadata(event: event))

        XCTAssertEqual(metadata.name, "Relay Tools")
        XCTAssertNil(metadata.about)
        XCTAssertEqual(metadata.supportedKinds, [1])
    }

    func testReportedGenericRepostNeventDecodesAsEventReference() throws {
        let identifier = "nevent1qqsddkzsl726q3smr7muc4e8ma5tqqcv2jer5g7puul9j98mmulk0jgpz4mhxue69uhhyetvv9ujuerpd46hxtnfduhsz9mhwden5te0wfjkccte9ec8y6tdv9kzumn9wshsygqyv87tanzvxd6y8xfj66u0zynfendhejtn44a9pt3k9kcntfr5m5psgqqqqqgqpl8jy0"

        let reference = try XCTUnwrap(NoteContentParser.eventReferencePointer(from: identifier))

        XCTAssertEqual(reference.eventID, "d6d850ff95a0461b1fb7cc5727df68b0030c54b23a23c1e73e5914fbdf3f67c9")
        XCTAssertEqual(reference.authorPubkey, "0461fcbecc4c3374439932d6b8f11269ccdb7cc973ad7a50ae362db135a474dd")
        XCTAssertEqual(
            reference.relayHints.map(\.absoluteString),
            ["wss://relay.damus.io/", "wss://relay.primal.net/"]
        )
    }

    func testEmptyContentEventUsesTitleAndDescriptionTagsForFallbackSummary() {
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 35_128,
            tags: [
                ["d", "accordion"],
                ["title", "Accordion"],
                ["description", "A Concord community app built using applesauce"]
            ],
            content: "",
            sig: String(repeating: "f", count: 128)
        )

        let summary = NoteContentView.taggedEventSummary(for: event)

        XCTAssertEqual(summary.title, "Accordion")
        XCTAssertEqual(summary.description, "A Concord community app built using applesauce")
        XCTAssertEqual(summary.kind, 35_128)
    }

    func testBareDomainURLUsesHTTPSLinkTarget() throws {
        let token = NoteContentToken(type: .url, value: "google.com")

        let url = try XCTUnwrap(
            NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: false
            )
        )

        XCTAssertEqual(url.absoluteString, "https://google.com")
    }

    func testBareDomainURLTrimsTrailingPunctuationForLinkTarget() throws {
        let token = NoteContentToken(type: .url, value: "google.com,")

        let url = try XCTUnwrap(
            NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: false
            )
        )

        XCTAssertEqual(url.absoluteString, "https://google.com")
    }

    func testOversizedWebURLIsRejectedBeforeTrailingPunctuationWork() {
        let oversizedURL = "https://example.com/photo.jpg" + String(repeating: ")", count: 10_000)

        XCTAssertNil(NoteContentParser.webURL(from: oversizedURL))
    }

    func testOversizedImetaURLIsNotAddedAsFeedMedia() {
        let oversizedURL = "https://example.com/photo.jpg" + String(repeating: "a", count: 10_000)
        let event = makeEvent(
            content: "A normal note",
            tags: [["imeta", "url \(oversizedURL)", "m image/png"]]
        )

        let tokens = NoteContentParser.tokenize(event: event)

        XCTAssertEqual(tokens, [NoteContentToken(type: .text, value: "A normal note")])
    }

    func testUntrustedContentTokenizationHasAWorkAndOutputBudget() {
        let content = String(repeating: "#spam ", count: 10_000) + "unreachable-tail"

        let tokens = NoteContentParser.tokenize(content: content)
        let renderedContent = tokens.map(\.value).joined()

        XCTAssertEqual(tokens.filter { $0.type == .hashtag }.count, 512)
        XCTAssertTrue(renderedContent.hasSuffix("[Note shortened for performance]"))
        XCTAssertFalse(renderedContent.contains("unreachable-tail"))
        XCTAssertLessThan(renderedContent.utf8.count, 33_000)
    }

    func testImetaMediaFanoutIsBounded() {
        let tags = (0..<100).map { index in
            ["imeta", "url https://example.com/image-\(index).png", "m image/png"]
        }
        let event = makeEvent(content: "A normal note", tags: tags)

        let tokens = NoteContentParser.tokenize(event: event)

        XCTAssertEqual(tokens.filter { $0.type == .image }.count, 12)
    }

    func testNonWebImetaURLIsNotAddedAsFeedMedia() {
        let blossomReference = "blossom:54278520e215570f95e24400a9a48ffc8646d599570df2e5ca1312c55c43e08e.png?xs=cdn.hzrd149.com&sz=18236"
        let event = makeEvent(
            content: "A normal note",
            tags: [["imeta", "url \(blossomReference)", "m image/png"]]
        )

        let tokens = NoteContentParser.tokenize(event: event)

        XCTAssertEqual(tokens, [NoteContentToken(type: .text, value: "A normal note")])
    }

    func testRenderPartsAdvancePastRejectedImageToken() {
        let rejectedImage = NoteContentToken(
            type: .image,
            value: "blossom:54278520e215570f95e24400a9a48ffc8646d599570df2e5ca1312c55c43e08e.png?xs=cdn.hzrd149.com&sz=18236"
        )
        let trailingText = NoteContentToken(type: .text, value: "Still renders")

        let parts = NoteContentView.buildRenderParts(tokens: [rejectedImage, trailingText])

        XCTAssertEqual(parts.count, 1)
        guard case .inlineTokens(let tokens) = parts[0] else {
            return XCTFail("Expected trailing text after rejected image token")
        }
        XCTAssertEqual(tokens, [trailingText])
    }

    func testBoundedRenderEventCapsContentTagsElementsAndValueBytes() throws {
        let oversizedName = String(repeating: "n", count: 100)
        let tagWithManyElements = [oversizedName] + (0..<40).map { "field-\($0)" }
        let oversizedValue = String(repeating: "v", count: 9_000)
        let tags = [tagWithManyElements, ["alt", oversizedValue]] +
            (0..<600).map { ["t", "topic-\($0)"] }
        let event = makeEvent(
            content: String(repeating: "c", count: 65_537),
            tags: tags
        )

        let bounded = NoteContentView.boundedRenderEvent(event)

        XCTAssertEqual(bounded.content.utf8.count, 65_536)
        XCTAssertEqual(bounded.tags.count, 512)
        XCTAssertEqual(bounded.tags[0].count, 33)
        XCTAssertEqual(bounded.tags[0][0].utf8.count, 32)
        XCTAssertEqual(bounded.tags[0].last, "field-31")
        XCTAssertFalse(bounded.tags[0].contains("field-32"))
        XCTAssertEqual(bounded.tags[1][1].utf8.count, 8_192)
        XCTAssertEqual(bounded.id, event.id)
        XCTAssertEqual(bounded.pubkey, event.pubkey)
        XCTAssertEqual(bounded.createdAt, event.createdAt)
        XCTAssertEqual(bounded.kind, event.kind)
        XCTAssertEqual(bounded.sig, event.sig)
    }

    func testBoundedRenderEventDoesNotExceedBudgetsAtSplitUTF8Scalar() {
        let contentPrefix = String(repeating: "c", count: 65_535)
        let tagValuePrefix = String(repeating: "v", count: 8_191)
        let event = makeEvent(
            content: contentPrefix + "😀",
            tags: [["alt", tagValuePrefix + "😀"]]
        )

        let bounded = NoteContentView.boundedRenderEvent(event)

        XCTAssertLessThanOrEqual(bounded.content.utf8.count, 65_536)
        XCTAssertLessThanOrEqual(bounded.tags[0][1].utf8.count, 8_192)
        XCTAssertEqual(bounded.content, contentPrefix)
        XCTAssertEqual(bounded.tags[0][1], tagValuePrefix)
        XCTAssertFalse(bounded.content.contains("\u{FFFD}"))
        XCTAssertFalse(bounded.tags[0][1].contains("\u{FFFD}"))
    }

    func testBoundedRenderEventCapsAggregateTagBytes() {
        let tags = (0..<20).map { _ in
            ["imeta", String(repeating: "x", count: 8_192)]
        }
        let bounded = NoteContentView.boundedRenderEvent(
            makeEvent(content: "A normal note", tags: tags)
        )
        let totalTagBytes = bounded.tags.reduce(into: 0) { total, tag in
            total += tag.reduce(into: 0) { $0 += $1.utf8.count }
        }

        XCTAssertEqual(totalTagBytes, 65_536)
        XCTAssertLessThan(bounded.tags.count, tags.count)
    }

    func testRenderEnvelopeSafetyAcceptsOnlyBoundedNostrHexIdentities() {
        XCTAssertEqual(
            NoteRenderEnvelopeSafety.normalizedEventID(String(repeating: "A", count: 64)),
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            NoteRenderEnvelopeSafety.normalizedPubkey(String(repeating: "F", count: 64)),
            String(repeating: "f", count: 64)
        )
        XCTAssertNil(
            NoteRenderEnvelopeSafety.normalizedEventID(String(repeating: "a", count: 65))
        )
        XCTAssertNil(
            NoteRenderEnvelopeSafety.normalizedPubkey(String(repeating: "p", count: 64))
        )
        XCTAssertNil(
            NoteRenderEnvelopeSafety.normalizedEventID(String(repeating: "a", count: 100_000))
        )
    }

    func testParsedContentCacheCachesPreparedRenderMetadataForValidEventID() {
        let event = makeEvent(content: "A normal note")
        let cache = NoteParsedContentCache(maxEntries: 2)
        var builderCallCount = 0

        _ = cache.parsedContent(for: event) {
            builderCallCount += 1
            return makeParsedContent(for: event)
        }
        let cached = cache.parsedContent(for: event) {
            builderCallCount += 1
            return makeParsedContent(for: event)
        }

        XCTAssertEqual(builderCallCount, 1)
        XCTAssertEqual(cached.renderEvent, event)
    }

    func testParsedContentCacheDoesNotCacheOversizedInvalidEventID() {
        let event = Flow.NostrEvent(
            id: String(repeating: "a", count: 100_000),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "A normal note",
            sig: String(repeating: "f", count: 128)
        )
        let cache = NoteParsedContentCache(maxEntries: 2)
        var builderCallCount = 0

        for _ in 0..<2 {
            _ = cache.parsedContent(for: event) {
                builderCallCount += 1
                return makeParsedContent(for: event)
            }
        }

        XCTAssertEqual(builderCallCount, 2)
    }

    func testPreparedRenderEventBoundsDecodedRepost() throws {
        let embeddedObject: [String: Any] = [
            "id": String(repeating: "2", count: 64),
            "pubkey": String(repeating: "b", count: 64),
            "created_at": 1_700_000_001,
            "kind": 1,
            "tags": (0..<600).map { ["t", "topic-\($0)"] },
            "content": String(repeating: "r", count: 70_000),
            "sig": String(repeating: "e", count: 128)
        ]
        let embeddedData = try JSONSerialization.data(withJSONObject: embeddedObject)
        let repost = Flow.NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_002,
            kind: 6,
            tags: [],
            content: String(decoding: embeddedData, as: UTF8.self),
            sig: String(repeating: "f", count: 128)
        )

        let prepared = NoteContentView.preparedRenderEvent(for: repost)

        XCTAssertEqual(prepared.kind, 1)
        XCTAssertEqual(prepared.id, String(repeating: "2", count: 64))
        XCTAssertEqual(prepared.content.utf8.count, 65_536)
        XCTAssertEqual(prepared.tags.count, 512)
    }

    func testImetaUsesFirstURLAndMIMEFields() {
        let firstURL = "https://example.com/asset"
        let event = makeEvent(
            content: "A normal note",
            tags: [[
                "imeta",
                "url \(firstURL)",
                "m image/png",
                "url https://example.com/asset.mp4",
                "m video/mp4"
            ]]
        )

        let mediaTokens = NoteContentParser.tokenize(event: event).filter { $0.type != .text }

        XCTAssertEqual(mediaTokens, [NoteContentToken(type: .image, value: firstURL)])
    }

    func testImetaDoesNotFallThroughAfterRejectedFirstURLField() {
        let oversizedURL = "https://example.com/" + String(repeating: "a", count: 9_000)
        let event = makeEvent(
            content: "A normal note",
            tags: [[
                "imeta",
                "url \(oversizedURL)",
                "url https://example.com/valid.png",
                "m image/png"
            ]]
        )

        XCTAssertEqual(
            NoteContentParser.tokenize(event: event),
            [NoteContentToken(type: .text, value: "A normal note")]
        )
    }

    func testImetaDoesNotFallThroughAfterRejectedFirstMIMEField() {
        let extensionlessURL = "https://example.com/asset"
        let oversizedMIME = "m " + String(repeating: "a", count: 300)
        let event = makeEvent(
            content: "A normal note",
            tags: [[
                "imeta",
                "url \(extensionlessURL)",
                oversizedMIME,
                "m image/png"
            ]]
        )

        let mediaTokens = NoteContentParser.tokenize(event: event).filter { $0.type != .text }

        XCTAssertEqual(mediaTokens, [NoteContentToken(type: .url, value: extensionlessURL)])
    }

    func testImetaInspectionStopsAfterThirtyTwoRecognizedTags() {
        let rejectedTags = (0..<32).map { index in
            ["imeta", "url blossom:rejected-\(index)", "m image/png"]
        }
        let event = makeEvent(
            content: "A normal note",
            tags: rejectedTags + [[
                "imeta",
                "url https://example.com/should-not-render.png",
                "m image/png"
            ]]
        )

        XCTAssertEqual(
            NoteContentParser.tokenize(event: event),
            [NoteContentToken(type: .text, value: "A normal note")]
        )
    }

    func testBareDomainTokenKeepsDisplayValueButGetsClickableTarget() throws {
        let tokens = NoteContentParser.tokenize(content: "Search google.com")
        let token = try XCTUnwrap(tokens.first { $0.type == .url })

        XCTAssertEqual(token.value, "google.com")
        XCTAssertEqual(NoteContentParser.lastWebsiteURL(in: tokens)?.absoluteString, "https://google.com")
        XCTAssertEqual(
            NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: false
            )?.absoluteString,
            "https://google.com"
        )
    }

    func testLocalNetworkWebURLsAreNotLoadable() {
        let blockedValues = [
            "http://localhost/avatar.jpg",
            "https://printer.local/image.png",
            "http://192.168.1.42/photo.jpg",
            "http://10.0.0.5/photo.jpg",
            "http://172.16.0.8/photo.jpg",
            "http://[fe80::1]/photo.jpg",
            "http://[::1]/photo.jpg"
        ]

        for value in blockedValues {
            XCTAssertNil(NoteContentParser.webURL(from: value), value)
        }

        XCTAssertEqual(
            NoteContentParser.webURL(from: "https://example.com/photo.jpg")?.absoluteString,
            "https://example.com/photo.jpg"
        )
    }

    func testLocalNetworkMediaURLDoesNotBecomeImageGalleryURL() {
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "bad http://192.168.1.42/photo.jpg good https://example.com/photo.jpg",
            sig: String(repeating: "f", count: 128)
        )

        XCTAssertEqual(
            NoteContentParser.imageURLs(in: event).map(\.absoluteString),
            ["https://example.com/photo.jpg"]
        )
    }

    func testLocalNetworkRelayURLsAreRejected() {
        XCTAssertNil(RelayURLSupport.normalizedURL(from: "ws://192.168.1.42:8080/"))
        XCTAssertNil(RelayURLSupport.normalizedURL(from: "wss://relay.local/"))
        XCTAssertNil(NoteContentParser.relayHintURL(from: "wss://10.0.0.4/"))
        XCTAssertEqual(
            RelayURLSupport.normalizedURL(from: "wss://relay.example.com")?.absoluteString,
            "wss://relay.example.com/"
        )
    }

    func testLocalNetworkProfileAvatarURLIsRejected() {
        let profile = NostrProfile(
            name: "Local Avatar",
            displayName: nil,
            picture: "http://192.168.1.42/avatar.jpg",
            banner: nil,
            about: nil,
            nip05: nil,
            website: nil,
            lud06: nil,
            lud16: nil
        )

        XCTAssertNil(profile.resolvedAvatarURL)
    }

    func testMentionLinkUsesInAppProfileRouteWhenProfileTapAvailable() throws {
        let pubkey = String(format: "%064x", 1)
        let npub = try XCTUnwrap(PublicKey(hex: pubkey)?.npub)
        let token = NoteContentToken(type: .nostrMention, value: npub)

        let url = try XCTUnwrap(
            NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: true
            )
        )

        XCTAssertEqual(url.scheme, "x21-profile")
        XCTAssertEqual(NoteContentParser.profilePubkey(fromActionURL: url), pubkey)
    }

    func testMentionLinkFallsBackToExternalNlinkWhenProfileTapUnavailable() throws {
        let pubkey = String(format: "%064x", 2)
        let npub = try XCTUnwrap(PublicKey(hex: pubkey)?.npub)
        let token = NoteContentToken(type: .nostrMention, value: npub)

        let url = try XCTUnwrap(
            NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: false
            )
        )

        XCTAssertEqual(url.absoluteString, "https://nlink.to/\(npub)")
    }

    func testM3U8URLTokenizesAsVideoInsteadOfWebsitePreview() {
        let tokens = NoteContentParser.tokenize(content: "Watch https://example.com/live/master.m3u8")

        XCTAssertTrue(tokens.contains(where: { $0.type == .video && $0.value == "https://example.com/live/master.m3u8" }))
        XCTAssertNil(NoteContentParser.lastWebsiteURL(in: tokens))
    }

    func testHLSImetaTagTokenizesAsVideoFromMimeType() {
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [[
                "imeta",
                "url https://example.com/live/channel",
                "m application/vnd.apple.mpegurl"
            ]],
            content: "",
            sig: String(repeating: "f", count: 128)
        )

        let tokens = NoteContentParser.tokenize(event: event)

        XCTAssertTrue(tokens.contains(where: { $0.type == .video && $0.value == "https://example.com/live/channel" }))
    }

    func testRelayDenseWebsocketNotesUseAttributedInlineRenderer() {
        let relayLines = (0..<20)
            .map { "wss://relay-\($0).example.com" }
            .joined(separator: "\n")
        let tokens = NoteContentParser.tokenize(content: "Relays:\n\(relayLines)")

        XCTAssertEqual(tokens.filter { $0.type == .websocketURL }.count, 20)
        XCTAssertTrue(NoteContentView.shouldUseAttributedInlineText(for: tokens))
    }

    func testSmallWebsocketNotesUseAttributedInlineRendererForRelayLinks() {
        let tokens = NoteContentParser.tokenize(content: "Relay: wss://relay.example.com")

        XCTAssertEqual(tokens.filter { $0.type == .websocketURL }.count, 1)
        XCTAssertTrue(NoteContentView.shouldUseAttributedInlineText(for: tokens))
    }

    func testWebsocketURLUsesInAppRelayRoute() throws {
        let token = NoteContentToken(type: .websocketURL, value: "wss://relay.damus.io")

        let url = try XCTUnwrap(
            NoteContentLinkResolver.linkURL(
                for: token,
                allowsInAppProfileRouting: true
            )
        )

        XCTAssertEqual(url.scheme, "x21-relay")
        XCTAssertEqual(RelayURLSupport.relayURL(fromActionURL: url)?.absoluteString, "wss://relay.damus.io/")
    }

    func testRelayRouteUsesFriendlyDisplayName() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.damus.io"))
        let route = try XCTUnwrap(RelayRoute(relayURL: relayURL))

        XCTAssertEqual(route.displayName, "Damus Source")
        XCTAssertEqual(route.relayURL.absoluteString, "wss://relay.damus.io/")
    }

    func testYouTubeWatchURLTokenizesAsPlayableVideoEmbed() throws {
        let urlString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s"
        let tokens = NoteContentParser.tokenize(content: "Watch \(urlString)")
        let embed = try XCTUnwrap(NoteContentParser.youtubeVideoEmbed(from: urlString))

        XCTAssertTrue(tokens.contains(where: { $0.type == .youtubeVideo && $0.value == urlString }))
        XCTAssertNil(NoteContentParser.lastWebsiteURL(in: tokens))
        XCTAssertEqual(embed.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(embed.startSeconds, 90)
        XCTAssertEqual(
            embed.embedURL()?.absoluteString,
            "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0&start=90"
        )
    }

    func testYouTubeShortURLTokenizesAsPlayableVideoEmbed() throws {
        let urlString = "https://youtu.be/dQw4w9WgXcQ?si=abc"
        let tokens = NoteContentParser.tokenize(content: urlString)
        let embed = try XCTUnwrap(NoteContentParser.youtubeVideoEmbed(from: urlString))

        XCTAssertTrue(tokens.contains(where: { $0.type == .youtubeVideo && $0.value == urlString }))
        XCTAssertNil(NoteContentParser.lastWebsiteURL(in: tokens))
        XCTAssertEqual(embed.videoID, "dQw4w9WgXcQ")
    }

    func testYouTubeEmbedNavigationAllowsEmbedURLInsideWebView() throws {
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"))

        XCTAssertEqual(
            YouTubeEmbedNavigationPolicy.decision(
                for: embedURL,
                embedURL: embedURL,
                isNewWindow: false
            ),
            .allowInWebView
        )
    }

    func testYouTubeEmbedNavigationOpensWatchURLExternally() throws {
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"))
        let watchURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))

        XCTAssertEqual(
            YouTubeEmbedNavigationPolicy.decision(
                for: watchURL,
                embedURL: embedURL,
                isNewWindow: false
            ),
            .openExternally(watchURL)
        )
    }

    func testYouTubeEmbedNavigationCancelsWrapperBaseURLNewWindow() throws {
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"))
        let wrapperBaseURL = try XCTUnwrap(URL(string: "https://com.21media.haloapp"))

        XCTAssertEqual(
            YouTubeEmbedNavigationPolicy.decision(
                for: wrapperBaseURL,
                embedURL: embedURL,
                isNewWindow: true,
                wrapperBaseURL: wrapperBaseURL
            ),
            .cancel
        )
    }

    func testYouTubeEmbedNavigationAllowsWrapperBaseURLMainFrameLoad() throws {
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"))
        let wrapperBaseURL = try XCTUnwrap(URL(string: "https://com.21media.haloapp/"))

        XCTAssertEqual(
            YouTubeEmbedNavigationPolicy.decision(
                for: wrapperBaseURL,
                embedURL: embedURL,
                isNewWindow: false,
                isUserInitiated: false,
                wrapperBaseURL: wrapperBaseURL
            ),
            .allowInWebView
        )
    }

    func testYouTubeEmbedNavigationCancelsAutomaticExternalURL() throws {
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"))
        let watchURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))

        XCTAssertEqual(
            YouTubeEmbedNavigationPolicy.decision(
                for: watchURL,
                embedURL: embedURL,
                isNewWindow: false,
                isUserInitiated: false
            ),
            .cancel
        )
    }

    func testYouTubeEmbedNavigationOpensJavaScriptNewWindowWatchURLExternally() throws {
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"))
        let watchURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))

        XCTAssertEqual(
            YouTubeEmbedNavigationPolicy.decision(
                for: watchURL,
                embedURL: embedURL,
                isNewWindow: true,
                isUserInitiated: false
            ),
            .openExternally(watchURL)
        )
    }

    func testYouTubeEmbedNavigationOpensNewWindowURLExternally() throws {
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"))
        let watchURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))

        XCTAssertEqual(
            YouTubeEmbedNavigationPolicy.decision(
                for: watchURL,
                embedURL: embedURL,
                isNewWindow: true
            ),
            .openExternally(watchURL)
        )
    }

    func testNeventIdentifierEncodesEventMetadataForCopying() throws {
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "hello",
            sig: String(repeating: "f", count: 128)
        )
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))

        let identifier = try XCTUnwrap(NoteContentParser.neventIdentifier(for: event, relayHints: [relayURL]))
        let decoded = try ReferenceMetadataDecoder().decodedMetadata(from: identifier)

        XCTAssertTrue(identifier.hasPrefix("nevent1"))
        XCTAssertEqual(decoded.eventId?.lowercased(), event.id)
        XCTAssertEqual(decoded.pubkey?.lowercased(), event.pubkey)
        XCTAssertEqual(decoded.kind, 1)
        XCTAssertEqual(decoded.relays, [relayURL.absoluteString])
    }

    func testQuotedEventTagCarriesRelayAndAuthorHintsForReferenceLookup() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))
        let eventID = String(repeating: "2", count: 64)
        let authorPubkey = String(repeating: "b", count: 64)
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [["q", eventID, relayURL.absoluteString, authorPubkey]],
            content: "",
            sig: String(repeating: "f", count: 128)
        )

        let token = try XCTUnwrap(NoteContentParser.tokenize(event: event).first)
        let decoded = try ReferenceMetadataDecoder().decodedMetadata(from: token.value)

        XCTAssertEqual(token.type, .nostrEvent)
        XCTAssertTrue(token.value.hasPrefix("nevent1"))
        XCTAssertEqual(decoded.eventId?.lowercased(), eventID)
        XCTAssertEqual(decoded.pubkey?.lowercased(), authorPubkey)
        XCTAssertEqual(decoded.relays, [relayURL.absoluteString])
    }

    func testInlineEventReferenceUpgradesToTaggedRelayAndAuthorHints() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))
        let eventID = String(repeating: "2", count: 64)
        let authorPubkey = String(repeating: "b", count: 64)
        let referencedEvent = NostrEvent(
            id: eventID,
            pubkey: authorPubkey,
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "quoted note",
            sig: String(repeating: "f", count: 128)
        )
        let inlineIdentifier = try XCTUnwrap(NoteContentParser.neventIdentifier(for: referencedEvent))
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_001,
            kind: 1,
            tags: [["q", eventID, relayURL.absoluteString, authorPubkey]],
            content: "nostr:\(inlineIdentifier)",
            sig: String(repeating: "f", count: 128)
        )

        let eventTokens = NoteContentParser.tokenize(event: event).filter { $0.type == .nostrEvent }
        let token = try XCTUnwrap(eventTokens.first)
        let decoded = try ReferenceMetadataDecoder().decodedMetadata(from: token.value)

        XCTAssertEqual(eventTokens.count, 1)
        XCTAssertEqual(decoded.eventId?.lowercased(), eventID)
        XCTAssertEqual(decoded.pubkey?.lowercased(), authorPubkey)
        XCTAssertEqual(decoded.relays, [relayURL.absoluteString])
    }

    func testMentionEventTagCarriesRelayAndAuthorHintsForReferenceLookup() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))
        let eventID = String(repeating: "2", count: 64)
        let authorPubkey = String(repeating: "b", count: 64)
        let event = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [["e", eventID, relayURL.absoluteString, "mention", authorPubkey]],
            content: "",
            sig: String(repeating: "f", count: 128)
        )

        let token = try XCTUnwrap(NoteContentParser.tokenize(event: event).first)
        let decoded = try ReferenceMetadataDecoder().decodedMetadata(from: token.value)

        XCTAssertEqual(token.type, .nostrEvent)
        XCTAssertTrue(token.value.hasPrefix("nevent1"))
        XCTAssertEqual(decoded.eventId?.lowercased(), eventID)
        XCTAssertEqual(decoded.pubkey?.lowercased(), authorPubkey)
        XCTAssertEqual(decoded.relays, [relayURL.absoluteString])
    }

    func testNeventSearchDescriptorCreatesEventReferenceSuggestion() throws {
        let event = NostrEvent(
            id: String(repeating: "3", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "hello",
            sig: String(repeating: "f", count: 128)
        )
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com"))
        let identifier = try XCTUnwrap(NoteContentParser.neventIdentifier(for: event, relayHints: [relayURL]))
        let descriptor = SearchViewModel.SearchQueryDescriptor(rawText: "nostr:\(identifier)")
        let suggestion = try XCTUnwrap(descriptor.suggestedContentSearch)

        guard case .eventReference(let reference) = suggestion.kind else {
            return XCTFail("Expected event reference search suggestion")
        }

        XCTAssertEqual(reference.eventID, event.id)
        XCTAssertEqual(reference.authorPubkey, event.pubkey)
        XCTAssertEqual(reference.relayHints.map(\.absoluteString), [relayURL.absoluteString])
        XCTAssertFalse(suggestion.isPinnable)
    }

    func testImageAspectRatioHintsReadImetaDimensions() {
        let hints = NoteImageLayoutGuide.imageAspectRatioHints(from: [[
            "imeta",
            "url https://example.com/photo.jpg",
            "m image/jpeg",
            "dim 1200x900"
        ]])

        XCTAssertEqual(hints["https://example.com/photo.jpg"] ?? 0, 1200.0 / 900.0, accuracy: 0.001)
    }

    func testSingleImageAspectRatioPreservesPanoramicMedia() throws {
        let panoramicRatio: CGFloat = 8

        XCTAssertEqual(
            try XCTUnwrap(NoteImageLayoutGuide.normalizedSingleImageAspectRatio(panoramicRatio)),
            panoramicRatio,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NoteImageLayoutGuide.singleImageHeight(width: 320, aspectRatio: panoramicRatio),
            40,
            accuracy: 0.001
        )
    }

    func testSingleImageImetaHintPreservesPanoramicDimensions() {
        let url = URL(string: "https://example.com/panorama.png")!
        let hints = NoteImageLayoutGuide.imageAspectRatioHints(from: [[
            "imeta",
            "url https://example.com/panorama.png",
            "m image/png",
            "dim 2400x300"
        ]])

        XCTAssertEqual(
            NoteImageLayoutGuide.singleImageAspectRatioHint(for: url, in: hints) ?? 0,
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NoteImageLayoutGuide.aspectRatioHint(for: url, in: hints) ?? 0,
            3.2,
            accuracy: 0.001
        )
    }

    func testMediaAspectRatioCacheBoundsPanoramicGeometryForGenericConsumers() throws {
        let url = try XCTUnwrap(
            URL(string: "https://example.com/panorama-\(UUID().uuidString).png")
        )

        FlowMediaAspectRatioCache.shared.insert(8, for: url)

        XCTAssertEqual(
            try XCTUnwrap(FlowMediaAspectRatioCache.shared.ratio(for: url)),
            3.2,
            accuracy: 0.001
        )
    }

    func testBucketedSingleImageAspectRatioUsesNearestLayoutBucket() {
        XCTAssertEqual(
            NoteImageLayoutGuide.bucketedSingleImageAspectRatio(for: 1.72),
            16.0 / 9.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NoteImageLayoutGuide.bucketedSingleImageAspectRatio(for: 0.78),
            4.0 / 5.0,
            accuracy: 0.001
        )
    }

    private func makeEvent(
        content: String,
        tags: [[String]] = []
    ) -> Flow.NostrEvent {
        Flow.NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: tags,
            content: content,
            sig: String(repeating: "f", count: 128)
        )
    }

    private func makeParsedContent(for event: Flow.NostrEvent) -> NoteContentView.ParsedContent {
        NoteContentView.ParsedContent(
            renderEvent: event,
            articleMetadata: nil,
            zapReceiptMetadata: nil,
            appHandlerMetadata: nil,
            unsupportedEventMetadata: nil,
            pollMetadata: nil,
            tokens: [],
            parts: [],
            websitePreviewURL: nil,
            mentionIdentifiers: [],
            emojiTagURLs: [:],
            mediaAspectRatioHints: [:],
            gifLikeVideoURLKeys: [],
            taggedEventSummary: NoteContentView.taggedEventSummary(for: event)
        )
    }
}

private struct ReferenceMetadataDecoder: MetadataCoding {}
