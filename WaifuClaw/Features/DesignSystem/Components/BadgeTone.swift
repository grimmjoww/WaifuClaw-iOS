import SwiftUI

/// Tones for StatusBadge. Each tone maps to a Theme color and carries its own
/// icon so status is never conveyed by color alone (differentiate-without-color).
enum BadgeTone {
    case info
    case success
    case warning
    case danger
    case neutral

    /// The Theme color backing this tone.
    var color: Color {
        switch self {
        case .info: Theme.magenta
        case .success: Theme.success
        case .warning: Theme.warning
        case .danger: Theme.danger
        case .neutral: Theme.textSecondary
        }
    }

    /// Small SF Symbol shown in the badge so tone is readable without color.
    var symbolName: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .neutral: "circle.fill"
        }
    }
}
