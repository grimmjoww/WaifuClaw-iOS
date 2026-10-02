import SwiftUI

/// Manual, user-mediated action UI for the bounded invocation client.
///
/// Parent integration: present `NativeExtensionActionView(registry: registry)`
/// from the existing extensions screen. This view deliberately has no model,
/// agent, workspace, project-file, shell, or automatic-hook input; it can send
/// only values typed into this form after an exact per-request review.
@MainActor
struct NativeExtensionActionView: View {
    @ObservedObject private var registry: ExtensionRegistry
    private let client: ExtensionInvocationClient

    @State private var selectedPluginID = ""
    @State private var selectedActionName = ""
    @State private var textValues: [String: String] = [:]
    @State private var booleanValues: [String: Bool] = [:]
    @State private var includedOptionalValues: Set<String> = []
    @State private var vendorToken = ""
    @State private var hasSavedVendorToken = false
    @State private var pendingDraft: ExtensionInvocationDraft?
    @State private var receipt: ExtensionInvocationReceipt?
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var invocationTask: Task<Void, Never>?

    init(registry: ExtensionRegistry, client: ExtensionInvocationClient = ExtensionInvocationClient()) {
        _registry = ObservedObject(wrappedValue: registry)
        self.client = client
    }

    var body: some View {
        Form {
            Section {
                Text("Actions are manual POST requests. Imported metadata is not code and cannot run scripts, Git hooks, downloads, or files.")
                    .font(.footnote)
                Text("This build invokes only GitHub's Markdown rendering action at https://api.github.com/markdown. Other imported manifests remain registration-only because hostname checks alone cannot provide complete DNS-rebinding/SSRF containment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Bounded external actions")
            }

            if supportedPlugins.isEmpty {
                ContentUnavailableView(
                    "No approved action is available",
                    systemImage: "lock.slash",
                    description: Text("Enable a declarative extension for GitHub's /markdown action. Other declarations stay local metadata."))
            } else {
                actionSelection
                parameterForm
                credentialControls
                reviewControls
                receiptSection
            }
        }
        .navigationTitle("Manual action")
        .onAppear(perform: chooseInitialAction)
        .onChange(of: selectedPluginID) { _, _ in
            selectedActionName = invokableActions.first?.name ?? ""
            resetForm()
            refreshCredentialAvailability()
        }
        .onChange(of: selectedActionName) { _, _ in
            resetForm()
        }
        .sheet(item: $pendingDraft) { draft in
            confirmationSheet(for: draft)
        }
        .alert(
            "Action could not be completed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onDisappear {
            invocationTask?.cancel()
        }
    }

    private var supportedPlugins: [InstalledExtension] {
        registry.installedExtensions.filter { plugin in
            plugin.isEnabled && client.isInvocationSupported(for: plugin.manifest)
        }
    }

    private var selectedPlugin: InstalledExtension? {
        supportedPlugins.first(where: { $0.id == selectedPluginID })
    }

    private var invokableActions: [ExtensionActionManifest] {
        guard let plugin = selectedPlugin else { return [] }
        return plugin.manifest.actions.filter { client.isActionSupported($0, in: plugin.manifest) }
    }

    private var selectedAction: ExtensionActionManifest? {
        invokableActions.first(where: { $0.name == selectedActionName })
    }

