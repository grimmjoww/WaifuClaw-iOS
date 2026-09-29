import Foundation

/// Outcome of a real iOS permission request.
///
/// `unknown` is honest, not a fudge: iOS offers no API to read the
/// local-network grant, so after summoning the system prompt the best we
/// can record is that we asked. Never synthesize a fake "granted".
enum PermissionResult: Equatable {
    case granted
    case denied
    case unavailable(reason: String)
    case unknown
}
