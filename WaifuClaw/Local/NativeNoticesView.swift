import SwiftUI

struct NativeNoticesView: View {
    private var noticeText: String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Third-party notices could not be loaded from this app build. Please report this release packaging error."
        }
        return contents
    }

    var body: some View {
        ScrollView {
            Text(noticeText)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Third-party notices")
    }
}
