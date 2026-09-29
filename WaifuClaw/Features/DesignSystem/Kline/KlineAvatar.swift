import SwiftUI

/// Kline's portrait avatar.
///
/// Loads the bundled `kline-operator.png` once (see the loud art note in
/// `KlinePanel.swift`). If the image is missing from the bundle — for
/// example after a packaging regression — this renders a magenta monogram
/// circle instead of a silent blank. Decorative for VoiceOver: the header
/// button already announces who she is.
struct KlineAvatar: View {
    var diameter: Double

    /// Loaded once; nil when the resource is absent from the bundle.
    private static let portrait: UIImage? = {
        guard
            let url = Bundle.main.url(forResource: "kline-operator", withExtension: "png"),
            let data = try? Data(contentsOf: url),
            let image = UIImage(data: data)
        else { return nil }
        return image
    }()

    var body: some View {
        Group {
            if let portrait = Self.portrait {
                Image(uiImage: portrait)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.magenta, Theme.magentaSoft],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("K")
                        .font(.system(size: diameter * 0.45, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(.circle)
        .overlay {
            Circle()
                .stroke(Theme.magenta.opacity(0.6), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 16) {
        KlineAvatar(diameter: 44)
        KlineAvatar(diameter: 64)
    }
    .padding()
    .background(Theme.background)
}
