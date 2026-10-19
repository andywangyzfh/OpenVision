import XCTest

/// A real settings view with SDK availability deliberately false. No glasses are accessed.
final class MVPGlassesInputConfigurationTests: XCTestCase {
    @MainActor
    private func waitForState(_ predicate: NSPredicate, of element: XCUIElement, in app: XCUIApplication) -> Bool {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        guard result == .completed else {
            // This fixture has no account or live content. Preserve evidence if a single
            // physical interaction fails; do not silently issue a second toggle tap.
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Inputs configuration accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Inputs configuration failed state"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Expected UI state was not reached after one action: \(predicate)")
            return false
        }
        return true
    }

    @MainActor
    func testGlassesGesturesAreOptInAndUnavailableSDKCannotArm() {
        let app = XCUIApplication()
        app.launchArguments = ["--mvp-platform-status-testing", "--mvp-test-language", "zh-CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.platform.banner"].waitForExistence(timeout: 15))
        app.buttons["settings.open"].tap()
        let toggle = app.switches["inputs.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0", "Gestures must start disabled, including a new process")
        XCTAssertFalse(app.buttons["inputs.arm"].isEnabled)
        // Run 2's saved AX tree proves this identified element is the entire row
        // (x24...382), with one real child Switch (x301...364). Its normalized
        // trailing-row tap landed at x364.1, outside the actual control. Address
        // that observed child directly; neither a row tap nor a guessed ratio.
        let controls = toggle.switches
        guard controls.count == 1 else {
            XCTFail("Expected one actual Switch inside the labelled toggle row, found \(controls.count)")
            return
        }
        let control = controls.firstMatch
        guard control.isHittable, toggle.frame.contains(control.frame) else {
            XCTFail("The actual Switch is not hittable inside its labelled row")
            return
        }
        control.tap()
        guard waitForState(NSPredicate(format: "value == %@", "1"), of: toggle, in: app) else { return }
        let arm = app.buttons["inputs.arm"]
        guard waitForState(NSPredicate(format: "enabled == true"), of: arm, in: app) else { return }
        for _ in 0..<4 where !arm.isHittable { app.swipeUp() }
        XCTAssertTrue(arm.isHittable)
        // The preference is allowed with SDK=false. Explicit activation must fail
        // visibly before any SDK/device operations; disabled-after-enabling was
        // an incorrect assumption in the original test.
        arm.tap()
        let status = app.staticTexts["inputs.status"]
        guard waitForState(NSPredicate(format: "label CONTAINS %@", "SDK 未就绪"), of: status, in: app) else { return }
        XCTAssertTrue(status.label.contains("双击待命未开启"))
        for _ in 0..<4 where !toggle.isHittable { app.swipeDown() }
        XCTAssertTrue(toggle.isHittable)
        guard controls.count == 1, control.isHittable, toggle.frame.contains(control.frame) else {
            XCTFail("The actual Switch cannot be safely selected to disable the preference")
            return
        }
        control.tap()
        guard waitForState(NSPredicate(format: "value == %@", "0"), of: toggle, in: app) else { return }
        app.buttons["完成"].tap()
        let state = app.staticTexts["fixture.platform.state"]
        XCTAssertTrue(state.label.contains("requests=0"))
        XCTAssertTrue(state.label.contains("listens=0"))
        XCTAssertTrue(state.label.contains("playbacks=0"))
        XCTAssertTrue(app.staticTexts["camera.status"].label.contains("关闭"))
    }
}
