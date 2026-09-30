import SwiftUI

struct NativeHomeView: View {
    @AppStorage(OnboardingKeys.displayName) private var displayName = ""
    @State private var conversations: [LocalConversation] = []
    @State private var loadError: String?
    let openAgent: () -> Void
    let openWorkspace: () -> Void
    let openSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Good \(greeting), \(displayName.isEmpty ? "there" : displayName)")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.textPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kline · Your operator")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your coding workspace runs on this iPhone—not on a paired computer.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    KlineSpriteView(mood: .idle)
                        .frame(height: 230)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Wing and blink animation pauses when Reduce Motion is enabled")
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Continue building")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Inspect a project and talk with your model using your own key. The agent can list and read files; you can review and save your own edits in Workspace. The agent does not yet edit, execute code or claim tests passed.")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Open agent", action: openAgent)
                        .themePrimaryButton()
                    Button("Browse or edit project files", action: openWorkspace)
                        .font(.subheadline.bold())
                    NavigationLink {
                        NativeRunsView()
                    } label: {
                        Label("Inspect runs & evidence", systemImage: "list.bullet.rectangle")
                            .font(.subheadline.bold())
                    }
                    Button("Configure model & API key", action: openSettings)
                        .font(.subheadline.bold())
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent conversations")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.textPrimary)
                    if let loadError {
                        Text(loadError)
                            .foregroundStyle(Theme.danger)
                        Button("Retry") { Task { await reload() } }
                    } else if conversations.isEmpty {
                        Text("No local conversations yet. Start in Agent.")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(conversations.prefix(5)) { conversation in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                Text(conversation.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .themeCard()
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("WaifuClaw")
        .onAppear { Task { await reload() } }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "morning" }
        if hour < 18 { return "afternoon" }
        return "evening"
    }

    private func reload() async {
        do {
            conversations = try await LocalRunStore().listConversations()
            loadError = nil
        } catch {
            loadError = "Couldn't open this phone's conversation history: \(error.localizedDescription)"
        }
    }
}
