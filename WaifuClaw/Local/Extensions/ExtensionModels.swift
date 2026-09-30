import Foundation

/// The only accepted schema identifier for a user-imported extension manifest.
///
/// Manifests are declarative registration data. They cannot supply scripts,
/// libraries, shell commands, JavaScript, or a callback to execute.
public struct ExtensionManifest: Codable, Identifiable, Equatable, Hashable, Sendable {
    public static let supportedSchema = "waifuclaw.extension"
    public static let supportedVersion = 1

    public let schema: String
    public let version: Int
    public let id: String
    public let name: String
    public let vendor: String
    public let capabilities: [String]
    public let baseEndpoint: URL
    public let actions: [ExtensionActionManifest]

    public init(
        schema: String = ExtensionManifest.supportedSchema,
        version: Int = ExtensionManifest.supportedVersion,
        id: String,
        name: String,
        vendor: String,
        capabilities: [String],
        baseEndpoint: URL,
        actions: [ExtensionActionManifest]
    ) {
        self.schema = schema
        self.version = version
        self.id = id
        self.name = name
        self.vendor = vendor
        self.capabilities = capabilities
        self.baseEndpoint = baseEndpoint
        self.actions = actions
    }

    /// Checks that an imported document is a bounded, declarative manifest.
    /// This deliberately performs no DNS, HTTP, redirect, or plugin execution.
    public func validate() throws {
        guard schema == Self.supportedSchema else {
            throw ExtensionManifestValidationError.unsupportedSchema(schema)
        }
        guard version == Self.supportedVersion else {
            throw ExtensionManifestValidationError.unsupportedVersion(version)
        }
        guard ExtensionManifestValidation.isIdentifier(id, maximumLength: 96) else {
            throw ExtensionManifestValidationError.invalidIdentifier(id)
        }
        guard ExtensionManifestValidation.isDisplayText(name, maximumLength: 80) else {
            throw ExtensionManifestValidationError.invalidName
        }
        guard ExtensionManifestValidation.isDisplayText(vendor, maximumLength: 120) else {
            throw ExtensionManifestValidationError.invalidVendor
        }
        guard !capabilities.isEmpty, capabilities.count <= 16 else {
            throw ExtensionManifestValidationError.invalidCapabilities
        }
        guard Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(ExtensionManifestValidation.isCapability)
        else {
            throw ExtensionManifestValidationError.invalidCapabilities
        }

        try ExtensionManifestValidation.validateBaseEndpoint(baseEndpoint)

        guard !actions.isEmpty, actions.count <= 32 else {
            throw ExtensionManifestValidationError.invalidActions
        }
        guard Set(actions.map(\.name)).count == actions.count else {
            throw ExtensionManifestValidationError.duplicateActionName
        }
        try actions.forEach { try $0.validate() }
    }
}

/// A fixed, declarative action description. There is intentionally no method
/// here (or in `ExtensionRegistry`) that turns this data into executable code
/// or a network request.
public struct ExtensionActionManifest: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let parameters: [ExtensionParameterSchema]

    public var id: String { name }

    public init(name: String, path: String, parameters: [ExtensionParameterSchema]) {
        self.name = name
        self.path = path
        self.parameters = parameters
    }

    fileprivate func validate() throws {
        guard ExtensionManifestValidation.isIdentifier(name, maximumLength: 64) else {
            throw ExtensionManifestValidationError.invalidActionName(name)
        }
        guard ExtensionManifestValidation.isSafeActionPath(path) else {
            throw ExtensionManifestValidationError.invalidActionPath(path)
        }
        guard parameters.count <= 16,
              Set(parameters.map(\.name)).count == parameters.count
        else {
            throw ExtensionManifestValidationError.invalidParameterSchema
        }
        try parameters.forEach { try $0.validate() }
    }
}

/// The allowed JSON primitive types for a plugin action parameter. Objects,
/// arrays, files, and executable values are not part of this first slice.
public enum ExtensionParameterType: String, Codable, CaseIterable, Sendable {
    case string
    case integer
    case number
    case boolean
}

