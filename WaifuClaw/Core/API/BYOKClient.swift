import Foundation

/// BYOK network client: direct provider validation probes + desktop sync.
///
/// - Validation probes go straight to the provider (fast user feedback,
///   no desktop round trip).
/// - Key sync goes through the passed-in `APIClient`, so it inherits the
///   device-bearer auth and TLS pinning.
/// - The raw key is never logged, never persisted outside the Keychain.
struct BYOKClient: Sendable {
    /// Outcome of the direct provider probe.
    enum ProbeResult: Sendable {
        /// 200 — the key works.
        case valid
        /// 429 — the key is probably fine but the provider is throttling.
        /// Forwarding continues; the desktop re-validates on receipt.
        case rateLimited
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Direct provider validation

    /// Probes the provider with the key. Throws `BYOKError`.
    func validateKey(provider: BYOKProvider, key: String, baseURL: String?) async throws -> ProbeResult {
        guard let request = provider.validationRequest(key: key, baseURL: baseURL) else {
            throw BYOKError.invalidBaseURL
        }
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw BYOKError.providerUnreachable(provider: provider)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BYOKError.providerUnreachable(provider: provider)
        }
        switch http.statusCode {
        case 200..<300:
            return .valid
        case 401, 403:
            throw BYOKError.keyRejected(provider: provider)
        case 429:
            return .rateLimited
        case 500..<600:
            throw BYOKError.providerUnreachable(provider: provider)
        default:
            throw BYOKError.keyRejected(provider: provider)
        }
    }

    // MARK: - Desktop sync (pinned device channel)

    func saveKey(_ request: BYOKSaveRequest, via api: APIClient) async throws -> BYOKSaveResponse {
        do {
            return try await api.post(Endpoints.Remote.byokKey, body: request)
        } catch let error as APIError {
            throw mapDesktopError(error)
        }
    }

    func fetchStatus(via api: APIClient) async throws -> BYOKKeyStatus {
        try await api.get(Endpoints.Remote.byokStatus)
    }

    func deleteKey(via api: APIClient) async throws {
        let _: EmptyResponse = try await api.delete(Endpoints.Remote.byokKey)
    }

    // MARK: - Private

    /// Maps desktop failures to the contract's error semantics (§4).
    /// The server's `detail` is already human-readable; anything unexpected
    /// keeps the typed `APIError` so its message still reaches the user.
    private func mapDesktopError(_ error: APIError) -> BYOKError {
        switch error {
        case .http(let status, let message):
            switch status {
            case 400:
                .desktopRejected(detail: message ?? "Your computer rejected that key.")
            case 404:
                .desktopTooOld
            case 429:
                .desktopRateLimited
            default:
                .underlying(error)
            }
        default:
            .underlying(error)
        }
    }
}
