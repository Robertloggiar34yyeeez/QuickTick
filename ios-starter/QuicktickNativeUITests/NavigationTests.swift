import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testCompactVisualSearchFiltersAndExcludedTags() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["search-filters"].tap()
        let input = app.textFields["search-filter-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("long_hair jacket")
        app.buttons["search-keyboard-done"].tap()
        app.buttons["Exclude jacket"].tap()
        XCTAssertTrue(app.buttons["Include jacket"].exists)
        app.buttons["search-sort-filter"].tap(); app.buttons["Random"].tap()
        let apply = app.buttons["apply-search-filters"]
        for _ in 0..<4 { if apply.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(apply.isHittable); apply.tap()
        XCTAssertTrue(app.textFields["feed-search-input"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["feed-search-input"].value as? String, "long_hair -jacket")
    }
    @MainActor func testManualVisualRefreshShowsProgressAndLoopsDownloadedGIF() {
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
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let gif = app.descendants(matching: .any).matching(identifier: "visual-refresh-gif").firstMatch
        for _ in 0..<3 { if gif.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(gif.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", "Looping"), evaluatedWith: gif)
        waitForExpectations(timeout: 15)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Manual visual refresh progress and local GIF loop"; capture.lifetime = .keepAlways; add(capture)
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
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "immersive-progress").count, 1)
            XCTAssertEqual(app.tabBars.count, 0)
            let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Immersive iPad full canvas \(orientation.rawValue)"; capture.lifetime = .keepAlways; add(capture)
        }
        app.buttons["tab-Home"].tap()
        // Home restores the media anchor instead of jumping to its header.
        let restoredMedia = app.otherElements["post-media-test:video"]
        XCTAssertTrue(restoredMedia.waitForExistence(timeout: 10))
        XCTAssertTrue(restoredMedia.isHittable)
        app.buttons["home-scroll-top"].tap()
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
        expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: playback)
        waitForExpectations(timeout: 10)
        app.buttons["fullscreen-test:video"].tap()
        let closeVideo = app.buttons["Close full screen video"]
        XCTAssertTrue(closeVideo.waitForExistence(timeout: 15))
        closeVideo.tap()
        expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: playback)
        waitForExpectations(timeout: 10)
        app.buttons["tab-Immersive"].tap(); app.buttons["tab-Home"].tap()
        // Tab refresh recreates the Home host. Resolve its current button on
        // every poll instead of holding an accessibility snapshot from before it.
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["inline-play-test:video"].value as? String == "Playing"
        }, object: nil)
        let result = XCTWaiter.wait(for: [resumed], timeout: 10)
        if result != .completed {
            let details = XCTAttachment(string: app.debugDescription); details.name = "Home return playback state"; details.lifetime = .keepAlways; add(details)
        }
        XCTAssertEqual(result, .completed, "The visible Home video must resume after tab refresh")
        app.buttons["feed-recent"].tap()
        XCTAssertTrue(app.buttons["inline-play-home:video"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["inline-play-test:video"].exists)
        app.buttons["feed-recommended"].tap()
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
        XCTAssertEqual(media.frame.width, min(680, app.frame.width), accuracy: 2)
        XCTAssertGreaterThan(frame.frame.height, 0)
        XCTAssertLessThanOrEqual(frame.frame.width, media.frame.width + 1)
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
            XCTAssertLessThanOrEqual(frame.frame.width, 681)
            XCTAssertGreaterThan(frame.frame.height, 0)
            XCTAssertLessThanOrEqual(frame.frame.height, viewport.height)
            let capture = XCTAttachment(string: "orientation=\(orientation.rawValue) viewport=\(viewport) media=\(media.frame) player=\(frame.frame)")
            capture.name = "Adaptive native media geometry";capture.lifetime = .keepAlways;add(capture)
        }
        XCUIDevice.shared.press(.home);app.activate()
        expectation(for: NSPredicate { _, _ in
            app.buttons["inline-play-test:video"].value as? String == "Playing"
        }, evaluatedWith: app)
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
        XCTAssertLessThanOrEqual(progress.frame.maxY, app.buttons["tab-Home"].frame.minY)
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
        app.swipeUp()
        expectation(for: NSPredicate(format: "value == %@", "Not liked"), evaluatedWith: like)
        waitForExpectations(timeout: 5)
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
        app.buttons["Done"].tap()
        app.buttons["tab-Immersive"].tap()
        XCTAssertTrue(app.staticTexts["Immersive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
        let immersive = XCTAttachment(screenshot: app.screenshot()); immersive.name = "Immersive controls"; immersive.lifetime = .keepAlways; add(immersive)
        XCTAssertFalse(app.staticTexts["#still_tag"].exists)
    }

    @MainActor func testPersonalPreferencesAndTabRefresh() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["feed-recent"].tap()
        app.buttons["tab-Home"].tap()
        expectation(for: NSPredicate(format: "selected == YES"), evaluatedWith: app.buttons["feed-recommended"])
        waitForExpectations(timeout: 10)
        app.buttons["personalize-feed"].tap()
        let input = app.textFields["positive-interest-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap()
        let intro = app.buttons["Continue"]
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        input.typeText("engineering")
        expectation(for: NSPredicate(format: "value == %@", "engineering"), evaluatedWith: input)
        waitForExpectations(timeout: 10)
        if intro.exists { intro.tap() }
        app.buttons["Add interests"].tap()
        XCTAssertTrue(app.staticTexts["engineering"].exists)
        app.buttons["Done"].tap()
        app.buttons["personalize-feed"].tap()
        XCTAssertTrue(app.staticTexts["engineering"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
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
        let username = app.textFields["rule34-user-input"]
        let filled = NSPredicate(format: "value == %@", "synced-test-user")
        expectation(for: filled, evaluatedWith: username)
        waitForExpectations(timeout: 10)
        print("Sync UI status:", app.staticTexts["sync-status"].label)
        let key = app.secureTextFields["rule34-key-input"]
        XCTAssertNotEqual(key.value as? String, "Rule34 API key")
        XCTAssertFalse((key.value as? String ?? "").isEmpty)
        let syncedName = app.textFields["pornhub-user-input"]
        for _ in 0..<5 { if syncedName.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(syncedName.waitForExistence(timeout:5))
        XCTAssertEqual(syncedName.value as? String, "synced-test-name")
        let session = app.secureTextFields["pornhub-session-input"]
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
