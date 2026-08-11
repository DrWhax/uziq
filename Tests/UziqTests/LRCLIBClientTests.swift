import Foundation
import XCTest
@testable import Uziq

final class LRCLIBClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LRCLIBURLProtocolStub.reset()
    }

    func testExactLookupSendsIdentifyingRequestAndReturnsPlainLyrics() async throws {
        LRCLIBURLProtocolStub.responses = [
            .init(statusCode: 200, body: """
                {
                  "trackName": "A Song",
                  "artistName": "An Artist",
                  "albumName": "An Album",
                  "duration": 183.2,
                  "instrumental": false,
                  "plainLyrics": "First line\\nSecond line",
                  "syncedLyrics": null
                }
                """)
        ]
        let client = LRCLIBClient(session: makeSession())

        let result = try await client.lookup(.init(
            title: "A Song",
            artist: "An Artist",
            album: "An Album",
            duration: 183.2
        ))

        XCTAssertEqual(result, .lyrics(LyricsPayload(
            plain: "First line\nSecond line",
            synced: nil
        )))
        let request = try XCTUnwrap(LRCLIBURLProtocolStub.requests.first)
        XCTAssertEqual(request.url?.path, "/api/get")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "track_name" })?.value, "A Song")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "duration" })?.value, "183")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Uziq/") == true)
    }

    func testMissingExactMatchFallsBackToSearchAndPreservesSyncedTimestamps() async throws {
        LRCLIBURLProtocolStub.responses = [
            .init(statusCode: 404, body: "{}"),
            .init(statusCode: 200, body: """
                [{
                  "trackName": "A Song",
                  "artistName": "An Artist feat. Someone",
                  "albumName": "Other Edition",
                  "duration": 184.0,
                  "instrumental": false,
                  "plainLyrics": null,
                  "syncedLyrics": "[00:01.20]First line\\n[00:05.00]Second line"
                }]
                """)
        ]
        let client = LRCLIBClient(session: makeSession())

        let result = try await client.lookup(.init(
            title: "A Song",
            artist: "An Artist",
            album: "An Album",
            duration: 183.2
        ))

        XCTAssertEqual(result, .lyrics(LyricsPayload(
            plain: "First line\nSecond line",
            synced: "[00:01.20]First line\n[00:05.00]Second line"
        )))
        XCTAssertEqual(LRCLIBURLProtocolStub.requests.map { $0.url?.path }, ["/api/get", "/api/search"])
    }

    func testSyncedLyricsParserHandlesFractionsMultipleTimestampsAndOffset() {
        let lines = SyncedLyricsParser.parse("""
            [offset:+250]
            [00:01.20]First line
            [00:05.5][00:07.500]Repeated line
            [ar:An Artist]
            """)

        XCTAssertEqual(lines.map(\.text), ["First line", "Repeated line", "Repeated line"])
        XCTAssertEqual(lines.map(\.time), [1.45, 5.75, 7.75])
    }

    func testRateLimitIsReportedWithoutSearching() async throws {
        LRCLIBURLProtocolStub.responses = [
            .init(statusCode: 429, body: "{}", headers: ["Retry-After": "60"])
        ]
        let client = LRCLIBClient(session: makeSession())

        do {
            _ = try await client.lookup(.init(
                title: "A Song",
                artist: "An Artist",
                album: "An Album",
                duration: 183
            ))
            XCTFail("Expected the lookup to be rate limited")
        } catch let error as LRCLIBError {
            guard case .rateLimited(let until) = error else {
                return XCTFail("Unexpected LRCLIB error: \(error)")
            }
            XCTAssertNotNil(until)
        }
        XCTAssertEqual(LRCLIBURLProtocolStub.requests.count, 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LRCLIBURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class LRCLIBURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let statusCode: Int
        let body: String
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    nonisolated(unsafe) static var responses: [StubResponse] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            responses = []
            requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.lock.withLock { () -> StubResponse in
            Self.requests.append(request)
            return Self.responses.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
