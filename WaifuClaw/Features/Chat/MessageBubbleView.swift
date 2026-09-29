import SwiftUI

/// One chat message bubble. Roles: human (right, magenta), ai/assistant
/// (left, surface), tool (small mono caption), anything else (subtle center).
struct MessageBubbleView: View {
    let message: ChatMessage
    var isThinking = false

    var body: some View {
        switch message.role.lowercased() {
        case "human", "user":
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.magenta)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case "ai", "assistant":
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if message.content.isEmpty, isThinking {
                        ThinkingDots()
                    } else {
                        Text(message.content)
                            .textSelection(.enabled)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 48)
            }
        case "tool":
            HStack {
                Image(systemName: "wrench.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(message.content)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                Spacer()
            }
            .padding(.horizontal, 4)
        default:
            HStack {
                Spacer()
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
    }
}

/// Animated "Kline is thinking" indicator while the stream is open but no
/// content has arrived yet — the user sees work happening (audit Q2).
private struct ThinkingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.magenta)
                    .frame(width: 8, height: 8)
                    .opacity(i == phase ? 1 : 0.25)
            }
        }
        .padding(.vertical, 6)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
