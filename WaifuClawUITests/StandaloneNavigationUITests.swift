import XCTest

final class StandaloneNavigationUITests: XCTestCase {
    func testPhoneOnlyOnboardingReachesAgentAndModelSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "NO"]
        app.launch()

        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Pair your computer"].exists)
        next.tap()
        next.tap()
        app.buttons["Get started"].tap()

        let name = app.textFields["Your display name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("iPhone Builder")
        app.buttons["Continue"].tap()

        let tabs = app.tabBars
        XCTAssertTrue(tabs.buttons["Home"].waitForExistence(timeout: 10))
        tabs.buttons["Agent"].tap()
        XCTAssertTrue(app.buttons["Choose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Model settings"].exists)

        tabs.buttons["Settings"].tap()
        app.buttons["Model & API Key"].tap()
        XCTAssertTrue(app.buttons["Save provider settings"].waitForExistence(timeout: 5))
    }
}
