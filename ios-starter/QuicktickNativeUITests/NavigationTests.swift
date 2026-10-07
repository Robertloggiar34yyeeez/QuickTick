import XCTest

final class NavigationTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
    }
    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
    }
    @MainActor func testImmersiveIPadCanvasAndSideNavigation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        guard app.frame.width > 600 else { throw XCTSkip("iPad canvas regression runs on the iPad simulator") }
        app.buttons["tab-Immersive"].tap()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let surface = app.otherElements["immersive-video-surface"].firstMatch
            XCTAssertTrue(surface.waitForExistence(timeout: 15))
            expectation(for: NSPredicate(format: "value == %@", "Ready"), evaluatedWith: surface)
            waitForExpectations(timeout: 15)
            XCTAssertGreaterThan(surface.frame.width, app.frame.width * 0.85)
            XCTAssertEqual(surface.frame.width / surface.frame.height, 16.0 / 9, accuracy: 0.05)
            let home = app.buttons["tab-Home"], immersive = app.buttons["tab-Immersive"]
            XCTAssertTrue(home.isHittable); XCTAssertTrue(immersive.isHittable)
            XCTAssertEqual(home.frame.midX, immersive.frame.midX, accuracy: 1)
            XCTAssertLessThan(home.frame.midX, app.frame.width * 0.1)
            let like = app.buttons["immersive-Like"]
            XCTAssertTrue(like.isHittable)
            XCTAssertGreaterThan(like.frame.midX, app.frame.width * 0.9)
            XCTAssertTrue(app.buttons["open-settings"].isHittable)
            XCTAssertTrue(app.otherElements["immersive-progress"].exists)
            XCTAssertEqual(app.tabBars.count, 0)
            let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Immersive iPad full canvas \(orientation.rawValue)"; capture.lifetime = .keepAlways; add(capture)
        }
        app.buttons["tab-Home"].tap()
        XCTAssertTrue(app.staticTexts["home-title"].isHittable)
    }

    @MainActor func testFourTabsSettingsAndScrollToTop() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 10))
        let names = ["Home", "Immersive", "Favorites", "Downloads"]
        for name in names { XCTAssertTrue(app.buttons["tab-\(name)"].exists) }
        XCTAssertFalse(app.buttons["tab-Settings"].exists)
        app.swipeUp()
        let top = app.buttons["home-scroll-top"]
        XCTAssertTrue(top.waitForExistence(timeout: 5)); top.tap()
        XCTAssertTrue(app.staticTexts["home-title"].isHittable)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["home-title"].isHittable)
    }
    @MainActor func testSearchAppearsOnceBeforeAndAfterSubmitting() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["Toggle search"].tap()
        let fields = app.textFields.matching(identifier: "feed-search-input")
        XCTAssertEqual(fields.count, 1)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        fields.firstMatch.typeText("engineering")
        XCTAssertEqual(fields.firstMatch.value as? String, "engineering")
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.firstMatch.value as? String, "engineering")
    }
    @MainActor func testDownloadedImagesUseNormalFeedAndCloseFullComic() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-download-images"]; app.launch()
        app.buttons["tab-Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        let full = app.buttons["View full image"].firstMatch
        for _ in 0..<5 { if full.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(full.isHittable); full.tap()
        let close = app.buttons["Close full image"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Downloaded comic full view"; capture.lifetime = .keepAlways; add(capture)
        close.tap(); XCTAssertTrue(app.navigationBars["Downloads"].exists)
    }

    @MainActor func testHomeInlinePlaybackAndComicClose() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let playback = app.buttons["inline-play-test:video"]
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        let actualFrame = app.otherElements["video-frame"].firstMatch
        XCTAssertTrue(actualFrame.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", "Ready"), evaluatedWith: actualFrame)
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: playback)
        waitForExpectations(timeout: 10)
        playback.tap()
        expectation(for: NSPredicate(format: "value == %@", "Paused"), evaluatedWith: playback)
        waitForExpectations(timeout: 5)
        playback.tap()
        app.buttons["tab-Immersive"].tap(); app.buttons["tab-Home"].tap()
        expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: playback)
        waitForExpectations(timeout: 10)
        app.buttons["feed-recent"].tap()
        XCTAssertTrue(app.buttons["inline-play-home:video"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["inline-play-test:video"].exists)
        app.buttons["feed-recommended"].tap()
        XCTAssertTrue(app.buttons["inline-play-test:video"].waitForExistence(timeout: 10))
        let full = app.buttons["View full image"].firstMatch
        for _ in 0..<3 { if full.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(full.isHittable); full.tap()
        let close = app.buttons["Close full image"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Full comic with close control"; screenshot.lifetime = .keepAlways; add(screenshot)
        close.tap()
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 5))
    }

    @MainActor func testAdaptiveMediaAcrossOrientationsAndForeground() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let frame = app.otherElements["video-frame"].firstMatch
        let playback = app.buttons["inline-play-test:video"]
        let media = app.otherElements["post-media-test:video"]
        XCTAssertTrue(media.waitForExistence(timeout: 15))
        XCTAssertTrue(frame.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "value == %@", "Ready"), evaluatedWith: frame)
        waitForExpectations(timeout: 15)
        XCTAssertLessThanOrEqual(frame.frame.width,321)
        XCTAssertGreaterThan(frame.frame.height, 0)
        XCTAssertEqual(frame.frame.width / frame.frame.height,320.0 / 180,accuracy:0.05)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            app.buttons["home-scroll-top"].tap()
            // On a short landscape window the Home header can move media below
            // the viewport. Reset the scroll anchor, then expose the entire
            // video, rather than mistaking its visible Play button for media.
            let scroll = app.scrollViews.firstMatch
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.buttons["tab-Home"].frame.minY
            let viewport = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: max(1, bottom - top)).insetBy(dx: 0, dy: 12)
            for _ in 0..<8 {
                if viewport.contains(media.frame) { break }
                // Short drags avoid flinging past this small, native-size video.
                // XCTest cannot compute a hit point for controls occluded by
                // the bottom bar; use their bounds until fully in the viewport.
                let below = media.frame.midY > viewport.midY
                let distance = min(45, max(8, abs(media.frame.midY - viewport.midY) / 2))
                let origin = scroll.coordinate(withNormalizedOffset: .zero)
                let dragX = scroll.frame.width * 0.92
                // The center can intersect the search field or media controls.
                // Drag in the clear side margin owned by the feed ScrollView.
                let start = origin.withOffset(CGVector(dx: dragX, dy: viewport.midY + (below ? distance : -distance)))
                let end = origin.withOffset(CGVector(dx: dragX, dy: viewport.midY + (below ? -distance : distance)))
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            XCTAssertTrue(viewport.contains(media.frame), "Media \(media.frame) must fit viewport \(viewport)")
            XCTAssertTrue(playback.isHittable)
            XCTAssertTrue(frame.waitForExistence(timeout:10))
            expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: playback)
            waitForExpectations(timeout: 10)
            XCTAssertLessThanOrEqual(frame.frame.width,321)
            XCTAssertGreaterThan(frame.frame.height, 0)
            XCTAssertEqual(frame.frame.width / frame.frame.height, 320.0 / 180, accuracy: 0.05)
            let capture = XCTAttachment(screenshot:app.screenshot());capture.name = "Adaptive native media \(orientation.rawValue)";capture.lifetime = .keepAlways;add(capture)
        }
        XCUIDevice.shared.press(.home);app.activate()
        expectation(for:NSPredicate(format:"value == %@","Playing"),evaluatedWith:playback)
        waitForExpectations(timeout:15)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testImmersiveRailSnapsAndDoubleTapLikes() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["tab-Immersive"].tap()
        let like = app.buttons["immersive-Like"]
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        let actions = ["Like", "Less", "Comments", "Download", "Mute"].map { app.buttons["immersive-\($0)"] }
        for action in actions {
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.width, 44)
            XCTAssertEqual(action.frame.midX, like.frame.midX, accuracy: 1)
        }
        for index in 1..<actions.count { XCTAssertGreaterThan(actions[index].frame.minY, actions[index - 1].frame.maxY) }
        let progress = app.otherElements["immersive-progress"]
        XCTAssertTrue(progress.isHittable)
        XCTAssertLessThanOrEqual(progress.frame.maxY, app.buttons["tab-Home"].frame.minY)
        XCTAssertTrue(progress.exists)
        let before = like.frame
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
        center.doubleTap()
        XCTAssertEqual(like.value as? String, "Liked")
        center.doubleTap()
        XCTAssertEqual(like.value as? String, "Liked")
        app.swipeUp()
        expectation(for: NSPredicate(format: "value == %@", "Not liked"), evaluatedWith: like)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(like.frame.midX, before.midX, accuracy: 1)
        XCTAssertEqual(like.frame.midY, before.midY, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Frosted right rail and snapped timeline"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testTagsHiddenUntilRequestedAndActionsHaveRoom() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["View tags"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["#test_tag"].exists)
        let labels = ["Like", "Less", "Download", "Comments"]
        let buttons = labels.map { app.buttons[$0].firstMatch }
        let tabs = ["Home", "Immersive", "Favorites", "Downloads"].map { app.buttons["tab-\($0)"] }
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
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
        let immersive = XCTAttachment(screenshot: app.screenshot()); immersive.name = "Immersive controls"; immersive.lifetime = .keepAlways; add(immersive)
        XCTAssertFalse(app.staticTexts["#still_tag"].exists)
    }

    @MainActor func testSyncedLoginsFillSettingsEvenWhenRememberIsOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-sync-login"]
        app.launch()
        app.buttons["open-settings"].tap()
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
        let syncedName = app.textFields["Pornhub username"]
        for _ in 0..<5 { if syncedName.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(syncedName.waitForExistence(timeout:5))
        XCTAssertEqual(syncedName.value as? String, "synced-test-name")
        let session = app.secureTextFields["Supported Pornhub session"]
        XCTAssertNotEqual(session.value as? String, "Supported Pornhub session")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Synced access fields (synthetic data)"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testHomeImmersiveHomeAndDownloads() async {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 10))
        app.buttons["tab-Immersive"].tap()
        XCTAssertTrue(app.staticTexts["Immersive"].waitForExistence(timeout: 5))
        app.buttons["tab-Home"].tap()
        XCTAssertTrue(app.staticTexts["home-title"].exists)
        app.buttons["tab-Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        app.buttons["tab-Favorites"].tap()
        XCTAssertTrue(app.navigationBars["Favorites"].exists)
    }
}
