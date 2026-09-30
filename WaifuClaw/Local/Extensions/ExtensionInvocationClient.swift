import Foundation
import Security

/// The primitive values an extension action may accept. Deliberately excludes
/// files, arrays, objects, URLs, workspace paths, and executable values.
public enum ExtensionParameterValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)

    var displayValue: String {
        switch self {
        case .string(let value): return "\"\(value)\""
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        }
    }

    fileprivate var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .boolean(let value): return value
        }
    }
}

/// One exact primitive value that appears in the human confirmation screen and
/// becomes one property in the outbound JSON object.
public struct ExtensionInvocationParameter: Identifiable, Equatable, Sendable {
    public let name: String
    public let value: ExtensionParameterValue

    public var id: String { name }

    fileprivate init(name: String, value: ExtensionParameterValue) {
        self.name = name
        self.value = value
    }
}

public enum ExtensionInvocationError: LocalizedError, Equatable, Sendable {
    case extensionNotEnabled
    case actionUnavailable
    case unsupportedOrigin
    case invalidConfirmation
    case invalidParameter(name: String, reason: String)
    case requestTooLarge
    case responseTooLarge
    case redirectBlocked
    case cancelled
    case timedOut
    case transportSecurityFailure
    case transportFailure
    case invalidResponse
    case httpStatus(Int, String?)
    case remoteToolError(String)

    public var errorDescription: String? {
        switch self {
        case .extensionNotEnabled:
            return "This extension is disabled or was removed before the request was sent."
        case .actionUnavailable:
            return "The selected action is no longer declared by this extension."
        case .unsupportedOrigin:
            return "This build only permits manual actions to approved official vendor origins."
        case .invalidConfirmation:
            return "This request was not confirmed for the exact action and values shown."
        case .invalidParameter(let name, let reason):
            return "The value for \(name) is invalid: \(reason)"
        case .requestTooLarge:
            return "The JSON request is larger than the 64 KB safety limit."
        case .responseTooLarge:
            return "The vendor response exceeded the 256 KB safety limit."
        case .redirectBlocked:
            return "The vendor attempted a redirect. Redirects are blocked before any credential can be forwarded."
        case .cancelled:
            return "The extension request was cancelled."
        case .timedOut:
            return "The extension request timed out."
        case .transportSecurityFailure:
            return "A secure HTTPS connection could not be established. Check the vendor endpoint and your network."
        case .transportFailure:
            return "The extension request could not reach the vendor. Check your connection and try again."
        case .invalidResponse:
            return "The vendor returned an invalid response."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "The vendor returned HTTP \(status): \(message)"
            }
            return "The vendor returned HTTP \(status)."
        case .remoteToolError(let message):
            return "The vendor reported an action error: \(message)"
        }
    }
}

/// A reviewable, immutable request created from an enabled registry entry.
/// It has no fields for model prompts, agent state, workspace paths, or files.
public struct ExtensionInvocationDraft: Identifiable, Sendable {
    public let id: UUID
    public let extensionID: String
    public let extensionName: String
    public let vendor: String
    public let actionName: String
    public let origin: String
    public let path: String
    public let parameters: [ExtensionInvocationParameter]
    public let usesSavedVendorToken: Bool

    fileprivate let manifest: ExtensionManifest
    fileprivate let action: ExtensionActionManifest

    public var outboundDataSummary: String {
        let values = parameters.map { "\($0.name) = \($0.value.displayValue)" }.joined(separator: ", ")
        return values.isEmpty ? "An empty JSON object." : "JSON values: \(values)"
    }

    fileprivate init(
        manifest: ExtensionManifest,
        action: ExtensionActionManifest,
        origin: String,
        parameters: [ExtensionInvocationParameter],
        usesSavedVendorToken: Bool
    ) {
        id = UUID()
        extensionID = manifest.id
        extensionName = manifest.name
        vendor = manifest.vendor
        actionName = action.name
        self.origin = origin
        path = action.path
        self.parameters = parameters
        self.usesSavedVendorToken = usesSavedVendorToken
        self.manifest = manifest
        self.action = action
    }
}

/// A capability minted only after the host UI has presented the draft's exact
/// origin, path, parameter values, and outbound-data warning to the user.
public struct ExtensionInvocationConfirmation: Sendable {
    fileprivate let draftID: UUID
}

