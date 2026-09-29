import SwiftUI

// MARK: - Phase → badge (view-layer mapping)

extension SessionStreamPhase {
    /// The badge label. "Connecting" on first open, "Reconnecting" once the
    /// stream has been live before — the task's required visible states.
    func badgeText(everConnected: Bool) -> String {
        switch self {
        case .connecting:
            everConnected ? "Reconnecting" : "Connecting"
        case .live:
            "Live"
        case .paused:
            "Paused"
        case .ended:
            "Ended"
        case .offline:
            "Offline"
        case .failed:
            "Error"
        }
    }

    var badgeTone: BadgeTone {
        switch self {
        case .connecting:
            .info
        case .live:
            .success
        case .paused:
            .warning
        case .ended:
            .neutral
        case .offline, .failed:
            .danger
        }
    }
}

// MARK: - Terminal card

/// The session terminal: a mono event log with a permanently visible
/// connection badge, Pause/Resume/Reconnect controls, and a persisted
/// per-session auto-scroll toggle. Read-only — the phone never sends input.
struct SessionTerminalCard: View {
    @Bindable var viewModel: SessionDetailViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            headerRow
            controlsRow
            if let backlogError = viewModel.backlogError {
                SessionErrorCard(
                    title: "Couldn't load past events",
                    message: backlogError
                ) {
                    Task { await viewModel.start() }
                }
            }
            terminalLog
        }
        .themeCard()
        .accessibilityLabel("Session terminal. \(viewModel.phase.badgeText(everConnected: viewModel.everConnected)).")
    }

    // MARK: Header

    private var headerRow: some View {
        HStack {
            Text("Terminal")
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            StatusBadge(
                text: viewModel.phase.badgeText(everConnected: viewModel.everConnected),
                tone: viewModel.phase.badgeTone
            )
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controlsRow: some View {
        HStack(spacing: Theme.spacingS) {
            streamButton
            Spacer()
            Toggle("Auto-scroll", isOn: Binding(
                get: { viewModel.autoScroll },
                set: { viewModel.setAutoScroll($0) }
            ))
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .toggleStyle(.switch)
            .frame(minHeight: 44)
            .accessibilityHint("When on, the terminal follows new output. Saved for this session.")
        }
    }

    @ViewBuilder
    private var streamButton: some View {
        switch viewModel.phase {
        case .live, .connecting:
            Button("Pause") { viewModel.pause() }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("Pauses the live stream. The run keeps going on your desktop.")
        case .paused:
            Button("Resume") { viewModel.resume() }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityHint("Resumes the live stream.")
        case .offline, .failed:
            Button("Reconnect") { viewModel.reconnect() }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityHint("Tries to reopen the live stream.")
        case .ended:
            EmptyView()
        }
    }

    // MARK: Log

    private var terminalLog: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.spacingXS) {
                    if viewModel.events.isEmpty && viewModel.backlogError == nil {
                        Text("No output yet — this run hasn't emitted any events.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(Theme.spacingS)
                    } else {
                        ForEach(viewModel.events) { event in
                            terminalLine(event)
                                .id(event.id)
                        }
                    }
                }
                .padding(Theme.spacingS)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 420)
            .background(Color.black.opacity(0.35))
            .clipShape(.rect(cornerRadius: Theme.radiusS))
            .onChange(of: viewModel.events.count) { _, _ in
                guard viewModel.autoScroll, let last = viewModel.events.last else { return }
                if reduceMotion {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: Theme.animationQuick)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .accessibilityLabel("Terminal output, \(viewModel.events.count) lines.")
        }
    }

    private func terminalLine(_ event: SessionEvent) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingS) {
            if let occurredAt = event.occurredAt {
                Text(Self.timeFormatter.string(from: occurredAt))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(event.summary)
                .foregroundStyle(event.isError ? Theme.danger : Theme.textPrimary)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.summary)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

#Preview("Terminal — live") {
    let viewModel = SessionDetailViewModel(
        summary: MockRunsData.summaries[0],
        data: MockSessionData()
    )
    viewModel.events = [
        SessionEvent(id: "s0", occurredAt: Date(), kind: "run.start", summary: "▶ Run started", isError: false),
        SessionEvent(id: "s1", occurredAt: Date(), kind: "llm.tool.result", summary: "⚙ shell: installed dependencies", isError: false),
        SessionEvent(id: "s2", occurredAt: Date(), kind: "llm.ai.response", summary: "Dependencies are in — wiring up the plan next.", isError: false),
    ]
    viewModel.phase = .live
    return ScrollView {
        SessionTerminalCard(viewModel: viewModel)
            .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
