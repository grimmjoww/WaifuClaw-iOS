import SwiftUI
import UniformTypeIdentifiers

/// A native iPhone surface for real Team workflows. It deliberately shows only
/// locally persisted workflow evidence, not fixture agents or invented progress.
public struct NativeTeamWorkflowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = NativeTeamWorkflowController()
    @State private var showingFolderPicker = false

    public init() {}

    public var body: some View {
        @Bindable var controller = controller

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workflowComposer

                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                statusCard

                if let workflow = controller.selectedWorkflow {
                    workflowEvidence(workflow)
                } else {
                    ContentUnavailableView(
                        "No Saved Workflow",
                        systemImage: "person.3.sequence.fill",
                        description: Text("Start a Team workflow to save separate worker conversations, runs, evidence, and any supervisor synthesis on this iPhone."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }

                history
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Team")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await controller.reload() }
                }
                .disabled(controller.isRunning)
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { controller.selectWorkspace(url) }
            case .failure(let error):
                controller.errorMessage = error.localizedDescription
            }
        }
        .task {
            await controller.load()
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS may suspend this process. Cancelling records the local Team
            // workflow as cancelled rather than claiming background completion.
            if phase == .background { controller.cancel() }
        }
    }

    private var workflowComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Read-only multiagent workflow", systemImage: "person.3.sequence.fill")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Runs Explorer, Risk Reviewer, and Implementation Planner in separate conversations (up to three concurrent BYOK turns), then asks one no-tools Supervisor to synthesize their actual evidence. This can create multiple billable turns with your configured provider.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            TextEditor(text: goalBinding)
                .frame(minHeight: 96)
                .padding(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.textSecondary.opacity(0.3))
                }
                .accessibilityLabel("Team workflow goal")
                .disabled(controller.isRunning)

            HStack {
                Text("\(controller.goal.count)/\(NativeTeamLimits.goalCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(controller.goal.count > NativeTeamLimits.goalCharacters ? Theme.danger : Theme.textSecondary)
                Spacer()
                Button(controller.workspaceName == nil ? "Choose project" : "Change project") {
                    showingFolderPicker = true
                }
                .buttonStyle(.bordered)
                .disabled(controller.isRunning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow workers to read selected project files", isOn: projectReadBinding)
                    .disabled(controller.isRunning || controller.workspaceName == nil)
                if let workspaceName = controller.workspaceName {
                    Text("Selected project: \(workspaceName). When enabled, project file text may be sent to your configured model provider only when a worker uses a read-only tool. The Supervisor never receives file tools.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Off by default. Choose a Files folder before you can explicitly allow read-only project access.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                if controller.isRunning {
                    Button("Cancel workflow", role: .destructive, action: controller.cancel)
                        .buttonStyle(.bordered)
                    ProgressView()
                        .controlSize(.small)
                    Text("Cancellation propagates to workers and Supervisor.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button("Start workflow", action: controller.start)
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.goal.count > NativeTeamLimits.goalCharacters)
                }
                Spacer()
            }
        }
        .themeCard()
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: controller.isRunning ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .foregroundStyle(controller.isRunning ? Theme.warning : Theme.magenta)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.status)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text("Status is derived from the active task or the saved local workflow record; no build or test result is implied.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .themeCard()
    }

    private func workflowEvidence(_ workflow: NativeTeamWorkflowRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workflow.phase.displayName)
                        .font(.title3.bold())
                        .foregroundStyle(phaseColor(workflow.phase))
                    Text(workflow.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(workflow.projectReadAllowed ? "Project read consent on" : "No project access")
                    .font(.caption.bold())
                    .foregroundStyle(workflow.projectReadAllowed ? Theme.warning : Theme.textSecondary)
            }

            Text("Goal")
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)
            Text(workflow.userGoal)
                .textSelection(.enabled)
                .foregroundStyle(Theme.textPrimary)

            if let note = workflow.statusNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            Text("Worker evidence")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(workflow.workers) { worker in
                participantEvidence(worker)
            }

            Text("Supervisor")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            supervisorEvidence(workflow.supervisor)

            if let synthesis = workflow.finalSynthesis {
                Divider()
                Text("Final synthesis")
                    .font(.headline)
                Text(synthesis)
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .themeCard()
    }

    private func participantEvidence(_ worker: NativeTeamWorkerEvidence) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                identifierLine("Conversation", worker.conversationID.uuidString)
                identifierLine("Run", worker.runID?.uuidString ?? "No run ID was recorded")
                Text("Run evidence: \(worker.runEvidenceExcerpt.isEmpty ? "No event excerpt was recorded." : worker.runEvidenceExcerpt)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                if let error = worker.errorMessage {
                    Text("Failure: \(error)")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
                Text(worker.outputExcerpt.isEmpty ? "No worker response was recorded." : worker.outputExcerpt)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(.top, 5)
        } label: {
            HStack {
                Text(worker.role.displayName)
                    .font(.subheadline.bold())
                Spacer()
                Text(worker.runPhase?.rawValue ?? "not started")
                    .font(.caption.monospaced())
                    .foregroundStyle(runPhaseColor(worker.runPhase))
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func supervisorEvidence(_ supervisor: NativeTeamSupervisorEvidence) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                identifierLine("Conversation", supervisor.conversationID.uuidString)
                identifierLine("Run", supervisor.runID?.uuidString ?? "No supervisor run was needed or recorded")
                Text("Run evidence: \(supervisor.runEvidenceExcerpt.isEmpty ? "No event excerpt was recorded." : supervisor.runEvidenceExcerpt)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                if let error = supervisor.errorMessage {
                    Text("Failure: \(error)")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
                if !supervisor.outputExcerpt.isEmpty {
                    Text(supervisor.outputExcerpt)
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 5)
        } label: {
            HStack {
                Text("No file tools")
                    .font(.subheadline.bold())
                Spacer()
                Text(supervisor.runPhase?.rawValue ?? "not started")
                    .font(.caption.monospaced())
                    .foregroundStyle(runPhaseColor(supervisor.runPhase))
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local workflow history")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Only the most recent \(NativeTeamLimits.historyCount) bounded records are retained here. Worker conversations, runs, and events remain in LocalRunStore.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            ForEach(controller.workflows) { workflow in
                Button {
                    controller.selectWorkflow(workflow.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.userGoal)
                                .lineLimit(1)
                                .font(.subheadline)
                            Text(workflow.phase.displayName)
                                .font(.caption)
                                .foregroundStyle(phaseColor(workflow.phase))
                        }
                        Spacer()
                        if workflow.id == controller.selectedWorkflowID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.magenta)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .themeCard()
    }

    private var goalBinding: Binding<String> {
        Binding(
            get: { controller.goal },
            set: { controller.goal = $0 }
        )
    }

    private var projectReadBinding: Binding<Bool> {
        Binding(
            get: { controller.projectReadEnabled },
            set: { controller.projectReadEnabled = $0 }
        )
    }

    private func identifierLine(_ label: String, _ value: String) -> some View {
        Text("\(label) ID: \(value)")
            .font(.caption.monospaced())
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
    }

    private func phaseColor(_ phase: NativeTeamWorkflowPhase) -> Color {
        switch phase {
        case .completed: Theme.magenta
        case .partialFailure, .failed, .interrupted: Theme.warning
        case .cancelled: Theme.textSecondary
        case .workersRunning, .synthesizing: Theme.warning
        }
    }

    private func runPhaseColor(_ phase: LocalRunPhase?) -> Color {
        switch phase {
        case .finished: Theme.magenta
        case .failed: Theme.danger
        case .cancelled: Theme.textSecondary
        case .queued, .running: Theme.warning
        case nil: Theme.textSecondary
        }
    }
}
