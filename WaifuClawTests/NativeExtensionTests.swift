import Foundation
import XCTest
@testable import WaifuClaw

@MainActor
final class NativeExtensionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testManifestValidationAcceptsOnlyBoundedDeclarativeHTTPSMetadata() throws {
        let manifest = makeManifest()
        XCTAssertNoThrow(try manifest.validate())

        var unsafeScheme = manifest
        unsafeScheme = ExtensionManifest(
            id: manifest.id,
            name: manifest.name,
            vendor: manifest.vendor,
            capabilities: manifest.capabilities,
            baseEndpoint: try XCTUnwrap(URL(string: "http://api.example.com")),
            actions: manifest.actions
        )
        XCTAssertThrowsError(try unsafeScheme.validate())

        let privateHost = ExtensionManifest(
            id: manifest.id,
            name: manifest.name,
            vendor: manifest.vendor,
            capabilities: manifest.capabilities,
            baseEndpoint: try XCTUnwrap(URL(string: "https://127.0.0.1")),
            actions: manifest.actions
        )
        XCTAssertThrowsError(try privateHost.validate())

        let credentialURL = ExtensionManifest(
            id: manifest.id,
            name: manifest.name,
            vendor: manifest.vendor,
            capabilities: manifest.capabilities,
            baseEndpoint: try XCTUnwrap(URL(string: "https://user:secret@api.example.com")),
            actions: manifest.actions
        )
        XCTAssertThrowsError(try credentialURL.validate())

        // A base endpoint may not carry a query/fragment redirect target. The
        // registry performs no HTTP request or redirect follow during import.
        let redirectURL = ExtensionManifest(
            id: manifest.id,
            name: manifest.name,
            vendor: manifest.vendor,
            capabilities: manifest.capabilities,
            baseEndpoint: try XCTUnwrap(URL(string: "https://api.example.com?next=https://private.example")),
            actions: manifest.actions
        )
        XCTAssertThrowsError(try redirectURL.validate())

        let redirectPath = ExtensionManifest(
            id: manifest.id,
            name: manifest.name,
            vendor: manifest.vendor,
            capabilities: manifest.capabilities,
            baseEndpoint: try XCTUnwrap(URL(string: "https://api.example.com/redirect")),
            actions: manifest.actions
        )
        XCTAssertThrowsError(try redirectPath.validate())

