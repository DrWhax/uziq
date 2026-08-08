import Foundation
import Security

struct KeychainWriteError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return "Could not save credentials in Keychain: \(detail) (\(status))"
    }
}
