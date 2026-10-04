import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testTagsHiddenUntilRequestedAndActionsHaveRoom() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--compact-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["View tags"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["#test_tag"].exists)
        let labels = ["Like", "Less", "Download", "Comments"]
        let buttons = labels.map { app.buttons[$0].firstMatch }
        let tabs = ["Home", "Immersive", "Downloads", "Favorites", "Settings"].map { app.buttons["tab-\($0)"] }
        for tab in tabs { XCTAssertGreaterThanOrEqual(tab.frame.width, 44) }
        for index in 1..<tabs.count { XCTAssertGreaterThanOrEqual(tabs[index].frame.minX, tabs[index - 1].frame.maxX - 1) }
        for button in buttons { XCTAssertGreaterThanOrEqual(button.frame.width, 44) }
        for index in 1..<buttons.count { XCTAssertGreaterThanOrEqual(buttons[index].frame.minX, buttons[index - 1].frame.maxX - 1) }
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Gradient home"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["View tags"].firstMatch.tap()
        XCTAssertTrue(app.buttons["#test_tag"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["tab-Immersive"].tap()
        XCTAssertTrue(app.staticTexts["Immersive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab-Settings"].isHittable)
        let immersive = XCTAttachment(screenshot: app.screenshot()); immersive.name = "Immersive controls"; immersive.lifetime = .keepAlways; add(immersive)
        XCTAssertFalse(app.staticTexts["#still_tag"].exists)
    }

    @MainActor func testSyncedLoginsFillSettingsEvenWhenRememberIsOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-sync-login"]
        app.launch()
        app.buttons["tab-Settings"].tap()
        let input = app.secureTextFields["sync-id-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("QT6-AAECAwQFBgcICQoLDA0ODw.ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8")
        app.buttons["Connect and merge"].tap()
        let username = app.textFields["Rule34 user ID"]
        let filled = NSPredicate(format: "value == %@", "synced-test-user")
        expectation(for: filled, evaluatedWith: username)
        waitForExpectations(timeout: 10)
        print("Sync UI status:", app.staticTexts["sync-status"].label)
        let key = app.secureTextFields["Rule34 API key"]
        XCTAssertNotEqual(key.value as? String, "Rule34 API key")
        XCTAssertFalse((key.value as? String ?? "").isEmpty)
        app.swipeUp()
        XCTAssertEqual(app.textFields["Pornhub username"].value as? String, "synced-test-name")
        let session = app.secureTextFields["Supported Pornhub session"]
        XCTAssertNotEqual(session.value as? String, "Supported Pornhub session")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Synced access fields (synthetic data)"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testHomeImmersiveHomeAndDownloads() async {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Quicktick"].waitForExistence(timeout: 10))
        app.buttons["tab-Immersive"].tap()
        XCTAssertTrue(app.staticTexts["Immersive"].waitForExistence(timeout: 5))
        app.buttons["tab-Home"].tap()
        XCTAssertTrue(app.navigationBars["Quicktick"].exists)
        app.buttons["tab-Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        app.buttons["tab-Favorites"].tap()
        XCTAssertTrue(app.navigationBars["Favorites"].exists)
    }
}
