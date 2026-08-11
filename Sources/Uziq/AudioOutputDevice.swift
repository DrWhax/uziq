import AudioToolbox
import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let isSystemDefault: Bool

    var id: String { uid }
}

struct AudioOutputSnapshot: Sendable {
    let devices: [AudioOutputDevice]
    let defaultDeviceID: AudioDeviceID?
}

enum AudioOutputSelection {
    static let systemDefaultUID = "__uziq_system_default__"

    static func resolveDeviceID(
        selectedUID: String,
        devices: [AudioOutputDevice],
        defaultDeviceID: AudioDeviceID?
    ) -> AudioDeviceID? {
        if selectedUID == systemDefaultUID { return defaultDeviceID }
        return devices.first(where: { $0.uid == selectedUID })?.deviceID
    }
}

enum AudioOutputError: LocalizedError {
    case noDefaultDevice
    case deviceUnavailable
    case outputUnitUnavailable
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDefaultDevice:
            "macOS did not report a default audio output device."
        case .deviceUnavailable:
            "The selected audio output is no longer available."
        case .outputUnitUnavailable:
            "Uziq could not access its CoreAudio output unit."
        case .coreAudio(let operation, let status):
            "\(operation) failed (CoreAudio \(status))."
        }
    }
}

enum AudioOutputDevices {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func snapshot() -> AudioOutputSnapshot {
        let defaultDeviceID = readDefaultDeviceID()
        let deviceIDs = readDeviceIDs()
        let devices = deviceIDs.compactMap { deviceID -> AudioOutputDevice? in
            guard hasOutputStreams(deviceID),
                  let uid = readString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = readString(objectID: deviceID, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return AudioOutputDevice(
                deviceID: deviceID,
                uid: uid,
                name: name,
                isSystemDefault: deviceID == defaultDeviceID
            )
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return AudioOutputSnapshot(devices: devices, defaultDeviceID: defaultDeviceID)
    }

    static func select(_ deviceID: AudioDeviceID, for audioUnit: AudioUnit) throws {
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioOutputError.coreAudio(operation: "Selecting the audio output", status: status)
        }
    }

    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func readDefaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &value)
        return status == noErr && value != kAudioObjectUnknown ? value : nil
    }

    private static func readDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var values = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? values : []
    }

    private static func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}

final class AudioOutputDeviceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.uziq.audio-output-monitor")
    private let didChange: @Sendable () -> Void
    private var listener: AudioObjectPropertyListenerBlock?

    init(didChange: @escaping @Sendable () -> Void) {
        self.didChange = didChange
    }

    func start() {
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.didChange()
        }
        self.listener = listener
        addListener(selector: kAudioHardwarePropertyDevices, listener: listener)
        addListener(selector: kAudioHardwarePropertyDefaultOutputDevice, listener: listener)
    }

    deinit {
        guard let listener else { return }
        removeListener(selector: kAudioHardwarePropertyDevices, listener: listener)
        removeListener(selector: kAudioHardwarePropertyDefaultOutputDevice, listener: listener)
    }

    private func addListener(
        selector: AudioObjectPropertySelector,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
    }

    private func removeListener(
        selector: AudioObjectPropertySelector,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
    }
}
