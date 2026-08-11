import Foundation
import XCTest
@testable import Uziq

final class FolderWatcherTests: XCTestCase {
    func testWatcherReportsARecursiveFileChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uziq-folder-watch-\(UUID().uuidString)", isDirectory: true)
        let nested = directory.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changeReceived = DispatchSemaphore(value: 0)
        let watcher = FolderWatcher()
        XCTAssertTrue(watcher.start(roots: [directory]) { affectedRoots in
            if affectedRoots.contains(directory.standardizedFileURL) {
                changeReceived.signal()
            }
        })
        defer { watcher.stop() }

        // Give the stream's dispatch queue a moment to install its initial cursor.
        Thread.sleep(forTimeInterval: 0.2)
        try Data("new audio placeholder".utf8)
            .write(to: nested.appendingPathComponent("track.flac"), options: .atomic)

        XCTAssertEqual(changeReceived.wait(timeout: .now() + 5), .success)
    }
}
