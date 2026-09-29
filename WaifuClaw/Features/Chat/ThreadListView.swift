import SwiftUI

/// Thread list (the Chat tab root). Real `POST /api/threads/search`;
/// "New chat" creates a thread first, then opens it.
struct ThreadListView: View {
    @EnvironmentObject var appState: AppState
    @State private var threads: [ThreadResponse] = []
    @State private var loading = true
    @State private var error: String?
    @State private var openedThreadID: String?
    @State private var creating = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if loading {
                ProgressView().tint(Theme.magenta)
            } else if let error, threads.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.warning)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Try again") {
                        Task { await load() }
                    }
                    .themePrimaryButton()
                    .padding(.horizontal, 48)
                }
                .padding()
            } else if threads.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.magenta)
                    Text("No chats yet")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Start a new chat and your computer will pick it up.")
                        .foregroundStyle(Theme.textSecondary)
                    Button("New chat") { createThread() }
                        .themePrimaryButton()
                        .padding(.horizontal, 48)
                }
                .padding()
            } else {
                List {
                    ForEach(threads, id: \.thread_id) { thread in
                        Button {
                            openedThreadID = thread.thread_id
                        } label: {
                            ThreadRow(thread: thread)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            Button { createThread() } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(creating)
        }
        .navigationDestination(item: $openedThreadID) { threadID in
            ChatView(threadID: threadID, appState: appState)
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = appState.api else { return }
        loading = threads.isEmpty
        error = nil
        defer { loading = false }
        do {
            let found: [ThreadResponse] = try await api.post(
                Endpoints.Threads.search, body: ThreadSearchRequest()
            )
            threads = found.sorted { ($0.updated_at ?? "") > ($1.updated_at ?? "") }
        } catch {
            nudgeRefreshOnRevoked(error)
            self.error = (error as? APIError)?.errorDescription ?? "Couldn't load chats."
        }
    }

    private func createThread() {
        guard let api = appState.api, !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let created: ThreadResponse = try await api.post(
                    Endpoints.Threads.create, body: ThreadCreateRequest()
                )
                await load()
                openedThreadID = created.thread_id
            } catch {
                nudgeRefreshOnRevoked(error)
                self.error = (error as? APIError)?.errorDescription ?? "Couldn't start a chat."
            }
        }
    }

    private func nudgeRefreshOnRevoked(_ error: Error) {
        if let apiError = error as? APIError, case .deviceRevoked = apiError {
            Task { await appState.refreshConnection() }
        }
    }
}

private struct ThreadRow: View {
    let thread: ThreadResponse

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(thread.thread_id.prefix(12)) + (thread.thread_id.count > 12 ? "…" : ""))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let updated = thread.updated_at,
                   let date = Self.parseDate(updated) {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if thread.status == "busy" {
                Label("running", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 4)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        iso.date(from: string) ?? isoPlain.date(from: string)
    }
}
