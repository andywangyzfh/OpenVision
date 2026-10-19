import XCTest

final class MVPFlowTests: XCTestCase {
    @MainActor
    func testNormalProductionColdStartRequiresExplicitAccountAction() {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["conversation.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["conversation.send"].isEnabled)
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["account.restore"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].exists)
        // Deliberately do not restore or sign in. Real credentials are never read by this test.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["conversation.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["conversation.send"].isEnabled)
    }

    @MainActor
    func testProductionAppKeychainPreflightUsesOnlySyntheticRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-keychain-preflight"]
        app.launch()
        let status = app.staticTexts["diagnostics.keychain.preflight"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.label.hasPrefix("PASS"), status.label)
        XCTAssertFalse(app.buttons["conversation.start"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.label.hasPrefix("PASS"), status.label)
    }

    @MainActor
    func testProductionSDKSetupFailureKeepsAccountUIUsableInBothLanguages() {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-smoke-testing", "--mvp-force-sdk-setup-failure"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation.start"].waitForExistence(timeout: 15))
        app.segmentedControls["conversation.language"].buttons["中文"].tap()
        XCTAssertTrue(app.staticTexts["glasses.setup.status"].label.contains("眼镜功能未配置"))
        XCTAssertFalse(app.buttons["conversation.photo"].isEnabled)
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        XCTAssertTrue(app.staticTexts["glasses.setup.status"].label.contains("Glasses features are not configured"))
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        guard let register = settingsButton("glasses.register", in: app) else { return }
        XCTAssertFalse(register.isEnabled)
        guard let developer = settingsButton("glasses.developer.install", in: app) else { return }
        XCTAssertFalse(developer.isEnabled)
        guard let authorize = settingsButton("glasses.camera.authorize", in: app) else { return }
        XCTAssertFalse(authorize.isEnabled)
    }

    @MainActor
    private func launch(resetLanguage: Bool = true, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-ui-testing"]
        if resetLanguage { app.launchArguments.append("--reset-mvp-language") }
        app.launchArguments += additionalArguments
        app.launch()
        return app
    }

    /// Form rows are lazy: scroll only until the row exists. Disabled SDK controls
    /// intentionally need not be hittable, and this helper never taps or enables them.
    @MainActor
    private func settingsButton(_ identifier: String, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        let target = app.buttons[identifier]
        for attempt in 0...6 {
            if target.waitForExistence(timeout: 1) { return target }
            guard attempt < 6 else { break }
            let surface: XCUIElement
            if app.collectionViews.firstMatch.exists { surface = app.collectionViews.firstMatch }
            else if app.tables.firstMatch.exists { surface = app.tables.firstMatch }
            else if app.scrollViews.firstMatch.exists { surface = app.scrollViews.firstMatch }
            else {
                XCTFail("Settings has no scrollable Form while locating \(identifier)", file: file, line: line)
                return nil
            }
            surface.swipeUp()
        }
        XCTFail("Settings button \(identifier) did not exist after at most 6 Form scrolls", file: file, line: line)
        return nil
    }

    @MainActor
    private func closeSettingsAfterScrolling(in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let close = app.buttons["完成"]
        for attempt in 0...6 {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
            if XCTWaiter.wait(for: [ready], timeout: 1) == .completed {
                let before = XCTAttachment(screenshot: app.screenshot())
                before.name = "Settings Done visible before its single tap"; before.lifetime = .keepAlways; add(before)
                let visibleControl = XCTAttachment(string: "Done exists=\(close.exists), hittable=\(close.isHittable), frame=\(close.frame)\n\(app.debugDescription)")
                visibleControl.name = "Settings Done ready state and accessibility hierarchy"; visibleControl.lifetime = .keepAlways; add(visibleControl)
                close.tap() // One real tap, only after the toolbar control is visible and hittable.
                let dismissed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"), object: close)
                if XCTWaiter.wait(for: [dismissed], timeout: 5) == .completed {
                    let after = XCTAttachment(screenshot: app.screenshot())
                    after.name = "Settings dismissed after the single Done tap"; after.lifetime = .keepAlways; add(after)
                    return true
                }
                break
            }
            guard attempt < 6 else { break }
            let surface: XCUIElement
            if app.collectionViews.firstMatch.exists { surface = app.collectionViews.firstMatch }
            else if app.tables.firstMatch.exists { surface = app.tables.firstMatch }
            else if app.scrollViews.firstMatch.exists { surface = app.scrollViews.firstMatch }
            else { break }
            surface.swipeDown() // Return the lazy Form toward its top; never tap a missing toolbar item.
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings close failed after bounded Form scroll"; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Settings close failure accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTFail("Settings Done did not become hittable within 6 downward Form scrolls, or its single tap did not dismiss it", file: file, line: line)
        return false
    }
    @MainActor
    func testLanguagePersistsAcrossAppTermination() {
        let app = launch()
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        app.terminate()
        let restored = launch(resetLanguage: false)
        XCTAssertTrue(restored.buttons["Start conversation"].waitForExistence(timeout: 10))
        restored.segmentedControls["conversation.language"].buttons["中文"].tap()
        restored.terminate()
        let chinese = launch(resetLanguage: false)
        XCTAssertTrue(chinese.buttons["开始对话"].waitForExistence(timeout: 10))
    }
    @MainActor
    func testUnknownLanguageSettingFallsBackAndCanBeChanged() {
        let app = launch(resetLanguage: false, additionalArguments: ["--mvp-test-language", "legacy-unknown"])
        XCTAssertTrue(app.buttons["开始对话"].waitForExistence(timeout: 10))
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        XCTAssertTrue(app.buttons["Start conversation"].exists)
    }
    @MainActor
    func testSettingsAndBackgroundRecovery() {
        let app = launch()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        guard settingsButton("glasses.camera.authorize", in: app) != nil else { return }
        guard closeSettingsAfterScrolling(in: app) else { return }
        // Switching to a real system app exercises lifecycle transitions on runtimes
        // whose synthetic Home key does not leave the foreground (e.g. iPhone Duo).
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let background = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "state == %d OR state == %d",
            XCUIApplication.State.runningBackground.rawValue,
            XCUIApplication.State.runningBackgroundSuspended.rawValue
        ), object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed, "App state: \(app.state.rawValue)")
        app.activate()
        settings.terminate()
        let status = app.staticTexts["conversation.status"]
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已暂停"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["开始对话"].exists)
        XCTAssertTrue(app.staticTexts["相机关闭"].exists)
    }
    @MainActor
    func testProductionStartupWithoutRestoringAnyAccount() {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-smoke-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["LOCAL FIXTURE · NO NETWORK / 本地假数据模式"].exists)
        XCTAssertTrue(app.staticTexts["眼镜未连接"].exists || app.staticTexts["Glasses disconnected"].exists)
        // Real configure() may succeed in developer mode. If it fails, the guarded
        // configuration state must remain usable, without accessing Wearables.shared.
        let setupFailed = app.staticTexts["glasses.setup.status"].exists
        if setupFailed { XCTAssertTrue(app.staticTexts["glasses.setup.status"].label.contains("Meta SDK")) }
        XCTAssertFalse(app.buttons["conversation.photo"].isEnabled)
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        guard let authorize = settingsButton("glasses.camera.authorize", in: app) else { return }
        XCTAssertEqual(authorize.isEnabled, !setupFailed)
    }
    @MainActor
    func testLanguageSwitchAndMinimalSurface() {
        let app = launch()
        XCTAssertTrue(app.buttons["conversation.start"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["相机关闭"].exists)
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        XCTAssertTrue(app.buttons["Start conversation"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }
    @MainActor
    func testTextConversationFixtureAndClear() {
        let app = launch()
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        let input = app.textFields["conversation.input"].exists ? app.textFields["conversation.input"] : app.textViews["conversation.input"]
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Software keyboard must appear before typing")
        input.typeText("Hello")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Software keyboard is required for this keyboard-geometry regression")
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Hello"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed, "Actual input: \(String(describing: input.value))")
        XCTAssertTrue(app.buttons["conversation.send"].isEnabled)
        XCTAssertTrue(app.buttons["conversation.send"].isHittable)
        XCTAssertFalse(app.buttons["conversation.send"].frame.intersects(app.keyboards.firstMatch.frame), "Send is under the keyboard")
        app.buttons["conversation.send"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Turn complete"), object: app.staticTexts["conversation.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["Local test reply. No model was called."].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap()
        XCTAssertFalse(app.staticTexts["Local test reply. No model was called."].exists)
    }
    @MainActor
    func testPhotoFailureNeverInventsScene() {
        let app = launch()
        app.buttons["conversation.photo"].tap()
        XCTAssertTrue(app.buttons["photo.confirm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["尚未开启相机"].exists)
        app.buttons["photo.confirm"].tap()
        let status = app.staticTexts["conversation.status"]
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "未能取得新照片"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["本地测试回答。没有调用模型。"].exists)
    }

    @MainActor
    func testPhotoRequestCanBeCancelledBeforeCameraStarts() {
        let app = launch()
        app.buttons["conversation.photo"].tap()
        XCTAssertTrue(app.buttons["photo.cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["尚未开启相机"].exists)
        app.buttons["photo.cancel"].tap()
        let status = app.staticTexts["conversation.status"]
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "相机尚未开启"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["相机关闭"].exists)
        XCTAssertFalse(app.staticTexts["本地测试回答。没有调用模型。"].exists)
    }
    @MainActor
    func testPhotoConfirmationStopLeavesCameraOff() {
        let app = launch()
        app.buttons["conversation.photo"].tap()
        XCTAssertTrue(app.buttons["photo.stop"].waitForExistence(timeout: 5))
        app.buttons["photo.stop"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["photo.confirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["相机关闭"].exists)
        XCTAssertFalse(app.staticTexts["本地测试回答。没有调用模型。"].exists)
    }

    @MainActor
    func testDismissingPhotoConfirmationCancelsWithoutStartingCamera() {
        let app = launch()
        app.buttons["conversation.photo"].tap()
        let title = app.staticTexts["photo.confirmation.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Photo sheet before one dismissal drag"; before.lifetime = .keepAlways; add(before)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Photo sheet drag bounds"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        // A short semantic swipe on the title did not dismiss the native sheet.
        // Start in the observed sheet top blank area and drag toward the actual window bottom once.
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -16))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        start.press(forDuration: 0.05, thenDragTo: end)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Photo sheet after one dismissal drag"; after.lifetime = .keepAlways; add(after)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["photo.confirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "相机尚未开启"), object: app.staticTexts["conversation.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["相机关闭"].exists)
        XCTAssertFalse(app.staticTexts["本地测试回答。没有调用模型。"].exists)
    }

}