/// The in-memory, user-visible outcome of one request. Receipts intentionally
/// are not persisted because vendor responses can contain sensitive data.
public struct ExtensionInvocationReceipt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let completedAt: Date
    public let origin: String
    public let path: String
    public let actionName: String
    public let statusCode: Int
    public let responsePreview: String?
}

/// Keychain namespace for one approved extension origin. The registry never
/// receives a token or a token reference.
public struct ExtensionVendorTokenScope: Hashable, Sendable {
    public let extensionID: String
    public let origin: String

    fileprivate init(extensionID: String, origin: String) {
        self.extensionID = extensionID
        self.origin = origin
    }
}

public protocol ExtensionVendorTokenStoring {
    func save(_ token: String, for scope: ExtensionVendorTokenScope) throws
    func load(for scope: ExtensionVendorTokenScope) throws -> String?
    func delete(for scope: ExtensionVendorTokenScope) throws
}

/// Dedicated Keychain storage for an extension vendor token. It does not share
/// the coding-model BYOK account and it never writes a token to the registry,
/// UserDefaults, a receipt, or a log.
public struct ExtensionVendorTokenKeychainStore: ExtensionVendorTokenStoring {
    private static let service = "studio.phantomhorizons.waifuclaw.extension-vendor-token"

    public init() {}

    public func save(_ rawToken: String, for scope: ExtensionVendorTokenScope) throws {
        let token = try validatedToken(rawToken)
        guard let data = token.data(using: .utf8) else {
            throw ExtensionVendorTokenStorageError.invalidEncoding
        }
        let query = baseQuery(scope)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ExtensionVendorTokenStorageError.status(addStatus)
            }
        } else if status != errSecSuccess {
            throw ExtensionVendorTokenStorageError.status(status)
        }
    }

    public func load(for scope: ExtensionVendorTokenScope) throws -> String? {
        var query = baseQuery(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ExtensionVendorTokenStorageError.status(status)
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ExtensionVendorTokenStorageError.invalidEncoding
        }
        return token
    }

    public func delete(for scope: ExtensionVendorTokenScope) throws {
        let status = SecItemDelete(baseQuery(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionVendorTokenStorageError.status(status)
        }
    }

    private func baseQuery(_ scope: ExtensionVendorTokenScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(scope.extensionID)|\(scope.origin)",
        ]
    }

    private func validatedToken(_ rawToken: String) throws -> String {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              token.utf8.count <= 4_096,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ExtensionVendorTokenStorageError.invalidToken
        }
        return token
    }
}

public enum ExtensionVendorTokenStorageError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case invalidEncoding
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Enter a valid vendor token before saving."
        case .invalidEncoding:
            return "The saved vendor token could not be read."
        case .status(let status):
            return "Secure vendor-token storage is unavailable (\(status)). Unlock your phone and try again."
        }
    }
}

/// A deliberately narrow manual HTTPS action client.
///
/// The current transport policy permits only `https://api.github.com/markdown`
/// (the official GitHub Markdown rendering API). That is a real integration:
/// an imported manifest can POST user-entered Markdown fields. Other imported
/// manifests remain registration metadata and cannot be invoked.
///
/// A public-DNS-name check alone cannot prevent DNS rebinding at connection
/// time, and URLSession does not expose a dependable peer-IP allowlist. For
/// that reason this client **does not** accept arbitrary vendor origins or
/// claim comprehensive DNS-based SSRF prevention. HTTPS certificate validation,
/// no redirects, no cookies, and a small official-origin allowlist reduce the
/// attack surface; expanding it requires a transport-level egress policy (for
/// example, a managed network extension or proxy with rebinding protection).
public final class ExtensionInvocationClient: @unchecked Sendable {
    public static let maximumRequestBytes = 64 * 1_024
    public static let maximumResponseBytes = 256 * 1_024

    private let session: URLSession
    private let tokenStore: ExtensionVendorTokenStoring

    public init(
        session: URLSession? = nil,
        tokenStore: ExtensionVendorTokenStoring = ExtensionVendorTokenKeychainStore()
    ) {
        self.session = session ?? Self.makeSecureSession()
        self.tokenStore = tokenStore
    }

