import Observation
import SwiftUI

@Observable
@MainActor
final class NativeAutomaticMemoryController {
    private let preferences = NativeMemoryAutocapturePreferenceStore()
    private let queue: NativeMemoryPendingCandidateQueue?
    private let graph: LocalNeuralMemoryStore?

    var projectID: String?
    var projectName = ""
    var isEnabled = false
    var records: [NativeMemoryPendingCandidateRecord] = []
    var interruptedApprovals: [NativeMemoryPendingCandidateRecord] = []
    var isBusy = false
    var status = "Automatic memory suggestions are off until you opt in for this project."
    var errorMessage: String?

    init() {
        do {
            queue = try NativeMemoryPendingCandidateQueue()
            graph = try LocalNeuralMemoryStore()
        } catch {
            queue = nil
            graph = nil
            errorMessage = "The on-device memory review queue could not be opened: \(error.localizedDescription)"
        }
    }

    func load(projectID: String, projectName: String) async {
        guard NativeMemoryAutocapturePreferenceStore.isValidProjectID(projectID) else {
            errorMessage = "Select a valid Files project before reviewing its memory notes."
            return
        }
        if self.projectID != projectID {
            records = []
            interruptedApprovals = []
        }
        self.projectID = projectID
        self.projectName = projectName
        isEnabled = preferences.preference(for: projectID) == .optedIn
        guard let queue else { return }
        do {
            let all = try await queue.records(in: projectID)
            records = all.filter { $0.state == .pending }
            interruptedApprovals = all.filter { $0.state == .approvalClaimed }
            errorMessage = nil
            status = records.isEmpty && interruptedApprovals.isEmpty
                ? "No unverified notes await review for this project."
                : "\(records.count) note(s) await review; \(interruptedApprovals.count) interrupted approval(s) need inspection."
        } catch {
            records = []
            interruptedApprovals = []
            errorMessage = "Pending notes could not be loaded: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let projectID, queue != nil, graph != nil else { return }
        preferences.setPreference(enabled ? .optedIn : .optedOut, for: projectID)
        isEnabled = preferences.preference(for: projectID) == .optedIn
        status = isEnabled
            ? "Future finished agent runs may draft local, unverified notes for this project. Review is required before use."
            : "Automatic notes are off. Existing pending notes remain here until you review or discard them."
    }

    func approve(_ record: NativeMemoryPendingCandidateRecord) async {
        guard !isBusy, let projectID, record.projectID == projectID,
              record.state == .pending, let queue, let graph else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await queue.approveFromUser(
                candidateID: record.id,
                projectID: projectID,
                approvalNote: "Reviewed the exact unverified model statement in Automatic memory",
                memoryStore: graph
            )
            let all = try await queue.records(in: projectID)
            records = all.filter { $0.state == .pending }
            interruptedApprovals = all.filter { $0.state == .approvalClaimed }
            errorMessage = nil
            status = "One reviewed note was saved as a source-labeled memory fact. Model output is not independent verification."
        } catch {
            let facts = (try? await graph.memories(in: projectID)) ?? []
            let alreadySaved = facts.contains { $0.provenance.sourceRecordID == record.id }
            errorMessage = alreadySaved
                ? "This reviewed memory was saved, but pending-queue cleanup failed. Its approval cannot be retried. Inspect Approved facts in Memory. \(error.localizedDescription)"
                : "Approval did not confirm a graph memory. Inspect Approved facts before trying anything else: \(error.localizedDescription)"
            let all = (try? await queue.records(in: projectID)) ?? []
            records = all.filter { $0.state == .pending }
            interruptedApprovals = all.filter { $0.state == .approvalClaimed }
        }
    }

    func discard(_ record: NativeMemoryPendingCandidateRecord) async {
        guard !isBusy, let projectID, record.projectID == projectID,
              record.state == .pending, let queue else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await queue.deletePendingCandidate(id: record.id, projectID: projectID)
            records = try await queue.pendingRecords(in: projectID)
            errorMessage = nil
            status = "Unverified note discarded; no approved memory was created."
        } catch {
            errorMessage = "The note was not discarded: \(error.localizedDescription)"
        }
    }

    func discardAllPending() async {
        guard !isBusy, let projectID, let queue else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let removed = try await queue.deleteAllPending(in: projectID)
            records = try await queue.pendingRecords(in: projectID)
            errorMessage = nil
            status = "Discarded \(removed) unverified note(s) in this project. Approved memories and interrupted approval claims were not changed."
        } catch {
            errorMessage = "The pending notes were not cleared: \(error.localizedDescription)"
        }
    }
}