    @ViewBuilder
    private var actionSelection: some View {
        Section("Choose action") {
            Picker("Extension", selection: $selectedPluginID) {
                ForEach(supportedPlugins) { plugin in
                    Text("\(plugin.manifest.name) · \(plugin.manifest.vendor)")
                        .tag(plugin.id)
                }
            }

            if let selectedPlugin {
                Text(selectedPlugin.manifest.baseEndpoint.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Picker("POST action", selection: $selectedActionName) {
                    ForEach(invokableActions) { action in
                        Text("\(action.name)  \(action.path)").tag(action.name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var parameterForm: some View {
        if let action = selectedAction {
            Section("Declared JSON parameters") {
                if action.parameters.isEmpty {
                    Text("This action declares an empty JSON body.")
                        .foregroundStyle(.secondary)
                }
                ForEach(action.parameters, id: \.name) { parameter in
                    parameterEditor(parameter)
                }
                Text("Only the named primitive values shown here are sent. This form has no field for your coding prompt, model output, agent state, workspace location, or project files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func parameterEditor(_ parameter: ExtensionParameterSchema) -> some View {
        let shouldInclude = parameter.required || includedOptionalValues.contains(parameter.name)
        if !parameter.required {
            Toggle("Include \(parameter.name)", isOn: optionalInclusionBinding(parameter.name))
        }
        if shouldInclude {
            switch parameter.type {
            case .boolean:
                Toggle(parameterLabel(parameter), isOn: booleanBinding(parameter.name))
            case .string where parameter.enumValues != nil:
                Picker(parameterLabel(parameter), selection: textBinding(parameter.name)) {
                    ForEach(parameter.enumValues ?? [], id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .onAppear {
                    if textValues[parameter.name] == nil, let first = parameter.enumValues?.first {
                        textValues[parameter.name] = first
                    }
                }
            case .integer:
                TextField(parameterLabel(parameter), text: textBinding(parameter.name))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
            case .number:
                TextField(parameterLabel(parameter), text: textBinding(parameter.name))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
            case .string:
                TextField(parameterLabel(parameter), text: textBinding(parameter.name), axis: .vertical)
                    .lineLimit(1...4)
            }
        }
    }

    @ViewBuilder
    private var credentialControls: some View {
        if let manifest = selectedPlugin?.manifest {
            Section {
                SecureField("Optional GitHub token", text: $vendorToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button("Save token in Keychain") {
                        saveToken(for: manifest)
                    }
                    .disabled(vendorToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasSavedVendorToken {
                        Spacer()
                        Button("Delete saved token", role: .destructive) {
                            deleteToken(for: manifest)
                        }
                    }
                }
                Text(hasSavedVendorToken
                     ? "A token is stored only in this iPhone’s Keychain and will be used only for reviewed requests to https://api.github.com."
                     : "A token is optional. If saved, it is kept only in this iPhone’s Keychain, never in the manifest or registry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Vendor authentication")
            }
        }
    }

    @ViewBuilder
    private var reviewControls: some View {
        Section {
            Button {
                reviewCurrentForm()
            } label: {
                Label("Review POST request", systemImage: "eye")
            }
            .disabled(selectedAction == nil || isSending)

            if isSending {
                Button("Cancel request", role: .destructive) {
                    invocationTask?.cancel()
                }
            }
        } footer: {
            Text("Sending always requires a second, explicit confirmation showing the exact public HTTPS origin, fixed path, values, and outbound-data warning.")
        }
    }

    @ViewBuilder
    private var receiptSection: some View {
        if let receipt {
            Section("Latest in-memory receipt") {
                Text("POST \(receipt.origin)\(receipt.path)")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("HTTP \(receipt.statusCode) · \(receipt.completedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let preview = receipt.responsePreview {
                    Text(preview)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(12)
                } else {
                    Text("The vendor returned no response body.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Receipts are intentionally not saved to disk.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func confirmationSheet(for draft: ExtensionInvocationDraft) -> some View {
        NavigationStack {
            List {
                Section("Request") {
                    LabeledContent("Vendor", value: draft.vendor)
                    LabeledContent("Method", value: "POST")
                    LabeledContent("Public HTTPS origin", value: draft.origin)
                    LabeledContent("Fixed path", value: draft.path)
                    LabeledContent("Declared action", value: draft.actionName)
                    LabeledContent("Saved token", value: draft.usesSavedVendorToken ? "Will authenticate this request" : "Not used")
                }
                Section("Outbound JSON values") {
                    if draft.parameters.isEmpty {
                        Text("{}")
                            .font(.body.monospaced())
                    } else {
                        ForEach(draft.parameters, id: \.name) { parameter in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(parameter.name)
                                    .font(.headline)
                                Text(parameter.value.displayValue)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("Data boundary") {
                    Text("Only the JSON values above are sent. This request does not attach your model prompt/output, agent state, workspace paths, project files, shell commands, Git data, or downloaded code.")
                    Text("If you manually entered sensitive content above, it will be sent to \(draft.origin). Review it before continuing.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Confirm external request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pendingDraft = nil }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send POST", role: .destructive) {
                        send(draft)
                    }
                    .disabled(isSending)
                }
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private func chooseInitialAction() {
        guard !supportedPlugins.isEmpty else { return }
        if selectedPlugin == nil {
            selectedPluginID = supportedPlugins[0].id
        }
        if selectedAction == nil {
            selectedActionName = invokableActions.first?.name ?? ""
        }
        resetForm()
        refreshCredentialAvailability()
    }

    private func resetForm() {
        textValues = [:]
        booleanValues = [:]
        includedOptionalValues = []
        for parameter in selectedAction?.parameters ?? [] {
            if parameter.required, let first = parameter.enumValues?.first {
                textValues[parameter.name] = first
            }
        }
    }

    private func parameterLabel(_ parameter: ExtensionParameterSchema) -> String {
        var label = "\(parameter.name) · \(parameter.type.rawValue)"
        if parameter.required { label += " · required" }
        if let maximum = parameter.maxLength { label += " · max \(maximum) bytes" }
        return label
    }

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { textValues[name, default: ""] },
            set: { textValues[name] = $0 }
        )
    }

    private func booleanBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { booleanValues[name, default: false] },
            set: { booleanValues[name] = $0 }
        )
    }

    private func optionalInclusionBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { includedOptionalValues.contains(name) },
            set: { enabled in
                if enabled {
                    includedOptionalValues.insert(name)
                } else {
                    includedOptionalValues.remove(name)
                    textValues.removeValue(forKey: name)
                    booleanValues.removeValue(forKey: name)
                }
            }
        )
    }

    private func reviewCurrentForm() {
        guard let plugin = selectedPlugin, let action = selectedAction else { return }
        do {
            let values = try valuesFromForm(for: action)
            pendingDraft = try client.makeDraft(
                registry: registry,
                pluginID: plugin.id,
                actionName: action.name,
                parameterValues: values
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func valuesFromForm(for action: ExtensionActionManifest) throws -> [String: ExtensionParameterValue] {
        var values: [String: ExtensionParameterValue] = [:]
        for parameter in action.parameters where parameter.required || includedOptionalValues.contains(parameter.name) {
            switch parameter.type {
            case .string:
                values[parameter.name] = .string(textValues[parameter.name, default: ""])
            case .boolean:
                values[parameter.name] = .boolean(booleanValues[parameter.name, default: false])
            case .integer:
                let raw = textValues[parameter.name, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = Int(raw) else {
                    throw ExtensionInvocationError.invalidParameter(name: parameter.name, reason: "enter a whole number")
                }
                values[parameter.name] = .integer(value)
            case .number:
                let raw = textValues[parameter.name, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = Double(raw), value.isFinite else {
                    throw ExtensionInvocationError.invalidParameter(name: parameter.name, reason: "enter a finite number")
                }
                values[parameter.name] = .number(value)
            }
        }
        return values
    }

    private func send(_ draft: ExtensionInvocationDraft) {
        let confirmation = client.confirmation(for: draft)
        isSending = true
        invocationTask?.cancel()
        invocationTask = Task { @MainActor in
            defer {
                isSending = false
                invocationTask = nil
            }
            do {
                receipt = try await client.invoke(draft, confirmedBy: confirmation, registry: registry)
                pendingDraft = nil
            } catch {
                pendingDraft = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshCredentialAvailability() {
        guard let manifest = selectedPlugin?.manifest else {
            hasSavedVendorToken = false
            return
        }
        do {
            hasSavedVendorToken = try client.hasSavedVendorToken(for: manifest)
        } catch {
            hasSavedVendorToken = false
            errorMessage = error.localizedDescription
        }
    }

    private func saveToken(for manifest: ExtensionManifest) {
        do {
            try client.saveVendorToken(vendorToken, for: manifest)
            vendorToken = ""
            hasSavedVendorToken = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteToken(for manifest: ExtensionManifest) {
        do {
            try client.deleteVendorToken(for: manifest)
            hasSavedVendorToken = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
