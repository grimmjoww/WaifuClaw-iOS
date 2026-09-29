import SwiftUI

/// Circular progress ring with a percentage label in the middle,
/// like the mockup's "87% Memory Recall" ring. Magenta gradient + soft glow.
struct ProgressRing: View {
    /// Progress from 0 to 1; clamped.
    var value: Double
    /// Outer diameter.
    var diameter: Double = 76
    /// Ring thickness.
    var lineWidth: Double = 8

    private var clampedValue: Double { min(max(value, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.background, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clampedValue)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [Theme.magenta, Theme.magentaSoft]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.magenta.opacity(0.35), radius: 6)
            Text("\(Int(clampedValue * 100))%")
                .font(.headline)
                .bold()
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(clampedValue * 100)) percent")
    }
}

#Preview {
    HStack(spacing: 24) {
        ProgressRing(value: 0.87)
        ProgressRing(value: 0.41, diameter: 64, lineWidth: 6)
        ProgressRing(value: 1.0)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
