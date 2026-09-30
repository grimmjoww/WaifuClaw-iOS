import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class NativeGuardianController {
    var projectName: String?
    var snapshot: NativeGuardianProjectSnapshot?
    var progress: NativeGuardianScanProgress?
    var statusMessage = "Manual only. Choose a Files project, then scan when you want a local review."
    var errorMessage: String?
    var isScanning = false
    var showingFolderPicker = false
    var showingInitialBaselineConfirmation = false
    var showingAdvanceBaselineConfirmation = false
    var showingDeleteConfirmation = false

    private let permission: NativeProjectPermission
    private var store: NativeGuardianStore?
    private var projectURL: URL?
    private var projectID: String?
    private var activeScanID: UUID?
    private var approvableReviewID: UUID?

    init(permission: NativeProjectPermission = NativeProjectPermission(), store: NativeGuardianStore? = nil) {
        self.permission = permission
        do {
            self.store = try store ?? NativeGuardianStore()
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

    var canSetInitialBaseline: Bool {
        guard let review = currentReview else { return false }
        return baseline == nil && review.baselineID == nil
    }

    var canAcceptAdvance: Bool {
        guard let review = currentReview, let baseline else { return false }
        return review.baselineID == baseline.id && review.hasChanges
    }

    func load() {
        guard let store else { return }
        do {
            guard let url = try permission.selectedFolder() else {
                projectURL = nil
                projectID = nil
                projectName = nil
                snapshot = nil
                statusMessage = "Manual only. Choose a Files project to create or compare a local baseline."
                return
            }
            try configure(url: url, store: store, restored: true)
        } catch {
            present(error)
            statusMessage = "Guardian did not scan automatically. Choose the Files folder again, then scan manually."
        }
    }

    func chooseFolder(_ url: URL) {
        guard let store else { return }
        do {
            _ = try permission.selectFolder(url)
            try configure(url: url, store: store, restored: false)
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
        guard canSetInitialBaseline else { return }
        showingInitialBaselineConfirmation = true
    }

    func confirmInitialBaseline() {
        approveCurrentReview(initial: true)
    }

    func requestAdvanceBaseline() {
        guard canAcceptAdvance else { return }
        showingAdvanceBaselineConfirmation = true
    }

    func confirmAdvanceBaseline() {
        approveCurrentReview(initial: false)
    }

    func deleteHistory() {
        guard let projectID, let store else { return }
        do {
            try store.deleteHistory(projectID: projectID)
            snapshot = nil
            approvableReviewID = nil
            progress = nil
            errorMessage = nil
            statusMessage = "Deleted Guardian history for this project. Project files were not changed."
        } catch {
            present(error)
        }
    }

    private func configure(url: URL, store: NativeGuardianStore, restored: Bool) throws {
        _ = try NativeGuardianScanner(rootURL: url)
        let id = NativeProjectIdentity.id(for: url)
        projectURL = url
        projectID = id
        projectName = url.lastPathComponent
        snapshot = try store.load(projectID: id)
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
        guard let projectID,
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
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// A user-controlled, on-device project hash review. It reads only the shared
/// Files folder the user selected, stores no source contents, never starts a
/// background schedule, and has no provider/model dependency.
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
                if let url = urls.first { controller.chooseFolder(url) }
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
            Button("Delete history", role: .destructive) { controller.deleteHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes this project’s local Guardian baseline and review history from app storage. It does not delete or modify any Files project content.")
        }
        .task { controller.load() }
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
            .disabled(controller.isScanning)
        }
        .guardianCard()
    }

    private var manualOnlyNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Manual local review only", systemImage: "hand.raised")
                .font(.headline)
            Text("Guardian does not scan on app open, does not run in the background, and makes no schedule promise. Tap Scan now when you explicitly want a deterministic local hash comparison.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("No model key is required. This screen does not send project text or hashes to a provider.")
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
            .disabled(controller.isScanning || controller.projectName == nil)
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
                Text("This evidence is a file-hash comparison only. Guardian did not run tests, a build, linting, or an AI analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .guardianCard()
        }
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
                Button("Delete Guardian history", role: .destructive) {
                    controller.showingDeleteConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(controller.isScanning)
            }
        }
        .guardianCard()
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

private extension View {
    func guardianCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
    }
}
