import SwiftUI

/// Team tab: the wave-2 conversational team surface on live data.
///
/// "Continue in chat" switches to the Chat tab, where the thread list shows
/// the conversation. True deep-link into the thread needs ThreadListView to
/// accept an external thread ID — another leaf owns that file, so the
/// deep-link is a follow-up, not faked here.
struct TeamTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let api = appState.api {
            TeamBoardView(
                data: LiveTeamData(api: api),
                onContinueInChat: openInChat
            )
        } else {
            ApiTransientView(onRetry: retryConnection)
        }
    }

    private func openInChat(_ threadID: String) {
        appState.tabSelection = .chat
    }

    private func retryConnection() {
        Task { await appState.restore() }
    }
}
