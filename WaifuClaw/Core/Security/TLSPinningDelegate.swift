import CryptoKit
import Foundation
import Security

/// TOFU certificate pinning (ARCHITECTURE.md §2.1).
/// The desktop serves a self-signed cert; instead of trusting a CA we pin the
/// SHA-256 fingerprint of the leaf certificate that came in the pairing QR.
/// A mismatch is NEVER auto-trusted — the app surfaces the blocking security
/// warning (audit §4) and cancels the connection.
final class TLSPinningDelegate: NSObject, URLSessionDelegate {
    /// Current expected fingerprint (Keychain-backed; replaced on "Trust new").
    var expectedFingerprint: () -> String?
    /// Fired on mismatch. The app must show FingerprintMismatchView.
    var onMismatch: (_ expected: String, _ actual: String) -> Void
    /// Last pin failure, for mapping the resulting URLError(.cancelled)
    /// back to the security error instead of a generic network error.
    private(set) var pinFailure: (expected: String, actual: String)?

    func clearPinFailure() { pinFailure = nil }

    init(
        expectedFingerprint: @escaping () -> String?,
        onMismatch: @escaping (_ expected: String, _ actual: String) -> Void
    ) {
        self.expectedFingerprint = expectedFingerprint
        self.onMismatch = onMismatch
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let expected = expectedFingerprint(),
              !expected.isEmpty
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let actual = Self.leafFingerprint(trust: trust)
        if actual == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            // Loud, blocking, never silent (audit §4).
            let failure = (expected: expected, actual: actual ?? "unknown")
            pinFailure = failure
            onMismatch(failure.expected, failure.actual)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// SHA-256 of the leaf certificate DER, lowercase hex.
    static func leafFingerprint(trust: SecTrust) -> String? {
        guard let cert = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
        let data = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: data)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }
}