        let arbitraryPath = ExtensionManifest(
            id: manifest.id,
            name: manifest.name,
            vendor: manifest.vendor,
            capabilities: manifest.capabilities,
            baseEndpoint: manifest.baseEndpoint,
            actions: [ExtensionActionManifest(name: "read", path: "/../../private.txt", parameters: [])]
        )
        XCTAssertThrowsError(try arbitraryPath.validate())
    }

    func testJSONImportRejectsUndeclaredExecutableFields() throws {
        let registry = ExtensionRegistry(storageURL: try makeStorageURL())
        let manifestJSON = """
        {
          "schema": "waifuclaw.extension",
          "version": 1,
          "id": "com.example.tracker",
          "name": "Example Tracker",
          "vendor": "Example, Inc.",
          "capabilities": ["tickets.read"],
          "baseEndpoint": "https://api.example.com",
          "actions": [{"name": "list_tickets", "path": "/v1/tickets", "parameters": []}],
          "script": "console.log('not executable')"
        }
        """

        XCTAssertThrowsError(try registry.importManifest(data: Data(manifestJSON.utf8))) { error in
            XCTAssertEqual(error as? ExtensionRegistryError, .nonDeclarativeManifest)
        }
        XCTAssertTrue(registry.installedExtensions.isEmpty)
    }

    func testImportRejectsDuplicateIDsAndPersistsAcrossReload() throws {
        let storageURL = try makeStorageURL()
        let registry = ExtensionRegistry(storageURL: storageURL)
        let manifest = makeManifest()
        let manifestData = try JSONEncoder().encode(manifest)

        try registry.importManifest(data: manifestData)
        XCTAssertThrowsError(try registry.importManifest(manifest)) { error in
            XCTAssertEqual(error as? ExtensionRegistryError, .duplicateExtensionID(manifest.id))
        }
        try registry.setExtensionEnabled(manifest.id, isEnabled: false)

        let reopened = ExtensionRegistry(storageURL: storageURL)
        XCTAssertNil(reopened.persistenceError)
        XCTAssertEqual(reopened.installedExtensions.count, 1)
        XCTAssertEqual(reopened.installedExtensions.first?.manifest, manifest)
        XCTAssertEqual(reopened.installedExtensions.first?.isEnabled, false)
    }

    func testDisabledPluginDoesNotExposeADeclaredAction() throws {
        let registry = ExtensionRegistry(storageURL: try makeStorageURL())
        let manifest = makeManifest()
        try registry.importManifest(manifest)
        XCTAssertEqual(registry.declaredAction(pluginID: manifest.id, named: "create_ticket")?.path, "/v1/tickets")

        try registry.setExtensionEnabled(manifest.id, isEnabled: false)
        XCTAssertNil(registry.declaredAction(pluginID: manifest.id, named: "create_ticket"))

        // There is intentionally no invocation API to test: manifests are
        // registration data and the production registry has no HTTP client.
    }

    func testHookCreatesMarkerOnlyWhenEnabledAndDoesNotDuplicateRunEvent() throws {
        let registry = ExtensionRegistry(storageURL: try makeStorageURL())
        let projectID = "ios-project"
        let disabledRun = UUID()

        XCTAssertEqual(
            try registry.record(event: .runFinished, runID: disabledRun, projectID: projectID),
            []
        )
        XCTAssertTrue(registry.activities.isEmpty)

        try registry.setHookEnabled(.runFinished, isEnabled: true)
        let enabledRun = UUID()
        let created = try registry.record(event: .runFinished, runID: enabledRun, projectID: projectID)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.event, .runFinished)
        XCTAssertEqual(created.first?.action, .createLocalActivityMarker)
        XCTAssertEqual(created.first?.projectID, projectID)
        XCTAssertEqual(registry.activities(forProjectID: projectID).map(\.runID), [enabledRun])

        XCTAssertTrue(try registry.record(event: .runFinished, runID: enabledRun, projectID: projectID).isEmpty)
        XCTAssertEqual(registry.activities.count, 1)

        try registry.setHookEnabled(.runFinished, isEnabled: false)
        XCTAssertTrue(try registry.record(event: .runFinished, runID: UUID(), projectID: projectID).isEmpty)
        XCTAssertEqual(registry.activities.count, 1)
    }

    func testActivitiesRemainProjectIsolated() throws {
        let registry = ExtensionRegistry(storageURL: try makeStorageURL())
        try registry.setHookEnabled(.runFailed, isEnabled: true)
        let firstProject = "ios-project"
        let secondProject = "android-project"
        let firstRun = UUID()
        let secondRun = UUID()

        _ = try registry.record(event: .runFailed, runID: firstRun, projectID: firstProject)
        _ = try registry.record(event: .runFailed, runID: secondRun, projectID: secondProject)

        XCTAssertEqual(registry.activities(forProjectID: firstProject).map(\.runID), [firstRun])
        XCTAssertEqual(registry.activities(forProjectID: secondProject).map(\.runID), [secondRun])
        XCTAssertTrue(registry.activities(forProjectID: nil).isEmpty)
    }

    private func makeManifest(id: String = "com.example.tracker") -> ExtensionManifest {
        ExtensionManifest(
            id: id,
            name: "Example Tracker",
            vendor: "Example, Inc.",
            capabilities: ["tickets.read", "tickets.write"],
            baseEndpoint: URL(string: "https://api.example.com")!,
            actions: [
                ExtensionActionManifest(
                    name: "create_ticket",
                    path: "/v1/tickets",
                    parameters: [
                        ExtensionParameterSchema(name: "title", type: .string, required: true, maxLength: 200),
                        ExtensionParameterSchema(name: "priority", type: .string, required: false, enumValues: ["low", "normal", "high"])
                    ]
                )
            ]
        )
    }

    private func makeStorageURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("ExtensionRegistry.json", isDirectory: false)
    }
}
