import SwiftUI

/// Settings → "Replay intro": the welcome pages again, outside first launch.
///
/// Entry point for the Settings leaf: present `ReplayIntroView(onDone:)`
/// (e.g. in a sheet) from a "Replay intro / guide" row.
struct ReplayIntroView: View {
    var onDone: () -> Void

    init(onDone: @escaping () -> Void = {}) {
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                IntroPagesView(onContinue: onDone)
            }
            .navigationTitle("Welcome guide")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
