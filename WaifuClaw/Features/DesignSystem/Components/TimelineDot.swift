import SwiftUI

/// Numbered circle for run step timelines (Objective → Plan → … → Rollback),
/// matching the OutcomeRun mockup's timeline dots. The current step glows.
struct TimelineDot: View {
    /// 1-based step number shown when the step is pending or current.
    var index: Int
    /// Visual state of this step.
    var state: TimelineState

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle()
                    .fill(Theme.magenta)
                Image(systemName: "checkmark")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.white)
            case .current:
                Circle()
                    .fill(Theme.magenta)
                    .shadow(color: Theme.magenta.opacity(0.55), radius: 10)
                Text("\(index)")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.white)
            case .pending:
                Circle()
                    .stroke(Theme.textSecondary, lineWidth: 1.5)
                Text("\(index)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            case .failed:
                Circle()
                    .fill(Theme.danger)
                Image(systemName: "xmark")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel("Step \(index), \(stateName)")
    }

    private var stateName: String {
        switch state {
        case .done: "done"
        case .current: "current"
        case .pending: "pending"
        case .failed: "failed"
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        TimelineDot(index: 1, state: .done)
        TimelineDot(index: 2, state: .done)
        TimelineDot(index: 3, state: .current)
        TimelineDot(index: 4, state: .pending)
        TimelineDot(index: 5, state: .failed)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