/// A bounded schema for one named action parameter.
public struct ExtensionParameterSchema: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let type: ExtensionParameterType
    public let required: Bool
    public let maxLength: Int?
    public let enumValues: [String]?

    public init(
        name: String,
        type: ExtensionParameterType,
        required: Bool,
        maxLength: Int? = nil,
        enumValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.maxLength = maxLength
        self.enumValues = enumValues
    }

    fileprivate func validate() throws {
        guard ExtensionManifestValidation.isIdentifier(name, maximumLength: 64) else {
            throw ExtensionManifestValidationError.invalidParameterSchema
        }
        if let maxLength {
            guard type == .string, (1...4_096).contains(maxLength) else {
                throw ExtensionManifestValidationError.invalidParameterSchema
            }
        }
        if let enumValues {
            guard type == .string,
                  !enumValues.isEmpty,
                  enumValues.count <= 32,
                  Set(enumValues).count == enumValues.count,
                  enumValues.allSatisfy({ ExtensionManifestValidation.isDisplayText($0, maximumLength: 256) })
            else {
                throw ExtensionManifestValidationError.invalidParameterSchema
            }
        }
    }
}

public enum ExtensionManifestValidationError: Error, Equatable, LocalizedError {
    case unsupportedSchema(String)
    case unsupportedVersion(Int)
    case invalidIdentifier(String)
    case invalidName
    case invalidVendor
    case invalidCapabilities
    case unsafeBaseEndpoint(String)
    case invalidActions
    case duplicateActionName
    case invalidActionName(String)
    case invalidActionPath(String)
    case invalidParameterSchema

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            return "This file is not a WaifuClaw extension manifest."
        case .unsupportedVersion:
            return "This extension manifest version is not supported."
        case .invalidIdentifier:
            return "The extension identifier is invalid."
        case .invalidName:
            return "The extension name is invalid."
        case .invalidVendor:
            return "The extension vendor is invalid."
        case .invalidCapabilities:
            return "The extension capabilities must be a unique, bounded list."
        case .unsafeBaseEndpoint:
            return "The extension endpoint must be a public HTTPS origin without credentials, paths, queries, fragments, or a private/local host."
        case .invalidActions:
            return "The extension must declare a bounded list of actions."
        case .duplicateActionName:
            return "Each extension action name must be unique."
        case .invalidActionName:
            return "An extension action name is invalid."
        case .invalidActionPath:
            return "An extension action path is invalid."
        case .invalidParameterSchema:
            return "An extension action parameter schema is invalid."
        }
    }
}

/// The two local run lifecycle events that can be configured in this vertical
/// slice. These are received only when the host app explicitly calls the
/// registry after a real local run event; no listener or background service is
/// started by this type.
public enum HookEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case runFinished = "run.finished"
    case runFailed = "run.failed"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .runFinished: return "Run finished"
        case .runFailed: return "Run failed"
        }
    }

    var activityMessage: String {
        switch self {
        case .runFinished: return "A local agent run finished."
        case .runFailed: return "A local agent run failed."
        }
    }
}

/// The only hook action implemented in the app. It never calls a plugin or
/// network endpoint; it appends a local activity record.
public enum LocalHookAction: String, Codable, CaseIterable, Sendable {
    case createLocalActivityMarker = "create.local.activity.marker"
}

/// A user-configurable, app-owned rule. Rule identifiers are derived from a
/// fixed event/action pair, so an imported document cannot create new hooks.
public struct ExtensionHookRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let event: HookEvent
    public let action: LocalHookAction
    public var isEnabled: Bool

    public init(event: HookEvent, action: LocalHookAction = .createLocalActivityMarker, isEnabled: Bool = false) {
        self.id = Self.identifier(event: event, action: action)
        self.event = event
        self.action = action
        self.isEnabled = isEnabled
    }

    public static func identifier(event: HookEvent, action: LocalHookAction) -> String {
        "hook.\(event.rawValue).\(action.rawValue)"
    }

    static var defaults: [ExtensionHookRule] {
        HookEvent.allCases.map { ExtensionHookRule(event: $0) }
    }
}

