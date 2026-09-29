import SwiftUI

/// Create / edit a free-tier memory fact. Save and delete both fail loudly
/// (audit Q3); delete asks for confirmation.
struct FactEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let fact: MemoryFact?
    var onSaved: () -> Void

    @State private var content: String
    @State private var category: String
    @State private var confidence: Double
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false

    init(fact: MemoryFact?, onSaved: @escaping () -> Void) {
        self.fact = fact
        self.onSaved = onSaved
        _content = State(initialValue: fact?.content ?? "")
        _category = State(initialValue: fact?.category ?? "")
        _confidence = State(initialValue: fact?.confidence ?? 0.8)
    }

    private var isNew: Bool { fact == nil }
    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                Form {
                    Section("Memory") {
                        TextField("What should WaifuClaw remember?", text: $content, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    Section("Category") {
                        TextField("e.g. preference", text: $category)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("Confidence") {
                        Slider(value: $confidence, in: 0...1, step: 0.05)
                        Text("\(Int(confidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let error {
                        Section {
                            Text(error)
                                .foregroundStyle(Theme.danger)
                        }
                    }
                    if !isNew {
                        Section {
                            Button("Delete this memory", role: .destructive) {
                                confirmingDelete = true
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(isNew ? "New memory" : "Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Delete this memory?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("This can't be undone.")
            }
            .overlay {
                if saving {
                    ProgressView()
                        .tint(Theme.magenta)
                        .padding()
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func save() {
        guard let api = appState.api else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if let fact {
                    let _: EmptyResponse = try await api.patch(
                        Endpoints.Memory.fact(fact.id),
                        body: FactPatchRequest(
                            content: content,
                            category: category.isEmpty ? nil : category,
                            confidence: confidence
                        )
                    )
                } else {
                    let _: EmptyResponse = try await api.post(
                        Endpoints.Memory.facts,
                        body: FactCreateRequest(
                            content: content,
                            category: category.isEmpty ? "fact" : category,
                            confidence: confidence
                        )
                    )
                }
                onSaved()
                dismiss()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "Couldn't save that."
            }
        }
    }

    private func delete() {
        guard let api = appState.api, let fact else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let _: EmptyResponse = try await api.delete(Endpoints.Memory.fact(fact.id))
                onSaved()
                dismiss()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "Couldn't delete that."
            }
        }
    }
}
