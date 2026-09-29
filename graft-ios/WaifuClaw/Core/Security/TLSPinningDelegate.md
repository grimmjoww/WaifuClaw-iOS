# WaifuClaw/Core/Security/TLSPinningDelegate.swift

- TLSPinningDelegate · class · L10-L62 — final class TLSPinningDelegate: NSObject, URLSessionDelegate
- clearPinFailure · method · L19-L19 — func clearPinFailure()
- TLSPinningDelegate · method · L21-L27 — init( expectedFingerprint: @escaping () -> String?, onMismatch: @escaping (_ expected: String, _ actual: String) -> Void )
- urlSession · method · L29-L53 — func urlSession( _ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void )
- leafFingerprint · method · L56-L61 — static func leafFingerprint(trust: SecTrust) -> String?
