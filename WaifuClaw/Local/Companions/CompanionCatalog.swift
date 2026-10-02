import CoreGraphics
import SwiftUI

/// A visual companion choice. It deliberately has no model, prompt, permission,
/// availability, or agent-status data: selection changes only the on-screen art.
enum CompanionID: String, CaseIterable, Codable, Identifiable, Sendable {
    case kline
    case rei
    case sage

    static let defaultSelection: CompanionID = .kline
    static let selectionStorageKey = "native.selectedCompanionID"

    var id: String { rawValue }

    /// Safely decodes persisted selection values from older or malformed defaults.
    static func selected(from storedID: String?) -> CompanionID {
        guard let storedID, let companion = CompanionID(rawValue: storedID) else {
            return defaultSelection
        }
        return companion
    }

    var definition: CompanionDefinition {
        CompanionCatalog.definition(for: self)
    }
}

/// The single source of truth for companion art metadata. Personality strings are
/// visual picker copy only and must never be used in an agent/system/model prompt.
enum CompanionCatalog {
    static let all: [CompanionDefinition] = [
        CompanionDefinition(
            id: .kline,
            name: "Kline",
            visualPersonality: "A calm, winged operator with a focused studio glow.",
            textures: CompanionTextureNames(
                body: "KlineBody",
                leftAppendage: "KlineWingLeft",
                rightAppendage: "KlineWingRight",
                blinkEyes: "KlineBlinkEyes"
            ),
            appendageKind: .wings,
            articulation: CompanionArticulation(
                // Verified against the existing aligned Kline layers.
                leftPivot: CGPoint(x: 318, y: 685),
                rightPivot: CGPoint(x: 457, y: 685)
            ),
            palette: CompanionPalette(
                accent: CompanionColor(red: 0.93, green: 0.22, blue: 0.61),
                surface: CompanionColor(red: 0.17, green: 0.08, blue: 0.19),
                label: CompanionColor(red: 0.89, green: 0.95, blue: 1.00)
            )
        ),
        CompanionDefinition(
            id: .rei,
            name: "Rei",
            visualPersonality: "A bright kitsune engineer with playful rose-and-cream tails.",
            textures: CompanionTextureNames(
                body: "ReiBody",
                leftAppendage: "ReiTailLeft",
                rightAppendage: "ReiTailRight",
                blinkEyes: "ReiBlinkEyes"
            ),
            appendageKind: .tails,
            articulation: CompanionArticulation(
                // Hip-root pivots measured from the source art; device motion QA is pending.
                leftPivot: CGPoint(x: 305, y: 530),
                rightPivot: CGPoint(x: 615, y: 510)
            ),
            palette: CompanionPalette(
                accent: CompanionColor(red: 0.98, green: 0.48, blue: 0.72),
                surface: CompanionColor(red: 0.22, green: 0.09, blue: 0.19),
                label: CompanionColor(red: 1.00, green: 0.92, blue: 0.97)
            )
        ),
        CompanionDefinition(
            id: .sage,
            name: "Sage",
            visualPersonality: "A moonlit moth-owl scholar with soft luminous wings.",
            textures: CompanionTextureNames(
                body: "SageBody",
                leftAppendage: "SageWingLeft",
                rightAppendage: "SageWingRight",
                blinkEyes: "SageBlinkEyes"
            ),
            appendageKind: .wings,
            articulation: CompanionArticulation(
                // Shoulder-root pivots measured from the source art; device motion QA is pending.
                leftPivot: CGPoint(x: 315, y: 735),
                rightPivot: CGPoint(x: 645, y: 735)
            ),
            palette: CompanionPalette(
                accent: CompanionColor(red: 0.54, green: 0.87, blue: 0.92),
                surface: CompanionColor(red: 0.12, green: 0.10, blue: 0.24),
                label: CompanionColor(red: 0.94, green: 0.92, blue: 1.00)
            )
        )
    ]

    static func definition(for id: CompanionID) -> CompanionDefinition {
        guard let definition = all.first(where: { $0.id == id }) else {
            preconditionFailure("Missing visual companion metadata for \(id.rawValue)")
        }
        return definition
    }
}

struct CompanionDefinition: Identifiable, Equatable {
    let id: CompanionID
    let name: String
    let visualPersonality: String
    let textures: CompanionTextureNames
    let appendageKind: CompanionAppendageKind
    let articulation: CompanionArticulation
    let palette: CompanionPalette
}

struct CompanionTextureNames: Equatable {
    let body: String
    let leftAppendage: String
    let rightAppendage: String
    let blinkEyes: String

    var all: [String] {
        [body, leftAppendage, rightAppendage, blinkEyes]
    }
}

enum CompanionAppendageKind: String, Equatable {
    case tails
    case wings
}

/// Pixel-space pivots on the shared, transparent 960 × 960 source canvas.
/// These are data rather than hard-coded rig values so art review can tune them.
struct CompanionArticulation: Equatable {
    let leftPivot: CGPoint
    let rightPivot: CGPoint
}

struct CompanionPalette: Equatable {
    let accent: CompanionColor
    let surface: CompanionColor
    let label: CompanionColor
}

struct CompanionColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}
