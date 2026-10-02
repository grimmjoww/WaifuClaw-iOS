import SwiftUI

private struct NativeRunSummary: Identifiable {
    let run: LocalRunRecord
    let conversation: LocalConversation
    var id: UUID { run.id }
}

/// An evidence browser for real local agent runs, not a simulated OutcomeRun
/// supervisor, review panel or remote desktop progress feed.
struct NativeRunsView: View {
    @State private var summaries: [NativeRunSummary] = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Reading local run evidence…")
            } else if let loadError {
                ContentUnavailableView {
                    Label("Runs could not be loaded", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Retry") { Task { await reload() } }
                }
            } else if summaries.isEmpty {
                ContentUnavailableView(
                    "No runs on this iPhone",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Start an Agent conversation to create real run evidence here.")
                )
            } else {
                List(summaries) { item in
                    NavigationLink {
                        NativeRunDetailView(run: item.run, conversationTitle: item.conversation.title)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.conversation.title)
                                .font(.headline)
                                .lineLimit(2)
                            HStack {
                                Label(item.run.phase.displayName, systemImage: item.run.phase.iconName)
                                    .foregroundStyle(item.run.phase.color)
                                Spacer()
                                Text(item.run.createdAt, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            Text("Run \(item.run.id.uuidString.prefix(8)) · evidence saved on this iPhone")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                    .listRowBackground(Theme.surface.opacity(0.88))
                    .listRowSeparatorTint(Theme.hairline)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await reload() }
            }
        }
        .navigationTitle("Runs")
        .background { StudioBackdrop() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let store = try LocalRunStore()
            var loaded: [NativeRunSummary] = []
            for conversation in try await store.listConversations() {
                for run in try await store.runs(in: conversation.id) {
                    loaded.append(NativeRunSummary(run: run, conversation: conversation))
                }
            }
            summaries = Array(loaded.sorted {
                if $0.run.createdAt != $1.run.createdAt {
                    return $0.run.createdAt > $1.run.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(150))
            loadError = nil
        } catch {
            loadError = "The on-device run database could not be read: \(error.localizedDescription)"
        }
    }
}

private struct NativeRunDetailView: View {
    let run: LocalRunRecord
    let conversationTitle: String
    @State private var currentRun: LocalRunRecord?
    @State private var events: [LocalRunEvent] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    StudioEyebrow(title: "Local run record")
                    Text(conversationTitle)
                        .font(Theme.sectionDisplay)
                    Label((currentRun ?? run).phase.displayName, systemImage: (currentRun ?? run).phase.iconName)
                        .foregroundStyle((currentRun ?? run).phase.color)
                    Text("Run ID: \(run.id.uuidString)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Started \(run.createdAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    if let error = (currentRun ?? run).errorMessage {
                        Text(error)
                            .foregroundStyle(Theme.danger)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .themeCard()

                StudioEyebrow(title: "Event timeline")
                if let loadError {
                    Text(loadError).foregroundStyle(Theme.danger)
                    Button("Retry") { Task { await reload() } }
                } else if events.isEmpty {
                    Text("No events were persisted for this run.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.kind)
                                .font(.subheadline.bold().monospaced())
                                .foregroundStyle(Theme.magenta)
                            Text(event.summary)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                            Text(event.createdAt.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themeCard()
                    }
                }
                Text("These are events actually recorded by the on-device agent. A completed model response does not certify tests, reviews, Git operations, or a code change.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Run evidence")
        .toolbar { Button("Refresh") { Task { await reload() } } }
        .task { await reload() }
    }

    private func reload() async {
        do {
            let store = try LocalRunStore()
            let runs = try await store.runs(in: run.conversationID)
            currentRun = runs.first(where: { $0.id == run.id })
            events = try await store.events(in: run.id)
            loadError = nil
        } catch {
            loadError = "The run's local evidence could not be opened: \(error.localizedDescription)"
        }
    }
}

private extension LocalRunPhase {
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .finished: "Response finished"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }

    var iconName: String {
        switch self {
        case .queued: "clock"
        case .running: "circle.dotted.circle"
        case .finished: "checkmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        }
    }

    var color: Color {
        switch self {
        case .queued: Theme.textSecondary
        case .running: Theme.warning
        case .finished: Theme.success
        case .failed: Theme.danger
        case .cancelled: Theme.textSecondary
        }
    }
}
