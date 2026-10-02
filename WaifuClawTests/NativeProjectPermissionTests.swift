import Foundation
import XCTest
@testable import WaifuClaw

final class NativeProjectPermissionTests: XCTestCase {
    func testSelectedProjectBookmarkPersistsAndForgettingKeepsFiles() throws {
        let suiteName = "project-permission-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let permission = NativeProjectPermission(defaults: defaults)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try "local only".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertNil(try permission.selectedFolder())
        XCTAssertEqual(try permission.selectFolder(folder), folder.lastPathComponent)
        XCTAssertEqual(try permission.selectedFolder()?.standardizedFileURL.path,
                       folder.standardizedFileURL.path)
        permission.disconnectFolder()
        XCTAssertNil(try permission.selectedFolder())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "local only")
    }

    func testInvalidFolderDoesNotReplaceAnExistingGrant() throws {
        let suiteName = "project-permission-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let permission = NativeProjectPermission(defaults: defaults)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try permission.selectFolder(folder)
        XCTAssertThrowsError(try permission.selectFolder(folder.appendingPathComponent("missing")))
        XCTAssertEqual(try permission.selectedFolder()?.standardizedFileURL.path,
                       folder.standardizedFileURL.path)
    }
}
