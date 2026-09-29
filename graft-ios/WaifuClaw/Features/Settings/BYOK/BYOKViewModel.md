# WaifuClaw/Features/Settings/BYOK/BYOKViewModel.swift

- BYOKViewModel · class · L10-L187 — @Observable @MainActor final class BYOKViewModel
- Phase · enum · L14-L19 — enum Phase: Equatable
- BYOKViewModel · method · L52-L54 — nonisolated init(client: BYOKClient = BYOKClient())
- refreshStatus · method · L60-L72 — func refreshStatus(api: APIClient?) async
- saveTapped · method · L76-L79 — func saveTapped(api: APIClient?)
- validateAndSave · method · L81-L158 — private func validateAndSave(api: APIClient?) async
- deleteTapped · method · L164-L166 — func deleteTapped(api: APIClient?)
- deleteKey · method · L168-L186 — private func deleteKey(api: APIClient?) async
- BYOKViewModel · module · L190-L204 — extension BYOKViewModel
