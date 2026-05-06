import XCTest
import NostrSDK
@testable import Flow

final class NoteContentLinkResolverTests: XCTestCase {
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

        XCTAssertEqual(route.displayName, "Damus Relay")
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
                isNewWindow: true,
                isUserInitiated: false
            ),
            .cancel
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
}

private struct ReferenceMetadataDecoder: MetadataCoding {}
