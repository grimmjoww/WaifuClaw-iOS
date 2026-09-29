# WaifuClaw/Core/API/BYOKClient.swift

- BYOKClient · struct · L10-L96 — struct BYOKClient: Sendable
- ProbeResult · enum · L12-L18 — enum ProbeResult: Sendable
- BYOKClient · method · L22-L24 — init(session: URLSession = .shared)
- validateKey · method · L29-L54 — func validateKey(provider: BYOKProvider, key: String, baseURL: String?) async throws -> ProbeResult
- saveKey · method · L58-L64 — func saveKey(_ request: BYOKSaveRequest, via api: APIClient) async throws -> BYOKSaveResponse
- fetchStatus · method · L66-L68 — func fetchStatus(via api: APIClient) async throws -> BYOKKeyStatus
- deleteKey · method · L70-L72 — func deleteKey(via api: APIClient) async throws
- mapDesktopError · method · L79-L95 — private func mapDesktopError(_ error: APIError) -> BYOKError
