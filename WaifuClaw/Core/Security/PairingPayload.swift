import Foundation

/// Parses the desktop's pairing QR: waifuclaw://pair?code=…&host=…&fingerprint=…
/// (ARCHITECTURE.md §2.1). The fingerprint is the TOFU pin anchor.
struct PairingPayload {
    let code: String
    let host: String
    /// Expected format: 64-char lowercase hex SHA-256 of the leaf cert DER.
    /// Confirmed with B2 — see CONTRACT_DRIFT.md.
    let fingerprint: String

    enum ParseError: LocalizedError {
        case notAPairingCode
        case missingField(String)

        var errorDescription: String? {
            switch self {
            case .notAPairingCode:
                return "That doesn't look like a WaifuClaw pairing code."
            case .missingField(let field):
                return "The pairing code is missing '\(field)' — ask your computer for a new one."
            }
        }
    }

    static func parse(_ string: String) throws -> PairingPayload {
        guard let url = URL(string: string),
              url.scheme == "waifuclaw",
              url.host == "pair",
              let items = URLComponents(string: string)?.queryItems
        else { throw ParseError.notAPairingCode }

        func value(_ name: String) throws -> String {
            guard let v = items.first(where: { $0.name == name })?.value,
                  !v.isEmpty
            else { throw ParseError.missingField(name) }
            return v
        }

        return PairingPayload(
            code: try value("code"),
            host: try value("host"),
            fingerprint: normalizeFingerprint(try value("fingerprint"))
        )
    }

    /// Accepts hex with or without colons; normalizes to 64-char lowercase hex.
    static func normalizeFingerprint(_ raw: String) -> String {
        raw.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    /// Short display form, e.g. "a3f9 … 91c2".
    var fingerprintPreview: String {
        let f = fingerprint
        guard f.count >= 8 else { return f }
        return "\(f.prefix(4)) … \(f.suffix(4))"
    }
}
