import Foundation

/// Protects on-device customer databases after the first device unlock. The
/// containing directory's protection class is also set so newly created SQLite
/// WAL/SHM sidecars inherit the same class. Simulator XCTest does not have a
/// hardware Data Protection guarantee; the signed-device gate must verify it.
enum NativeDatabaseProtection {
    static func prepareDirectory(_ directory: URL) throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        #endif
    }

    static func protectExistingFiles(at databaseURL: URL) throws {
        #if os(iOS) && !targetEnvironment(simulator)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"] {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
            }
        }
        #endif
    }
}
