import SwiftUI

/// Memory (in Settings): free-tier fact CRUD plus the paid associative-recall section.
/// A 402 from recall/retain never silently drops — it becomes the Pro upsell
/// (audit §7).
struct MemoryBrowserView: View {
    @EnvironmentObject var appState: AppState
    @State private var facts: [MemoryFact] = []
    @State private var loading = true
    @State private var error: String?
    @State private var searchText = ""
    @State private var editingFact: MemoryFact?
    @State private var showingCreate = false

    // Pro recall state
    @State private var recallQuery = ""
    @State private var recallResults: [RecallHit] = []
    @State private var recallPhase: RecallPhase = .idle
    @State private var retainText = ""

    enum RecallPhase: Equatable {
        case idle
        case loading
        case results
        case needsPro
        case error(String)
    }

    private var filteredFacts: [MemoryFact] {
        guard !searchText.isEmpty else { return facts }
        let q = searchText.lowercased()
        return facts.filter {
            $0.content.lowercased().contains(q) || $0.category.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if loading {
                ProgressView().tint(Theme.magenta)
            } else if let error, facts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.warning)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Try again") { Task { await load() } }
                        .themePrimaryButton()
                        .padding(.horizontal, 48)
                }
                .padding()
            } else {
                List {
                    Section {
                        proRecallCard
                    }
                    Section("Saved facts (\(filteredFacts.count))") {
                        ForEach(filteredFacts) { fact in
                            Button { editingFact = fact } label: {
                                FactRow(fact: fact)
                            }
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Search memories")
                .refreshable { await load() }
            }
        }
        .navigationTitle("Memory")
        .toolbar {
            Button { showingCreate = true } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingCreate) {
            FactEditSheet(fact: nil) { Task { await load() } }
                .environmentObject(appState)
        }
        .sheet(item: $editingFact) { fact in
            FactEditSheet(fact: fact) { Task { await load() } }
                .environmentObject(appState)
        }
        .task { await load() }
    }

    // MARK: - Pro associative recall

    private var proRecallCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Associative recall", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if appState.license?.isPro == true {
                    Text("PRO")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.magenta)
                        .clipShape(Capsule())
                }
            }
            Text("Ask for a memory by meaning, not keywords.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            HStack {
                TextField("e.g. what does Willie like to drink?", text: $recallQuery, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Button("Recall") { recall() }
                    .disabled(recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || recallPhase == .loading)
            }

            switch recallPhase {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView().tint(Theme.magenta)
            case .results:
                if recallResults.isEmpty {
                    Text("Nothing relevant found.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(Array(recallResults.enumerated()), id: \.offset) { _, hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.content ?? "(empty)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            if let score = hit.score {
                                Text(String(format: "relevance %.0f%%", score * 100))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            case .needsPro:
                // 402 → loud upsell, never silently missing recall (audit §7).
                // Pro lives in Settings now (not a tab), so this links straight
                // to it — a tab switch here would land on the wrong tab.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Associative recall is a Pro feature.")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your free memory keeps working — Pro adds recall by meaning.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    NavigationLink {
                        LicenseView()
                    } label: {
                        Text("See Pro options")
                            .frame(maxWidth: .infinity)
                    }
                    .themePrimaryButton()
                }
                .padding(.top, 4)
            case .error(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }

            Divider().background(Theme.textSecondary.opacity(0.3))

            // Paid retain.
            HStack {
                TextField("Save to Pro memory…", text: $retainText, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { retain() }
                    .disabled(retainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .themeCard()
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func recall() {
        guard let api = appState.api else { return }
        let query = recallQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recallPhase = .loading
        Task {
            do {
                let response: RecallResponse = try await api.post(
                    Endpoints.Remote.memoryRecall,
                    body: RecallRequest(query: query, top_k: 5)
                )
                recallResults = response.results ?? []
                recallPhase = .results
            } catch let apiError as APIError {
                if case .paymentRequired = apiError {
                    recallPhase = .needsPro
                } else {
                    recallPhase = .error(apiError.errorDescription ?? "Recall failed.")
                }
            } catch {
                recallPhase = .error("Recall failed.")
            }
        }
    }

    private func retain() {
        guard let api = appState.api else { return }
        let content = retainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        recallPhase = .loading
        Task {
            do {
                let _: EmptyResponse = try await api.post(
                    Endpoints.Remote.memoryRetain, body: RetainRequest(content: content)
                )
                retainText = ""
                recallPhase = .idle
            } catch let apiError as APIError {
                if case .paymentRequired = apiError {
                    recallPhase = .needsPro
                } else {
                    recallPhase = .error(apiError.errorDescription ?? "Couldn't save that.")
                }
            } catch {
                recallPhase = .error("Couldn't save that.")
            }
        }
    }

    // MARK: - Free CRUD

    private func load() async {
        guard let api = appState.api else { return }
        loading = facts.isEmpty
        defer { loading = false }
        do {
            // Contract shape is {facts:[...]}; tolerate a bare array.
            if let response: MemoryResponse = try? await api.get(Endpoints.Memory.get) {
                facts = response.facts ?? []
            } else {
                let array: [MemoryFact] = try await api.get(Endpoints.Memory.get)
                facts = array
            }
            error = nil
        } catch {
            nudgeRefreshOnRevoked(error)
            self.error = (error as? APIError)?.errorDescription ?? "Couldn't load memories."
        }
    }

    private func nudgeRefreshOnRevoked(_ error: Error) {
        if let apiError = error as? APIError, case .deviceRevoked = apiError {
            Task { await appState.refreshConnection() }
        }
    }
}

private struct FactRow: View {
    let fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fact.content)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(fact.category)
                    .font(.caption)
                    .foregroundStyle(Theme.magentaSoft)
                Text(String(format: "%.0f%%", fact.confidence * 100))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}
