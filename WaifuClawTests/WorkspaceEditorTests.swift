import Foundation
import XCTest
@testable import WaifuClaw

final class WorkspaceEditorTests: XCTestCase {
    func testTraversalAndSensitivePathsAreRejected() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        try "outside".write(
            to: outside.appendingPathComponent("outside.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "visible".write(
            to: root.appendingPathComponent("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "secret".write(
            to: root.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "private".write(
            to: root.appendingPathComponent("id_ed25519"),
            atomically: true,
            encoding: .utf8
        )

        let editor = try WorkspaceEditor(rootURL: root)
        XCTAssertEqual(try editor.readText(relativePath: "visible.txt").originalText, "visible")
        XCTAssertThrowsError(try editor.readText(relativePath: "../outside.txt")) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .invalidPath)
        }
        XCTAssertThrowsError(try editor.readText(relativePath: "/etc/passwd")) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .invalidPath)
        }
        XCTAssertThrowsError(try editor.readText(relativePath: ".env")) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .sensitivePath)
        }
        XCTAssertThrowsError(try editor.readText(relativePath: "id_ed25519")) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .sensitivePath)
        }
    }

    func testSymlinkEscapeIsNotBrowsableOrReadable() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        try "private".write(
            to: outside.appendingPathComponent("private.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let editor = try WorkspaceEditor(rootURL: root)
        XCTAssertFalse(try editor.listDirectory().entries.contains(where: { $0.name == "escape" }))
        XCTAssertThrowsError(try editor.readText(relativePath: "escape/private.txt")) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .outsideRoot)
        }
    }

    func testSaveDetectsConcurrentChangeBeforeOverwriting() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("note.txt")
        try "first".write(to: file, atomically: true, encoding: .utf8)
        let editor = try WorkspaceEditor(rootURL: root)
        let document = try editor.readText(relativePath: "note.txt")

        try "changed elsewhere".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try editor.save(document: document, draft: "my draft")) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .concurrentModification)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed elsewhere")
    }

    func testUndoRestoresLastSaveAndRefusesAChangedFile() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("note.txt")
        try "first".write(to: file, atomically: true, encoding: .utf8)
        let editor = try WorkspaceEditor(rootURL: root)
        let document = try editor.readText(relativePath: "note.txt")

        let save = try editor.save(document: document, draft: "second")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
        let restored = try editor.undoLastSave(save.undoRecord)
        XCTAssertEqual(restored.originalText, "first")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")

        let secondSave = try editor.save(document: restored, draft: "second")
        try "changed elsewhere".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try editor.undoLastSave(secondSave.undoRecord)) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .concurrentModification)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed elsewhere")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
