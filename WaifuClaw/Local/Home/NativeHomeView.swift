import SwiftUI

struct NativeHomeView: View {
    @AppStorage(OnboardingKeys.displayName) private var displayName = ""
    @AppStorage(CompanionID.selectionStorageKey) private var selectedCompanionID = CompanionID.defaultSelection.rawValue
    @State private var conversations: [LocalConversation] = []
    @State private var loadError: String?

    let openAgent: () -> Void
    let openWorkspace: () -> Void
    let openSettings: () -> Void
    let openConversation: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                studioMasthead
                companionHero
                quickActions
                teamCard
                guardianCard
                conversationCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background { StudioBackdrop() }
        .navigationTitle("WaifuClaw")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await reload() } }
    }

    private var studioMasthead: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                StudioEyebrow(title: "WaifuClaw / Mobile Studio")
                Spacer()
                Image(systemName: "sparkle")
                    .font(.caption)
                    .foregroundStyle(Theme.magentaSoft)
                    .accessibilityHidden(true)
            }
            Text("PHANTOM HORIZONS")
                .font(Theme.studioMark)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
                .foregroundStyle(Theme.displayGradient)
                .shadow(color: Theme.magenta.opacity(0.48), radius: 10)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Text("STUDIOS")
                    .font(.caption.weight(.semibold))
                    .tracking(4)
                    .foregroundStyle(Theme.textSecondary)
                Rectangle()
                    .fill(Theme.magentaGradient)
                    .frame(height: 1)
            }
            Text("Good \(greeting), \(displayName.isEmpty ? "there" : displayName)")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 7)
            Text("Your own coding studio, on your iPhone.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3)
    }

    private var companionHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .leading, spacing: 9) {
                    StudioEyebrow(title: "Animated companion")
                    Text(selectedCompanion.definition.name)
                        .font(Theme.sectionDisplay)
                        .foregroundStyle(Theme.textPrimary)
                    Text("A guide, not a remote worker")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Label("ON DEVICE", systemImage: "iphone.gen3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.success)
                        .accessibilityLabel("The app's workspace and sprite run on this iPhone")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CompanionSpriteView(mood: .idle)
                    .frame(width: 175, height: 215)
                    .accessibilityHint("Her articulated movement and blinking pause when Reduce Motion is enabled")
                    .background {
                    RadialGradient(
                        colors: [Theme.magenta.opacity(0.23), Theme.magenta.opacity(0.05), .clear],
                        center: .center,
                        startRadius: 15,
                        endRadius: 170
                    )
                }
            }

            NavigationLink {
                ScrollView { NativeCompanionChooserView().padding() }
                    .background { StudioBackdrop() }
                    .navigationTitle("Companions")
            } label: {
                HStack(spacing: 6) {
                    Label("Choose your animated companion", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Theme.magentaSoft)
                .frame(minHeight: 40)
            }
            .accessibilityIdentifier("chooseCompanion")
        }
        .themeCard()
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioEyebrow(title: "Your workspace")
            Text("Create · inspect · refine")
                .font(Theme.sectionDisplay)
                .foregroundStyle(Theme.textPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button(action: openAgent) {
                    actionTile("Agent", subtitle: "Ask & review edits", icon: "sparkle.magnifyingglass")
                }
                .accessibilityLabel("Open agent")

                Button(action: openWorkspace) {
                    actionTile("Workspace", subtitle: "Browse & edit files", icon: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityLabel("Browse or edit project files")

                NavigationLink {
                    NativeGitView()
                } label: {
                    actionTile("Git", subtitle: "Clone, fetch & pull", icon: "arrow.triangle.branch")
                }
                .accessibilityLabel("Clone, fetch or pull Git")

                NavigationLink {
                    NativeRunsView()
                } label: {
                    actionTile("Runs", subtitle: "Actual run evidence", icon: "list.bullet.rectangle")
                }
                .accessibilityLabel("Inspect runs & evidence")
            }

            Text("Agent reads your selected Files folder and can propose a bounded edit. Nothing is written until you inspect and approve the complete diff; builds and tests are not implied.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Button("Configure model & API key", action: openSettings)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.magentaSoft)
                .frame(minHeight: 40)
        }
        .themeCard()
    }

    private func actionTile(_ title: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.magentaSoft)
                .frame(width: 34, height: 30, alignment: .leading)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(12)
        .background(Theme.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.magenta.opacity(0.22), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }

    private var teamCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioEyebrow(title: "Multiagent / Read-only")
            Text("Team workflow")
                .font(Theme.sectionDisplay)
                .foregroundStyle(Theme.textPrimary)
            Text("Explorer, Risk Reviewer and Implementation Planner run separately; a supervisor synthesizes their saved evidence. Multiple BYOK model turns may be billable.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            NavigationLink {
                NativeTeamWorkflowView()
            } label: {
                Label("Start a multiagent workflow", systemImage: "person.3.sequence.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.magentaSoft)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private var guardianCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioEyebrow(title: "Project Guardian")
            Text("Review what changed")
                .font(Theme.sectionDisplay)
                .foregroundStyle(Theme.textPrimary)
            Text("Manually compare approved on-device file hashes without uploading source or pretending a build ran. This is not an automatic background agent.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            NavigationLink {
                NativeGuardianView()
            } label: {
                Label("Review project changes", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.magentaSoft)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioEyebrow(title: "Local history")
            Text("Recent conversations")
                .font(Theme.sectionDisplay)
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
                    Button {
                        openConversation(conversation.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                Text(conversation.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(Theme.magentaSoft)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open this saved conversation in Agent")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private var selectedCompanion: CompanionID {
        CompanionID.selected(from: selectedCompanionID)
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
