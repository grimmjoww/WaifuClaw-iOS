import Foundation
import XCTest
@testable import WaifuClaw

@MainActor
final class ExtensionInvocationTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        ExtensionInvocationURLProtocol.reset()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testPostsOnlyValidatedPrimitivePayloadToApprovedOrigin() async throws {
        let tokenStore = TestTokenStore()
        let manifest = githubManifest()
        let registry = try registeredRegistry(manifest)
        let client = makeClient(tokenStore: tokenStore)
        try client.saveVendorToken("github-secret", for: manifest)

        let captured = expectation(description: "request captured")
        ExtensionInvocationURLProtocol.configure { request in
            captured.fulfill()
            return .response(status: 200, body: Data("<h1>Rendered</h1>".utf8))
        }

        let draft = try client.makeDraft(
            registry: registry,
            pluginID: manifest.id,
            actionName: "render_markdown",
            parameterValues: [
                "text": .string("# Hello"),
                "mode": .string("gfm"),
                "context": .string("octo/private")
            ]
        )
        XCTAssertEqual(draft.origin, "https://api.github.com")
        XCTAssertTrue(draft.usesSavedVendorToken)

        let receipt = try await client.invoke(
            draft,
            confirmedBy: client.confirmation(for: draft),
            registry: registry
        )
        await fulfillment(of: [captured], timeout: 1)

        let request = try XCTUnwrap(ExtensionInvocationURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/markdown")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")

        let body = try XCTUnwrap(ExtensionInvocationURLProtocol.lastBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["text"] as? String, "# Hello")
        XCTAssertEqual(payload["mode"] as? String, "gfm")
        XCTAssertEqual(payload["context"] as? String, "octo/private")
        XCTAssertEqual(payload.count, 3)
        XCTAssertEqual(receipt.statusCode, 200)
        XCTAssertEqual(receipt.responsePreview, "<h1>Rendered</h1>")
    }

    func testRejectsUndeclaredParameterAndDoesNotStartRequest() throws {
        let manifest = githubManifest()
        let registry = try registeredRegistry(manifest)
        let client = makeClient()

        XCTAssertThrowsError(
            try client.makeDraft(
                registry: registry,
                pluginID: manifest.id,
                actionName: "render_markdown",
                parameterValues: ["workspace_file": .string("/private/project/secret.swift")]
            )
        ) { error in
            guard case ExtensionInvocationError.invalidParameter(let name, _) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(name, "workspace_file")
        }
        XCTAssertNil(ExtensionInvocationURLProtocol.lastRequest)
    }

    func testRejectsDirectRedirectResponseBeforeFollowingIt() async throws {
        let manifest = githubManifest()
        let registry = try registeredRegistry(manifest)
        let client = makeClient()
        ExtensionInvocationURLProtocol.configure { _ in
            .response(
                status: 302,
                headers: ["Location": "https://example.invalid/collect"],
                body: Data()
            )
        }

        let draft = try client.makeDraft(
            registry: registry,
            pluginID: manifest.id,
            actionName: "render_markdown",
            parameterValues: ["text": .string("# Hello"), "mode": .string("gfm")]
        )

        do {
            _ = try await client.invoke(
                draft,
                confirmedBy: client.confirmation(for: draft),
                registry: registry
            )
            XCTFail("Redirect must not be accepted")
        } catch let error as ExtensionInvocationError {
            XCTAssertEqual(error, .redirectBlocked)
        }
        XCTAssertEqual(ExtensionInvocationURLProtocol.requestCount, 1)
    }

    func testCancellationCancelsURLSessionRequest() async throws {
        let manifest = githubManifest()
        let registry = try registeredRegistry(manifest)
        let client = makeClient()
        let started = expectation(description: "request started")
        ExtensionInvocationURLProtocol.configure { _ in
            started.fulfill()
            return .pending
        }

        let draft = try client.makeDraft(
            registry: registry,
            pluginID: manifest.id,
            actionName: "render_markdown",
            parameterValues: ["text": .string("# Hello"), "mode": .string("gfm")]
        )
        let confirmation = client.confirmation(for: draft)
        let task = Task { @MainActor () -> Result<ExtensionInvocationReceipt, Error> in
            do {
                return .success(try await client.invoke(draft, confirmedBy: confirmation, registry: registry))
            } catch {
                return .failure(error)
            }
        }

        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value
        switch result {
        case .success:
            XCTFail("Cancellation should not produce a receipt")
        case .failure(let error as ExtensionInvocationError):
            XCTAssertEqual(error, .cancelled)
        case .failure(let error):
            XCTFail("Unexpected cancellation error \(error)")
        }
        // URLSession delivers the URLProtocol stop callback on its own queue,
        // which can follow the cancelled Swift task's return on a busy simulator.
        for _ in 0..<50 where !ExtensionInvocationURLProtocol.didStopLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ExtensionInvocationURLProtocol.didStopLoading)
    }

    func testDisabledRegistrationAndUnapprovedOriginCannotInvoke() throws {
        let manifest = githubManifest()
        let registry = try registeredRegistry(manifest)
        let client = makeClient()
        try registry.setExtensionEnabled(manifest.id, isEnabled: false)
        XCTAssertThrowsError(
            try client.makeDraft(
                registry: registry,
                pluginID: manifest.id,
                actionName: "render_markdown",
                parameterValues: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ExtensionInvocationError, .extensionNotEnabled)
        }

        let unapproved = ExtensionManifest(
            id: "com.example.other",
            name: "Other Vendor",
            vendor: "Other",
            capabilities: ["other.write"],
            baseEndpoint: URL(string: "https://api.example.com")!,
            actions: [ExtensionActionManifest(name: "post", path: "/v1/post", parameters: [])]
        )
        let secondRegistry = try registeredRegistry(unapproved)
        XCTAssertThrowsError(
            try client.makeDraft(
                registry: secondRegistry,
                pluginID: unapproved.id,
                actionName: "post",
                parameterValues: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ExtensionInvocationError, .unsupportedOrigin)
        }
    }

    func testApprovedGitHubOriginStillRejectsUnapprovedMutatingPaths() throws {
        let manifest = ExtensionManifest(
            id: "com.github.unsafe-action",
            name: "Unsafe GitHub action",
            vendor: "GitHub",
            capabilities: ["repository.create"],
            baseEndpoint: URL(string: "https://api.github.com")!,
            actions: [ExtensionActionManifest(name: "create_repository", path: "/user/repos", parameters: [])]
        )
        let registry = try registeredRegistry(manifest)
        let client = makeClient()
        XCTAssertFalse(client.isInvocationSupported(for: manifest))
        XCTAssertThrowsError(
            try client.makeDraft(
                registry: registry,
                pluginID: manifest.id,
                actionName: "create_repository",
                parameterValues: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ExtensionInvocationError, .unsupportedOrigin)
        }
        XCTAssertNil(ExtensionInvocationURLProtocol.lastRequest)
    }

    private func githubManifest() -> ExtensionManifest {
        ExtensionManifest(
            id: "com.github.markdown",
            name: "GitHub Markdown",
            vendor: "GitHub",
            capabilities: ["markdown.render"],
            baseEndpoint: URL(string: "https://api.github.com")!,
            actions: [
                ExtensionActionManifest(
                    name: "render_markdown",
                    path: "/markdown",
                    parameters: [
                        ExtensionParameterSchema(name: "text", type: .string, required: true, maxLength: 4_096),
                        ExtensionParameterSchema(name: "mode", type: .string, required: true, enumValues: ["markdown", "gfm"]),
                        ExtensionParameterSchema(name: "context", type: .string, required: false, maxLength: 256)
                    ]
                )
            ]
        )
    }

    private func registeredRegistry(_ manifest: ExtensionManifest) throws -> ExtensionRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let registry = ExtensionRegistry(storageURL: directory.appendingPathComponent("registry.json"))
        try registry.importManifest(manifest)
        return registry
    }

    private func makeClient(tokenStore: TestTokenStore = TestTokenStore()) -> ExtensionInvocationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExtensionInvocationURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return ExtensionInvocationClient(
            session: URLSession(configuration: configuration),
            tokenStore: tokenStore
        )
    }
}

