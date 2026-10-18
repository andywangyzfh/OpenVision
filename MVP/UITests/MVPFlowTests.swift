import XCTest

final class MVPFlowTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-ui-testing"]
        app.launch()
        return app
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
