import XCTest

/// Local simulator only: real ContentView + non-preview VM + real SpeechService. Model and
/// SpeechDriver effects are injected; these tests make no claim about audible device output.
final class MVPStatusPlaybackTests: XCTestCase {
    private enum InputFailure: Error { case focusNotAcquired }
    @MainActor
    private func launch(_ language: String = "zh-CN", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-platform-status-testing", "--mvp-test-language", language] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.platform.banner"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["fixture.platform.banner"].label.contains("preview=false"))
        XCTAssertFalse(app.staticTexts["LOCAL FIXTURE · NO NETWORK / 本地假数据模式"].exists)
        assertState(app, ["stage=idle", "busy=false", "canSend=true", "preview=false", "requests=0"])
        return app
    }

    @MainActor
    private func waitLabel(_ element: XCUIElement, contains: [String], file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: contains.map { _ in "label CONTAINS %@" }.joined(separator: " AND "), argumentArray: contains)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 8)
        XCTAssertEqual(result, .completed, "Expected \(contains), actual: \(element.label)", file: file, line: line)
    }

    @MainActor
    private func assertState(_ app: XCUIApplication, _ fields: [String], file: StaticString = #filePath, line: UInt = #line) {
        waitLabel(app.staticTexts["fixture.platform.state"], contains: fields, file: file, line: line)
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ question: String = "1+2", captureKeyboard: Bool = false) throws {
        let input = app.textFields["conversation.input"].exists ? app.textFields["conversation.input"] : app.textViews["conversation.input"]
        // The previous harness placed its footer over the real composer. Assert geometry
        // before tapping, rather than letting a fixture control intercept the tap silently.
        for id in ["fixture.platform.banner", "fixture.platform.state"] {
            XCTAssertFalse(input.frame.intersects(app.staticTexts[id].frame), "Composer overlaps \(id): \(input.frame) / \(app.staticTexts[id].frame)")
        }
        XCTAssertFalse(input.frame.intersects(app.buttons["fixture.platform.finish"].frame))
        XCTAssertTrue(input.isHittable)
        try acquireKeyboardFocus(app, input: input)
        input.typeText(question)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", question), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed, "Actual input: \(String(describing: input.value))")
        XCTAssertTrue(app.buttons["conversation.send"].isEnabled)
        XCTAssertTrue(app.buttons["conversation.send"].isHittable)
        XCTAssertFalse(app.buttons["conversation.send"].frame.intersects(app.keyboards.firstMatch.frame), "Send is under the keyboard")
        XCTAssertTrue(app.buttons["conversation.stop"].isHittable)
        XCTAssertFalse(app.buttons["conversation.stop"].frame.intersects(app.keyboards.firstMatch.frame), "Stop is under the keyboard")
        if captureKeyboard { attachScreenshot("Chinese keyboard open - Send and Stop visible") }
        app.buttons["conversation.send"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "Sending did not end editing")
    }

    @MainActor
    private func acquireKeyboardFocus(_ app: XCUIApplication, input: XCUIElement) throws {
        input.tap()
        let keyboardReady = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        let focus = app.staticTexts["fixture.platform.state"]
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "focus=true"), object: focus)
        let focusReady = XCTWaiter.wait(for: [focused], timeout: 5) == .completed
        guard keyboardReady && focusReady else {
            attachScreenshot("Input focus acquisition failure - no retry")
            XCTFail("A single input tap did not acquire focus. keyboard=\(keyboardReady); diagnostic=\(String(describing: focus.value)); field=\(input.debugDescription)")
            throw InputFailure.focusNotAcquired
        }
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func speaking(_ app: XCUIApplication, _ language: String = "zh-CN", requests: Int = 1) {
        assertState(app, ["stage=speaking", "busy=true", "canSend=false", "requests=\(requests)", "playbacks=\(requests)"])
        waitLabel(app.staticTexts["conversation.status"], contains: [language == "zh-CN" ? "正在播报" : "Speaking"])
    }

    @MainActor
    private func complete(_ app: XCUIApplication, _ language: String = "zh-CN", requests: Int = 1) {
        app.buttons["fixture.platform.finish"].tap() // driver -> SpeechService -> VM callback
        assertState(app, ["stage=idle", "busy=false", "canSend=true", "requests=\(requests)"])
        waitLabel(app.staticTexts["conversation.status"], contains: [language == "zh-CN" ? "本轮已完成" : "Turn complete"])
        XCTAssertTrue(app.buttons["conversation.start"].isEnabled)
    }

    @MainActor
    func testChineseTypedCompletionReturnsIdleAndNextSendWorks() throws {
        let app = launch()
        try send(app, captureKeyboard: true); speaking(app); complete(app)
        XCTAssertTrue(app.staticTexts["1加2等于3。"].exists)
        attachScreenshot("Chinese completed idle - reply visible")
        try send(app, "3+4"); speaking(app, requests: 2); complete(app, requests: 2)
    }

    @MainActor
    func testEnglishTypedCompletionReturnsIdleAndNextSendWorks() throws {
        let app = launch("en-US")
        try send(app); speaking(app, "en-US"); complete(app, "en-US")
        XCTAssertTrue(app.staticTexts["One plus two equals three."].exists)
        try send(app, "3+4"); speaking(app, "en-US", requests: 2); complete(app, "en-US", requests: 2)
    }

    @MainActor
    func testStopSpeakingAndOldFinishCannotCompleteNewTurn() throws {
        let app = launch()
        try send(app); speaking(app)
        app.buttons["conversation.stop"].tap()
        assertState(app, ["stage=idle", "busy=false", "canSend=true"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["已停止"])
        app.buttons["fixture.platform.finish"].tap()
        waitLabel(app.staticTexts["conversation.status"], contains: ["已停止"])
        try send(app, "3+4"); speaking(app, requests: 2)
        app.buttons["fixture.platform.old-finish"].tap()
        // Old platform UUID must not finish the current SpeechService/VM turn.
        speaking(app, requests: 2)
        complete(app, requests: 2)
    }

    @MainActor
    func testStopThinkingAndLateModelReplyPreserveStoppedStatus() throws {
        let app = launch("en-US", extra: ["--mvp-status-hold-model"])
        try send(app)
        assertState(app, ["stage=answering", "busy=true", "requests=1", "playbacks=0"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["Thinking"])
        app.buttons["conversation.stop"].tap()
        waitLabel(app.staticTexts["conversation.status"], contains: ["Stopped"])
        app.buttons["fixture.platform.answer"].tap()
        assertState(app, ["stage=idle", "busy=false", "canSend=true", "playbacks=0", "requests=1"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["Stopped"])
    }

    @MainActor
    private func focusDraftAndStop(_ app: XCUIApplication) throws {
        let input = app.textFields["conversation.input"].exists ? app.textFields["conversation.input"] : app.textViews["conversation.input"]
        try acquireKeyboardFocus(app, input: input)
        input.typeText("draft")
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "draft"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["camera.status"].exists, "Camera indicator disappeared while editing")
        XCTAssertTrue(app.staticTexts["camera.status"].isHittable, "Camera indicator is not visible while editing")
        XCTAssertTrue(app.staticTexts["conversation.status"].exists, "Turn status disappeared while editing")
        let stop = app.buttons["conversation.stop"]
        XCTAssertTrue(stop.isEnabled)
        XCTAssertTrue(stop.isHittable, "Stop must remain immediately usable with the keyboard up")
        XCTAssertFalse(stop.frame.intersects(app.keyboards.firstMatch.frame), "Stop is under the keyboard")
        XCTAssertFalse(app.buttons["conversation.send"].isEnabled, "Draft editing started an extra request while busy")
        stop.tap()
        assertState(app, ["stage=idle", "busy=false", "canSend=true", "requests=1"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["已停止"])
    }

    @MainActor
    func testFocusedDraftWhileSpeakingKeepsCameraIndicatorAndUsableStop() throws {
        let app = launch()
        try send(app); speaking(app)
        try focusDraftAndStop(app)
        app.buttons["fixture.platform.finish"].tap()
        assertState(app, ["stage=idle", "requests=1", "playbacks=1"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["已停止"])
    }

    @MainActor
    func testFocusedDraftWhileAnsweringKeepsCameraIndicatorAndUsableStop() throws {
        let app = launch(extra: ["--mvp-status-hold-model"])
        try send(app)
        assertState(app, ["stage=answering", "busy=true", "requests=1", "playbacks=0"])
        try focusDraftAndStop(app)
        app.buttons["fixture.platform.answer"].tap()
        assertState(app, ["stage=idle", "requests=1", "playbacks=0"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["已停止"])
    }

    @MainActor
    func testContinuousSpeechCompletionResumesListening() throws {
        let app = launch()
        app.buttons["conversation.start"].tap()
        assertState(app, ["stage=listening", "busy=false", "listens=1"])
        app.buttons["fixture.platform.say"].tap()
        speaking(app)
        app.buttons["fixture.platform.finish"].tap()
        assertState(app, ["stage=listening", "busy=false", "listens=2", "requests=1"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["正在听，请说中文"])
        app.buttons["fixture.platform.finish"].tap()
        assertState(app, ["stage=listening", "listens=2", "requests=1"])
    }

    @MainActor
    func testMissingVoiceGuidanceSurvivesStopAndLateEvent() throws {
        let app = launch(extra: ["--mvp-status-missing-voice"])
        try send(app)
        assertState(app, ["stage=idle", "busy=false", "canSend=true", "requests=1", "playbacks=0"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["播报声音", "下载"])
        app.buttons["conversation.stop"].tap()
        app.buttons["fixture.platform.finish"].tap()
        waitLabel(app.staticTexts["conversation.status"], contains: ["播报声音", "下载"])
    }

    @MainActor
    func testSettingsStopsPlaybackAndLateFinishKeepsStoppedState() throws {
        let app = launch()
        try send(app); speaking(app)
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["fixture.platform.finish"].tap()
        assertState(app, ["stage=idle", "busy=false", "canSend=true"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["已停止"])
    }

    @MainActor
    func testLanguageSwitchStopsPlaybackAndLateFinishKeepsCurrentLanguage() throws {
        let app = launch()
        try send(app); speaking(app)
        app.segmentedControls["conversation.language"].buttons["English"].tap()
        app.buttons["fixture.platform.finish"].tap()
        assertState(app, ["stage=idle", "busy=false", "canSend=true"])
        // SDK guidance has higher priority after switching language on an unconfigured build.
        waitLabel(app.staticTexts["conversation.status"], contains: ["Glasses features are not configured"])
    }

    @MainActor
    func testBackgroundPauseSurvivesLatePlaybackCompletion() throws {
        let app = launch()
        try send(app); speaking(app)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let background = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "state == %d OR state == %d",
            XCUIApplication.State.runningBackground.rawValue,
            XCUIApplication.State.runningBackgroundSuspended.rawValue
        ), object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed)
        app.activate(); settings.terminate()
        app.buttons["fixture.platform.finish"].tap()
        assertState(app, ["stage=idle", "busy=false", "canSend=true"])
        waitLabel(app.staticTexts["conversation.status"], contains: ["已暂停"])
    }
}