/// An auditable marker made by the bounded local hook action. Activities carry
/// a project identifier when the host has one, and should be queried through
/// `ExtensionRegistry.activities(forProjectID:)` to preserve project isolation.
public struct ExtensionActivity: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let ruleID: String
    public let event: HookEvent
    public let action: LocalHookAction
    public let runID: UUID
    public let projectID: String?
    public let message: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        ruleID: String,
        event: HookEvent,
        action: LocalHookAction,
        runID: UUID,
        projectID: String?,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.ruleID = ruleID
        self.event = event
        self.action = action
        self.runID = runID
        self.projectID = projectID
        self.message = message
        self.createdAt = createdAt
    }
}

/// The locally persisted representation of a registered manifest.
public struct InstalledExtension: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let manifest: ExtensionManifest
    public var isEnabled: Bool
    public let importedAt: Date

    public var id: String { manifest.id }

    public init(manifest: ExtensionManifest, isEnabled: Bool = true, importedAt: Date = Date()) {
        self.manifest = manifest
        self.isEnabled = isEnabled
        self.importedAt = importedAt
    }
}

private enum ExtensionManifestValidation {
    static func isIdentifier(_ value: String, maximumLength: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLength,
              let first = bytes.first, isLowercaseLetter(first)
        else { return false }
        return bytes.allSatisfy { isLowercaseLetter($0) || isDigit($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    static func isCapability(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 96,
              let first = bytes.first, isLowercaseLetter(first)
        else { return false }
        var previousWasDot = false
        for byte in bytes {
            guard isLowercaseLetter(byte) || isDigit(byte) || byte == 46 else { return false }
            if byte == 46, previousWasDot { return false }
            previousWasDot = byte == 46
        }
        return !previousWasDot
    }

    static func isDisplayText(_ value: String, maximumLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumLength else { return false }
        return !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func isSafeActionPath(_ path: String) -> Bool {
        guard path.utf8.count <= 512,
              path.hasPrefix("/"),
              path != "/",
              !path.contains("//"),
              !path.contains("\\"),
              !path.contains("%"),
              !path.contains("?"),
              !path.contains("#")
        else { return false }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        guard path.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }

    static func validateBaseEndpoint(_ endpoint: URL) throws {
        guard endpoint.absoluteString.utf8.count <= 2_048,
              endpoint.scheme?.lowercased() == "https",
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.port == nil || endpoint.port == 443,
              let host = endpoint.host?.lowercased(),
              isPublicDNSHostname(host),
              isSafeBasePath(endpoint.path)
        else {
            throw ExtensionManifestValidationError.unsafeBaseEndpoint(endpoint.absoluteString)
        }
    }

    /// Accept DNS hostnames only. Rejecting all literal addresses avoids
    /// accepting loopback, link-local, RFC1918, carrier-grade NAT, or IPv6
    /// local literals, and leaves no IP-literal bypass for the private-host
    /// checks below. Registration makes no connection to the hostname.
    static func isPublicDNSHostname(_ host: String) -> Bool {
        guard host.utf8.count <= 253,
              host.contains("."),
              !host.hasSuffix("."),
              host != "localhost",
              host != "localdomain",
              host != "home.arpa",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !host.hasSuffix(".lan"),
              !host.hasSuffix(".home.arpa"),
              !host.contains(":"),
              !host.allSatisfy({ $0 == "." || $0.isNumber })
        else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  let first = label.utf8.first, let last = label.utf8.last,
                  isLowercaseLetter(first) || isDigit(first),
                  isLowercaseLetter(last) || isDigit(last)
            else { return false }
            return label.utf8.allSatisfy { isLowercaseLetter($0) || isDigit($0) || $0 == 45 }
        }
    }

    /// The endpoint is an origin, not a full arbitrary URL. Version and action
    /// routes belong to each separately validated `ExtensionActionManifest`.
    /// This prevents a manifest from carrying an arbitrary redirect/path target
    /// as its base address; registration still performs no network request.
    static func isSafeBasePath(_ path: String) -> Bool {
        path.isEmpty || path == "/"
    }

    static func isLowercaseLetter(_ byte: UInt8) -> Bool { (97...122).contains(byte) }
    static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
}
