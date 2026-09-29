import Foundation
import SwiftUI

/// Chat state machine for one thread. Audible states per audit §6:
/// streaming (visible via Stop control + typing indicator), reconnecting,
/// backgrounded ("run continues on your computer"), failed (loud banner).
/// The server is the source of truth: after every stream we re-fetch the
/// thread's messages, which also self-heals any chunk-format duplication.
@MainActor
final class ChatViewModel: ObservableObject {
    enum StreamPhase: Equatable {
        case idle
        case streaming
        case reconnecting
        case backgrounded
        case failed(String)
    }

    @Published var messages: [ChatMessage] = []
    @Published var phase: StreamPhase = .idle
    @Published var inputText = ""
    @Published var usage: ThreadTokenUsage?
    @Published var loadError: String?

    var canSend: Bool {
        switch phase {
        case .idle, .failed, .backgrounded: return true
        case .streaming, .reconnecting: return false
        }
    }

    let threadID: String
    private let appState: AppState
    private var streamTask: Task<Void, Never>?
    private var runID: String?

    init(threadID: String, appState: AppState) {
        self.threadID = threadID
        self.appState = appState
    }

    // MARK: - Loading

    func load() async {
        await catchUpFromServer(initial: true)
        await refreshUsage()
    }

    private func catchUpFromServer(initial: Bool = false) async {
        guard let api = appState.api else { return }
        do {
            messages = try await fetchMessages(api: api)
            loadError = nil
        } catch {
            if let apiError = error as? APIError, case .deviceRevoked = apiError {
                Task { await appState.refreshConnection() }
            }
            if initial {
                loadError = (error as? APIError)?.errorDescription
                    ?? "Couldn't load this chat."
            }
            // Non-initial catch-ups are best-effort: keep what's on screen.
        }
    }

    private func fetchMessages(api: APIClient) async throws -> [ChatMessage] {
        let path = Endpoints.Threads.messages(threadID)
        // Contract shape is {data:[...]}; tolerate a bare array.
        if let page: PaginatedMessages = try? await api.get(path) {
            return page.messages
        }
        let array: [ChatMessage] = try await api.get(path)
        return array
    }

    private func refreshUsage() async {
        guard let api = appState.api else { return }
        let fetched: ThreadTokenUsage? = try? await api.get(Endpoints.Threads.tokenUsage(threadID))
        usage = fetched
    }

    // MARK: - Sending

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }
        inputText = ""
        loadError = nil
        if case .failed = phase { phase = .idle } // clear the banner on retry
        messages.append(ChatMessage(role: "human", content: text))
        startStream(input: text)
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    private func startStream(input: String) {
        guard let api = appState.api else {
            phase = .failed("This phone isn't paired.")
            return
        }
        let body = ChatStreamRequest(
            thread_id: threadID,
            input: .init(messages: [RunInputMessage(role: "human", content: input)]),
            stream_mode: ["messages", "values"],
            on_disconnect: "continue"
        )
        let placeholder = ChatMessage(role: "ai", content: "")
        messages.append(placeholder)
        let assistantID = placeholder.id
        phase = .streaming
        streamTask = Task { [weak self] in
            guard let self else { return }
            // One automatic reconnect with a VISIBLE state (audit §6).
            for attempt in 0...1 {
                do {
                    if attempt > 0 {
                        try Task.checkCancellation()
                        self.phase = .reconnecting
                    }
                    try await api.streamChat(
                        body,
                        onHeaders: { self.captureRunID(from: $0) },
                        onEvent: { try self.handle(event: $0, assistantID: assistantID) }
                    )
                    self.finishStream(error: nil)
                    return
                } catch is CancellationError {
                    // stop()/markBackgrounded() already set the visible state —
                    // never clobber it here.
                    await self.catchUpFromServer()
                    return
                } catch {
                    if Task.isCancelled || attempt == 1 {
                        self.finishStream(error: error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    private func finishStream(error: Error?) {
        if let error {
            phase = .failed(describe(error))
        } else {
            phase = .idle
        }
        runID = nil
        Task {
            await catchUpFromServer()
            await refreshUsage()
        }
    }

    private func describe(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return "Something went wrong." }
        if case .deviceRevoked = apiError {
            Task { await appState.refreshConnection() }
        }
        return apiError.errorDescription ?? "Something went wrong."
    }

    // MARK: - Stop / background

    /// Stop button: cancel the local stream, best-effort server cancel, and
    /// say plainly that the run continues on the computer (audit §6).
    func stop() {
        guard phase == .streaming || phase == .reconnecting else { return }
        streamTask?.cancel()
        streamTask = nil
        if let api = appState.api, let runID {
            let tid = threadID
            Task {
                let _: EmptyResponse? = try? await api.post(Endpoints.Threads.cancelRun(tid, runID))
            }
        }
        runID = nil
        phase = .backgrounded
    }

    func markBackgrounded() {
        guard phase == .streaming || phase == .reconnecting else { return }
        streamTask?.cancel()
        streamTask = nil
        runID = nil
        phase = .backgrounded
    }

    func checkNow() async {
        await catchUpFromServer()
        await refreshUsage()
        if phase == .backgrounded { phase = .idle }
    }

    // MARK: - Stream internals

    private func captureRunID(from headers: [AnyHashable: Any]) {
        for (key, value) in headers {
            guard let name = key as? String,
                  name.caseInsensitiveCompare("Content-Location") == .orderedSame,
                  let location = value as? String,
                  let last = location.split(separator: "/").last
            else { continue }
            runID = String(last)
        }
    }

    private func handle(event: SSEEvent, assistantID: String) throws {
        try Task.checkCancellation()
        if event.event == "error" {
            throw APIError.http(status: 500, message: event.data.isEmpty ? nil : event.data)
        }
        guard let delta = Self.extractDelta(from: event.data),
              !delta.isEmpty,
              let idx = messages.firstIndex(where: { $0.id == assistantID })
        else { return }
        let current = messages[idx].content
        // Cumulative frames replace; true deltas append.
        let updated = (!current.isEmpty && delta.hasPrefix(current)) ? delta : current + delta
        messages[idx] = ChatMessage(id: assistantID, role: "ai", content: updated)
    }

    /// Tolerant chunk extraction. The exact `chat/stream` SSE shape is a
    /// contract-drift item — see CONTRACT_DRIFT.md.
    static func extractDelta(from data: String) -> String? {
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData)
        else { return nil }
        if let dict = json as? [String: Any] {
            if let content = dict["content"] as? String { return content }
            if let nested = dict["data"] as? [String: Any],
               let content = nested["content"] as? String { return content }
        } else if let array = json as? [Any] {
            for item in array {
                if let dict = item as? [String: Any],
                   let content = dict["content"] as? String, !content.isEmpty {
                    return content
                }
            }
        }
        return nil
    }
}
