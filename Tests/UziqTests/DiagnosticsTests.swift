import Foundation
import XCTest
@testable import Uziq

final class DiagnosticsTests: XCTestCase {
    func testDiagnosticsRedactsHomePathsAndCredentials() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let input = "\(home)/Music password=opensesame authorization: token123 bearer abc.def https://user:pass@example.com"

        let redacted = DiagnosticsLog.redact(input)

        XCTAssertFalse(redacted.contains(home))
        XCTAssertFalse(redacted.contains("opensesame"))
        XCTAssertFalse(redacted.contains("token123"))
        XCTAssertFalse(redacted.contains("abc.def"))
        XCTAssertFalse(redacted.contains("user:pass"))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }
}
