import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class NativeGuardianController {
    private struct ConfirmedProvider: Equatable {
        let endpoint: URL
        let model: String

        var host: String { endpoint.host ?? "unknown host" }
    }

    var projectName: String?
    var snapshot: NativeGuardianProjectSnapshot?
    var progress: NativeGuardianScanProgress?
    var aiReports: [NativeGuardianAIReviewReport] = []
    var pendingAIReview: NativeGuardianReviewRecord?
    var pendingAIProviderHost: String?
    var pendingAIModel: String?
    var statusMessage = "Manual only. Choose a Files project, then scan when you want a local review."
    var errorMessage: String?
    var isScanning = false
    var isRequestingAIReview = false
    var showingFolderPicker = false
    var showingInitialBaselineConfirmation = false
    var showingAdvanceBaselineConfirmation = false
    var showingDeleteConfirmation = false
    var showingDeleteAIReportsConfirmation = false
    var showingAIReviewConfirmation = false

    private let permission: NativeProjectPermission
    private var store: NativeGuardianStore?
    private var aiReportStore: NativeGuardianAIReviewStore?
    private var projectURL: URL?
    private var projectID: String?
    private var activeScanID: UUID?
    private var approvableReviewID: UUID?
    private var activeAIReviewID: UUID?
    private var activeAIReviewTask: Task<Void, Never>?
    private var pendingConfirmedProvider: ConfirmedProvider?

    init(
        permission: NativeProjectPermission = NativeProjectPermission(),
        store: NativeGuardianStore? = nil,
        aiReportStore: NativeGuardianAIReviewStore? = nil
    ) {
        self.permission = permission
        do {
            self.store = try store ?? NativeGuardianStore()
        } catch {
            present(error)
        }
        do {
            self.aiReportStore = try aiReportStore ?? NativeGuardianAIReviewStore()
        } catch {
            present(error)
        }
    }

    var baseline: NativeGuardianBaseline? { snapshot?.baseline }

    /// Only a scan completed in this visible session may advance a baseline.
    /// After a relaunch, scan again rather than approving stale evidence.
    var currentReview: NativeGuardianReviewRecord? {
        guard let approvableReviewID else { return nil }
        return snapshot?.reviews.first(where: { $0.id == approvableReviewID })
    }

    var historicalReviews: [NativeGuardianReviewRecord] {
        Array((snapshot?.reviews ?? []).reversed())
    }

    var historicalAIReports: [NativeGuardianAIReviewReport] {
        Array(aiReports.reversed())
    }

    var canSetInitialBaseline: Bool {
        guard !isRequestingAIReview, let review = currentReview else { return false }
        return baseline == nil && review.baselineID == nil
    }

    var canAcceptAdvance: Bool {
        guard !isRequestingAIReview, let review = currentReview, let baseline else { return false }
        return review.baselineID == baseline.id && review.hasChanges
    }

    /// A provider request is possible only from the persisted review produced by
    /// the currently visible scan. This keeps an old historical record from
    /// silently becoming a new network request after a relaunch.
    var canRequestAIReview: Bool {
        guard !isScanning,
              !isRequestingAIReview,
              let review = currentReview,
              let projectID,
              review.projectID == projectID,
              review.hasChanges,
              snapshot?.reviews.contains(where: { $0.id == review.id }) == true,
              aiReviewLimitMessage(for: review) == nil
        else { return false }
        return (try? savedProvider()) != nil
    }

    var aiReviewAvailabilityMessage: String {
        guard let review = currentReview else {
            return "Run a local scan with changes first. Optional provider review never uses an old or unpersisted scan."
        }
        guard review.hasChanges else {
            return "This persisted local scan has no changes, so there is no model review to send."
        }
        if let limitMessage = aiReviewLimitMessage(for: review) { return limitMessage }
        do {
            let provider = try savedProvider()
            return "Ready only after confirmation: direct to \(provider.host), model \(provider.model). Your provider may charge."
        } catch {
            return "Optional model review is unavailable: \(userMessage(for: error))"
        }
    }

    func load() async {
        guard let store else { return }
        do {
            guard let url = try permission.selectedFolder() else {
                projectURL = nil
                projectID = nil
                projectName = nil
                snapshot = nil
                aiReports = []
                statusMessage = "Manual only. Choose a Files project to create or compare a local baseline."
                return
            }
            try configure(url: url, store: store, restored: true)
            if let projectID { await refreshAIReports(projectID: projectID) }
        } catch {
            present(error)
            statusMessage = "Guardian did not scan automatically. Choose the Files folder again, then scan manually."
        }
    }

    func chooseFolder(_ url: URL) async {
        guard !isScanning, !isRequestingAIReview else { return }
        guard let store else { return }
        do {
            _ = try permission.selectFolder(url)
            try configure(url: url, store: store, restored: false)
            if let projectID { await refreshAIReports(projectID: projectID) }
        } catch {
            present(error)
            statusMessage = "Folder selection failed. No Guardian baseline changed."
        }
    }

    func presentPickerError(_ error: Error) {
        errorMessage = "Files could not select that folder: \(error.localizedDescription)"
        statusMessage = "Folder selection failed."
    }

    func scanNow() {
        guard !isScanning,
              !isRequestingAIReview,
              let rootURL = projectURL,
              let projectID,
              let store
        else {
            if projectURL == nil { present(NativeGuardianError.noSelectedProject) }
            return
        }

        let baseline = snapshot?.baseline
        let scanID = UUID()
        activeScanID = scanID
        approvableReviewID = nil
        isScanning = true
        progress = NativeGuardianScanProgress(phase: .enumerating, visitedEntries: 0, hashedFiles: 0, omittedFiles: 0)
        errorMessage = nil
        statusMessage = "Scanning locally. Guardian is only hashing eligible UTF-8 text; it is not running tests or a build."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let scanner = try NativeGuardianScanner(rootURL: rootURL)
                let review = try scanner.scan(baseline: baseline) { update in
                    DispatchQueue.main.async { [weak self] in
                        guard self?.activeScanID == scanID else { return }
                        self?.progress = update
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.activeScanID == scanID,
                          self.projectID == projectID
                    else { return }
                    do {
                        self.snapshot = try store.recordReview(review, for: projectID)
                        self.approvableReviewID = review.id
                        self.progress = NativeGuardianScanProgress(
                            phase: .complete,
                            visitedEntries: review.visitedEntries,
                            hashedFiles: review.candidateFiles.count,
                            omittedFiles: review.omissions.count
                        )
                        if review.baselineID == nil {
                            self.statusMessage = "Local inventory complete. Review the files, then explicitly set the first baseline if it is correct."
                        } else if review.hasChanges {
                            self.statusMessage = "Local comparison complete. Review the exact hashes and sizes before accepting a new baseline."
                        } else {
                            self.statusMessage = "No eligible UTF-8 text changes were found since the approved baseline. No test or build was run."
                        }
                    } catch {
                        self.present(error)
                        self.statusMessage = "Scan evidence was not saved, so no baseline can be accepted."
                    }
                    self.isScanning = false
                    self.activeScanID = nil
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeScanID == scanID else { return }
                    self.isScanning = false
                    self.activeScanID = nil
                    self.progress = nil
                    self.present(error)
                    self.statusMessage = "Guardian did not save a partial review or advance the baseline."
                }
            }
        }
    }

    func requestInitialBaseline() {
        guard !isRequestingAIReview, canSetInitialBaseline else { return }
        showingInitialBaselineConfirmation = true
    }

    func confirmInitialBaseline() {
        approveCurrentReview(initial: true)
    }

    func requestAdvanceBaseline() {
        guard !isRequestingAIReview, canAcceptAdvance else { return }
        showingAdvanceBaselineConfirmation = true
    }

    func confirmAdvanceBaseline() {
        approveCurrentReview(initial: false)
    }

    func requestAIReview() {
        guard canRequestAIReview,
              let review = currentReview
        else { return }
        do {
            let provider = try savedProvider()
            pendingAIReview = review
            pendingConfirmedProvider = provider
            pendingAIProviderHost = provider.host
            pendingAIModel = provider.model
            errorMessage = nil
            statusMessage = "Review confirmation required. No project source has been sent."
            showingAIReviewConfirmation = true
        } catch {
            present(error)
            statusMessage = "No provider review was started. Save a readable provider endpoint, model, and key first."
        }
    }

    func cancelAIReviewConfirmation() {
        guard !isRequestingAIReview else { return }
        pendingAIReview = nil
        pendingConfirmedProvider = nil
        pendingAIProviderHost = nil
        pendingAIModel = nil
    }

    func confirmAIReviewRequest() {
        guard !isRequestingAIReview,
              let review = pendingAIReview,
              let expectedProvider = pendingConfirmedProvider,
              let rootURL = projectURL,
              let projectID,
              let store,
              let aiReportStore,
              review.projectID == projectID,
              snapshot?.reviews.contains(where: { $0.id == review.id }) == true,
              aiReviewLimitMessage(for: review) == nil
        else {
            cancelAIReviewConfirmation()
            errorMessage = "That local Guardian review is no longer available. Scan again before requesting a model opinion."
            statusMessage = "No provider request was sent."
            return
        }

        // Re-read both configuration and key immediately before provider setup.
        // A changed endpoint/model must be shown in a new confirmation rather
        // than silently redirecting the already-confirmed source request.
        do {
            let currentProvider = try savedProvider()
            guard currentProvider == expectedProvider else {
                cancelAIReviewConfirmation()
                errorMessage = "Provider settings changed after confirmation. Review the recipient and model again before sending anything."
                statusMessage = "No provider request was sent."
                return
            }
        } catch {
            cancelAIReviewConfirmation()
            present(error)
            statusMessage = "No provider request was sent because a saved provider key or configuration is unavailable."
            return
        }

        let requestID = UUID()
        showingAIReviewConfirmation = false
        pendingAIReview = nil
        pendingConfirmedProvider = nil
        pendingAIProviderHost = nil
        pendingAIModel = nil
        activeAIReviewID = requestID
        isRequestingAIReview = true
        errorMessage = nil
        statusMessage = "Preparing only the confirmed bounded excerpts. Guardian rechecks each current file hash before any provider request."
        activeAIReviewTask = Task { [weak self] in
            guard let self else { return }
            await self.runAIReview(
                requestID: requestID,
                rootURL: rootURL,
                projectID: projectID,
                review: review,
                expectedProvider: expectedProvider,
                guardianStore: store,
                reportStore: aiReportStore
            )
        }
    }

    func cancelAIReview() {
        guard isRequestingAIReview else { return }
        activeAIReviewTask?.cancel()
        statusMessage = "Stopping the optional provider review. No model opinion will be shown unless Guardian saves an actual completed report."
    }

    func deleteHistory() async {
        guard !isScanning,
              !isRequestingAIReview,
              let projectID,
              let store,
              let aiReportStore
        else { return }
        do {
            // Remove linked reports first. If this fails, retain the base
            // Guardian history rather than leaving reports without their scan.
            try await aiReportStore.deleteReports(projectID: projectID)
            try store.deleteHistory(projectID: projectID)
            guard self.projectID == projectID else { return }
            snapshot = nil
            aiReports = []
            approvableReviewID = nil
            progress = nil
            errorMessage = nil
            statusMessage = "Deleted this project's local Guardian hashes, reviews, and linked model reports. Project files were not changed."
        } catch {
            present(error)
            statusMessage = "Guardian history was not fully deleted. Local project files were not changed."
        }
    }

    func deleteAIReports() async {
        guard !isScanning,
              !isRequestingAIReview,
              let projectID,
              let aiReportStore
        else { return }
        do {
            try await aiReportStore.deleteReports(projectID: projectID)
            guard self.projectID == projectID else { return }
            aiReports = []
            errorMessage = nil
            statusMessage = "Deleted this project's saved model opinions and provider-review records. Local Guardian hashes and reviews remain."
        } catch {
            present(error)
            statusMessage = "Saved model opinions were not deleted. Local project files were not changed."
        }
    }

    private func configure(url: URL, store: NativeGuardianStore, restored: Bool) throws {
        _ = try NativeGuardianScanner(rootURL: url)
        let id = NativeProjectIdentity.id(for: url)
        if projectID != nil, projectID != id {
            // Folder controls are disabled while a request is active, but a
            // restored Files grant can still change between view lifecycles.
            // Cancel and detach the old project rather than presenting its
            // report under the new identity.
            activeAIReviewTask?.cancel()
            activeAIReviewTask = nil
            activeAIReviewID = nil
            isRequestingAIReview = false
            pendingAIReview = nil
            pendingConfirmedProvider = nil
            pendingAIProviderHost = nil
            pendingAIModel = nil
            showingAIReviewConfirmation = false
        }
        projectURL = url
        projectID = id
        projectName = url.lastPathComponent
        snapshot = try store.load(projectID: id)
        aiReports = []
        approvableReviewID = nil
        progress = nil
        errorMessage = nil
        if let baseline = snapshot?.baseline {
            statusMessage = "Restored \(projectName ?? "Files project"). Baseline approved \(baseline.approvedAt.formatted(date: .abbreviated, time: .shortened)). Manual scan only."
        } else if restored {
            statusMessage = "Restored \(projectName ?? "Files project"). No approved Guardian baseline yet; scan manually to inspect local hashes."
        } else {
            statusMessage = "Selected \(projectName ?? "Files project"). Guardian will not scan until you tap Scan now."
        }
    }

    private func approveCurrentReview(initial: Bool) {
        guard !isRequestingAIReview,
              let projectID,
              let review = currentReview,
              let store
        else { return }
        do {
            snapshot = try store.approveBaseline(projectID: projectID, reviewID: review.id)
            approvableReviewID = nil
            errorMessage = nil
            statusMessage = initial
                ? "Approved the first local baseline from the review you inspected. Guardian did not change project files or run tests/builds."
                : "Approved the reviewed local inventory as the new baseline. Guardian did not change project files or run tests/builds."
        } catch {
            present(error)
            statusMessage = "No baseline was advanced. Scan again and review the result."
        }
    }

    private func present(_ error: Error) {
        errorMessage = userMessage(for: error)
    }

    private func userMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func savedProvider() throws -> ConfirmedProvider {
        let configuration = try LocalModelPreferences.load()
        guard let key = try KeychainStore.agentKey(),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LocalModelConfigurationError.missingKey
        }
        return ConfirmedProvider(endpoint: configuration.endpoint, model: configuration.model)
    }

    private func aiReviewLimitMessage(for review: NativeGuardianReviewRecord) -> String? {
        guard review.changes.count <= NativeGuardianAIReviewLimits.maximumChanges else {
            return "This persisted scan has \(review.changes.count) changed paths. Optional review is limited to \(NativeGuardianAIReviewLimits.maximumChanges) changed paths, so no source can be sent."
        }
        let currentChanges = review.changes.count { $0.kind == .added || $0.kind == .changed }
        guard currentChanges <= NativeGuardianAIReviewLimits.maximumCurrentFiles else {
            return "This persisted scan has \(currentChanges) current changed files. Optional review is limited to \(NativeGuardianAIReviewLimits.maximumCurrentFiles) current excerpts, so no source can be sent."
        }
        return nil
    }

    private func refreshAIReports(projectID: String) async {
        guard let aiReportStore else { return }
        do {
            let reports = try await aiReportStore.reports(projectID: projectID)
            guard self.projectID == projectID else { return }
            aiReports = reports
        } catch {
            guard self.projectID == projectID else { return }
            present(error)
            statusMessage = "Saved model-opinion history could not be loaded. Guardian did not scan or send anything."
        }
    }

    private func runAIReview(
        requestID: UUID,
        rootURL: URL,
        projectID: String,
        review: NativeGuardianReviewRecord,
        expectedProvider: ConfirmedProvider,
        guardianStore: NativeGuardianStore,
        reportStore: NativeGuardianAIReviewStore
    ) async {
        defer { finishAIReview(requestID: requestID) }
        do {
            try Task.checkCancellation()
            let configuration = try LocalModelPreferences.load()
            guard ConfirmedProvider(endpoint: configuration.endpoint, model: configuration.model) == expectedProvider else {
                guard isCurrentAIReview(requestID, projectID: projectID) else { return }
                errorMessage = "Provider settings changed after confirmation. No provider request was sent."
                statusMessage = "Review the new recipient and model before sending anything."
                return
            }
            guard let key = try KeychainStore.agentKey(),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw LocalModelConfigurationError.missingKey
            }
            let provider = try OpenAICompatibleProvider(
                baseURL: configuration.endpoint,
                model: configuration.model,
                apiKey: key
            )
            let reviewer = NativeGuardianAIReviewer(
                guardianStore: guardianStore,
                reportStore: reportStore
            )
            let report = try await reviewer.review(
                rootURL: rootURL,
                guardianReview: review,
                provider: provider
            )
            guard isCurrentAIReview(requestID, projectID: projectID) else { return }
            aiReports = try await reportStore.reports(projectID: projectID)
            errorMessage = nil
            switch report.status {
            case .completed:
                statusMessage = "Saved a local model opinion. It is not verification; Guardian did not run tests, builds, execution, or security checks."
            case .refused:
                statusMessage = "No source was sent. Guardian saved the bounded-review refusal: \(report.failure?.userMessage ?? "unknown refusal")."
            case .cancelled:
                statusMessage = "Provider review was cancelled. Guardian saved a local cancellation record; no model opinion was shown."
            case .providerFailed:
                statusMessage = "Provider review did not produce a model opinion. Guardian saved the local outcome: \(report.failure?.userMessage ?? "provider failure")."
            }
        } catch is CancellationError {
            guard isCurrentAIReview(requestID, projectID: projectID) else { return }
            errorMessage = nil
            statusMessage = "Provider review was cancelled before Guardian could save a model opinion."
        } catch {
            guard isCurrentAIReview(requestID, projectID: projectID) else { return }
            present(error)
            statusMessage = "Optional provider review failed. No model opinion was shown as verification."
        }
    }

    private func isCurrentAIReview(_ requestID: UUID, projectID: String) -> Bool {
        activeAIReviewID == requestID && self.projectID == projectID
    }

    private func finishAIReview(requestID: UUID) {
        guard activeAIReviewID == requestID else { return }
        isRequestingAIReview = false
        activeAIReviewID = nil
        activeAIReviewTask = nil
    }
}

