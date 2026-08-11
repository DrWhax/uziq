import CoreAudio
import XCTest
@testable import Uziq

final class AudioOutputDeviceTests: XCTestCase {
    func testSystemDefaultSelectionResolvesCurrentDefaultDevice() {
        let devices = [
            AudioOutputDevice(deviceID: 42, uid: "speakers", name: "Speakers", isSystemDefault: true),
            AudioOutputDevice(deviceID: 84, uid: "headphones", name: "Headphones", isSystemDefault: false)
        ]

        XCTAssertEqual(
            AudioOutputSelection.resolveDeviceID(
                selectedUID: AudioOutputSelection.systemDefaultUID,
                devices: devices,
                defaultDeviceID: 42
            ),
            42
        )
    }

    func testSpecificSelectionUsesPersistentDeviceUID() {
        let devices = [
            AudioOutputDevice(deviceID: 42, uid: "speakers", name: "Speakers", isSystemDefault: true),
            AudioOutputDevice(deviceID: 84, uid: "headphones", name: "Headphones", isSystemDefault: false)
        ]

        XCTAssertEqual(
            AudioOutputSelection.resolveDeviceID(
                selectedUID: "headphones",
                devices: devices,
                defaultDeviceID: 42
            ),
            84
        )
        XCTAssertNil(
            AudioOutputSelection.resolveDeviceID(
                selectedUID: "disconnected-device",
                devices: devices,
                defaultDeviceID: 42
            )
        )
    }

    func testCoreAudioDiscoveryOnlyReturnsNamedOutputDevices() {
        let snapshot = AudioOutputDevices.snapshot()

        XCTAssertTrue(snapshot.devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        XCTAssertEqual(Set(snapshot.devices.map(\.uid)).count, snapshot.devices.count)
    }
}
