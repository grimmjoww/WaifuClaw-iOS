import SwiftUI

/// Settings for an optional, typed TypeSafe Jev assessment. Jev provides
/// classifications only; it never grants permission for file writes, command
/// execution, Git operations, or any other unsafe action.
struct JevSettingsView: View {
    private let keychain = JevKeychainStore()
    private let preferences = JevDecisionPreferences()

    @State private var keyInput = ""
    @State private var showKey = false
    @State private var hasSavedKey = false
    @State private var decisionOptIn = false
    @State private var sampleRequest = ""
    @State private var assessment: JevAssessment?
    @State private var notice: String?
    @State private var isError = false
    @State private var isTesting = false
    @State private var confirmRemoval = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    StudioEyebrow(title: "Decision service / optional")
                    Text("Optional Jev decisions")
                        .font(Theme.sectionDisplay)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Jev is a TypeSafe System One model for typed routing decisions. It is not a chat or coding model, and its result never authorizes an action.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Toggle("Enable optional Jev routing assessment", isOn: $decisionOptIn)
                        .tint(Theme.magenta)
                        .disabled(!hasSavedKey)
                    Text(decisionOptIn
                         ? "Jev may assess your next agent request. Safety checks still decide what the agent may do."
                         : "Jev assessments are off. Save a Jev key, then enable this option if you want automatic decision requests.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        hasSavedKey ? "Jev key saved on this iPhone" : "No Jev key saved",
                        systemImage: hasSavedKey ? "checkmark.shield.fill" : "key"
                    )
                    .foregroundStyle(hasSavedKey ? Theme.success : Theme.warning)

                    HStack {
                        Group {
                            if showKey {
                                TextField("TypeSafe Jev API key", text: $keyInput)
                            } else {
                                SecureField("TypeSafe Jev API key", text: $keyInput)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                        Button(showKey ? "Hide key" : "Show key", systemImage: showKey ? "eye.slash" : "eye") {
                            showKey.toggle()
                        }
                        .labelStyle(.iconOnly)
                    }

                    Text("The Jev key is stored only in this iPhone's Keychain, separately from your coding-model provider key. Leave this field blank to keep the saved Jev key unchanged.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)

                    HStack {
                        Button("Save Jev key", action: saveKey)
                            .themePrimaryButton()
                            .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasSavedKey {
                            Button("Remove Jev key", role: .destructive) {
                                confirmRemoval = true
                            }
                        }
                    }
                }
                .themeCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Test Jev")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Enter a sample request. Test Jev is a real TypeSafe API call, not a simulation.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $sampleRequest)
                        .frame(minHeight: 110)
                        .padding(6)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textInputAutocapitalization(.sentences)

                    Text("When you tap Test Jev, WaifuClaw sends the sample text you entered and `workspace_selected: false` directly to TypeSafe at api.typesafe.ai. It does not send project files or project contents. This real provider request may incur separate TypeSafe charges.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)

                    HStack {
                        Button {
                            testJev()
                        } label: {
                            if isTesting {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Testing Jev…")
                                }
                            } else {
                                Text("Test Jev")
                            }
                        }
                        .themePrimaryButton()
                        .disabled(
                            isTesting ||
                            !hasSavedKey ||
                            sampleRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )

                        if isTesting {
                            Button("Cancel test", role: .cancel) {
                                testTask?.cancel()
                            }
                        }
                    }
                    if !hasSavedKey {
                        Text("Save a Jev key above before running a live test.")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .themeCard()

                if let assessment {
                    assessmentView(assessment)
                }

                if let notice {
                    Label(notice, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(isError ? Theme.danger : Theme.success)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding()
        }
        .background { StudioBackdrop() }
        .navigationTitle("Jev Decisions")
        .task { refresh() }
        .onDisappear { testTask?.cancel() }
        .onChange(of: decisionOptIn) { _, enabled in
            preferences.isDecisionOptedIn = enabled
        }
        .confirmationDialog("Remove this phone's Jev key?", isPresented: $confirmRemoval) {
            Button("Remove key", role: .destructive, action: removeKey)
        } message: {
            Text("Optional Jev assessments and live tests will stop until you save a new key.")
        }
    }

    @ViewBuilder
    private func assessmentView(_ assessment: JevAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest Jev result")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Intent: \(assessment.intent.choice.rawValue)")
                .foregroundStyle(Theme.textPrimary)
            probabilityRow("Inspect project", assessment.intent.probabilities.inspect)
            probabilityRow("Answer without project", assessment.intent.probabilities.general)
            probabilityRow("Intent confidence", assessment.intent.confidence)
            probabilityRow("Request needs writing / code / Git", assessment.needsWrite.probability)
            Text("Model \(assessment.model) · \(assessment.usage.inputTokens) input / \(assessment.usage.outputTokens) output tokens")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text("This is an informational typed decision, not an authorization to perform any action.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .themeCard()
    }

    @ViewBuilder
    private func probabilityRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value, format: .percent.precision(.fractionLength(1)))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)
    }

    private func refresh() {
        decisionOptIn = preferences.isDecisionOptedIn
        do {
            hasSavedKey = try keychain.load() != nil
        } catch {
            showError(error)
        }
    }

    private func saveKey() {
        do {
            try keychain.save(keyInput)
            keyInput = ""
            hasSavedKey = true
            isError = false
            notice = "Jev key saved in this iPhone's Keychain."
        } catch {
            showError(error)
        }
    }

    private func removeKey() {
        do {
            try keychain.delete()
            keyInput = ""
            hasSavedKey = false
            decisionOptIn = false
            assessment = nil
            isError = false
            notice = "Jev key removed from this iPhone."
        } catch {
            showError(error)
        }
    }

    private func testJev() {
        let request = sampleRequest
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError(JevDecisionError.invalidRequest)
            return
        }

        do {
            guard let apiKey = try keychain.load() else {
                hasSavedKey = false
                showError(JevDecisionError.invalidAPIKey)
                return
            }

            isTesting = true
            isError = false
            notice = nil
            assessment = nil
            testTask = Task {
                defer {
                    isTesting = false
                    testTask = nil
                }
                do {
                    let result = try await JevDecisionClient().assess(
                        request: request,
                        workspaceSelected: false,
                        apiKey: apiKey
                    )
                    guard !Task.isCancelled else { return }
                    assessment = result
                    notice = "Jev returned a typed decision from TypeSafe."
                } catch is CancellationError {
                    guard !Task.isCancelled else { return }
                } catch {
                    guard !Task.isCancelled else { return }
                    showError(error)
                }
            }
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        isError = true
        notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
