import SwiftUI
import XCTest
@testable import Uziq

final class PlaybackUsabilityTests: XCTestCase {
    @MainActor
    func testBrowseStateKeepsIndependentFiltersPathsAndOffsets() {
        let state = BrowseState()
        state.filter(for: .albums).wrappedValue = "Album filter"
        state.filter(for: .artists).wrappedValue = "Artist filter"
        var path = NavigationPath()
        path.append(LocalBrowseRoute.artist("artist"))
        path.append(LocalBrowseRoute.album("album"))
        state.path(for: .artists).wrappedValue = path
        state.offsets["artist-artist"] = CGPoint(x: 0, y: 750)
        XCTAssertEqual(state.path(for: .artists).wrappedValue.count, 2)
        XCTAssertTrue(state.path(for: .albums).wrappedValue.isEmpty)
        XCTAssertEqual(state.filter(for: .albums).wrappedValue, "Album filter")
        XCTAssertEqual(state.filter(for: .artists).wrappedValue, "Artist filter")
        state.path(for: .albums).wrappedValue = NavigationPath()
        XCTAssertEqual(state.offsets["artist-artist"]?.y, 750)
        XCTAssertEqual(state.path(for: .artists).wrappedValue.count, 2)
    }

    @MainActor
    func testUndoReplacementAndClearRestoreQueueIdentityAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-undo-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PlaybackQueueStore(sessionURL: url)
        let first = item("first"), second = item("second"), replacement = item("replacement")
        queue.replace(with: [first, second], startingAt: second)
        XCTAssertFalse(queue.canUndoQueueChange)
        queue.replace(with: replacement)
        XCTAssertTrue(queue.canUndoQueueChange)
        queue.undoQueueChange()
        XCTAssertEqual(queue.items, [first, second])
        XCTAssertEqual(queue.currentItem?.id, second.id)
        XCTAssertFalse(queue.canUndoQueueChange)
        queue.clear()
        XCTAssertTrue(queue.items.isEmpty)
        queue.undoQueueChange()
        XCTAssertEqual(queue.items, [first, second])
        XCTAssertEqual(queue.currentItem?.id, second.id)
        let restored = PlaybackQueueStore(sessionURL: url)
        XCTAssertEqual(restored.items, [first, second])
        XCTAssertEqual(restored.currentItem?.id, second.id)
    }

    @MainActor
    func testUndoClearUpcomingAndNoOpDoNotLosePreviousQueue() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-upcoming-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PlaybackQueueStore(sessionURL: url)
        let first = item("first"), second = item("second")
        queue.replace(with: [first, second])
        queue.clearUpcoming()
        queue.clearUpcoming()
        queue.undoQueueChange()
        XCTAssertEqual(queue.items, [first, second])
        XCTAssertEqual(queue.currentItem?.id, first.id)
    }

    @MainActor
    func testMissingFileDoesNotLoopWithRepeatAllAndIssueSurvivesReplacement() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-missing-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PlaybackQueueStore(sessionURL: url)
        let missing = item("missing")
        queue.repeatMode = .all
        queue.replace(with: missing)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(queue.currentItem?.id, missing.id)
        XCTAssertEqual(queue.issue(source: .local, id: "missing")?.missingFile, true)
        queue.replace(with: item("other"))
        XCTAssertNotNil(queue.issue(source: .local, id: "missing"))
        XCTAssertNil(queue.issue(source: .spotify, id: "missing"))
    }

    @MainActor
    func testLateCompletionDoesNotAdvanceAFailedQueueItem() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-late-completion-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PlaybackQueueStore(sessionURL: url)
        let first = item("first"), second = item("second")
        queue.replace(with: [first, second])
        NotificationCenter.default.post(name: .uziqPlaybackItemFinished, object: nil)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(queue.currentItem?.id, first.id)
    }

    private func item(_ id: String) -> UnifiedQueueItem {
        UnifiedQueueItem(historyLocalID: id, url: URL(fileURLWithPath: "/tmp/nonexistent-\(id).flac"), title: id, artist: "Artist", album: "Album")
    }
}
