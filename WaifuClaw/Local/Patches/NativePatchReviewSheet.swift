import SwiftUI

/// The model can create a pending record, but this view is the only UI route to
/// `approveAndApply`. The exact path and every line of the bounded diff appear
/// before the user's separate, destructive confirmation.
struct NativePatchReviewSheet: View {
    let preview: NativePatchApprovalPreview
    let isApplying: Bool
    let onClose: () -> Void
    let onReject: () -> Void
    let onApprove: () -> Void

    @State private var showingApplyConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("No file has been changed", systemImage: "hand.raised.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.warning)
                        Text("File inside your selected project")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(preview.relativePath)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        Text("Reason from model: \(preview.proposal.reason)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                        Text("Expected current SHA-256: \(preview.proposal.expectedSHA256)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeCard()

                    Text("Complete change to review")
                        .font(Theme.sectionDisplay)
                    Text("− removed   + added   unchanged lines have no marker. Only this exact file is affected; a changed file is refused during Save.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(preview.diffLines) { line in
                            Text(marker(for: line) + line.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(.vertical, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeCard()
                    Text("An approved edit is written only after Files grants access and the current bytes still match the review. Undo is available in Agent only while this app session retains the actual save token.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding()
            }
            .background { StudioBackdrop() }
            .navigationTitle("Review proposed edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: onClose)
                        .disabled(isApplying)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Reject proposal", role: .destructive, action: onReject)
                        .accessibilityIdentifier("patch.reject")
                        .disabled(isApplying)
                    Spacer()
                    Button("Apply reviewed edit") { showingApplyConfirmation = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("patch.apply")
                        .disabled(isApplying || !preview.isCurrent || preview.diffLines.isEmpty)
                }
                .padding()
                .background(.regularMaterial)
            }
            .alert("Apply this exact file change?", isPresented: $showingApplyConfirmation) {
                Button("Apply reviewed edit", role: .destructive, action: onApprove)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Write only \(preview.relativePath) in the selected project. If its contents changed after review, the edit is refused. No command or test will run.")
            }
        }
    }

    private func marker(for line: WorkspaceLineDiff.Line) -> String {
        switch line.kind {
        case .context: return "  "
        case .removed: return "− "
        case .added: return "+ "
        case .notice: return "! "
        }
    }

    private func color(for line: WorkspaceLineDiff.Line) -> Color {
        switch line.kind {
        case .context: return Theme.textSecondary
        case .removed: return Theme.danger
        case .added: return Theme.success
        case .notice: return Theme.warning
        }
    }
}
