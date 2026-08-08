import XCTest
@testable import Uziq

final class BandcampTests: XCTestCase {
    func testDuplicatedMalformedBandcampURLIsCanonicalized() throws {
        let malformed = try XCTUnwrap(URL(
            string: "https://dkfmshoegaze.bandcamp.comhttps//dkfmshoegaze.bandcamp.com/album/alternative-f-acts-a-shoegaze-resistance-compilation"
        ))
        let result = BandcampResult(
            id: "album-1",
            title: "Alternative F-Acts",
            artist: "Various Artists",
            url: malformed,
            type: "a"
        )

        XCTAssertEqual(
            result.openURL.absoluteString,
            "https://dkfmshoegaze.bandcamp.com/album/alternative-f-acts-a-shoegaze-resistance-compilation"
        )
    }

    func testCacheCleanupOnlyRemovesFilesUnusedForSevenDays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-cache-test-\(UUID().uuidString)", isDirectory: true)
        let cache = BandcampCacheManager(directory: directory)
        try cache.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stale = directory.appendingPathComponent("stale.mp3")
        let recent = directory.appendingPathComponent("recent.mp3")
        try Data(repeating: 1, count: 12).write(to: stale)
        try Data(repeating: 2, count: 20).write(to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: stale.path
        )

        let removed = try cache.removeFilesNotUsed(
            since: Date.now.addingTimeInterval(-BandcampCacheManager.retentionInterval)
        )
        let stats = try cache.stats()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(stats, BandcampCacheStats(fileCount: 1, totalBytes: 20))
    }

    func testPlayingCachedFileUpdatesItsLastUsedDate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-cache-touch-test-\(UUID().uuidString)", isDirectory: true)
        let cache = BandcampCacheManager(directory: directory)
        try cache.prepareDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("track.mp3")
        try Data([1]).write(to: file)
        let oldDate = Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        try cache.markUsed(file)
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey])

        XCTAssertGreaterThan(try XCTUnwrap(values.contentModificationDate), oldDate)
    }
}
