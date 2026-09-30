import XCTest
@testable import WaifuClaw

final class OnboardingTests: XCTestCase {
    func testStandaloneFlowDoesNotAskForDesktopOrInactivePermissions() {
        XCTAssertEqual(OnboardingStep.allCases, [.intro, .displayName])
        XCTAssertNil(OnboardingStep.displayName.next)
        XCTAssertEqual(OnboardingStep.intro.next, .displayName)
    }
}
