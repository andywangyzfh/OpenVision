import XCTest

final class MVPFlowTests: XCTestCase {
    private func launch(resetLanguage: Bool = true, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-ui-testing"]
        if resetLanguage { app.launchArguments.append("--reset-mvp-language") }
        app.launchArguments += additionalArguments
        app.launch()
        return app
    }
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
    func testUnknownLanguageSettingFallsBackAndCanBeChanged() {
        let app = launch(resetLanguage: false, additionalArguments: ["--mvp-test-language", "legacy-unknown"])
        XCTAssertTrue(app.buttons["开始对话"].waitForExistence(timeout: 10))
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        XCTAssertTrue(app.buttons["Start conversation"].exists)
    }
    func testSettingsAndBackgroundRecovery() {
        let app = launch()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["授权眼镜相机"].exists)
        app.buttons["完成"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        let status = app.staticTexts["conversation.status"]
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已暂停"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["开始对话"].exists)
        XCTAssertTrue(app.staticTexts["相机关闭"].exists)
    }
    func testProductionStartupWithoutRestoringAnyAccount() {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-smoke-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["conversation.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["LOCAL FIXTURE · NO NETWORK / 本地假数据模式"].exists)
        XCTAssertFalse(app.staticTexts["conversation.status"].label.contains("Meta SDK setup failed"))
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["Continue with ChatGPT"].waitForExistence(timeout: 5))
    }
    func testLanguageSwitchAndMinimalSurface() {
        let app = launch()
        XCTAssertTrue(app.buttons["conversation.start"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["相机关闭"].exists)
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        XCTAssertTrue(app.buttons["Start conversation"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }
    func testTextConversationFixtureAndClear() {
        let app = launch()
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        let input = app.textFields["conversation.input"].exists ? app.textFields["conversation.input"] : app.textViews["conversation.input"]
        input.tap(); input.typeText("Hello")
        app.buttons["conversation.send"].tap()
        XCTAssertTrue(app.staticTexts["Local test reply. No model was called."].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap()
        XCTAssertFalse(app.staticTexts["Local test reply. No model was called."].exists)
    }
    func testPhotoFailureNeverInventsScene() {
        let app = launch()
        app.buttons["conversation.photo"].tap()
        let status = app.staticTexts["conversation.status"]
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "未能取得新照片"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["本地测试回答。没有调用模型。"].exists)
    }
}
