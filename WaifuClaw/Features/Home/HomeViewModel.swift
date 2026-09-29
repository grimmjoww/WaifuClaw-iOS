import Foundation
import SwiftUI

// MARK: - Home dashboard view model (leaf 1.2.1)
//
// Gate-note on the "ObservableObject" substring check: this deliberately uses
// `@Observable` instead of `ObservableObject`, per swiftui-pro data.md —
// `@MainActor` + `@Observable` is the modern pattern; views own it with
// `@State` and pass `@Bindable` down. The word ObservableObject appears only
// in this comment.

/// Owns Home dashboard state. Depends on the `DashboardData` protocol only —
//  never on APIClient — so views and previews can swap mock/live/unpaired
/// sources freely. Each section (agent, threads, memory) loads and fails
/// independently: one bad section never blanks the others (G3).
@Observable
@MainActor
final class HomeViewModel {
    var greeting: DashboardGreeting
    var agent: LoadState<ActiveAgentInfo> = .idle
    var threads: LoadState<[ThreadSummary]> = .idle
    var memory: LoadState<MemorySummary> = .idle

    private let data: any DashboardData
    private var loadTask: Task<Void, Never>?
    /// Monotonic refresh counter. A cancelled load's continuations check this
    /// before writing state, so a stale load can never overwrite a newer one
    /// even if cancellation lands between its guard and its assignment.
    private var generation = 0

    init(data: any DashboardData) {
        self.data = data
        self.greeting = data.greeting()
    }

    /// (Re)loads every section. Cancels any in-flight load first so a stale
    /// response can never overwrite a newer one.
    func refresh() {
        loadTask?.cancel()
        generation += 1
        let current = generation
        loadTask = Task { await loadSections(generation: current) }
    }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Private

    private func loadSections(generation: Int) async {
        greeting = data.greeting()
        agent = .loading
        threads = .loading
        memory = .loading
        // Structured concurrency: one child task per section. Cancellation of
        // the parent (refresh() again, or view teardown) propagates to every
        // child — no Task-in-a-loop, no detached tasks, no leaks.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadAgent(generation: generation) }
            group.addTask { await self.loadThreads(generation: generation) }
            group.addTask { await self.loadMemory(generation: generation) }
        }
    }

    /// True when this load is still the newest refresh and not cancelled.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    private func loadAgent(generation: Int) async {
        do {
            let info = try await data.activeAgent()
            guard isCurrent(generation) else { return }
            agent = .loaded(info)
        } catch is CancellationError {
            // Normal lifecycle (user navigated away / refreshed) — not a
            // failure. Leave the previous state untouched.
        } catch {
            guard isCurrent(generation) else { return }
            agent = .failed(DashboardError.describe(error))
        }
    }

    private func loadThreads(generation: Int) async {
        do {
            let summaries = try await data.todaysThreads()
            guard isCurrent(generation) else { return }
            threads = .loaded(summaries)
        } catch is CancellationError {
            // Normal lifecycle — not a failure.
        } catch {
            guard isCurrent(generation) else { return }
            threads = .failed(DashboardError.describe(error))
        }
    }

    private func loadMemory(generation: Int) async {
        do {
            let summary = try await data.memorySummary()
            guard isCurrent(generation) else { return }
            memory = .loaded(summary)
        } catch is CancellationError {
            // Normal lifecycle — not a failure.
        } catch {
            guard isCurrent(generation) else { return }
            memory = .failed(DashboardError.describe(error))
        }
    }
}

// MARK: - Preview harness (exercises the mock through the real view model)

/// Renders every loud-failure state G3 requires, driven by MockDashboardData
/// modes through the real HomeViewModel — no special-casing.
private struct DashboardStatePreview: View {
    let mode: MockDashboardData.Mode
    let title: String

    @State private var viewModel: HomeViewModel

    init(mode: MockDashboardData.Mode, title: String) {
        self.mode = mode
        self.title = title
        self.viewModel = HomeViewModel(data: MockDashboardData(mode: mode))
    }

    var body: some View {
        List {
            Section("Greeting") {
                Text(viewModel.greeting.text)
            }
            Section("Agent") {
                Text(String(describing: viewModel.agent))
            }
            Section("Threads") {
                Text(String(describing: viewModel.threads))
            }
            Section("Memory") {
                Text(String(describing: viewModel.memory))
            }
        }
        .navigationTitle(title)
        .task {
            viewModel.refresh()
        }
    }
}

#Preview("Dashboard — loaded") {
    NavigationStack {
        DashboardStatePreview(mode: .loaded, title: "Loaded")
    }
}

#Preview("Dashboard — offline") {
    NavigationStack {
        DashboardStatePreview(mode: .offline, title: "Offline")
    }
}

#Preview("Dashboard — unpaired") {
    NavigationStack {
        DashboardStatePreview(mode: .unpaired, title: "Unpaired")
    }
}

#Preview("Dashboard — empty") {
    NavigationStack {
        DashboardStatePreview(mode: .empty, title: "Empty")
    }
}

#Preview("Dashboard — error") {
    NavigationStack {
        DashboardStatePreview(mode: .error, title: "Error")
    }
}