    /// Lets the UI hide metadata-only manifests without attempting a request.
    public func isInvocationSupported(for manifest: ExtensionManifest) -> Bool {
        guard (try? manifest.validate()) != nil else { return false }
        guard let approved = ApprovedExtensionOrigin.match(manifest.baseEndpoint) else { return false }
        return manifest.actions.contains(where: { approved.isSafePath($0.path) })
    }

    public func isActionSupported(_ action: ExtensionActionManifest, in manifest: ExtensionManifest) -> Bool {
        guard (try? manifest.validate()) != nil,
              let approved = ApprovedExtensionOrigin.match(manifest.baseEndpoint) else { return false }
        return approved.isSafePath(action.path)
    }

    /// Produces a request only from action metadata currently enabled in the
    /// app-owned registry. There is no model, agent, workspace, or file input.
    @MainActor
    public func makeDraft(
        registry: ExtensionRegistry,
        pluginID: String,
        actionName: String,
        parameterValues: [String: ExtensionParameterValue]
    ) throws -> ExtensionInvocationDraft {
        guard let installed = registry.installedExtensions.first(where: { $0.id == pluginID && $0.isEnabled }) else {
            throw ExtensionInvocationError.extensionNotEnabled
        }
        guard let action = installed.manifest.actions.first(where: { $0.name == actionName }) else {
            throw ExtensionInvocationError.actionUnavailable
        }
        return try makeDraft(manifest: installed.manifest, action: action, parameterValues: parameterValues)
    }

    /// Returns a confirmation capability after the caller has shown the draft
    /// to a human. The included SwiftUI view does this with an explicit review
    /// sheet; callers must not call this from an automatic agent/tool path.
    public func confirmation(for draft: ExtensionInvocationDraft) -> ExtensionInvocationConfirmation {
        ExtensionInvocationConfirmation(draftID: draft.id)
    }

    /// Saves an optional vendor token in the device Keychain for this extension
    /// and approved origin. A saved token is attached only to that same origin.
    public func saveVendorToken(_ token: String, for manifest: ExtensionManifest) throws {
        let scope = try credentialScope(for: manifest)
        try tokenStore.save(token, for: scope)
    }

    public func hasSavedVendorToken(for manifest: ExtensionManifest) throws -> Bool {
        let scope = try credentialScope(for: manifest)
        return try tokenStore.load(for: scope) != nil
    }

    public func deleteVendorToken(for manifest: ExtensionManifest) throws {
        let scope = try credentialScope(for: manifest)
        try tokenStore.delete(for: scope)
    }

    /// Re-checks registry enablement and the exact manifest/action immediately
    /// before sending. The confirmation must correspond to this immutable draft.
    @MainActor
    public func invoke(
        _ draft: ExtensionInvocationDraft,
        confirmedBy confirmation: ExtensionInvocationConfirmation,
        registry: ExtensionRegistry
    ) async throws -> ExtensionInvocationReceipt {
        guard confirmation.draftID == draft.id else {
            throw ExtensionInvocationError.invalidConfirmation
        }
        guard let installed = registry.installedExtensions.first(where: {
            $0.id == draft.extensionID && $0.isEnabled && $0.manifest == draft.manifest
        }) else {
            throw ExtensionInvocationError.extensionNotEnabled
        }
        guard installed.manifest.actions.contains(draft.action) else {
            throw ExtensionInvocationError.actionUnavailable
        }
        try Task.checkCancellation()
        let request = try makeURLRequest(for: draft)
        return try await send(request, draft: draft)
    }

    private func makeDraft(
        manifest: ExtensionManifest,
        action: ExtensionActionManifest,
        parameterValues: [String: ExtensionParameterValue]
    ) throws -> ExtensionInvocationDraft {
        try manifest.validate()
        guard let approved = ApprovedExtensionOrigin.match(manifest.baseEndpoint) else {
            throw ExtensionInvocationError.unsupportedOrigin
        }
        guard manifest.actions.contains(action) else {
            throw ExtensionInvocationError.actionUnavailable
        }
        guard approved.isSafePath(action.path) else {
            throw ExtensionInvocationError.unsupportedOrigin
        }
        let orderedValues = try validate(parameterValues: parameterValues, action: action)
        let scope = ExtensionVendorTokenScope(extensionID: manifest.id, origin: approved.origin)
        let usesToken = try tokenStore.load(for: scope) != nil
        return ExtensionInvocationDraft(
            manifest: manifest,
            action: action,
            origin: approved.origin,
            parameters: orderedValues,
            usesSavedVendorToken: usesToken
        )
    }

