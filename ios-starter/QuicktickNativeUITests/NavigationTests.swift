import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testHomeImmersiveHomeAndDownloads() async {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Quicktick"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Immersive"].tap()
        XCTAssertTrue(app.navigationBars["Immersive"].exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Quicktick"].exists)
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        app.tabBars.buttons["Favorites"].tap()
        XCTAssertTrue(app.navigationBars["Favorites"].exists)
    }
}
