# WaifuClaw/Features/Chat/ChatViewModel.swift

- ChatViewModel · class · L9-L246 — @MainActor final class ChatViewModel: ObservableObject
- StreamPhase · enum · L11-L17 — enum StreamPhase: Equatable
- ChatViewModel · method · L37-L40 — init(threadID: String, appState: AppState)
- load · method · L44-L47 — func load() async
- catchUpFromServer · method · L49-L64 — private func catchUpFromServer(initial: Bool = false) async
- fetchMessages · method · L66-L74 — private func fetchMessages(api: APIClient) async throws -> [ChatMessage]
- refreshUsage · method · L76-L80 — private func refreshUsage() async
- send · method · L84-L92 — func send()
- dismissFailure · method · L94-L96 — func dismissFailure()
- startStream · method · L98-L143 — private func startStream(input: String)
- finishStream · method · L145-L156 — private func finishStream(error: Error?)
- describe · method · L158-L164 — private func describe(_ error: Error) -> String
- stop · method · L170-L182 — func stop()
- markBackgrounded · method · L184-L190 — func markBackgrounded()
- checkNow · method · L192-L196 — func checkNow() async
- captureRunID · method · L200-L209 — private func captureRunID(from headers: [AnyHashable: Any])
- handle · method · L211-L224 — private func handle(event: SSEEvent, assistantID: String) throws
- extractDelta · method · L228-L245 — static func extractDelta(from data: String) -> String?