    private func validate(
        parameterValues: [String: ExtensionParameterValue],
        action: ExtensionActionManifest
    ) throws -> [ExtensionInvocationParameter] {
        let schemas = Dictionary(uniqueKeysWithValues: action.parameters.map { ($0.name, $0) })
        guard Set(parameterValues.keys).isSubset(of: Set(schemas.keys)) else {
            let unknown = parameterValues.keys.first(where: { schemas[$0] == nil }) ?? "parameter"
            throw ExtensionInvocationError.invalidParameter(name: unknown, reason: "it is not declared by this action")
        }

        return try action.parameters.compactMap { schema in
            guard let value = parameterValues[schema.name] else {
                if schema.required {
                    throw ExtensionInvocationError.invalidParameter(name: schema.name, reason: "a value is required")
                }
                return nil
            }
            switch (schema.type, value) {
            case (.string, .string(let string)):
                let maximum = schema.maxLength ?? 4_096
                guard string.utf8.count <= maximum else {
                    throw ExtensionInvocationError.invalidParameter(name: schema.name, reason: "it exceeds \(maximum) bytes")
                }
                guard !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ExtensionInvocationError.invalidParameter(name: schema.name, reason: "control characters are not allowed")
                }
                if let allowed = schema.enumValues, !allowed.contains(string) {
                    throw ExtensionInvocationError.invalidParameter(name: schema.name, reason: "it is not one of the declared values")
                }
            case (.integer, .integer):
                break
            case (.number, .number(let number)) where number.isFinite:
                break
            case (.boolean, .boolean):
                break
            case (.number, .number):
                throw ExtensionInvocationError.invalidParameter(name: schema.name, reason: "it must be finite")
            default:
                throw ExtensionInvocationError.invalidParameter(name: schema.name, reason: "it does not match the declared \(schema.type.rawValue) type")
            }
            return ExtensionInvocationParameter(name: schema.name, value: value)
        }
    }

    private func makeURLRequest(for draft: ExtensionInvocationDraft) throws -> URLRequest {
        guard let approved = ApprovedExtensionOrigin.match(draft.manifest.baseEndpoint),
              approved.origin == draft.origin,
              approved.isSafePath(draft.action.path),
              draft.path == draft.action.path
        else {
            throw ExtensionInvocationError.unsupportedOrigin
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = approved.host
        components.path = draft.action.path
        guard let url = components.url else {
            throw ExtensionInvocationError.unsupportedOrigin
        }

        let object = Dictionary(uniqueKeysWithValues: draft.parameters.map { ($0.name, $0.value.jsonValue) })
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ExtensionInvocationError.invalidResponse
        }
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard body.count <= Self.maximumRequestBytes else {
            throw ExtensionInvocationError.requestTooLarge
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("WaifuClaw/1.0", forHTTPHeaderField: "User-Agent")

        let scope = ExtensionVendorTokenScope(extensionID: draft.extensionID, origin: approved.origin)
        if let token = try tokenStore.load(for: scope) {
            // This header is possible only for the hard-coded GitHub origin.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest, draft: ExtensionInvocationDraft) async throws -> ExtensionInvocationReceipt {
        let redirectBlocker = ExtensionRedirectBlocker()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectBlocker)
            guard let http = response as? HTTPURLResponse else {
                throw ExtensionInvocationError.invalidResponse
            }
            if redirectBlocker.didBlockRedirect || (300...399).contains(http.statusCode) {
                throw ExtensionInvocationError.redirectBlocked
            }
            if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
                throw ExtensionInvocationError.responseTooLarge
            }

            var data = Data()
            data.reserveCapacity(min(max(0, Int(http.expectedContentLength)), Self.maximumResponseBytes))
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    throw ExtensionInvocationError.responseTooLarge
                }
                data.append(byte)
            }
            try Task.checkCancellation()

            let preview = Self.responsePreview(data)
            if !(200...299).contains(http.statusCode) {
                throw ExtensionInvocationError.httpStatus(http.statusCode, Self.serverMessage(from: data))
            }
            if let toolError = Self.toolError(from: data) {
                throw ExtensionInvocationError.remoteToolError(toolError)
            }
            return ExtensionInvocationReceipt(
                id: UUID(),
                completedAt: Date(),
                origin: draft.origin,
                path: draft.path,
                actionName: draft.actionName,
                statusCode: http.statusCode,
                responsePreview: preview
            )
        } catch let error as ExtensionInvocationError {
            throw error
        } catch is CancellationError {
            throw ExtensionInvocationError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            if redirectBlocker.didBlockRedirect {
                throw ExtensionInvocationError.redirectBlocked
            }
            if Task.isCancelled {
                throw ExtensionInvocationError.cancelled
            }
            throw ExtensionInvocationError.transportFailure
        } catch let error as URLError where error.code == .timedOut {
            throw ExtensionInvocationError.timedOut
        } catch let error as URLError where Self.isTransportSecurityFailure(error.code) {
            throw ExtensionInvocationError.transportSecurityFailure
        } catch {
            if redirectBlocker.didBlockRedirect {
                throw ExtensionInvocationError.redirectBlocked
            }
            if Task.isCancelled {
                throw ExtensionInvocationError.cancelled
            }
            throw ExtensionInvocationError.transportFailure
        }
    }

    private func credentialScope(for manifest: ExtensionManifest) throws -> ExtensionVendorTokenScope {
        try manifest.validate()
        guard let approved = ApprovedExtensionOrigin.match(manifest.baseEndpoint) else {
            throw ExtensionInvocationError.unsupportedOrigin
        }
        return ExtensionVendorTokenScope(extensionID: manifest.id, origin: approved.origin)
    }

    private static func makeSecureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }

    private static func isTransportSecurityFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .appTransportSecurityRequiresSecureConnection,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    private static func responsePreview(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            return "Received \(data.count) bytes of non-text response data."
        }
        var cleaned = ""
        for scalar in text.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t" {
            cleaned.unicodeScalars.append(scalar)
        }
        let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return String(result.prefix(4_096))
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return responsePreview(data)
        }
        let candidate: String?
        if let error = dictionary["error"] as? String {
            candidate = error
        } else if let error = dictionary["error"] as? [String: Any] {
            candidate = error["message"] as? String ?? error["detail"] as? String
        } else {
            candidate = dictionary["message"] as? String ?? dictionary["detail"] as? String
        }
        return sanitizedMessage(candidate)
    }

    private static func toolError(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.keys.contains("error")
        else {
            return nil
        }
        if let error = dictionary["error"] as? String {
            return sanitizedMessage(error) ?? "The vendor returned an unspecified tool error."
        }
        if let error = dictionary["error"] as? [String: Any] {
            return sanitizedMessage(error["message"] as? String ?? error["detail"] as? String)
                ?? "The vendor returned an unspecified tool error."
        }
        return "The vendor returned an unspecified tool error."
    }

    private static func sanitizedMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        var cleaned = ""
        for scalar in message.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            cleaned.unicodeScalars.append(scalar)
        }
        let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return String(result.prefix(512))
    }
}

private enum ApprovedExtensionOrigin {
    case githubAPI

    static func match(_ url: URL) -> ApprovedExtensionOrigin? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || components.port == 443,
              components.host?.lowercased() == "api.github.com"
        else {
            return nil
        }
        return .githubAPI
    }

    var host: String {
        switch self {
        case .githubAPI: return "api.github.com"
        }
    }

    var origin: String {
        "https://\(host)"
    }

    func isSafePath(_ path: String) -> Bool {
        switch self {
        case .githubAPI:
            return path == "/markdown"
        }
    }
}

/// Refuses every redirect, including same-origin redirects. This prevents a
/// saved Authorization token from being replayed to a path or origin the user
/// did not review. The direct 3xx check in `send` is a second safeguard.
private final class ExtensionRedirectBlocker: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var blocked = false

    var didBlockRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        blocked = true
        lock.unlock()
        completionHandler(nil)
    }
}
