import Foundation
import XCTest
@testable import WaifuClaw

final class NativeGitTests: XCTestCase {
    func testAcceptsPublicHTTPSRepositoryURL() throws {
        let url = try NativeGitURLValidator.validatedRemoteURL("https://github.com/example/repository.git")

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(NativeGitDestinationValidator.suggestedDirectoryName(for: url), "repository")
    }

    func testRejectsInsecureLocalCredentialedAndNonRepositoryURLs() {
        let rejected = [
            "http://github.com/example/repository.git",
            "ssh://git@github.com/example/repository.git",
            "https://token@github.com/example/repository.git",
            "https://localhost/example/repository.git",
            "https://127.0.0.1/example/repository.git",
            "https://github.com/",
            "https://github.com/example/repository.git?token=secret",
            "https://github.com/example/repository.git#main"
        ]

        for value in rejected {
            XCTAssertThrowsError(try NativeGitURLValidator.validatedRemoteURL(value), value)
        }
    }

    func testRejectsUnsafeDestinationNames() {
        for value in ["", ".", "..", "../escape", "nested/folder", "has space", "repo;rm"] {
            XCTAssertThrowsError(try NativeGitDestinationValidator.validatedDirectoryName(value), value)
        }
        XCTAssertEqual(try NativeGitDestinationValidator.validatedDirectoryName("safe_repo-1.0"), "safe_repo-1.0")
    }

    func testMetadataRoundTripPersistsOnlyCloneMetadata() throws {
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent("clones.json")
        let store = try NativeGitMetadataStore(fileURL: file)
        let record = NativeGitCloneRecord(
            remoteURL: "https://github.com/example/repository.git",
            directoryName: "repository",
            location: .appSupport
        )

        try store.save([record])
        let loaded = try store.load()

        XCTAssertEqual(loaded, [record])
        let serialized = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("apiKey"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
