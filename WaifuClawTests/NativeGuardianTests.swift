import Foundation
import XCTest
@testable import WaifuClaw

final class NativeGuardianTests: XCTestCase {
    func testRealFolderScanReportsAddedChangedAndDeletedFiles() throws {
        let project = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }

        try write("same\n", to: project.appendingPathComponent("same.txt"))
        try write("before\n", to: project.appendingPathComponent("changed.swift"))
        try write("remove me\n", to: project.appendingPathComponent("deleted.md"))

        let scanner = try NativeGuardianScanner(rootURL: project)
        let initial = try scanner.scan(baseline: nil)
        let baseline = NativeGuardianBaseline(files: initial.candidateFiles)

        try write("after\n", to: project.appendingPathComponent("changed.swift"))
        try FileManager.default.removeItem(at: project.appendingPathComponent("deleted.md"))
        try write("new file\n", to: project.appendingPathComponent("added.json"))

        let review = try scanner.scan(baseline: baseline)
        XCTAssertEqual(review.addedCount, 1)
        XCTAssertEqual(review.changedCount, 1)
        XCTAssertEqual(review.deletedCount, 1)

        let changes = Dictionary(uniqueKeysWithValues: review.changes.map { ($0.relativePath, $0) })
        let added = try XCTUnwrap(changes["added.json"])
        XCTAssertEqual(added.kind, .added)
        XCTAssertNil(added.previousSHA256)
        XCTAssertNotNil(added.currentSHA256)
        XCTAssertEqual(added.currentByteCount, Data("new file\n".utf8).count)

        let changed = try XCTUnwrap(changes["changed.swift"])
        XCTAssertEqual(changed.kind, .changed)
        XCTAssertNotEqual(changed.previousSHA256, changed.currentSHA256)
        XCTAssertEqual(changed.previousByteCount, Data("before\n".utf8).count)
        XCTAssertEqual(changed.currentByteCount, Data("after\n".utf8).count)

        let deleted = try XCTUnwrap(changes["deleted.md"])
        XCTAssertEqual(deleted.kind, .deleted)
        XCTAssertNotNil(deleted.previousSHA256)
        XCTAssertNil(deleted.currentSHA256)
        XCTAssertEqual(deleted.previousByteCount, Data("remove me\n".utf8).count)
        XCTAssertNil(deleted.currentByteCount)
    }

    func testSensitivePathsAreNeverInventoriedFromRealFolder() throws {
        let project = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }

        try write("safe\n", to: project.appendingPathComponent("Sources/Visible.swift"))
        try write("config\n", to: project.appendingPathComponent(".git/config"))
        try write("secret\n", to: project.appendingPathComponent(".env"))
        try write("local secret\n", to: project.appendingPathComponent(".env.local"))
        try write("secret\n", to: project.appendingPathComponent("credentials"))
        try write("secret json\n", to: project.appendingPathComponent("credentials.json"))
        try write("nested secret\n", to: project.appendingPathComponent("Nested/credentials/token.txt"))

        let review = try NativeGuardianScanner(rootURL: project).scan(baseline: nil)
        XCTAssertEqual(review.candidateFiles.map(\.relativePath), ["Sources/Visible.swift"])
        XCTAssertFalse(review.candidateFiles.contains(where: { $0.relativePath.contains(".env") }))
        XCTAssertFalse(review.candidateFiles.contains(where: { $0.relativePath.contains("credential") }))
        XCTAssertFalse(review.candidateFiles.contains(where: { $0.relativePath.contains(".git") }))
    }

    func testPreviouslyTrackedFileBecomingSymlinkFailsClosed() throws {
        let project = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: outside)
        }
        let tracked = project.appendingPathComponent("Tracked.swift")
        try write("let safe = true\n", to: tracked)
        let scanner = try NativeGuardianScanner(rootURL: project)
        let baseline = NativeGuardianBaseline(files: try scanner.scan(baseline: nil).candidateFiles)
        let privateFile = outside.appendingPathComponent("Private.swift")
        try write("let secret = true\n", to: privateFile)
        try FileManager.default.removeItem(at: tracked)
        try FileManager.default.createSymbolicLink(at: tracked, withDestinationURL: privateFile)

        XCTAssertThrowsError(try scanner.scan(baseline: baseline)) { error in
            guard case NativeGuardianError.trackedFileCannotBeRead = error else {
                return XCTFail("A symlinked tracked file must not be read or reported deleted: \(error)")
            }
        }
    }

    func testProjectSnapshotsAreIsolatedOnDisk() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProject = root.appendingPathComponent("first", isDirectory: true)
        let secondProject = root.appendingPathComponent("second", isDirectory: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        try write("first\n", to: firstProject.appendingPathComponent("one.txt"))
        try write("second\n", to: secondProject.appendingPathComponent("two.txt"))

        let store = try NativeGuardianStore(rootDirectory: history)
        let firstID = NativeProjectIdentity.id(for: firstProject)
        let secondID = NativeProjectIdentity.id(for: secondProject)
        XCTAssertNotEqual(firstID, secondID)

        let firstReview = try NativeGuardianScanner(rootURL: firstProject).scan(baseline: nil)
        _ = try store.recordReview(firstReview, for: firstID)
        let firstSnapshot = try store.approveBaseline(projectID: firstID, reviewID: firstReview.id)
        XCTAssertEqual(firstSnapshot.baseline?.files.map(\.relativePath), ["one.txt"])

        XCTAssertNil(try store.load(projectID: secondID))
        let secondReview = try NativeGuardianScanner(rootURL: secondProject).scan(baseline: nil)
        _ = try store.recordReview(secondReview, for: secondID)
        let secondSnapshot = try store.approveBaseline(projectID: secondID, reviewID: secondReview.id)
        XCTAssertEqual(secondSnapshot.baseline?.files.map(\.relativePath), ["two.txt"])

        XCTAssertEqual(try store.load(projectID: firstID)?.baseline?.files.map(\.relativePath), ["one.txt"])
        XCTAssertEqual(try store.load(projectID: secondID)?.baseline?.files.map(\.relativePath), ["two.txt"])
        XCTAssertNotEqual(try store.fileURL(forProjectID: firstID), try store.fileURL(forProjectID: secondID))
    }

    func testMalformedStateFailsClosedUntilHistoryIsDeleted() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write("real local file\n", to: project.appendingPathComponent("notes.txt"))

        let store = try NativeGuardianStore(rootDirectory: history)
        let projectID = NativeProjectIdentity.id(for: project)
        let malformedURL = try store.fileURL(forProjectID: projectID)
        try FileManager.default.createDirectory(at: malformedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not valid JSON".utf8).write(to: malformedURL)

        XCTAssertThrowsError(try store.load(projectID: projectID)) { error in
            guard let guardianError = error as? NativeGuardianError,
                  case .corruptState = guardianError else {
                return XCTFail("Expected corrupt Guardian state, got \(error)")
            }
        }

        let realReview = try NativeGuardianScanner(rootURL: project).scan(baseline: nil)
        XCTAssertThrowsError(try store.recordReview(realReview, for: projectID)) { error in
            guard let guardianError = error as? NativeGuardianError,
                  case .corruptState = guardianError else {
                return XCTFail("Corrupt state must not be overwritten, got \(error)")
            }
        }

        try store.deleteHistory(projectID: projectID)
        XCTAssertNil(try store.load(projectID: projectID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-guardian-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
