import Foundation
import XCTest
@testable import WaifuClaw

final class ScopedWorkspaceTests: XCTestCase {
    func testReadsOnlySelectedProjectText() throws {
        let root = try temporaryDirectory()
        try "struct Example {}".write(to: root.appendingPathComponent("Example.swift"), atomically: true, encoding: .utf8)
        let workspace = try ScopedWorkspace(rootURL: root)

        XCTAssertEqual(try workspace.listFiles(), ["Example.swift"])
        XCTAssertEqual(try workspace.readFile(relativePath: "Example.swift"), "struct Example {}")
        XCTAssertThrowsError(try workspace.readFile(relativePath: "../Example.swift"))
        XCTAssertThrowsError(try workspace.readFile(relativePath: "/etc/passwd"))
    }

    func testSymlinkCannotEscapeSelectedFolder() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        try "private".write(to: outside.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let workspace = try ScopedWorkspace(rootURL: root)
        XCTAssertThrowsError(try workspace.readFile(relativePath: "escape/private.txt"))
    }

    func testSecretNamesAndOversizedFilesAreNotRead() throws {
        let root = try temporaryDirectory()
        try "secret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try Data(repeating: 65, count: 128 * 1024 + 1).write(to: root.appendingPathComponent("big.txt"))
        let workspace = try ScopedWorkspace(rootURL: root)

        XCTAssertThrowsError(try workspace.readFile(relativePath: ".env"))
        XCTAssertThrowsError(try workspace.readFile(relativePath: "big.txt"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
