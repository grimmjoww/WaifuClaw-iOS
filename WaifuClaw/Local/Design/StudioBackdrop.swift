import SwiftUI

/// Original, decorative Phantom Horizons atmosphere. All marks are artwork;
/// none of these dots or streaks represent fictitious agent activity.
struct StudioBackdrop: View {
    private let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.08, 0.05, 1.8), (0.74, 0.035, 1.3), (0.89, 0.12, 1.8),
        (0.17, 0.22, 1.0), (0.93, 0.31, 1.4), (0.04, 0.48, 1.2),
        (0.86, 0.54, 1.8), (0.14, 0.67, 1.1), (0.72, 0.79, 1.4),
        (0.07, 0.91, 1.4), (0.92, 0.97, 1.2)
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [Theme.background, Color(red: 0.105, green: 0.065, blue: 0.145), Theme.background],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [Theme.magenta.opacity(0.21), .clear],
                    center: .topTrailing,
                    startRadius: 18,
                    endRadius: max(geometry.size.width * 0.85, 240)
                )

                Canvas(opaque: false) { context, size in
                    for (x, y, radius) in stars {
                        let rect = CGRect(
                            x: size.width * x,
                            y: size.height * y,
                            width: radius,
                            height: radius
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(Theme.magentaSoft.opacity(0.55)))
                    }

                    for y in [0.18, 0.55, 0.83] as [CGFloat] {
                        var scratch = Path()
                        scratch.move(to: CGPoint(x: size.width * 0.69, y: size.height * y))
                        scratch.addLine(to: CGPoint(x: size.width * 1.04, y: size.height * y - 47))
                        context.stroke(scratch, with: .color(Theme.magenta.opacity(0.055)), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct StudioEyebrow: View {
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(Theme.magentaGradient)
                .frame(width: 12, height: 2)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.7)
                .foregroundStyle(Theme.magentaSoft)
        }
        .accessibilityElement(children: .combine)
    }
}
