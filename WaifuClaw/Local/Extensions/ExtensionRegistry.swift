import Combine
import Foundation

public enum ExtensionRegistryError: Error, LocalizedError, Equatable {
    case manifestTooLarge
    case importRequiresRegularFile
    case duplicateExtensionID(String)
    case extensionNotFound(String)
    case nonDeclarativeManifest
    case storageVersionUnsupported
    case corruptPersistedState

    public var errorDescription: String? {
        switch self {
        case .manifestTooLarge:
            return "Extension manifest files are limited to 256 KB."
        case .importRequiresRegularFile:
            return "Choose a JSON manifest file from Files."
        case .duplicateExtensionID:
            return "An extension with that identifier is already installed."
        case .extensionNotFound:
            return "The extension is no longer installed."
        case .nonDeclarativeManifest:
            return "The manifest contains fields outside the declarative extension schema."
        case .storageVersionUnsupported:
            return "The saved extension registry uses an unsupported version."
        case .corruptPersistedState:
            return "The saved extension registry could not be validated."
        }
    }
}

/// App-owned registry for declarative extension manifests and bounded local
/// hooks. It has no URLSession, JavaScript, shell, dynamic-library, Git-hook,
/// or downloaded-code execution path. A declared action is metadata only.
@MainActor
public final class ExtensionRegistry: ObservableObject {
    public static let maximumManifestBytes = 256 * 1_024
    public static let maximumActivities = 250

    @Published public private(set) var installedExtensions: [InstalledExtension]
    @Published public private(set) var hookRules: [ExtensionHookRule]
    @Published public private(set) var activities: [ExtensionActivity]
    @Published public private(set) var persistenceError: String?

    public let storageURL: URL

    private var persistedState: ExtensionRegistryState
    private let fileManager: FileManager

