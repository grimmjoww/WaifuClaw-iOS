import CryptoKit
import Foundation

/// Stable local namespace for an explicitly selected Files folder. No raw path
/// or bookmark bytes are stored in a memory graph project identifier.
enum NativeProjectIdentity {
    static func id(for folderURL: URL) -> String {
        let canonical = folderURL.standardizedFileURL.absoluteString
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
