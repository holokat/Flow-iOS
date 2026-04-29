import XCTest
@testable import Flow

final class NostrArchivesSearchServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSearchProfilesUsesSuggestThenProfileSearchAndDeduplicatesResults() async throws {
        let firstPubkey = String(repeating: "a", count: 64)
        let secondPubkey = String(repeating: "b", count: 64)
        let session = makeMockSession { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            XCTAssertEqual(queryItems["q"], "ja")
            XCTAssertEqual(queryItems["limit"], "3")

            switch components.path {
            case "/v1/search/suggest":
                return self.jsonResponse(
                    """
                    {
                      "query": "ja",
                      "suggestions": [
                        {
                          "pubkey": "\(firstPubkey)",
                          "name": "jack",
                          "display_name": "Jack",
                          "picture": "https://example.com/jack.jpg"
                        }
                      ]
                    }
                    """
                )
            case "/v1/search":
                XCTAssertEqual(queryItems["type"], "profiles")
                return self.jsonResponse(
                    """
                    {
                      "query": "ja",
                      "profiles": [
                        {
                          "pubkey": "\(firstPubkey)",
                          "name": "jack duplicate",
                          "display_name": "Jack Duplicate"
                        },
                        {
                          "pubkey": "\(secondPubkey)",
                          "name": "jack mallers",
                          "display_name": "Jack Mallers",
                          "nip05": "jack@example.com"
                        }
                      ]
                    }
                    """
                )
            default:
                XCTFail("Unexpected path \(components.path)")
                return self.jsonResponse(#"{}"#, statusCode: 404)
            }
        }
        let service = NostrArchivesSearchService(
            baseURL: URL(string: "https://api.example.test")!,
            session: session
        )

        let results = await service.searchProfiles(query: "ja", limit: 3)

        XCTAssertEqual(results.map { $0.pubkey }, [firstPubkey, secondPubkey])
        XCTAssertEqual(results.first?.profile?.displayName, "Jack")
        XCTAssertEqual(results.last?.profile?.nip05, "jack@example.com")
    }

    func testSearchNotesCallsV1SearchNotesAndFiltersKinds() async throws {
        let matchingEventID = String(repeating: "c", count: 64)
        let skippedEventID = String(repeating: "d", count: 64)
        let authorPubkey = String(repeating: "e", count: 64)
        let session = makeMockSession { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            XCTAssertEqual(components.path, "/v1/search")
            XCTAssertEqual(queryItems["q"], "Food")
            XCTAssertEqual(queryItems["type"], "notes")
            XCTAssertEqual(queryItems["limit"], "10")
            XCTAssertEqual(queryItems["offset"], "0")

            return self.jsonResponse(
                """
                {
                  "query": "Food",
                  "notes": [
                    {
                      "event": {
                        "id": "\(matchingEventID)",
                        "pubkey": "\(authorPubkey)",
                        "created_at": 1770723788,
                        "kind": 1,
                        "content": "Food systems",
                        "tags": [["t", "food"]],
                        "sig": "\(String(repeating: "f", count: 128))"
                      },
                      "reactions": 12
                    },
                    {
                      "event": {
                        "id": "\(skippedEventID)",
                        "pubkey": "\(authorPubkey)",
                        "created_at": 1770723790,
                        "kind": 7,
                        "content": "+",
                        "tags": [],
                        "sig": "\(String(repeating: "0", count: 128))"
                      }
                    }
                  ]
                }
                """
            )
        }
        let service = NostrArchivesSearchService(
            baseURL: URL(string: "https://api.example.test")!,
            session: session
        )

        let events = try await service.searchNotes(
            query: "Food",
            kinds: [1],
            limit: 10
        )

        XCTAssertEqual(events.map { $0.id }, [matchingEventID])
        XCTAssertEqual(events.first?.content, "Food systems")
        XCTAssertEqual(events.first?.tags, [["t", "food"]])
    }

    private func makeMockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func jsonResponse(_ json: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://api.example.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
