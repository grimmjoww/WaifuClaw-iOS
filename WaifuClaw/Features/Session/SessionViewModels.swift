import Foundation

// MARK: - Session list view model

/// Owns Session-list load state. Depends on `RunsData` only (a session is a
/// run) — never on APIClient — so previews and the App-integration leaf can
/// swap mock/live sources freely.
@Observable
@MainActor
final class SessionListViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case error(String)
    }

    private let runsData: any RunsData & Sendable

    var sessions: [RunSummary] = []
    var phase: Phase = .loading

    init(runsData: any RunsData & Sendable) {
        self.runsData = runsData
    }

    /// Loads recent runs across threads (newest first). Cancellation is
    /// normal lifecycle — the previous state is kept, never an error card.
    func refresh() async {
        phase = .loading
        do {
            sessions = try await runsData.recentRuns(limit: 50)
            phase = .ready
        } catch is CancellationError {
            // Keep the previous state.
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .error(message)
        }
    }
}

// MARK: - Session detail view model

/// Owns one session's terminal: the event backlog, the live join stream,
/// the skill receipts, and the persisted per-session auto-scroll preference.
///
/// Stream lifecycle: `start()` (called from the view's `.task`) loads the
/// backlog, then opens the SSE stream on a stored task. That task is
/// explicitly cancelled when replaced (`connect()` cancels first), when
/// paused, and when the view disappears (`stop()`). `CancellationError` is
/// normal lifecycle — it never becomes an error state.
@Observable
@MainActor
final class SessionDetailViewModel {
    private let summary: RunSummary
    private let data: any SessionData & Sendable

    /// Terminal lines: backlog first, live frames appended.
    var events: [SessionEvent] = []
    var phase: SessionStreamPhase = .connecting
    /// Set once the stream has gone live at least once — drives the
    /// "Connecting" vs "Reconnecting" badge label.
    private(set) var everConnected = false
    /// Backlog load failure; the terminal shows this loudly with Retry.
    var backlogError: String?
    var receipts: SkillReceiptList?
    var skillsError: String?
    /// Real persisted preference, per session (UserDefaults — a bool, never
    /// a secret). Changed only through `setAutoScroll`.
    private(set) var autoScroll: Bool

    private var streamTask: Task<Void, Never>?

    init(summary: RunSummary, data: any SessionData & Sendable) {
        self.summary = summary
        self.data = data
        let stored = UserDefaults.standard.object(forKey: Self.scrollKey(for: summary.id)) as? Bool
        self.autoScroll = stored ?? true
    }

    var runSummary: RunSummary { summary }

    // MARK: Lifecycle

    /// Called from the view's `.task`. Loads the backlog, then the skill
    /// receipts, then opens the live stream (unless the run is terminal).
    func start() async {
        await loadBacklog()
        await loadSkills()
        connect()
    }

    /// Called from the view's `.onDisappear` — the stored stream task must
    /// not outlive the view.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: Auto-scroll preference

    static func scrollKey(for runID: String) -> String {
        "waifuclaw.session.autoscroll.\(runID)"
    }

    func setAutoScroll(_ value: Bool) {
        autoScroll = value
        UserDefaults.standard.set(value, forKey: Self.scrollKey(for: summary.id))
    }

    // MARK: Stream controls

    func pause() {
        streamTask?.cancel()
        streamTask = nil
        if phase == .live || phase == .connecting {
            phase = .paused
        }
    }

    func resume() {
        connect()
    }

    func reconnect() {
        connect()
    }

    func retrySkills() async {
        await loadSkills()
    }

    // MARK: Loading

    private func loadBacklog() async {
        do {
            let backlog = try await data.sessionEvents(threadID: summary.threadID, runID: summary.id)
            guard !Task.isCancelled else { return }
            events = backlog
            backlogError = nil
        } catch is CancellationError {
            // Normal lifecycle.
        } catch {
            backlogError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadSkills() async {
        do {
            let list = try await data.skillReceipts(threadID: summary.threadID, runID: summary.id)
            guard !Task.isCancelled else { return }
            receipts = list
            skillsError = nil
        } catch is CancellationError {
            // Normal lifecycle.
        } catch {
            skillsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Stream

    /// Opens (or re-opens) the live join stream. Any previous stream task is
    /// cancelled first. Terminal runs show the backlog as "Ended" — the
    /// desktop answers 409 for those, which becomes `.ended`, not an error.
    private func connect() {
        streamTask?.cancel()
        streamTask = nil
        guard !summary.status.isTerminal else {
            phase = .ended
            return
        }
        phase = .connecting
        let stream = data.sessionEventStream(threadID: summary.threadID, runID: summary.id)
        streamTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    self.events.append(event)
                    // Bound the terminal — a long run must not grow the
                    // array without limit.
                    if self.events.count > 2000 {
                        self.events.removeFirst(self.events.count - 2000)
                    }
                    if self.phase == .connecting {
                        self.phase = .live
                        self.everConnected = true
                    }
                }
                // The server closed the stream cleanly (end frame): the run
                // is over as far as this worker is concerned.
                guard let self else { return }
                if self.phase == .live || self.phase == .connecting {
                    self.phase = .ended
                }
            } catch is CancellationError {
                // Pause / reconnect / view disappeared — not a failure.
            } catch SessionStreamError.runNotActive {
                self?.phase = .ended
            } catch {
                self?.phase = Self.phaseForError(error)
            }
        }
    }

    /// Maps stream failures to the terminal's visible states. Connectivity
    /// problems become `.offline`; everything else is loud with the
    /// backend's message.
    private static func phaseForError(_ error: Error) -> SessionStreamPhase {
        if let apiError = error as? APIError, case .unreachable = apiError {
            return .offline
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .failed(message)
    }
}
