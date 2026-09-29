import SwiftUI

/// The swipeable welcome pages. Shared by `OnboardingView` (first launch)
/// and `ReplayIntroView` (Settings → "Replay intro").
struct IntroPagesView: View {
    var onContinue: () -> Void

    private enum Page: Int, CaseIterable {
        case meetWaifuClaw
        case remote
        case meetKline
    }

    @State private var page: Page = .meetWaifuClaw

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    introPage(for: page)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button(page == .meetKline ? "Get started" : "Next", action: nextTapped)
                .themePrimaryButton()
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
        }
    }

    private func nextTapped() {
        if page == .meetKline {
            onContinue()
        } else if let next = Page(rawValue: page.rawValue + 1) {
            page = next
        }
    }

    // MARK: - Pages

    private func introPage(for page: Page) -> some View {
        VStack(spacing: 16) {
            Spacer()
            pageArt(for: page)
            Text(pageTitle(for: page))
                .themeDisplayText()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text(pageBody(for: page))
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pageTitle(for: page)). \(pageBody(for: page))")
    }

    @ViewBuilder
    private func pageArt(for page: Page) -> some View {
        switch page {
        case .meetKline:
            KlineAvatar(diameter: 128)
                .shadow(color: Theme.magenta.opacity(0.35), radius: 24)
        default:
            ZStack {
                Circle()
                    .fill(Theme.magentaGradient)
                    .frame(width: 128, height: 128)
                    .shadow(color: Theme.magenta.opacity(0.35), radius: 24)
                Image(systemName: pageIcon(for: page))
                    .font(.system(size: 52))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
        }
    }

    private func pageIcon(for page: Page) -> String {
        switch page {
        case .meetWaifuClaw: "sparkles"
        case .remote: "apps.iphone"
        case .meetKline: "" // Kline art instead
        }
    }

    private func pageTitle(for page: Page) -> String {
        switch page {
        case .meetWaifuClaw: "Meet WaifuClaw"
        case .remote: "Your computer, in your pocket"
        case .meetKline: "Meet Kline"
        }
    }

    private func pageBody(for page: Page) -> String {
        switch page {
        case .meetWaifuClaw:
            "Your own agent system — a team of AI specialists that build, run, "
                + "and verify real work on your computer."
        case .remote:
            "This app is the remote. Watch runs live, check on your team, and "
                + "talk to your agents — from anywhere."
        case .meetKline:
            "Your operator and guide. She keeps an eye on everything and tells "
                + "you straight when something needs you."
        }
    }
}