/// A user-controlled, on-device project hash review. It reads only the shared
/// Files folder the user selected, stores no source contents, and never starts
/// a background schedule. A separate, explicit confirmation can optionally
/// send bounded current excerpts to a user-configured BYOK provider.
public struct NativeGuardianView: View {
    @State private var controller = NativeGuardianController()

    public init() {}

    public var body: some View {
        @Bindable var controller = controller

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                projectCard
                manualOnlyNotice
                scanCard
                reviewEvidence
                historyCard
                aiReportHistoryCard
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(controller.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Guardian")
        .fileImporter(
            isPresented: $controller.showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await controller.chooseFolder(url) }
                }
            case .failure(let error):
                controller.presentPickerError(error)
            }
        }
        .alert("Set the first baseline?", isPresented: $controller.showingInitialBaselineConfirmation) {
            Button("Set baseline", role: .destructive) { controller.confirmInitialBaseline() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This saves only the reviewed paths, UTF-8 file hashes, and byte sizes locally on this iPhone. It does not upload source text, edit your project, run tests, or run a build.")
        }
        .alert("Accept this reviewed inventory?", isPresented: $controller.showingAdvanceBaselineConfirmation) {
            Button("Accept new baseline", role: .destructive) { controller.confirmAdvanceBaseline() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the approved local hash baseline with the inventory from the review you just inspected. It does not change project files, run tests, or run a build.")
        }
        .alert("Delete Guardian history?", isPresented: $controller.showingDeleteConfirmation) {
            Button("Delete hashes and model reports", role: .destructive) {
                Task { await controller.deleteHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes this project’s local Guardian baseline, review history, and all linked saved model opinions/reports from app storage. It does not delete or modify Files project content.")
        }
        .alert("Delete saved model opinions?", isPresented: $controller.showingDeleteAIReportsConfirmation) {
            Button("Delete model opinions", role: .destructive) {
                Task { await controller.deleteAIReports() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only this project’s locally saved provider opinions and report metadata. Local Guardian hashes, baselines, and scan reviews remain. Files project content is not changed.")
        }
        .sheet(isPresented: $controller.showingAIReviewConfirmation, onDismiss: {
            controller.cancelAIReviewConfirmation()
        }) {
            if let review = controller.pendingAIReview,
               let host = controller.pendingAIProviderHost,
               let model = controller.pendingAIModel {
                NativeGuardianAIReviewConfirmation(
                    review: review,
                    recipientHost: host,
                    model: model,
                    send: { controller.confirmAIReviewRequest() },
                    decline: { controller.cancelAIReviewConfirmation() }
                )
            }
        }
        .task { await controller.load() }
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Files project", systemImage: "folder")
                .font(.headline)
            if let name = controller.projectName {
                Text(name)
                    .font(.subheadline.weight(.medium))
                if let baseline = controller.baseline {
                    Text("Approved baseline: \(baseline.files.count) eligible UTF-8 text file\(baseline.files.count == 1 ? "" : "s") · \(baseline.approvedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No approved baseline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No Files project selected")
                    .foregroundStyle(.secondary)
            }
            Button(controller.projectName == nil ? "Choose Files folder" : "Change Files folder", systemImage: "folder.badge.plus") {
                controller.showingFolderPicker = true
            }
            .buttonStyle(.bordered)
            .disabled(controller.isScanning || controller.isRequestingAIReview)
        }
        .guardianCard()
    }

    private var manualOnlyNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Manual local scan; optional network opinion", systemImage: "hand.raised")
                .font(.headline)
            Text("Guardian does not scan on app open, does not run in the background, and makes no schedule promise. Tap Scan now when you explicitly want a deterministic local hash comparison.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Local scans stay on this iPhone and need no model key. Only a separate optional BYOK action after a changed, saved scan can send confirmed bounded current excerpts and change metadata directly to your configured provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("That optional action is not automatic monitoring or a Pro entitlement. Pro remains disabled until it is available through App Store Connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .guardianCard()
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local hash review", systemImage: "checklist")
                .font(.headline)
            Text("Eligible files are bounded to 1,000 UTF-8 regular files, 128 KB each, 8 MB total, and 12 folders deep. .git, .env, credential names, and symlinks are never read.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let progress = controller.progress, controller.isScanning {
                ProgressView()
                Text("Visited \(progress.visitedEntries) entries · hashed \(progress.hashedFiles) files · omitted \(progress.omittedFiles) non-baseline files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                controller.scanNow()
            } label: {
                Label(controller.isScanning ? "Scanning locally…" : "Scan now", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isScanning || controller.isRequestingAIReview || controller.projectName == nil)
        }
        .guardianCard()
    }

    @ViewBuilder
    private var reviewEvidence: some View {
        if let review = controller.currentReview {
            VStack(alignment: .leading, spacing: 12) {
                Label("Reviewed evidence", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text("\(review.candidateFiles.count) eligible UTF-8 text files hashed locally from \(review.visitedEntries) visited entries.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if review.baselineID == nil {
                    Text("No baseline existed. The files below are the exact initial inventory available to approve after this review.")
                        .font(.footnote)
                }
                if review.changes.isEmpty {
                    Text("No added, changed, or deleted eligible UTF-8 text files were found against the approved baseline.")
                        .font(.footnote)
                } else {
                    Text("\(review.addedCount) added · \(review.changedCount) changed · \(review.deletedCount) deleted")
                        .font(.subheadline.weight(.semibold))
                    ForEach(review.changes) { change in
                        changeEvidence(change)
                    }
                }

                if !review.omissions.isEmpty {
                    DisclosureGroup("\(review.omissions.count) eligible paths omitted from the inventory") {
                        Text("These files were not read into the baseline because they exceeded a guard or were not UTF-8. Sensitive paths and symlinks are not listed or read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(review.omissions) { omission in
                            Text("\(omission.relativePath) — \(omissionLabel(omission.reason))")
                                .font(.caption.monospaced())
                        }
                    }
                    .font(.footnote)
                }

                if controller.canSetInitialBaseline {
                    Button("Set baseline from this review", systemImage: "checkmark.seal") {
                        controller.requestInitialBaseline()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if controller.canAcceptAdvance {
                    Button("Accept new baseline", systemImage: "checkmark.seal") {
                        controller.requestAdvanceBaseline()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if review.hasChanges {
                    optionalAIReviewCard
                }
                Text("This evidence is a file-hash comparison only. Guardian did not run tests, a build, linting, or an AI analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .guardianCard()
        }
    }

    private var optionalAIReviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("Optional BYOK model opinion", systemImage: "network.badge.shield.half.filled")
                .font(.subheadline.weight(.semibold))
            Text("After confirmation only, Guardian can ask your saved provider to give a bounded opinion on this just-persisted scan. It is never a test, build, execution, security check, or verification.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(controller.aiReviewAvailabilityMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            if controller.isRequestingAIReview {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Requesting a bounded model opinion…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel model review", role: .cancel) {
                    controller.cancelAIReview()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Review bounded current excerpts", systemImage: "sparkles") {
                    controller.requestAIReview()
                }
                .buttonStyle(.bordered)
                .disabled(!controller.canRequestAIReview)
            }
        }
        .padding(.top, 2)
    }

    private func changeEvidence(_ change: NativeGuardianFileChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(change.kind.rawValue.capitalized) · \(change.relativePath)")
                .font(.subheadline.weight(.medium))
            if let previousHash = change.previousSHA256 {
                Text("Previous SHA-256: \(previousHash) · \(byteString(change.previousByteCount))")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let currentHash = change.currentSHA256 {
                Text("Current SHA-256: \(currentHash) · \(byteString(change.currentByteCount))")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local review history", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if controller.historicalReviews.isEmpty {
                Text("No local Guardian reviews saved for this project.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.historicalReviews) { review in
                    HStack(alignment: .top, spacing: 8) {
                        Text(review.scannedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(review.addedCount) added · \(review.changedCount) changed · \(review.deletedCount) deleted")
                            .font(.caption)
                        Spacer()
                    }
                }
            }
            if controller.projectName != nil {
                Button("Delete Guardian history and model reports", role: .destructive) {
                    controller.showingDeleteConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(controller.isScanning || controller.isRequestingAIReview)
            }
        }
        .guardianCard()
    }

    private var aiReportHistoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved model opinions", systemImage: "text.bubble")
                .font(.headline)
            Text("These are local, per-project records of optional provider requests. An opinion is not verification, and Guardian stores request evidence rather than source excerpts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if controller.historicalAIReports.isEmpty {
                Text("No saved model opinions or provider-review outcomes for this project.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.historicalAIReports) { report in
                    aiReportEvidence(report)
                }
                Button("Delete saved model opinions", role: .destructive) {
                    controller.showingDeleteAIReportsConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(controller.isScanning || controller.isRequestingAIReview)
            }
        }
        .guardianCard()
    }

    private func aiReportEvidence(_ report: NativeGuardianAIReviewReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(aiReportStatusTitle(report.status))
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            if report.status == .completed, let opinion = report.modelOpinion {
                Text("Model opinion — not verification")
                    .font(.subheadline.weight(.semibold))
                Text(opinion)
                    .font(.footnote)
                    .textSelection(.enabled)
                Text(report.verificationNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let failure = report.failure {
                Text(failure.userMessage)
                    .font(.footnote)
                Text("No model opinion was shown as verification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Request evidence: \(report.changes.count) changed paths · \(report.excerpts.count) current excerpts") {
                Text("Guardian does not store the sent source excerpts. Deleted-file entries contain metadata only; prior deleted content was never sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(report.changes) { change in
                    Text("\(change.kind.rawValue.capitalized) · \(change.relativePath)")
                        .font(.caption.monospaced())
                }
                if !report.excerpts.isEmpty {
                    Text("Current excerpt ranges")
                        .font(.caption.weight(.semibold))
                    ForEach(report.excerpts) { excerpt in
                        Text("\(excerpt.relativePath) · lines \(excerpt.lineStart)-\(excerpt.lineEnd) · \(byteString(excerpt.excerptByteCount))")
                            .font(.caption.monospaced())
                    }
                }
            }
            .font(.footnote)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func aiReportStatusTitle(_ status: NativeGuardianAIReviewStatus) -> String {
        switch status {
        case .completed: "Opinion saved"
        case .refused: "Not sent"
        case .cancelled: "Cancelled"
        case .providerFailed: "Provider failed"
        }
    }

    private func byteString(_ value: Int?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func omissionLabel(_ reason: NativeGuardianOmission.Reason) -> String {
        switch reason {
        case .tooLarge: "over 128 KB"
        case .notUTF8: "not UTF-8 text"
        case .depthLimit: "deeper than 12 folders"
        case .unsupportedName: "unsupported path name"
        }
    }
}

/// This sheet is intentionally the final user gesture before an outbound
/// provider request. It uses only persisted Guardian metadata; it never reads
/// a project file itself.
private struct NativeGuardianAIReviewConfirmation: View {
    let review: NativeGuardianReviewRecord
    let recipientHost: String
    let model: String
    let send: () -> Void
    let decline: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var sortedChanges: [NativeGuardianFileChange] {
        review.changes.sorted {
            if $0.relativePath == $1.relativePath { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.relativePath < $1.relativePath
        }
    }

    private var currentChanges: [NativeGuardianFileChange] {
        sortedChanges.filter { $0.kind == .added || $0.kind == .changed }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Send a bounded model-opinion request?", systemImage: "network.badge.shield.half.filled")
                        .font(.headline)
                    Text("Decline sends nothing. This optional BYOK request goes directly to your configured provider; it is not a local hash scan and it is not verification.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    confirmationSection("Recipient") {
                        Text("Host: \(recipientHost)")
                        Text("Model: \(model)")
                        Text("Your provider may charge for this request. WaifuClaw does not represent this as a Pro entitlement.")
                            .foregroundStyle(.secondary)
                    }

                    confirmationSection("Exact persisted change metadata to send — \(sortedChanges.count) of \(NativeGuardianAIReviewLimits.maximumChanges) maximum paths") {
                        ForEach(sortedChanges) { change in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(change.kind.rawValue.capitalized) · \(change.relativePath)")
                                    .font(.caption.monospaced())
                                if change.kind == .deleted {
                                    Text("Metadata only — no prior deleted content exists in Guardian and none will be sent.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    confirmationSection("Current source excerpts — \(currentChanges.count) of \(NativeGuardianAIReviewLimits.maximumCurrentFiles) maximum files") {
                        Text("For each added or changed path listed above, the provider receives only the current excerpt: from line 1, at most the first \(NativeGuardianAIReviewLimits.maximumExcerptLinesPerFile) lines and \(NativeGuardianAIReviewLimits.maximumExcerptBytesPerFile / 1_024) KiB (\(NativeGuardianAIReviewLimits.maximumExcerptBytesPerFile) bytes) per file.")
                        Text("No prior version or deleted-file content is sent. Guardian re-reads each current file and requires its SHA-256 to still match the saved scan before any outbound request; a stale file is refused instead.")
                            .foregroundStyle(.secondary)
                    }

                    confirmationSection("Limitations") {
                        Text("The result is a model opinion, not verification. No tests, builds, execution, linting, or security verification will run. This creates no background monitoring or schedule.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Confirm provider review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline") {
                        decline()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send opinion request") {
                        send()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { decline() }
    }

    @ViewBuilder
    private func confirmationSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension View {
    func guardianCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
    }
}
