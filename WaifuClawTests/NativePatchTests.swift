import Foundation
import XCTest
@testable import WaifuClaw

/// Uses only temporary fixture folders and fixture text. No test invokes a
/// model, shell command, network API, or a real user workspace.
final class NativePatchTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testRejectsModelHashThatDoesNotMatchCurrentSnapshot() throws {
        let fixture = try makeFixtureProject(files: ["note.txt": "fixture before"])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let workflow = try makeWorkflow()

        let request = NativePatchToolRequest(
            runID: UUID(),
            projectID: project.projectID,
            relativePath: "note.txt",
            expectedSHA256: String(repeating: "0", count: 64),
            newText: "fixture after",
            reason: "Fixture replacement"
        )

        XCTAssertThrowsError(try workflow.proposeEdit(request, in: project)) { error in
            XCTAssertEqual(error as? NativePatchError, .expectedHashMismatch)
        }
        XCTAssertEqual(try read("note.txt", in: fixture), "fixture before")
        XCTAssertTrue(try workflow.pendingProposals(in: project).isEmpty)
    }

    func testTraversalIsRejectedBeforeAnyProposalIsPersisted() throws {
        let fixture = try makeFixtureProject(files: ["note.txt": "fixture before"])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let workflow = try makeWorkflow()
        let request = NativePatchToolRequest(
            runID: UUID(),
            projectID: project.projectID,
            relativePath: "../outside.txt",
            expectedSHA256: String(repeating: "0", count: 64),
            newText: "fixture after",
            reason: "Fixture traversal attempt"
        )

        XCTAssertThrowsError(try workflow.proposeEdit(request, in: project)) { error in
            XCTAssertEqual(error as? WorkspaceEditorError, .invalidPath)
        }
        XCTAssertTrue(try workflow.pendingProposals(in: project).isEmpty)
        XCTAssertEqual(try read("note.txt", in: fixture), "fixture before")
    }

    func testProposalDoesNotWriteBeforeApproval() throws {
        let fixture = try makeFixtureProject(files: ["note.txt": "fixture before"])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let workflow = try makeWorkflow()

        let proposal = try workflow.proposeEdit(
            request(for: project, path: "note.txt", original: "fixture before", replacement: "fixture after"),
            in: project
        )

        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(try read("note.txt", in: fixture), "fixture before")
        XCTAssertEqual(try workflow.pendingProposals(in: project).map(\.proposalID), [proposal.proposalID])
    }

    func testEveryChangedSourceAndReplacementLineMustFitApprovalPreview() throws {
        let original = Array(repeating: "one line", count: 101).joined(separator: "\n")
        let fixture = try makeFixtureProject(files: ["note.txt": original])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let workflow = try makeWorkflow()
        let request = NativePatchToolRequest(
            runID: UUID(),
            projectID: project.projectID,
            relativePath: "note.txt",
            expectedSHA256: NativePatchDigest.sha256(Data(original.utf8)),
            newText: "short replacement",
            reason: "Must not hide the other lines"
        )

        XCTAssertThrowsError(try workflow.proposeEdit(request, in: project)) { error in
            XCTAssertEqual(error as? NativePatchError, .tooManyLines)
        }
        XCTAssertEqual(try read("note.txt", in: fixture), original)
        XCTAssertTrue(try workflow.pendingProposals(in: project).isEmpty)
    }

    func testExplicitRejectionDoesNotWriteWorkspace() throws {
        let fixture = try makeFixtureProject(files: ["note.txt": "fixture before"])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let workflow = try makeWorkflow()
        let proposal = try workflow.proposeEdit(
            request(for: project, path: "note.txt", original: "fixture before", replacement: "fixture after"),
            in: project
        )

        let rejected = try workflow.reject(proposalID: proposal.proposalID, in: project)

        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(rejected.result?.kind, .rejected)
        XCTAssertEqual(try read("note.txt", in: fixture), "fixture before")
        XCTAssertTrue(try workflow.pendingProposals(in: project).isEmpty)
    }

    func testChangedBytesAfterProposalInvalidateWithoutOverwriting() throws {
        let fixture = try makeFixtureProject(files: ["note.txt": "fixture before"])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let workflow = try makeWorkflow()
        let proposal = try workflow.proposeEdit(
            request(for: project, path: "note.txt", original: "fixture before", replacement: "fixture after"),
            in: project
        )
        try write("changed by fixture", path: "note.txt", in: fixture)

        let outcome = try workflow.approveAndApply(proposalID: proposal.proposalID, in: project)

        XCTAssertFalse(outcome.didWriteWorkspace)
        XCTAssertEqual(outcome.proposal.status, .invalidated)
        XCTAssertEqual(outcome.proposal.result?.kind, .invalidated)
        XCTAssertEqual(try read("note.txt", in: fixture), "changed by fixture")
    }

    func testPendingProposalSurvivesStoreReopen() throws {
        let fixture = try makeFixtureProject(files: ["note.txt": "fixture before"])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let persistence = try makeTemporaryDirectory()
        let firstWorkflow = try NativePatchWorkflow(persistenceDirectoryURL: persistence)
        let proposal = try firstWorkflow.proposeEdit(
            request(for: project, path: "note.txt", original: "fixture before", replacement: "fixture after"),
            in: project
        )

        let reopenedWorkflow = try NativePatchWorkflow(persistenceDirectoryURL: persistence)
        let restored = try XCTUnwrap(reopenedWorkflow.proposal(id: proposal.proposalID, in: project))

        XCTAssertEqual(restored, proposal)
        XCTAssertEqual(try reopenedWorkflow.pendingProposals(in: project).map(\.proposalID), [proposal.proposalID])
    }

    func testPendingRecordDoesNotPersistOriginalFixtureSource() throws {
        let original = "ORIGINAL_FIXTURE_SOURCE_MUST_NOT_BE_PERSISTED"
        let replacement = "REPLACEMENT_FIXTURE_TEXT"
        let fixture = try makeFixtureProject(files: ["note.txt": original])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let persistence = try makeTemporaryDirectory()
        let workflow = try NativePatchWorkflow(persistenceDirectoryURL: persistence)

        _ = try workflow.proposeEdit(
            request(for: project, path: "note.txt", original: original, replacement: replacement),
            in: project
        )

        let jsonURLs = try FileManager.default.subpathsOfDirectory(atPath: persistence.path)
            .filter { $0.hasSuffix(".json") }
            .map { persistence.appendingPathComponent($0) }
        let persistedText = try jsonURLs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(persistedText.contains(original))
        XCTAssertTrue(persistedText.contains(replacement))
    }

    func testListingIsIsolatedToEachProjectIdentity() throws {
        let firstFixture = try makeFixtureProject(files: ["note.txt": "first fixture"])
        let secondFixture = try makeFixtureProject(files: ["note.txt": "second fixture"])
        let firstProject = try NativePatchProject(userSelectedFolderURL: firstFixture)
        let secondProject = try NativePatchProject(userSelectedFolderURL: secondFixture)
        let workflow = try makeWorkflow()

        let first = try workflow.proposeEdit(
            request(for: firstProject, path: "note.txt", original: "first fixture", replacement: "first updated"),
            in: firstProject
        )
        let second = try workflow.proposeEdit(
            request(for: secondProject, path: "note.txt", original: "second fixture", replacement: "second updated"),
            in: secondProject
        )

        XCTAssertNotEqual(firstProject.projectID, secondProject.projectID)
        XCTAssertEqual(try workflow.pendingProposals(in: firstProject).map(\.proposalID), [first.proposalID])
        XCTAssertEqual(try workflow.pendingProposals(in: secondProject).map(\.proposalID), [second.proposalID])
        XCTAssertNil(try workflow.proposal(id: second.proposalID, in: firstProject))
    }

    func testSafeApprovalDisplaysExactPathSavesAndUsesInMemoryUndo() throws {
        let fixture = try makeFixtureProject(files: ["Sources/todo.txt": "fixture before\n"])
        let project = try NativePatchProject(userSelectedFolderURL: fixture)
        let workflow = try makeWorkflow()
        let proposal = try workflow.proposeEdit(
            request(
                for: project,
                path: "Sources/todo.txt",
                original: "fixture before\n",
                replacement: "fixture after\n"
            ),
            in: project
        )

        let preview = try workflow.approvalPreview(proposalID: proposal.proposalID, in: project)
        XCTAssertTrue(preview.isCurrent)
        XCTAssertEqual(preview.relativePath, "Sources/todo.txt")
        XCTAssertFalse(preview.diffLines.isEmpty)
        XCTAssertEqual(try read("Sources/todo.txt", in: fixture), "fixture before\n")

        let applied = try workflow.approveAndApply(proposalID: proposal.proposalID, in: project)
        XCTAssertTrue(applied.didWriteWorkspace)
        XCTAssertEqual(applied.proposal.status, .applied)
        XCTAssertEqual(applied.proposal.result?.kind, .applied)
        XCTAssertEqual(try read("Sources/todo.txt", in: fixture), "fixture after\n")

        let undone = try workflow.undoLastApprovedSave(proposalID: proposal.proposalID, in: project)
        XCTAssertTrue(undone.didWriteWorkspace)
        XCTAssertEqual(undone.proposal.status, .undone)
        XCTAssertEqual(undone.proposal.result?.kind, .undone)
        XCTAssertEqual(try read("Sources/todo.txt", in: fixture), "fixture before\n")
    }

    private func request(
        for project: NativePatchProject,
        path: String,
        original: String,
        replacement: String
    ) -> NativePatchToolRequest {
        NativePatchToolRequest(
            runID: UUID(),
            projectID: project.projectID,
            relativePath: path,
            expectedSHA256: NativePatchDigest.sha256(Data(original.utf8)),
            newText: replacement,
            reason: "Fixture replacement"
        )
    }

    private func makeWorkflow() throws -> NativePatchWorkflow {
        try NativePatchWorkflow(persistenceDirectoryURL: try makeTemporaryDirectory())
    }

    private func makeFixtureProject(files: [String: String]) throws -> URL {
        let directory = try makeTemporaryDirectory()
        for (relativePath, text) in files {
            try write(text, path: relativePath, in: directory)
        }
        return directory
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ text: String, path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