    /// Creates a registry backed by one JSON file in Application Support.
    /// A persistence error is surfaced to the view; an unreadable file is never
    /// overwritten automatically.
    public init(
        storageURL: URL = ExtensionRegistry.defaultStorageURL(),
        fileManager: FileManager = .default
    ) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        let initialState = ExtensionRegistryState.empty
        self.persistedState = initialState
        self.installedExtensions = initialState.installedExtensions
        self.hookRules = initialState.hookRules
        self.activities = initialState.activities
        self.persistenceError = nil
        restorePersistedStateIfPresent()
    }

    /// Imports JSON selected by the user through a file importer. The URL is
    /// read once and only as data; it is not retained, executed, or opened as a
    /// project/workspace path.
    public func importManifest(fromFileURL fileURL: URL) throws {
        guard fileURL.isFileURL else {
            throw ExtensionRegistryError.importRequiresRegularFile
        }

        let didAccessSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ExtensionRegistryError.importRequiresRegularFile
        }
        guard (values.fileSize ?? 0) <= Self.maximumManifestBytes else {
            throw ExtensionRegistryError.manifestTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try importManifest(data: data)
    }

    /// Decodes, validates, and stores a manifest supplied as JSON data.
    public func importManifest(data: Data) throws {
        guard data.count <= Self.maximumManifestBytes else {
            throw ExtensionRegistryError.manifestTooLarge
        }
        try Self.validateManifestJSONShape(data)
        let manifest = try Self.manifestDecoder.decode(ExtensionManifest.self, from: data)
        try importManifest(manifest)
    }

    /// Validates and stores an already decoded manifest. This is useful for a
    /// trusted in-app editor or tests; it still cannot register executable code.
    public func importManifest(_ manifest: ExtensionManifest) throws {
        try manifest.validate()
        guard !installedExtensions.contains(where: { $0.id == manifest.id }) else {
            throw ExtensionRegistryError.duplicateExtensionID(manifest.id)
        }

        var next = persistedState
        next.installedExtensions.append(InstalledExtension(manifest: manifest))
        try persist(next)
        publish(next)
    }

    /// Explicitly enables or disables a registration. Disabled registrations do
    /// not expose any declarative action through `declaredAction`.
    public func setExtensionEnabled(_ extensionID: String, isEnabled: Bool) throws {
        var next = persistedState
        guard let index = next.installedExtensions.firstIndex(where: { $0.id == extensionID }) else {
            throw ExtensionRegistryError.extensionNotFound(extensionID)
        }
        next.installedExtensions[index].isEnabled = isEnabled
        try persist(next)
        publish(next)
    }

    /// Removes a registration and its manifest from this device. It does not
    /// make a network request or notify the vendor.
    public func removeExtension(_ extensionID: String) throws {
        var next = persistedState
        guard let index = next.installedExtensions.firstIndex(where: { $0.id == extensionID }) else {
            throw ExtensionRegistryError.extensionNotFound(extensionID)
        }
        next.installedExtensions.remove(at: index)
        try persist(next)
        publish(next)
    }

    /// Returns registration metadata only when the plugin is enabled. This is
    /// deliberately not an invocation API and never issues an HTTP request.
    public func declaredAction(pluginID: String, named actionName: String) -> ExtensionActionManifest? {
        guard let plugin = installedExtensions.first(where: { $0.id == pluginID && $0.isEnabled }) else {
            return nil
        }
        return plugin.manifest.actions.first(where: { $0.name == actionName })
    }

    public func hookRule(for event: HookEvent) -> ExtensionHookRule {
        hookRules.first(where: { $0.event == event }) ?? ExtensionHookRule(event: event)
    }

    /// Explicitly changes one of the two fixed local hook rules. Callers cannot
    /// introduce a new event or action through this API.
    public func setHookEnabled(_ event: HookEvent, isEnabled: Bool) throws {
        var next = persistedState
        guard let index = next.hookRules.firstIndex(where: { $0.event == event }) else {
            throw ExtensionRegistryError.corruptPersistedState
        }
        next.hookRules[index].isEnabled = isEnabled
        try persist(next)
        publish(next)
    }

    /// Call this after the app has recorded a real terminal run event. For every
    /// enabled matching rule, this creates at most one local marker for the
    /// (event, run, project) tuple. It never invokes a plugin or external URL.
    @discardableResult
    public func record(
        event: HookEvent,
        runID: UUID,
        projectID: String? = nil,
        occurredAt: Date = Date()
    ) throws -> [ExtensionActivity] {
        let enabledRules = hookRules.filter {
            $0.event == event && $0.action == .createLocalActivityMarker && $0.isEnabled
        }
        guard !enabledRules.isEmpty else { return [] }

        var next = persistedState
        var created: [ExtensionActivity] = []
        for rule in enabledRules {
            let exists = next.activities.contains {
                $0.ruleID == rule.id &&
                $0.event == event &&
                $0.runID == runID &&
                $0.projectID == projectID
            }
            guard !exists else { continue }
            let marker = ExtensionActivity(
                ruleID: rule.id,
                event: event,
                action: .createLocalActivityMarker,
                runID: runID,
                projectID: projectID,
                message: event.activityMessage,
                createdAt: occurredAt
            )
            next.activities.insert(marker, at: 0)
            created.append(marker)
        }
        guard !created.isEmpty else { return [] }

        if next.activities.count > Self.maximumActivities {
            next.activities.removeLast(next.activities.count - Self.maximumActivities)
        }
        try persist(next)
        publish(next)
        return created
    }

    /// Returns only markers for one project. Passing `nil` returns only markers
    /// that were recorded without a project identifier; it never returns every
    /// project's markers as a fallback.
    public func activities(forProjectID projectID: String?) -> [ExtensionActivity] {
        activities.filter { $0.projectID == projectID }
    }

    /// Refreshes the view's in-memory registry after another app tab records a
    /// real run hook. Existing on-disk state is never replaced on a read error.
    public func reloadFromDisk() {
        restorePersistedStateIfPresent()
    }

    // MARK: - Local persistence

    private func restorePersistedStateIfPresent() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL, options: .mappedIfSafe)
            let decoded = try Self.stateDecoder.decode(ExtensionRegistryState.self, from: data)
            let validated = try Self.validatePersistedState(decoded)
            publish(validated)
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func persist(_ state: ExtensionRegistryState) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.stateEncoder.encode(state)
        try data.write(to: storageURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: storageURL.path
        )
    }

    private func publish(_ state: ExtensionRegistryState) {
        persistedState = state
        installedExtensions = state.installedExtensions
        hookRules = state.hookRules
        activities = state.activities
        persistenceError = nil
    }

    private static func validatePersistedState(_ state: ExtensionRegistryState) throws -> ExtensionRegistryState {
        guard state.storageVersion == ExtensionRegistryState.currentVersion,
              state.installedExtensions.count <= 64,
              state.activities.count <= maximumActivities,
              Set(state.installedExtensions.map(\.id)).count == state.installedExtensions.count,
              Set(state.activities.map(\.id)).count == state.activities.count
        else {
            throw ExtensionRegistryError.corruptPersistedState
        }
        try state.installedExtensions.forEach { try $0.manifest.validate() }

        // Persisted hooks are normalized to the app's fixed event/action list.
        // Unknown hooks in a tampered or future file are ignored, not activated.
        let normalizedRules = ExtensionHookRule.defaults.map { defaultRule in
            let enabled = state.hookRules.first {
                $0.id == defaultRule.id &&
                $0.event == defaultRule.event &&
                $0.action == defaultRule.action
            }?.isEnabled ?? false
            return ExtensionHookRule(event: defaultRule.event, action: defaultRule.action, isEnabled: enabled)
        }
        let knownRuleIDs = Set(normalizedRules.map(\.id))
        guard state.activities.allSatisfy({ activity in
            activity.action == .createLocalActivityMarker &&
            knownRuleIDs.contains(activity.ruleID) &&
            activity.message == activity.event.activityMessage &&
            activity.message.utf8.count <= 256
        }) else {
            throw ExtensionRegistryError.corruptPersistedState
        }

        return ExtensionRegistryState(
            storageVersion: state.storageVersion,
            installedExtensions: state.installedExtensions,
            hookRules: normalizedRules,
            activities: state.activities
        )
    }

    private static var manifestDecoder: JSONDecoder {
        JSONDecoder()
    }

    /// `Codable` intentionally ignores unknown JSON keys by default. Manifest
    /// import does not: a schema document may contain only data this release
    /// explicitly understands, so fields such as `script`, `file`, `dylib`, or
    /// `hook` are rejected rather than silently retained or normalized.
    private static func validateManifestJSONShape(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let manifest = object as? [String: Any] else {
            throw ExtensionRegistryError.nonDeclarativeManifest
        }
        try validateKeys(
            manifest,
            allowed: ["schema", "version", "id", "name", "vendor", "capabilities", "baseEndpoint", "actions"]
        )

        if let actions = manifest["actions"] as? [Any] {
            for actionValue in actions {
                guard let action = actionValue as? [String: Any] else { continue }
                try validateKeys(action, allowed: ["name", "path", "parameters"])
                if let parameters = action["parameters"] as? [Any] {
                    for parameterValue in parameters {
                        guard let parameter = parameterValue as? [String: Any] else { continue }
                        try validateKeys(
                            parameter,
                            allowed: ["name", "type", "required", "maxLength", "enumValues"]
                        )
                    }
                }
            }
        }
    }

    private static func validateKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw ExtensionRegistryError.nonDeclarativeManifest
        }
    }

    private static var stateDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static var stateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WaifuClaw", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent("registry.json", isDirectory: false)
    }
}

private struct ExtensionRegistryState: Codable {
    static let currentVersion = 1

    let storageVersion: Int
    var installedExtensions: [InstalledExtension]
    var hookRules: [ExtensionHookRule]
    var activities: [ExtensionActivity]

    static let empty = ExtensionRegistryState(
        storageVersion: currentVersion,
        installedExtensions: [],
        hookRules: ExtensionHookRule.defaults,
        activities: []
    )
}
