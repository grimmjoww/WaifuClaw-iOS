import SwiftUI

// MARK: - Skills card ("Tools" section)
//
// Backed by the real skill-receipts endpoint. Rows show the skill name,
// its category, and a state badge (Active .success / Needs attention
// .warning / done-or-idle .neutral). When the backend reports no skill
// telemetry, the card says so honestly instead of rendering invented
// tool categories.

struct SessionSkillsCard: View {
    @Bindable var viewModel: SessionDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            SectionHeader(title: "Skills")
            if let skillsError = viewModel.skillsError {
                SessionErrorCard(
                    title: "Couldn't load skills",
                    message: skillsError
                ) {
                    Task { await viewModel.retrySkills() }
                }
            } else if let receipts = viewModel.receipts {
                if receipts.receipts.isEmpty {
                    Text(
                        receipts.telemetryAvailable
                            ? "No skills were used in this run."
                            : "Skill telemetry isn't available for this run."
                    )
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Skills. \(receipts.telemetryAvailable ? "No skills were used in this run." : "Skill telemetry is not available for this run.")")
                } else {
                    skillsList(receipts)
                }
            } else {
                skillsSkeleton
            }
        }
        .themeCard()
    }

    private func skillsList(_ list: SkillReceiptList) -> some View {
        VStack(spacing: Theme.spacingS) {
            ForEach(list.receipts) { receipt in
                let badge = Self.badge(for: receipt)
                HStack(spacing: Theme.spacingM) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(receipt.skillName)
                            .font(Theme.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(receipt.category)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    StatusBadge(text: badge.text, tone: badge.tone)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(receipt.skillName), \(receipt.category), \(badge.text)")
            }
            if list.hasMore {
                Text("Showing recent skills — more on your desktop.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Maps a receipt's backend state to the contract's Active/Idle rows.
    /// `requiresAttention` always wins — it is the loudest signal.
    private static func badge(for receipt: SkillReceipt) -> (text: String, tone: BadgeTone) {
        if receipt.requiresAttention {
            return ("Needs attention", .warning)
        }
        let state = (receipt.state ?? "").lowercased()
        if state.contains("active") || state.contains("running") {
            return ("Active", .success)
        }
        if state.contains("fail") || state.contains("error") {
            return ("Failed", .danger)
        }
        if state.contains("complete") || state.contains("done") || state.contains("success") {
            return ("Done", .neutral)
        }
        if let raw = receipt.state, !raw.isEmpty {
            return (raw, .neutral)
        }
        return ("Idle", .neutral)
    }

    private var skillsSkeleton: some View {
        VStack(spacing: Theme.spacingS) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.radiusS)
                    .fill(Theme.track)
                    .frame(height: 52)
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Loading skills")
    }
}

#Preview("Skills — loaded") {
    let viewModel = SessionDetailViewModel(
        summary: MockRunsData.summaries[0],
        data: MockSessionData()
    )
    viewModel.receipts = SkillReceiptList(
        receipts: [
            SkillReceipt(id: "r1", skillName: "web-search", category: "research", state: "active", requiresAttention: false, eventCount: 4),
            SkillReceipt(id: "r2", skillName: "shell", category: "execution", state: "completed", requiresAttention: false, eventCount: 9),
            SkillReceipt(id: "r3", skillName: "deploy", category: "release", state: nil, requiresAttention: true, eventCount: 2),
        ],
        telemetryAvailable: true,
        hasMore: true
    )
    return ScrollView {
        SessionSkillsCard(viewModel: viewModel)
            .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

#Preview("Skills — no telemetry") {
    let viewModel = SessionDetailViewModel(
        summary: MockRunsData.summaries[0],
        data: MockSessionData()
    )
    viewModel.receipts = SkillReceiptList(receipts: [], telemetryAvailable: false, hasMore: false)
    return ScrollView {
        SessionSkillsCard(viewModel: viewModel)
            .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
