import Foundation
import Observation

/// State + actions for the Settings → API Key screen.
///
/// Flow: validate the key directly against the provider (fast, loud
/// feedback) → forward it to the paired computer over the pinned device
/// channel → persist it in the Keychain only after the desktop confirms.
/// A failed save persists nothing anywhere — no split state.
@Observable
@MainActor
final class BYOKViewModel {
    /// Save-flow phases — the user always sees where the key stands.
    enum Phase: Equatable {
        case idle
        case checkingKey // probing the provider directly
        case syncing // forwarding to the paired computer
        case error(String)
    }

    var provider: BYOKProvider = .openai
    var keyInput = ""
    var baseURLInput = ""
    var modelInput = ""
    var revealKey = false
    var phase: Phase = .idle
    var status: BYOKKeyStatus?
    var statusLoading = false
    /// Transient banner text (confirmations, background-refresh failures).
    var notice: String?
    var noticeIsError = false
    var confirmingDelete = false

    var isBusy: Bool {
        phase == .checkingKey || phase == .syncing || statusLoading
    }

    /// Inline format hint, mirroring the license-key screen's pattern.
    /// Advisory — the live provider probe is the real validator, and Save
    /// stays disabled while the hint shows.
    var keyHint: String? {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return provider.keyLooksRight(key) ? nil : provider.keyHint
    }

    private let client: BYOKClient
    private var saveTask: Task<Void, Never>?

    /// Nonisolated so SwiftUI views can construct it in their own (nonisolated)
    /// initializers; the init only stores the Sendable client.
    nonisolated init(client: BYOKClient = BYOKClient()) {
        self.client = client
    }

    // MARK: - Status

    /// Loads the desktop key status. Silent when there's no API client
    /// (unpaired) so the screen shows its empty state instead of an error.
    func refreshStatus(api: APIClient?) async {
        guard let api else { return }
        statusLoading = true
        defer { statusLoading = false }
        do {
            status = try await client.fetchStatus(via: api)
        } catch is CancellationError {
            // View went away — normal lifecycle, stay quiet.
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            noticeIsError = true
        }
    }

    // MARK: - Save (validate → forward → persist)

    func saveTapped(api: APIClient?) {
        saveTask?.cancel()
        saveTask = Task { await validateAndSave(api: api) }
    }

    private func validateAndSave(api: APIClient?) async {
        notice = nil
        noticeIsError = false
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            phase = .error("Paste your API key first.")
            return
        }
        guard let api else {
            phase = .error(
                "Pair this phone with your computer first — the key is used by the agent running on your computer."
            )
            return
        }
        let baseURL = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.requiresBaseURL, baseURL.isEmpty {
            phase = .error("Enter your endpoint's base URL (https://…).")
            return
        }

        // 1. Validate directly against the provider — fast, loud feedback.
        // A rejected key is never saved and never forwarded.
        phase = .checkingKey
        let probe: BYOKClient.ProbeResult
        do {
            try Task.checkCancellation()
            probe = try await client.validateKey(
                provider: provider,
                key: key,
                baseURL: baseURL.isEmpty ? nil : baseURL
            )
        } catch is CancellationError {
            phase = .idle
            return
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }

        // 2. Forward to the desktop over the pinned device channel.
        // The Keychain write happens only after the desktop confirms.
        phase = .syncing
        let model = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = BYOKSaveRequest(
            provider: provider.rawValue,
            api_key: key,
            model: model.isEmpty ? nil : model,
            base_url: baseURL.isEmpty ? nil : baseURL
        )
        do {
            try Task.checkCancellation()
            let response = try await client.saveKey(request, via: api)
            KeychainStore.byokAPIKey = key
            status = BYOKKeyStatus(
                configured: true,
                provider: response.provider,
                model: response.model,
                active: response.active,
                last_validated_at: response.last_validated_at
            )
            keyInput = ""
            phase = .idle
            if probe == .rateLimited {
                notice = """
                    \(provider.displayName) is rate-limiting right now — the key is saved \
                    and will be re-checked automatically.
                    """
            } else {
                let modelSuffix = response.model.map { " · \($0)" } ?? ""
                notice = "API key active — \(provider.displayName)\(modelSuffix)."
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            // Nothing persisted: the Keychain write only happens on success.
            phase = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Delete

    /// The view confirms via `confirmingDelete` before calling this.
    /// Deleting is idempotent server-side, so no task tracking needed.
    func deleteTapped(api: APIClient?) {
        Task { await deleteKey(api: api) }
    }

    private func deleteKey(api: APIClient?) async {
        noticeIsError = false
        guard let api else {
            notice = "Pair this phone with your computer first."
            return
        }
        do {
            try await client.deleteKey(via: api)
            KeychainStore.byokAPIKey = nil
            status = nil
            notice = "API key deleted from this phone and your computer."
            noticeIsError = false
        } catch is CancellationError {
            // Stay quiet on lifecycle cancellation.
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            noticeIsError = true
        }
    }
}

#if DEBUG
extension BYOKViewModel {
    /// Canned view model for `#Preview`: looks configured, no network.
    static var previewConfigured: BYOKViewModel {
        let viewModel = BYOKViewModel()
        viewModel.provider = .anthropic
        viewModel.status = BYOKKeyStatus(
            configured: true,
            provider: "anthropic",
            model: "claude-sonnet-4-20250514",
            active: true,
            last_validated_at: "2026-09-29T18:00:00Z"
        )
        return viewModel
    }
}
#endif
