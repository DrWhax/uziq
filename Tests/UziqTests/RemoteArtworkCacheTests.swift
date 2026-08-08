import Foundation
import XCTest
@testable import Uziq

final class RemoteArtworkCacheTests: XCTestCase {
    func testConcurrentRequestsFetchOnceAndLaterUseDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-artwork-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        ArtworkURLProtocolStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(URL(string: "https://images.example.test/release-cover.jpg"))
        let firstCache = RemoteArtworkCache(directory: directory, session: session)
        async let first = firstCache.data(for: url)
        async let second = firstCache.data(for: url)
        let values = await (first, second)

        XCTAssertEqual(values.0, ArtworkURLProtocolStub.payload)
        XCTAssertEqual(values.1, ArtworkURLProtocolStub.payload)
        XCTAssertEqual(ArtworkURLProtocolStub.requestCount, 1)

        let restoredCache = RemoteArtworkCache(directory: directory, session: session)
        let restored = await restoredCache.data(for: url)
        XCTAssertEqual(restored, ArtworkURLProtocolStub.payload)
        XCTAssertEqual(ArtworkURLProtocolStub.requestCount, 1)
    }
}

private final class ArtworkURLProtocolStub: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 0xA5, count: 4_096)
    nonisolated(unsafe) private static var count = 0
    private static let lock = NSLock()

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset() {
        lock.withLock { count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