private final class TestTokenStore: ExtensionVendorTokenStoring {
    private var tokens: [ExtensionVendorTokenScope: String] = [:]

    func save(_ token: String, for scope: ExtensionVendorTokenScope) throws {
        tokens[scope] = token
    }

    func load(for scope: ExtensionVendorTokenScope) throws -> String? {
        tokens[scope]
    }

    func delete(for scope: ExtensionVendorTokenScope) throws {
        tokens.removeValue(forKey: scope)
    }
}

private final class ExtensionInvocationURLProtocol: URLProtocol {
    enum Stub {
        case response(status: Int, headers: [String: String] = [:], body: Data)
        case pending
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Stub)?
    private static var capturedRequest: URLRequest?
    private static var capturedBody: Data?
    private static var count = 0
    private static var stopped = false

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    static var lastBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static var didStopLoading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    static func configure(_ handler: @escaping (URLRequest) -> Stub) {
        lock.lock()
        self.handler = handler
        capturedRequest = nil
        capturedBody = nil
        count = 0
        stopped = false
        lock.unlock()
    }

    static func record(_ request: URLRequest) {
        // URLSession often converts URLRequest.httpBody to httpBodyStream before
        // presenting the request to URLProtocol. Read it in this TEST transport;
        // the production request still sends exactly the JSON body it encoded.
        let body = request.httpBody ?? readBodyStream(request.httpBodyStream)
        lock.lock()
        capturedRequest = request
        capturedBody = body
        count += 1
        lock.unlock()
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { return nil }
            if read == 0 { break }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }

    static func reset() {
        lock.lock()
        handler = nil
        capturedRequest = nil
        capturedBody = nil
        count = 0
        stopped = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.record(request)
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch handler(request) {
        case .pending:
            break
        case .response(let status, let headers, let body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopped = true
        Self.lock.unlock()
    }
}
