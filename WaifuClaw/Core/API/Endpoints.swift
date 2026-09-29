import Foundation

/// Every route the app calls, from ARCHITECTURE.md §1.3 + the verified
/// backend routers (memory.py, thread_runs.py, threads.py).
/// Runs routes verified 2026-09-29 against
/// backend/app/gateway/routers/thread_runs.py.
enum Endpoints {
    // MARK: Remote namespace (new in B2/B3)

    enum Remote {
        static let pairingExchange = "/api/remote/v1/pairing/exchange"
        static let pairingDevices = "/api/remote/v1/pairing/devices"
        static func pairingDevice(_ id: String) -> String {
            "/api/remote/v1/pairing/devices/\(id)"
        }
        static let chatStream = "/api/remote/v1/chat/stream"
        static let agentStop = "/api/remote/v1/agent/stop"
        static let agentStatus = "/api/remote/v1/agent/status"
        static let agentWake = "/api/remote/v1/agent/wake"
        static let memoryRecall = "/api/remote/v1/memory/recall"
        static let memoryRetain = "/api/remote/v1/memory/retain"
        static let licenseStatus = "/api/remote/v1/license/status"
        static let licenseActivate = "/api/remote/v1/license/activate"
        // MARK: BYOK (free tier) — see Features/Settings/BYOK/BYOK-CONTRACT.md
        static let byokKey = "/api/remote/v1/byok/key" // POST save/rotate, DELETE remove
        static let byokStatus = "/api/remote/v1/byok/status" // GET status (metadata only)
    }

    // MARK: Existing gateway routes (reused unchanged)

    enum Threads {
        static let create = "/api/threads" // POST {thread_id?, metadata?}
        static let search = "/api/threads/search" // POST {metadata, limit, offset, status?}
        // MARK: Runs — verified against thread_runs.py (2026-09-29)
        static func runs(_ threadID: String) -> String { // GET, thread_runs.py:571
            "/api/threads/\(threadID)/runs"
        }
        static func run(_ threadID: String, _ runID: String) -> String { // GET, thread_runs.py:581
            "/api/threads/\(threadID)/runs/\(runID)"
        }
        static func runEvents(_ threadID: String, _ runID: String) -> String { // GET, thread_runs.py:867
            "/api/threads/\(threadID)/runs/\(runID)/events"
        }
        static func runJoin(_ threadID: String, _ runID: String) -> String { // GET SSE, thread_runs.py:677
            "/api/threads/\(threadID)/runs/\(runID)/join"
        }
        static func skillReceipts(_ threadID: String, _ runID: String) -> String { // GET, thread_runs.py:883
            "/api/threads/\(threadID)/runs/\(runID)/skill-receipts"
        }
        static func runsStream(_ threadID: String) -> String {
            "/api/threads/\(threadID)/runs/stream"
        }
        static func runsWait(_ threadID: String) -> String {
            "/api/threads/\(threadID)/runs/wait"
        }
        static func cancelRun(_ threadID: String, _ runID: String) -> String {
            "/api/threads/\(threadID)/runs/\(runID)/cancel"
        }
        static func messages(_ threadID: String) -> String {
            "/api/threads/\(threadID)/messages"
        }
        static func tokenUsage(_ threadID: String) -> String {
            "/api/threads/\(threadID)/token-usage"
        }
    }

    enum Memory {
        static let get = "/api/memory" // GET → MemoryResponse
        static let reload = "/api/memory/reload" // POST
        static let facts = "/api/memory/facts" // POST {content, category, confidence}
        static func fact(_ id: String) -> String {
            "/api/memory/facts/\(id)" // DELETE / PATCH
        }
    }
}
