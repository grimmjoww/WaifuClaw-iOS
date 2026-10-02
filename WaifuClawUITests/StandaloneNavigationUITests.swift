import XCTest

final class StandaloneNavigationUITests: XCTestCase {
    func testCompanionChoiceChangesHomeAndGuardianRequiresRealProject() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "YES"]
        app.launch()

        let chooseCompanion = app.buttons["chooseCompanion"]
        XCTAssertTrue(chooseCompanion.waitForExistence(timeout: 10))
        chooseCompanion.tap()
        XCTAssertTrue(app.navigationBars["Companions"].waitForExistence(timeout: 5))
        let rei = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rei,")).firstMatch
        XCTAssertTrue(rei.exists)
        rei.tap()
        XCTAssertEqual(rei.value as? String, "Selected")
        app.navigationBars.buttons["WaifuClaw"].tap()
        XCTAssertTrue(app.staticTexts["Rei"].waitForExistence(timeout: 5))

        let openGuardian = app.buttons["Review project changes"]
        XCTAssertTrue(openGuardian.exists)
        openGuardian.tap()
        XCTAssertTrue(app.navigationBars["Guardian"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose Files folder"].exists)
        XCTAssertFalse(app.buttons["Scan now"].isEnabled,
                       "Guardian must not invent a scan before a user grants project access")
    }

    func testMultiagentTeamIsReachableWithoutFakeOnlineAgents() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "YES"]
        app.launch()

        let openTeam = app.buttons["Start a multiagent workflow"]
        XCTAssertTrue(openTeam.waitForExistence(timeout: 10))
        openTeam.tap()
        XCTAssertTrue(app.navigationBars["Team"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Team workflow goal"].exists)
        let projectRead = app.switches["Allow workers to read selected project files"]
        XCTAssertTrue(projectRead.exists)
        XCTAssertEqual(projectRead.value as? String, "0")
        XCTAssertFalse(app.buttons["Start workflow"].isEnabled)
    }

    func testPhoneOnlyOnboardingReachesAgentAndModelSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["WAIFUCLAW_UI_TEST_RESET_ONBOARDING"] = "1"
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
        // First launch of a fresh iOS simulator can display Apple's keyboard
        // coaching window above the app. Dismiss that system UI, not the app's
        // separate onboarding button, before testing the actual finish action.
        let coachingText = "Speed up your typing by sliding your finger across the letters to compose a word."
        let coachingWindow = app.windows.containing(.staticText, identifier: coachingText).firstMatch
        if coachingWindow.exists {
            let dismissCoaching = coachingWindow.buttons["Continue"]
            XCTAssertTrue(dismissCoaching.exists)
            dismissCoaching.tap()
        }
        let finishOnboarding = app.buttons["onboarding.finish"]
        XCTAssertTrue(finishOnboarding.waitForExistence(timeout: 5))
        XCTAssertTrue(finishOnboarding.isEnabled)
        // XCTest scrolls an enabled button into view during tap(). Querying
        // isHittable before that scroll can report false on a smaller iPhone
        // even when the control is fully tappable and setup succeeds.
        finishOnboarding.tap()

        let tabs = app.tabBars
        XCTAssertTrue(tabs.buttons["Home"].waitForExistence(timeout: 15), app.debugDescription)
        tabs.buttons["Agent"].tap()
        XCTAssertTrue(app.buttons["Choose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Model settings"].exists)

        tabs.buttons["Settings"].tap()
        app.buttons["Model & API Key"].tap()
        XCTAssertTrue(app.buttons["Save provider settings"].waitForExistence(timeout: 5))
    }

    func testRealWorkspaceMemoryAndIntegrationSettingsAreVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "YES"]
        app.launch()

        let tabs = app.tabBars
        // The mobile dashboard creates its action tiles lazily below the
        // companion hero. Bring Runs into the visible, hittable viewport.
        app.scrollViews.firstMatch.swipeUp()
        let runs = app.buttons["Inspect runs & evidence"]
        XCTAssertTrue(runs.waitForExistence(timeout: 10))
        runs.tap()
        XCTAssertTrue(app.navigationBars["Runs"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Workspace"].waitForExistence(timeout: 10))
        tabs.buttons["Workspace"].tap()
        XCTAssertTrue(app.buttons["Choose folder"].waitForExistence(timeout: 5))

        tabs.buttons["Memory"].tap()
        XCTAssertTrue(app.buttons["Choose project folder"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Include relevant approved memories in agent requests"].exists,
                       "Memory-sharing consent should appear only after a real project is chosen")

        tabs.buttons["Settings"].tap()
        let permissions = app.buttons["Connections & Permissions"]
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        permissions.tap()
        XCTAssertTrue(app.navigationBars["Connections & Permissions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose project folder in Files"].exists)
        XCTAssertTrue(app.buttons["Set up or test model connection"].exists)
        app.navigationBars.buttons["Settings"].tap()
        let jev = app.buttons["Jev Decisions"]
        XCTAssertTrue(jev.waitForExistence(timeout: 5))
        jev.tap()
        XCTAssertTrue(app.buttons["Save Jev key"].waitForExistence(timeout: 5))

        app.navigationBars.buttons["Settings"].tap()
        let extensions = app.buttons["Manage extensions & hooks"]
        XCTAssertTrue(extensions.waitForExistence(timeout: 5))
        extensions.tap()
        XCTAssertTrue(app.buttons["Import manifest from Files"].waitForExistence(timeout: 5))

        app.navigationBars.buttons["Settings"].tap()
        let mcp = app.buttons["Manage MCP servers"]
        XCTAssertTrue(mcp.waitForExistence(timeout: 5))
        mcp.tap()
        XCTAssertTrue(app.buttons["Save server locally"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "OAuth-only servers")).firstMatch.exists)

        app.navigationBars.buttons["Settings"].tap()
        app.swipeUp()
        let pro = app.buttons["Membership & Pro status"]
        XCTAssertTrue(pro.waitForExistence(timeout: 5))
        pro.tap()
        XCTAssertTrue(app.staticTexts["There is no price or checkout in this release. Nothing on this screen can charge your Apple Account."].waitForExistence(timeout: 5))
    }
}
