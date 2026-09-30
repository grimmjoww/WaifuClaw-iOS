import CoreText
import SwiftUI

/// The font files are app resources, not system fonts. Explicit registration
/// also works in a hosted XCTest process, where UIAppFonts is not guaranteed
/// to have been processed by UIKit before the first SwiftUI view is built.
enum StudioFontRegistration {
    static func registerIfNeeded() {
        for fileName in ["CinzelDecorative-Regular", "CinzelDecorative-Bold"] {
            guard let fontURL = Bundle.main.url(forResource: fileName, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }
}

/// WaifuClaw brand theme — Phantom Horizons palette: dark plum-black with
/// magenta accents. Never generic piano black.
///
/// Single source of truth for colors, typography roles, radii, spacing,
/// gradients, and animation timings. Dark-only by design (every mockup is
/// dark). Colors are hardcoded sRGB values rather than an asset catalog
/// because this repo is authored on Linux, where .xcassets can't be validated.
///
/// Cinzel Decorative (SIL OFL 1.1) is reserved for legible fantasy display
/// headings; body text remains the iOS system font with Dynamic Type scaling.
/// Its full copyright and license are bundled under Third-Party Notices.
/// - No blue "info" color: per the Phantom Horizons palette the info tone is
///   magenta (see BadgeTone.info). The status set is success/warning/danger.
/// - Card/PrimaryButton/DisplayText live nested in this enum (one file) rather
///   than one-type-per-file: a theme namespace keeps the single source of
///   truth in one place.
enum Theme {
    // MARK: - Colors

    /// Deep plum-black background.
    static let background = Color(red: 0.078, green: 0.066, blue: 0.106) // #14111B
    /// Slightly lifted surface for cards / bubbles.
    static let surface = Color(red: 0.118, green: 0.098, blue: 0.157) // #1E1928
    /// Primary magenta accent.
    static let magenta = Color(red: 0.878, green: 0.271, blue: 0.604) // #E0459A
    /// Soft magenta for highlights / gradients.
    static let magentaSoft = Color(red: 0.949, green: 0.478, blue: 0.741) // #F27ABD
    /// Primary text.
    static let textPrimary = Color(red: 0.965, green: 0.945, blue: 0.976)
    /// Secondary text.
    static let textSecondary = Color(red: 0.663, green: 0.620, blue: 0.729)
    /// Success green.
    static let success = Color(red: 0.298, green: 0.851, blue: 0.392)
    /// Warning amber.
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.157)
    /// Danger red.
    static let danger = Color(red: 1.0, green: 0.271, blue: 0.278)
    /// Hairline borders on dark surfaces.
    static let hairline = Color.white.opacity(0.08)
    /// Track behind progress bars / rings.
    static let track = Color.white.opacity(0.10)

    // MARK: - Gradients

    /// Magenta accent gradient — progress bars, active indicators, glows.
    static let magentaGradient = LinearGradient(
        colors: [magenta, magentaSoft],
        startPoint: .leading, endPoint: .trailing
    )
    /// Dimensional display lettering — white-hot top melting into magenta.
    /// Apply via `.foregroundStyle(Theme.displayGradient)` or themeDisplayText().
    static let displayGradient = LinearGradient(
        colors: [.white, magentaSoft, magenta],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: - Typography (Dynamic Type roles — never fixed point sizes)

    /// Ornate, readable studio mark and feature title; scales with Dynamic Type.
    static var studioMark: Font { .custom("CinzelDecorative-Bold", size: 26, relativeTo: .title) }
    static var display: Font { .custom("CinzelDecorative-Bold", size: 30, relativeTo: .largeTitle) }
    static var sectionDisplay: Font { .custom("CinzelDecorative-Regular", size: 19, relativeTo: .title3) }
    /// Functional screen/card labels stay system-font readable at small sizes.
    static var title: Font { .title }
    static var headline: Font { .headline }
    /// Body copy.
    static var body: Font { .body }
    /// Small supporting text. Never .caption2 — too small per HIG.
    static var caption: Font { .caption }
    // Eyebrow labels ("SYSTEM HEALTH"): .font(Theme.caption).bold()
    //   + .textCase(.uppercase) at the call site.

    // MARK: - Radii

    static let radiusS: Double = 8
    static let radiusM: Double = 16
    static let radiusL: Double = 24

    // MARK: - Spacing (4pt scale)

    static let spacingXS: Double = 4
    static let spacingS: Double = 8
    static let spacingM: Double = 12
    static let spacingL: Double = 16
    static let spacingXL: Double = 24
    static let spacingXXL: Double = 32

    // MARK: - Animation timings

    static let animationQuick: Double = 0.2
    static let animationStandard: Double = 0.35

    // MARK: - View modifiers

    struct Card: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(Theme.spacingL)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.17, green: 0.11, blue: 0.20), Theme.surface],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(LinearGradient(
                                    colors: [Theme.magentaSoft.opacity(0.40), Theme.hairline, Theme.magenta.opacity(0.20)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ), lineWidth: 1)
                        }
                        .overlay(alignment: .topLeading) {
                            Rectangle()
                                .fill(Theme.magentaGradient)
                                .frame(width: 38, height: 2)
                                .padding(.leading, 16)
                        }
                }
                .shadow(color: Theme.magenta.opacity(0.08), radius: 12, y: 6)
        }
    }

    struct PrimaryButton: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(Theme.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14) // headline (~22pt) + 28 = ~50pt ≥ 44pt min target
                .background(Theme.magentaGradient, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.magentaSoft.opacity(0.6), lineWidth: 1)
                }
        }
    }

    /// Dimensional display lettering — largeTitle, bold, magenta gradient.
    struct DisplayText: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(Theme.display)
                .bold()
                .foregroundStyle(Theme.displayGradient)
        }
    }
}

extension View {
    func themeCard() -> some View { modifier(Theme.Card()) }
    func themePrimaryButton() -> some View { modifier(Theme.PrimaryButton()) }
    func themeDisplayText() -> some View { modifier(Theme.DisplayText()) }
}
