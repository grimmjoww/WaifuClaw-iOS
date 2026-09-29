import Foundation

/// Tokenless HTTP client used ONLY for the pairing exchange.
/// The pairing code is the credential; the Bearer device token doesn't exist yet.
/// TLS pinning still applies — the QR fingerprint is pinned before the first byte.
struct PairingClient {
    let baseURL: URL
    private let session: URLSession
    private let pinningDelegate: TLSPinningDelegate

    init(host: String, fingerprint: String, onMismatch: @escaping (String, String) -> Void) {
        let (cleanHost, port) = AppState.splitHostPort(host)
        self.baseURL = URL(string: "https://\(cleanHost):\(port)")!
        let delegate = TLSPinningDelegate(
            expectedFingerprint: { fingerprint },
            onMismatch: onMismatch
        )
        self.pinningDelegate = delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func exchange(_ body: PairingExchangeRequest) async throws -> PairingExchangeResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(Endpoints.Remote.pairingExchange))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WaifuClaw-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let pin = pinningDelegate.pinFailure {
                throw APIError.tlsMismatch(expected: pin.expected, actual: pin.actual)
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                     .timedOut, .networkConnectionLost, .dnsLookupFailed:
                    throw APIError.unreachable(kind: AppState.kind(for: baseURL.host ?? ""))
                default:
                    throw APIError.desktopNotResponding
                }
            }
            throw APIError.network(URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(PairingExchangeResponse.self, from: data)
            } catch {
                throw APIError.decoding
            }
        case 410:
            throw APIError.pairingCodeExpired
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["detail"] as? String) ?? ($0["message"] as? String) }
            throw APIError.http(status: http.statusCode, message: message)
        }
    }
}
