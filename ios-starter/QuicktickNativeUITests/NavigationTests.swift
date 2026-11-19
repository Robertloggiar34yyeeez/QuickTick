import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testInterfaceStylePersistsAcrossSettingsPresentation() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        func stylePicker() -> XCUIElement {
            let change = app.buttons["settings-change-theme"]
            if change.isHittable { change.tap() }
            let picker = app.buttons["interface-style-original"]
            for _ in 0..<8 { if picker.isHittable { break }; app.swipeUp() }
            return picker
        }
        app.buttons["open-settings"].tap()
        let picker = stylePicker()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        app.buttons["interface-style-original"].tap()
        XCTAssertTrue(app.buttons["interface-style-original"].isSelected)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["tab-Home"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        _ = stylePicker()
        XCTAssertTrue(app.buttons["interface-style-original"].isSelected)
        app.buttons["interface-style-new"].tap()
        XCTAssertTrue(app.buttons["interface-style-new"].isSelected)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Persistent original and premium interface switch"
        capture.lifetime = .keepAlways
        add(capture)
    }
    @MainActor private func assertHomeScrolledToTop(_ app: XCUIApplication,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) {
        // The shortcut animates for 0.3 seconds. XCTest may query the
        // accessibility tree before the title has re-entered the viewport.
        let title = app.staticTexts["home-title"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: title)], timeout: 5),
            .completed, "Scroll to top should restore the visible Home heading", file: file, line: line)
    }
    @MainActor func testRecommendationProfileCanBePreparedForNativeSharing() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["open-settings"].tap()
        let share = app.buttons["share-recommendation-profile"]
        for _ in 0..<7 { if share.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(share.isHittable); share.tap()
        let nativeShare = app.buttons["airdrop-profile-share-link"]
        XCTAssertTrue(nativeShare.waitForExistence(timeout: 10))
        XCTAssertTrue(nativeShare.isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Native recommendation profile sharing"; capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor func testCombinedRecommendationRefreshShowsProgressWithoutCompetingGIF() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-download-images", "--ui-testing-download-gif"]
        app.launch()
        app.buttons["tab-Immersive"].tap()
        let like = app.buttons["immersive-Like"]
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        if like.value as? String != "Liked" { like.tap() }
        app.buttons["open-settings"].tap()
        let refresh = app.buttons["force-visual-refresh"]
        for _ in 0..<12 { if refresh.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(refresh.isHittable); refresh.tap()
        let progress = app.descendants(matching: .any).matching(identifier: "manual-visual-progress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 45),
                      "One refresh action must fetch new posts and then begin the visual profile scan")
        let carousel = app.descendants(matching: .any).matching(identifier: "visual-refresh-carousel").firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "visual-refresh-gif").firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Manual visual refresh progress and lightweight carousel"; capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor func testActiveLearningKeepsPlaybackAndDislikeResponsive() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-active-learning", "--measure-performance"]
        let start = Date(); app.launch()
        let video = app.buttons["inline-play-test:video"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        print("QUICKTICK_METRIC simulator_fixture_launch_to_first_post_ms=\(Date().timeIntervalSince(start) * 1000)")
        expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: video)
        waitForExpectations(timeout: 15)
        for _ in 0..<3 { app.swipeUp(); app.swipeDown() }
        app.buttons["tab-Home"].tap()
        let dislike = app.buttons["dislike-test:video"]
        XCTAssertTrue(dislike.waitForExistence(timeout: 10)); dislike.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dislike)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["Close full image"].exists)
        XCTAssertTrue(app.buttons["dislike-test:image"].exists)
    }
    @MainActor func testHomeDislikeCannotOpenTheLowerImage() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        // A tall image directly below this video extends beyond its clipped
        // drawing bounds. Tap the actual coordinate, as a finger would.
        let dislike = app.buttons["dislike-test:video"]
        XCTAssertTrue(dislike.waitForExistence(timeout: 10))
        XCTAssertTrue(dislike.isHittable)
        dislike.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dislike)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["Close full image"].exists)
        XCTAssertTrue(app.buttons["dislike-test:image"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Home dislike removes upper post without opening lower image"
        capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor func testFavoritesImmersiveAndDownloadExport() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-download-images"]
        app.launch()
        app.buttons["tab-Immersive"].tap()
        let like = app.buttons["immersive-Like"]
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        if like.value as? String != "Liked" { like.tap() }
        app.buttons["tab-Favorites"].tap()
        XCTAssertTrue(app.buttons["favorites-shuffle"].waitForExistence(timeout: 10))
        let immersive = app.buttons["favorites-immersive"]
        XCTAssertTrue(immersive.waitForExistence(timeout: 10))
        immersive.tap()
        XCTAssertTrue(app.otherElements["immersive-media-test:video"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Back"].exists)
        app.buttons["Back"].tap()
        app.buttons["tab-Downloads"].tap()
        let export = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "export-download-")).firstMatch
        for _ in 0..<6 {
            if export.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(export.isHittable)
        export.tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 10) || app.buttons["Save to Files"].exists || app.otherElements["ActivityListView"].exists)
    }
    @MainActor func testDownloadsShuffleAndOriginalOrderMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-download-images"]
        app.launch()
        app.buttons["tab-Downloads"].tap()
        let shuffle = app.buttons["downloads-shuffle"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 10))
        XCTAssertEqual(shuffle.value as? String, "Original order")
        shuffle.tap()
        app.buttons["Shuffle downloads"].tap()
        XCTAssertEqual(shuffle.value as? String, "Shuffled")
        shuffle.tap()
        app.buttons["Original order"].tap()
        XCTAssertEqual(shuffle.value as? String, "Original order")
        shuffle.tap()
        let largest = app.buttons["downloads-sort-largest"]
        XCTAssertTrue(largest.waitForExistence(timeout: 5))
        largest.tap()
        XCTAssertEqual(shuffle.value as? String, "Largest first")
    }
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
            let window = app.windows.firstMatch.frame
            XCTAssertLessThanOrEqual(surface.frame.width, window.width + 2)
            XCTAssertLessThanOrEqual(surface.frame.height, window.height + 2)
            XCTAssertEqual(surface.frame.midX, window.midX, accuracy: 3,
                           "Immersive media should be centered independently of the sidebar")
            XCTAssertEqual(surface.frame.midY, window.midY, accuracy: 3,
                           "Immersive media should be centered on the device, not below its safe area")
            XCTAssertEqual(surface.frame.width / surface.frame.height, 320.0 / 180, accuracy: 0.10,
                           "The original video aspect ratio should survive rotation without center-cropping")
            let home = app.buttons["tab-Home"], immersive = app.buttons["tab-Immersive"]
            XCTAssertTrue(home.isHittable); XCTAssertTrue(immersive.isHittable)
            XCTAssertEqual(home.frame.midX, immersive.frame.midX, accuracy: 1)
            XCTAssertLessThan(home.frame.midX, app.frame.width * 0.1)
            let like = app.buttons["immersive-Like"]
            XCTAssertTrue(like.isHittable)
            XCTAssertGreaterThan(like.frame.midX, app.frame.width * 0.9)
            XCTAssertTrue(app.buttons["open-settings"].isHittable)
            let progress = app.descendants(matching: .any).matching(identifier: "immersive-progress")
            XCTAssertEqual(progress.count, 1)
            XCTAssertTrue(progress.firstMatch.isHittable,
                          "The timeline must stay tappable above the iPad home indicator")
            XCTAssertLessThanOrEqual(progress.firstMatch.frame.maxY, window.maxY - 20)
            XCTAssertEqual(app.tabBars.count, 0)
            let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Immersive iPad full canvas \(orientation.rawValue)"; capture.lifetime = .keepAlways; add(capture)
        }
        app.buttons["tab-Home"].tap()
        // Home restores the media anchor instead of jumping to its header.
        let restoredMedia = app.otherElements["post-media-test:video"]
        XCTAssertTrue(restoredMedia.waitForExistence(timeout: 10))
        XCTAssertTrue(restoredMedia.isHittable)
        XCTAssertEqual(restoredMedia.frame.midX, app.frame.midX, accuracy: 2,
                       "The pinned iPad sidebar must overlay the feed, not shift posts off center")
        app.buttons["home-scroll-top"].tap()
        assertHomeScrolledToTop(app)
    }

    @MainActor func testSwipeRightFromImmersiveEdgeReturnsToHome() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["tab-Immersive"].tap()
        XCTAssertTrue(app.staticTexts["Immersive"].waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.55))
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.55))
        start.press(forDuration: 0.07, thenDragTo: destination)
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 10))
    }

    @MainActor func testSettingsDirectoryMakesThemesAndRefreshEasyToFind() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 8))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15),
                      "The settings screen should be fully presented before checking its controls")
        XCTAssertTrue(app.buttons["settings-change-theme"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["settings-refresh-recommended"].exists)
        XCTAssertTrue(app.buttons["settings-jump-models"].exists)
        XCTAssertTrue(app.buttons["settings-sections-menu"].exists)
        app.buttons["settings-change-theme"].tap()
        XCTAssertTrue(app.switches["automatic-seasonal-theme-toggle"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    @MainActor func testFiveTabsSettingsAndScrollToTop() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 10))
        let names = ["Home", "Immersive", "Create", "Favorites", "Downloads"]
        for name in names { XCTAssertTrue(app.buttons["tab-\(name)"].exists) }
        XCTAssertFalse(app.buttons["tab-Settings"].exists)
        app.swipeUp()
        let top = app.buttons["home-scroll-top"]
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        XCTAssertLessThan(top.frame.maxY, app.buttons["tab-Home"].frame.minY,
                          "Scroll to top must be entirely above the floating iPhone dock")
        XCTAssertTrue(top.isHittable)
        top.tap()
        assertHomeScrolledToTop(app)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let title = app.staticTexts["home-title"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: title)], timeout: 5), .completed)
    }

    @MainActor func testIconOnlyFeedActionsAndIdleScrollShortcutOnLeft() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let dislike = app.buttons["dislike-test:video"]
        XCTAssertTrue(dislike.waitForExistence(timeout: 10))
        XCTAssertFalse(dislike.staticTexts["Less"].exists)
        let download = app.buttons["card-download-test:video"]
        XCTAssertTrue(download.exists)
        XCTAssertFalse(download.staticTexts["Download"].exists)

        app.swipeUp()
        let scrollTop = app.buttons["home-scroll-top"]
        XCTAssertTrue(scrollTop.waitForExistence(timeout: 5))
        XCTAssertLessThan(scrollTop.frame.midX, app.frame.width / 2)
        scrollTop.tap()
        assertHomeScrolledToTop(app)
    }
    @MainActor func testCreateStudioFirstRunAndReturnToFeed() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["tab-Create"].waitForExistence(timeout: 10))
        app.buttons["tab-Create"].tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 5))
        if app.buttons["studio-intro-complete"].waitForExistence(timeout: 2) {
            app.buttons["studio-intro-complete"].tap()
        }
        XCTAssertTrue(app.otherElements["studio-prompt"].exists || app.textViews["studio-prompt"].exists)
        XCTAssertTrue(app.buttons["studio-generate"].exists)
        XCTAssertTrue(app.buttons["studio-generate-from-favorites"].exists)
        XCTAssertTrue(app.buttons["studio-open-lora-menu"].exists)
        app.buttons["studio-open-lora-menu"].tap()
        XCTAssertTrue(app.navigationBars["Model library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["studio-catalog-search"].exists)
        XCTAssertTrue(app.buttons["studio-catalog-kind-lora"].exists)
        XCTAssertTrue(app.buttons["studio-catalog-kind-checkpoint"].exists)
        app.buttons["Done"].tap()
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistence(timeout: 5))
    }
    @MainActor func testStudioCanContinueWithoutDownloadingAnima() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-quicktick-studio-intro-v1", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-Create"].waitForExistence(timeout: 10))
        app.buttons["tab-Create"].tap()
        let continueButton = app.buttons["studio-intro-complete"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()
        XCTAssertTrue(app.buttons["studio-generate"].waitForExistence(timeout: 5))
    }
    @MainActor func testHomeDownloadShowsFeedbackAndSavedState() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let download = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "card-download-")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        // UI tests share a simulator: a previous test may already have saved
        // this fixture, which is a valid persistent completed state.
        if download.value as? String != "Saved" {
            download.tap()
            let state = download.value as? String
            XCTAssertTrue(state == "Downloading" || state == "Saved", "A tap should show transfer feedback immediately")
        }
        expectation(for: NSPredicate(format: "value == %@", "Saved"), evaluatedWith: download)
        waitForExpectations(timeout: 15)
    }
    @MainActor func testHideAITabKeepsFourNavigationTabs() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["tab-Create"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["show-ai-tab-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "1" { toggle.tap() }
        app.buttons["Done"].tap()
        let createTab = app.buttons["tab-Create"]
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: createTab)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        for name in ["Home", "Immersive", "Favorites", "Downloads"] {
            XCTAssertTrue(app.buttons["tab-\(name)"].exists)
        }
        app.buttons["open-settings"].tap()
        let restoreToggle = app.switches["show-ai-tab-toggle"]
        if restoreToggle.value as? String == "0" { restoreToggle.tap() }
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["tab-Create"].waitForExistence(timeout: 5))
    }
    @MainActor func testSearchAppearsOnceBeforeAndAfterSubmitting() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["home-search-button"].tap()
        let fields = app.textFields.matching(identifier: "feed-search-input")
        XCTAssertEqual(fields.count, 1)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // A fresh simulator can show the system QuickPath introduction over
        // the keyboard. Dismiss the observed prompt before sending input.
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.waitForExistence(timeout: 2) { keyboardIntroduction.tap() }
        fields.firstMatch.tap()
        fields.firstMatch.typeText("engineering")
        // iPadOS can present QuickPath only after the first keystroke. It
        // temporarily exposes a stale field value through accessibility.
        if keyboardIntroduction.waitForExistence(timeout: 2) { keyboardIntroduction.tap() }
        expectation(for: NSPredicate(format: "value == %@", "engineering"), evaluatedWith: fields.firstMatch)
        waitForExpectations(timeout: 10)
        app.buttons["apply-search-filters"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: fields.firstMatch)
        waitForExpectations(timeout: 10)
        app.buttons["home-search-button"].tap()
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(fields.count, 1)
        XCTAssertTrue(app.buttons["Remove engineering"].exists)
        app.buttons["Exclude engineering"].tap()
        XCTAssertTrue(app.buttons["Include engineering"].exists)
        app.buttons["Include engineering"].tap()
        XCTAssertTrue(app.buttons["Exclude engineering"].exists)
        app.buttons["close-search"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: fields.firstMatch)
        waitForExpectations(timeout: 10)
    }
    @MainActor func testDownloadedImagesUseNormalFeedAndCloseFullComic() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-download-images"]; app.launch()
        let homeCard = app.otherElements["post-media-test:video"]
        XCTAssertTrue(homeCard.waitForExistence(timeout: 10))
        let homeWidth = homeCard.frame.width
        app.buttons["tab-Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        let offlineCard = app.otherElements["post-media-test:video"]
        XCTAssertTrue(offlineCard.waitForExistence(timeout: 10))
        XCTAssertEqual(offlineCard.frame.width, homeWidth, accuracy: 2,
                       "Downloaded media cards must use the same edge-to-edge width as Home")
        // The full-bleed comic now uses a stable media action identifier,
        // rather than a label that is different between the two UI styles.
        let full = app.buttons["fullscreen-test:image"]
        XCTAssertTrue(full.waitForExistence(timeout: 10))
        for _ in 0..<10 { if full.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(full.isHittable); full.tap()
        let close = app.buttons["Close full image"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let comic = app.scrollViews["full-comic-zoom"]
        XCTAssertTrue(comic.waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.35))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.75))
        start.press(forDuration: 0.06, thenDragTo: finish)
        XCTAssertTrue(close.exists, "A downward reading scroll must never dismiss a long comic")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Downloaded comic full view"; capture.lifetime = .keepAlways; add(capture)
        close.tap(); XCTAssertTrue(app.navigationBars["Downloads"].exists)
    }

    @MainActor func testBottomNavigationDockFillsAvailableWidth() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let dock = app.otherElements["bottom-navigation-bar"]
        let home = app.buttons["tab-Home"]
        XCTAssertTrue(dock.waitForExistence(timeout: 12))
        XCTAssertTrue(home.exists)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(dock.frame.width, screen.width * 0.95,
                             "Bottom navigation should span the screen, not float as an inset capsule")
        XCTAssertLessThanOrEqual(dock.frame.maxY, screen.maxY + 1)
        XCTAssertGreaterThanOrEqual(dock.frame.maxY, screen.maxY - 50,
                                    "Dock should sit directly above the system home indicator")
        if screen.width < 600 {
            app.buttons["tab-Immersive"].tap()
            XCTAssertTrue(dock.waitForExistence(timeout: 8))
            XCTAssertGreaterThan(dock.frame.width, screen.width * 0.95,
                                 "Immersive on iPhone must retain the edge-attached navigation bar")
            XCTAssertGreaterThanOrEqual(dock.frame.maxY, screen.maxY - 50,
                                        "Immersive navigation must not float above the home indicator")
        }
    }

    @MainActor func testFullscreenVideoSwipeDownDismissesOnlyStandardViewer() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let surface = app.buttons["fullscreen-test:video"]
        XCTAssertTrue(surface.waitForExistence(timeout: 12))
        surface.tap()
        let close = app.buttons["Close full screen video"]
        XCTAssertTrue(close.waitForExistence(timeout: 12))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.32))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.72))
        start.press(forDuration: 0.06, thenDragTo: finish)
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed,
            "Swipe down should exit standard full screen")
        // Immersive vertical paging uses a different view without this dismiss
        // modifier, so its vertical gesture still advances within the feed.
        app.buttons["tab-Immersive"].tap()
        XCTAssertTrue(app.staticTexts["Immersive"].waitForExistence(timeout: 10))
    }

    @MainActor func testFirstRunWizardExplainsFeaturesAndCanSkipRule34Key() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-first-run"]
        app.launch()
        let next = app.buttons["first-run-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Your taste")).firstMatch.exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["Choose your source"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["first-run-rule34-key"].exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["Which characters do you like?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["simple-pick-mario"].exists)
        app.buttons["simple-pick-mario"].tap()
        XCTAssertTrue(app.otherElements["simple-example-post"].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.staticTexts["You're ready"].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.buttons["tab-Home"].waitForExistence(timeout: 10))
    }

    @MainActor func testFirstRunAdvancedModeShowsDetailedPreferences() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-first-run"]
        app.launch()
        let next = app.buttons["first-run-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 12))
        app.buttons["Advanced"].tap()
        next.tap()
        next.tap()
        XCTAssertTrue(app.staticTexts["Teach QuickTick your taste"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Characters"].exists)
        XCTAssertTrue(app.staticTexts["Artists"].exists)
        XCTAssertTrue(app.staticTexts["Attributes"].exists)
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
        expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: playback)
        waitForExpectations(timeout: 10)
        app.buttons["fullscreen-test:video"].tap()
        let closeVideo = app.buttons["Close full screen video"]
        XCTAssertTrue(closeVideo.waitForExistence(timeout: 15))
        closeVideo.tap()
        expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: playback)
        waitForExpectations(timeout: 10)
        let immersiveTab = app.buttons["tab-Immersive"]
        immersiveTab.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == YES"), object: immersiveTab)],
            timeout: 8), .completed, "Immersive must mount its iPad side dock before switching back")
        let homeTab = app.buttons["tab-Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 8))
        homeTab.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == YES"), object: homeTab)],
            timeout: 8), .completed, "The return tap must select Home, not remain on Immersive")
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: playback)
        let result = XCTWaiter.wait(for: [resumed], timeout: 10)
        if result != .completed {
            let details = XCTAttachment(string: app.debugDescription); details.name = "Home return playback state"; details.lifetime = .keepAlways; add(details)
        }
        XCTAssertEqual(result, .completed, "The visible Home video must resume after tab refresh")
        app.buttons["feed-popular"].tap()
        // The store commits synchronously, but XCTest can observe the old
        // accessibility tree for one SwiftUI rendering pass after a tap.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == YES"),
            object: app.buttons["feed-popular"])], timeout: 5), .completed)
        app.buttons["feed-recommended"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == YES"),
            object: app.buttons["feed-recommended"])], timeout: 5), .completed,
            "The second sort tap must take effect before its asynchronous refresh")
        XCTAssertTrue(app.buttons["inline-play-test:video"].waitForExistence(timeout: 10))
        let full = app.buttons["View full image"].firstMatch
        for _ in 0..<3 { if full.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(full.isHittable); full.tap()
        let close = app.buttons["Close full image"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
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
        XCTAssertGreaterThan(frame.frame.width, 0)
        XCTAssertLessThanOrEqual(frame.frame.width, min(680, app.frame.width) + 1)
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
            XCTAssertGreaterThan(frame.frame.width, 0)
        XCTAssertLessThanOrEqual(frame.frame.width, min(680, app.frame.width) + 1)
            XCTAssertGreaterThan(frame.frame.height, 0)
            XCTAssertEqual(frame.frame.width / frame.frame.height, 320.0 / 180, accuracy: 0.05)
            let capture = XCTAttachment(string: "orientation=\(orientation.rawValue) viewport=\(viewport) media=\(media.frame) player=\(frame.frame)")
            capture.name = "Adaptive native media geometry";capture.lifetime = .keepAlways;add(capture)
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
        let progressElements = app.descendants(matching: .any).matching(identifier: "immersive-progress")
        XCTAssertEqual(progressElements.count, 1)
        let progress = progressElements.firstMatch
        XCTAssertTrue(progress.isHittable)
        XCTAssertLessThanOrEqual(progress.frame.maxY + 8, app.buttons["tab-Home"].frame.minY,
                                 "The timeline must clear the bottom tab dock with room to seek")
        XCTAssertGreaterThanOrEqual(progress.frame.height, 44)
        XCTAssertTrue(progress.exists)
        let before = like.frame
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
        let surface = app.otherElements["immersive-video-surface"].firstMatch
        expectation(for: NSPredicate(format: "value == %@", "Ready"), evaluatedWith: surface)
        waitForExpectations(timeout: 10)
        center.tap() // Pause before verifying an exact seek, independent of elapsed time.
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        let percentage = Int((progress.value as? String ?? "").split(separator: " ").first ?? "") ?? -1
        XCTAssertEqual(Double(percentage), 75, accuracy: 4)
        center.doubleTap()
        XCTAssertEqual(like.value as? String, "Liked")
        center.doubleTap()
        XCTAssertEqual(like.value as? String, "Liked")
        let pageStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.72))
        let pageEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.22))
        pageStart.press(forDuration: 0.08, thenDragTo: pageEnd)
        // The first gesture can land during a SwiftUI paging/seek transition
        // on a busy simulator; a second deliberate swipe must still work.
        if like.value as? String != "Not liked" { app.swipeUp() }
        let pageAdvanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Not liked"), object: like)
        let swipeResult = XCTWaiter.wait(for: [pageAdvanced], timeout: 5)
        if swipeResult != .completed {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Immersive swipe did not advance"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(swipeResult, .completed, "A vertical media swipe must switch to the next post")
        XCTAssertEqual(like.frame.midX, before.midX, accuracy: 1)
        XCTAssertEqual(like.frame.midY, before.midY, accuracy: 1)
        like.tap()
        XCTAssertEqual(like.value as? String, "Liked")
        let download = app.buttons["immersive-Download"]
        download.tap()
        expectation(for: NSPredicate(format: "value == %@", "Saved"), evaluatedWith: download)
        waitForExpectations(timeout: 15)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Frosted right rail and snapped timeline"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["tab-Downloads"].tap()
        let size = app.staticTexts["download-size-test:next"]
        for _ in 0..<4 { if size.exists { break }; app.swipeUp() }
        XCTAssertTrue(size.waitForExistence(timeout: 10))
        XCTAssertNotEqual(size.label, "Size unavailable")
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
        app.buttons["#test_tag"].tap()
        XCTAssertTrue(app.buttons["Copy tag"].waitForExistence(timeout: 5))
        app.buttons["Copy tag"].tap()
        XCTAssertTrue(app.staticTexts["Copied test_tag"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["tab-Immersive"].tap()
        XCTAssertTrue(app.staticTexts["Immersive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
        let immersive = XCTAttachment(screenshot: app.screenshot()); immersive.name = "Immersive controls"; immersive.lifetime = .keepAlways; add(immersive)
        XCTAssertFalse(app.staticTexts["#still_tag"].exists)
    }

    @MainActor func testPersonalPreferencesAndTabRefresh() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["feed-popular"].tap()
        app.buttons["tab-Home"].tap()
        // Reselecting Home refreshes the current mode instead of silently
        // discarding an explicit Popular selection or search.
        expectation(for: NSPredicate(format: "selected == YES"), evaluatedWith: app.buttons["feed-popular"])
        waitForExpectations(timeout: 10)
        app.buttons["feed-recommended"].tap()
        XCTAssertTrue(app.buttons["feed-recommended"].isSelected)
        XCTAssertFalse(app.buttons["personalize-feed"].exists)
        app.buttons["open-settings"].tap()
        let personalize = app.buttons["personalize-feed"]
        for _ in 0..<8 { if personalize.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(personalize.isHittable)
        personalize.tap()
        let input = app.textFields["positive-interest-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap()
        input.typeText("engineering")
        expectation(for: NSPredicate(format: "value == %@", "engineering"), evaluatedWith: input)
        waitForExpectations(timeout: 10)
        app.buttons["Add interest"].tap()
        XCTAssertTrue(app.staticTexts["engineering"].exists)
        app.buttons["save-taste"].tap()
        personalize.tap()
        XCTAssertTrue(app.staticTexts["engineering"].waitForExistence(timeout: 10))
        app.buttons["save-taste"].tap()
    }

    @MainActor func testIPadHomeSideGuttersDoubleTapToLike() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        guard app.frame.width > 850 else { throw XCTSkip("iPad side-gutter gestures need a wide layout") }
        let like = app.buttons["Like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.58))
        left.doubleTap()
        XCTAssertTrue(like.isSelected)
        like.tap()
        XCTAssertFalse(like.isSelected)
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.58))
        right.doubleTap()
        XCTAssertTrue(like.isSelected)
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