struct NativeAutomaticMemoryView: View {
    let projectID: String
    let projectName: String

    @State private var controller = NativeAutomaticMemoryController()
    @State private var reviewing: NativeMemoryPendingCandidateRecord?
    @State private var discarding: NativeMemoryPendingCandidateRecord?
    @State private var showingDiscardAll = false

    var body: some View {
        @Bindable var controller = controller
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    StudioEyebrow(title: "Neural memory / automatic notes")
                    Text(projectName)
                        .font(.custom("CinzelDecorative-Bold", size: 21, relativeTo: .title3))
                        .foregroundStyle(Theme.textPrimary)
                    Toggle("Automatically draft notes from finished agent runs", isOn: Binding(
                        get: { controller.isEnabled },
                        set: { controller.setEnabled($0) }
                    ))
                    .disabled(controller.projectID == nil || controller.errorMessage != nil)
                    .tint(Theme.magenta)
                    Text("Off by default. When on, successful runs may create up to three local draft notes; failed or cancelled runs do not. Drafts are unverified model statements. Nothing becomes an approved graph fact or goes to your model provider until you separately review a note and permit model sharing for this project.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .themeCard()

                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Pending review (\(controller.records.count))")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if controller.records.isEmpty {
                        Text("No suggestions yet. Finish a real agent run in this project after opting in; the run may produce no eligible notes.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(controller.records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Unverified model statement", systemImage: "questionmark.circle")
                                .font(.caption.bold())
                                .foregroundStyle(Theme.magenta)
                            Text(record.candidate.statement)
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                            Text("Run \(record.candidate.provenance.runID.uuidString.prefix(8)) · \(record.enqueuedAt, style: .date)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            HStack(spacing: 12) {
                                Button("Review exact note") { reviewing = record }
                                    .disabled(controller.isBusy)
                                Button("Discard", role: .destructive) { discarding = record }
                                    .disabled(controller.isBusy)
                            }
                            Divider()
                        }
                    }
                    if !controller.records.isEmpty {
                        Button("Discard all pending notes", role: .destructive) {
                            showingDiscardAll = true
                        }
                        .disabled(controller.isBusy)
                    }
                }
                .themeCard()
                if !controller.interruptedApprovals.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Interrupted approvals (\(controller.interruptedApprovals.count))", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.danger)
                        Text("An approval began but queue cleanup was interrupted. The fact may already exist. For safety it cannot be retried automatically; inspect Approved facts on the main Memory screen before taking further action.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(controller.interruptedApprovals) { record in
                            Text(record.candidate.statement)
                                .textSelection(.enabled)
                                .foregroundStyle(Theme.textPrimary)
                            Divider()
                        }
                    }
                    .themeCard()
                }
                Text(controller.status)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Automatic memory")
        .task(id: projectID) { await controller.load(projectID: projectID, projectName: projectName) }
        .sheet(item: $reviewing) { record in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Exact proposed note")
                            .font(.headline)
                        Text(record.candidate.statement)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("This came from model output in a real finished run. Approving saves it to this project's on-device graph with an unverified-model source label. It does not verify its truth. Sharing approved memories with a model is a separate switch on the Memory screen.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        Text("Run ID: \(record.candidate.provenance.runID.uuidString)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding()
                }
                .background { StudioBackdrop() }
                .navigationTitle("Review memory note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { reviewing = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Approve exact note") {
                            reviewing = nil
                            Task { await controller.approve(record) }
                        }
                        .disabled(controller.isBusy)
                    }
                }
            }
        }
        .alert("Discard this exact unverified note?", isPresented: Binding(
            get: { discarding != nil },
            set: { if !$0 { discarding = nil } }
        )) {
            Button("Discard note", role: .destructive) {
                if let record = discarding { Task { await controller.discard(record) } }
                discarding = nil
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: {
            Text(discarding?.candidate.statement ?? "")
        }
        .alert("Discard all pending notes in this project?", isPresented: $showingDiscardAll) {
            Button("Discard all pending notes", role: .destructive) {
                Task { await controller.discardAllPending() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(controller.records.count) unverified draft(s) only. Approved memories, other projects and interrupted approval claims remain unchanged.")
        }
    }
}
