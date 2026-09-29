import SwiftUI

/// Horizontal progress bar with a magenta gradient fill and soft glow,
/// like the run-progress bars in the OutcomeRun mockup.
/// Width is relative to the container (containerRelativeFrame) — no GeometryReader.
struct ProgressBar: View {
    /// Progress from 0 to 1; clamped.
    var value: Double
    /// Bar thickness.
    var height: Double = 8

    private var clampedValue: Double { min(max(value, 0), 1) }

    var body: some View {
        Capsule()
            .fill(Theme.background)
            .frame(height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.magenta, Theme.magentaSoft],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .containerRelativeFrame(.horizontal) { width, _ in width * clampedValue }
                    .shadow(color: Theme.magenta.opacity(0.35), radius: 6)
            }
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int(clampedValue * 100)) percent")
    }
}

#Preview {
    VStack(spacing: 16) {
        ProgressBar(value: 0.33)
        ProgressBar(value: 0.87)
        ProgressBar(value: 1.0)
        ProgressBar(value: 0.0)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
