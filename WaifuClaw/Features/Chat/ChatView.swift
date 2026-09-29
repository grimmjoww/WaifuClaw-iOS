import SwiftUI

/// One thread's conversation. Owns its ChatViewModel for the thread id.
/// Stream lifecycle states are always visible (audit §6); backgrounding the
/// app mid-run says plainly that the run continues on the computer.
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool

    init(threadID: String, appState: AppState) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(threadID: threadID, appState: appState))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                streamBanner
                if let loadError = viewModel.loadError, viewModel.messages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.warning)
                        Text(loadError)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.textSecondary)
                        Button("Try again") {
                            Task { await viewModel.load() }
                        }
                        .themePrimaryButton()
                        .padding(.horizontal, 48)
                    }
                    .padding()
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.messages) { message in
                                    MessageBubbleView(
                                        message: message,
                                        isThinking: message.id == viewModel.messages.last?.id
                                            && message.role.lowercased() != "human"
                                            && message.role.lowercased() != "user"
                                            && message.content.isEmpty
                                            && (viewModel.phase == .streaming
                                                || viewModel.phase == .reconnecting)
                                    )
                                }
                            }
                            .padding()
                        }
                        .onChange(of: viewModel.messages.count) {
                            scrollToBottom(proxy)
                        }
                        .onChange(of: viewModel.messages.last?.content) {
                            scrollToBottom(proxy)
                        }
                    }
                }
                if let total = viewModel.usage?.total_tokens {
                    Text("\(total.formatted()) tokens this thread")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                }
                inputBar
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.phase == .streaming || viewModel.phase == .reconnecting {
                Button("Stop") { viewModel.stop() }
            }
        }
        .task { await viewModel.load() }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .background {
                viewModel.markBackgrounded()
            } else if newValue == .active, viewModel.phase == .backgrounded {
                Task { await viewModel.checkNow() }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = viewModel.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    // MARK: - Stream state banner (audit §6 — always visible, never silent)

    @ViewBuilder
    private var streamBanner: some View {
        switch viewModel.phase {
        case .reconnecting:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.warning)
                Text("Reconnecting…")
                Spacer()
            }
            .streamBannerStyle(color: Theme.warning)
        case .backgrounded:
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                Text("Run continues on your computer.")
                Spacer()
                Button("Check now") {
                    Task { await viewModel.checkNow() }
                }
                .bold()
            }
            .streamBannerStyle(color: Theme.textSecondary)
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).lineLimit(3)
                Spacer()
                Button("Dismiss") { viewModel.dismissFailure() }
                    .bold()
            }
            .streamBannerStyle(color: Theme.danger)
        case .idle, .streaming:
            EmptyView()
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message WaifuClaw…", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($inputFocused)
                .disabled(!viewModel.canSend)
                .onSubmit { viewModel.send() }
            Button { viewModel.send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(sendButtonColor)
            }
            .disabled(!viewModel.canSend)
        }
        .padding()
        .background(Theme.background)
    }

    private var sendButtonColor: Color {
        let empty = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (viewModel.canSend && !empty) ? Theme.magenta : Theme.textSecondary.opacity(0.4)
    }
}

private extension View {
    func streamBannerStyle(color: Color) -> some View {
        font(.footnote)
            .foregroundStyle(color)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.12))
    }
}
