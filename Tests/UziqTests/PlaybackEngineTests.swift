import XCTest
@testable import Uziq

final class PlaybackEngineTests: XCTestCase {
    func testEqualizerAddsHeadroomForPositiveBoosts() {
        XCTAssertEqual(
            PlaybackEngine.equalizerHeadroomDB(
                enabled: true,
                gains: EqualizerPreset.bassBoost.gains!
            ),
            -7
        )
        XCTAssertEqual(
            PlaybackEngine.equalizerHeadroomDB(
                enabled: true,
                gains: [-3, -1, 0]
            ),
            0
        )
    }

    func testDisabledEqualizerDoesNotAttenuatePlayback() {
        XCTAssertEqual(
            PlaybackEngine.equalizerHeadroomDB(enabled: false, gains: [12]),
            0
        )
    }
}
