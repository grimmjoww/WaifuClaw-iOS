import SwiftUI
import UniformTypeIdentifiers

struct NativeAgentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = NativeAgentController()
    @State private var showingFolderPicker = false

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Theme.danger.opacity(0.12))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.messages) { message in
                            messageCard(role: message.role.rawValue, text: message.content)
                                .id(message.id)
                        }
                        if !controller.streamedText.isEmpty {
                            messageCard(role: "assistant · streaming", text: controller.streamedText)
                                .id("stream")
                        }
                        if controller.messages.isEmpty && controller.streamedText.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                KlineAvatar(diameter: 88)
                                Text("Work with a project on this iPhone")
                                    .font(.title2.bold())
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Choose a folder in Files, add your model key in Settings, then ask WaifuClaw to inspect your code. These first native tools can read files only; edits and Git arrive when they are verified.")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        if !controller.recentEvents.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Run evidence")
                                    .font(.headline)
                                ForEach(controller.recentEvents) { event in
                                    Text("\(event.kind): \(event.summary)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themeCard()
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: controller.messages.count) { _, _ in
                    if let last = controller.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: controller.streamedText) { _, newValue in
                    if !newValue.isEmpty { proxy.scrollTo("stream", anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: controller.isRunning ? "circle.dotted.circle" : "checkmark.circle")
                Text(controller.status)
                    .lineLimit(2)
                Spacer()
                if controller.isRunning {
                    Button("Stop", action: controller.stop)
                        .fontWeight(.bold)
                }
            }
            .font(.footnote)
            .foregroundStyle(controller.isRunning ? Theme.warning : Theme.textSecondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            composer
        }
        .background(Theme.background)
        .navigationTitle("Agent")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("New conversation", systemImage: "plus", action: controller.newConversation)
                    ForEach(controller.conversations) { conversation in
                        Button(conversation.title) {
                            Task { await controller.selectConversation(conversation.id) }
                        }
                    }
                } label: {
                    Label("Conversations", systemImage: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NativeModelSettingsView()
                } label: {
                    Label("Model settings", systemImage: "key.fill")
                }
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let folders):
                if let folder = folders.first { controller.selectWorkspace(folder) }
            case .failure(let error):
                controller.errorMessage = error.localizedDescription
            }
        }
        .task { await controller.load() }
        .onChange(of: scenePhase) { _, phase in
            // iOS 17 can suspend the process. Do not claim a local run keeps
            // executing after backgrounding; persist the cancelled run.
            if phase == .background { controller.stop() }
        }
    }

    private var projectHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.magenta)
            VStack(alignment: .leading) {
                Text(controller.workspaceName ?? "No project selected")
                    .font(.subheadline.bold())
                Text("Selected files can be sent to your model provider when the agent reads them.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            Button(controller.workspaceName == nil ? "Choose" : "Change") {
                showingFolderPicker = true
            }
        }
        .padding()
        .background(Theme.surface)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your project…", text: $controller.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isRunning)
            Button("Send", systemImage: "arrow.up.circle.fill", action: controller.send)
                .labelStyle(.iconOnly)
                .font(.system(size: 30))
                .foregroundStyle(Theme.magenta)
                .disabled(controller.isRunning || controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private func messageCard(role: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(role.uppercased())
                .font(.caption.bold())
                .foregroundStyle(role.hasPrefix("user") ? Theme.textSecondary : Theme.magenta)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .padding(.horizontal)
    }
}
